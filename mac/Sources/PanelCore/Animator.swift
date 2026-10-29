// 动画：视图模型 → 每一帧的数值。只算数，不读时钟、不做 I/O。
//
// 对应原型 dashboard-prototype.html 里的三处：
// - CSS 的 transition（圆弧位置 0.4 秒缓动、不透明度 0.6 秒线性、整屏亮度 0.3/秒）
// - @keyframes pulse（流指示点 1.4 秒 / 1 秒的余弦脉冲）
// - @keyframes swapin 和 frame() 里的"缓动"那一段（主数字 0.25 秒刷一次、三块 0.32 秒淡入）
import Foundation

// 时间常数与速度，和原型一致
private let TAU = 0.4                  // 圆弧位置 / 主数字的缓动时间常数（秒）
private let MIX_RATE = 1 / 0.4         // 圆弧颜色：0.4 秒走完全程（每秒 2.5）
private let ALPHA_RATE = 1 / 0.6       // 五个不透明度：0.6 秒走完全程
private let FADE_FAST = 0.32           // 普通淡入时长（秒）
private let FADE_SLOW = 0.8            // 慢淡入时长：完成 → 空闲
private let MAX_DT = 0.1               // 一帧最多推进多久，隔太久没画也不许一步跳到目标
private let DIM_RATE = 0.3             // 整屏变暗的速度：每秒 0.3
private let PULSE_DEC = 1.4            // 解码脉冲周期（秒）
private let PULSE_PRE = 1.0            // 预填充脉冲周期（秒）
private let ALPHA_FLOOR = 0.15         // 淡入起始不透明度
private let EPS = 1e-9                 // 视为"已经到目标"的误差

/// 画一帧需要的全部数值。
public struct Frame: Equatable, Sendable {
    public var arcFrac: Double = 0.0        // 数值弧当前位置 0–1
    public var arcMix: Double = 0.0         // 数值弧颜色：0 薄荷绿，1 琥珀色
    public var valueAlpha: Double = 0.0     // 数值弧
    public var ghostAlpha: Double = 0.0     // 灰色小点
    public var ticksAlpha: Double = 0.0     // 刻度数字（已乘上切换刻度时的淡入）
    public var trackAlpha: Double = 0.5     // 底环
    public var notchAlpha: Double = 0.0     // 底环上的刻度缺口
    public var bigInt: String = ""          // 这一帧实际显示的主数字
    public var bigDec: String = ""
    public var barFrac: Double = 0.0        // 条的当前长度
    public var centerAlpha: Double = 1.0    // 中间区域淡入
    public var statsAlpha: Double = 1.0     // 右侧三栏淡入
    public var stripAlpha: Double = 1.0     // 状态条淡入
    public var pulseDec: Double = 1.0       // 解码中的流指示点的不透明度
    public var pulsePre: Double = 1.0       // 预填充中的流指示点的不透明度
    public var dim: Double = 1.0            // 整屏亮度
    public var animating: Bool = false      // 还有动画没走完（窗口据此决定要不要继续重画）

    public init() {}
}

/// 夹到 0–1，和原型的 clamp01 一样。
private func clamp01(_ x: Double) -> Double {
    x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x)
}

/// 线性走向目标。一步就能走完时直接等于目标。
/// 返回 (新值, 是否还没到目标)。
private func linear(_ cur: Double, _ target: Double, _ stride: Double) -> (Double, Bool) {
    let gap = target - cur
    if abs(gap) <= max(stride, EPS) { return (target, false) }
    return (clamp01(cur + copysign(stride, gap)), true)
}

/// 圆弧各部分不透明度的目标值，按 view.arc。
private func alphaTargets(_ view: View) -> [String: Double] {
    if view.arc == "value" || view.arc == "prefill" {
        return ["value": 1.0, "ghost": 0.0, "ticks": 1.0, "track": 1.0, "notch": 1.0]
    }
    if view.arc == "rest" {
        // 灰色小点：有位置才画，0.9 是原型里 --ghost 的不透明度
        return ["value": 0.0, "ghost": view.ghost != nil ? 0.9 : 0.0,
                "ticks": 0.75, "track": 1.0, "notch": 1.0]
    }
    // blank / off：只剩暗底环
    return ["value": 0.0, "ghost": 0.0, "ticks": 0.0, "track": 0.5, "notch": 0.0]
}

/// 流指示点的脉冲，等价于 @keyframes pulse：1 → 0.35 → 1。
private func pulse(_ now: Double, _ period: Double) -> Double {
    clamp01(0.675 + 0.325 * cos(2 * Double.pi * now / period))
}

/// 一次淡入：什么时候开始、走多久、是不是慢淡入。
private struct Fade {
    let start: Double
    let duration: Double
    let slow: Bool

    /// 这一刻还在淡入途中吗。
    func running(_ now: Double) -> Bool {
        (now - start) < duration
    }

    /// 淡入进行到 e 秒时的不透明度；键变化的那一帧是 0.15。
    func alpha(_ now: Double) -> Double {
        let e = now - start
        if e >= duration { return 1.0 }
        let p = min(1.0, max(0.0, e / duration))
        if slow {
            return ALPHA_FLOOR + 0.85 * (p * p * (3 - 2 * p))   // ease-in-out
        }
        return ALPHA_FLOOR + 0.85 * (1 - (1 - p) * (1 - p))      // ease-out
    }
}

/// 决定每一块要不要淡入的"内容键"（Python 里是元组 / 字符串，这里按块区分类型）。
private enum PartKey: Equatable {
    case center(String, String, Bool, Bool, Bool)
    case stats([String])
    case strip(String)
}

/// 把一串 View 变成一串 Frame。每个画面用一个 Animator；step 不读时钟。
public final class Animator {
    private var _now: Double?                  // 上一次调用的时刻，nil = 第一次
    private var _arcFrac: Double = 0.0
    private var _arcMix: Double = 0.0
    private var _alphas: [String: Double] = [:]   // 五个不透明度的当前值（value/ghost/ticks/track/notch）
    private var _ticksFade: Fade?
    private var _scale: String?
    private var _display: Double?              // 缓动中的解码速度，nil = 上一帧不是实时数字
    private var _bigAt: Double = 0.0           // 上次刷新主数字文字的时刻
    private var _big: String = ""              // 上一帧显示的主数字文字
    private var _barFrac: Double = 0.0
    private var _barKind: String?
    private var _dim: Double = 1.0
    private var _fades: [String: Fade] = [:]   // 没有条目 = 这一块不在淡入
    private var _keys: [String: PartKey] = [:]

    public init() {}

    /// 所有动画都走完时的那一帧（静止画面、离屏截图用）。
    public static func settled(_ view: View) -> Frame {
        let targets = alphaTargets(view)
        var f = Frame()
        f.arcFrac = view.arcTarget.map(clamp01) ?? 0.0
        f.arcMix = view.arc == "prefill" ? 1.0 : 0.0
        f.valueAlpha = targets["value"]!
        f.ghostAlpha = targets["ghost"]!
        f.ticksAlpha = targets["ticks"]!
        f.trackAlpha = targets["track"]!
        f.notchAlpha = targets["notch"]!
        f.bigInt = view.bigInt
        f.bigDec = view.bigDec
        f.barFrac = view.bar.map { clamp01($0.frac) } ?? 0.0
        f.centerAlpha = 1.0
        f.statsAlpha = 1.0
        f.stripAlpha = 1.0
        f.pulseDec = 1.0
        f.pulsePre = 1.0
        f.dim = clamp01(view.dim)
        f.animating = false
        return f
    }

    /// 算 now 这一帧。第一次调用给出动画已经走完的那一帧。
    public func step(_ view: View, now: Double) -> Frame {
        let first = _now == nil
        let dt = first ? 0.0 : min(MAX_DT, max(0.0, now - _now!))
        _now = now
        let k = dt > 0 ? 1.0 - exp(-dt / TAU) : 0.0

        // 1) 圆弧位置：指数缓动；没有目标就停在原地
        let arcFrac: Double
        let arcDone: Bool
        if first {
            arcFrac = view.arcTarget.map(clamp01) ?? 0.0
            arcDone = true
        } else if view.arcTarget == nil {
            arcFrac = _arcFrac
            arcDone = true
        } else if let tgt = view.arcTarget, abs(tgt - _arcFrac) < 0.0005 {
            arcFrac = clamp01(tgt)
            arcDone = true
        } else {
            let tgt = view.arcTarget!
            arcFrac = _arcFrac + (tgt - _arcFrac) * k
            arcDone = false
        }
        _arcFrac = clamp01(arcFrac)

        // 2) 圆弧颜色：prefill 是琥珀色，其余回到薄荷绿
        let mixTarget = view.arc == "prefill" ? 1.0 : 0.0
        let arcMix: Double
        let mixDone: Bool
        if first {
            arcMix = mixTarget
            mixDone = true
        } else {
            let (m, moving) = linear(_arcMix, mixTarget, dt * MIX_RATE)
            arcMix = clamp01(m)
            mixDone = !moving
        }
        _arcMix = arcMix

        // 3) 五个不透明度：0.6 秒走完全程
        let targets = alphaTargets(view)
        var alpha: [String: Double] = [:]
        var alphaDone = true
        for (key, tgt) in targets {
            let (value, moving) = linear(_alphas[key] ?? tgt, tgt, dt * ALPHA_RATE)
            alpha[key] = clamp01(value)
            alphaDone = alphaDone && !moving
        }

        // 4) 切换刻度时淡入一次，结果再乘上第 3 条算出的不透明度
        let ticksFade: Fade?
        if first {
            ticksFade = nil
        } else if view.scale != _scale {
            ticksFade = Fade(start: now, duration: FADE_FAST, slow: false)
        } else {
            ticksFade = _ticksFade
        }
        let ticksMoving = ticksFade?.running(now) ?? false
        let ticksFactor = ticksFade?.alpha(now) ?? 1.0
        let ticksAlpha = clamp01(alpha["ticks"]! * ticksFactor)

        // 5) 主数字
        let bigInt: String
        let bigDec: String
        let bigMoving: Bool
        if let bv = view.bigValue {
            let jump = first || _display == nil      // 上一帧不是实时数字
            let display: Double
            if jump {
                display = bv                         // 直接取新值，立刻刷新显示
            } else {
                let prev = _display!
                let gap = bv - prev
                display = abs(gap) < 0.02 ? bv : prev + gap * k
            }
            _display = display
            let shown = String(jsRound(display))
            if jump || now - _bigAt >= 0.25 {
                bigInt = shown
                _bigAt = now                         // 每 0.25 秒最多刷新一次
            } else {
                bigInt = _big.isEmpty ? shown : _big
            }
            bigDec = ""
            bigMoving = abs(bv - display) >= 0.02 || bigInt != shown
        } else {
            bigInt = view.bigInt
            bigDec = view.bigDec
            _display = nil
            bigMoving = false
        }
        _big = bigInt

        // 6) 三块淡入：内容标签（键）变了才淡入，第一次调用不淡入
        //（键缺失时用 _MISSING 哨兵，Python 里必然和任何键不相等 → 这里用 nil 比较实现）
        let keys: [String: PartKey] = [
            "center": .center(view.cap, view.unit, view.bigWhole, view.muted,
                              view.state == "offline"),
            "stats": .stats(view.cards.map(\.label)),
            "strip": .strip(view.stateName),
        ]
        var fades: [String: Fade] = [:]
        for (part, key) in keys {
            if first {
                fades.removeValue(forKey: part)
            } else if _keys[part] != key {
                // 键变了就从头淡入；slow_fade 为真时用 0.8 秒慢淡入
                fades[part] = Fade(start: now, duration: view.slowFade ? FADE_SLOW : FADE_FAST,
                                   slow: view.slowFade)
            } else if let kept = _fades[part] {
                fades[part] = kept
            } else {
                fades.removeValue(forKey: part)
            }
        }
        let fadeMoving = fades.values.contains { $0.running(now) }
        let centerAlpha = fades["center"]?.alpha(now) ?? 1.0
        let statsAlpha = fades["stats"]?.alpha(now) ?? 1.0
        let stripAlpha = fades["strip"]?.alpha(now) ?? 1.0

        // 7) 条的长度
        var barFrac: Double
        let barDone: Bool
        if view.bar == nil {
            barFrac = 0.0
            _barKind = nil
            barDone = true
        } else if first || view.bar!.kind != _barKind {
            // 上一帧没有条，或者换了一种条：直接等于新的长度
            barFrac = clamp01(view.bar!.frac)
            _barKind = view.bar!.kind
            barDone = true
        } else {
            let tgt = clamp01(view.bar!.frac)
            let gap = tgt - _barFrac
            if abs(gap) < 0.001 {
                barFrac = tgt
            } else {
                barFrac = _barFrac + gap * k
            }
            barDone = barFrac == tgt
        }
        _barFrac = barFrac

        // 8) 流指示点的脉冲；离线时只画一个红点，不参与脉冲
        let lanes = view.lanes
        let pulseDec: Double
        let pulsePre: Double
        let pulseMoving: Bool
        if lanes.offline {
            pulseDec = 1.0
            pulsePre = 1.0
            pulseMoving = false
        } else {
            pulseDec = lanes.decoding != 0 ? pulse(now, PULSE_DEC) : 1.0
            pulsePre = lanes.prefilling != 0 ? pulse(now, PULSE_PRE) : 1.0
            pulseMoving = lanes.decoding != 0 || lanes.prefilling != 0
        }

        // 9) 整屏亮度：变暗慢慢来（每秒 0.3），变亮立刻回
        let dimTarget = clamp01(view.dim)
        let dim: Double
        let dimDone: Bool
        if first || _dim <= dimTarget + EPS {
            dim = dimTarget
            dimDone = true
        } else {
            dim = max(dimTarget, _dim - DIM_RATE * dt)
            dimDone = dim == dimTarget
        }
        _dim = dim

        // 10) 还有没走完的动画就一直重画
        let animating = !(arcDone && mixDone && alphaDone && barDone && dimDone)
            || ticksMoving || fadeMoving || bigMoving || pulseMoving

        // 记下这一帧的状态，供下一帧接着算
        _alphas = alpha
        _ticksFade = ticksFade
        _scale = view.scale
        _fades = fades
        _keys = keys

        var frame = Frame()
        frame.arcFrac = arcFrac
        frame.arcMix = arcMix
        frame.valueAlpha = alpha["value"]!
        frame.ghostAlpha = alpha["ghost"]!
        frame.ticksAlpha = ticksAlpha
        frame.trackAlpha = alpha["track"]!
        frame.notchAlpha = alpha["notch"]!
        frame.bigInt = bigInt
        frame.bigDec = bigDec
        frame.barFrac = barFrac
        frame.centerAlpha = centerAlpha
        frame.statsAlpha = statsAlpha
        frame.stripAlpha = stripAlpha
        frame.pulseDec = pulseDec
        frame.pulsePre = pulsePre
        frame.dim = dim
        frame.animating = animating
        return frame
    }
}
