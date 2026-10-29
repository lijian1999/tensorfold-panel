// 任务 G：动画（Animator / Frame）测试。全部用假时刻，不 sleep。
import Testing
import Foundation
@testable import PanelCore

private let STEP = 1.0 / 30.0   // 动画时约每秒 30 帧

/// 从 start 起连续 count 帧的时刻（包含 start 那一帧）。
private func times(_ start: Double, _ count: Int, _ step: Double = STEP) -> [Double] {
    (0..<count).map { start + Double($0) * step }
}

/// 把同一个 View 按给定时刻逐帧喂进去，返回每一帧的 Frame。
private func feed(_ animator: Animator, _ view: View, _ moments: [Double]) -> [Frame] {
    moments.map { animator.step(view, now: $0) }
}

/// 三张右侧卡片，只给标签，数值一律相同。
private func cards(_ labels: String...) -> [Card] {
    labels.map { Card($0, "6.2K") }
}

/// 构造 View：先 View() 再逐个赋值（对应 Python 的关键字参数）。
private func makeView(_ set: (inout View) -> Void) -> View {
    var v = View()
    set(&v)
    return v
}

/// 1. settled：所有动画走完时的那一帧。
@Suite struct TestSettled {
    private let alphaFields: [(String, KeyPath<Frame, Double>)] = [
        ("value_alpha", \Frame.valueAlpha),
        ("ghost_alpha", \Frame.ghostAlpha),
        ("ticks_alpha", \Frame.ticksAlpha),
        ("track_alpha", \Frame.trackAlpha),
        ("notch_alpha", \Frame.notchAlpha),
    ]

    // 六种 arc 的各部分不透明度按任务给的表。
    @Test func test_alpha_table() {
        let cases: [(String, [Double])] = [
            ("value", [1, 0, 1, 1, 1]),
            ("prefill", [1, 0, 1, 1, 1]),
            ("rest", [0, 0.9, 0.75, 1, 1]),
            ("blank", [0, 0, 0, 0.5, 0]),
            ("off", [0, 0, 0, 0.5, 0]),
        ]
        for (arc, want) in cases {
            let view = makeView { $0.arc = arc; $0.arcTarget = 0.4; $0.ghost = 0.2 }
            let frame = Animator.settled(view)
            for (i, item) in alphaFields.enumerated() {
                #expect(abs(frame[keyPath: item.1] - want[i]) <= 1e-9, "arc=\(arc) \(item.0)")
            }
        }
    }

    // ghost 为 None 时灰点不画（不透明度 0）。
    @Test func test_rest_without_ghost() {
        let view = makeView { $0.arc = "rest"; $0.ghost = nil }
        let frame = Animator.settled(view)
        #expect(frame.ghostAlpha == 0)
    }

    // 其余字段：圆弧位置 / 颜色、主数字、条、三块、脉冲、亮度。
    @Test func test_fields() {
        let view = makeView {
            $0.state = "decode"; $0.stateName = "解码"; $0.cap = "解码速度"; $0.unit = "tok/s"
            $0.bigInt = "62"; $0.bigDec = ".3"; $0.bigWhole = true
            $0.arc = "prefill"; $0.arcTarget = 0.4
            $0.bar = Bar(kind: "prog", frac: 0.3); $0.dim = 0.4
        }
        let frame = Animator.settled(view)
        #expect(abs(frame.arcFrac - 0.4) <= 1e-9)
        #expect(abs(frame.arcMix - 1.0) <= 1e-9)   // prefill 才是琥珀色
        #expect((frame.bigInt, frame.bigDec) == ("62", ".3"))
        #expect(abs(frame.barFrac - 0.3) <= 1e-9)
        let names: [(String, KeyPath<Frame, Double>)] = [
            ("center_alpha", \Frame.centerAlpha),
            ("stats_alpha", \Frame.statsAlpha),
            ("strip_alpha", \Frame.stripAlpha),
            ("pulse_dec", \Frame.pulseDec),
            ("pulse_pre", \Frame.pulsePre),
        ]
        for item in names {
            #expect(abs(frame[keyPath: item.1] - 1.0) <= 1e-9, Comment(rawValue: item.0))
        }
        #expect(abs(frame.dim - 0.4) <= 1e-9)
    }

    // arc_target 为 None → arc_frac 0；没有 bar → bar_frac 0；不忙。
    @Test func test_defaults() {
        let view = makeView { $0.arc = "blank"; $0.arcTarget = nil; $0.bar = nil }
        let frame = Animator.settled(view)
        #expect(frame.arcFrac == 0)
        #expect(frame.barFrac == 0)
        #expect(frame.animating == false)
    }
}

/// 2. 第一次 step 等于 settled（脉冲除外），三块不透明度都是 1。
@Suite struct TestFirstStep {
    // Frame 的全部 Double 字段的键路径（名字用 Python 的下划线写法，写进断言说明）。
    private let allDoubleFields: [(String, KeyPath<Frame, Double>)] = [
        ("arc_frac", \Frame.arcFrac),
        ("arc_mix", \Frame.arcMix),
        ("value_alpha", \Frame.valueAlpha),
        ("ghost_alpha", \Frame.ghostAlpha),
        ("ticks_alpha", \Frame.ticksAlpha),
        ("track_alpha", \Frame.trackAlpha),
        ("notch_alpha", \Frame.notchAlpha),
        ("bar_frac", \Frame.barFrac),
        ("center_alpha", \Frame.centerAlpha),
        ("stats_alpha", \Frame.statsAlpha),
        ("strip_alpha", \Frame.stripAlpha),
        ("pulse_dec", \Frame.pulseDec),
        ("pulse_pre", \Frame.pulsePre),
        ("dim", \Frame.dim),
    ]

    @Test func test_matches_settled() {
        let views = [
            makeView { $0.arc = "value"; $0.arcTarget = 0.5; $0.bar = Bar(kind: "ctx", frac: 0.3) },
            makeView { $0.arc = "prefill"; $0.arcTarget = 0.2 },
            makeView { $0.arc = "rest"; $0.ghost = 0.3; $0.dim = 0.4 },
            makeView { $0.arc = "blank"; $0.dim = 0.4 },
            makeView { $0.arc = "off"; $0.state = "offline"; $0.lanes = Lanes(offline: true) },
        ]
        for view in views {
            let got = Animator().step(view, now: 100.0)
            let want = Animator.settled(view)
            for item in allDoubleFields {
                #expect(abs(got[keyPath: item.1] - want[keyPath: item.1]) <= 1e-9,
                        "\(item.0) 应与 settled 一致")
            }
            #expect(got.bigInt == want.bigInt, "big_int 应与 settled 一致")
            #expect(got.bigDec == want.bigDec, "big_dec 应与 settled 一致")
            #expect(got.animating == want.animating, "animating 应与 settled 一致")
        }
    }

    // 第一次调用不淡入：中间、右侧三栏、状态条都是 1。
    @Test func test_three_blocks_start_at_one() {
        let view = makeView {
            $0.state = "decode"; $0.stateName = "解码"; $0.cap = "解码速度"; $0.unit = "tok/s"
            $0.bigInt = "62"; $0.bigDec = ".3"; $0.cards = cards("上下文", "今日", "费用")
        }
        let frame = Animator().step(view, now: 0.0)
        #expect((frame.centerAlpha, frame.statsAlpha, frame.stripAlpha) == (1.0, 1.0, 1.0))
    }
}

/// 3. 圆弧位置的缓动。
@Suite struct TestArcEasing {
    @Test func test_monotonic_and_value_after_0_4s() {
        let animator = Animator()
        animator.step(makeView { $0.arc = "value"; $0.arcTarget = 0.2 }, now: 0.0)
        let frames = feed(animator, makeView { $0.arc = "value"; $0.arcTarget = 0.8 }, times(STEP, 12))
        let values = frames.map(\.arcFrac)
        for (a, b) in zip(values, values.dropFirst()) {
            #expect(a < b)      // 一路变大，中间不回头
        }
        #expect(abs(values.last! - (0.2 + 0.6 * (1 - exp(-1)))) <= 0.01)
    }

    @Test func test_done_after_5s_and_not_animating() {
        let animator = Animator()
        animator.step(makeView { $0.arc = "value"; $0.arcTarget = 0.2 }, now: 0.0)
        let frames = feed(animator, makeView { $0.arc = "value"; $0.arcTarget = 0.8 }, times(STEP, 150))
        #expect(abs(frames[11].arcFrac - (0.2 + 0.6 * (1 - exp(-1)))) <= 0.01)
        #expect(abs(frames[149].arcFrac - 0.8) <= 1e-9)
        #expect(frames[149].animating == false)   // 到位了，又没别的东西在动
    }

    // arc_target 为 None 时停在原地。
    @Test func test_target_none_holds_position() {
        let animator = Animator()
        let start = animator.step(makeView { $0.arc = "value"; $0.arcTarget = 0.5 }, now: 0.0).arcFrac
        let frames = feed(animator, makeView { $0.arc = "value"; $0.arcTarget = nil }, times(STEP, 60))
        for frame in frames {
            #expect(abs(frame.arcFrac - start) <= 1e-9)
        }
        #expect(frames.last!.animating == false)
    }
}

/// 4. 两次 step 相隔 10 秒，只按 0.1 秒推进。
@Suite struct TestDtCap {
    @Test func test_long_gap_only_advances_0_1s() {
        let animator = Animator()
        animator.step(makeView { $0.arc = "value"; $0.arcTarget = 0.2 }, now: 0.0)
        let frame = animator.step(makeView { $0.arc = "value"; $0.arcTarget = 0.8 }, now: 10.0)
        let k = 1 - exp(-0.1 / 0.4)
        #expect(frame.arcFrac < 0.8)   // 没有一步跳到目标
        #expect(abs(frame.arcFrac - (0.2 + 0.6 * k)) <= 1e-9)
        #expect(frame.animating == true)
    }
}

/// 5. 圆弧颜色：0.4 秒走完 0→1（每秒 2.5）。
@Suite struct TestArcMix {
    @Test func test_value_to_prefill() {
        let animator = Animator()
        animator.step(makeView { $0.arc = "value"; $0.arcTarget = 0.5 }, now: 0.0)
        let frames = feed(animator, makeView { $0.arc = "prefill"; $0.arcTarget = 0.5 }, times(STEP, 12))
        #expect(abs(frames[5].arcMix - 0.5) <= 0.01)   // 0.2 秒后
        #expect(abs(frames[11].arcMix - 1.0) <= 1e-9)  // 0.4 秒后到位
    }
}

/// 6. 五个不透明度：0.6 秒走完全程，线性。
@Suite struct TestAlphas {
    @Test func test_blank_to_value() {
        let animator = Animator()
        animator.step(makeView { $0.arc = "blank" }, now: 0.0)
        let frames = feed(animator, makeView { $0.arc = "value"; $0.arcTarget = 0.5 }, times(STEP, 18))
        let at03 = frames[8]    // 走了 9 帧 = 0.3 秒
        #expect(abs(at03.valueAlpha - 0.5) <= 0.01)
        #expect(abs(at03.trackAlpha - 1.0) <= 0.01)  // 0.5 起步
        #expect(abs(at03.notchAlpha - 0.5) <= 0.01)
        let at06 = frames[17]   // 0.6 秒全部到位
        let expects: [(String, KeyPath<Frame, Double>, Double)] = [
            ("value_alpha", \Frame.valueAlpha, 1.0),
            ("ghost_alpha", \Frame.ghostAlpha, 0.0),
            ("ticks_alpha", \Frame.ticksAlpha, 1.0),
            ("track_alpha", \Frame.trackAlpha, 1.0),
            ("notch_alpha", \Frame.notchAlpha, 1.0),
        ]
        for item in expects {
            #expect(abs(at06[keyPath: item.1] - item.2) <= 1e-9, Comment(rawValue: item.0))
        }
    }
}

/// 7. 切换刻度时淡入一次。
@Suite struct TestTicksFade {
    @Test func test_scale_change_fades() {
        let animator = Animator()
        let first = makeView { $0.arc = "value"; $0.arcTarget = 0.5; $0.scale = "decode" }
        let then = makeView { $0.arc = "value"; $0.arcTarget = 0.5; $0.scale = "prefill" }
        #expect(abs(animator.step(first, now: 0.0).ticksAlpha - 1.0) <= 1e-9)
        let onChange = animator.step(then, now: 0.01)
        #expect(abs(onChange.ticksAlpha - 0.15) <= 1e-9)
        #expect(onChange.animating == true)
        let done = animator.step(then, now: 0.33)
        #expect(abs(done.ticksAlpha - 1.0) <= 1e-9)
        #expect(done.animating == false)
    }
}

/// 8. 三块淡入：只在各自的键变化时开始。
@Suite struct TestBlockFade {
    @Test func test_cap_change_fades_center() {
        let animator = Animator()
        animator.step(makeView { $0.cap = "解码速度"; $0.stateName = "解码" }, now: 0.0)
        let frames = feed(animator, makeView { $0.cap = "本轮解码"; $0.stateName = "解码" },
                          [0.01, 0.17, 0.33])
        let atStart = frames[0], atHalf = frames[1], atEnd = frames[2]
        #expect(abs(atStart.centerAlpha - 0.15) <= 1e-9)
        #expect(abs(atStart.statsAlpha - 1.0) <= 1e-9)
        #expect(abs(atStart.stripAlpha - 1.0) <= 1e-9)
        #expect(abs(atHalf.centerAlpha - (0.15 + 0.85 * 0.75)) <= 1e-9)
        #expect(abs(atEnd.centerAlpha - 1.0) <= 1e-9)
        #expect(atHalf.animating == true)     // 淡入还在途中
        #expect(atEnd.animating == false)
    }

    @Test func test_card_label_change_fades_stats_only() {
        let animator = Animator()
        animator.step(makeView { $0.cap = "解码速度"; $0.stateName = "解码"
                                $0.cards = cards("上下文", "今日", "费用") }, now: 0.0)
        let frames = feed(animator, makeView { $0.cap = "解码速度"; $0.stateName = "解码"
                                              $0.cards = cards("上下文", "本轮", "本轮") },
                          [0.01, 0.33])
        #expect(abs(frames[0].statsAlpha - 0.15) <= 1e-9)
        #expect(abs(frames[0].centerAlpha - 1.0) <= 1e-9)
        #expect(abs(frames[0].stripAlpha - 1.0) <= 1e-9)
        #expect(abs(frames[1].statsAlpha - 1.0) <= 1e-9)
    }

    @Test func test_state_name_change_fades_strip_only() {
        let animator = Animator()
        animator.step(makeView { $0.cap = "解码速度"; $0.stateName = "解码" }, now: 0.0)
        let frames = feed(animator, makeView { $0.cap = "解码速度"; $0.stateName = "完成" }, [0.01, 0.33])
        #expect(abs(frames[0].stripAlpha - 0.15) <= 1e-9)
        #expect(abs(frames[0].centerAlpha - 1.0) <= 1e-9)
        #expect(abs(frames[0].statsAlpha - 1.0) <= 1e-9)
        #expect(abs(frames[1].stripAlpha - 1.0) <= 1e-9)
    }

    // 卡片只有数值变（标签没变）、只有主数字变：都不淡入。
    @Test func test_no_fade_for_value_only_changes() {
        let animator = Animator()
        let before = makeView { $0.cap = "解码速度"; $0.bigInt = "62"
                                $0.cards = cards("上下文", "今日", "费用") }
        let after = makeView { $0.cap = "解码速度"; $0.bigInt = "63"
                               $0.cards = cards("上下文", "今日", "费用") }
        animator.step(before, now: 0.0)
        let byNumber = animator.step(after, now: 0.1)
        #expect((byNumber.centerAlpha, byNumber.statsAlpha, byNumber.stripAlpha) == (1.0, 1.0, 1.0))
        #expect(byNumber.animating == false)

        let other = Animator()
        var low = makeView { $0.cards = cards("上下文", "今日", "费用") }
        low.cards[0].value = "6.2K"
        var high = makeView { $0.cards = cards("上下文", "今日", "费用") }
        high.cards[0].value = "9.9K"
        other.step(low, now: 0.0)
        let frame = other.step(high, now: 0.1)
        #expect((frame.centerAlpha, frame.statsAlpha, frame.stripAlpha) == (1.0, 1.0, 1.0))
    }
}

/// 9. 慢淡入 0.8 秒（完成 → 空闲那一类切换）。
@Suite struct TestSlowFade {
    @Test func test_slow_fade_curve() {
        let animator = Animator()
        animator.step(makeView { $0.cap = "本轮统计"; $0.stateName = "完成" }, now: 0.0)
        let frames = feed(animator, makeView { $0.cap = "今日统计"; $0.stateName = "完成"; $0.slowFade = true },
                          [0.4, 0.8, 1.21])
        #expect(abs(frames[1].centerAlpha - (0.15 + 0.85 * 0.5)) <= 1e-9)
        #expect(abs(frames[2].centerAlpha - 1.0) <= 1e-9)
        #expect(frames[1].animating == true)
        #expect(frames[2].animating == false)
    }
}

/// 10. 主数字：非实时直接抄，实时用缓动值且每 0.25 秒最多刷新一次。
@Suite struct TestBigNumber {
    @Test func test_non_live_text() {
        let animator = Animator()
        let frames = feed(animator, makeView { $0.bigInt = "62"; $0.bigDec = ".3" }, [0.0, 0.2, 1.0])
        for frame in frames {
            #expect((frame.bigInt, frame.bigDec) == ("62", ".3"))
        }
    }

    @Test func test_live_number() {
        let animator = Animator()
        let first = animator.step(makeView { $0.bigValue = 60.4 }, now: 0.0)
        #expect(first.bigInt == "60")
        let live = makeView { $0.bigValue = 100 }
        let at01 = animator.step(live, now: 0.1)
        #expect(at01.bigInt == "60")              // 没到 0.25 秒，文字不动
        let at025 = animator.step(live, now: 0.25)
        let n = Int(at025.bigInt)!
        #expect(60 < n && n < 100)                // 刷新的那一帧在 60–100 之间
        let tail = feed(animator, live, times(0.25 + STEP, 150))
        #expect(tail.last!.bigInt == "100")       // 5 秒后追上目标
        #expect(tail.last!.bigDec == "")
        #expect(tail.last!.animating == false)
    }

    // 从实时回到非实时再回到实时：display 直接取新的 big_value。
    @Test func test_back_to_non_live_then_live() {
        let animator = Animator()
        animator.step(makeView { $0.bigValue = 60.4 }, now: 0.0)
        let easing = animator.step(makeView { $0.bigValue = 100 }, now: 0.3)
        #expect(easing.bigInt != "100")           // 还在缓动途中
        let back = animator.step(makeView { $0.bigInt = "1200" }, now: 1.0)
        #expect((back.bigInt, back.bigDec) == ("1200", ""))
        let again = animator.step(makeView { $0.bigValue = 250.0 }, now: 1.2)
        #expect(again.bigInt == "250")
        #expect(again.bigDec == "")
        #expect(again.animating == false)
    }
}

/// 11. 条的长度。
@Suite struct TestBar {
    @Test func test_same_kind_eases() {
        let animator = Animator()
        animator.step(makeView { $0.bar = Bar(kind: "ctx", frac: 0.2) }, now: 0.0)
        let frames = feed(animator, makeView { $0.bar = Bar(kind: "ctx", frac: 0.6) }, times(STEP, 12))
        #expect(abs(frames.last!.barFrac - (0.2 + 0.4 * (1 - exp(-1)))) <= 0.01)
        #expect(frames.last!.animating == true)
        let tail = feed(animator, makeView { $0.bar = Bar(kind: "ctx", frac: 0.6) },
                        times(12 * STEP + STEP, 150))
        #expect(abs(tail.last!.barFrac - 0.6) <= 1e-9)
        #expect(tail.last!.animating == false)
    }

    @Test func test_kind_change_jumps() {
        let animator = Animator()
        animator.step(makeView { $0.bar = Bar(kind: "ctx", frac: 0.2) }, now: 0.0)
        let frame = animator.step(makeView { $0.bar = Bar(kind: "prog", frac: 0.75) }, now: STEP)
        #expect(abs(frame.barFrac - 0.75) <= 1e-9)
    }

    @Test func test_bar_gone() {
        let animator = Animator()
        animator.step(makeView { $0.bar = Bar(kind: "ctx", frac: 0.8) }, now: 0.0)
        #expect(animator.step(makeView { $0.bar = nil }, now: STEP).barFrac == 0)
    }
}

/// 12. 流指示点的脉冲。
@Suite struct TestPulse {
    @Test func test_decode_pulse() {
        let animator = Animator()
        let view = makeView { $0.lanes = Lanes(decoding: 1) }
        #expect(abs(animator.step(view, now: 0).pulseDec - 1.0) <= 1e-9)
        #expect(abs(animator.step(view, now: 0.7).pulseDec - 0.35) <= 1e-9)
        #expect(abs(animator.step(view, now: 1.4).pulseDec - 1.0) <= 1e-9)
    }

    @Test func test_prefill_pulse() {
        let frame = Animator().step(makeView { $0.lanes = Lanes(prefilling: 1) }, now: 0.5)
        #expect(abs(frame.pulsePre - 0.35) <= 1e-9)
        #expect(abs(frame.pulseDec - 1.0) <= 1e-9)   // 没有解码中的流
    }

    @Test func test_no_lanes() {
        let frame = Animator().step(makeView { $0.lanes = Lanes() }, now: 0.3)
        #expect((frame.pulseDec, frame.pulsePre) == (1.0, 1.0))
    }

    @Test func test_offline() {
        let frame = Animator().step(makeView { $0.lanes = Lanes(decoding: 2, offline: true) }, now: 0.3)
        #expect((frame.pulseDec, frame.pulsePre) == (1.0, 1.0))
        #expect(frame.animating == false)
    }
}

/// 13. 整屏亮度：变暗每秒 0.3，变亮立刻回。
@Suite struct TestDim {
    @Test func test_down_slowly_up_immediately() {
        let animator = Animator()
        animator.step(makeView { $0.dim = 1.0 }, now: 0.0)
        let frames = feed(animator, makeView { $0.dim = 0.4 }, times(STEP, 60))
        #expect(abs(frames[29].dim - 0.7) <= 1e-6)   // 1 秒后
        #expect(abs(frames[59].dim - 0.4) <= 1e-9)   // 2 秒后走完
        let back = animator.step(makeView { $0.dim = 1.0 }, now: 2.1)
        #expect(abs(back.dim - 1.0) <= 1e-9)
        #expect(back.animating == false)
    }
}

/// 14. animating：还有没有走完的动画。
@Suite struct TestAnimating {
    @Test func test_idle_settles_after_two_steps() {
        let animator = Animator()
        let view = makeView { $0.state = "idle"; $0.stateName = "空闲"; $0.cap = "今日统计" }
        #expect(animator.step(view, now: 0.0).animating == false)
        #expect(animator.step(view, now: STEP).animating == false)
    }

    @Test func test_pulse_keeps_animating() {
        let animator = Animator()
        let view = makeView { $0.lanes = Lanes(decoding: 1) }
        for moment in times(0.0, 10) {
            #expect(animator.step(view, now: moment).animating == true, "\(moment)")
        }
    }

    @Test func test_arc_easing_keeps_animating() {
        let animator = Animator()
        animator.step(makeView { $0.arc = "value"; $0.arcTarget = 0.2 }, now: 0.0)
        let frames = feed(animator, makeView { $0.arc = "value"; $0.arcTarget = 0.8 }, times(STEP, 150))
        #expect(frames[0].animating == true)          // 还在缓动
        #expect(frames.last!.animating == false)      // 到位且没有脉冲
    }

    @Test func test_fade_keeps_animating() {
        let animator = Animator()
        animator.step(makeView { $0.cap = "解码速度"; $0.stateName = "解码" }, now: 0.0)
        let frames = feed(animator, makeView { $0.cap = "本轮解码"; $0.stateName = "解码" },
                          [0.01, 0.17, 0.33])
        #expect(frames[0].animating == true)
        #expect(frames[1].animating == true)
        #expect(frames[2].animating == false)
    }
}

/// 15. 所有输出的不透明度、位置都在 0–1 之间。
@Suite struct TestRanges {
    private let fields: [(String, KeyPath<Frame, Double>)] = [
        ("arc_frac", \Frame.arcFrac), ("arc_mix", \Frame.arcMix),
        ("value_alpha", \Frame.valueAlpha), ("ghost_alpha", \Frame.ghostAlpha),
        ("ticks_alpha", \Frame.ticksAlpha), ("track_alpha", \Frame.trackAlpha),
        ("notch_alpha", \Frame.notchAlpha), ("bar_frac", \Frame.barFrac),
        ("center_alpha", \Frame.centerAlpha), ("stats_alpha", \Frame.statsAlpha),
        ("strip_alpha", \Frame.stripAlpha), ("pulse_dec", \Frame.pulseDec),
        ("pulse_pre", \Frame.pulsePre), ("dim", \Frame.dim),
    ]

    @Test func test_everything_stays_in_0_1() {
        let views = [
            makeView { $0.arc = "blank"; $0.dim = 1.0 },
            makeView { $0.arc = "value"; $0.arcTarget = 0.5; $0.scale = "prefill"; $0.dim = 0.4 },
            makeView { $0.arc = "prefill"; $0.arcTarget = 1.0; $0.slowFade = true
                       $0.lanes = Lanes(prefilling: 2); $0.dim = 1.0 },
            makeView { $0.arc = "rest"; $0.ghost = 0.3; $0.lanes = Lanes(decoding: 2, prefilling: 1)
                       $0.bar = Bar(kind: "ctx", frac: 0.9, text: [Seg("上下文 6.2K", "normal")])
                       $0.state = "decode"; $0.stateName = "解码" },
            makeView { $0.arc = "off"; $0.ghost = nil; $0.bar = nil; $0.dim = 0.4
                       $0.lanes = Lanes(waiting: 1, offline: true)
                       $0.state = "offline"; $0.stateName = "离线" },
            makeView { $0.arc = "blank"; $0.bigValue = 12.3; $0.dim = 0.6; $0.bigInt = "12"
                       $0.cards = cards("上下文", "今日", "费用"); $0.state = "idle" },
            makeView { $0.arc = "value"; $0.arcTarget = 0.1; $0.bigValue = nil; $0.bigInt = "0.10"
                       $0.scale = "decode"; $0.dim = 1.0; $0.slowFade = true
                       $0.bar = Bar(kind: "note", frac: 0.0) },
        ]
        let animator = Animator()
        var moment = 0.0
        for i in 0..<140 {
            let frame = animator.step(views[i % views.count], now: moment)
            for item in fields {
                let value = frame[keyPath: item.1]
                #expect(value >= 0.0, "frame=\(i) field=\(item.0)")
                #expect(value <= 1.0, "frame=\(i) field=\(item.0)")
            }
            moment += STEP
        }
    }
}
