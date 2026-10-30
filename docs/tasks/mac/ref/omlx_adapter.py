"""oMLX 适配器的参考实现（编排者写，任务 O1 照它翻译成 Swift）。

把 oMLX 的 /api/status 和 /admin/api/stats 换算成和 TensorFold /health 同格式的
“统一读数”（health、metrics 两个字典），并维护一张按 request_id 记的流表。
只用标准库；不读时钟、不做 I/O：同样的输入序列得到同样的输出。
"""

import math

LIMBO_S = 1.0               # 一行从表里消失后最多保留多久，等累计请求数跟上
DEFAULT_CONTEXT = 262144    # /v1/models 里读不到上下文上限时用
DEFAULT_MAX_STREAMS = 8     # oMLX 的默认并发上限
EPOCH_TOLERANCE_S = 30.0    # 启动时刻算出来的值抖动多少以内算同一次启动
GIB = 1073741824

_TOTAL_KEYS = ("total_requests", "total_prompt_tokens", "total_cached_tokens",
               "total_completion_tokens")


def _int(v):
    """整数（bool 不算）原样返回，其余 None。"""
    if isinstance(v, bool) or not isinstance(v, int):
        return None
    return v


def _num(v, default=0.0):
    """数（bool 不算）转成 float，其余返回 default。"""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return default
    return float(v)


def _int_or(v, default=0):
    """整数或浮点数取整（向零截断），其余返回 default。"""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return default
    return int(v)


class OmlxAdapter:
    """oMLX 读数 → (health, metrics)。"""

    def __init__(self, max_streams=DEFAULT_MAX_STREAMS):
        self.max_streams = max_streams
        self.contexts = {}          # 模型名 → 上下文上限，由调用方用 set_models 给
        self.reset()

    def reset(self):
        """回到刚建好的状态（contexts、max_streams 不动）。"""
        self._prev = None            # 上一次完整读数的四项累计值（元组），None 表示还没有
        self._last_full = None       # 上一次完整读数的时刻
        self._uptime = None          # 上一次的 uptime_seconds
        self._epoch = None           # 粘住的启动时刻（整数秒）
        self._rows = {}              # request_id → 行，插入顺序就是第一次见到的顺序
        self._placeholders = []      # “行还没出来”的占位的开始时刻，从早到晚
        self._credits = []           # [(时刻, 个数)]：累计请求数增加了、还没对上消失的行
        self._next_id = 1
        self._aborted = 0
        self._ab_prompt = 0          # 断开带走的提示、缓存命中、输出
        self._ab_cached = 0
        self._ab_output = 0
        self._ttft_sum = 0.0
        self._ttft_count = 0
        self._prefill_s = 0.0
        self._decode_s = 0.0
        self._by_model = {}          # 模型名 → [prompt, cached, completion, requests]
        self._last_model = None      # 最近开始的那条流所属的模型
        self._default_model = None
        self._last_c = 0             # 上一次给出的 completion_tokens_total（只增不减）
        self._usage_totals = None    # 上一次完整读数给出的 usage_totals / usage_by_model
        self._usage_by_model = None
        self._loading = None         # 上一次读到的加载信息 (时刻, 字典)

    def set_models(self, models):
        """/v1/models 的 data 列表 → 记下各模型的上下文上限。"""
        self.contexts = {}
        for m in models or []:
            if not isinstance(m, dict) or not isinstance(m.get("id"), str):
                continue
            n = _int(m.get("max_model_len"))
            if n is not None and n > 0:
                self.contexts[m["id"]] = n

    @property
    def model_name(self):
        """画面上显示的模型：加载中的 → 最近开始的 → oMLX 的默认模型。"""
        if self._loading is not None:
            return self._loading[1]["model"]
        return self._last_model or self._default_model

    def rows(self):
        """当前流表（公开的 8 个键），按第一次见到的顺序。"""
        return [self._pub(r) for r in self._rows.values()]

    # ---- 对外接口 ----

    def feed(self, now, wall, status, stats):
        """喂一次读数。status 是 /api/status 的字典；stats 是 /admin/api/stats 的字典或 None。

        now：单调时钟秒数（和采集器同一个钟）；wall：Unix 时间戳（只用来算启动时刻）。
        status 不是字典、或四项累计值缺了 / 不是整数 → 返回 None（当作这次读不到）。
        返回 (health, metrics)。
        """
        if not isinstance(status, dict):
            return None
        totals = tuple(_int(status.get(k)) for k in _TOTAL_KEYS)
        if any(v is None for v in totals):
            return None
        active = max(0, _int_or(status.get("active_requests")))
        waiting_status = max(0, _int_or(status.get("waiting_requests")))
        dm = status.get("default_model")
        uptime = status.get("uptime_seconds")
        uptime = None if isinstance(uptime, bool) or not isinstance(uptime, (int, float)) else float(uptime)

        # 1. 重启：累计值变小、uptime 变小、或者启动时刻跳了 → 全部清空，这次当第一次读数
        raw_epoch = None if uptime is None else wall - uptime
        if self._prev is not None:
            restarted = any(c < p for c, p in zip(totals, self._prev))
            if uptime is not None and self._uptime is not None and uptime < self._uptime:
                restarted = True
            if (raw_epoch is not None and self._epoch is not None
                    and abs(raw_epoch - self._epoch) > EPOCH_TOLERANCE_S):
                restarted = True
            if restarted:
                self.reset()
        if isinstance(dm, str) and dm:
            self._default_model = dm
        if raw_epoch is not None and (self._epoch is None
                                      or abs(raw_epoch - self._epoch) > EPOCH_TOLERANCE_S):
            self._epoch = int(round(raw_epoch))
        if uptime is not None:
            self._uptime = uptime

        if not isinstance(stats, dict):
            return self._degraded(now, totals, active, waiting_status)

        tables, loading = self._parse_stats(stats)
        if loading is None:
            self._loading = None
        else:
            self._loading = (now, loading)

        if self._prev is None:
            self._first(now, tables)
            self._prev = totals
            self._last_full = now
            self._fit_placeholders(now, tables, active, waiting_status)
            base = self._last_model or self._default_model or ""
            self._by_model = {base: [totals[1], totals[2], totals[3], totals[0]]}
            return self._output(now, totals, active, waiting_status, tables)

        # 2. 表里的行：更新已知的，新建第一次见到的
        self._update_rows(now, tables)
        # 3. 结束：累计请求数增加了 k，对上这次没出现在表里的行
        inc = totals[0] - self._prev[0]
        if inc > 0:
            self._credits.append((now, inc))
        finished = self._match_finished(now, tables, inc, totals[3] - self._prev[3])
        # 4. 这次累计值的增量记到模型名下
        self._attribute(totals, finished)
        # 5. 消失超过 LIMBO_S 的行算中途断开；过期的累计请求数增量作废
        self._expire(now)
        # 6. 占位
        self._fit_placeholders(now, tables, active, waiting_status)
        self._prev = totals
        self._last_full = now
        return self._output(now, totals, active, waiting_status, tables)

    # ---- 解析 ----

    @staticmethod
    def _parse_stats(stats):
        """→ (tables, loading)。tables：request_id → (表名, 行字典, 模型名)，
        按模型在列表里的顺序、每个模型内 waiting、prefilling、generating 的顺序。
        loading：第一个 is_loading 为真的模型 → {model, elapsed_s, estimated_s, size_gb}，没有就 None。
        """
        tables = {}
        loading = None
        am = stats.get("active_models")
        models = am.get("models") if isinstance(am, dict) else None
        if not isinstance(models, list):
            return tables, loading
        for m in models:
            if not isinstance(m, dict):
                continue
            name = m.get("id") if isinstance(m.get("id"), str) else ""
            if m.get("is_loading") is True and loading is None:
                est = m.get("loading_estimated_seconds")
                size = m.get("estimated_size")
                loading = {
                    "model": name,
                    "elapsed_s": _num(m.get("loading_elapsed_seconds"), 0.0),
                    "estimated_s": (float(est) if not isinstance(est, bool)
                                    and isinstance(est, (int, float)) and est > 0 else None),
                    "size_gb": (size / GIB if not isinstance(size, bool)
                                and isinstance(size, (int, float)) and size > 0 else None),
                }
            for table in ("waiting", "prefilling", "generating"):
                rows = m.get(table)
                if not isinstance(rows, list):
                    continue
                for r in rows:
                    if not isinstance(r, dict):
                        continue
                    rid = r.get("request_id")
                    if not isinstance(rid, str) or not rid or rid in tables:
                        continue
                    tables[rid] = (table, r, name)
        return tables, loading

    # ---- 流表 ----

    def _new_row(self, rid, model, start):
        row = {"id": self._next_id, "rid": rid, "model": model, "phase": "wait",
               "prompt": 0, "cached": 0, "filled": 0, "output": 0, "start": start,
               "ttft_s": None, "pstart": None, "dec_s": 0.0, "seen": True, "gone_at": None,
               "ttft_known": True}
        self._next_id += 1
        self._rows[rid] = row
        self._last_model = model
        return row

    @staticmethod
    def _elapsed(table, r):
        """这一行自己报的已用秒数：waiting、generating 是 elapsed_seconds，prefilling 是 elapsed。"""
        key = "elapsed" if table == "prefilling" else "elapsed_seconds"
        return max(0.0, _num(r.get(key), 0.0))

    def _first(self, now, tables):
        """第一次读数：表里已有的行照各自报的已用秒数回推开始时刻；正在解码的不知道首字时间。"""
        for rid, (table, r, model) in tables.items():
            row = self._new_row(rid, model, now - self._elapsed(table, r))
            if table == "generating":
                row["ttft_known"] = False
            self._apply(now, row, table, r)

    def _update_rows(self, now, tables):
        """先按 waiting、prefilling、generating 的顺序新建行（新行按这个顺序领占位），再更新所有行。"""
        for row in self._rows.values():
            row["seen"] = False
        for order in ("waiting", "prefilling", "generating"):
            for rid, (table, r, model) in tables.items():
                if table != order or rid in self._rows:
                    continue
                if table == "waiting":
                    start = now - self._elapsed(table, r)
                elif self._placeholders:
                    start = self._placeholders.pop(0)
                elif (table == "generating" and self._last_full is not None
                      and self._last_full < now - self._elapsed(table, r)):
                    # 两次读数之间就预填充完了：只知道它在上次读数和开始解码之间到的，取中点（误差不超过半次轮询）
                    start = (self._last_full + now - self._elapsed(table, r)) / 2
                else:
                    start = now - self._elapsed(table, r)
                self._new_row(rid, model, start)
        for rid, (table, r, model) in tables.items():
            self._apply(now, self._rows[rid], table, r)

    def _apply(self, now, row, table, r):
        """用表里的这一行更新流表的行。"""
        row["seen"] = True
        row["gone_at"] = None
        row["prompt"] = max(0, _int_or(r.get("prompt_tokens")))
        if table == "waiting":
            row["phase"] = "wait"
            return
        if table == "prefilling":
            row["phase"] = "prefill"
            row["cached"] = max(0, _int_or(r.get("cached_tokens")))
            row["filled"] = max(row["cached"], _int_or(r.get("processed")))
            row["output"] = 0
            if row["pstart"] is None:
                row["pstart"] = now - self._elapsed(table, r)
            return
        # generating
        el = self._elapsed(table, r)
        if row["phase"] != "decode" and row["ttft_known"] and row["ttft_s"] is None:
            row["ttft_s"] = max(0.0, now - el - row["start"])
        row["phase"] = "decode"
        row["filled"] = row["prompt"]
        row["output"] = max(0, _int_or(r.get("generated_tokens")))
        row["dec_s"] = el

    def _match_finished(self, now, tables, inc, comp_inc):
        """这次没出现在表里的行：先记下消失的时刻；再用攒着的累计请求数增量对上，
        解码行优先，同类里开始早的优先。对上的行算正常结束，从流表删掉。返回这些行。"""
        gone = []
        for row in self._rows.values():
            if row["rid"] in tables:
                continue
            if row["gone_at"] is None:
                row["gone_at"] = now
            gone.append(row)
        gone.sort(key=lambda r: (r["phase"] != "decode", r["start"], r["id"]))
        credit = sum(n for _, n in self._credits)
        k = min(credit, len(gone))
        finished = gone[:k]
        # 从最早的增量开始扣
        left = k
        kept = []
        for t, n in self._credits:
            use = min(n, left)
            left -= use
            if n - use > 0:
                kept.append((t, n - use))
        self._credits = kept
        # 这次消失的行都在这次读数里正常结束、而且都是解码行：累计输出的增量就是它们的最终输出，
        # 解码秒数按“最终输出 / 最后一次读到的输出”同比放大（两次读数之间那段也算上）
        scale = 1.0
        out = sum(r["output"] for r in finished)
        if (finished and inc == len(finished) == credit == len(gone) and out > 0 and comp_inc >= out
                and all(r["phase"] == "decode" and r["output"] > 0 for r in finished)):
            scale = comp_inc / out
        for row in finished:
            del self._rows[row["rid"]]
            if row["ttft_s"] is not None:
                self._ttft_sum += row["ttft_s"]
                self._ttft_count += 1
                queue = max(0.0, row["pstart"] - row["start"]) if row["pstart"] is not None else 0.0
                self._prefill_s += max(0.0, row["ttft_s"] - queue)
            if row["phase"] == "decode":
                self._decode_s += row["dec_s"] * scale
        return finished

    def _attribute(self, totals, finished):
        """四项累计值的增量记到模型名下：有对上结束的行就按它们的提示长度分，
        没有就记在最近开始的模型（再没有就是默认模型）名下。"""
        delta = [totals[1] - self._prev[1], totals[2] - self._prev[2],
                 totals[3] - self._prev[3], totals[0] - self._prev[0]]
        if not any(delta):
            return
        if finished:
            names = [r["model"] for r in finished]
            weights = [r["prompt"] for r in finished]
        else:
            names = [self._last_model or self._default_model or ""]
            weights = [1]
        if sum(weights) == 0:
            weights = [1] * len(names)
        wsum = sum(weights)
        for i, d in enumerate(delta):
            shares = [d * w // wsum for w in weights]
            shares[0] += d - sum(shares)
            for name, s in zip(names, shares):
                self._by_model.setdefault(name, [0, 0, 0, 0])[i] += s

    def _expire(self, now):
        """消失超过 LIMBO_S 的行算中途断开；超过 LIMBO_S 还没对上的累计请求数增量作废。"""
        for row in list(self._rows.values()):
            if row["gone_at"] is None or now - row["gone_at"] < LIMBO_S:
                continue
            del self._rows[row["rid"]]
            self._aborted += 1
            # 排队时就断开的请求还没算过，不计用量
            prompt = row["prompt"] if row["phase"] != "wait" else 0
            cached = row["cached"] if row["phase"] != "wait" else 0
            out = row["output"] if row["phase"] == "decode" else 0
            self._ab_prompt += prompt
            self._ab_cached += cached
            self._ab_output += out
            acc = self._by_model.setdefault(row["model"], [0, 0, 0, 0])
            acc[0] += prompt
            acc[1] += cached
            acc[2] += out
        self._credits = [(t, n) for t, n in self._credits if now - t < LIMBO_S]

    def _fit_placeholders(self, now, tables, active, waiting_status):
        """在跑数比表里的行多出来的部分记成占位：多了从最晚的删，少了按这次的时刻补。"""
        n_wait = sum(1 for t, _, _ in tables.values() if t == "waiting")
        wait = max(waiting_status, n_wait)
        n_run = sum(1 for t, _, _ in tables.values() if t != "waiting")
        gone = sum(1 for r in self._rows.values() if r["gone_at"] is not None)
        target = max(0, active - wait - n_run - gone)
        while len(self._placeholders) > target:
            self._placeholders.pop()
        while len(self._placeholders) < target:
            self._placeholders.append(now)

    # ---- 输出 ----

    def _pub(self, row):
        return {"id": row["id"], "phase": row["phase"], "prompt": row["prompt"],
                "cached": row["cached"], "filled": row["filled"], "output": row["output"],
                "start": row["start"], "ttft_s": row["ttft_s"]}

    def _loading_now(self, now):
        if self._loading is None:
            return None
        t, info = self._loading
        out = dict(info)
        out["elapsed_s"] = info["elapsed_s"] + (now - t)
        return out

    def _context(self):
        name = self.model_name
        return self.contexts.get(name, DEFAULT_CONTEXT) if name else DEFAULT_CONTEXT

    def _health_base(self, now, totals, running, decoding, prefilling, completion):
        self._last_c = max(self._last_c, completion)
        health = {
            "ok": True,
            "backend": "omlx",
            "requests_running": running,
            "streams": {"decoding": decoding, "prefilling": prefilling, "max": self.max_streams},
            "requests_total": totals[0],
            "completion_tokens_total": self._last_c,
            "prompt_tokens_total": totals[1],
            "cached_tokens_total": totals[2],
            "prefill_seconds_total": self._prefill_s,
            "decode_seconds_total": self._decode_s,
            "drafted_total": 0,
            "accepted_total": 0,
            "epoch": self._epoch,
            "aborted_total": self._aborted,
            "completion_finished_total": totals[3],
            "context_length": self._context(),
        }
        loading = self._loading_now(now)
        if loading is not None:
            health["loading"] = loading
        return health

    def _output(self, now, totals, active, waiting_status, tables):
        rows = list(self._rows.values())
        n_wait = sum(1 for r in rows if r["phase"] == "wait")
        dec = [r for r in rows if r["phase"] == "decode"]
        pre = [r for r in rows if r["phase"] == "prefill"]
        wait = max(waiting_status, n_wait)
        ph = len(self._placeholders)
        running = wait + len(dec) + len(pre) + ph
        live = sum(r["output"] for r in dec)
        health = self._health_base(now, totals, running, len(dec), len(pre) + ph,
                                   totals[3] + live + self._ab_output)
        self._usage_totals = {"prompt": totals[1] + self._ab_prompt,
                              "cached": totals[2] + self._ab_cached,
                              "completion": totals[3] + self._ab_output,
                              "requests": totals[0]}
        self._usage_by_model = {name: {"prompt": v[0], "cached": v[1], "completion": v[2],
                                       "requests": v[3]}
                                for name, v in sorted(self._by_model.items())}
        health["usage_totals"] = dict(self._usage_totals)
        health["usage_by_model"] = {k: dict(v) for k, v in self._usage_by_model.items()}
        if ph == 0:
            health["tfpanel"] = {"v": 1, "streams": [self._pub(r) for r in rows if r["phase"] != "wait"]}
        metrics = {"waiting": wait, "kv_usage": [], "ttft_sum": self._ttft_sum,
                   "ttft_count": self._ttft_count}
        return health, metrics

    def _degraded(self, now, totals, active, waiting_status):
        """/admin/api/stats 读不到：只用 /api/status，不带 tfpanel；流表、累计秒数都不动。"""
        health = self._health_base(now, totals, active, max(0, active - waiting_status), 0,
                                   totals[3] + self._ab_output)
        if self._usage_totals is None:
            base = self._last_model or self._default_model or ""
            self._usage_totals = {"prompt": totals[1], "cached": totals[2],
                                  "completion": totals[3], "requests": totals[0]}
            self._usage_by_model = {base: dict(self._usage_totals)}
        health["usage_totals"] = dict(self._usage_totals)
        health["usage_by_model"] = {k: dict(v) for k, v in self._usage_by_model.items()}
        metrics = {"waiting": waiting_status, "kv_usage": [], "ttft_sum": self._ttft_sum,
                   "ttft_count": self._ttft_count}
        return health, metrics
