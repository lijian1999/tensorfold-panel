"""轮询：按什么频率读哪个接口，把读数喂给采集器换成快照。

只读 /health、/metrics、/v1/models 和 /proc/meminfo，不发别的请求。
读取和采集器抛的异常一律吃掉，不往外抛，免得把窗口程序带崩。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

from panel.collector import Collector
from panel.config import load_config
from panel.engine import EngineReader
from panel.fmt import cost_fmt, split1
from panel.sources import read_meminfo
from panel.usage import UsageLedger

METRICS_S = 0.5      # /metrics 最短读取间隔
MEMORY_S = 1.0       # 内存读数最短读取间隔
MODEL_S = 5.0        # 模型名重试间隔
BUSY_TAIL_S = 2.0    # 忙碌过后多久不再读 /metrics


def _lanes_sum(snapshot) -> int:
    """把三个流指示点数加起来（不是字典、缺键都按 0 算）。"""
    if not isinstance(snapshot, dict):
        return 0
    lanes = snapshot.get("lanes") or {}

    def num(value) -> int:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return 0
        return int(value)

    return num(lanes.get("decoding")) + num(lanes.get("prefilling")) + num(lanes.get("waiting"))


def _is_busy(snapshot) -> bool:
    """忙：状态是 prefill/decode，或三个流指示数之和大于 0。"""
    if not isinstance(snapshot, dict):
        return False
    if snapshot.get("state") in ("prefill", "decode"):
        return True
    return _lanes_sum(snapshot) > 0


def brief_line(snapshot) -> str:
    """一行简短状态，给命令行 --brief 用。

    形如 `decode 2/1/0 tps=112.4 pf=10240/24615 round=3+3 today=98req $0.597`；
    读不到的项写 `-`。
    """
    snap = snapshot if isinstance(snapshot, dict) else {}
    state = snap.get("state") or "idle"
    lanes = snap.get("lanes") or {}
    lanes_str = "{}/{}/{}".format(
        _num(lanes.get("decoding")), _num(lanes.get("prefilling")), _num(lanes.get("waiting"))
    )
    decode = snap.get("decode")
    if isinstance(decode, dict) and isinstance(decode.get("tps"), (int, float)):
        int_part, dec_part = split1(decode["tps"])
        tps_str = "tps={}{}".format(int_part, dec_part)
    else:
        tps_str = "-"
    prefill = snap.get("prefill")
    if isinstance(prefill, dict):
        filled = _num(prefill.get("filled_tokens"))
        prompt = _num(prefill.get("prompt_tokens"))
        pf_str = "pf={}/{}".format(filled, prompt)
    else:
        pf_str = "-"
    rnd = snap.get("round")
    if isinstance(rnd, dict):
        round_str = "round={}+{}".format(_num(rnd.get("requests")), _num(rnd.get("running")))
    else:
        round_str = "-"
    today = snap.get("today")
    if isinstance(today, dict):
        today_str = "today={}req {}".format(
            _num(today.get("requests")), cost_fmt(today.get("cost", 0.0) or 0.0, "$")
        )
    else:
        today_str = "-"
    line = " ".join((state, lanes_str, tps_str, pf_str, round_str, today_str))
    # 认出来的引擎：非空才写，方便在终端上一眼看出是哪个
    engine = snap.get("engine")
    if isinstance(engine, str) and engine:
        line += f" engine={engine}"
    return line


def _num(value) -> int:
    """不是数字（含 None、bool）一律按 0 算。"""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return int(value)


class Poller:
    """决定每次读取读哪几项、喂给采集器、算出下一次读取的间隔。"""

    def __init__(self, config, fetcher, collector, read_memory=None, clock=time.monotonic):
        self.config = config
        self.fetcher = fetcher
        self.collector = collector
        # 没给 read_memory 时用真读 /proc/meminfo 的那个；测试里给假的
        self.read_memory = read_meminfo if read_memory is None else read_memory
        self.clock = clock
        self._model = None        # 拿到的模型名
        self._model_at = None     # 上次试读模型名的时刻
        self._metrics_at = None   # 上次读 /metrics 的时刻
        self._memory_at = None    # 上次读内存的时刻
        self._last_busy = None    # 上一次出现忙碌的时刻
        self._last_snapshot = None

    def tick(self):
        """做一次读取，返回（快照， 距下一次读取的秒数）。"""
        now = self.clock()
        last = self._last_snapshot

        # 带引擎识别的读取器需要这次的时刻和平均预填充速度才能算出每条流的明细
        prepare = getattr(self.fetcher, "prepare", None)
        if callable(prepare):
            self._call(lambda: prepare(now, getattr(self.collector, "prefill_tps", None)))

        health = self._call(self.fetcher.health)

        metrics = None
        # vLLM 的 metrics 不访问网络，这一拍一定能拿到
        every = getattr(self.fetcher, "metrics_every_tick", False) is True
        if health is not None and every:
            metrics = self._call(self.fetcher.metrics)
        elif health is not None and self._need_metrics(now, last, health):
            if self._metrics_at is None or (now - self._metrics_at) >= METRICS_S:
                self._metrics_at = now
                metrics = self._call(self.fetcher.metrics)

        memory = None
        if self._memory_at is None or (now - self._memory_at) >= MEMORY_S:
            self._memory_at = now
            memory = self._call(self.read_memory)

        model = None
        if self._want_model(now, last, health):
            self._model_at = now
            model = self._call(self.fetcher.model_name)
            if isinstance(model, str) and model:
                # 拿到名字就记下来，之后不再反复读 /v1/models
                self._model = model

        feed_failed = False
        try:
            snapshot = self.collector.feed(now, health, metrics, memory, model)
            if not isinstance(snapshot, dict):
                # 采集器坏了：沿用上一次，没有就用离线
                snapshot = last if last is not None else {"state": "offline"}
                feed_failed = True
        except Exception:
            snapshot = last if last is not None else {"state": "offline"}
            feed_failed = True

        self._last_snapshot = snapshot

        if feed_failed:
            # 采集器坏了：固定 0.5 秒后再试
            interval = 0.5
        elif _is_busy(snapshot):
            self._last_busy = now
            interval = 0.1
        elif snapshot.get("state") == "offline":
            interval = 0.5
        else:
            interval = 0.25

        # 扣掉这次读取花掉的时间
        wait = max(0.01, interval - (self.clock() - now))
        return (snapshot, wait)

    def run(self, on_snapshot, stop_event):
        """一圈圈地读，直到 stop_event 置位。每拍都回调，内容相同也回调。"""
        while not stop_event.is_set():
            snapshot, wait = self.tick()
            try:
                on_snapshot(snapshot)
            except Exception:
                pass
            if stop_event.wait(wait):
                break

    def _want_model(self, now, last, health) -> bool:
        """要不要读模型名。"""
        if health is None:
            return False
        recovering = isinstance(last, dict) and last.get("state") == "offline"
        if self._model:
            # 已经拿到名字：只有从离线恢复才重新读一次
            return recovering
        if recovering:
            return True
        # 还没拿到名字：距上次尝试满 5 秒（或从没试过）才再试
        return self._model_at is None or (now - self._model_at) >= MODEL_S

    def _need_metrics(self, now, last, health) -> bool:
        """这一拍要不要读 /metrics。"""
        if _is_busy(last):
            return True
        if self._last_busy is not None and (now - self._last_busy) < BUSY_TAIL_S:
            return True
        return _num(health.get("requests_running")) > 0

    def _call(self, func):
        """调用一个读取；出错就当没读到（None）。"""
        try:
            return func()
        except Exception:
            return None


def _print_snapshot(snapshot, brief: bool) -> None:
    """往标准输出打一行。"""
    if brief:
        print(brief_line(snapshot), flush=True)
    else:
        print(json.dumps(snapshot, ensure_ascii=False), flush=True)


def _sleep(seconds: float) -> None:
    if seconds > 0:
        time.sleep(seconds)


def main(argv=None) -> int:
    """命令行入口：在终端上跑轮询，默认不碰正式的今日用量文件。"""
    import signal
    import threading

    parser = argparse.ArgumentParser(prog="python3 -m panel.poller", description="读取模型接口的只读接口")
    parser.add_argument("--seconds", type=float, default=10.0, help="跑多久（秒），默认 10")
    parser.add_argument("--every", type=float, default=1.0, help="隔多久打印一行（秒），默认 1")
    parser.add_argument("--config", default=None, help="配置文件路径")
    parser.add_argument("--state-dir", dest="state_dir", default=None, help="今日用量目录；不给就不写文件")
    parser.add_argument("--brief", action="store_true", help="打一行简短状态，不打整份 JSON")
    args = parser.parse_args(argv)

    config = load_config(args.config)
    fetcher = EngineReader(config.urls())
    # 没给目录时 usage=None：不和正在运行的副屏程序抢着写同一个账本
    usage = UsageLedger(config, state_dir=args.state_dir) if args.state_dir else None
    collector = Collector(config, usage)
    poller = Poller(config, fetcher, collector)

    stop = threading.Event()

    def _stop(signum, frame):
        stop.set()

    old = signal.signal(signal.SIGINT, _stop)
    try:
        start = time.monotonic()
        last_print = start - args.every  # 让第一拍就打印一行
        while not stop.is_set() and (time.monotonic() - start) < args.seconds:
            snapshot, wait = poller.tick()
            if (time.monotonic() - start) >= args.seconds:
                break
            now = time.monotonic()
            if (now - last_print) >= args.every:
                last_print = now
                try:
                    _print_snapshot(snapshot, args.brief)
                except BrokenPipeError:
                    # 输出被掐断（例如被 head 提前关掉）：把标准输出指到空设备，
                    # 免得解释器退出时再报一次 BrokenPipeError
                    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
                    break
            _sleep(wait)
    finally:
        signal.signal(signal.SIGINT, old)
        fetcher.close()
        if usage is not None:
            usage.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
