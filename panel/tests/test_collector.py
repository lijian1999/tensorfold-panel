"""任务 E 采集模块的测试。

全部用假时刻，不 sleep；浮点用 assertAlmostEqual 比。
"""

import json
import os
import unittest

from panel.collector import Collector
from panel.config import Config

FIXTURES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "fixtures"
)


def health(running=0, total=0, prompt=0, cached=0, c=0, prefill_s=0.0, decode_s=0.0,
           drafted=0, accepted=0, dec=0, pre=0, maximum=5, context=262144, hook=None):
    """造一份 /health 读数；没给的累计值按 0 给。"""
    data = {
        "ok": True,
        "busy": bool(running or dec or pre),
        "requests_running": running,
        "requests_total": total,
        "completion_tokens_total": c,
        "prompt_tokens_total": prompt,
        "cached_tokens_total": cached,
        "prefill_seconds_total": prefill_s,
        "decode_seconds_total": decode_s,
        "drafted_total": drafted,
        "accepted_total": accepted,
        "streams": {"decoding": dec, "prefilling": pre, "max": maximum},
        "context_length": context,
    }
    if hook is not None:
        data["tfpanel"] = hook
    return data


def every_tenth(start, stop, dt=0.1):
    """从 start 到 stop（两头都含）每隔 dt 秒一个时刻，避开累加带来的误差。"""
    out = []
    t = start
    while t <= stop + 1e-9:
        out.append(round(t, 6))
        t = round(t + dt, 6)
    return out


class FakeUsage:
    """假账本：记下每次收到的 totals；today() 返回固定值；throw 时两个方法都抛。"""

    TODAY = {
        "date": "2026-10-03",
        "prompt_tokens": 8260391,
        "cached_tokens": 5443627,
        "completion_tokens": 185305,
        "requests": 98,
        "cost": 0.597,
    }

    def __init__(self, throw=False):
        self.calls = []
        self.throw = throw

    def update(self, totals):
        if self.throw:
            raise RuntimeError("账本坏了")
        self.calls.append(dict(totals))

    def today(self):
        if self.throw:
            raise RuntimeError("账本坏了")
        return dict(self.TODAY)


def hook_rows(*rows):
    """把外挂行装进 /health 的 tfpanel 字段。"""
    return {"v": 1, "streams": list(rows)}


class Scene:
    """按时刻推进的读数脚本：记下每一次的快照，方便按时刻取。"""

    def __init__(self, collector):
        self.collector = collector
        self.points = []

    def at(self, t, h, metrics=None):
        """在时刻 t 喂一次读数，返回这份快照。"""
        key = round(t, 6)
        snap = self.collector.feed(key, h, metrics=metrics)
        self.points.append((key, snap))
        return snap

    def last_snap(self):
        """最近一次喂出来的快照。"""
        return self.points[-1][1]

    def snap_at(self, t):
        """取时刻 t 上的那份快照（没有就报错，防止断言写错时刻）。"""
        key = round(t, 6)
        for point, snap in self.points:
            if abs(point - key) < 1e-6:
                return snap
        raise AssertionError(f"没有喂过时刻 {t} 的读数")


# 场景 1 的空闲基线
BASE = {
    "total": 97,
    "c": 185105,
    "prompt": 8260333,
    "cached": 5443627,
    "prefill_s": 1457.3376,
    "decode_s": 2848.0993,
    "drafted": 178331,
    "accepted": 124265,
}

# 场景 1 里那个请求结束后的累计值：提示 58、输出 200、解码 3.3507 秒、草稿 171 接受 116
FINISHED = {
    "total": 98,
    "c": 185305,
    "prompt": 8260391,
    "cached": 5443627,
    "prefill_s": 1457.42,
    "decode_s": 2851.45,
    "drafted": 178502,
    "accepted": 124381,
}


def scene1_c(t):
    """场景 1 里 t 时刻的 C：解码中每 0.1 秒加 6，最后一步只加 2，凑够 200。"""
    if t < 10.1:
        return 185105
    if t > 13.4 - 1e-9:
        return 185305
    grown = 6 * (int(round((t - 10.1) * 10)) + 1)
    return 185105 + (grown - 4 if grown > 200 else grown)


def scene1_steps():
    """单个请求的全过程：空闲 → 预填充 → 解码 → 完成 → 空闲。"""
    steps = [(1.0, health(**BASE))]
    steps.append((10.0, health(running=1, pre=1, **BASE)))
    for t in every_tenth(10.1, 13.4):
        steps.append((t, health(running=1, dec=1, **{**BASE, "c": scene1_c(t)})))
    for t in (13.5, 17.4, 17.6, 22.0):
        steps.append((t, health(**FINISHED)))
    return steps


class TestSingleRequest(unittest.TestCase):
    """1. 单个请求的全过程。"""

    def setUp(self):
        self.scene = Scene(Collector(Config()))
        for t, h in scene1_steps():
            self.scene.at(t, h)

    def test_状态依次经过空闲预填充解码完成空闲(self):
        self.assertEqual(self.scene.snap_at(1.0)["state"], "idle")
        self.assertEqual(self.scene.snap_at(10.0)["state"], "prefill")
        self.assertEqual(self.scene.snap_at(10.1)["state"], "decode")
        self.assertEqual(self.scene.snap_at(13.4)["state"], "decode")
        self.assertEqual(self.scene.snap_at(13.5)["state"], "done", "结束后先停 4 秒完成画面")
        self.assertEqual(self.scene.snap_at(17.4)["state"], "done")
        self.assertEqual(self.scene.snap_at(17.6)["state"], "idle")
        self.assertEqual(self.scene.snap_at(22.0)["state"], "idle")
        # 空闲 → 预填充 → 解码 → 完成（停 4 秒）→ 空闲
        self.assertEqual(self.scene.points[1][1]["state"], "prefill")
        self.assertEqual(self.scene.points[2][1]["state"], "decode")
        self.assertEqual(self.scene.points[35][1]["state"], "decode")
        self.assertEqual(self.scene.points[36][1]["state"], "done")
        self.assertEqual(self.scene.points[37][1]["state"], "done")
        self.assertEqual(self.scene.points[38][1]["state"], "idle")
        self.assertEqual(self.scene.points[39][1]["state"], "idle")

    def test_解码中的解码段和本轮(self):
        for t, h in scene1_steps():
            decode = self.scene.snap_at(t)["decode"]
            if not (10.1 <= t <= 13.4):
                self.assertIsNone(decode, f"t={t} 不该有解码段")
                continue
            self.assertEqual(decode["output_tokens"], scene1_c(t) - 185105, f"t={t}")
        decode = self.scene.snap_at(11.0)["decode"]
        self.assertEqual(decode["output_tokens"], 60)
        self.assertAlmostEqual(decode["ttft_s"], 0.1, places=6)
        self.assertEqual(self.scene.snap_at(13.4)["decode"]["output_tokens"], 200)
        self.assertEqual(self.scene.snap_at(11.0)["round"], {
            "requests": 0,
            "running": 1,
            "output_tokens": 60,
            "decode_tps_avg": None,
            "exact": True,
            "elapsed_s": 1.0,
            "active": True,
        })

    def test_结束后的快照(self):
        snap = self.scene.snap_at(13.5)
        last = snap["last"]
        self.assertEqual(last["prompt_tokens"], 58)
        self.assertEqual(last["cached_tokens"], 0)
        self.assertEqual(last["completion_tokens"], 200)
        self.assertAlmostEqual(last["decode_tps"], 200 / 3.3507, places=4)
        self.assertAlmostEqual(last["prefill_tps"], 58 / 0.0824, places=4)
        self.assertAlmostEqual(last["acceptance_rate"], 116 / 171, places=4)
        self.assertAlmostEqual(last["ttft_s"], 0.1, places=6)
        self.assertEqual(last["context_used"], 258)
        self.assertEqual(snap["context_used"], 258)
        self.assertIsNone(snap["decode"])
        self.assertIsNone(snap["prefill"])
        round_snap = snap["round"]
        self.assertEqual(round_snap["requests"], 1)
        self.assertEqual(round_snap["running"], 0)
        self.assertEqual(round_snap["output_tokens"], 200)
        self.assertAlmostEqual(round_snap["decode_tps_avg"], 200 / 3.3507, places=4)
        self.assertIs(round_snap["exact"], True)

    def test_每次成功读数都记进账本(self):
        usage = FakeUsage()
        scene = Scene(Collector(Config(), usage=usage))
        steps = scene1_steps()
        for t, h in steps:
            scene.at(t, h)
        self.assertEqual(len(usage.calls), len(steps))
        self.assertEqual(usage.calls[0],
                         {"prompt": 8260333, "cached": 5443627, "completion": 185105, "requests": 97})
        self.assertEqual(usage.calls[-1],
                         {"prompt": 8260391, "cached": 5443627, "completion": 185305, "requests": 98})


class TestDecodeSpeed(unittest.TestCase):
    """2. 解码速度。"""

    BASE = {"total": 20, "c": 1000, "prompt": 500000, "cached": 300000,
            "prefill_s": 200.0, "decode_s": 500.0, "drafted": 20000, "accepted": 14000}

    def decode_c(self, t):
        """t 时刻的 C：t=5.3 起每 0.1 秒加 6（60 tok/s），涨到 1300 后平 3 秒不涨。"""
        if t <= 5.2:
            return 1000
        if t <= 10.2 + 1e-9:
            return 1000 + 6 * (int(round((t - 5.2) * 10)))
        return 1300

    def test_解码速度(self):
        scene = Scene(Collector(Config()))
        scene.at(1.0, health(**self.BASE))
        scene.at(5.0, health(running=1, pre=1, **self.BASE))
        seen = {}
        for t in every_tenth(5.2, 13.2):
            snap = scene.at(t, health(running=1, dec=1, **{**self.BASE, "c": self.decode_c(t)}))
            self.assertEqual(snap["state"], "decode", f"t={t} 应该还在解码")
            seen[round(t, 6)] = snap["decode"]

        for t in (5.2, 5.3, 5.4, 5.5, 5.6):
            self.assertIsNone(seen[round(t, 6)]["tps_avg"], f"t={t} 的 tps_avg 应该是 None")
        for t in (5.7, 6.2, 7.7):
            decode = seen[round(t, 6)]
            elapsed = round(t - 5.2, 6)
            self.assertAlmostEqual(decode["tps_avg"], (decode["output_tokens"]) / elapsed,
                                   places=4, msg=f"t={t} 的平均速度")
            self.assertAlmostEqual(decode["tps"], 60.0, places=4, msg=f"t={t} 的实时速度")
        for t in (5.2, 5.6, 6.2):
            self.assertEqual(seen[round(t, 6)]["tps_peak"], 0, f"t={t} 的峰值该是 0")

        self.assertAlmostEqual(seen[5.4]["tps"], 24.0, places=4, msg="el=0.2 时 12 / 0.5")
        self.assertAlmostEqual(seen[13.2]["tps"], 0.0, places=4, msg="C 不再增长后速度降到 0")
        peak = max(decode["tps_peak"] for decode in seen.values())
        self.assertAlmostEqual(peak, 60.0, places=4, msg="峰值是出现过的最大速度")
        self.assertAlmostEqual(seen[13.2]["tps_peak"], peak, places=4, msg="峰值不降")
        self.assertAlmostEqual(seen[13.2]["tps_avg"], 300 / 8.0, places=4)
        self.assertEqual(seen[13.2]["output_tokens"], 300)


class TestDecodeRestart(unittest.TestCase):
    """2.9 补充：离开解码再回来时，解码段重新开始算。"""

    BASE = {"total": 20, "prompt": 500000, "cached": 300000,
            "prefill_s": 200.0, "decode_s": 500.0, "drafted": 20000, "accepted": 14000}

    def test_回到解码时段落重新开始(self):
        scene = Scene(Collector(Config()))
        base = self.BASE

        def decode_c(t, start):
            """解码中每 0.1 秒加 6：t=起点时刻时还是 start。"""
            return start + 6 * int(round((t - 5.0) * 10))

        scene.at(1.0, health(**base, c=1000))
        # 第一段解码：5.0 到 7.4，在跑数一直是 1
        for t in every_tenth(5.0, 7.4):
            scene.at(t, health(running=1, dec=1, **{**base, "c": decode_c(t, 1000)}))
        # 7.5 上一个结束、下一个同时到达：在跑数还是 1，但这一条在预填充
        for t in every_tenth(7.5, 7.9):
            scene.at(t, health(running=1, pre=1, **{**base, "total": 21, "c": 1144}))
        # 8.0 起重新解码
        for t in every_tenth(8.0, 8.5):
            scene.at(t, health(running=1, dec=1, **{**base, "total": 21, "c": decode_c(t, 1150)}))

        self.assertEqual(scene.snap_at(7.4)["state"], "decode")
        for t in (7.5, 7.6, 7.7, 7.8, 7.9):
            self.assertEqual(scene.snap_at(t)["state"], "prefill", f"t={t} 没有在解码的流")
            self.assertIsNone(scene.snap_at(t)["decode"], f"t={t} 不该有解码段")
        self.assertEqual(scene.snap_at(8.0)["state"], "decode")

        self.assertAlmostEqual(scene.snap_at(7.4)["decode"]["tps"], 60.0, places=4)
        self.assertAlmostEqual(scene.snap_at(7.4)["decode"]["tps_peak"], 60.0, places=4,
                               msg="第一段解码跑了 2.4 秒，峰值早该记到 60")
        for t in (8.0, 8.1, 8.2, 8.3, 8.4):
            decode = scene.snap_at(t)["decode"]
            self.assertIsNone(decode["tps_avg"], f"t={t} 刚回到解码，平均速度该是 None")
            self.assertEqual(decode["tps_peak"], 0, f"t={t} 的峰值从 0 重新算")
        self.assertAlmostEqual(scene.snap_at(8.5)["decode"]["tps_avg"], 60.0, places=4)


class TestExactTtft(unittest.TestCase):
    """3. 首字的精确值。"""

    def test_精确值盖掉估算值(self):
        scene = Scene(Collector(Config()))
        for t, h in scene1_steps():
            if t <= 17.4 + 1e-9:
                scene.at(t, h)
        self.assertAlmostEqual(scene.snap_at(13.5)["last"]["ttft_s"], 0.1, places=6)
        self.assertAlmostEqual(scene.snap_at(17.4)["last"]["ttft_s"], 0.1, places=6)
        done = health(**FINISHED)
        scene.at(17.5, done, metrics={"waiting": 0, "kv_usage": [0.093899, 0.0],
                                     "ttft_sum": 100.0, "ttft_count": 97})
        snap = scene.at(17.6, done, metrics={"waiting": 0, "kv_usage": [0.093899, 0.0],
                                            "ttft_sum": 100.0824, "ttft_count": 98})
        self.assertAlmostEqual(snap["last"]["ttft_s"], 0.0824, places=6)

    def test_计数变小说明重启(self):
        scene = Scene(Collector(Config()))
        metrics = {"waiting": 0, "kv_usage": [], "ttft_sum": 100.0, "ttft_count": 97}
        scene.at(1.0, health(**BASE))
        scene.at(2.0, health(**BASE), metrics=metrics)
        snap = scene.at(3.0, health(**BASE), metrics={"waiting": 0, "kv_usage": [],
                                                     "ttft_sum": 5.0, "ttft_count": 2})
        self.assertIsNone(snap["last"])
        self.assertEqual(snap["state"], "idle")


class TestOffline(unittest.TestCase):
    """4. 离线。"""

    def scene_with_history(self):
        usage = FakeUsage()
        scene = Scene(Collector(Config(), usage=usage))
        for t, h in scene1_steps():
            if t <= 13.5 + 1e-9:
                scene.at(t, h)
        return scene, usage

    def test_连续三次读不到才进入离线(self):
        scene, usage = self.scene_with_history()
        before = scene.last_snap()
        self.assertIsNotNone(before["last"])
        self.assertEqual(scene.at(13.6, None), before)
        self.assertEqual(scene.at(13.7, None), before)
        used = len(usage.calls)
        offline = scene.at(13.8, None)
        self.assertEqual(offline["state"], "offline")
        self.assertAlmostEqual(offline["offline_s"], 0.2, places=6, msg="离线秒数从第一次失败算起")
        self.assertIsNone(offline["decode"])
        self.assertIsNone(offline["prefill"])
        self.assertIsNone(offline["round"])
        self.assertEqual(offline["last"], before["last"], "last 要保留")
        self.assertEqual(offline["lanes"], {"max": 5, "decoding": 0, "prefilling": 0, "waiting": 0})
        self.assertEqual(len(usage.calls), used, "离线期间不记账")
        back = scene.at(14.0, health(**FINISHED))
        self.assertEqual(back["state"], "idle")
        self.assertIsNone(back["offline_s"])
        self.assertEqual(len(usage.calls), used + 1, "恢复后又开始记账")

    def test_一上来就读不到(self):
        collector = Collector(Config())
        snap = collector.feed(1.0, None)
        self.assertEqual(snap["state"], "offline")
        self.assertEqual(snap["offline_s"], 0.0)
        self.assertIsNone(snap["decode"])
        self.assertIsNone(snap["prefill"])
        self.assertIsNone(snap["round"])
        self.assertIsNone(snap["last"])
        self.assertEqual(snap["memory"], {"used_gb": 0.0, "total_gb": 0.0})
        self.assertEqual(snap["model"], "Qwen3.8-Flash-Next")
        self.assertEqual(snap["context_max"], 262144)
        self.assertEqual(snap["hook"], "missing")
        self.assertEqual(collector.feed(2.0, None)["state"], "offline")


class TestRestart(unittest.TestCase):
    """5. 模型重启。"""

    def test_累计值变小不产生请求结束(self):
        scene = Scene(Collector(Config()))
        for t, h in scene1_steps():
            if t <= 13.5 + 1e-9:
                scene.at(t, h)
        before = scene.last_snap()
        self.assertIsNotNone(before["last"])
        after = scene.at(13.6, health(running=1, dec=1, total=3, c=10, prompt=5000, cached=1000,
                                      prefill_s=2.0, decode_s=4.0, drafted=200, accepted=120))
        self.assertEqual(after["last"], before["last"], "重启不该产生新的请求结束")
        self.assertIsNone(after["round"])
        self.assertEqual(after["state"], "decode")
        self.assertEqual(after["hook"], "missing")


class TestRound(unittest.TestCase):
    """6. 一轮。"""

    FIRST = {"total": 97, "c": 185105, "prompt": 8260333, "cached": 5443627,
             "prefill_s": 1457.3376, "decode_s": 2848.0993, "drafted": 178331, "accepted": 124265}
    SECOND = {"total": 98, "c": 185305, "prompt": 8260391, "cached": 5443627,
              "prefill_s": 1457.42, "decode_s": 2851.45, "drafted": 178502, "accepted": 124381}
    THIRD = {"total": 99, "c": 185479, "prompt": 8260449, "cached": 5443627,
             "prefill_s": 1457.5, "decode_s": 2853.95, "drafted": 178702, "accepted": 124501}

    def test_顺序两个请求算同一轮(self):
        steps = [(1.0, health(**self.FIRST)),
                 (10.0, health(running=1, pre=1, **self.FIRST)),
                 (13.5, health(**self.SECOND)),
                 (18.0, health(running=1, pre=1, **self.SECOND)),
                 (21.0, health(**self.THIRD))]
        scene = Scene(Collector(Config()))
        for t, h in steps:
            scene.at(t, h)
        during = scene.snap_at(18.0)["round"]
        self.assertEqual(during["requests"], 1)
        self.assertEqual(during["running"], 1)
        self.assertIs(during["active"], True)
        after = scene.snap_at(21.0)["round"]
        self.assertEqual(after["requests"], 2)
        self.assertEqual(after["running"], 0)
        self.assertIs(after["exact"], True)
        # 本轮平均 = 两次输出之和 ÷ 两次解码秒数之和
        self.assertAlmostEqual(after["decode_tps_avg"], (200 + 174) / (3.3507 + 2.5), places=4)

    def test_隔了61秒算新一轮(self):
        steps = [(1.0, health(**BASE)), (10.0, health(running=1, pre=1, **BASE)), (13.5, health(**FINISHED))]
        steps += [(t, health(**FINISHED)) for t in every_tenth(14.5, 74.5, dt=1.0)]
        steps.append((74.6, health(running=1, pre=1, **FINISHED)))
        scene = Scene(Collector(Config()))
        for t, h in steps:
            scene.at(t, h)
        idle_long = scene.snap_at(74.5)
        self.assertIs(idle_long["round"]["active"], False, "隔了 61 秒，这一轮该算结束")
        self.assertAlmostEqual(idle_long["round"]["elapsed_s"], 3.5, places=4)
        self.assertAlmostEqual(idle_long["round"]["decode_tps_avg"], 200 / 3.3507, places=4)
        new_round = scene.snap_at(74.6)["round"]
        self.assertEqual(new_round["requests"], 0)
        self.assertEqual(new_round["running"], 1)
        self.assertEqual(new_round["output_tokens"], 0)
        self.assertIs(new_round["active"], True)

    def test_隔了59秒仍是同一轮(self):
        steps = [(1.0, health(**BASE)), (10.0, health(running=1, pre=1, **BASE)), (13.5, health(**FINISHED))]
        steps += [(t, health(**FINISHED)) for t in every_tenth(14.5, 72.4, dt=1.0)]
        steps.append((72.4, health(running=1, pre=1, **FINISHED)))
        scene = Scene(Collector(Config()))
        for t, h in steps:
            scene.at(t, h)
        snap = scene.snap_at(72.4)
        self.assertIs(snap["round"]["active"], True)
        self.assertEqual(snap["round"]["requests"], 1, "还在同一轮里，第二个请求算进同一轮")
        self.assertEqual(snap["round"]["running"], 1)

    def test_上一个结束下一个到达在同一次读数里(self):
        scene = Scene(Collector(Config()))
        for t, h in scene1_steps():
            if t <= 13.4 + 1e-9:
                scene.at(t, h)
        snap = scene.at(13.5, health(running=1, pre=1, **FINISHED))
        self.assertIs(snap["round"]["exact"], True, "刚结束一个，间隔为 0，还算同一轮")
        self.assertEqual(snap["round"]["requests"], 1)
        self.assertEqual(snap["round"]["running"], 1)
        self.assertEqual(snap["last"]["completion_tokens"], 200)


class TestConcurrent(unittest.TestCase):
    """7. 并发。"""

    BASE = {"total": 5, "c": 1000, "prompt": 400000, "cached": 200000,
            "prefill_s": 100.0, "decode_s": 300.0, "drafted": 10000, "accepted": 7000}

    def test_两个请求同时在跑(self):
        base = self.BASE
        scene = Scene(Collector(Config()))
        seen = {}
        seconds = {}
        total = 0.0

        def drive(points):
            """逐条喂读数，同时累加“处在解码状态的时长”。"""
            nonlocal total
            for t, running, dec, c, total_requests in points:
                snap = scene.at(t, health(running=running, dec=dec, **{**base, "c": c, "total": total_requests}))
                if snap["state"] == "decode":
                    total = round(total + 0.1, 6)
                seen[round(t, 6)] = snap
                seconds[round(t, 6)] = total

        def c_list(t1, t2, start, step=6):
            """(时刻, 在跑数, 解码数, C, 请求数)：C 从 start 起每 0.1 秒加 step。"""
            out = []
            c = start
            for t in every_tenth(t1, t2):
                out.append((t, 2, 2, c, 5))
                c += step
            return out

        points = [(20.0, 1, 0, 1000, 5)]                                  # 第一个到达：在预填充
        points += [(t, 1, 1, 1000 + 6 * (i + 1), 5)                        # 第一个单独在解码
                   for i, t in enumerate(every_tenth(20.1, 20.4))]
        points += c_list(20.5, 22.9, 1030)                                 # 第二个到达：两个同时在跑
        points += [(t, 1, 1, 1174 + 6 * (i + 1), 6)                        # 第一个结束：还剩一个
                   for i, t in enumerate(every_tenth(23.0, 24.9))]
        points.append((25.0, 0, 0, 1294, 7))                               # 都结束
        drive(points)

        self.assertIs(seen[20.5]["round"]["exact"], False, "两个同时在跑，本轮不再算精确值")
        self.assertIs(seen[21.1]["round"]["exact"], False)
        self.assertIsNone(seen[20.5]["round"]["decode_tps_avg"], "解码时长不到 0.5 秒时算不出本轮平均")
        # 并发时没有首字时间（这一忙碌段的在跑数峰值是 2）
        self.assertIsNone(seen[21.1]["decode"]["ttft_s"])
        self.assertIsNone(seen[23.1]["decode"]["ttft_s"])
        for t, c_now, seconds_in_decode in ((20.6, 1036, 0.6), (21.1, 1066, 1.1), (23.1, 1186, 3.1)):
            snap = seen[round(t, 6)]
            self.assertAlmostEqual(snap["round"]["decode_tps_avg"], (c_now - 1000) / seconds_in_decode,
                                   places=4, msg=f"t={t}")
        # 一个先结束：还在解码，不进完成
        self.assertEqual(seen[23.0]["state"], "decode")
        self.assertEqual(seen[23.1]["state"], "decode")
        # 都结束才进完成
        self.assertEqual(seen[25.0]["state"], "done")
        # 两个请求的输出之和等于本轮输出
        first = seen[23.0]["last"]["completion_tokens"]
        second = seen[25.0]["last"]["completion_tokens"]
        self.assertEqual(first + second, seen[25.0]["round"]["output_tokens"])
        self.assertAlmostEqual(seconds[23.1], 3.1, places=4)


class TestNoHookPrefill(unittest.TestCase):
    """11. 外挂失效时的预填充画面。"""

    def test_没有外挂时的预填充(self):
        collector = Collector(Config())
        scene = Scene(collector)
        scene.at(1.0, health(**BASE))
        metrics = {"waiting": 0, "kv_usage": [0.093899, 0.0], "ttft_sum": 1599.727361, "ttft_count": 156}
        for t in (10.0, 10.1, 10.2, 10.3, 10.4):
            scene.at(t, health(running=1, pre=1, **BASE), metrics=metrics)
        first = scene.points[-5][1]
        snap = scene.last_snap()
        self.assertEqual(snap["hook"], "missing")
        self.assertEqual(snap["state"], "prefill")
        self.assertAlmostEqual(first["prefill"]["elapsed_s"], 0.0, places=6, msg="从预填充中变出来那次算起")
        self.assertAlmostEqual(snap["prefill"]["elapsed_s"], 0.4, places=6)
        prefill = snap["prefill"]
        self.assertEqual(prefill["prompt_tokens"], 24615)
        self.assertEqual(snap["context_used"], 24615)
        for key in ("cached_tokens", "filled_tokens", "tps", "remaining_s", "est_s"):
            self.assertIsNone(prefill[key], key)
        self.assertIs(prefill["cache_miss"], False)

    def test_排队数取自metrics(self):
        collector = Collector(Config())
        scene = Scene(collector)
        scene.at(1.0, health(**BASE))
        snap = scene.at(2.0, health(running=1, pre=1, **BASE),
                        metrics={"waiting": 2, "kv_usage": [], "ttft_sum": None, "ttft_count": None})
        self.assertEqual(snap["lanes"], {"max": 5, "decoding": 0, "prefilling": 1, "waiting": 2})
        snap = scene.at(3.0, health(running=1, pre=1, **BASE),
                        metrics={"waiting": None, "kv_usage": [], "ttft_sum": None, "ttft_count": None})
        self.assertEqual(snap["lanes"], {"max": 5, "decoding": 0, "prefilling": 1, "waiting": 0})
        snap = scene.at(4.0, health(**BASE))
        self.assertEqual(snap["lanes"], {"max": 5, "decoding": 0, "prefilling": 0, "waiting": 0})


class TestRobustness(unittest.TestCase):
    """13. 健壮性。"""

    def test_缺键不抛异常(self):
        collector = Collector(Config())
        snap = collector.feed(1.0, {"ok": True})
        self.assertEqual(snap["state"], "idle")
        self.assertEqual(snap["context_used"], 0)
        self.assertEqual(snap["lanes"], {"max": 1, "decoding": 0, "prefilling": 0, "waiting": 0})
        json.dumps(snap, ensure_ascii=False)

    def test_账本抛异常不影响feed(self):
        collector = Collector(Config(), usage=FakeUsage(throw=True))
        for t, h in scene1_steps():
            if t <= 13.5 + 1e-9:
                snap = collector.feed(t, h)
                self.assertIn(snap["state"], ("idle", "prefill", "decode", "done"))
                self.assertEqual(snap["today"],
                                 {"date": "", "prompt_tokens": 0, "cached_tokens": 0,
                                  "completion_tokens": 0, "requests": 0, "cost": 0.0},
                                 "today() 抛异常时退回默认空账本（说明 2.12）")

    def test_快照可以转成JSON(self):
        collector = Collector(Config())
        for t, h in scene1_steps():
            snap = collector.feed(t, h)
            self.assertIsInstance(json.loads(json.dumps(snap, ensure_ascii=False)), dict)

    def test_改动返回的字典不影响下一次(self):
        steps = scene1_steps()

        def run(mutate):
            collector = Collector(Config(), usage=FakeUsage())
            snaps = []
            for t, h in steps:
                snap = collector.feed(t, h)
                snaps.append(json.dumps(snap, sort_keys=True, ensure_ascii=False))
                if mutate:
                    snap["last"] = {"坏": 1}
                    snap["round"] = {"坏": 2}
                    snap["today"]["cost"] = 999.0
                    snap["lanes"]["decoding"] = 9
                    snap["memory"]["used_gb"] = 999.0
            return snaps

        self.assertEqual(run(False), run(True))

    def test_顶层键和原型一致(self):
        path = os.path.join(FIXTURES, "idle.json")
        if not os.path.exists(path):
            self.skipTest(f"没有 {path}")
        with open(path, "r", encoding="utf-8") as handle:
            fixture = json.load(handle)
        collector = Collector(Config())
        self.assertEqual(set(collector.feed(1.0, health(**BASE))), set(fixture))


class TestHookPrefill(unittest.TestCase):
    """8. 外挂好用时的预填充。"""

    def filled_at(self, elapsed):
        """预填充开始后的 elapsed 秒里已算到的位置：0.9/1.8/2.7 各涨 2048。"""
        if elapsed < 0.9 - 1e-9:
            return 0
        if elapsed < 1.8 - 1e-9:
            return 2048
        if elapsed < 2.7 - 1e-9:
            return 4096
        return 6144

    def test_一条预填充流(self):
        scene = Scene(Collector(Config()))
        scene.at(1.0, health(**BASE))
        for t in every_tenth(10.0, 12.7):
            filled = self.filled_at(round(t - 10.0, 6))
            row = {"id": 1, "phase": "prefill", "prompt": 24615, "cached": 0, "filled": filled}
            scene.at(t, health(running=1, pre=1, hook=hook_rows(row), **BASE))

        self.assertEqual(scene.snap_at(10.0)["hook"], "ok")
        self.assertEqual(scene.snap_at(10.0)["state"], "prefill")
        early = scene.snap_at(10.5)["prefill"]
        self.assertIsNone(early["tps"], "只进了一个进度点，算不出速度")
        self.assertAlmostEqual(early["remaining_s"], 24615 / 2300 - 0.5, places=4)
        self.assertAlmostEqual(early["est_s"], 10.70, places=2, msg="24615 ÷ 2300")

        first = scene.snap_at(10.9)["prefill"]
        self.assertAlmostEqual(first["tps"], 2048 / 0.9, places=4, msg="2048 ÷ 0.9")
        self.assertAlmostEqual(first["remaining_s"], (24615 - 2048) / (2048 / 0.9), places=4)

        last = scene.snap_at(12.7)["prefill"]
        self.assertAlmostEqual(last["tps"], 6144 / 2.7, places=4, msg="6144 ÷ 2.7")
        self.assertEqual(last["filled_tokens"], 6144)
        self.assertAlmostEqual(last["remaining_s"], (24615 - 6144) / (6144 / 2.7), places=4)
        self.assertAlmostEqual(last["elapsed_s"], 2.7, places=6, msg="预填充计时从这条流第一次被读到算起")
        self.assertEqual(last["prompt_tokens"], 24615)
        self.assertEqual(last["cached_tokens"], 0)
        self.assertEqual(scene.snap_at(12.7)["context_used"], 24615, "上下文占用取占用最大的那条流")

    def test_两条预填充流取之和(self):
        scene = Scene(Collector(Config()))
        scene.at(1.0, health(**BASE))
        for t in every_tenth(10.0, 12.7):
            filled = self.filled_at(round(t - 10.0, 6))
            rows = [{"id": 1, "phase": "prefill", "prompt": 24615, "cached": 2048,
                     "filled": 10240 + filled},
                    {"id": 2, "phase": "prefill", "prompt": 24615, "cached": 0,
                     "filled": 8192 + filled}]
            scene.at(t, health(running=2, pre=2, hook=hook_rows(*rows), **BASE))
        total_tps = 2 * (6144 / 2.7)
        snap = scene.snap_at(12.7)
        prefill = snap["prefill"]
        self.assertEqual(prefill["prompt_tokens"], 49230, "两条流的提示长度之和")
        self.assertEqual(prefill["cached_tokens"], 2048)
        self.assertEqual(prefill["filled_tokens"], 30720, "两条流的已算 token 之和")
        self.assertAlmostEqual(prefill["tps"], total_tps, places=4, msg="两条流的速度之和")
        self.assertAlmostEqual(prefill["elapsed_s"], 2.7, places=6, msg="计时从最早那条流算起")
        self.assertAlmostEqual(prefill["remaining_s"], (49230 - 30720) / total_tps, places=4)
        self.assertEqual(snap["context_used"], 24615, "两条流占用一样")


class TestHookCacheMiss(unittest.TestCase):
    """9. 缓存未命中的判定（只在没出现过并发的一轮里做）。"""

    # 上一个请求：提示 40120、命中 39400（新算 720）
    AFTER_FIRST = {"total": 98, "c": 185305, "prompt": 8300453, "cached": 5483027,
                   "prefill_s": 1457.42, "decode_s": 2851.45, "drafted": 178502,
                   "accepted": 124381}
    # 上一个请求提示只有 3000
    AFTER_SHORT = {"total": 98, "c": 185305, "prompt": 8263333, "cached": 5445627,
                   "prefill_s": 1457.42, "decode_s": 2851.45, "drafted": 178502,
                   "accepted": 124381}

    def test_新算token多才算缓存未命中(self):
        scene = Scene(Collector(Config()))
        big = hook_rows({"id": 1, "phase": "prefill", "prompt": 41230, "cached": 0,
                         "filled": 0})
        scene.at(1.0, health(**BASE))
        scene.at(5.0, health(running=1, pre=1, hook=big, **self.AFTER_FIRST))
        self.assertIs(scene.snap_at(5.0)["prefill"]["cache_miss"], True,
                      "上一个请求提示 40120、这次几乎没复用")

    def test_复用了缓存不算缓存未命中(self):
        scene = Scene(Collector(Config()))
        reused = hook_rows({"id": 1, "phase": "prefill", "prompt": 41230, "cached": 39000,
                            "filled": 0})
        scene.at(1.0, health(**BASE))
        scene.at(5.0, health(running=1, pre=1, hook=reused, **self.AFTER_FIRST))
        self.assertIs(scene.snap_at(5.0)["prefill"]["cache_miss"], False,
                      "39000 个是从缓存复用的，不算未命中")

    def test_提示短于上一个的一半不算(self):
        scene = Scene(Collector(Config()))
        short = hook_rows({"id": 1, "phase": "prefill", "prompt": 5000, "cached": 0,
                           "filled": 0})
        scene.at(1.0, health(**BASE))
        scene.at(5.0, health(running=1, pre=1, hook=short, **self.AFTER_FIRST))
        self.assertIs(scene.snap_at(5.0)["prefill"]["cache_miss"], False,
                      "5000 个比上一个请求的一半还短")

    def test_本轮出现过并发就不判定(self):
        scene = Scene(Collector(Config()))
        big = hook_rows({"id": 1, "phase": "prefill", "prompt": 41230, "cached": 0,
                         "filled": 0},
                        {"id": 2, "phase": "prefill", "prompt": 41230, "cached": 0,
                         "filled": 0})
        scene.at(1.0, health(**BASE))
        scene.at(5.0, health(running=2, pre=2, hook=big, **self.AFTER_FIRST))
        self.assertIs(scene.snap_at(5.0)["round"]["exact"], False, "这一轮已经有两条流同时在跑")
        self.assertIs(scene.snap_at(5.0)["prefill"]["cache_miss"], False,
                      "并发的几个请求各有各的对话，不比上一个")

    def test_上一个请求提示不足4000不算(self):
        scene = Scene(Collector(Config()))
        big = hook_rows({"id": 1, "phase": "prefill", "prompt": 41230, "cached": 0,
                         "filled": 0})
        scene.at(1.0, health(**BASE))
        scene.at(5.0, health(running=1, pre=1, hook=big, **self.AFTER_SHORT))
        self.assertIs(scene.snap_at(5.0)["prefill"]["cache_miss"], False,
                      "上一个请求提示只有 3000，不够判定")


class TestHookDecode(unittest.TestCase):
    """10. 外挂好用时的解码。"""

    ROWS = [{"id": 3, "phase": "decode", "prompt": 18420, "cached": 16384, "output": 312},
            {"id": 4, "phase": "decode", "prompt": 20000, "cached": 2048, "output": 100},
            {"id": 5, "phase": "prefill", "prompt": 61000, "cached": 2048, "filled": 10240}]

    def test_解码中取外挂行的条数(self):
        collector = Collector(Config())
        scene = Scene(collector)
        scene.at(1.0, health(**BASE))
        snap = scene.at(5.0, health(running=3, dec=2, pre=1, hook=hook_rows(*self.ROWS),
                                    **BASE),
                        metrics={"waiting": 2, "kv_usage": [0.5, 0.0],
                                 "ttft_sum": 1599.727361, "ttft_count": 156})
        self.assertEqual(snap["hook"], "ok")
        self.assertEqual(snap["state"], "decode", "有流在解码就是解码中")
        self.assertEqual(snap["lanes"], {"max": 5, "decoding": 2, "prefilling": 1, "waiting": 2})
        decode = snap["decode"]
        self.assertEqual(decode["output_tokens"], 412, "两条解码中的流已输出 312 + 100")
        self.assertEqual(snap["context_used"], 61000, "占用最大的那条是 61000")
        self.assertIsNotNone(snap["prefill"], "解码中仍然看得到在预填充的那条流")
        self.assertEqual(snap["prefill"]["prompt_tokens"], 61000)
        self.assertEqual(snap["prefill"]["cached_tokens"], 2048)
        self.assertEqual(snap["prefill"]["filled_tokens"], 10240)
        self.assertIsNone(snap["prefill"]["tps"], "只进了一个进度点，算不出速度")
        self.assertAlmostEqual(snap["prefill"]["est_s"], (61000 - 2048) / 2300, places=4)
        self.assertIs(snap["prefill"]["cache_miss"], False, "这一轮还没有结束的请求")


class TestPrefillSpeed(unittest.TestCase):
    """12. 平均预填充速度的滚动更新（初始 2300）。"""

    FIRST = {"total": 50, "c": 100000, "prompt": 400000, "cached": 200000,
             "prefill_s": 100.0, "decode_s": 300.0, "drafted": 20000, "accepted": 14000}
    # 新算 20000 个 token、预填充 8 秒，即 2500 tok/s
    SECOND = {"total": 51, "c": 102000, "prompt": 425000, "cached": 205000,
              "prefill_s": 108.0, "decode_s": 304.0, "drafted": 21000, "accepted": 14800}
    # 新算 500 个 token、预填充 0.5 秒：不足 2048，不参与滚动
    THIRD = {"total": 52, "c": 104000, "prompt": 425500, "cached": 205000,
             "prefill_s": 108.5, "decode_s": 306.0, "drafted": 21500, "accepted": 15100}
    ROW = hook_rows({"id": 1, "phase": "prefill", "prompt": 24615, "cached": 0,
                     "filled": 0})

    def test_滚动平均从2300往上滚动(self):
        scene = Scene(Collector(Config()))
        scene.at(1.0, health(**self.FIRST))
        scene.at(5.0, health(**self.SECOND))
        snap = scene.at(5.1, health(running=1, pre=1, hook=self.ROW, **self.SECOND))
        self.assertAlmostEqual(snap["prefill"]["est_s"], 24615 / 2360, places=4,
                               msg="平均预填充速度该滚动到 0.7×2300 + 0.3×2500 = 2360")

    def test_新算不足2048的请求不更新滚动平均(self):
        scene = Scene(Collector(Config()))
        rows = hook_rows({"id": 2, "phase": "prefill", "prompt": 24615, "cached": 0,
                          "filled": 0})
        scene.at(1.0, health(**self.FIRST))
        scene.at(5.0, health(**self.SECOND))
        scene.at(5.1, health(**self.THIRD))
        snap = scene.at(5.2, health(running=1, pre=1, hook=rows, **self.THIRD))
        self.assertAlmostEqual(snap["prefill"]["est_s"], 24615 / 2360, places=4,
                               msg="500 个新算 token 太少，2360 不变")


if __name__ == "__main__":
    unittest.main()
