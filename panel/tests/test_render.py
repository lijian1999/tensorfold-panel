"""任务 H：绘制（render）。

需要 cairo 和 gi 里的 Pango / PangoCairo；没有这两样（例如 MacBook Pro）
的机器上整个文件跳过。
"""

import json
import math
import tempfile
import time
import unittest
from pathlib import Path

try:
    import cairo
    import gi
    gi.require_version("Pango", "1.0")
    gi.require_version("PangoCairo", "1.0")
    from gi.repository import Pango, PangoCairo
except Exception:                      # 没有 gi / cairo：整个文件跳过
    raise unittest.SkipTest("没有 gi / cairo")

from panel.anim import Animator, Frame
from panel.config import Config
from panel.render import draw, render_png
from panel.view import Bar, Card, Lanes, Seg, View
from panel.viewmodel import ViewModel

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"

BG = (10, 11, 13)
CARD = (20, 22, 26)
TRACK = (29, 32, 37)
TEXT = (243, 244, 246)
TEXT_2 = (167, 173, 182)
ACCENT = (118, 226, 183)
AMBER = (240, 180, 76)
DANGER = (226, 122, 114)
TOL = 3


def read_fixture(name):
    """读快照样例，变成 View。"""
    with open(FIXTURES / f"{name}.json", encoding="utf-8") as f:
        snapshot = json.load(f)
    return ViewModel(Config()).update(snapshot, 0.0)


def paint(name, path):
    """把一个样例画到文件里。"""
    render_png(read_fixture(name), str(path))


def pixel(surface, x, y):
    """取一个像素的 (R, G, B)。cairo 内存里每像素 4 字节，顺序是 B、G、R、A。"""
    data = surface.get_data()
    offset = y * surface.get_stride() + x * 4
    return (data[offset + 2], data[offset + 1], data[offset])


def same(color, expect, tol=TOL):
    """每个通道允许 3 以内的误差。"""
    return all(abs(a - b) <= tol for a, b in zip(color, expect))


def row_brightest(surface, y, x0, x1):
    """一行里最亮的像素（用来判断文字写出来没有、是什么颜色）。"""
    best = (0, 0, 0)
    for x in range(x0, x1):
        p = pixel(surface, x, y)
        if sum(p) > sum(best):
            best = p
    return best


def ring_pixel(f, radius=124):
    """圆弧上位置 f 对应的像素（960×640 图里，取圆弧中间那条线）。"""
    a = math.radians(135 + 270 * f)
    x = (166 + radius * math.cos(a)) * 2
    y = (184 + radius * math.sin(a)) * 2
    return int(round(x)), int(round(y))


def surface_of(name):
    """把样例画到内存图片上并读回来。"""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / f"{name}.png"
        paint(name, path)
        return cairo.ImageSurface.create_from_png(str(path))


class DrawCrash(unittest.TestCase):
    """一、每个样例都能画出来，尺寸是 960×640。"""

    def test_every_fixture(self):
        names = sorted(p.stem for p in FIXTURES.glob("*.json"))
        self.assertTrue(names)
        with tempfile.TemporaryDirectory() as tmp:
            for name in names:
                with self.subTest(样例=name):
                    path = Path(tmp) / f"{name}.png"
                    paint(name, path)
                    self.assertTrue(path.is_file())
                    back = cairo.ImageSurface.create_from_png(str(path))
                    self.assertEqual((back.get_width(), back.get_height()),
                                     (960, 640))


class DrawPixels(unittest.TestCase):
    """二、取像素检查颜色。"""

    def test_background(self):
        """整屏底色，以及每张卡片里没有字的地方是卡片底色。"""
        names = sorted(p.stem for p in FIXTURES.glob("*.json"))
        for name in names:
            with self.subTest(样例=name):
                surface = surface_of(name)
                self.assertEqual(pixel(surface, 4, 4), BG,
                                 f"{name} 的 (4, 4) 不是底色")
                for i in range(3):
                    y0 = int((40 + 91.33 * i) * 2)   # 第 i 张卡片顶边（960×640 图的像素坐标）
                    # 每卡四内角：在填充区内、上文字块的上下两行，取在没字的地方
                    for x, y in ((700, y0 + 12), (926, y0 + 12),
                                 (700, y0 + 158), (926, y0 + 158)):
                        got = pixel(surface, x, y)
                        if not same(got, CARD):
                            self.fail(f"{name} 卡片 {i} 的 "
                                      f"({x}, {y}) 是 {got}，不是卡片底色")

    def test_card_points(self):
        """每张卡片左上角那一小块，取在卡片里、没有字的地方。"""
        for name in sorted(p.stem for p in FIXTURES.glob("*.json")):
            with self.subTest(样例=name):
                surface = surface_of(name)
                for i in range(3):
                    y = int(round((40 + 91.33 * i + 4) * 2))
                    got = pixel(surface, 700, y)
                    self.assertTrue(same(got, CARD),
                                    f"{name} 卡片 {i} 的 (700, {y}) 是 {got}")

    def test_decode_arc(self):
        """解码：f=0.25 是薄荷绿，f=0.9 只剩底环。"""
        surface = surface_of("decode")
        x, y = ring_pixel(0.25)
        self.assertTrue(same(pixel(surface, x, y), ACCENT),
                        f"解码圆弧 f=0.25 是 {pixel(surface, x, y)}")
        x, y = ring_pixel(0.9)
        self.assertTrue(same(pixel(surface, x, y), TRACK),
                        f"解码圆弧 f=0.9 是 {pixel(surface, x, y)}")

    def test_prefill_arc(self):
        """预填充：f=0.25 是琥珀色。"""
        surface = surface_of("prefill")
        x, y = ring_pixel(0.25)
        self.assertTrue(same(pixel(surface, x, y), AMBER),
                        f"预填充圆弧 f=0.25 是 {pixel(surface, x, y)}")

    def test_idle_arc(self):
        """空闲：f=0.25 是半透明的底环，既不是薄荷绿也不是纯底色。"""
        surface = surface_of("idle")
        x, y = ring_pixel(0.25)
        got = pixel(surface, x, y)
        self.assertFalse(same(got, ACCENT), f"空闲圆弧 f=0.25 是 {got}")
        self.assertFalse(same(got, BG), f"空闲圆弧 f=0.25 是 {got}")

    def test_offline_dot(self):
        """离线：状态条上只有一个红点。"""
        surface = surface_of("offline")
        got = pixel(surface, 36, 46)
        self.assertTrue(same(got, DANGER), f"离线红点是 {got}")

    def test_tick_50(self):
        """刻度数字：解码的“50”处（f=0.4，半径 R+20）附近有比背景亮的像素；空闲同一小块全是背景。"""
        a = math.radians(135 + 270 * 0.4)
        cx = round((166 + (124 + 20) * math.cos(a)) * 2)
        cy = round((184 + (124 + 20) * math.sin(a)) * 2)

        def block(s):
            """“50”位置周围 24×16 的小块。"""
            return [pixel(s, x, y)
                    for x in range(cx - 12, cx + 12)
                    for y in range(cy - 8, cy + 8)]

        dec = surface_of("decode")
        self.assertTrue(any(max(p) > 80 for p in block(dec)),
                        "解码里“50”那一小块没有一个明显比背景亮的像素")
        idle = surface_of("idle")
        self.assertTrue(all(same(p, BG) for p in block(idle)),
                        "空闲里“50”那一小块不是纯背景（刻度不该显示）")

    def test_muted_is_gray(self):
        """灰色画面（一轮空隙）：主数字和卡片数值都是灰的。"""
        gray = surface_of("round-rest")
        bright = surface_of("idle")
        x0, x1 = 220, 444                       # 主数字那一行
        self.assertTrue(same(row_brightest(gray, 370, x0, x1), TEXT_2),
                        f"灰色画面的主数字是 {row_brightest(gray, 370, x0, x1)}")
        self.assertTrue(same(row_brightest(bright, 370, x0, x1), TEXT),
                        f"正常画面的主数字是 {row_brightest(bright, 370, x0, x1)}")
        for i in range(3):                      # 三张卡片的数值那一行
            y0 = 40 + 91.33 * i
            top = y0 + (85.33 - 73.4) / 2
            y = int(round((top + 16 + 17) * 2))
            self.assertTrue(same(row_brightest(gray, y, 698, 912), TEXT_2),
                            f"灰色画面卡片 {i} 的数值是 "
                            f"{row_brightest(gray, y, 698, 912)}")
            self.assertTrue(same(row_brightest(bright, y, 698, 912), TEXT),
                            f"正常画面卡片 {i} 的数值是 "
                            f"{row_brightest(bright, y, 698, 912)}")


    def test_avg_pill(self):
        """“近期平均”是琥珀色的：估算版预填充的标题行里有，TensorFold 的预填充里没有。"""
        def has_amber(s):
            """y=256 这一行里有没有琥珀色像素（标题后面那个标记）。"""
            return any(all(abs(a - b) <= 12 for a, b in zip(pixel(s, x, 256), AMBER))
                       for x in range(380, 530))
        est = surface_of("prefill-est")
        self.assertTrue(has_amber(est),
                        "prefill-est 里没有琥珀色的“近期平均”")
        std = surface_of("prefill")
        self.assertFalse(has_amber(std),
                         "prefill（TensorFold）里出现了琥珀色像素")


class DrawRobust(unittest.TestCase):
    """三、draw 对任何 View 都不能抛异常。"""

    def test_views(self):
        views = [
            View(),
            View(cards=[]),
            View(state="offline"),
            View(big_int="", big_dec=""),
            View(big_int="$", big_dec="0.60", big_size="cost",
                 big_whole=True, state="idle"),
            View(bar=Bar("ctx", 0.5, "normal", [Seg("上下文 "), Seg("6.2K", "strong")])),
            View(bar=Bar("ctx", 0.9, "warn", [Seg("上下文 ", "warn"), Seg("262K", "warn")])),
            View(bar=Bar("ctx", 0.99, "full", [])),
            View(bar=Bar("prog", 0.0, "normal", [Seg("已算 ")])),
            View(bar=Bar("note", 0.0, "normal", [Seg("10月4日 · 太平洋时间")])),
            View(bar=Bar("note", 0.0, "normal", [])),
            View(cards=[Card(), Card(label="内存", value="94.2", unit="GB",
                                    foot="共 121 GB", pending=True),
                        Card(label="本轮平均", value="62.3", foot="tok/s")]),
            View(state="offline", muted=True, dim=0.4,
                 strip_right=[Seg("内存 "), Seg("9.3", "strong"), Seg(" GB")],
                 cards=[Card("今日费用", "$0.60", "", "")]),
            View(lanes=Lanes(max=5, decoding=3, prefilling=1, waiting=2)),
            View(lanes=Lanes(max=0, offline=True), state="offline"),
        ]
        frames = [
            Frame(),
            Frame(dim=0.4),
            Frame(track_alpha=0.5, notch_alpha=0.5, ghost_alpha=0.5,
                  value_alpha=0.5, ticks_alpha=0.5, center_alpha=0.5,
                  stats_alpha=0.5, strip_alpha=0.5, pulse_dec=0.5,
                  pulse_pre=0.5, arc_frac=0.6, arc_mix=0.5,
                  bar_frac=0.7),
        ]
        surface = cairo.ImageSurface(cairo.FORMAT_RGB24, 960, 640)
        cr = cairo.Context(surface)
        for view in views:
            for frame in frames:
                for size in ((960, 640), (480, 320)):
                    try:
                        draw(cr, view, frame, *size)
                    except Exception as exc:          # 不允许抛异常
                        self.fail(f"画 {view.state} 时抛了 {exc!r}")
        cr.save()
        draw(cr, View(state="decode", muted=True, dim=0.4), Animator.settled(
            read_fixture("decode")))
        cr.restore()

    def test_context_state(self):
        """四、画完之后 cairo 上下文和画之前一样。"""
        surface = cairo.ImageSurface(cairo.FORMAT_RGB24, 960, 640)
        cr = cairo.Context(surface)
        cr.scale(2, 2)

        def state():
            m = cr.get_matrix()
            return ((m.xx, m.yx, m.xy, m.yy, m.x0, m.y0), cr.get_operator(),
                    cr.get_tolerance(), type(cr.get_source()).__name__)

        before = state()
        view = read_fixture("decode")
        draw(cr, view, Animator.settled(view))
        self.assertEqual(state(), before, "画完之后 cairo 状态没还原")


class DrawSpeed(unittest.TestCase):

    def test_hundred_frames(self):
        """五、同一个画面画 100 次，总共不超过 2 秒。"""
        view = read_fixture("decode-multi")
        frame = Animator.settled(view)
        surface = cairo.ImageSurface(cairo.FORMAT_RGB24, 960, 640)
        cr = cairo.Context(surface)
        draw(cr, view, frame)                         # 先热身一次
        start = time.perf_counter()
        for _ in range(100):
            draw(cr, view, frame)
        used = time.perf_counter() - start
        self.assertLess(used, 2.0, f"画 100 次用了 {used:.2f} 秒")


if __name__ == "__main__":
    unittest.main()
