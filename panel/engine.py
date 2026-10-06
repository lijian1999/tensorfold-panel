# vLLM 适配器：从全局计数器推出每条流的明细，并换算成 TensorFold 格式的统一读数。
# 只用标准库；不读时钟、不做 I/O，同样的输入序列得到同样的输出。

# 用来判断“引擎换过（重启）”的累计键：任一变小就认为计数器归零过。
_RESTART_KEYS = ("queries", "hits", "prompt", "prompt_cached", "ttft_count", "generation",
                 "success", "req_prompt_sum", "req_generation_sum", "req_computed_sum",
                 "drafted", "accepted")

# 读数里除 epoch 外的全部键，float 型的缺省用 0.0，其余缺省用 0。
_FLOAT_KEYS = ("ttft_sum", "prefill_s", "decode_s")
_INT_KEYS = ("running", "waiting", "queries", "hits", "prompt", "prompt_cached", "ttft_count",
             "generation", "success", "req_prompt_sum", "req_generation_sum", "req_computed_sum",
             "drafted", "accepted")

_DEFAULT_TPS = 2300.0  # 没给 prefill_tps 时 assumed 的预填充速度（token/秒）


def _share(total, n):
    """把 total 平均分给 n 行：每行 total // n，余数全部加给第一行。"""
    if n <= 0:
        return []
    base = total // n
    vals = [base] * n
    vals[0] += total % n
    return vals


class VllmAdapter:
    """vLLM 读数 → (health, metrics)，并维护一张按到达先后排列的流表。"""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        """回到刚建好的状态。"""
        self.prev = None          # 上一次读数 p
        self._rows = []           # 流表，按到达先后，新行加在末尾
        self._next_id = 1         # 每新建一行用掉一个，删掉也不回收
        self._peak = 0            # 见过的 running 最大值
        self._aborted = 0         # 中途断开的累计次数
        self._done_ttft_sum = 0.0
        self._done_ttft_count = 0
        self._lag = 2.0           # 典型延迟：请求到达到第一次出现在读数里要多久
        self._orphan = 0          # 不属于任何在跑的行的输出 token
        self._drafted = 0         # 锁存的推测解码计数
        self._accepted = 0
        self._empty_since = None  # 流表最近一次变空的时刻；None 表示“很久以前”

    # ---- 内部工具 ----

    def _new_row(self, now):
        """新建一行提示未知的行，加到流表末尾。"""
        row = {"id": self._next_id, "phase": "prefill", "prompt": None, "cached": 0,
               "output": 0, "start": now, "ttft_s": None, "seen": now, "solo": False}
        self._next_id += 1
        self._rows.append(row)
        return row

    @staticmethod
    def _normalize(m):
        """读数缺的键按 0 算（epoch 按 None）。"""
        out = {k: m.get(k, 0.0 if k in _FLOAT_KEYS else 0) for k in _FLOAT_KEYS + _INT_KEYS}
        out["epoch"] = m.get("epoch")
        return out

    def _pub(self, row):
        """流表一行对外公开的 7 个键（都是标量，拷贝即隔离）。"""
        return {"id": row["id"], "phase": row["phase"], "prompt": row["prompt"],
                "cached": row["cached"], "output": row["output"],
                "start": row["start"], "ttft_s": row["ttft_s"]}

    # ---- 对外接口 ----

    def rows(self):
        """当前流表各行的拷贝（每行恰好 7 个键），按到达先后。"""
        return [self._pub(r) for r in self._rows]

    def feed(self, now, m, prefill_tps=None, context_length=None):
        """喂一次读数，返回 (health, metrics)。"""
        m = self._normalize(m)
        tps = (float(prefill_tps) if isinstance(prefill_tps, (int, float))
               and not isinstance(prefill_tps, bool) and prefill_tps > 0
               else _DEFAULT_TPS)
        if self.prev is not None and self._is_restart(self.prev, m):
            self.reset()
            p = None
        else:
            p = self.prev
        if p is None:
            # 第一步处理之外：新建 running 行提示未知的行，算好 orphan / 锁存 / peak，直接输出。
            for _ in range(m["running"]):
                self._new_row(now)
            self._orphan = m["generation"] - m["req_generation_sum"]
            self._drafted = m["drafted"]
            self._accepted = m["accepted"]
            self._peak = max(self._peak, m["running"])
            self.prev = m
            return self._output(m, context_length)

        fin = m["success"] - p["success"]  # 这次结束的条数
        aborted_before = self._aborted
        self._step_arrive(now, m, p, fin, tps)
        self._step_first_token(now, m, p)
        self._step_output(m, p)
        self._step_finish(m, p, fin)
        self._step_reconcile(now, m)
        self._step_calibrate(m)
        self._step_finalize(now, m, p, fin, aborted_before)
        self._peak = max(self._peak, m["running"])
        self.prev = m
        return self._output(m, context_length)

    # ---- 各步 ----

    @staticmethod
    def _is_restart(p, m):
        """epoch 变了，或任一枚举的累计键变小 → 引擎重启过。"""
        if p["epoch"] is not None and m["epoch"] is not None and p["epoch"] != m["epoch"]:
            return True
        return any(m[k] < p[k] for k in _RESTART_KEYS)

    def _step_arrive(self, now, m, p, fin, tps):
        """第 3 步：到达。用 running/queries 的差推新来的请求。"""
        n = m["running"] - len(self._rows) + fin
        dq = m["queries"] - p["queries"]
        dh = m["hits"] - p["hits"]
        # 独自出现的条件：此刻流表是空的，且距上次变空够久（empty_since 为 None 视作很久以前）。
        solo_ok = len(self._rows) == 0 and (self._empty_since is None
                                            or now - self._empty_since >= 0.25)
        if dq > 0:
            n = max(1, n)
            fresh = [self._new_row(now) for _ in range(n)]
            prompts = _share(dq, n)
            caches = _share(dh, n)
            for row, pr, ca in zip(fresh, prompts, caches):
                row["prompt"] = pr
                row["cached"] = ca
                row["start"] = now - min((pr - ca) / tps, self._lag) if solo_ok else now
                row["solo"] = solo_ok and n == 1
        elif n > 0:
            for _ in range(n):
                self._new_row(now)

    def _step_first_token(self, now, m, p):
        """第 4 步：出首字。按 ttft_count 的差把预填充行翻成解码行。"""
        k = m["ttft_count"] - p["ttft_count"]
        if k <= 0:
            return
        dp = m["prompt"] - p["prompt"]
        dc = m["prompt_cached"] - p["prompt_cached"]
        dt = m["ttft_sum"] - p["ttft_sum"]
        prefill = [r for r in self._rows if r["phase"] == "prefill"]
        if k == 1:
            row = next((r for r in prefill if r["prompt"] == dp), None)
            if row is None:
                row = next((r for r in prefill if r["prompt"] is None), None)
            if row is None and prefill:
                row = prefill[0]
            if row is None:
                row = self._new_row(now)
            # 长提示独自出现时，用实测首字时间校准 lag。
            if (row["solo"] and row["prompt"] is not None
                    and row["prompt"] - row["cached"] >= 4096):
                self._lag = 0.7 * self._lag + 0.3 * max(0.0, dt - (now - row["seen"]))
            row["phase"] = "decode"
            row["prompt"] = dp
            row["cached"] = dc
            row["ttft_s"] = dt
            row["start"] = now - dt
            return
        # k > 1：取前 k 个预填充行，不够就补未知行。
        picked = prefill[:k]
        while len(picked) < k:
            picked.append(self._new_row(now))
        unknown = [r for r in picked if r["prompt"] is None]
        if unknown:
            known_p = sum(r["prompt"] for r in picked if r["prompt"] is not None)
            known_c = sum(r["cached"] for r in picked if r["prompt"] is not None)
            ps = _share(max(0, dp - known_p), len(unknown))
            cs = _share(max(0, dc - known_c), len(unknown))
            for row, pr, ca in zip(unknown, ps, cs):
                row["prompt"] = pr
                row["cached"] = ca
        for row in picked:
            row["phase"] = "decode"
            row["ttft_s"] = dt / k
            row["start"] = now - dt / k

    def _step_output(self, m, p):
        """第 5 步：把这次新增的输出 token 平均分给解码行。"""
        dg = m["generation"] - p["generation"]
        decode = [r for r in self._rows if r["phase"] == "decode"]
        if dg > 0 and decode:
            for row, s in zip(decode, _share(dg, len(decode))):
                row["output"] += s

    def _step_finish(self, m, p, fin):
        """第 6 步：结束的请求从流表删掉，有首字时间的计入已结束统计。"""
        if fin < 1:
            return
        decode = [r for r in self._rows if r["phase"] == "decode"]
        others = [r for r in self._rows if r["phase"] != "decode"]
        candidates = decode + others
        if fin == 1:
            if not candidates:
                return
            rp = m["req_prompt_sum"] - p["req_prompt_sum"]
            row = next((r for r in decode if r["prompt"] == rp), None)
            removed = [row if row is not None else candidates[0]]
        else:
            removed = candidates[:min(fin, len(candidates))]
        gone = {id(r) for r in removed}
        self._rows = [r for r in self._rows if id(r) not in gone]
        for row in removed:
            if row["ttft_s"] is not None:
                self._done_ttft_sum += row["ttft_s"]
                self._done_ttft_count += 1

    def _step_reconcile(self, now, m):
        """第 7 步：流表行数和 running 对账，多出的是中途断开的。"""
        extra = len(self._rows) - m["running"]
        if extra > 0:
            for row in self._rows[-extra:]:
                self._orphan += row["output"]
            del self._rows[-extra:]
            self._aborted += extra
        elif extra < 0:
            for _ in range(-extra):
                self._new_row(now)

    def _step_calibrate(self, m):
        """第 8 步：解码行的 output 总数对齐“总输出 − 已结束 − 无主流”。"""
        target = max(0, m["generation"] - m["req_generation_sum"] - self._orphan)
        decode = [r for r in self._rows if r["phase"] == "decode"]
        if target > 0 and self._rows and not decode:
            # 明明有输出却没有解码行：多半是第一行还挂着 prefill，改过来。
            self._rows[0]["phase"] = "decode"
            decode = [self._rows[0]]
        if not decode:
            return
        total = sum(r["output"] for r in decode)
        if total == target:
            return
        if total > 0:
            for row in decode:
                row["output"] = row["output"] * target // total
        else:
            for row, s in zip(decode, _share(target, len(decode))):
                row["output"] = s
        decode[0]["output"] += target - sum(r["output"] for r in decode)

    def _step_finalize(self, now, m, p, fin, aborted_before):
        """第 9 步：收尾——空表时刻、锁存推测解码计数。"""
        if m["running"] == 0:
            self._orphan = m["generation"] - m["req_generation_sum"]
            if p["running"] > 0 or fin >= 1 or self._aborted != aborted_before:
                self._empty_since = now
        if fin >= 1 or m["running"] == 0:
            self._drafted = m["drafted"]
            self._accepted = m["accepted"]

    def _output(self, m, context_length):
        """拼约定第 3 节的 (health, metrics)，全部是新的字典。"""
        decoding = sum(1 for r in self._rows if r["phase"] == "decode")
        prefilling = sum(1 for r in self._rows if r["phase"] == "prefill")
        health = {
            "ok": True,
            "backend": "vllm",
            "requests_running": m["running"],
            "streams": {"decoding": decoding, "prefilling": prefilling,
                        "max": max(4, self._peak)},
            "requests_total": m["success"],
            "completion_tokens_total": m["generation"],
            "prompt_tokens_total": m["req_prompt_sum"],
            "cached_tokens_total": m["req_prompt_sum"] - m["req_computed_sum"],
            "prefill_seconds_total": m["prefill_s"],
            "decode_seconds_total": m["decode_s"],
            "drafted_total": self._drafted,
            "accepted_total": self._accepted,
            "epoch": m["epoch"],
            "aborted_total": self._aborted,
            "completion_finished_total": m["req_generation_sum"],
            "usage_totals": {"prompt": m["prompt"], "cached": m["prompt_cached"],
                             "completion": m["generation"], "requests": m["success"]},
        }
        if isinstance(context_length, (int, float)) and not isinstance(context_length, bool) \
                and context_length > 0:
            health["context_length"] = context_length
        # 只有每一行的 prompt 都已知才给 tfpanel（空表也算）。
        if all(r["prompt"] is not None for r in self._rows):
            health["tfpanel"] = {"v": 1, "streams": [self._pub(r) for r in self._rows]}
        metrics = {"waiting": m["waiting"], "kv_usage": [],
                   "ttft_sum": self._done_ttft_sum, "ttft_count": self._done_ttft_count}
        return health, metrics
