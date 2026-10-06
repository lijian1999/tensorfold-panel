"""今日用量：把 /health 里的累计值换算成当天的增量，记在当天的账上。

账本写在 <state_dir>/usage.json，换日时把前一天追加到 <state_dir>/usage-history.jsonl。
读文件、写文件都不抛异常：读不懂就当没有，写不进去就留着“待写”，下次再试。
"""

from __future__ import annotations

import json
import os
import tempfile
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from panel.config import Config

USAGE_FILE = "usage.json"
HISTORY_FILE = "usage-history.jsonl"

# 今日账上的四项，和 /health 里的累计值一一对应
_COUNTERS = ("prompt_tokens", "cached_tokens", "completion_tokens", "requests")
# /health 里对应的键名
_SOURCE_KEYS = ("prompt", "cached", "completion", "requests")

_FALLBACK_TIMEZONE = "America/Los_Angeles"


def _zone(name: str):
    """时区名；配置里的时区名无效时退回太平洋时间。"""
    for candidate in (name, _FALLBACK_TIMEZONE):
        try:
            return ZoneInfo(candidate)
        except (ValueError, OSError, KeyError):
            # 时区数据库里没有这个名字（ZoneInfoNotFoundError 是 KeyError 的子类），
            # 或者根本找不到 tzdata
            pass
    return timezone(timedelta(hours=-8))  # 兜底：固定按 UTC−8 算


class UsageLedger:
    """一天的账：累计值的差记到当天，换日清零，有变化时限量写文件。"""

    def __init__(
        self,
        config: Config,
        clock=time.time,
        state_dir: str | None = None,
        save_interval_s: float = 10.0,
    ) -> None:
        self.config = config
        self._clock = clock
        self._state_dir = os.path.expanduser(config.state_dir if state_dir is None else state_dir)
        self._zone = _zone(config.timezone)
        self._save_interval_s = save_interval_s
        self._counters: dict = {key: 0 for key in _COUNTERS}
        self._last_totals: dict | None = None  # 上一次读到的累计值；None 表示还没有基线
        self._last_epoch: float | None = None   # 上次读数的引擎启动标记（vLLM 才有）
        self._date: str | None = None
        self._pending = False                  # 文件和内存里的账一致，没有要写的东西
        self._last_write: float | None = None  # 上次写文件时的时刻
        self._load()

    def update(self, totals: dict) -> None:
        """把一组累计值记进账：先换日，再算增量，最后按需写文件。"""
        if not isinstance(totals, dict):
            return
        now = self._clock()
        self._roll_day(now)
        if not self._valid(totals):
            return  # 缺键或值不是整数：整次忽略
        # 引擎启动标记：不是数字就当没有（只用 TensorFold 时一直是 None）
        epoch = totals.get("epoch")
        if isinstance(epoch, bool) or not isinstance(epoch, (int, float)):
            epoch = None
        last = self._last_totals
        epoch_changed = epoch != self._last_epoch
        if last is None:
            delta = None  # 第一次运行：只记下基线，不动账
        elif epoch_changed:
            delta = {key: totals[key] for key in _SOURCE_KEYS}  # 引擎重启或换了引擎：整个算增量
        elif any(totals[key] < last[key] for key in _SOURCE_KEYS):
            delta = {key: totals[key] for key in _SOURCE_KEYS}  # 模型重启过：整个算增量
        else:
            delta = {key: totals[key] - last[key] for key in _SOURCE_KEYS}
        self._last_totals = {key: totals[key] for key in _SOURCE_KEYS}
        self._last_epoch = epoch
        if delta is None or epoch_changed or any(delta.values()):
            self._pending = True
        if delta is not None:
            for counter, src in zip(_COUNTERS, _SOURCE_KEYS):
                self._counters[counter] += delta[src]
        self._maybe_write(now)

    def today(self) -> dict:
        """今天的账（费用现算）。先处理换日，离线时过了 0 点这里也会清零。"""
        now = self._clock()
        self._roll_day(now)
        return {
            "date": self._date,
            "prompt_tokens": self._counters["prompt_tokens"],
            "cached_tokens": self._counters["cached_tokens"],
            "completion_tokens": self._counters["completion_tokens"],
            "requests": self._counters["requests"],
            "cost": self._cost(self._counters),
        }

    def flush(self) -> None:
        """有没写的改动就立刻写文件（不受写文件间隔的限制）。"""
        if self._pending:
            self._write()

    # 以下都是内部方法

    def _valid(self, totals: dict) -> bool:
        """四项齐全且都是整数（bool 不算整数）才算一次有效读数。"""
        for key in _SOURCE_KEYS:
            value = totals.get(key)
            if isinstance(value, bool) or not isinstance(value, int):
                return False
        return True

    def _today(self, now: float) -> str:
        """按配置的时区算出今天的日期。"""
        return datetime.fromtimestamp(now, self._zone).date().isoformat()

    def _roll_day(self, now: float) -> None:
        """换日：前一天写进历史，四项清零，日期改成今天，并立刻写文件。"""
        today = self._today(now)
        if today == self._date:
            return
        if self._date is not None and any(self._counters.values()):
            self._append_history(self._date, self._cost(self._counters))
        self._date = today
        self._counters = {key: 0 for key in _COUNTERS}
        self._pending = True
        self._write()

    def _maybe_write(self, now: float) -> None:
        """到点了才写文件，免得每秒写一次磁盘。"""
        if not self._pending:
            return
        if self._last_write is not None and now - self._last_write < self._save_interval_s:
            return
        self._write()

    def _write(self) -> bool:
        """把账写进文件；写成功就清掉“待写”标记，写失败就留着下次再试。"""
        payload = {
            "version": 1,
            "date": self._date,
            "prompt_tokens": self._counters["prompt_tokens"],
            "cached_tokens": self._counters["cached_tokens"],
            "completion_tokens": self._counters["completion_tokens"],
            "requests": self._counters["requests"],
            "last_totals": self._last_totals,
        }
        if self._last_epoch is not None:
            payload["last_epoch"] = self._last_epoch
        if self._write_text(USAGE_FILE, json.dumps(payload, ensure_ascii=False) + "\n"):
            self._pending = False
            self._last_write = self._clock()
            return True
        return False

    def _append_history(self, day: str, cost: float) -> None:
        """把一天的合计追加到历史文件；写不进去就丢掉这一行，不抛异常。"""
        row = {"date": day, **self._counters, "cost": cost}
        self._write_text(HISTORY_FILE, json.dumps(row, ensure_ascii=False) + "\n", append=True)

    def _cost(self, counters: dict) -> float:
        """按配置的单价算费用（单价都是每百万 token）。"""
        cached = counters["cached_tokens"]
        total = (
            (counters["prompt_tokens"] - cached) * self.config.price_input
            + cached * self.config.price_cached
            + counters["completion_tokens"] * self.config.price_output
        )
        return total / 1_000_000

    def _read(self) -> dict | None:
        """读账本文件；读不了或者不是合法的 JSON 对象就返回 None。"""
        try:
            with open(os.path.join(self._state_dir, USAGE_FILE), "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def _load(self) -> None:
        """读 usage.json；读不懂就当作第一次运行（账为 0，没有基线）。"""
        data = self._read()
        if data is not None and self._load_from(data):
            return
        self._date = self._today(self._clock())

    def _load_from(self, data: dict) -> bool:
        """文件里的账能用就采用，用不了返回 False（按第一次运行处理）。"""
        date = data.get("date")
        if not isinstance(date, str) or not date:
            return False
        for key in _COUNTERS:
            if not _is_int(data.get(key)):
                return False
        last = data.get("last_totals")
        if not isinstance(last, dict) or any(not _is_int(last.get(key)) for key in _SOURCE_KEYS):
            return False
        for key in _SOURCE_KEYS:
            if key not in last:
                return False
        self._date = date
        self._counters = {key: data[key] for key in _COUNTERS}
        self._last_totals = {key: last[key] for key in _SOURCE_KEYS}
        epoch = data.get("last_epoch")
        self._last_epoch = epoch if isinstance(epoch, (int, float)) and not isinstance(epoch, bool) else None
        return True

    def _write_text(self, name: str, text: str, append: bool = False) -> bool:
        """写文件；目录建不出来或文件动不了就返回 False。"""
        path = os.path.join(self._state_dir, name)
        try:
            os.makedirs(self._state_dir, exist_ok=True)
            if append:
                with open(path, "a", encoding="utf-8") as f:
                    f.write(text)
                return True
            return self._replace_text(path, text)
        except OSError:
            return False

    @staticmethod
    def _replace_text(path: str, text: str) -> bool:
        """先写同目录的临时文件再改名换过去，避免读到写了一半的文件。"""
        directory = os.path.dirname(path)
        try:
            fd, tmp = tempfile.mkstemp(prefix=".usage-", suffix=".tmp", dir=directory)
        except OSError:
            return False
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
            try:
                os.replace(tmp, path)
            except OSError:
                os.unlink(tmp)
                return False
            return True
        except OSError:
            return False


def _is_int(value) -> bool:
    """整数才算数（bool 不算）。"""
    return isinstance(value, int) and not isinstance(value, bool)
