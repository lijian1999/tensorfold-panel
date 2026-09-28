#!/usr/bin/env python3
"""tfpanel：给 TensorFold 外挂副屏指标采集的启动器（只用标准库）。

`tfpanel <参数…>` 等价于 `tensorfold <参数…>`，额外做三件事：
1. 用 sys.meta_path 钩子在 tensorfold.server.app 被 TensorFold 自己导入、
   执行完之后再打补丁（不能提前 import，见 cli 里 MLX 环境变量的设置顺序）；
2. 在 127.0.0.1:8081（可用 TFPANEL_METRICS_PORT 改）提供只读的 /metrics；
3. 启动 TensorFold 本身（tensorfold.cli.main），参数原样传递。

外挂的任何环节出错都只打印/记录，绝不影响 TensorFold 启动和请求。
"""
from __future__ import annotations

import functools
import importlib.util
import inspect
import json
import math
import os
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# /metrics 只监听本机地址
METRICS_HOST = "127.0.0.1"
METRICS_DEFAULT_PORT = 8081
# tensorfold 设置好 MLX 环境变量之后才会 import 的模块名
APP_MODULE = "tensorfold.server.app"
# “一轮”统计：距上次活动结束超过该间隔（秒）就另起一轮
ROUND_GAP_DEFAULT_S = 60.0
# 记住本线程正在 chat() 里的请求记录，供 render 包装定位当前请求
_TLS = threading.local()


# ---------------------------------------------------------------- 增量文字


def _delta_text(delta):
    """把一个 on_delta 增量（str / dict）里的文字抽出来；抽不到就返回空串。"""
    if isinstance(delta, str):
        return delta
    if isinstance(delta, dict):
        parts = []

        def walk(v):
            if isinstance(v, str):
                parts.append(v)
            elif isinstance(v, dict):
                for x in v.values():
                    walk(x)
            elif isinstance(v, (list, tuple)):
                for x in v:
                    walk(x)

        walk(delta)
        return "".join(parts)
    return ""


# ---------------------------------------------------------------- 请求记录


class _Request:
    """一次进行中的 chat() 请求。"""

    __slots__ = ("start_time", "streaming", "deltas", "consumed",
                 "total_tokens", "events", "first_delta_time", "peak",
                 "prompt_tokens", "job", "job_seen", "first_token_time")

    def __init__(self, start_time, streaming):
        self.start_time = start_time      # clock 时间
        self.streaming = streaming        # 请求带了 on_delta 回调
        self.prompt_tokens = None         # 提示 token 数（render 返回长度；没拿到则 None）
        self.deltas = []                  # [(时间, 文字)]，按到达顺序
        self.consumed = 0                 # deltas 里已参与换算的条数（换算后截掉归零）
        self.total_tokens = 0.0           # 累计 token 数（首字之后全部，O(1) 维护）
        self.events = deque()             # 窗口内的 token 事件 [(时间, 数量)]，数量可为小数
        self.first_delta_time = None      # 第一个增量到达的时间
        self.peak = 0.0                   # 解码 1 秒后的峰值速度
        self.job = None                   # 最近一次 attach 的调度器 job
        self.job_seen = 0                 # 已经计入的引擎 token 数
        self.first_token_time = None      # 换算线程第一次看到引擎 token 数 > 0 的时刻


def _new_round(started):
    """新一轮数据：started 为本轮开始时刻（clock），各项计数清零。"""
    return {"started": started, "requests": 0, "output_tokens": 0,
            "avg_tokens": 0.0, "decode_secs": 0.0}


# ---------------------------------------------------------------- 采集器


class Collector:
    """挂在 chat() 外面的指标采集器。构造参数可注入，方便测试。"""

    def __init__(self, clock=time.perf_counter, done_hold_s=4.0,
                 window_s=2.5, tick_s=0.1, start_worker=True,
                 round_gap_s=60.0):
        self.clock = clock
        self.done_hold_s = done_hold_s    # “完成”状态保持多久
        self.window_s = window_s          # 实时速度统计窗口
        self.tick_s = tick_s              # 换算线程周期
        self.round_gap_s = round_gap_s    # “一轮”的间隔阈值（秒）
        self._requests = {}               # id(req) -> _Request
        self._lock = threading.Lock()     # 保护 _requests / last / totals / 一轮数据
        self.last = None                  # 最近一次成功完成的成绩
        self.last_done_time = None        # 完成时刻（clock）
        self.last_activity = None         # 最近一次活动结束时刻（finish/fail，clock）
        self._round = None                # 本轮数据；None = 还没有请求 begin 过
        self.totals = {"requests": 0, "peak_tps": 0.0}
        # 引擎实例信息（拿到 ChatApp 实例后填充）
        self.engine_ready = False
        self.model_name = None
        self.context_window = 0
        self.tensorfold_version = None
        self.hooks = {"chat": "missing"}
        self._tokenizer = None
        self._tokenizer_lock = None
        self._wall_start = time.time()    # 真实墙钟，uptime 用
        if start_worker:
            threading.Thread(target=self._loop, name="tfpanel-collector",
                             daemon=True).start()

    # ---------------- 实例信息 ----------------

    def register_instance(self, app):
        """记下 ChatApp 实例（构造完成或处理过请求都算引擎就绪）。"""
        self.engine_ready = True
        name = getattr(app, "served_name", None)
        if isinstance(name, str) and name:
            self.model_name = name
        cw = getattr(app, "context_window", 0)
        if isinstance(cw, (int, float)) and not isinstance(cw, bool):
            self.context_window = int(cw)
        tokenizer = getattr(app, "tokenizer", None)
        if tokenizer is not None:
            self._tokenizer = tokenizer
            self._tokenizer_lock = getattr(app, "tokenizer_lock", None)

    # ---------------- 请求生命周期 ----------------

    def begin(self, streaming=True):
        """请求开始，返回请求记录。"""
        req = _Request(self.clock(), streaming)
        with self._lock:
            # 在把新请求加入 _requests 之前判断：
            # 当前没有进行中的请求，且距上次活动结束超过阈值 → 开始新的一轮
            if not self._requests and (self.last_activity is None
                                       or req.start_time - self.last_activity
                                       > self.round_gap_s):
                self._round = None
            if self._round is None:
                self._round = _new_round(req.start_time)
            self._requests[id(req)] = req
        return req

    def delta(self, req, delta):
        """增量到达：只追加 (时间, 文字) 到列表，O(1)，不分词。"""
        text = _delta_text(delta)
        if not text:
            return
        now = self.clock()
        with self._lock:
            req.deltas.append((now, text))
            if req.first_delta_time is None:
                req.first_delta_time = now

    def attach_job(self, req, job):
        """记下本请求的调度器 job（供换算线程直接数引擎生成的 token）。

        抢占重跑时会用新 job 再 attach：不重置 job_seen——新 job 会把
        已数过的 token 重新生成一遍，只有超过 job_seen 的部分才是新的。
        """
        with self._lock:
            req.job = job

    def set_prompt_tokens(self, req, n):
        """提示 token 数：一个请求只记第一次（render 可能被调用多次）。"""
        with self._lock:
            if req.prompt_tokens is None:
                req.prompt_tokens = n

    def fail(self, req):
        """请求抛异常：直接丢弃，不更新 last、不进入 done，只刷新 last_activity。"""
        now = self.clock()
        with self._lock:
            self._requests.pop(id(req), None)
            self.last_activity = now

    def finish(self, req, reply=None):
        """请求正常结束：用成绩单生成 last，并更新本轮统计。"""
        now = self.clock()
        with self._lock:
            self._requests.pop(id(req), None)
        last = self._last_from_reply(reply)
        with self._lock:
            self.last = last
            self.last_done_time = now
            self.totals["requests"] += 1
            self.totals["peak_tps"] = max(self.totals["peak_tps"], req.peak)
            self.last_activity = now
            if self._round is not None:
                self._accumulate_round(reply)

    def _accumulate_round(self, reply):
        """按成绩单更新本轮统计（调用方必须持 self._lock）。"""
        reply = reply if isinstance(reply, dict) else {}
        runtime = self._sub(reply, "runtime") or {}
        completion = self._int_or_none(reply.get("completion_tokens"))
        tps = self._num_or_none(runtime.get("tokens_per_second"))
        self._round["requests"] += 1
        if completion is not None:
            self._round["output_tokens"] += completion
        if (completion is not None and tps is not None
                and completion > 0 and tps > 0):
            self._round["avg_tokens"] += completion
            self._round["decode_secs"] += completion / tps

    # ---------------- 换算线程 ----------------

    def _loop(self):
        while True:
            try:
                self.tick()
            except Exception as exc:  # 采集出错不能杀死线程
                print(f"[tfpanel] 警告：换算线程出错：{exc}", file=sys.stderr)
            time.sleep(self.tick_s)

    def tick(self, now=None):
        """把上次之后新到的增量文字换算成 token 事件。测试可直接调用。"""
        if now is None:
            now = self.clock()
        for req in self._active_list():
            try:
                self._convert(req, now)
            except Exception:
                pass  # 单条请求换算出错不影响其他请求

    def _active_list(self):
        with self._lock:
            return list(self._requests.values())

    def current_request(self):
        """当前请求 = 进行中里最后开始的那个；没有则 None。"""
        active = self._active_list()
        if not active:
            return None
        return max(active, key=lambda r: r.start_time)

    def _convert(self, req, now):
        """对 req 做一次 token 换算。

        引擎计数模式（attach 过 job）：直接读引擎 job.stream.emitted 的
        数量，不调分词器，丢弃积压的文字增量。读取出异常时当作本次没有
        新 token（不退回文字换算，下次 tick 再读）。

        文字换算模式（job 为 None）：先切片、换算完再在锁里截掉已消费
        前缀（而不是把 consumed 记成当前总长）：切片之后、换算期间
        on_delta 线程追加的增量留在列表尾部，下一次 tick 照常换算，
        不会丢。
        """
        if req.job is not None:
            try:
                stream = req.job.stream
                n = 0 if stream is None else len(stream.emitted)
            except Exception:
                n = None  # 读失败：本次没有新 token，不调分词器
            if n is not None:
                new = n - req.job_seen
                if new > 0:
                    self._add_event(req, now, new, now)
                    with self._lock:
                        req.job_seen = n
                        if req.first_token_time is None:
                            req.first_token_time = now
                with self._lock:
                    del req.deltas[:len(req.deltas)]  # 丢弃积压的文字
                    req.consumed = 0
        else:
            with self._lock:
                new = req.deltas[req.consumed:]
            if new:
                text = "".join(seg for _, seg in new)
                if text:
                    n = self._count_tokens(text)
                    if n:
                        for t, seg in new:
                            if seg:
                                self._add_event(req, t, n * len(seg) / len(text), now)
                with self._lock:
                    del req.deltas[:len(new)]  # 只截已换算前缀，保留换算期间新追加的增量
                    req.consumed = 0
        start = self._decode_start(req)
        if start is not None:
            if now - start >= 1.0:
                req.peak = max(req.peak, self._decode_tps(req, now))

    def _add_event(self, req, t, n, now):
        """追加 token 事件，顺带丢弃窗口外旧事件；摊销 O(1)。"""
        with self._lock:
            req.total_tokens += n
            events = req.events
            cutoff = now - self.window_s
            while events and events[0][0] <= cutoff:
                events.popleft()
            events.append((t, n))

    def _count_tokens(self, text):
        """token 数：用模型自己的分词器；没有则按每 4 字符 1 token 估算。"""
        tokenizer = self._tokenizer
        if tokenizer is None:
            return len(text) / 4.0
        lock = self._tokenizer_lock
        if lock is not None:
            with lock:  # 持锁只包住 encode 这一句
                return self._encode_len(tokenizer, text)
        return self._encode_len(tokenizer, text)

    @staticmethod
    def _encode_len(tokenizer, text):
        try:
            return len(tokenizer.encode(text, add_special_tokens=False))
        except TypeError:
            # 旧版 tokenizer 不认识这个参数
            return len(tokenizer.encode(text))

    # ---------------- 指标计算 ----------------

    def state(self, now=None):
        if now is None:
            now = self.clock()
        req = self.current_request()
        if req is not None:
            return "decode" if self._decode_start(req) is not None else "prefill"
        with self._lock:
            last_done = self.last_done_time
        if last_done is not None and now - last_done < self.done_hold_s:
            return "done"
        return "idle"

    def _decode_start(self, req):
        """解码开始时刻：first_delta_time 和 first_token_time 里非 None 的最小值。"""
        with self._lock:
            first_delta = req.first_delta_time
            first_token = req.first_token_time
        times = [t for t in (first_delta, first_token) if t is not None]
        return min(times) if times else None

    def _decode_tps(self, req, now):
        """最近 window_s 秒的平均速度；分母下限 0.5 秒。"""
        start = self._decode_start(req)
        if start is None:
            return 0.0
        elapsed = now - start
        cutoff = now - self.window_s
        # 换算线程会同时 append/popleft，必须在锁内遍历
        with self._lock:
            tokens = sum(c for t, c in req.events if t > cutoff)
        return tokens / max(0.5, min(self.window_s, elapsed))

    def _decode_avg(self, req, now):
        """解码进行满 0.5 秒 = 首字之后的 token 数 ÷ 首字之后的秒数；否则 None。"""
        start = self._decode_start(req)
        if start is None:
            return None
        elapsed = now - start
        if elapsed < 0.5:
            return None
        with self._lock:
            tokens = req.total_tokens  # 换算线程会同时累加，在锁内读
        return tokens / elapsed

    # ---------------- /metrics 输出 ----------------

    def snapshot(self, now=None):
        """生成 /metrics 的 JSON。输出里绝不含对话文字。"""
        if now is None:
            now = self.clock()
        req = self.current_request()
        if req is None:
            current = None
        else:
            start = self._decode_start(req)
            if start is None:
                # 预填充：还在等首字
                ttft = None
                tps = 0.0
                avg = None
                peak = 0.0
            else:
                ttft = start - req.start_time
                tps = self._decode_tps(req, now)
                if now - start >= 1.0:
                    req.peak = max(req.peak, tps)
                peak = req.peak
                avg = self._decode_avg(req, now)
            with self._lock:
                output_tokens = req.total_tokens  # 换算线程会同时累加，在锁内读
                prompt_tokens = req.prompt_tokens  # 换算线程可能同时写，在锁内读
            current = {
                "elapsed_s": round(now - req.start_time, 3),
                "ttft_s": None if ttft is None else round(ttft, 3),
                "prompt_tokens": prompt_tokens,
                "output_tokens": int(round(output_tokens)),
                "decode_tps": round(tps, 3),
                "decode_tps_peak": round(peak, 3),
                "decode_tps_avg": None if avg is None else round(avg, 3),
            }
        with self._lock:
            last = self.last
            requests_n = self.totals["requests"]
            total_peak = self.totals["peak_tps"]
            round_data = None if self._round is None else dict(self._round)
            last_activity = self.last_activity
            in_progress = bool(self._requests)
        cw = self.context_window
        round_out = None
        if round_data is not None:
            if in_progress:
                elapsed = now - round_data["started"]
            elif last_activity is not None:
                elapsed = last_activity - round_data["started"]
            else:
                elapsed = 0.0
            if round_data["decode_secs"] > 0:
                avg = round(round_data["avg_tokens"] / round_data["decode_secs"], 3)
            else:
                avg = None
            round_out = {
                "requests": round_data["requests"],
                "output_tokens": round_data["output_tokens"],
                "decode_tps_avg": avg,
                "elapsed_s": round(max(0.0, elapsed), 3),
                "active": in_progress or (last_activity is not None
                                          and now - last_activity
                                          <= self.round_gap_s),
            }
        return {
            "version": 1,
            "state": self.state(now),
            "engine_ready": self.engine_ready,
            "model": self.model_name,
            "tensorfold_version": self.tensorfold_version,
            "context_max": None if not cw else int(cw),
            "hooks": dict(self.hooks),
            "current": current,
            "last": last,
            "totals": {
                "requests": requests_n,
                "peak_tps": round(total_peak, 3),
                "uptime_s": int(time.time() - self._wall_start),
            },
            "round": round_out,
        }

    # ---------------- 成绩单 -> last ----------------

    @staticmethod
    def _int_or_none(v):
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return int(round(v))
        return None

    @staticmethod
    def _num_or_none(v):
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return round(float(v), 3)
        return None

    @staticmethod
    def _sub(reply, key):
        v = reply.get(key) if isinstance(reply, dict) else None
        return v if isinstance(v, dict) else None

    def _last_from_reply(self, reply):
        """字段缺哪个，输出就是 null，其他照常。"""
        reply = reply if isinstance(reply, dict) else {}
        runtime = self._sub(reply, "runtime")
        speculative = self._sub(reply, "speculative")
        prompt = reply.get("prompt_tokens")
        completion = reply.get("completion_tokens")
        prompt_n = self._int_or_none(prompt)
        completion_n = self._int_or_none(completion)
        context_used = (prompt_n + completion_n) if (prompt_n is not None
                                                     and completion_n is not None) else None
        return {
            "prompt_tokens": prompt_n,
            "cached_tokens": self._int_or_none(reply.get("cached_tokens")),
            "completion_tokens": completion_n,
            "decode_tps": self._num_or_none((runtime or {}).get("tokens_per_second")),
            "ttft_s": self._num_or_none((runtime or {}).get("time_to_first_token")),
            "acceptance_rate": self._num_or_none((speculative or {}).get("acceptance_rate")),
            "context_used": context_used,
            "finish_reason": reply.get("finish_reason"),
        }


# ---------------------------------------------------------------- 打补丁


def _collect_safe(fn, *args):
    """调用采集器方法并吞掉一切异常：外挂不能影响请求。"""
    try:
        fn(*args)
    except Exception:
        pass


def patch_chat_app(module, collector, hooks):
    """启动自检 + 打补丁。通过返回 True（hooks.chat 置为 "ok"）；不通过返回 False。"""
    app_class = getattr(module, "ChatApp", None)
    chat = getattr(app_class, "chat", None) if app_class is not None else None
    if not callable(chat):
        return False
    try:
        params = inspect.signature(chat).parameters
    except (TypeError, ValueError):
        return False
    if "on_delta" not in params:
        return False

    # on_delta 若允许位置传入，记下它的位置下标（不含 self；关键字专用参数则没有）
    on_delta_pos = None
    params_iter = iter(params.values())
    try:
        next(params_iter)  # self
    except StopIteration:
        pass
    pos = 0
    for p in params_iter:
        if p.kind in (inspect.Parameter.POSITIONAL_ONLY,
                      inspect.Parameter.POSITIONAL_OR_KEYWORD):
            if p.name == "on_delta":
                on_delta_pos = pos
            pos += 1
        else:
            break

    original = chat

    @functools.wraps(original)
    def wrapped(self, *args, **kwargs):
        # 尽力记下引擎实例（拿模型名、上下文上限）；失败就算了
        _collect_safe(collector.register_instance, self)
        req_holder = {}
        on_delta = kwargs.get("on_delta")
        # 极端情况：on_delta 以位置参数传入——不改 args，只做开始/结束记录
        if on_delta is None and args and on_delta_pos is not None \
                and on_delta_pos < len(args):
            on_delta = args[on_delta_pos]
        # on_delta 以关键字传入时换成“原样转发 + 交采集器”的新回调
        if on_delta is not None and "on_delta" in kwargs:

            def forward(delta):
                ret = on_delta(delta)  # 原样调用、原样返回、异常原样抛出
                if req_holder.get("req") is not None:
                    _collect_safe(collector.delta, req_holder["req"], delta)
                return ret

            kwargs["on_delta"] = forward
        req = None
        try:
            req = collector.begin(streaming=on_delta is not None)
        except Exception:
            req = None
        if req is not None:
            req_holder["req"] = req
        # 让同线程里的 render 包装能定位本请求；结束后恢复原值
        prev_tls_req = getattr(_TLS, "req", None)
        _TLS.req = req
        try:
            try:
                reply = original(self, *args, **kwargs)
            except BaseException:
                if req is not None:
                    _collect_safe(collector.fail, req)
                raise  # 原样抛出
            if req is not None:
                _collect_safe(collector.finish, req, reply)
            return reply  # 同一个对象，不复制、不修改
        finally:
            _TLS.req = prev_tls_req

    app_class.chat = wrapped

    # 尽力包装 render：chat 一开头会调用它渲染提示，返回值第 0 项就是完整提示
    # token 列表；只读长度，任何异常都吞掉，绝不影响 render 本身
    try:
        render = getattr(app_class, "render", None)
        if not callable(render):
            hooks["render"] = "missing"
        else:
            original_render = render

            @functools.wraps(original_render)
            def wrapped_render(self, *args, **kwargs):
                result = original_render(self, *args, **kwargs)  # 异常原样抛出
                try:
                    req = getattr(_TLS, "req", None)
                    if req is not None and isinstance(result, tuple) \
                            and len(result) >= 1:
                        # result[0] 支持 len() 时才记；不支持则 TypeError 被吞掉
                        collector.set_prompt_tokens(req, len(result[0]))
                except Exception:
                    pass  # 外挂不能影响 render 的返回值和调用方
                return result  # 同一个对象，不复制、不修改

            app_class.render = wrapped_render
            hooks["render"] = "ok"
    except Exception:
        hooks["render"] = "missing"

    # 尽力包装 Scheduler.submit：chat 在请求线程里同步 submit 任务时，把
    # job attach 到当前请求，换算线程就能直接数引擎生成的 token
    try:
        scheduler_cls = getattr(module, "Scheduler", None)
        submit = (getattr(scheduler_cls, "submit", None)
                  if scheduler_cls is not None else None)
        if not callable(submit):
            hooks["tokens"] = "missing"
        else:
            original_submit = submit

            @functools.wraps(original_submit)
            def wrapped_submit(self, *args, **kwargs):
                try:
                    req = getattr(_TLS, "req", None)
                    job = args[0] if args else kwargs.get("job")
                    if req is not None and job is not None:
                        collector.attach_job(req, job)
                except Exception:
                    pass  # 外挂不能影响 submit 的调用
                return original_submit(self, *args, **kwargs)  # 参数/返回值/异常原样

            scheduler_cls.submit = wrapped_submit
            hooks["tokens"] = "ok"
    except Exception:
        hooks["tokens"] = "missing"

    # 尽力包装 __init__：构造完成就记下实例；失败就退回在第一次 chat() 时再记
    try:
        init = getattr(app_class, "__init__", None)
        if callable(init) and init is not object.__init__:
            original_init = init

            @functools.wraps(original_init)
            def wrapped_init(self, *args, **kwargs):
                ret = original_init(self, *args, **kwargs)  # 异常必须原样抛出
                _collect_safe(collector.register_instance, self)
                return ret

            app_class.__init__ = wrapped_init
    except Exception:
        pass

    hooks["chat"] = "ok"
    return True


def run_self_check(module, collector, hooks, version=None, force_fail=False):
    """导入钩子的回调：自检不通过（或被强制）时打印提示，不打补丁。"""
    if force_fail or not patch_chat_app(module, collector, hooks):
        hooks["chat"] = "missing"
        hooks["render"] = "missing"
        hooks["tokens"] = "missing"
        print(f"[tfpanel] 指标未挂载：TensorFold {version or '未知版本'} 的 ChatApp.chat "
              f"已变化，副屏将显示“指标不可用”", file=sys.stderr)
        return False
    return True


# ---------------------------------------------------------------- 导入钩子


class _HookedLoader:
    """代理真实 loader：模块执行完之后追加运行回调。"""

    def __init__(self, loader, callback):
        self._loader = loader
        self._callback = callback

    def exec_module(self, module):
        self._loader.exec_module(module)
        try:
            self._callback(module)
        except Exception as exc:  # 钩子出错绝不影响 import
            print(f"[tfpanel] 警告：打补丁失败：{exc}", file=sys.stderr)

    def __getattr__(self, name):
        return getattr(self._loader, name)


class _ExecHookFinder:
    """sys.meta_path 查找器：在 tensorfold.server.app 执行完之后打补丁。"""

    def __init__(self, fullname, callback):
        self._fullname = fullname
        self._callback = callback
        self._done = False

    def find_spec(self, fullname, path=None, target=None):
        if self._done or fullname != self._fullname:
            return None
        self._done = True
        # 请其余查找器找出真实的 spec，我们不改变模块的来源
        real = None
        for finder in sys.meta_path:
            if finder is self:
                continue
            try:
                real = finder.find_spec(fullname, path, target)
            except Exception:
                real = None
            if real is not None:
                break
        if real is None or real.loader is None:
            return None
        real.loader = _HookedLoader(real.loader, self._callback)
        return real


def install_hook(callback):
    """安装导入钩子：tensorfold.server.app 执行完后运行 callback(module)。

    模块若已经被导入过就直接运行回调。返回查找器（未安装时 None）。
    """
    if APP_MODULE in sys.modules:
        try:
            callback(sys.modules[APP_MODULE])
        except Exception as exc:  # 钩子出错绝不影响进程
            print(f"[tfpanel] 警告：打补丁失败：{exc}", file=sys.stderr)
        return None
    finder = _ExecHookFinder(APP_MODULE, callback)
    sys.meta_path.insert(0, finder)
    return finder


# ---------------------------------------------------------------- /metrics


def make_metrics_server(port, collector):
    """在 127.0.0.1:port 上启动 /metrics（守护线程），返回 server。"""

    class Handler(BaseHTTPRequestHandler):
        # HTTP/1.1：客户端可复用连接（keep-alive），避免每个请求重建 TCP。
        # 注意：HTTP/1.1 下每个响应都必须带 Content-Length，否则客户端会挂住。
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):  # 不记访问日志
            pass

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path != "/metrics":
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            try:
                data = collector.snapshot()
            except Exception:
                # 快照出错：返回 500 空 body，副屏把它当作一次读取失败，
                # 不能冒充一份“指标不可用”的数据
                self.send_response(500)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer((METRICS_HOST, port), Handler)
    threading.Thread(target=server.serve_forever, name="tfpanel-metrics",
                     daemon=True).start()
    return server


# ---------------------------------------------------------------- 启动器


def _tensorfold_version():
    try:
        import tensorfold
        v = getattr(tensorfold, "__version__", None)
        return v if isinstance(v, str) else None
    except Exception:
        return None


def decide_initial_hook_state(module_name=APP_MODULE):
    """加载期间自检还没运行：找到模块 → "pending"；找不到 → "missing"。"""
    try:
        spec = importlib.util.find_spec(module_name)
    except Exception:
        spec = None
    return "pending" if spec is not None else "missing"


def round_gap_from_env(environ):
    """TFPANEL_ROUND_GAP_S（浮点秒数）；没设、解析失败、不是正数时用 60.0。"""
    raw = environ.get("TFPANEL_ROUND_GAP_S")
    if raw is None:
        return ROUND_GAP_DEFAULT_S
    try:
        value = float(raw)
    except ValueError:
        return ROUND_GAP_DEFAULT_S
    return value if math.isfinite(value) and value > 0 else ROUND_GAP_DEFAULT_S


def main(argv):
    collector = Collector(round_gap_s=round_gap_from_env(os.environ))
    # 记录启动时间（uptime_s）、启动换算线程
    collector.tensorfold_version = _tensorfold_version()
    force_fail = os.environ.get("TFPANEL_FORCE_HOOK_FAIL") == "1"
    state = decide_initial_hook_state()
    hooks = {"chat": state, "render": state, "tokens": state}
    collector.hooks = hooks

    def on_app_module(module):
        run_self_check(module, collector, hooks,
                       version=collector.tensorfold_version, force_fail=force_fail)

    # 找到模块才装导入钩子（加载期间显示 pending）；找不到直接 missing
    if state == "pending":
        install_hook(on_app_module)

    # /metrics 服务：端口被占用等错误只打印，不能影响 TensorFold 启动
    try:
        port = int(os.environ.get("TFPANEL_METRICS_PORT", str(METRICS_DEFAULT_PORT)))
    except ValueError:
        port = METRICS_DEFAULT_PORT
    try:
        make_metrics_server(port, collector)
    except Exception as exc:
        print(f"[tfpanel] 警告：端口 {port} 被占用或不可用，/metrics 已禁用（{exc}）",
              file=sys.stderr)

    # 照常启动 TensorFold
    try:
        from tensorfold.cli import main as tf_main
    except Exception as exc:
        print(f"[tfpanel] 错误：无法导入 tensorfold.cli：{exc}", file=sys.stderr)
        return 1
    try:
        code = tf_main(list(argv))
    except SystemExit as exc:
        code = exc.code
    if code is None:
        code = 0
    if isinstance(code, int):
        return code
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
