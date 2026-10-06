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

