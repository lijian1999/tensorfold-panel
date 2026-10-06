"""任务 F：视图模型（指标快照 → View）。

每个快照样例都用新建的 ViewModel(Config())，now=100.0。
"""

import json
import unittest
from pathlib import Path

from panel.config import Config
from panel.view import Seg, View
from panel.viewmodel import ViewModel

# 测试文件在 panel/tests/ 下，往上两级就是仓库根目录，fixtures/ 在它下面。
FIXTURES_DIR = Path(__file__).resolve().parents[2] / "fixtures"


def plain(segs):
    """把 Seg 列表拼成纯文字。"""
    return "".join(s.text for s in segs)


def marks(segs):
    """只要非 normal 的段，返回 (文字, 样式)。"""
    return [(s.text, s.style) for s in segs if s.style != "normal"]


def read(name, **overrides):
    """读快照样例，可以顺手改几个字段。"""
    with open(FIXTURES_DIR / f"{name}.json", encoding="utf-8") as f:
        data = json.load(f)
    data.update(overrides)
    return data


def view_of(name, now=100.0, **overrides):
    """用全新的 ViewModel 画一个样例。"""
    return ViewModel(Config()).update(read(name, **overrides), now)


def cards(view):
    """右侧三栏写成 (标签, 数值, 单位, 脚注)。"""
    return [(c.label, c.value, c.unit, c.foot) for c in view.cards]


class FixtureCase(unittest.TestCase):
    """每个样例都检查：恰好三栏、能原样转成字典再转回来。"""

    def check(self, name, now=100.0, **overrides):
        view = view_of(name, now=now, **overrides)
        self.assertEqual(len(view.cards), 3, name)
        self.assertEqual(View.from_dict(view.to_dict()), view, name)
        return view


class TestOffline(FixtureCase):
    def test_offline(self):
        view = self.check("offline")
        self.assertEqual(view.state_name, "引擎离线")
        self.assertEqual(view.strip_left, "")
        self.assertEqual(plain(view.strip_right), "上次模型 Qwen3.8-Flash-Next · TensorFold")
        self.assertEqual(marks(view.strip_right), [])
        self.assertTrue(view.lanes.offline)
        self.assertEqual(view.arc, "off")
        self.assertIsNone(view.bar)
        self.assertEqual(view.big_int, "")
        self.assertEqual(
            cards(view),
            [("今日费用", "$0.60", "", ""),
             ("已离线", "44", "秒", ""),
             ("内存", "9.3", "GB", "共 121 GB")],
        )


class TestIdle(FixtureCase):
    def test_idle(self):
        view = self.check("idle")
        self.assertEqual(view.state_name, "空闲")
        self.assertEqual(view.strip_left, "Qwen3.8-Flash-Next · TensorFold")
        self.assertEqual(plain(view.strip_right), "内存 94.2 / 121 GB")
        self.assertEqual(marks(view.strip_right), [("94.2", "strong")])
        self.assertEqual(view.cap, "今日费用")
        self.assertEqual(view.unit, "美元")
        self.assertEqual(view.big_int, "$0")
        self.assertEqual(view.big_dec, ".60")
        self.assertTrue(view.big_whole)
        self.assertEqual(view.big_size, "cost")
        self.assertEqual(view.arc, "blank")
        self.assertIsNone(view.arc_target)
        self.assertEqual(view.bar.kind, "note")
        self.assertEqual(plain(view.bar.text), "10月3日 · 太平洋时间")
        self.assertFalse(view.muted)
        self.assertAlmostEqual(view.dim, 1.0, places=3)
        self.assertEqual(
            cards(view),
            [("今日输入", "8.26M", "tok", "缓存命中 66%"),
             ("今日输出", "185K", "tok", ""),
             ("今日请求", "98", "次", "上次 63.6 tok/s")],
        )

    def test_idle_nohook(self):
        view = self.check("idle-nohook")
        self.assertEqual(plain(view.strip_right), "外挂未生效 · 内存 94.2 / 121 GB")
        self.assertEqual(marks(view.strip_right),
                         [("外挂未生效", "warn"), ("94.2", "strong")])
        self.assertEqual(view.cap, "今日费用")
        self.assertEqual(view.unit, "美元")
        self.assertEqual(view.big_int, "$0")
        self.assertEqual(view.big_dec, ".60")
        self.assertEqual(view.arc, "blank")
        self.assertEqual(plain(view.bar.text), "10月3日 · 太平洋时间")
        self.assertEqual(
            cards(view),
            [("今日输入", "8.26M", "tok", "缓存命中 66%"),
             ("今日输出", "185K", "tok", ""),
             ("今日请求", "98", "次", "上次 63.6 tok/s")],
        )


class TestPrefill(FixtureCase):
    def test_prefill(self):
        view = self.check("prefill")
        self.assertEqual(view.state_name, "预填充中")
        self.assertEqual(view.strip_left, "")
        self.assertEqual(plain(view.strip_right), "新算 20.2K tok")
        self.assertEqual(marks(view.strip_right), [("20.2K", "strong")])
        self.assertEqual(view.lanes.prefilling, 1)
        self.assertEqual(view.cap, "预填充速度")
        self.assertEqual(view.unit, "tok/s")
        self.assertEqual(view.big_int, "2412")
        self.assertEqual(view.big_dec, "")
        self.assertEqual(view.big_size, "four")
        self.assertEqual(view.arc, "prefill")
        self.assertEqual(view.scale, "prefill")
        self.assertAlmostEqual(view.arc_target, 0.804, places=3)
        self.assertEqual(view.bar.kind, "prog")
        self.assertAlmostEqual(view.bar.frac, 0.8701, places=3)
        self.assertEqual(plain(view.bar.text), "已算 53.2K / 61.2K")
        self.assertEqual(marks(view.bar.text), [("53.2K", "strong")])
        self.assertEqual(
            cards(view),
            [("缓存命中", "67", "%", "41.0K / 61.2K"),
             ("已等待", "5.7", "s", "剩余约 4 s"),
             ("内存", "95.1", "GB", "共 121 GB")],
        )

    def test_prefill_fresh(self):
        view = self.check("prefill-fresh")
        self.assertEqual(plain(view.strip_right), "新算 24.6K tok")
        self.assertEqual(view.big_int, "2354")
        self.assertAlmostEqual(view.bar.frac, 0.5824, places=3)
        self.assertEqual(plain(view.bar.text), "已算 14.3K / 24.6K")
        self.assertEqual(
            cards(view),
            [("缓存命中", "0", "%", "0 / 24.6K"),
             ("已等待", "6.7", "s", "剩余约 5 s"),
             ("内存", "94.4", "GB", "共 121 GB")],
        )

    def test_prefill_miss(self):
        view = self.check("prefill-miss")
        self.assertEqual(plain(view.strip_right),
                        "已用时 5.7 s · 缓存未命中 · 剩余约 13 s")
        self.assertEqual(marks(view.strip_right),
                         [("5.7", "strong"), ("缓存未命中", "warn"), ("13", "strong")])
        self.assertEqual(view.big_int, "2368")
        self.assertEqual(view.arc, "prefill")
        self.assertEqual(plain(view.bar.text), "已算 12.3K / 41.2K")
        self.assertEqual(
            cards(view),
            [("本轮请求", "6", "次", "用时 1 分钟"),
             ("累计输出", "1.8K", "tok", ""),
             ("本轮平均", "61.8", "", "tok/s")],
        )

    def test_prefill_nohook(self):
        view = self.check("prefill-nohook")
        self.assertEqual(plain(view.strip_right), "提示较长，可能需要几秒")
        self.assertEqual(view.cap, "已用时")
        self.assertEqual(view.unit, "秒")
        self.assertEqual(view.big_int, "5")
        self.assertEqual(view.big_dec, ".6")
        self.assertTrue(view.big_whole)
        self.assertEqual(view.big_size, "normal")
        self.assertEqual(view.arc, "rest")
        self.assertEqual(view.scale, "decode")
        self.assertAlmostEqual(view.ghost, 0.4544, places=3)
        self.assertFalse(view.muted)
        self.assertEqual(view.bar.kind, "ctx")
        self.assertEqual(plain(view.bar.text), "上下文 24.6K / 262K")
        self.assertAlmostEqual(view.bar.frac, 0.0939, places=3)
        self.assertEqual(view.bar.level, "normal")
        self.assertEqual(
            cards(view),
            [("输出", "—", "", ""),
             ("首字", "—", "", "等待首个 token"),
             ("内存", "94.4", "GB", "共 121 GB")],
        )
        self.assertTrue(view.cards[0].pending)
        self.assertTrue(view.cards[1].pending)

    def test_prefill_short(self):
        view = self.check("prefill-short")
        self.assertEqual(view.state_name, "预填充中")
        self.assertEqual(view.strip_left, "")
        self.assertEqual(plain(view.strip_right), "已用时 1.2 s")
        self.assertEqual(marks(view.strip_right), [("1.2", "strong")])
        self.assertEqual(view.lanes.prefilling, 1)
        # 其余同 idle：短预填充保持原来的今日统计
        self.assertEqual(view.cap, "今日费用")
        self.assertEqual(view.big_int, "$0")
        self.assertEqual(view.arc, "blank")
        self.assertEqual(
            cards(view),
            [("今日输入", "8.26M", "tok", "缓存命中 66%"),
             ("今日输出", "185K", "tok", ""),
             ("今日请求", "98", "次", "上次 63.6 tok/s")],
        )


class TestDecode(FixtureCase):
    def test_decode(self):
        view = self.check("decode")
        self.assertEqual(view.state_name, "解码中")
        self.assertEqual(plain(view.strip_right), "首字 0.10 s · 内存 94.2 / 121 GB")
        self.assertEqual(marks(view.strip_right),
                         [("0.10", "strong"), ("94.2", "strong")])
        self.assertEqual(view.lanes.decoding, 1)
        self.assertEqual(view.cap, "解码速度")
        self.assertEqual(view.unit, "tok/s")
        self.assertEqual(view.big_int, "74")
        self.assertEqual(view.big_dec, "")
        self.assertAlmostEqual(view.big_value, 74.3, places=3)
        self.assertEqual(view.arc, "value")
        self.assertAlmostEqual(view.arc_target, 0.4972, places=3)
        self.assertEqual(view.bar.kind, "ctx")
        self.assertEqual(plain(view.bar.text), "上下文 441 / 262K")
        self.assertEqual(view.bar.level, "normal")
        self.assertEqual(
            cards(view),
            [("输出", "383", "tok", ""),
             ("平均", "69.7", "", "tok/s"),
             ("峰值", "79", "tok/s", "")],
        )

    def test_decode_multi(self):
        view = self.check("decode-multi")
        self.assertEqual(plain(view.strip_right),
                         "解码 3 · 预填充 1 · 内存 94.9 / 121 GB")
        self.assertEqual(marks(view.strip_right),
                         [("3", "strong"), ("1", "strong"), ("94.9", "strong")])
        self.assertEqual(view.lanes.decoding, 3)
        self.assertEqual(view.lanes.prefilling, 1)
        self.assertEqual(view.lanes.waiting, 0)
        self.assertEqual(view.big_int, "100")
        self.assertEqual(view.arc, "value")
        self.assertEqual(plain(view.bar.text), "上下文 61.0K / 262K")
        self.assertEqual(
            cards(view),
            [("本轮请求", "7", "次", "用时 46 秒"),
             ("累计输出", "1.7K", "tok", ""),
             ("本轮平均", "107.6", "", "tok/s")],
        )

    def test_decode_ctx_warn(self):
        view = self.check("decode-ctx-warn")
        self.assertEqual(plain(view.strip_right), "首字 0.35 s · 内存 97.9 / 121 GB")
        self.assertEqual(view.big_int, "88")
        self.assertEqual(view.bar.level, "warn")
        self.assertAlmostEqual(view.bar.frac, 0.8392, places=3)
        self.assertEqual(plain(view.bar.text), "上下文 220K / 262K")
        self.assertEqual(
            cards(view),
            [("输出", "12.4K", "tok", ""),
             ("平均", "87.9", "", "tok/s"),
             ("峰值", "96", "tok/s", "")],
        )

    def test_queue(self):
        view = self.check("queue")
        self.assertEqual(plain(view.strip_right),
                         "解码 5 · 排队 2 · 内存 94.9 / 121 GB")
        self.assertEqual(view.lanes.decoding, 5)
        self.assertEqual(view.lanes.prefilling, 0)
        self.assertEqual(view.lanes.waiting, 2)
        self.assertEqual(view.big_int, "136")
        self.assertEqual(plain(view.bar.text), "上下文 9.5K / 262K")
        self.assertEqual(
            cards(view),
            [("本轮请求", "9", "次", "用时 17 秒"),
             ("累计输出", "1.4K", "tok", ""),
             ("本轮平均", "128.2", "", "tok/s")],
        )


class TestDone(FixtureCase):
    def test_done(self):
        view = self.check("done")
        self.assertEqual(view.state_name, "完成")
        self.assertEqual(plain(view.strip_right), "首字 0.09 s")
        self.assertEqual(marks(view.strip_right), [("0.09", "strong")])
        self.assertEqual(view.cap, "平均速度")
        self.assertEqual(view.unit, "tok/s")
        self.assertTrue(view.pill)
        self.assertEqual(view.big_int, "97")
        self.assertEqual(view.big_dec, ".2")
        self.assertFalse(view.big_whole)
        self.assertIsNone(view.big_value)
        self.assertEqual(view.arc, "value")
        self.assertAlmostEqual(view.arc_target, 0.5888, places=3)
        self.assertFalse(view.muted)
        self.assertEqual(plain(view.bar.text), "上下文 696 / 262K")
        self.assertEqual(
            cards(view),
            [("输出", "600", "tok", "提示 96 tok"),
             ("缓存命中", "0", "%", "0 tok"),
             ("接受率", "81", "%", "")],
        )


class TestRoundRest(FixtureCase):
    def test_round_rest(self):
        view = self.check("round-rest")
        self.assertEqual(view.state_name, "空闲")
        self.assertEqual(view.strip_left, "")
        self.assertEqual(plain(view.strip_right), "内存 94.2 / 121 GB")
        self.assertEqual(view.cap, "本轮平均")
        self.assertEqual(view.unit, "tok/s")
        self.assertTrue(view.pill)
        self.assertEqual(view.big_int, "62")
        self.assertEqual(view.big_dec, ".3")
        self.assertTrue(view.muted)
        self.assertEqual(view.arc, "rest")
        self.assertAlmostEqual(view.ghost, 0.4492, places=3)
        self.assertEqual(plain(view.bar.text), "上下文 14.5K / 262K")
        self.assertEqual(
            cards(view),
            [("本轮请求", "7", "次", "用时 2 分钟"),
             ("累计输出", "2.3K", "tok", ""),
             ("本轮平均", "62.3", "", "tok/s")],
        )


class TestMemory(FixtureCase):
    """两次 update 之间记住的东西。"""

    def test_short_prefill_keeps_previous_view(self):
        round_modified = {
            "requests": 7, "running": 1, "output_tokens": 2345,
            "decode_tps_avg": 62.3, "exact": True, "elapsed_s": 140,
            "active": True,
        }
        # 先是一轮中间的空隙（本轮统计），再来短预填充：还是本轮统计
        vm = ViewModel(Config())
        vm.update(read("round-rest"), 100.0)
        view = vm.update(read("prefill-short", round=round_modified), 100.0)
        self.assertEqual(view.cap, "本轮平均")
        self.assertTrue(view.muted)
        self.assertEqual(view.state_name, "预填充中")
        self.assertEqual(plain(view.strip_right), "已用时 1.2 s")
        self.assertEqual(view.cards[0].label, "本轮请求")
        self.assertEqual(view.cards[0].value, "8")
        # 之前是今日统计：短预填充也保持今日统计
        vm2 = ViewModel(Config())
        vm2.update(read("idle"), 100.0)
        view2 = vm2.update(read("prefill-short", round=round_modified), 100.0)
        self.assertEqual(view2.cap, "今日费用")

    def test_take_over_stays_taken(self):
        short = {"elapsed_s": 1.0, "prompt_tokens": 24615, "cached_tokens": 0,
                 "filled_tokens": 14336, "tps": 2354.0, "remaining_s": 4.37,
                 "est_s": 0.5, "cache_miss": False}
        # 接管过之后，同一轮预填充里不再退回短预填充画面
        vm = ViewModel(Config())
        vm.update(read("prefill"), 100.0)
        self.assertEqual(vm.update(read("prefill", prefill=short), 100.0).cap,
                         "预填充速度")
        # 中间插一次空闲：重新计时，短预填充不接管
        vm2 = ViewModel(Config())
        vm2.update(read("prefill"), 100.0)
        vm2.update(read("idle"), 100.0)
        self.assertNotEqual(vm2.update(read("prefill", prefill=short), 100.0).cap,
                           "预填充速度")

    def test_slow_fade(self):
        vm = ViewModel(Config())
        vm.update(read("done"), 100.0)
        self.assertTrue(vm.update(read("idle"), 100.0).slow_fade)
        self.assertFalse(vm.update(read("idle"), 101.0).slow_fade)
        vm.update(read("decode"), 102.0)
        self.assertFalse(vm.update(read("idle"), 103.0).slow_fade)

    def test_dim(self):
        config = Config(dim_after_s=1800)
        vm = ViewModel(config)
        cases = [("idle", 0, 1.0), ("idle", 1799, 1.0), ("idle", 1800, 0.4),
                 ("decode", 1801, 1.0), ("idle", 1802, 1.0)]
        for state, now, want in cases:
            with self.subTest(state=state, now=now):
                view = vm.update(read(state), now)
                self.assertAlmostEqual(view.dim, want, places=3)
        # 本轮统计和离线画面不调暗
        vm2 = ViewModel(config)
        vm2.update(read("round-rest"), 0)
        self.assertAlmostEqual(vm2.update(read("round-rest"), 5000).dim, 1.0,
                              places=3)
        vm3 = ViewModel(config)
        vm3.update(read("offline"), 0)
        self.assertAlmostEqual(vm3.update(read("offline"), 5000).dim, 1.0,
                              places=3)


class TestMissingData(FixtureCase):
    """缺字段、空值不能抛异常，缺的写“—”或留空。"""

    def test_idle_without_last(self):
        view = self.check("idle", last=None)
        self.assertEqual(view.cards[2].foot, "")

    def test_decode_missing_values(self):
        decode = {"tps": 74.3, "tps_peak": 0, "tps_avg": None,
                  "output_tokens": 383, "ttft_s": None}
        view = self.check("decode", decode=decode)
        self.assertEqual(view.cards[1].value, "—")
        self.assertTrue(view.cards[1].pending)
        self.assertEqual(view.cards[2].value, "—")
        self.assertTrue(view.cards[2].pending)
        self.assertEqual(plain(view.strip_right), "内存 94.2 / 121 GB")

    def test_done_missing_acceptance(self):
        last = read("done")["last"] | {"acceptance_rate": None}
        view = self.check("done", last=last)
        self.assertEqual(view.cards[2].value, "—")
        self.assertTrue(view.cards[2].pending)

    def test_prefill_missing_tps(self):
        prefill = read("prefill")["prefill"] | {"tps": None}
        view = self.check("prefill", prefill=prefill)
        self.assertEqual(view.big_int, "—")
        self.assertEqual(view.arc_target, 0)

    def test_round_rest_missing_average(self):
        rnd = read("round-rest")["round"] | {"decode_tps_avg": None}
        view = self.check("round-rest", round=rnd)
        self.assertEqual(view.big_int, "—")
        self.assertFalse(view.pill)
        self.assertIsNone(view.ghost)

    def test_context_bar_levels(self):
        view = self.check("decode", context_used=250000)
        self.assertEqual(view.bar.level, "full")
        view = self.check("decode", context_used=300000)
        self.assertEqual(view.bar.frac, 1.0)
        self.assertEqual(plain(view.bar.text), "上下文 262K / 262K")

    def test_offline_over_a_minute(self):
        view = self.check("offline", offline_s=185)
        self.assertEqual(cards(view)[1], ("已离线", "3", "分钟", ""))

    def test_done_inside_a_round(self):
        rnd = {"requests": 3, "running": 0, "output_tokens": 900,
               "decode_tps_avg": 70.0, "exact": True, "elapsed_s": 30,
               "active": True}
        view = self.check("done", round=dict(rnd))
        self.assertTrue(view.muted)
        self.assertEqual(view.cap, "本轮平均")
        self.assertTrue(view.pill)
        self.assertEqual(view.state_name, "完成")
        self.assertEqual(plain(view.strip_right), "首字 0.09 s")
        # 本轮出现过并发：不写首字，改写内存
        view2 = self.check("done", round=dict(rnd, exact=False))
        self.assertFalse(view2.pill)
        self.assertEqual(plain(view2.strip_right), "内存 94.2 / 121 GB")

    def test_back_to_today_after_round(self):
        rnd = read("round-rest")["round"] | {"active": False}
        view = self.check("round-rest", round=rnd)
        self.assertEqual(view.cap, "今日费用")
        self.assertEqual(view.strip_left, "Qwen3.8-Flash-Next · TensorFold")

    def test_empty_snapshots(self):
        for snapshot in ({}, {"state": "prefill"}, {"state": "decode"},
                        {"state": "done"}, {"state": "offline"}):
            with self.subTest(state=snapshot.get("state")):
                view = ViewModel(Config()).update(snapshot, 0.0)
                self.assertEqual(len(view.cards), 3)


class TestSegs(FixtureCase):
    """段与段之间：检查拼出来的纯文字里没有多余空格。"""

    def test_plain_helper(self):
        self.assertEqual(plain([Seg("内存 "), Seg("94.2", "strong"),
                               Seg(" / 121 GB")]), "内存 94.2 / 121 GB")
        self.assertEqual(marks([Seg("内存 ")]), [])


class TestEngineLabel(FixtureCase):
    """模型名只写最后一段，后面标出当前引擎。"""

    def test_idle_vllm(self):
        view = self.check("idle-vllm")
        self.assertEqual(view.strip_left, "Qwen3.8-Flash-Next · vLLM")
        self.assertEqual(plain(view.strip_right), "内存 94.2 / 121 GB")
        self.assertEqual(view.lanes.max, 4)

    def test_offline_vllm(self):
        view = self.check("offline-vllm")
        self.assertEqual(view.strip_left, "")
        self.assertEqual(plain(view.strip_right),
                         "上次模型 Qwen3.8-Flash-Next · vLLM")

    def test_hook_missing_drops_engine(self):
        view = self.check("idle-nohook")
        self.assertEqual(view.strip_left, "Qwen3.8-Flash-Next")

    def test_engine_unknown(self):
        view = self.check("idle", engine=None)
        self.assertEqual(view.strip_left, "Qwen3.8-Flash-Next")
        view = self.check("offline", engine=None)
        self.assertEqual(plain(view.strip_right), "上次模型 Qwen3.8-Flash-Next")

    def test_vllm_never_warns_hook(self):
        view = self.check("idle-vllm", hook="missing")
        self.assertEqual(view.strip_left, "Qwen3.8-Flash-Next · vLLM")
        self.assertEqual(plain(view.strip_right), "内存 94.2 / 121 GB")

    def test_model_falls_back_to_config(self):
        view = self.check("idle", model=None)
        self.assertEqual(view.strip_left, "Qwen3.8-Flash-Next · TensorFold")


class TestPrefillEstimated(FixtureCase):
    """估算版预填充（vLLM）：标“近期平均”，进度按时间估算。"""

    def test_prefill_est(self):
        view = self.check("prefill-est")
        self.assertEqual(view.state_name, "预填充中")
        self.assertEqual(view.cap, "预填充速度")
        self.assertEqual(view.unit, "tok/s")
        self.assertTrue(view.pill)
        self.assertEqual(view.pill_kind, "avg")
        self.assertEqual(view.big_int, "2200")
        self.assertEqual(view.big_size, "four")
        self.assertEqual(view.arc, "prefill")
        self.assertEqual(view.scale, "prefill")
        self.assertAlmostEqual(view.arc_target, 0.7333, places=3)
        self.assertEqual(view.bar.kind, "prog")
        self.assertAlmostEqual(view.bar.frac, 0.3696, places=3)
        self.assertEqual(plain(view.bar.text), "已算约 14.7K / 39.9K")
        self.assertEqual(marks(view.bar.text), [("14.7K", "strong")])
        self.assertEqual(plain(view.strip_right), "新算 39.9K tok")
        self.assertEqual(
            cards(view),
            [("缓存命中", "0", "%", "0 / 39.9K"),
             ("已等待", "6.7", "s", "剩余约 12 s"),
             ("内存", "94.4", "GB", "共 121 GB")],
        )
        self.assertEqual(view.lanes.max, 4)
        self.assertEqual(view.lanes.prefilling, 1)

    def test_prefill_est_inside_a_round(self):
        with open(FIXTURES_DIR / "prefill-miss.json", encoding="utf-8") as f:
            miss = json.load(f)
        view = self.check("prefill-est", round=miss["round"])
        self.assertEqual(plain(view.strip_right),
                         "已用时 6.7 s · 缓存命中 0% · 剩余约 12 s")
        self.assertEqual([c.label for c in view.cards],
                         ["本轮请求", "累计输出", "本轮平均"])

    def test_prefill_est_almost_done(self):
        base = read("prefill-est")["prefill"]
        view = self.check("prefill-est",
                          prefill=dict(base, elapsed_s=30.0,
                                       filled_tokens=39485, remaining_s=0.0))
        self.assertEqual(cards(view)[1], ("已等待", "30.0", "s", "剩余约 1 s"))
        self.assertAlmostEqual(view.bar.frac, 0.99, places=2)

    def test_tensorfold_prefill_unchanged(self):
        view = self.check("prefill")
        self.assertFalse(view.pill)
        self.assertEqual(view.pill_kind, "exact")
        self.assertEqual(plain(view.bar.text), "已算 53.2K / 61.2K")
        view = self.check("done")
        self.assertTrue(view.pill)
        self.assertEqual(view.pill_kind, "exact")


if __name__ == "__main__":
    unittest.main()
