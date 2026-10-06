"""采集：把 /health、/metrics、/proc/meminfo 的原始读数变成一份指标快照。

Collector.feed 只做计算：不读时钟、不访问网络、不读写文件、不起线程。
同样的输入序列一定得到同样的输出，返回的字典每次都是新的。

`hook` 字段照 2.3 判断：外报告知了每条流（tfpanel.v 是 1、streams 是列表）就是
“好用”，这时现存输出、预填充进度和缓存命中、上下文占用都从外挂行里取；
不好用时走降级算法（现存输出取 0、进度和缓存命中读不到、上下文占用用占用比换算）。
"""

from __future__ import annotations

import copy
import math

# 没有账本（或账本抛异常）时快照里的 today
NO_TODAY = {
    "date": "",
    "prompt_tokens": 0,
    "cached_tokens": 0,
    "completion_tokens": 0,
    "requests": 0,
    "cost": 0.0,
}

# 从没读到过内存读数时快照里的 memory
NO_MEMORY = {"used_gb": 0.0, "total_gb": 0.0}

DEFAULT_CONTEXT_MAX = 262144   # 上下文上限的兜底值
DEFAULT_LANES_MAX = 5          # 流数上限的兜底值
DEFAULT_PREFILL_TPS = 2300.0   # 平均预填充速度的初始值
SMOOTH_WINDOW_S = 10.0         # 解码采样的保留时长
SMOOTH_LAG_S = 2.5            # 解码速度的平滑滞后


def js_round(value: float) -> int:
    """和 JavaScript 的 Math.round 一致：.5 永远往前进一位。"""
    return math.floor(value + 0.5)


def _number(source: dict, key: str, default=0):
    """取一个读数；缺键、不是数字都按默认值处理。"""
    value = source.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    return value


class _Prev:
    """上一次成功读到 /health 时的那组数（下面简称“上次”）。"""

    __slots__ = (
        "t", "c", "requests", "prompt", "cached", "prefill_s", "decode_s",
        "drafted", "accepted", "running", "arrive", "rows",
        "epoch", "aborted", "finished_c",
    )

    def __init__(self, now, running, arrive, c, requests, prompt, cached,
                 prefill_s, decode_s, drafted, accepted, rows=None,
                 epoch=None, aborted=0, finished_c=None):
        self.t = now
        self.running = running      # 上次的在跑数
        self.arrive = arrive        # 上次的到达计数
        self.c = c
        self.requests = requests
        self.prompt = prompt
        self.cached = cached
        self.prefill_s = prefill_s
        self.decode_s = decode_s
        self.drafted = drafted
        self.accepted = accepted
        self.rows = rows           # 上次的外挂行（没有外挂时为 None）
        self.epoch = epoch         # 上次的引擎启动标记（vLLM 才有）
        self.aborted = aborted     # 上次的中途断开累计数（vLLM 才有）
        self.finished_c = finished_c  # 上次的“已结束请求的输出 token 累计”（vLLM 才有）


class Collector:
    """采集器：每读到一次 /health 调一次 feed，吐出一份快照。"""

    def __init__(self, config, usage=None):
        self.config = config
        self.usage = usage
        # 0. 沿用的输入
        self._metrics = None
        self._memory = None
        self._model = None
        self._context_max = DEFAULT_CONTEXT_MAX
        self._context_used = 0
        self._hook = "missing"
        self._engine = None        # 最近一次读数的 backend

        # 1. 读不到的处理
        self._fails = 0
        self._fail_start = None
        self._ever_ok = False
        self._last_snapshot = None
        # 2. 正在跑的状态
        self._prev = None            # 上次的读数
        self._busy = None            # 忙碌段
        self._decode = None          # 解码段
        self._round = None           # 本轮
        self._last = None            # 上一个结束的请求
        self._done_at = None         # 全部结束时刻
        self._prefill_start = None   # 预填充起点（没有外挂时用）
        self._stream = {}            # 2.7 的流表：id -> {"start": 开始时刻, "points": 进度点}
        self._arrive_at = None       # 最近到达时刻
        self._rows = None            # 这次的外挂行（外挂失效时为 None）
        self._stream_tps = {}        # 流表算出来的每条流的预填充速度
        self._ttft_pair = None       # 上一组 (ttft_sum, ttft_count)
        self._ttft_pending = 0       # 等着用精确值替换的首字数
        self._prefill_tps = DEFAULT_PREFILL_TPS
        # 一次 feed 里几个段落共用的中间量
        self._now = 0.0
        self._c = 0
        self._running = 0
        self._dec = 0
        self._pre = 0
        self._lanes_max = DEFAULT_LANES_MAX

    @property
    def prefill_tps(self) -> float:
        """当前的平均预填充速度（滚动更新，只读）。"""
        return self._prefill_tps

    # 入口

    def feed(self, now: float, health, metrics=None, memory=None, model=None) -> dict:
        """吃一次读数，吐出一份快照。"""
        self._now = now
        self._metrics = metrics if metrics is not None else self._metrics
        if memory is not None:
            self._memory = dict(memory)
        if model:
            self._model = model
        if health is None:
            snap = self._on_fail(now)
        else:
            snap = self._on_read(now, health)
        self._last_snapshot = snap
        return copy.deepcopy(snap)

    # 1. 读不到

    def _on_fail(self, now: float) -> dict:
        """读不到：头两次原样返回上一次的快照；第三次（或从来没成功过）进入离线。"""
        self._fails += 1
        if self._fail_start is None:
            self._fail_start = now
        if self._ever_ok and self._fails < 3:
            snap = copy.deepcopy(self._last_snapshot)
            snap["today"] = self._today()
            return snap
        self._clear_running()
        return self._offline_snapshot(now)

    def _clear_running(self) -> None:
        """清掉所有“正在跑”的状态。"""
        self._busy = None
        self._decode = None
        self._round = None
        self._prev = None
        self._done_at = None
        self._prefill_start = None
        self._stream = {}
        self._stream_tps = {}
        self._arrive_at = None

    def _offline_snapshot(self, now: float) -> dict:
        """离线快照：状态、离线秒数以外的东西沿用上一次。"""
        previous = self._last_snapshot or {}
        lanes = previous.get("lanes") or {}
        snap = self._blank_snapshot()
        snap["state"] = "offline"
        snap["hook"] = previous.get("hook", "missing")
        snap["lanes"] = {
            "max": lanes.get("max", DEFAULT_LANES_MAX),
            "decoding": 0,
            "prefilling": 0,
            "waiting": 0,
        }
        snap["decode"] = None
        snap["prefill"] = None
        snap["round"] = None
        snap["context_used"] = self._context_used
        snap["offline_s"] = now - self._fail_start
        return snap

    # 2. 读到了

    def _on_read(self, now: float, health: dict) -> dict:
        """一次成功读数：按 2.1 到 2.12 的顺序算完，最后拼快照。"""
        self._fails = 0
        self._fail_start = None
        self._ever_ok = True

        backend = health.get("backend")
        if isinstance(backend, str) and backend:
            self._engine = backend

        requests = int(_number(health, "requests_total"))
        c = int(_number(health, "completion_tokens_total"))
        prompt = int(_number(health, "prompt_tokens_total"))
        cached = int(_number(health, "cached_tokens_total"))
        prefill_s = _number(health, "prefill_seconds_total", 0.0)
        decode_s = _number(health, "decode_seconds_total", 0.0)
        drafted = int(_number(health, "drafted_total"))
        accepted = int(_number(health, "accepted_total"))
        running, dec, pre, lanes_max = self._streams(health)
        # vLLM 才有的三个可选键：取不到都当没有
        raw_epoch = health.get("epoch")
        epoch = raw_epoch if isinstance(raw_epoch, (int, float)) and not isinstance(raw_epoch, bool) else None
        aborted = int(_number(health, "aborted_total"))
        raw_finished = health.get("completion_finished_total")
        finished_c = (raw_finished if isinstance(raw_finished, (int, float)) and not isinstance(raw_finished, bool)
                      else None)

        # 2.1 记账：把这次的累计值交给账本（账本自己算增量）；抛的异常一律吃掉
        # vLLM 的读数把四项累计值放在 usage_totals 里；带引擎启动标记时一并交给账本
        if self.usage is not None:
            totals = health.get("usage_totals")
            if isinstance(totals, dict):
                for_usage = {key: totals.get(key) for key in ("prompt", "cached", "completion", "requests")}
            else:
                for_usage = {"prompt": prompt, "cached": cached, "completion": c, "requests": requests}
            if epoch is not None:
                for_usage["epoch"] = epoch
            try:
                self.usage.update(for_usage)
            except Exception:
                pass

        context_length = health.get("context_length")
        if isinstance(context_length, (int, float)) and not isinstance(context_length, bool) and context_length > 0:
            self._context_max = int(context_length)
        self._context_max = int(self._context_max)

        # 2.3 外挂：先定下这次有没有外挂行，后面几段都按它选算法
        self._hook = self._hook_of(health)
        self._rows = self._hook_rows(health)
        self._dec, self._pre, self._lanes_max = dec, pre, lanes_max

        prev = self._prev
        # 2.2 模型重启：累计值变小，或引擎换了个启动标记，这次当作没有上次
        restart = prev is not None and (requests < prev.requests or c < prev.c
                                        or (epoch is not None and prev.epoch is not None
                                            and epoch != prev.epoch))
        if restart:
            prev = None
            self._clear_running()
            self._ttft_pair = None
            self._ttft_pending = 0

        self._c = c
        self._running = running

        # 2.4 请求结束
        finished = 0
        if prev is not None:
            finished = requests - prev.requests
            if finished >= 1:
                self._on_finish(now, prev, finished, c, prompt, cached,
                               prefill_s, decode_s, drafted, accepted, running, finished_c)

        # 2.5 请求到达（模型重启那次连到达也不记：重启那次读数不产生新一轮）
        arrive = requests + int(_number(health, "requests_running")) + aborted
        if restart:
            arrived = 0
        elif prev is None:
            arrived = running
        else:
            arrived = max(0, arrive - prev.arrive)
        if arrived >= 1:
            self._arrive_at = now
            self._on_arrive(now, prev, finished, c)

        # 中途断开也算本轮的一次活动：本轮的最后活动时刻记成断开的这次
        if (not restart and prev is not None and aborted > prev.aborted
                and self._round is not None):
            self._round["end"] = now

        # 2.6 忙碌段
        self._busy_section(now, prev, finished, running, c)

        # 2.7 流表：只有外报告知了每条流才维护
        if running > 0:
            self._stream_table(now, self._rows)

        # 2.8 状态（含首个 token 时刻）
        state = self._state_of(now, dec, running)
        self._first_token(now, dec, c)

        # 2.9 解码段
        decode = self._decode_section(now, c, state)

        # 2.10 预填充段
        prefill = self._prefill_section(now, state, pre, running)

        # 2.11 首字的精确值
        self._ttft_exact()

        snap = self._build_snapshot(state, decode, prefill, running)
        self._prev = _Prev(now, running, arrive, c, requests, prompt, cached,
                          prefill_s, decode_s, drafted, accepted, self._rows,
                          epoch, aborted, finished_c)
        return snap

    @staticmethod
    def _hook_of(health: dict) -> str:
        """2.3：tfpanel 是字典、v 是 1、streams 是列表才算外挂好用。"""
        tfpanel = health.get("tfpanel")
        if isinstance(tfpanel, dict) and tfpanel.get("v") == 1 and isinstance(tfpanel.get("streams"), list):
            return "ok"
        return "missing"

    def _hook_rows(self, health: dict):
        """取这次的外挂行；外挂不好用（包括有 tfpanel 但 streams 不是列表）时为 None。"""
        if self._hook != "ok":
            return None
        return [row for row in health["tfpanel"]["streams"] if isinstance(row, dict)]

    @staticmethod
    def _rows_output(rows, phase="decode", ids=None):
        """外挂行里指定阶段那些行的 output 之和；没有外挂行时为 0。"""
        if not rows:
            return 0
        total = 0
        for row in rows:
            if row.get("phase") != phase:
                continue
            if ids is not None and row.get("id") not in ids:
                continue
            total += int(_number(row, "output", 0))
        return total

    @staticmethod
    def _streams(health: dict):
        """取在跑数、正在解码、正在预填充的流数和上限。

        没有 `streams` 时当作 decoding = requests_running、prefilling = 0、max = 1。
        """
        running = int(_number(health, "requests_running"))
        streams = health.get("streams")
        if isinstance(streams, dict):
            dec = int(_number(streams, "decoding"))
            pre = int(_number(streams, "prefilling"))
            maximum = int(_number(streams, "max", DEFAULT_LANES_MAX))
        else:
            dec, pre, maximum = running, 0, 1  # 没有 streams 时上限按 1 算
        return max(running, dec + pre), dec, pre, maximum

    def _on_finish(self, now, prev, finished, c, prompt, cached, prefill_s,
                   decode_s, drafted, accepted, running, finished_c=None) -> None:
        """2.4 请求结束：差值算成这个请求的成绩，并记进本轮。"""
        survivors = prev.running - finished
        busy = self._busy
        # 现存输出：这次还在解码的外挂行已输出的 token 之和
        existing = self._rows_output(self._rows)
        if prev.finished_c is not None and finished_c is not None:
            # vLLM 给了“已结束请求的输出 token 累计”：直接相减，不用估算
            completion = max(0, int(finished_c - prev.finished_c))
            if survivors > 0 and busy is not None:
                busy["used"] += completion
        elif survivors <= 0:
            # 之前在跑的全结束了：从忙碌起点的 C 减出精确值
            if busy is None:
                completion = 0
            else:
                completion = c - busy["start_c"] - busy["used"] - existing
        else:
            # 还有别的流在跑：只能估算，先拿上次的外挂行比出结束的几条
            now_ids = {row.get("id") for row in self._rows} if self._rows else set()
            gone = [row for row in (prev.rows or [])
                    if row.get("phase") == "decode" and row.get("id") not in now_ids]
            if len(gone) == finished:
                completion = self._rows_output(gone)
            else:
                completion = c - prev.c
            if busy is not None:
                busy["used"] += completion
        if completion < 0:
            completion = 0

        delta_prompt = prompt - prev.prompt
        delta_cached = cached - prev.cached
        delta_decode = decode_s - prev.decode_s
        delta_prefill = prefill_s - prev.prefill_s
        delta_draft = drafted - prev.drafted
        delta_accept = accepted - prev.accepted
        fresh = delta_prompt - delta_cached

        self._last = {
            "prompt_tokens": delta_prompt,
            "cached_tokens": delta_cached,
            "completion_tokens": completion,
            "decode_tps": (completion / delta_decode) if delta_decode > 0 else None,
            "prefill_tps": (fresh / delta_prefill) if (fresh > 0 and delta_prefill > 0) else None,
            "ttft_s": self._last_ttft(busy),
            "acceptance_rate": (delta_accept / delta_draft) if delta_draft > 0 else None,
            "context_used": delta_prompt + completion,
        }

        # 本轮：没有就先新开一轮，再把这个请求记进本轮
        rnd = self._round
        if rnd is None:
            rnd = self._new_round(now, c)
            self._round = rnd
        rnd["done"] += finished
        rnd["output"] += completion
        rnd["decode_sum"] += delta_decode
        rnd["end"] = now
        rnd["last_prompt"] = delta_prompt if finished == 1 else None

        # 平均预填充速度的滚动更新
        if finished == 1 and fresh >= 2048 and delta_prefill > 0:
            self._prefill_tps = 0.7 * self._prefill_tps + 0.3 * (fresh / delta_prefill)

        self._ttft_pending = finished
        if running == 0:
            self._done_at = now

    def _last_ttft(self, busy):
        """2.4 的 ttft_s：这一忙碌段只跑过一条流时，等于首个 token 时刻 − 忙碌起点时刻。"""
        if busy is None or busy["peak"] != 1 or busy["first"] is None:
            return None
        return busy["first"] - busy["start"]

    def _new_round(self, now: float, start_c: int) -> dict:
        """新开一轮。"""
        return {
            "start": now,
            "start_c": start_c,
            "done": 0,
            "output": 0,
            "decode_sum": 0.0,
            "decode_len": 0.0,
            "concurrent": False,
            "end": now,
            "last_prompt": None,
        }

    def _on_arrive(self, now, prev, finished, c) -> None:
        """2.5 请求到达：隔得太久的新请求算新一轮。"""
        rnd = self._round
        if rnd is None:
            self._round = self._new_round(now, c if prev is None else prev.c)
            return
        survivors = (prev.running - finished) if prev is not None else 0
        if survivors <= 0 and (now - rnd["end"]) > self.config.round_gap_s:
            self._round = self._new_round(now, c if prev is None else prev.c)

    def _busy_section(self, now, prev, finished, running, c) -> None:
        """2.6 忙碌段：在跑数从 0 变正算开始，回到 0 算结束。"""
        if running <= 0:
            self._busy = None
            self._decode = None
            self._stream = {}
            self._stream_tps = {}
            return
        fresh_start = prev is None or (prev.running - finished) <= 0
        if fresh_start:
            if finished >= 1:
                # 这一次读数里刚结束了请求：起点从这次的 C 减去还在跑的几条算
                start_c = c - self._rows_output(self._rows)
            elif prev is None:
                start_c = c
            else:
                start_c = prev.c
            self._busy = {"start": now, "start_c": start_c, "used": 0, "first": None, "peak": 0}
        busy = self._busy
        busy["peak"] = max(busy["peak"], running)
        if self._round is not None and running >= 2:
            self._round["concurrent"] = True

    def _stream_table(self, now: float, rows) -> None:
        """2.7 流表：按 id 记下每条流的开始时刻和预填充进度点，顺带算出每条流的预填充速度。

        没有外挂行（外挂失效或这次一条都没有）时清空，下次重新记。
        """
        if not rows:
            self._stream = {}
            self._stream_tps = {}
            return
        table = {}
        speeds = {}
        for row in rows:
            sid = row.get("id")
            if sid is None:
                continue
            entry = self._stream.get(sid)
            row_start = row.get("start")
            has_start = isinstance(row_start, (int, float)) and not isinstance(row_start, bool)
            if entry is None:                       # 新出现的 id
                # 行里有开始时刻就用它，否则按这次读到算
                start = float(row_start) if has_start else (now if self._arrive_at is None else self._arrive_at)
                points = []
                if row.get("phase") == "prefill":
                    points = [(now, _number(row, "filled", 0))]
            else:
                # 每次读数都按行里的开始时刻更新
                start = float(row_start) if has_start else entry["start"]
                points = list(entry["points"])
                if row.get("phase") == "prefill":
                    filled = _number(row, "filled", 0)
                    if points and filled > points[-1][1]:
                        points.append((now, filled))
                        del points[:-4]              # 只留最后 4 个
            table[sid] = {"start": start, "points": points}
            if len(points) >= 2 and points[-1][0] > points[0][0]:
                speeds[sid] = (points[-1][1] - points[0][1]) / (points[-1][0] - points[0][0])
        self._stream = table
        self._stream_tps = speeds

    def _state_of(self, now: float, dec: int, running: int) -> str:
        """2.8 状态。"""
        if dec > 0:
            return "decode"
        if running > 0:
            return "prefill"
        if self._done_at is not None and (now - self._done_at) < self.config.done_hold_s:
            return "done"
        return "idle"

    def _first_token(self, now: float, dec: int, c: int) -> None:
        """2.8 首个 token 时刻。"""
        busy = self._busy
        if busy is None or busy["first"] is not None:
            return
        if dec > 0 or (c - busy["start_c"] - busy["used"]) > 0:
            busy["first"] = now

    def _decode_section(self, now: float, c: int, state: str):
        """2.9 解码段：只有状态是 decode 时才有；离开解码状态就清掉，回来算新的一段。"""
        if state != "decode":
            self._decode = None
            return None
        busy = self._busy
        if self._decode is None:
            self._decode = {"start": now, "start_c": c, "samples": [(now, c)], "peak": 0.0}
        else:
            samples = self._decode["samples"]
            samples.append((now, c))
            cutoff = now - SMOOTH_WINDOW_S
            while samples and samples[0][0] < cutoff:
                del samples[0]
        decode = self._decode
        elapsed = now - decode["start"]
        if self._prev is not None and self._round is not None:
            self._round["decode_len"] += min(now - self._prev.t, 1.0)
        reference = None
        for point in decode["samples"]:
            if point[0] <= now - SMOOTH_LAG_S:
                reference = point
        if reference is None:
            reference = decode["samples"][0]
        tps = (c - reference[1]) / max(0.5, now - reference[0])
        if elapsed > 1.0:
            decode["peak"] = max(decode["peak"], tps)
        if elapsed >= 0.5:
            tps_avg = (c - decode["start_c"]) / elapsed
        else:
            tps_avg = None
        if busy is not None and busy["peak"] == 1 and busy["first"] is not None:
            ttft = busy["first"] - busy["start"]
        else:
            ttft = None
        # vLLM：只有一条流时，行里直接给了这条流的首字时间
        if (self._rows is not None and len(self._rows) == 1 and self._running == 1):
            value = self._rows[0].get("ttft_s")
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                ttft = value
        if self._hook == "ok":
            # 外挂好用：直接数解码中那几条已输出的 token
            output = self._rows_output(self._rows)
        elif busy is None:
            output = 0
        else:
            output = max(0, c - busy["start_c"] - busy["used"])
        return {
            "tps": tps,
            "tps_peak": decode["peak"],
            "tps_avg": tps_avg,
            "output_tokens": output,
            "ttft_s": ttft,
        }

    def _prefill_section(self, now: float, state: str, pre: int, running: int):
        """2.10 预填充段：外挂好用时从外挂行取，失效时只算得出秒数和占用比换算的提示数。"""
        if not (pre > 0 or state == "prefill"):
            self._prefill_start = None
            return None
        if self._hook == "ok":
            return self._prefill_from_hook(now)
        if self._prefill_start is None:
            self._prefill_start = now
        prompt_tokens = None
        if running > 0 and self._metrics is not None:
            usage = self._metrics.get("kv_usage") or []
            top = max(usage) if usage else 0
            if top > 0:
                prompt_tokens = js_round(top * self._context_max)
        return {
            "elapsed_s": now - self._prefill_start,
            "prompt_tokens": prompt_tokens,
            "cached_tokens": None,
            "filled_tokens": None,
            "tps": None,
            "remaining_s": None,
            "est_s": None,
            "cache_miss": False,
            "estimated": False,
        }

    def _prefill_from_hook(self, now: float) -> dict:
        """2.10：把这次还在预填充的那几条的外挂行加起来。"""
        rows = [row for row in self._rows if row.get("phase") == "prefill"]
        prompt = sum(int(_number(row, "prompt", 0)) for row in rows)
        cached = sum(int(_number(row, "cached", 0)) for row in rows)
        filled = sum(int(_number(row, "filled", 0)) for row in rows)
        starts = [self._stream[row["id"]]["start"] for row in rows if row.get("id") in self._stream]
        if starts:
            elapsed = now - min(starts)
        elif self._busy is not None:
            elapsed = now - self._busy["start"]
        else:
            elapsed = 0.0
        speeds = [self._stream_tps[row["id"]] for row in rows if self._stream_tps.get(row.get("id")) is not None]
        tps = sum(speeds) if speeds else None
        est = (prompt - cached) / self._prefill_tps
        if rows and any("filled" not in row for row in rows):
            # vLLM 的行里没有 filled：只能按平均速度估已算到的位置，进度最高按 99%
            frac = 0.99 if est <= 0 else min(0.99, elapsed / est)
            return {
                "elapsed_s": elapsed,
                "prompt_tokens": prompt,
                "cached_tokens": cached,
                "filled_tokens": cached + js_round((prompt - cached) * frac),
                "tps": self._prefill_tps,
                "remaining_s": max(0.0, est - elapsed),
                "est_s": est,
                "cache_miss": self._cache_miss(rows, prompt, cached),
                "estimated": True,
            }
        if tps is not None and tps > 0:
            remaining = (prompt - filled) / tps
        else:
            remaining = max(0.0, est - elapsed)
        return {
            "elapsed_s": elapsed,
            "prompt_tokens": prompt,
            "cached_tokens": cached,
            "filled_tokens": filled,
            "tps": tps,
            "remaining_s": remaining,
            "est_s": est,
            "cache_miss": self._cache_miss(rows, prompt, cached),
            "estimated": False,
        }

    def _cache_miss(self, rows, prompt: int, cached: int) -> bool:
        """2.10：这一轮上一个请求新算的 token 多、这次几乎没复用才算缓存未命中。"""
        rnd = self._round
        if rnd is None or rnd["concurrent"] or rnd["done"] < 1:
            return False
        before = rnd["last_prompt"]
        if before is None or before < 4000:
            return False
        return (prompt >= before * 0.5 and cached < before * 0.5
                and (prompt - cached) >= 4000)

    def _ttft_exact(self) -> None:
        """2.11：读到了首字直方图就用精确值盖掉估算值。"""
        metrics = self._metrics
        if metrics is None:
            return
        count = metrics.get("ttft_count")
        total = metrics.get("ttft_sum")
        if count is None or total is None:
            return
        pair = self._ttft_pair
        if pair is not None and count > pair[1] and self._ttft_pending >= 1 and self._last is not None:
            self._last["ttft_s"] = (total - pair[0]) / (count - pair[1])
            self._ttft_pending = 0
        self._ttft_pair = (total, count)

    def _round_view(self, now: float):
        """2.12 的本轮。"""
        rnd = self._round
        if rnd is None:
            return None
        if self._running > 0:
            elapsed = now - rnd["start"]
        else:
            elapsed = rnd["end"] - rnd["start"]
        if rnd["concurrent"]:
            if rnd["decode_len"] > 0.5:
                avg = (self._c - rnd["start_c"]) / rnd["decode_len"]
            else:
                avg = None
        elif rnd["decode_sum"] > 0:
            avg = rnd["output"] / rnd["decode_sum"]
        else:
            avg = None
        gap = self.config.round_gap_s
        return {
            "requests": rnd["done"],
            "running": self._running,
            "output_tokens": self._c - rnd["start_c"],
            "decode_tps_avg": avg,
            "exact": not rnd["concurrent"],
            "elapsed_s": elapsed,
            "active": self._running > 0 or (now - rnd["end"]) <= (gap + 1e-9),
        }

    def _context_used_of(self, running: int):
        """2.12 的上下文占用：外挂好用时取占用最大的那条流，失效时用占用比换算。"""
        if running > 0:
            used = self._slot_used(self._rows)
            if used is not None:
                return used
            metrics = self._metrics
            if metrics is not None:
                usage = metrics.get("kv_usage") or []
                top = max(usage) if usage else 0
                if top > 0:
                    return js_round(top * self._context_max)
            return self._context_used
        if self._last is not None:
            return self._last["context_used"]
        return 0

    @staticmethod
    def _slot_used(rows):
        """每条外挂行的 提示 + 已输出（预填充行只算提示），取最大的；一行都没有时 None。"""
        values = []
        for row in rows or []:
            prompt = _number(row, "prompt", 0)
            output = _number(row, "output", 0) if row.get("phase") == "decode" else 0
            if prompt or output:
                values.append(prompt + output)
        return max(values) if values else None

    def _today(self) -> dict:
        """2.12 的今日用量：账本给的东西一律照抄，抛异常就当没有。"""
        if self.usage is None:
            return dict(NO_TODAY)
        try:
            return dict(self.usage.today())
        except Exception:  # 账本坏掉不能连累画面
            return dict(NO_TODAY)

    def _blank_snapshot(self) -> dict:
        """快照骨架：顶层键和顺序照 docs/design.md 的示例。"""
        return {
            "version": 2,
            "state": "idle",
            "hook": self._hook,
            "engine": self._engine,
            "model": self._model if self._model else self.config.model_name,
            "context_max": self._context_max,
            "lanes": {"max": self._lanes_max, "decoding": self._dec, "prefilling": self._pre, "waiting": 0},
            "decode": None,
            "prefill": None,
            "context_used": self._context_used,
            "last": copy.deepcopy(self._last),
            "round": None,
            "today": self._today(),
            "memory": dict(self._memory) if self._memory is not None else dict(NO_MEMORY),
            "offline_s": None,
        }

    def _build_snapshot(self, state: str, decode, prefill, running: int) -> dict:
        """2.12：把各段算出来的东西拼成快照。"""
        snap = self._blank_snapshot()
        snap["state"] = state
        snap["decode"] = decode
        snap["prefill"] = prefill
        waiting = 0
        if running > 0 and self._metrics is not None:
            value = self._metrics.get("waiting")
            if isinstance(value, int) and not isinstance(value, bool) and value > 0:
                waiting = value
        snap["lanes"] = {
            "max": self._lanes_max,
            "decoding": self._dec,
            "prefilling": self._pre,
            "waiting": waiting,
        }
        snap["context_used"] = self._context_used_of(running)
        self._context_used = snap["context_used"]
        snap["round"] = self._round_view(self._now)
        return snap
