"""参考适配器的单元测试：录音里没走到的分支（任务 O1 照它翻译成 Swift 测试）。

python3 -m unittest docs/tasks/mac/ref/test_omlx_adapter.py -v
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from omlx_adapter import OmlxAdapter  # noqa: E402

WALL0 = 1793330000.0


def status(req=0, prompt=0, cached=0, comp=0, active=0, waiting=0, uptime=100.0, default="M"):
    return {"total_requests": req, "total_prompt_tokens": prompt, "total_cached_tokens": cached,
            "total_completion_tokens": comp, "active_requests": active,
            "waiting_requests": waiting, "uptime_seconds": uptime, "default_model": default}


def stats(*models):
    return {"active_models": {"models": list(models)}}


def model(name="M", waiting=(), prefilling=(), generating=(), loading=None):
    m = {"id": name, "is_loading": loading is not None, "waiting": list(waiting),
         "prefilling": list(prefilling), "generating": list(generating)}
    if loading is not None:
        m.update(loading)
    return m


def w(rid, elapsed, prompt):
    return {"request_id": rid, "queue_position": 1, "elapsed_seconds": elapsed, "prompt_tokens": prompt}


def p(rid, processed, prompt, cached=0, elapsed=0.0):
    return {"request_id": rid, "processed": processed, "total": prompt, "speed": 0.0,
            "elapsed": elapsed, "prompt_tokens": prompt, "cached_tokens": cached}


def g(rid, out, elapsed, prompt):
    return {"request_id": rid, "generated_tokens": out, "elapsed_seconds": elapsed,
            "prompt_tokens": prompt, "max_tokens": 1000}


class TestOmlxAdapter(unittest.TestCase):
    def setUp(self):
        self.ad = OmlxAdapter()
        self.ad.set_models([{"id": "M", "max_model_len": 40960}, {"id": "N", "max_model_len": 8192},
                            {"id": "bad", "max_model_len": True}])

    def feed(self, t, st, sx, uptime_shift=0.0):
        return self.ad.feed(t, WALL0 + t + uptime_shift, st, sx)

    def test_状态不是字典或累计值缺了返回None(self):
        self.assertIsNone(self.feed(0.0, None, stats()))
        self.assertIsNone(self.feed(0.0, 401, stats()))
        bad = status()
        del bad["total_cached_tokens"]
        self.assertIsNone(self.feed(0.0, bad, stats()))
        bad = status()
        bad["total_requests"] = True
        self.assertIsNone(self.feed(0.0, bad, stats()))

    def test_第一次读数带基线和固定字段(self):
        h, m = self.feed(0.0, status(req=3, prompt=100, cached=20, comp=50), stats(model()))
        self.assertEqual(h["backend"], "omlx")
        self.assertIs(h["ok"], True)
        self.assertEqual(h["requests_total"], 3)
        self.assertEqual(h["completion_tokens_total"], 50)
        self.assertEqual(h["completion_finished_total"], 50)
        self.assertEqual(h["streams"], {"decoding": 0, "prefilling": 0, "max": 8})
        self.assertEqual(h["drafted_total"], 0)
        self.assertEqual(h["accepted_total"], 0)
        self.assertEqual(h["epoch"], int(round(WALL0 - 100.0)))
        self.assertEqual(h["context_length"], 40960)
        self.assertEqual(h["usage_totals"], {"prompt": 100, "cached": 20, "completion": 50, "requests": 3})
        self.assertEqual(h["usage_by_model"], {"M": {"prompt": 100, "cached": 20, "completion": 50, "requests": 3}})
        self.assertEqual(h["tfpanel"], {"v": 1, "streams": []})
        self.assertEqual(m, {"waiting": 0, "kv_usage": [], "ttft_sum": 0.0, "ttft_count": 0})
        self.assertNotIn("loading", h)
        self.assertEqual(self.ad.model_name, "M")

    def test_第一次读数里正在解码的行不知道首字时间(self):
        h, _ = self.feed(10.0, status(active=1), stats(model(generating=[g("a", 30, 2.0, 500)])))
        row = h["tfpanel"]["streams"][0]
        self.assertEqual(row["phase"], "decode")
        self.assertEqual(row["start"], 8.0)
        self.assertIsNone(row["ttft_s"])
        self.assertEqual(row["filled"], 500)
        self.assertEqual(h["completion_tokens_total"], 30)

    def test_占位领开始时刻且有占位时不带tfpanel(self):
        self.feed(0.0, status(), stats(model()))
        h, _ = self.feed(1.0, status(active=1), stats(model()))
        self.assertNotIn("tfpanel", h)
        self.assertEqual(h["streams"]["prefilling"], 1)
        self.assertEqual(h["requests_running"], 1)
        h, _ = self.feed(1.1, status(active=1), stats(model()))   # 占位的开始时刻不变
        h, _ = self.feed(1.5, status(active=1), stats(model(prefilling=[p("a", 2048, 9000, elapsed=0.2)])))
        row = h["tfpanel"]["streams"][0]
        self.assertEqual(row["start"], 1.0)
        self.assertEqual(row["filled"], 2048)
        h, _ = self.feed(4.0, status(active=1), stats(model(generating=[g("a", 3, 0.25, 9000)])))
        row = h["tfpanel"]["streams"][0]
        self.assertAlmostEqual(row["ttft_s"], 2.75)
        self.assertEqual(row["cached"], 0)

    def test_排队的行按已等待秒数回推开始时刻且不进tfpanel(self):
        self.feed(0.0, status(), stats(model()))
        h, m = self.feed(2.0, status(active=2, waiting=1),
                         stats(model(waiting=[w("b", 0.5, 300)], generating=[g("a", 5, 0.4, 100)])))
        self.assertEqual(m["waiting"], 1)
        self.assertEqual([r["phase"] for r in h["tfpanel"]["streams"]], ["decode"])
        self.assertEqual(h["requests_running"], 2)
        h, _ = self.feed(3.0, status(active=2), stats(model(prefilling=[p("b", 512, 300, cached=256, elapsed=0.3)],
                                                          generating=[g("a", 9, 1.4, 100)])))
        rows = {r["id"]: r for r in h["tfpanel"]["streams"]}
        self.assertEqual(rows[1]["start"], 1.5)       # 排队的行先编号
        self.assertEqual(rows[1]["cached"], 256)
        self.assertEqual(rows[1]["filled"], 512)
        self.assertEqual(rows[2]["start"], 1.6)

    def test_正常结束记首字和两项累计秒数(self):
        self.feed(0.0, status(), stats(model()))
        self.feed(1.0, status(active=1), stats(model(prefilling=[p("a", 2048, 4000, elapsed=0.5)])))
        self.feed(3.0, status(active=1), stats(model(generating=[g("a", 10, 0.5, 4000)])))
        self.feed(4.0, status(active=1), stats(model(generating=[g("a", 40, 1.5, 4000)])))
        h, m = self.feed(4.2, status(req=1, prompt=4000, comp=45), stats(model()))
        self.assertEqual(m["ttft_count"], 1)
        self.assertAlmostEqual(m["ttft_sum"], 2.0)              # 3.0 − 0.5 − 0.5
        self.assertAlmostEqual(h["prefill_seconds_total"], 2.0)  # 没排队，首字时间全算预填充
        self.assertAlmostEqual(h["decode_seconds_total"], 1.6875)  # 1.5 × 45 / 40：补上最后一次读数之后的那段
        self.assertEqual(h["tfpanel"]["streams"], [])
        self.assertEqual(h["completion_tokens_total"], 45)
        self.assertEqual(h["aborted_total"], 0)

    def test_排队时间不算预填充秒数(self):
        self.feed(0.0, status(), stats(model()))
        self.feed(1.0, status(active=1, waiting=1), stats(model(waiting=[w("a", 0.0, 100)])))
        self.feed(2.0, status(active=1), stats(model(prefilling=[p("a", 50, 100, elapsed=0.4)])))
        self.feed(3.0, status(active=1), stats(model(generating=[g("a", 2, 0.2, 100)])))
        h, m = self.feed(3.5, status(req=1, prompt=100, comp=5), stats(model()))
        self.assertAlmostEqual(m["ttft_sum"], 1.8)                # 3.0 − 0.2 − 1.0
        self.assertAlmostEqual(h["prefill_seconds_total"], 1.2)   # 减去排队的 0.6 秒

    def test_消失后累计请求数晚到也算正常结束(self):
        self.feed(0.0, status(), stats(model()))
        self.feed(1.0, status(active=1), stats(model(generating=[g("a", 5, 0.1, 10)])))
        h, _ = self.feed(1.1, status(active=1), stats(model()))
        self.assertEqual([r["phase"] for r in h["tfpanel"]["streams"]], ["decode"])   # 还留着
        self.assertEqual(h["completion_tokens_total"], 5)
        h, _ = self.feed(1.4, status(req=1, prompt=10, comp=8), stats(model()))
        self.assertEqual(h["tfpanel"]["streams"], [])
        self.assertEqual(h["aborted_total"], 0)
        self.assertEqual(h["completion_tokens_total"], 8)

    def test_消失一秒还没对上算中途断开(self):
        self.feed(0.0, status(), stats(model()))
        self.feed(1.0, status(active=1), stats(model(generating=[g("a", 50, 0.5, 30)])))
        h, _ = self.feed(1.1, status(), stats(model()))
        self.assertEqual(h["aborted_total"], 0)
        h, _ = self.feed(2.05, status(), stats(model()))
        self.assertEqual(h["aborted_total"], 0)
        h, _ = self.feed(2.1, status(), stats(model()))
        self.assertEqual(h["aborted_total"], 1)
        self.assertEqual(h["tfpanel"]["streams"], [])
        self.assertEqual(h["completion_tokens_total"], 50)   # 断开带走的输出照样算
        self.assertEqual(h["completion_finished_total"], 0)
        self.assertEqual(h["usage_totals"], {"prompt": 30, "cached": 0, "completion": 50, "requests": 0})
        self.assertEqual(h["usage_by_model"]["M"], {"prompt": 30, "cached": 0, "completion": 50, "requests": 0})

    def test_排队时断开不计用量(self):
        self.feed(0.0, status(), stats(model()))
        self.feed(1.0, status(active=1, waiting=1), stats(model(waiting=[w("a", 0.2, 900)])))
        self.feed(2.5, status(), stats(model()))
        h, _ = self.feed(3.5, status(), stats(model()))
        self.assertEqual(h["aborted_total"], 1)
        self.assertEqual(h["usage_totals"]["prompt"], 0)

    def test_重新出现的行接着用(self):
        self.feed(0.0, status(), stats(model()))
        self.feed(1.0, status(active=1), stats(model(prefilling=[p("a", 512, 2000, elapsed=0.3)])))
        h, _ = self.feed(1.1, status(active=1), stats(model()))
        self.assertEqual(h["streams"]["prefilling"], 1)
        self.assertEqual(h["requests_running"], 1)
        h, _ = self.feed(1.2, status(active=1), stats(model(generating=[g("a", 1, 0.05, 2000)])))
        rows = h["tfpanel"]["streams"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], 1)
        self.assertEqual(rows[0]["phase"], "decode")

    def test_多条同时结束取最早的且解码行优先(self):
        self.feed(0.0, status(), stats(model()))
        self.feed(1.0, status(active=3), stats(model(prefilling=[p("c", 10, 500, elapsed=0.0)],
                                                     generating=[g("a", 5, 0.5, 100), g("b", 5, 0.2, 200)])))
        h, _ = self.feed(1.2, status(req=1, prompt=100, comp=9, active=2), stats(model()))
        ids = [r["id"] for r in h["tfpanel"]["streams"]]
        self.assertEqual(ids, [1, 3])   # 新行按排队、预填充、解码的顺序编号：c=1、a=2、b=3；a 开始最早，先算它结束

    def test_用量按结束的行的提示长度分到各模型(self):
        self.feed(0.0, status(), stats(model("M"), model("N")))
        self.feed(1.0, status(active=2), stats(model("M", generating=[g("a", 5, 0.5, 300)]),
                                               model("N", generating=[g("b", 5, 0.5, 100)])))
        h, _ = self.feed(1.5, status(req=2, prompt=400, cached=10, comp=21),
                         stats(model("M"), model("N")))
        self.assertEqual(h["usage_by_model"]["M"], {"prompt": 300, "cached": 8, "completion": 16, "requests": 2})
        self.assertEqual(h["usage_by_model"]["N"], {"prompt": 100, "cached": 2, "completion": 5, "requests": 0})
        total = {k: sum(v[k] for v in h["usage_by_model"].values()) for k in ("prompt", "cached", "completion", "requests")}
        self.assertEqual(total, h["usage_totals"])

    def test_没对上行的增量记在最近开始的模型名下(self):
        self.feed(0.0, status(), stats(model("M"), model("N")))
        self.feed(1.0, status(active=1), stats(model("M"), model("N", generating=[g("b", 1, 0.1, 10)])))
        h, _ = self.feed(1.1, status(req=1, prompt=7, comp=3, active=1),
                         stats(model("M"), model("N", generating=[g("b", 2, 0.2, 10)])))
        self.assertEqual(h["usage_by_model"]["N"], {"prompt": 7, "cached": 0, "completion": 3, "requests": 1})
        self.assertEqual(self.ad.model_name, "N")
        self.assertEqual(h["context_length"], 8192)

    def test_累计值变小算重启(self):
        self.feed(0.0, status(req=5, prompt=50, comp=50), stats(model()))
        self.feed(1.0, status(req=5, prompt=50, comp=50, active=1), stats(model(generating=[g("a", 5, 0.5, 10)])))
        h, _ = self.feed(2.0, status(req=0, uptime=1.0), stats(model()))
        self.assertEqual(h["tfpanel"]["streams"], [])
        self.assertEqual(h["completion_tokens_total"], 0)
        self.assertEqual(h["epoch"], int(round(WALL0 + 2.0 - 1.0)))
        self.assertEqual(h["usage_by_model"], {"M": {"prompt": 0, "cached": 0, "completion": 0, "requests": 0}})

    def test_启动时刻抖动不算重启跳得多才算(self):
        h0, _ = self.feed(0.0, status(req=1), stats(model()))
        h1, _ = self.feed(1.0, status(req=1, uptime=100.0), stats(model()), uptime_shift=-0.4)
        self.assertEqual(h1["epoch"], h0["epoch"])
        self.feed(2.0, status(req=1, active=1), stats(model(generating=[g("a", 1, 0.1, 10)])))
        h2, _ = self.feed(3.0, status(req=1, uptime=103.0), stats(model()), uptime_shift=60.0)
        self.assertNotEqual(h2["epoch"], h0["epoch"])
        self.assertEqual(h2["tfpanel"]["streams"], [])
        self.assertEqual(h2["aborted_total"], 0)

    def test_完成输出累计只增不减(self):
        self.feed(0.0, status(), stats(model()))
        h, _ = self.feed(1.0, status(active=1), stats(model(generating=[g("a", 40, 0.5, 10)])))
        self.assertEqual(h["completion_tokens_total"], 40)
        # 累计请求数先跟上、行还在：合计会重复算一次，之后不往回掉
        h, _ = self.feed(1.1, status(req=1, prompt=10, comp=42, active=0), stats(model(generating=[g("a", 42, 0.6, 10)])))
        self.assertEqual(h["completion_tokens_total"], 84)
        h, _ = self.feed(1.2, status(req=1, prompt=10, comp=42), stats(model()))
        self.assertEqual(h["completion_tokens_total"], 84)
        self.assertEqual(h["tfpanel"]["streams"], [])

    def test_加载中带loading字段(self):
        h, _ = self.feed(0.0, status(), stats(model(loading={"loading_elapsed_seconds": 1.5,
                                                             "loading_estimated_seconds": 20,
                                                             "estimated_size": 2 * 1073741824})))
        self.assertEqual(h["loading"], {"model": "M", "elapsed_s": 1.5, "estimated_s": 20.0, "size_gb": 2.0})
        self.assertEqual(self.ad.model_name, "M")
        h, _ = self.feed(0.5, status(), stats(model(loading={"loading_elapsed_seconds": 2.0,
                                                             "loading_estimated_seconds": None,
                                                             "estimated_size": None})))
        self.assertEqual(h["loading"], {"model": "M", "elapsed_s": 2.0, "estimated_s": None, "size_gb": None})
        h, _ = self.feed(1.0, status(), stats(model()))
        self.assertNotIn("loading", h)

    def test_详情读不到时降级(self):
        self.feed(0.0, status(req=1, prompt=5, comp=5), stats(model(loading={"loading_elapsed_seconds": 1.0,
                                                                            "loading_estimated_seconds": 9})))
        h, m = self.feed(0.5, status(req=2, prompt=9, comp=7, active=3, waiting=1), None)
        self.assertNotIn("tfpanel", h)
        self.assertEqual(h["requests_running"], 3)
        self.assertEqual(h["streams"], {"decoding": 2, "prefilling": 0, "max": 8})
        self.assertEqual(m["waiting"], 1)
        self.assertEqual(h["requests_total"], 2)
        self.assertEqual(h["usage_totals"], {"prompt": 5, "cached": 0, "completion": 5, "requests": 1})
        self.assertEqual(h["loading"]["elapsed_s"], 1.5)
        # 详情恢复后，增量照常记账
        h, _ = self.feed(1.0, status(req=2, prompt=9, comp=7), stats(model()))
        self.assertEqual(h["usage_totals"], {"prompt": 9, "cached": 0, "completion": 7, "requests": 2})
        self.assertEqual(h["usage_by_model"]["M"]["requests"], 2)

    def test_上下文上限读不到用默认值(self):
        ad = OmlxAdapter()
        h, _ = ad.feed(0.0, WALL0, status(default="X"), stats())
        self.assertEqual(h["context_length"], 262144)
        self.assertEqual(ad.model_name, "X")

    def test_并发上限可以设(self):
        ad = OmlxAdapter(max_streams=16)
        h, _ = ad.feed(0.0, WALL0, status(), stats())
        self.assertEqual(h["streams"]["max"], 16)


if __name__ == "__main__":
    unittest.main()
