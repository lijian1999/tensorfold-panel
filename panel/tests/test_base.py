"""任务 A 基础模块的测试：配置、格式、刻度、视图数据结构。"""

import json
import os
import tempfile
import unittest
from dataclasses import asdict

from panel.config import Config, load_config
from panel.fmt import cost_fmt, date_label, dur_fmt, js_round, pct, split1, tok_fmt
from panel.scale import TICK_FRACS, SCALES, v2f
from panel.view import Bar, Card, Lanes, Seg, View


class TestTokFmt(unittest.TestCase):
    def test_values(self):
        cases = [
            (0, "0"),
            (999, "999"),
            (999.6, "1.0K"),
            (1000, "1.0K"),
            (6000, "6.0K"),
            (6249, "6.2K"),
            (24615, "24.6K"),
            (99949, "99.9K"),
            (99950, "100K"),
            (262144, "262K"),
            (999499, "999K"),
            (999500, "1.00M"),
            (8260391, "8.26M"),
            (9995000, "10.0M"),
            (12345678, "12.3M"),
        ]
        for n, want in cases:
            with self.subTest(n=n):
                self.assertEqual(tok_fmt(n), want)


class TestSplit1(unittest.TestCase):
    def test_values(self):
        self.assertEqual(split1(62.3), ("62", ".3"))
        self.assertEqual(split1(97.2), ("97", ".2"))
        self.assertEqual(split1(5), ("5", ".0"))
        self.assertEqual(split1(107.64), ("107", ".6"))


class TestCostFmt(unittest.TestCase):
    def test_values(self):
        self.assertEqual(cost_fmt(0.597), "$0.60")
        self.assertEqual(cost_fmt(0), "$0.00")
        self.assertEqual(cost_fmt(99.994), "$99.99")
        self.assertEqual(cost_fmt(100), "$100")
        self.assertEqual(cost_fmt(1234.5), "$1235")
        self.assertEqual(cost_fmt(1.5, "¥"), "¥1.50")


class TestDurFmt(unittest.TestCase):
    def test_values(self):
        cases = [
            (0, "0 秒"),
            (46.9, "46 秒"),
            (60, "1 分钟"),
            (132, "2 分钟"),
            (3599, "59 分钟"),
            (3600, "1 小时"),
            (-5, "0 秒"),
        ]
        for sec, want in cases:
            with self.subTest(sec=sec):
                self.assertEqual(dur_fmt(sec), want)


class TestDateLabel(unittest.TestCase):
    def test_values(self):
        self.assertEqual(date_label("2026-10-03"), "10月3日")
        self.assertEqual(date_label("2026-12-25"), "12月25日")
        self.assertEqual(date_label(""), "今日")
        self.assertEqual(date_label("x"), "今日")


class TestPct(unittest.TestCase):
    def test_values(self):
        self.assertEqual(pct(5443627, 8260391), 66)
        self.assertEqual(pct(0, 0), 0)
        self.assertEqual(pct(1, None), 0)
        self.assertEqual(pct(40960, 61200), 67)


class TestJsRound(unittest.TestCase):
    def test_values(self):
        self.assertEqual(js_round(0.5), 1)
        self.assertEqual(js_round(1.5), 2)
        self.assertEqual(js_round(2.5), 3)
        self.assertEqual(js_round(2.4), 2)


class TestV2F(unittest.TestCase):
    def test_decode(self):
        cases = [
            (0, 0),
            (-3, 0),
            (None, 0),
            (25, 0.2),
            (50, 0.4),
            (74, 0.496),
            (100, 0.6),
            (150, 0.7),
            (200, 0.8),
            (300, 1),
            (500, 1),
        ]
        for v, want in cases:
            with self.subTest(v=v):
                self.assertAlmostEqual(v2f(v, "decode"), want, places=6)

    def test_prefill(self):
        self.assertAlmostEqual(v2f(600, "prefill"), 0.2, places=6)
        self.assertAlmostEqual(v2f(2412, "prefill"), 0.804, places=6)
        self.assertAlmostEqual(v2f(3000, "prefill"), 1, places=6)

    def test_scale_data(self):
        self.assertEqual(TICK_FRACS, (0.0, 0.2, 0.4, 0.6, 0.8, 1.0))
        self.assertEqual(SCALES["decode"]["ticks"], (0, 25, 50, 100, 200, 300))
        self.assertEqual(SCALES["prefill"]["ticks"], (0, 600, 1200, 1800, 2400, 3000))
        self.assertEqual(SCALES["decode"]["labels"], ("0", "25", "50", "100", "200", "300"))
        self.assertEqual(SCALES["prefill"]["labels"], ("0", "600", "1.2K", "1.8K", "2.4K", "3K"))


class TestConfig(unittest.TestCase):
    def test_defaults(self):
        expected = {
            "base_url": "",
            "base_urls": ["http://127.0.0.1:8888", "http://127.0.0.1:8000"],
            "monitor_match": "manufacturer",
            "monitor_value": "DRS",
            "round_gap_s": 60.0,
            "prefill_short_s": 3.0,
            "done_hold_s": 4.0,
            "dim_after_s": 1800.0,
            "anim_fps": 10.0,
            "timezone": "America/Los_Angeles",
            "price_input": 0.15,
            "price_cached": 0.016,
            "price_output": 0.47,
            "currency": "$",
            "state_dir": "~/.local/state/tfpanel",
            "model_name": "Qwen3.8-Flash-Next",
        }
        self.assertEqual(asdict(Config()), expected)

    def test_missing_file(self):
        self.assertEqual(load_config("/tmp/tfpanel-tests-不存在.json"), Config())

    def test_not_object(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "array.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("[1,2]")
            self.assertEqual(load_config(path), Config())

    def test_bad_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "bad.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{不是 JSON")
            self.assertEqual(load_config(path), Config())

    def test_anim_fps_default(self):
        self.assertEqual(Config().anim_fps, 10.0)

    def test_anim_fps_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "fps.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write('{"anim_fps": 15}')
            self.assertEqual(load_config(path).anim_fps, 15.0)
            with open(path, "w", encoding="utf-8") as f:
                f.write('{"anim_fps": "快"}')
            self.assertEqual(load_config(path).anim_fps, 10.0)

    def test_overrides(self):
        data = {
            "round_gap_s": 30,
            "price_output": "贵",
            "currency": "¥",
            "monitor_match": "connector",
            "monitor_value": "USB-C-0",
            "不认识": 1,
            "done_hold_s": True,
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            c = load_config(path)
        self.assertEqual(c.round_gap_s, 30.0)
        self.assertEqual(c.price_output, 0.47)
        self.assertEqual(c.currency, "¥")
        self.assertEqual(c.monitor_match, "connector")
        self.assertEqual(c.monitor_value, "USB-C-0")
        self.assertEqual(c.done_hold_s, 4.0)


class TestConfigUrls(unittest.TestCase):
    """接口地址列表：base_url 优先，base_urls 非法就用默认的两个。"""

    DEFAULTS = ["http://127.0.0.1:8888", "http://127.0.0.1:8000"]

    def load(self, data: dict) -> Config:
        """把 data 写成配置文件再读回来。"""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f)
            return load_config(path)

    def test_default_urls(self):
        """默认配置就是两个地址，改返回的列表不影响下一次。"""
        c = Config()
        self.assertEqual(c.urls(), self.DEFAULTS)
        got = c.urls()
        got.append("http://127.0.0.1:9")
        self.assertEqual(c.urls(), self.DEFAULTS)
        self.assertIsNot(c.urls(), c.base_urls)

    def test_only_base_url(self):
        """只写了 base_url：只用这一个地址。"""
        self.assertEqual(self.load({"base_url": "http://127.0.0.1:1"}).urls(), ["http://127.0.0.1:1"])

    def test_only_base_urls(self):
        """只写了 base_urls：就是它，而且是拷贝的一份。"""
        c = self.load({"base_urls": ["http://127.0.0.1:1"]})
        self.assertEqual(c.urls(), ["http://127.0.0.1:1"])
        self.assertIsNot(c.urls(), c.base_urls)

    def test_both(self):
        """两个都写了：base_url 说的算。"""
        c = self.load({"base_url": "http://127.0.0.1:1", "base_urls": ["http://127.0.0.1:2", "http://127.0.0.1:3"]})
        self.assertEqual(c.urls(), ["http://127.0.0.1:1"])

    def test_bad_base_urls(self):
        """写成字符串、空列表、含数字、含空字符串：都用默认的两个地址。"""
        for bad in ("http://127.0.0.1:1", [], ["", "http://127.0.0.1:2"], [1], ["http://127.0.0.1:1", 2], True):
            with self.subTest(bad=bad):
                self.assertEqual(self.load({"base_urls": bad}).urls(), self.DEFAULTS)


class TestView(unittest.TestCase):
    def test_defaults(self):
        v = View()
        self.assertEqual(v.state, "idle")
        self.assertEqual(v.arc, "blank")
        self.assertEqual(v.cards, [])
        self.assertIsNone(v.bar)
        self.assertEqual(v.dim, 1.0)

    def test_round_trip(self):
        v = View(
            state="decode",
            state_name="解码中",
            strip_left="Qwen3.8-Flash-Next",
            strip_right=[Seg("新算 "), Seg("24.6K", "strong"), Seg(" tok")],
            lanes=Lanes(max=6, decoding=3, prefilling=1, waiting=2, offline=True),
            cap="解码速度",
            unit="tok/s",
            pill=True,
            big_int="62",
            big_dec=".3",
            big_whole=True,
            big_size="four",
            big_value=62.3,
            arc="value",
            scale="prefill",
            arc_target=0.496,
            ghost=0.25,
            muted=True,
            bar=Bar(kind="prog", frac=0.6, level="warn", text=[Seg("已算 "), Seg("6.2K", "warn")]),
            cards=[Card("输出", "24.6K", "tok", "", False),
                   Card("缓存命中", "66", "%", "4.0M / 6.1M", True),
                   Card("今日费用", "$0.60", "", "用时 2 分钟")],
            dim=0.4,
            slow_fade=True,
        )
        self.assertEqual(View.from_dict(v.to_dict()), v)
        self.assertIsInstance(v.to_dict()["strip_right"][1], dict)
        self.assertIsInstance(v.to_dict()["lanes"], dict)
        self.assertIsInstance(v.to_dict()["bar"]["text"][0], dict)  # asdict 把嵌套数据类也转成字典
        json.dumps(v.to_dict(), ensure_ascii=False)

    def test_from_empty(self):
        self.assertEqual(View.from_dict({}), View())

    def test_from_partial(self):
        v = View.from_dict({"bar": None, "多余": 1, "cards": [{"label": "输出"}]})
        self.assertEqual(len(v.cards), 1)
        self.assertEqual(v.cards[0], Card(label="输出"))
        self.assertEqual(v.cards[0].label, "输出")
        self.assertIsNone(v.bar)
        self.assertEqual(v.state, "idle")


if __name__ == "__main__":
    unittest.main()
