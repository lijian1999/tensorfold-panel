"""任务 G：动画（Animator / Frame）测试。全部用假时刻，不 sleep。"""

import math
import unittest

from panel.anim import Animator, Frame
from panel.view import Bar, Card, Lanes, Seg, View

STEP = 1 / 30  # 动画时约每秒 30 帧


def times(start, count, step=STEP):
    """从 start 起连续 count 帧的时刻（包含 start 那一帧）。"""
    return [start + i * step for i in range(count)]


def feed(animator, view, moments):
    """把同一个 View 按给定时刻逐帧喂进去，返回每一帧的 Frame。"""
    return [animator.step(view, t) for t in moments]


def cards(*labels):
    """三张右侧卡片，只给标签，数值一律相同。"""
    return [Card(label=label, value="6.2K") for label in labels]


class TestSettled(unittest.TestCase):
    """1. settled：所有动画走完时的那一帧。"""

    ALPHA_FIELDS = ("value_alpha", "ghost_alpha", "ticks_alpha",
                    "track_alpha", "notch_alpha")

    def test_alpha_table(self):
        """六种 arc 的各部分不透明度按任务给的表。"""
        cases = [
            ("value", (1, 0, 1, 1, 1)),
            ("prefill", (1, 0, 1, 1, 1)),
            ("rest", (0, 0.9, 0.75, 1, 1)),
            ("blank", (0, 0, 0, 0.5, 0)),
            ("off", (0, 0, 0, 0.5, 0)),
        ]
        for arc, want in cases:
            with self.subTest(arc=arc):
                view = View(arc=arc, arc_target=0.4, ghost=0.2)
                frame = Animator.settled(view)
                got = tuple(getattr(frame, name) for name in self.ALPHA_FIELDS)
                for value, expect in zip(got, want):
                    self.assertAlmostEqual(value, expect, delta=1e-9)

    def test_rest_without_ghost(self):
        """ghost 为 None 时灰点不画（不透明度 0）。"""
        frame = Animator.settled(View(arc="rest", ghost=None))
        self.assertEqual(frame.ghost_alpha, 0)

    def test_fields(self):
        """其余字段：圆弧位置 / 颜色、主数字、条、三块、脉冲、亮度。"""
        view = View(state="decode", state_name="解码", cap="解码速度", unit="tok/s",
                    big_int="62", big_dec=".3", big_whole=True,
                    arc="prefill", arc_target=0.4,
                    bar=Bar("prog", 0.3), dim=0.4)
        frame = Animator.settled(view)
        self.assertAlmostEqual(frame.arc_frac, 0.4, delta=1e-9)
        self.assertAlmostEqual(frame.arc_mix, 1.0, delta=1e-9)   # prefill 才是琥珀色
        self.assertEqual((frame.big_int, frame.big_dec), ("62", ".3"))
        self.assertAlmostEqual(frame.bar_frac, 0.3, delta=1e-9)
        for name in ("center_alpha", "stats_alpha", "strip_alpha", "pulse_dec", "pulse_pre"):
            self.assertAlmostEqual(getattr(frame, name), 1.0, delta=1e-9, msg=name)
        self.assertAlmostEqual(frame.dim, 0.4, delta=1e-9)

    def test_defaults(self):
        """arc_target 为 None → arc_frac 0；没有 bar → bar_frac 0；不忙。"""
        frame = Animator.settled(View(arc="blank", arc_target=None, bar=None))
        self.assertEqual(frame.arc_frac, 0)
        self.assertEqual(frame.bar_frac, 0)
        self.assertIs(frame.animating, False)


class TestFirstStep(unittest.TestCase):
    """2. 第一次 step 等于 settled（脉冲除外），三块不透明度都是 1。"""

    def test_matches_settled(self):
        views = [
            View(arc="value", arc_target=0.5, bar=Bar("ctx", 0.3)),
            View(arc="prefill", arc_target=0.2),
            View(arc="rest", ghost=0.3, dim=0.4),
            View(arc="blank", dim=0.4),
            View(arc="off", state="offline", lanes=Lanes(offline=True)),
        ]
        for view in views:
            with self.subTest(arc=view.arc, state=view.state):
                got = Animator().step(view, 100.0)
                want = Animator.settled(view)
                for name in Frame.__dataclass_fields__:
                    if name in ("pulse_dec", "pulse_pre", "animating"):
                        continue
                    self.assertAlmostEqual(
                        getattr(got, name), getattr(want, name), delta=1e-9,
                        msg=f"{name} 应与 settled 一致")

    def test_three_blocks_start_at_one(self):
        """第一次调用不淡入：中间、右侧三栏、状态条都是 1。"""
        view = View(state="decode", state_name="解码", cap="解码速度", unit="tok/s",
                    big_int="62", big_dec=".3", cards=cards("上下文", "今日", "费用"))
        frame = Animator().step(view, 0.0)
        self.assertEqual((frame.center_alpha, frame.stats_alpha, frame.strip_alpha),
                         (1.0, 1.0, 1.0))


class TestArcEasing(unittest.TestCase):
    """3. 圆弧位置的缓动。"""

    def test_monotonic_and_value_after_0_4s(self):
        animator = Animator()
        animator.step(View(arc="value", arc_target=0.2), 0.0)
        frames = feed(animator, View(arc="value", arc_target=0.8), times(STEP, 12))
        values = [frame.arc_frac for frame in frames]
        for a, b in zip(values, values[1:]):
            self.assertLess(a, b)      # 一路变大，中间不回头
        self.assertAlmostEqual(values[-1], 0.2 + 0.6 * (1 - math.exp(-1)), delta=0.01)

    def test_done_after_5s_and_not_animating(self):
        animator = Animator()
        animator.step(View(arc="value", arc_target=0.2), 0.0)
        frames = feed(animator, View(arc="value", arc_target=0.8), times(STEP, 150))
        self.assertAlmostEqual(frames[11].arc_frac, 0.2 + 0.6 * (1 - math.exp(-1)),
                              delta=0.01)
        self.assertAlmostEqual(frames[-1].arc_frac, 0.8, delta=1e-9)
        self.assertIs(frames[-1].animating, False)   # 到位了，又没别的东西在动

    def test_target_none_holds_position(self):
        """arc_target 为 None 时停在原地。"""
        animator = Animator()
        start = animator.step(View(arc="value", arc_target=0.5), 0.0).arc_frac
        frames = feed(animator, View(arc="value", arc_target=None), times(STEP, 60))
        for frame in frames:
            self.assertAlmostEqual(frame.arc_frac, start, delta=1e-9)
        self.assertIs(frames[-1].animating, False)


class TestDtCap(unittest.TestCase):
    """4. 两次 step 相隔 10 秒，只按 0.1 秒推进。"""

    def test_long_gap_only_advances_0_1s(self):
        animator = Animator()
        animator.step(View(arc="value", arc_target=0.2), 0.0)
        frame = animator.step(View(arc="value", arc_target=0.8), 10.0)
        k = 1 - math.exp(-0.1 / 0.4)
        self.assertLess(frame.arc_frac, 0.8)   # 没有一步跳到目标
        self.assertAlmostEqual(frame.arc_frac, 0.2 + 0.6 * k, delta=1e-9)
        self.assertIs(frame.animating, True)


class TestArcMix(unittest.TestCase):
    """5. 圆弧颜色：0.4 秒走完 0→1（每秒 2.5）。"""

    def test_value_to_prefill(self):
        animator = Animator()
        animator.step(View(arc="value", arc_target=0.5), 0.0)
        frames = feed(animator, View(arc="prefill", arc_target=0.5), times(STEP, 12))
        self.assertAlmostEqual(frames[5].arc_mix, 0.5, delta=0.01)   # 0.2 秒后
        self.assertAlmostEqual(frames[11].arc_mix, 1.0, delta=1e-9)  # 0.4 秒后到位


class TestAlphas(unittest.TestCase):
    """6. 五个不透明度：0.6 秒走完全程，线性。"""

    def test_blank_to_value(self):
        animator = Animator()
        animator.step(View(arc="blank"), 0.0)
        frames = feed(animator, View(arc="value", arc_target=0.5), times(STEP, 18))
        at_0_3 = frames[8]    # 走了 9 帧 = 0.3 秒
        self.assertAlmostEqual(at_0_3.value_alpha, 0.5, delta=0.01)
        self.assertAlmostEqual(at_0_3.track_alpha, 1.0, delta=0.01)  # 0.5 起步
        self.assertAlmostEqual(at_0_3.notch_alpha, 0.5, delta=0.01)
        at_0_6 = frames[17]   # 0.6 秒全部到位
        for name, expect in (("value_alpha", 1.0), ("ghost_alpha", 0.0),
                             ("ticks_alpha", 1.0), ("track_alpha", 1.0),
                             ("notch_alpha", 1.0)):
            self.assertAlmostEqual(getattr(at_0_6, name), expect, delta=1e-9, msg=name)


class TestTicksFade(unittest.TestCase):
    """7. 切换刻度时淡入一次。"""

    def test_scale_change_fades(self):
        animator = Animator()
        first = View(arc="value", arc_target=0.5, scale="decode")
        then = View(arc="value", arc_target=0.5, scale="prefill")
        self.assertAlmostEqual(animator.step(first, 0.0).ticks_alpha, 1.0, delta=1e-9)
        on_change = animator.step(then, 0.01)
        self.assertAlmostEqual(on_change.ticks_alpha, 0.15, delta=1e-9)
        self.assertIs(on_change.animating, True)
        done = animator.step(then, 0.33)
        self.assertAlmostEqual(done.ticks_alpha, 1.0, delta=1e-9)
        self.assertIs(done.animating, False)


class TestBlockFade(unittest.TestCase):
    """8. 三块淡入：只在各自的键变化时开始。"""

    def test_cap_change_fades_center(self):
        animator = Animator()
        animator.step(View(cap="解码速度", state_name="解码"), 0.0)
        frames = feed(animator, View(cap="本轮解码", state_name="解码"),
                      [0.01, 0.17, 0.33])
        at_start, at_half, at_end = frames
        self.assertAlmostEqual(at_start.center_alpha, 0.15, delta=1e-9)
        self.assertAlmostEqual(at_start.stats_alpha, 1.0, delta=1e-9)
        self.assertAlmostEqual(at_start.strip_alpha, 1.0, delta=1e-9)
        self.assertAlmostEqual(at_half.center_alpha, 0.15 + 0.85 * 0.75, delta=1e-9)
        self.assertAlmostEqual(at_end.center_alpha, 1.0, delta=1e-9)
        self.assertIs(at_half.animating, True)     # 淡入还在途中
        self.assertIs(at_end.animating, False)

    def test_card_label_change_fades_stats_only(self):
        animator = Animator()
        animator.step(View(cap="解码速度", state_name="解码",
                           cards=cards("上下文", "今日", "费用")), 0.0)
        frames = feed(animator, View(cap="解码速度", state_name="解码",
                                     cards=cards("上下文", "本轮", "本轮")),
                      [0.01, 0.33])
        self.assertAlmostEqual(frames[0].stats_alpha, 0.15, delta=1e-9)
        self.assertAlmostEqual(frames[0].center_alpha, 1.0, delta=1e-9)
        self.assertAlmostEqual(frames[0].strip_alpha, 1.0, delta=1e-9)
        self.assertAlmostEqual(frames[1].stats_alpha, 1.0, delta=1e-9)

    def test_state_name_change_fades_strip_only(self):
        animator = Animator()
        animator.step(View(cap="解码速度", state_name="解码"), 0.0)
        frames = feed(animator, View(cap="解码速度", state_name="完成"), [0.01, 0.33])
        self.assertAlmostEqual(frames[0].strip_alpha, 0.15, delta=1e-9)
        self.assertAlmostEqual(frames[0].center_alpha, 1.0, delta=1e-9)
        self.assertAlmostEqual(frames[0].stats_alpha, 1.0, delta=1e-9)
        self.assertAlmostEqual(frames[1].strip_alpha, 1.0, delta=1e-9)

    def test_no_fade_for_value_only_changes(self):
        """卡片只有数值变（标签没变）、只有主数字变：都不淡入。"""
        animator = Animator()
        before = View(cap="解码速度", big_int="62", cards=cards("上下文", "今日", "费用"))
        after = View(cap="解码速度", big_int="63", cards=cards("上下文", "今日", "费用"))
        animator.step(before, 0.0)
        by_number = animator.step(after, 0.1)
        self.assertEqual((by_number.center_alpha, by_number.stats_alpha,
                          by_number.strip_alpha), (1.0, 1.0, 1.0))
        self.assertIs(by_number.animating, False)

        other = Animator()
        low = View(cards=cards("上下文", "今日", "费用"))
        low.cards[0].value = "6.2K"
        high = View(cards=cards("上下文", "今日", "费用"))
        high.cards[0].value = "9.9K"
        other.step(low, 0.0)
        frame = other.step(high, 0.1)
        self.assertEqual((frame.center_alpha, frame.stats_alpha, frame.strip_alpha),
                         (1.0, 1.0, 1.0))


class TestSlowFade(unittest.TestCase):
    """9. 慢淡入 0.8 秒（完成 → 空闲那一类切换）。"""

    def test_slow_fade_curve(self):
        animator = Animator()
        animator.step(View(cap="本轮统计", state_name="完成"), 0.0)
        frames = feed(animator, View(cap="今日统计", state_name="完成", slow_fade=True),
                      [0.4, 0.8, 1.21])
        self.assertAlmostEqual(frames[1].center_alpha, 0.15 + 0.85 * 0.5, delta=1e-9)
        self.assertAlmostEqual(frames[2].center_alpha, 1.0, delta=1e-9)
        self.assertIs(frames[1].animating, True)
        self.assertIs(frames[2].animating, False)


class TestBigNumber(unittest.TestCase):
    """10. 主数字：非实时直接抄，实时用缓动值且每 0.25 秒最多刷新一次。"""

    def test_non_live_text(self):
        animator = Animator()
        frames = feed(animator, View(big_int="62", big_dec=".3"), [0.0, 0.2, 1.0])
        for frame in frames:
            self.assertEqual((frame.big_int, frame.big_dec), ("62", ".3"))

    def test_live_number(self):
        animator = Animator()
        first = animator.step(View(big_value=60.4), 0.0)
        self.assertEqual(first.big_int, "60")
        at_0_1 = animator.step(View(big_value=100), 0.1)
        self.assertEqual(at_0_1.big_int, "60")              # 没到 0.25 秒，文字不动
        at_0_25 = animator.step(View(big_value=100), 0.25)
        self.assertTrue(60 < int(at_0_25.big_int) < 100)     # 刷新的那一帧在 60–100 之间
        tail = feed(animator, View(big_value=100), times(0.25 + STEP, 150))
        self.assertEqual(tail[-1].big_int, "100")           # 5 秒后追上目标
        self.assertEqual(tail[-1].big_dec, "")
        self.assertIs(tail[-1].animating, False)

    def test_back_to_non_live_then_live(self):
        """从实时回到非实时再回到实时：display 直接取新的 big_value。"""
        animator = Animator()
        animator.step(View(big_value=60.4), 0.0)
        easing = animator.step(View(big_value=100), 0.3)
        self.assertNotEqual(easing.big_int, "100")           # 还在缓动途中
        back = animator.step(View(big_int="1200"), 1.0)
        self.assertEqual((back.big_int, back.big_dec), ("1200", ""))
        again = animator.step(View(big_value=250.0), 1.2)
        self.assertEqual(again.big_int, "250")
        self.assertEqual(again.big_dec, "")
        self.assertIs(again.animating, False)


class TestBar(unittest.TestCase):
    """11. 条的长度。"""

    def test_same_kind_eases(self):
        animator = Animator()
        animator.step(View(bar=Bar("ctx", 0.2)), 0.0)
        frames = feed(animator, View(bar=Bar("ctx", 0.6)), times(STEP, 12))
        self.assertAlmostEqual(frames[-1].bar_frac, 0.2 + 0.4 * (1 - math.exp(-1)),
                              delta=0.01)
        self.assertIs(frames[-1].animating, True)
        tail = feed(animator, View(bar=Bar("ctx", 0.6)), times(12 * STEP + STEP, 150))
        self.assertAlmostEqual(tail[-1].bar_frac, 0.6, delta=1e-9)
        self.assertIs(tail[-1].animating, False)

    def test_kind_change_jumps(self):
        animator = Animator()
        animator.step(View(bar=Bar("ctx", 0.2)), 0.0)
        frame = animator.step(View(bar=Bar("prog", 0.75)), STEP)
        self.assertAlmostEqual(frame.bar_frac, 0.75, delta=1e-9)

    def test_bar_gone(self):
        animator = Animator()
        animator.step(View(bar=Bar("ctx", 0.8)), 0.0)
        self.assertEqual(animator.step(View(bar=None), STEP).bar_frac, 0)


class TestPulse(unittest.TestCase):
    """12. 流指示点的脉冲。"""

    def test_decode_pulse(self):
        animator = Animator()
        view = View(lanes=Lanes(decoding=1))
        self.assertAlmostEqual(animator.step(view, 0).pulse_dec, 1.0, delta=1e-9)
        self.assertAlmostEqual(animator.step(view, 0.7).pulse_dec, 0.35, delta=1e-9)
        self.assertAlmostEqual(animator.step(view, 1.4).pulse_dec, 1.0, delta=1e-9)

    def test_prefill_pulse(self):
        frame = Animator().step(View(lanes=Lanes(prefilling=1)), 0.5)
        self.assertAlmostEqual(frame.pulse_pre, 0.35, delta=1e-9)
        self.assertAlmostEqual(frame.pulse_dec, 1.0, delta=1e-9)   # 没有解码中的流

    def test_no_lanes(self):
        frame = Animator().step(View(lanes=Lanes()), 0.3)
        self.assertEqual((frame.pulse_dec, frame.pulse_pre), (1.0, 1.0))

    def test_offline(self):
        frame = Animator().step(View(lanes=Lanes(decoding=2, offline=True)), 0.3)
        self.assertEqual((frame.pulse_dec, frame.pulse_pre), (1.0, 1.0))
        self.assertIs(frame.animating, False)


class TestDim(unittest.TestCase):
    """13. 整屏亮度：变暗每秒 0.3，变亮立刻回。"""

    def test_down_slowly_up_immediately(self):
        animator = Animator()
        animator.step(View(dim=1.0), 0.0)
        frames = feed(animator, View(dim=0.4), times(STEP, 60))
        self.assertAlmostEqual(frames[29].dim, 0.7, delta=1e-6)   # 1 秒后
        self.assertAlmostEqual(frames[59].dim, 0.4, delta=1e-9)   # 2 秒后走完
        back = animator.step(View(dim=1.0), 2.1)
        self.assertAlmostEqual(back.dim, 1.0, delta=1e-9)
        self.assertIs(back.animating, False)


class TestAnimating(unittest.TestCase):
    """14. animating：还有没有走完的动画。"""

    def test_idle_settles_after_two_steps(self):
        animator = Animator()
        view = View(state="idle", state_name="空闲", cap="今日统计")
        self.assertIs(animator.step(view, 0.0).animating, False)
        self.assertIs(animator.step(view, STEP).animating, False)

    def test_pulse_keeps_animating(self):
        animator = Animator()
        view = View(lanes=Lanes(decoding=1))
        for moment in times(0.0, 10):
            self.assertIs(animator.step(view, moment).animating, True, msg=moment)

    def test_arc_easing_keeps_animating(self):
        animator = Animator()
        animator.step(View(arc="value", arc_target=0.2), 0.0)
        frames = feed(animator, View(arc="value", arc_target=0.8), times(STEP, 150))
        self.assertIs(frames[0].animating, True)          # 还在缓动
        self.assertIs(frames[-1].animating, False)        # 到位且没有脉冲

    def test_fade_keeps_animating(self):
        animator = Animator()
        animator.step(View(cap="解码速度", state_name="解码"), 0.0)
        frames = feed(animator, View(cap="本轮解码", state_name="解码"),
                      [0.01, 0.17, 0.33])
        self.assertIs(frames[0].animating, True)
        self.assertIs(frames[1].animating, True)
        self.assertIs(frames[2].animating, False)


class TestRanges(unittest.TestCase):
    """15. 所有输出的不透明度、位置都在 0–1 之间。"""

    FIELDS = ("arc_frac", "arc_mix", "value_alpha", "ghost_alpha", "ticks_alpha",
              "track_alpha", "notch_alpha", "bar_frac", "center_alpha",
              "stats_alpha", "strip_alpha", "pulse_dec", "pulse_pre", "dim")

    def test_everything_stays_in_0_1(self):
        views = [
            View(arc="blank", dim=1.0),
            View(arc="value", arc_target=0.5, scale="prefill", dim=0.4),
            View(arc="prefill", arc_target=1.0, slow_fade=True,
                 lanes=Lanes(prefilling=2), dim=1.0),
            View(arc="rest", ghost=0.3, lanes=Lanes(decoding=2, prefilling=1),
                 bar=Bar("ctx", 0.9, text=[Seg("上下文 6.2K", "normal")]),
                 state="decode", state_name="解码"),
            View(arc="off", ghost=None, bar=None, dim=0.4,
                 lanes=Lanes(offline=True, waiting=1), state="offline",
                 state_name="离线"),
            View(arc="blank", big_value=12.3, dim=0.6, big_int="12",
                 cards=cards("上下文", "今日", "费用"), state="idle"),
            View(arc="value", arc_target=0.1, big_value=None, big_int="0.10",
                 scale="decode", dim=1.0, slow_fade=True, bar=Bar("note", 0.0)),
        ]
        animator = Animator()
        moment = 0.0
        for i in range(140):
            frame = animator.step(views[i % len(views)], moment)
            for name in self.FIELDS:
                value = getattr(frame, name)
                with self.subTest(frame=i, field=name):
                    self.assertGreaterEqual(value, 0.0)
                    self.assertLessEqual(value, 1.0)
            moment += STEP


if __name__ == "__main__":
    unittest.main()
