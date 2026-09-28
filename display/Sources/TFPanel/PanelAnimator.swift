import Foundation
import PanelCore

/// 随时间变化的动画量：缓动、大数字节流、状态切换淡入、圆点脉冲。
/// 由外部（窗口程序）每帧调用 `tick(now:model:)`。
@MainActor
final class PanelAnimator {
    /// 一帧渲染需要的全部动画量（视图直接读它）
    struct Frame {
        /// 缓动后的弧值（tok/s）
        var display: Double = 0
        /// 大数字整数段（decode 状态为缓动值四舍五入，受 0.25 s 节流）
        var bigInt: String = ""
        /// 大数字小数段
        var bigDec: String = ""
        /// 状态切换淡入不透明度（0.15 → 1）
        var fadeOpacity: Double = 1
        /// 圆点脉冲不透明度（1 ↔ 0.35）
        var pulseOpacity: Double = 1
    }

    private(set) var frame = Frame()
    private var lastTick: Double?
    private var lastState: PanelState?
    private var fadeStart: Double = 0
    private var fadeDuration: Double = 0.32
    private var fadeSlow = false
    private var bigLastAt: Double?
    private var pulseStart: Double = 0
    /// 最近一次 tick 的缓动目标（isSettled 用）
    private var targetCache: Double = 0

    /// 推进一帧动画。`now` 为任意单调时钟（秒）。
    func tick(now: Double, model: PanelViewModel) {
        let dt = min(0.1, now - (lastTick ?? now))   // 断帧时 dt 上限 0.1 s
        lastTick = now

        // 圆弧缓动：时间常数 0.4 s 的指数趋近，差值 < 0.02 直接到位
        let target = model.arc == .value ? model.arcTarget : 0
        targetCache = target
        var d = frame.display
        d += (target - d) * (1 - exp(-dt / 0.4))
        if abs(target - d) < 0.02 { d = target }
        frame.display = d

        // 大数字：decode 显示缓动值，但最多每 0.25 s 更新一次（每秒最多刷新 4 次）
        if model.state == .decode {
            if bigLastAt == nil || now - bigLastAt! >= 0.25 {
                frame.bigInt = String(Int(d.rounded()))
                frame.bigDec = ""
                bigLastAt = now
            }
        } else {
            bigLastAt = nil
            frame.bigInt = model.bigInt
            frame.bigDec = model.bigDec
        }

        // 状态切换淡入：0.15 → 1，一般 0.32 s ease-out；done → idle 用 0.8 s ease-in-out
        if model.state != lastState {
            let prev = lastState
            lastState = model.state
            fadeStart = now
            fadeSlow = prev == .done && model.state == .idle
            fadeDuration = fadeSlow ? 0.8 : 0.32
            if pulseState(model.state) { pulseStart = now }
        }
        let p = min(1, max(0, (now - fadeStart) / fadeDuration))
        frame.fadeOpacity = 0.15 + 0.85 * (fadeSlow ? Self.easeInOut(p) : Self.easeOut(p))

        // 圆点脉冲：prefill 周期 1.0 s、decode 1.4 s、starting 同 prefill；其他不脉冲
        switch model.state {
        case .decode:
            frame.pulseOpacity = pulseOpacity(now, period: 1.4)
        case .prefill, .starting:
            frame.pulseOpacity = pulseOpacity(now, period: 1.0)
        default:
            frame.pulseOpacity = 1
        }
    }

    /// 「所有动画已结束」的状态（截图用）：display = 目标、大数字 = 目标四舍五入、淡入完成、脉冲不透明度 1
    func settled(model: PanelViewModel) -> Frame {
        var f = Frame()
        f.display = model.arc == .value ? model.arcTarget : 0
        if model.state == .decode {
            f.bigInt = String(Int(model.arcTarget.rounded()))
            f.bigDec = ""
        } else {
            f.bigInt = model.bigInt
            f.bigDec = model.bigDec
        }
        f.fadeOpacity = 1
        f.pulseOpacity = 1
        return f
    }

    /// 是否已静止（供窗口程序暂停 TimelineView）：
    /// 淡入结束、无脉冲/彗星（prefill/decode/starting 不静止）、弧值已到达目标。
    /// 只读属性，不改变 tick 的已有逻辑；未 tick 过时视为未静止。
    var isSettled: Bool {
        guard let lastTick else { return false }
        if lastTick - fadeStart < fadeDuration { return false }
        if let s = lastState, pulseState(s) { return false }
        return frame.display == targetCache
    }

    private func pulseState(_ s: PanelState) -> Bool {
        s == .prefill || s == .decode || s == .starting
    }

    /// 不透明度在 1 与 0.35 之间正弦往复，从 1 起步
    private func pulseOpacity(_ now: Double, period: Double) -> Double {
        let phase = (now - pulseStart) / period
        return 1 - 0.65 * (0.5 - 0.5 * cos(2 * .pi * phase))
    }

    /// 二次 ease-out
    private static func easeOut(_ p: Double) -> Double { p * (2 - p) }

    /// 二次 ease-in-out（与原型彗星扫动同一曲线）
    private static func easeInOut(_ p: Double) -> Double {
        p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
    }
}
