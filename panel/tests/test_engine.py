import json
import unittest
from pathlib import Path

from panel.engine import VllmAdapter

SEQ_DIR = Path(__file__).resolve().parents[2] / "fixtures" / "vllm"


def load(name):
    """读一段录下来的序列，返回 (整个文件, [(t, 读数), …])。"""
    with open(SEQ_DIR / f"seq-{name}.json", encoding="utf-8") as f:
        data = json.load(f)
    fields = data["fields"]
    return data, [(s[0], dict(zip(fields[1:], s[1:]))) for s in data["samples"]]


def state_of(adapter, health, metrics):
    """适配器此刻的状态，写成和 checkpoints 同样的格式（不含 t）。"""
    rows = []
    for row in adapter.rows():
        rows.append({"id": row["id"], "phase": row["phase"], "prompt": row["prompt"], "cached": row["cached"],
                     "start": round(row["start"], 3),
                     "ttft_s": None if row["ttft_s"] is None else round(row["ttft_s"], 4)})
    return {"detail": "tfpanel" in health, "rows": rows,
            "decoding": health["streams"]["decoding"], "prefilling": health["streams"]["prefilling"],
            "max": health["streams"]["max"], "aborted_total": health["aborted_total"],
            "ttft_count": metrics["ttft_count"], "ttft_sum": round(metrics["ttft_sum"], 4)}


class SeqCase(unittest.TestCase):
    def check_checkpoints(self, name):
        """把 samples[::2] 喂进去，每一步的状态都要等于时刻不晚于它的最后一个 checkpoint。"""
        data, samples = load(name)
        checkpoints = data["checkpoints"]
        adapter = VllmAdapter()
        for t, m in samples[::2]:
            health, metrics = adapter.feed(t, m)
            want = [c for c in checkpoints if c["t"] <= t + 1e-9][-1]
            want = {k: v for k, v in want.items() if k != "t"}
            got = state_of(adapter, health, metrics)
            self.assertEqual(len(got["rows"]), len(want["rows"]), f"{name} t={t}")
            for g, w in zip(got["rows"], want["rows"]):
                self.assertAlmostEqual(g.pop("start"), w["start"], delta=0.002, msg=f"{name} t={t}")
                if w["ttft_s"] is None:
                    self.assertIsNone(g.pop("ttft_s"), f"{name} t={t}")
                else:
                    self.assertAlmostEqual(g.pop("ttft_s"), w["ttft_s"], delta=0.0002, msg=f"{name} t={t}")
                self.assertEqual(g, {k: v for k, v in w.items() if k not in ("start", "ttft_s")}, f"{name} t={t}")
            self.assertAlmostEqual(got.pop("ttft_sum"), want["ttft_sum"], delta=0.0002, msg=f"{name} t={t}")
            got.pop("rows")
            self.assertEqual(got, {k: v for k, v in want.items() if k not in ("rows", "ttft_sum")}, f"{name} t={t}")
        return adapter


class TestSingle(SeqCase):
    def test_short(self):
        self.check_checkpoints("short")

    def test_long(self):
        self.check_checkpoints("long")

    def test_followup(self):
        self.check_checkpoints("followup")

    def test_round(self):
        self.check_checkpoints("round")


class TestMulti(SeqCase):
    def test_conc3(self):
        self.check_checkpoints("conc3")

    def test_conc5(self):
        self.check_checkpoints("conc5")

    def test_long_then_short(self):
        self.check_checkpoints("long-then-short")

    def test_abort_decode(self):
        self.check_checkpoints("abort-decode")

    def test_abort_prefill(self):
        self.check_checkpoints("abort-prefill")

    def test_abort_conc(self):
        self.check_checkpoints("abort-conc")


def feed_all(adapter, seq):
    """把一段序列全部喂进去，返回最后一次的 (health, metrics)。"""
    last = None
    for t, m in seq:
        last = adapter.feed(t, m)
    return last


class TestUnified(SeqCase):

    def test_followup_totals(self):
        data, samples = load("followup")
        adapter = VllmAdapter()
        health, metrics = feed_all(adapter, samples[::2])
        first = samples[::2][0][1]
        self.assertEqual(health["requests_total"] - first["success"], 1)
        self.assertEqual(health["prompt_tokens_total"] - first["req_prompt_sum"], 24126)
        self.assertEqual(health["cached_tokens_total"] - (first["req_prompt_sum"] - first["req_computed_sum"]), 19584)
        self.assertEqual(health["completion_tokens_total"] - first["generation"], 120)
        self.assertEqual(health["completion_finished_total"] - first["req_generation_sum"], 120)
        last = samples[::2][-1][1]
        self.assertEqual(health["usage_totals"], {"prompt": last["prompt"], "cached": last["prompt_cached"],
                                                 "completion": last["generation"], "requests": last["success"]})
        self.assertIs(health["ok"], True)
        self.assertEqual(health["backend"], "vllm")
        self.assertEqual(health["epoch"], last["epoch"])
        self.assertEqual(metrics["waiting"], 0)
        self.assertEqual(metrics["kv_usage"], [])

    def test_draft_latch(self):
        data, samples = load("short")
        adapter = VllmAdapter()
        seq = samples[::2]
        first_health, _ = adapter.feed(*seq[0])
        base_d, base_a = first_health["drafted_total"], first_health["accepted_total"]
        last_health = first_health
        for t, m in seq[1:]:
            health, _ = adapter.feed(t, m)
            if health["requests_running"] == 1:
                self.assertEqual(health["drafted_total"], base_d, f"t={t}")
                self.assertEqual(health["accepted_total"], base_a, f"t={t}")
            last_health = health
        self.assertEqual(last_health["drafted_total"] - base_d, 84)
        self.assertEqual(last_health["accepted_total"] - base_a, 29)

    def test_invariants_all_offsets(self):
        names = ["short", "long", "followup", "round", "conc3", "conc5",
                 "long-then-short", "abort-decode", "abort-prefill", "abort-conc"]
        for name in names:
            data, samples = load(name)
            for step in (1, 2, 3, 5):
                for off in range(step):
                    adapter = VllmAdapter()
                    health = metrics = None
                    for t, m in samples[off::step]:
                        health, metrics = adapter.feed(t, m)
                        self.assertEqual(len(adapter.rows()), m["running"],
                                         f"{name} step={step} off={off} t={t}")
                        self.assertEqual(health["requests_running"], m["running"],
                                         f"{name} step={step} off={off} t={t}")
                        st = health["streams"]
                        self.assertEqual(st["decoding"] + st["prefilling"], m["running"],
                                         f"{name} step={step} off={off} t={t}")
                    self.assertEqual(len(adapter.rows()), 0, f"{name} step={step} off={off}")
                    aborted = sum(1 for r in data["requests"] if r["aborted"])
                    self.assertEqual(health["aborted_total"], aborted,
                                     f"{name} step={step} off={off}")
                    self.assertEqual(metrics["ttft_count"], len(data["requests"]) - aborted,
                                     f"{name} step={step} off={off}")

    def test_decode_output_sum(self):
        for name in ("long", "conc3", "conc5"):
            data, samples = load(name)
            for off in (0, 1):
                adapter = VllmAdapter()
                seq = samples[off::2]
                base = seq[0][1]
                for t, m in seq:
                    adapter.feed(t, m)
                    want = (m["generation"] - m["req_generation_sum"]) - (base["generation"] - base["req_generation_sum"])
                    got = sum(r["output"] for r in adapter.rows() if r["phase"] == "decode")
                    self.assertEqual(got, want, f"{name} off={off} t={t}")

    def test_peak_max(self):
        adapter = VllmAdapter()
        last = None
        for t, m in load("conc5")[1][::2]:
            last = adapter.feed(t, m)
        self.assertEqual(last[0]["streams"]["max"], 5)
        adapter = VllmAdapter()
        last = None
        for t, m in load("short")[1][::2]:
            last = adapter.feed(t, m)
        self.assertEqual(last[0]["streams"]["max"], 4)

    def test_context_length(self):
        data, samples = load("short")
        adapter = VllmAdapter()
        for t, m in samples[::2]:
            health, _ = adapter.feed(t, m, None, 262144)
            self.assertEqual(health["context_length"], 262144)
        adapter = VllmAdapter()
        for t, m in samples[::2]:
            health, _ = adapter.feed(t, m)
            self.assertNotIn("context_length", health)

    def test_prefill_tps(self):
        data, samples = load("long")
        adapter = VllmAdapter()
        hit = False
        for t, m in samples[::2]:
            adapter.feed(t, m, 24085.0)
            if not hit and t >= 3.5058:
                rows = adapter.rows()
                self.assertEqual(len(rows), 1)
                self.assertAlmostEqual(rows[0]["start"], 2.5058, delta=0.002)
                hit = True
        self.assertTrue(hit)

    def test_returned_values_are_copies(self):
        data, samples = load("short")
        adapter = VllmAdapter()
        seq = samples[::2]
        i = 0
        health, _ = adapter.feed(*seq[i]); i += 1
        # 喂到已有行且带 tfpanel 的那一步
        while i < len(seq):
            health, _ = adapter.feed(*seq[i]); i += 1
            rows = adapter.rows()
            if rows and "tfpanel" in health:
                break
        rows = adapter.rows()
        if rows:
            rows[0]["prompt"] = 999999
        if "tfpanel" in health and health["tfpanel"]["streams"]:
            health["tfpanel"]["streams"][0]["prompt"] = 999999
        ids = [r["id"] for r in adapter.rows()]
        health, _ = adapter.feed(*seq[i]); i += 1
        for r in adapter.rows():
            self.assertNotEqual(r["prompt"], 999999)
        self.assertEqual([r["id"] for r in adapter.rows()], ids)


class TestEdges(SeqCase):

    def test_midstart_prefill(self):
        data, samples = load("long")
        adapter = VllmAdapter()
        seq = samples[100::2]
        health, _ = adapter.feed(*seq[0])
        rows = adapter.rows()
        self.assertEqual(len(rows), 1)
        self.assertIsNone(rows[0]["prompt"])
        self.assertEqual(rows[0]["phase"], "prefill")
        self.assertNotIn("tfpanel", health)
        seen_detail = None
        last_health = None
        for t, m in seq[1:]:
            last_health, metrics = adapter.feed(t, m)
            if t >= 10.5 and seen_detail is None:
                seen_detail = t
                self.assertIn("tfpanel", last_health, f"t={t}")
                rows = adapter.rows()
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]["phase"], "decode")
                self.assertEqual(rows[0]["prompt"], 24085)
                self.assertAlmostEqual(rows[0]["ttft_s"], 9.3375, delta=0.0002, msg=f"t={t}")
        self.assertIsNotNone(seen_detail)
        self.assertEqual(len(adapter.rows()), 0)
        self.assertEqual(last_health["aborted_total"], 0)
        self.assertEqual(metrics["ttft_count"], 1)

    def test_midstart_decode(self):
        data, samples = load("long")
        adapter = VllmAdapter()
        seq = samples[230::2]
        health, _ = adapter.feed(*seq[0])
        self.assertNotIn("tfpanel", health)
        rows = adapter.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["phase"], "prefill")
        base_gen = seq[0][1]["generation"]
        last_health = None
        for t, m in seq[1:]:
            last_health, metrics = adapter.feed(t, m)
            if m["running"] == 0:
                continue
            rows = adapter.rows()
            self.assertEqual(len(rows), 1, f"t={t}")
            self.assertEqual(rows[0]["phase"], "decode", f"t={t}")
            self.assertEqual(rows[0]["output"], m["generation"] - base_gen, f"t={t}")
            self.assertNotIn("tfpanel", last_health, f"t={t}")
        self.assertEqual(len(adapter.rows()), 0)
        self.assertIn("tfpanel", last_health)
        self.assertEqual(last_health["aborted_total"], 0)
        self.assertEqual(metrics["ttft_count"], 0)

    def test_midstart_all_positions(self):
        names = ["short", "long", "followup", "round", "conc3", "conc5",
                 "long-then-short", "abort-decode", "abort-prefill", "abort-conc"]
        for name in names:
            data, samples = load(name)
            for start in range(0, len(samples) - 5, 7):
                adapter = VllmAdapter()
                for t, m in samples[start::2]:
                    adapter.feed(t, m)
                self.assertEqual(len(adapter.rows()), 0, f"{name} start={start}")

    def test_restart_epoch(self):
        data, samples = load("conc5")
        adapter = VllmAdapter()
        seq = samples[::2]
        for t, m in seq:
            health, _ = adapter.feed(t, m)
        zero = {k: 0 for k in samples[0][1]}
        zero["epoch"] = 12345.0
        health, metrics = adapter.feed(seq[-1][0] + 0.1, zero)
        self.assertEqual(len(adapter.rows()), 0)
        self.assertEqual(health["aborted_total"], 0)
        self.assertEqual(metrics["ttft_count"], 0)
        self.assertEqual(health["streams"]["max"], 4)
        self.assertEqual(health["drafted_total"], 0)

    def test_restart_decreased_counter(self):
        data, samples = load("abort-decode")
        adapter = VllmAdapter()
        seq = samples[::2]
        last = None
        for t, m in seq:
            last = adapter.feed(t, m)
        self.assertEqual(last[0]["aborted_total"], 1)
        t, m = seq[-1]
        m2 = dict(m)
        m2["generation"] = m["generation"] - 1
        health, _ = adapter.feed(t + 0.1, m2)
        self.assertEqual(health["aborted_total"], 0)

    def test_reset_midway(self):
        data, samples = load("short")
        adapter = VllmAdapter()
        seq = samples[::2]
        half = len(seq) // 2
        for t, m in seq[:half]:
            adapter.feed(t, m)
        adapter.reset()
        self.assertEqual(len(adapter.rows()), 0)
        for t, m in seq[half:]:
            adapter.feed(t, m)

    def test_missing_keys(self):
        adapter = VllmAdapter()
        health, metrics = adapter.feed(0.0, {"running": 0})
        self.assertEqual(health["requests_total"], 0)
        self.assertIsNone(health["epoch"])

    def test_start_not_before_empty(self):
        """流表空了之后才出现的请求，开始时刻不早于变空的那一刻。"""
        Z = dict(running=0, waiting=0, queries=0, hits=0, prompt=0, prompt_cached=0, ttft_sum=0.0, ttft_count=0,
                 generation=0, success=0, req_prompt_sum=0, req_generation_sum=0, req_computed_sum=0,
                 prefill_s=0.0, decode_s=0.0, drafted=0, accepted=0, epoch=1.0)
        m1 = dict(Z, running=1, queries=100, prompt=100, ttft_count=1, ttft_sum=0.1, generation=1)       # 一个短请求出首字
        m2 = dict(Z, queries=100, prompt=100, ttft_count=1, ttft_sum=0.1, generation=5, success=1,
                  req_prompt_sum=100, req_generation_sum=5, req_computed_sum=100)                         # 它结束了
        m3 = dict(m2, running=1, queries=23100)                                                           # 又来一个 23000 token 的
        for t3, want in ((10.75, 10.5), (11.7, 10.5), (13.5, 11.5)):
            adapter = VllmAdapter()
            adapter.feed(1.0, Z)
            adapter.feed(10.0, m1)
            adapter.feed(10.5, m2)
            adapter.feed(t3, m3)
            rows = adapter.rows()
            self.assertEqual(len(rows), 1, f"t3={t3}")
            self.assertEqual(rows[0]["phase"], "prefill", f"t3={t3}")
            self.assertEqual(rows[0]["prompt"], 23000, f"t3={t3}")
            self.assertAlmostEqual(rows[0]["start"], want, delta=0.001, msg=f"t3={t3}")
        # 从没有过请求：empty_since 是 None，照常回推。
        adapter = VllmAdapter()
        adapter.feed(1.0, Z)
        adapter.feed(13.5, dict(Z, running=1, queries=23000))
        rows = adapter.rows()
        self.assertEqual(len(rows), 1)
        self.assertAlmostEqual(rows[0]["start"], 11.5, delta=0.001)



from panel.collector import Collector
from panel.config import Config
from panel.engine import EngineReader

METRIC_NAMES = {
    "running": "vllm:num_requests_running", "waiting": "vllm:num_requests_waiting",
    "queries": "vllm:prefix_cache_queries_total", "hits": "vllm:prefix_cache_hits_total",
    "prompt": "vllm:prompt_tokens_total", "prompt_cached": "vllm:prompt_tokens_cached_total",
    "ttft_sum": "vllm:time_to_first_token_seconds_sum", "ttft_count": "vllm:time_to_first_token_seconds_count",
    "generation": "vllm:generation_tokens_total", "success": "vllm:request_success_total",
    "req_prompt_sum": "vllm:request_prompt_tokens_sum", "req_generation_sum": "vllm:request_generation_tokens_sum",
    "req_computed_sum": "vllm:request_prefill_kv_computed_tokens_sum",
    "prefill_s": "vllm:request_prefill_time_seconds_sum", "decode_s": "vllm:request_decode_time_seconds_sum",
    "drafted": "vllm:spec_decode_num_draft_tokens_total", "accepted": "vllm:spec_decode_num_accepted_tokens_total",
    "epoch": "process_start_time_seconds",
}


def metrics_text(m):
    """把一份 vLLM 读数写回 /metrics 文本（repr 保证浮点数原样读回来）。"""
    return "".join(f"{METRIC_NAMES[k]} {m[k]!r}\n" for k in METRIC_NAMES if m.get(k) is not None)


class FakeFetcher:
    """假读取器：texts 是 {路径: 正文或 None}；记下每次调用。"""

    def __init__(self, url, texts=None, health=None, metrics=None, model=None, info=None):
        self.url = url
        self.texts = dict(texts or {})
        self.health_value, self.metrics_value, self.model_value, self.info_value = health, metrics, model, info
        self.calls = []
        self.closed = 0

    def get_text(self, path):
        self.calls.append(("get_text", path))
        return self.texts.get(path)

    def health(self):
        self.calls.append(("health",))
        return self.health_value

    def metrics(self):
        self.calls.append(("metrics",))
        return self.metrics_value

    def model_name(self):
        self.calls.append(("model_name",))
        return self.model_value

    def model_info(self):
        self.calls.append(("model_info",))
        return self.info_value

    def close(self):
        self.closed += 1


def reader_with(fakes):
    """fakes 是 {地址: FakeFetcher}；返回按这些地址的顺序去试的 EngineReader。"""
    return EngineReader(list(fakes), make_fetcher=lambda url: fakes[url])


# 一份真实的 /metrics 原文：B 地址靠它被认成 vLLM
VTEXT = (SEQ_DIR / "metrics-b.txt").read_text(encoding="utf-8")
A = "http://127.0.0.1:8888"
B = "http://127.0.0.1:8000"
TF = '{"ok": true, "backend": "tensorfold", "requests_running": 0}'


class TestEngineReader(unittest.TestCase):
    """EngineReader：认出引擎、只读认出的那个地址、连续 3 次读不到就忘掉。"""

    def vreader(self):
        """A 读不到、B 是 vLLM 的 reader 和 B 的假读取器。"""
        fb = FakeFetcher(B, {"/health": "", "/metrics": VTEXT})
        return reader_with({A: FakeFetcher(A), B: fb}), fb

    def test_all_unreachable(self):
        fa, fb = FakeFetcher(A), FakeFetcher(B)
        reader = reader_with({A: fa, B: fb})
        self.assertIsNone(reader.health())
        self.assertIsNone(reader.engine)
        self.assertIsNone(reader.base_url)
        self.assertIs(reader.metrics_every_tick, False)
        self.assertIsNone(reader.metrics())
        self.assertIsNone(reader.model_name())
        for _ in range(4):
            self.assertIsNone(reader.health())
        self.assertEqual(fa.calls.count(("get_text", "/health")), 5)
        self.assertEqual(fb.calls.count(("get_text", "/health")), 5)
        self.assertEqual((fa.closed, fb.closed), (0, 0))

    def test_recognizes_tensorfold(self):
        fa = FakeFetcher(A, {"/health": TF}, health={"ok": True, "requests_running": 1},
                         metrics={"waiting": 3}, model="m")
        fb = FakeFetcher(B)
        reader = reader_with({A: fa, B: fb})
        self.assertEqual(reader.health(), {"ok": True, "backend": "tensorfold", "requests_running": 0})
        self.assertEqual(reader.engine, "tensorfold")
        self.assertEqual(reader.base_url, A)
        self.assertIs(reader.metrics_every_tick, False)
        self.assertEqual(fb.calls, [])
        self.assertEqual(reader.health(), {"ok": True, "requests_running": 1})  # 走 A.health()
        self.assertEqual(reader.metrics(), {"waiting": 3})
        self.assertEqual(reader.model_name(), "m")

    def test_recognizes_vllm_on_second_url(self):
        reader, fb = self.vreader()
        reader.prepare(5.0, None)
        health = reader.health()
        self.assertEqual(health["backend"], "vllm")
        self.assertEqual(health["requests_total"], 20)
        self.assertEqual(health["completion_tokens_total"], 2036)
        self.assertIn("tfpanel", health)
        self.assertEqual(reader.engine, "vllm")
        self.assertEqual(reader.base_url, B)
        self.assertIs(reader.metrics_every_tick, True)
        got = reader.metrics()
        self.assertEqual(got, {"waiting": 0, "kv_usage": [], "ttft_sum": 0.0, "ttft_count": 0})
        got["waiting"] = 99
        self.assertEqual(reader.metrics()["waiting"], 0)  # 返回的是拷贝
        # 再读一次：B 只多一次 /metrics，A 没有新的调用
        before = len(fb.calls)
        fa = reader._fetchers[A]
        seen = len(fa.calls)
        reader.health()
        self.assertEqual(fb.calls[before:], [("get_text", "/metrics")])
        self.assertEqual(len(fa.calls), seen)

    def test_health_200_but_unrecognized(self):
        # 两个地址都认不出：None
        reader = reader_with({A: FakeFetcher(A, {"/health": "", "/metrics": "tensorfold:requests_waiting 0\n"}),
                              B: FakeFetcher(B)})
        self.assertIsNone(reader.health())
        self.assertIsNone(reader.engine)
        # /health 不是合法的 TensorFold 正文时照样去看 /metrics
        reader = reader_with({A: FakeFetcher(A, {"/health": '{"ok": false}', "/metrics": VTEXT})})
        self.assertEqual(reader.health()["backend"], "vllm")
        self.assertEqual(reader.engine, "vllm")

    def test_forget_after_three_misses(self):
        reader, fb = self.vreader()
        reader.prepare(5.0, None)
        self.assertEqual(reader.health()["backend"], "vllm")
        fa = reader._fetchers[A]
        seen = fa.calls.count(("get_text", "/health"))
        fb.texts["/metrics"] = None
        self.assertIsNone(reader.health())
        self.assertEqual(reader.engine, "vllm")
        self.assertIsNone(reader.health())
        self.assertEqual(reader.engine, "vllm")
        self.assertIsNone(reader.health())
        self.assertIsNone(reader.engine)
        self.assertIsNone(reader.base_url)
        self.assertGreaterEqual(fb.closed, 1)
        self.assertIsNone(reader.health())  # 忘掉之后又从 A 开始试
        self.assertEqual(fa.calls.count(("get_text", "/health")), seen + 1)

    def test_one_read_resets_the_counter(self):
        reader, fb = self.vreader()
        reader.prepare(5.0, None)
        self.assertEqual(reader.health()["backend"], "vllm")
        for _ in range(2):  # 读不到两次
            fb.texts["/metrics"] = None
            self.assertIsNone(reader.health())
        fb.texts["/metrics"] = VTEXT
        self.assertIsNotNone(reader.health())  # 读到一次，计数清零
        fb.texts["/metrics"] = None
        self.assertIsNone(reader.health())
        self.assertIsNone(reader.health())
        self.assertEqual(reader.engine, "vllm")

    def test_forget_tensorfold(self):
        fa = FakeFetcher(A, {"/health": TF}, health={"ok": True, "requests_running": 1})
        reader = reader_with({A: fa, B: FakeFetcher(B)})
        self.assertEqual(reader.health()["backend"], "tensorfold")
        fa.health_value = None
        for _ in range(3):
            self.assertIsNone(reader.health())
        self.assertIsNone(reader.engine)

    def test_adapter_clean_after_forget(self):
        data, samples = load("abort-decode")
        reader, fb = self.vreader()
        last = None
        for t, m in samples[::2]:
            fb.texts["/metrics"] = metrics_text(m)
            reader.prepare(t, None)
            last = reader.health()
        self.assertEqual(last["aborted_total"], 1)
        fb.texts["/metrics"] = None
        for _ in range(3):
            self.assertIsNone(reader.health())
        self.assertIsNone(reader.engine)
        fb.texts["/metrics"] = metrics_text(samples[::2][-1][1])
        self.assertEqual(reader.health()["aborted_total"], 0)

    def test_now_and_tps_go_to_adapter(self):
        data, samples = load("long")
        reader, fb = self.vreader()
        start = None
        for t, m in samples[::2]:
            fb.texts["/metrics"] = metrics_text(m)
            reader.prepare(t, 24085.0)
            health = reader.health()
            if start is None and t >= 3.5058 and health and health.get("tfpanel"):
                streams = health["tfpanel"]["streams"]
                if streams:
                    start = streams[0]["start"]
        self.assertIsNotNone(start)
        self.assertAlmostEqual(start, 2.5058, delta=0.002)
        self.assertEqual(reader.metrics()["ttft_count"], 1)
        self.assertAlmostEqual(reader.metrics()["ttft_sum"], 9.3375, delta=0.001)

    def test_vllm_model_name_and_context(self):
        reader, fb = self.vreader()
        reader.prepare(5.0, None)
        self.assertNotIn("context_length", reader.health())
        fb.info_value = {"id": "Qwen/Qwen3.8-Flash-Next", "max_model_len": 131072}
        self.assertEqual(reader.model_name(), "Qwen/Qwen3.8-Flash-Next")
        self.assertEqual(reader.health()["context_length"], 131072)
        fb.info_value = None
        self.assertIsNone(reader.model_name())

    def test_close_closes_every_fetcher(self):
        fa = FakeFetcher(A)
        reader = reader_with({A: fa, B: FakeFetcher(B, {"/health": "", "/metrics": VTEXT})})
        reader.prepare(5.0, None)
        self.assertEqual(reader.health()["backend"], "vllm")
        reader.close()
        self.assertGreaterEqual(fa.closed, 1)
        self.assertGreaterEqual(reader._fetchers[B].closed, 1)

    def test_default_fetcher_unreachable(self):
        """不传 make_fetcher 时用的是真的 Fetcher：读不到也不抛异常。"""
        self.assertIsNone(EngineReader(["http://127.0.0.1:1"]).health())


def run_pipeline(name, usage=None):
    """适配器和采集器连着跑一段序列：返回 [(时刻, 读数, 快照), …]。"""
    data, samples = load(name)
    adapter = VllmAdapter()
    collector = Collector(Config(), usage)
    out = []
    for t, m in samples[::2]:
        health, metrics = adapter.feed(t, m, collector.prefill_tps, 262144)
        out.append((t, m, collector.feed(t, health, metrics)))
    return out


class RecordingLedger:
    """只记 update 参数的假账本。"""

    def __init__(self):
        self.updates = []

    def today(self):
        return {}

    def update(self, totals):
        self.updates.append(dict(totals))


class TestPipeline(unittest.TestCase):
    """适配器和采集器连起来，对照录制时实际发出的请求。"""

    def first_state(self, runs, state):
        """第一份某种状态的快照，没有就 None。"""
        return next((s for _t, _m, s in runs if s["state"] == state), None)

    def test_short(self):
        runs = run_pipeline("short")
        req = load("short")[0]["requests"][0]
        snap = runs[-1][2]
        self.assertEqual(snap["state"], "done")
        self.assertEqual(snap["engine"], "vllm")
        self.assertEqual(snap["hook"], "ok")
        last = snap["last"]
        self.assertEqual(last["prompt_tokens"], req["prompt_tokens"])
        self.assertEqual(last["completion_tokens"], req["completion_tokens"])
        self.assertEqual(last["cached_tokens"], 0)
        self.assertAlmostEqual(last["ttft_s"], 0.1255, delta=0.001)
        self.assertAlmostEqual(last["decode_tps"], 40 / 0.61455, delta=0.01)

    def test_long(self):
        runs = run_pipeline("long")
        first_pf = self.first_state(runs, "prefill")
        self.assertIs(first_pf["prefill"]["estimated"], True)
        self.assertEqual(first_pf["prefill"]["prompt_tokens"], 24085)
        self.assertEqual(first_pf["prefill"]["cached_tokens"], 0)
        self.assertAlmostEqual(first_pf["prefill"]["elapsed_s"], 2.0, delta=0.01)
        last_pf = next(s for _t, _m, s in reversed(runs) if s["state"] == "prefill")
        self.assertGreaterEqual(last_pf["prefill"]["filled_tokens"] / last_pf["prefill"]["prompt_tokens"], 0.6)
        for _t, _m, snap in runs:
            if snap["state"] == "decode":
                self.assertAlmostEqual(snap["decode"]["ttft_s"], 9.3375, delta=0.001)
        snap = runs[-1][2]
        self.assertEqual(snap["state"], "done")
        last = snap["last"]
        self.assertEqual(last["prompt_tokens"], 24085)
        self.assertEqual(last["cached_tokens"], 0)
        self.assertEqual(last["completion_tokens"], 160)
        self.assertAlmostEqual(last["ttft_s"], 9.3375, delta=0.001)
        self.assertEqual(last["context_used"], 24245)

    def test_followup(self):
        for t, _m, snap in run_pipeline("followup"):
            if snap["prefill"] is not None:
                self.assertFalse(snap["prefill"].get("cache_miss"), f"t={t}")
        last = run_pipeline("followup")[-1][2]["last"]
        self.assertEqual(last["prompt_tokens"], 24126)
        self.assertEqual(last["cached_tokens"], 19584)
        self.assertEqual(last["completion_tokens"], 120)

    def test_aborts(self):
        for name in ("abort-decode", "abort-prefill"):
            runs = run_pipeline(name)
            states = [s["state"] for _t, _m, s in runs]
            self.assertNotIn("done", states, name)
            snap = runs[-1][2]
            self.assertEqual(snap["state"], "idle", name)
            self.assertIsNone(snap["last"], name)
            self.assertEqual(snap["lanes"]["decoding"], 0, name)
            self.assertEqual(snap["lanes"]["prefilling"], 0, name)

    def test_conc5(self):
        runs = run_pipeline("conc5")
        for t, m, snap in runs:
            lanes = snap["lanes"]
            self.assertEqual(lanes["decoding"] + lanes["prefilling"], m["running"], f"t={t}")
        snap = runs[-1][2]
        self.assertEqual(snap["lanes"]["max"], 5)
        self.assertEqual(snap["round"]["requests"], 5)
        self.assertEqual(snap["round"]["output_tokens"], 568)
        self.assertIs(snap["round"]["exact"], False)

    def test_round(self):
        snap = run_pipeline("round")[-1][2]
        self.assertEqual(snap["round"]["requests"], 4)
        self.assertEqual(snap["round"]["output_tokens"], 122)
        self.assertIs(snap["round"]["exact"], True)
        self.assertEqual(snap["last"]["prompt_tokens"], 1646)
        self.assertEqual(snap["last"]["completion_tokens"], 30)

    def test_ledger_totals(self):
        ledger = RecordingLedger()
        run_pipeline("conc3", ledger)
        self.assertTrue(ledger.updates)
        first, last = ledger.updates[0], ledger.updates[-1]
        self.assertEqual(last["prompt"] - first["prompt"], 3199)
        self.assertEqual(last["cached"] - first["cached"], 0)
        self.assertEqual(last["completion"] - first["completion"], 490)
        self.assertEqual(last["requests"] - first["requests"], 3)
        epochs = {u["epoch"] for u in ledger.updates}
        self.assertNotIn(None, epochs)
        self.assertEqual(len(epochs), 1)
