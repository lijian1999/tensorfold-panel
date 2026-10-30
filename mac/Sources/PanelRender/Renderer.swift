// 绘制：View + Frame → Core Graphics + Core Text。对应 panel/render.py（接口约定 9.2 节）。
//
// 坐标系：draw 开头把上下文按 width/480、height/320 放大，
// 之后所有坐标、尺寸都按 480×320 写（副屏真实像素 960×640 就是 2 倍）。
// 文字用 Core Text：字号用绝对尺寸（随缩放一起放大），全部开等宽数字，
// 字距用 kern（em 数 × 字号）。每段文字的垂直位置按“逻辑矩形在行框里垂直居中”算；
// 一行里几段不同样式的文字基线对齐。布局与颜色照原型 docs/dashboard-prototype.html。
import AppKit
import CoreText
import Foundation
import ImageIO
import PanelCore
import UniformTypeIdentifiers

// ---------------------------------------------------------------- 颜色

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

private let BG = rgb(0x0A, 0x0B, 0x0D)
private let CARD = rgb(0x14, 0x16, 0x1A)
private let CARD_LINE = rgb(0x1D, 0x20, 0x25)
private let TEXT = rgb(0xF3, 0xF4, 0xF6)
private let TEXT_2 = rgb(0xA7, 0xAD, 0xB6)
private let MUTED = rgb(0x8C, 0x92, 0x9B)
private let FAINT = rgb(0x55, 0x5B, 0x64)
private let ACCENT = rgb(0x76, 0xE2, 0xB7)
private let AMBER = rgb(0xF0, 0xB4, 0x4C)
private let DANGER = rgb(0xE2, 0x7A, 0x72)
private let GHOST = rgb(0x59, 0x60, 0x6A)
private let PILL_BG = rgb(0x76, 0xE2, 0xB7)      // 底色不透明度 0.15
private let PILL_BG_ALPHA = 0.15
private let PILL_TEXT = rgb(0x8E, 0xEA, 0xC5)
private let TRACK = CARD_LINE                    // 底环和卡片描边同色

private let DIAL: (Double, Double, Double) = (166, 184, 124)   // 仪表圆心 x、y 和半径
private let STRIP_Y = 23.0                                      // 状态条的垂直中心

/// 夹到 0–1。
private func clamp01(_ x: Double) -> Double {
    x < 0 ? 0 : (x > 1 ? 1 : x)
}

/// 带不透明度的颜色（对应 set_source_rgba(*color, a)）。
private func withAlpha(_ color: CGColor, _ a: Double) -> CGColor {
    color.copy(alpha: CGFloat(clamp01(a)))!
}

/// 两个颜色按 t 线性混合（对应 _mix，只混 R、G、B 分量）。
private func mix(_ c1: CGColor, _ c2: CGColor, _ t: Double) -> CGColor {
    let a = c1.components!, b = c2.components!
    let tt = CGFloat(t)
    return CGColor(srgbRed: a[0] + (b[0] - a[0]) * tt,
                   green: a[1] + (b[1] - a[1]) * tt,
                   blue: a[2] + (b[2] - a[2]) * tt, alpha: 1)
}

/// 一段文字：(文字, 字号, 是否粗, 颜色, 字距)。
private typealias TextSeg = (text: String, size: Double, bold: Bool, color: CGColor, ls: Double)

// 弧度：math.radians(d)。
nonisolated(unsafe) private var fontCache: [String: CTFont] = [:]   // 只在 fontLock 里读写
private let fontLock = NSLock()

private func rad(_ d: Double) -> CGFloat { CGFloat(d * .pi / 180) }

public final class Renderer {
    public init() {}

    // ------------------------------------------------------------ 文字

    /// 字体：系统等宽数字字体 + 字重（中文自动用苹方）。
    private func font(_ size: CGFloat, _ bold: Bool) -> CTFont {
        // 按（字号, 粗细）缓存、加锁取：多个线程同时向字体服务要字体时偶尔会互相卡住
        fontLock.lock()
        defer { fontLock.unlock() }
        let key = "\(size)|\(bold)"
        if let f = fontCache[key] { return f }
        // 等宽数字（对应 Pango 的 tnum=1）
        let f = NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont
        fontCache[key] = f
        return f
    }

    private struct TextItem {
        let line: CTLine
        let w: CGFloat     // 宽
        let h: CGFloat     // 逻辑矩形的高
        let base: CGFloat  // 基线到逻辑矩形顶边
        let color: CGColor
    }

    /// 建一段文字的布局：颜色取自上下文的填充色，字距 = ls（em 数）× 字号。
    private func makeItem(_ text: String, _ size: Double, _ bold: Bool, _ ls: Double, _ color: CGColor) -> TextItem {
        let f = font(CGFloat(size), bold)
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if ls != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = ls * size }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let h = CTFontGetAscent(f) + CTFontGetDescent(f)
        let base = CTFontGetAscent(f)
        return TextItem(line: line, w: w, h: h, base: base, color: color)
    }

    /// Seg 的样式 → (是否粗, 颜色)。
    private func style(_ style: String, _ defaultColor: CGColor) -> (Bool, CGColor) {
        if style == "strong" { return (true, TEXT_2) }
        if style == "warn" { return (true, AMBER) }
        return (false, defaultColor)
    }

    /// 一段文字占多宽（用来算后面文字的起点）。
    private func _width(_ ctx: CGContext?, _ text: String, _ size: Double, _ bold: Bool, _ ls: Double = 0) -> Double {
        if text.isEmpty { return 0 }
        return Double(makeItem(text, size, bold, ls, MUTED).w)
    }

    /// 画一行文字，返回这一行的总宽度。
    ///
    /// anchor_x 按 align 解释（left 从它起排、center 以它为中心、right 右对齐）。
    /// mode="center"：每段的逻辑矩形垂直居中在 anchor_y 这一行里；
    /// mode="baseline"：各段基线对齐；第一段（主段）的逻辑矩形垂直居中在
    /// anchor_y 的那块 34 高（或 41.4 高）的范围里，其余各段跟着它的基线走。
    @discardableResult
    private func _drawLine(_ ctx: CGContext, _ segs: [TextSeg], _ anchorX: Double, _ anchorY: Double,
                           align: String = "left", mode: String = "center", gap: Double = 0) -> Double {
        var items: [TextItem] = []
        for seg in segs {
            if seg.text.isEmpty { continue }
            let item = makeItem(seg.text, seg.size, seg.bold, seg.ls, seg.color)
            if item.w > 0 && item.h > 0 { items.append(item) }
        }
        if items.isEmpty { return 0 }
        let total = items.reduce(0.0) { $0 + Double($1.w) } + gap * Double(items.count - 1)
        var x: CGFloat
        if align == "center" {
            x = CGFloat(anchorX - total / 2)
        } else if align == "right" {
            x = CGFloat(anchorX - total)
        } else {
            x = CGFloat(anchorX)
        }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        if mode == "baseline" {
            let main = items[0]
            let baseY = anchorY - Double(main.h) / 2 + Double(main.base)
            for it in items {
                ctx.setFillColor(it.color)
                ctx.textPosition = CGPoint(x: x, y: CGFloat(baseY))
                CTLineDraw(it.line, ctx)
                x += it.w + CGFloat(gap)
            }
        } else {
            for it in items {
                ctx.setFillColor(it.color)
                // 每段的顶边是 anchor_y - h / 2，基线是顶边加 base
                ctx.textPosition = CGPoint(x: x, y: CGFloat(anchorY) - it.h / 2 + it.base)
                CTLineDraw(it.line, ctx)
                x += it.w + CGFloat(gap)
            }
        }
        return total
    }

    /// 一段文字，垂直居中在 y。
    @discardableResult
    private func _text(_ ctx: CGContext, _ text: String, _ size: Double, _ x: Double, _ y: Double,
                       _ color: CGColor = MUTED, _ bold: Bool = false, align: String = "left",
                       ls: Double = 0) -> Double {
        if text.isEmpty { return 0 }
        return _drawLine(ctx, [(text, size, bold, color, ls)], x, y, align: align)
    }

    // ------------------------------------------------------------ 小块

    /// 整块乘一个不透明度（重叠处不会透出来）。不透明度 1 时不用 group。
    private func _block(_ ctx: CGContext, _ alpha: Double, _ drawFn: () -> Void) {
        if alpha <= 0 { return }
        if alpha >= 1 { drawFn(); return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawFn()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 圆角矩形的路径。
    private func _rrect(_ ctx: CGContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) {
        let rr = min(r, w / 2, h / 2)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                           cornerWidth: rr, cornerHeight: rr, transform: nil))
    }

    /// 实心圆点。
    private func _circle(_ ctx: CGContext, _ cx: Double, _ cy: Double, _ r: Double,
                         _ color: CGColor, _ alpha: Double = 1.0) {
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.setFillColor(withAlpha(color, alpha))
        ctx.fillPath()
    }

    // ------------------------------------------------------------ 状态条

    /// 流指示点：解码中（薄荷绿）→ 预填充中（琥珀）→ 空着（灰）。
    private func _dots(_ ctx: CGContext, _ lanes: Lanes, _ n: Int, _ frame: Frame) {
        let dec = max(0, lanes.decoding)
        let pre = max(0, lanes.prefilling)
        for i in 0..<n {
            let color: CGColor
            let alpha: Double
            if i < dec {
                color = ACCENT; alpha = clamp01(frame.pulseDec)
            } else if i < dec + pre {
                color = AMBER; alpha = clamp01(frame.pulsePre)
            } else {
                color = FAINT; alpha = 0.5
            }
            _circle(ctx, 14 + 3.5 + 11 * Double(i), STRIP_Y, 3.5, color, alpha)
        }
    }

    /// 状态条：流指示点、排队数、状态名、模型名、右侧文字。
    private func _strip(_ ctx: CGContext, _ view: View, _ frame: Frame) {
        let lanes = view.lanes
        var x = 14.0
        if lanes.offline {
            // 离线：只有一个红点，直径 8
            _circle(ctx, 18, STRIP_Y, 4, DANGER)
            x = 22 + 8
        } else {
            let n = max(0, min(12, lanes.max))
            let right = n != 0 ? 14 + 11 * Double(n) - 4 : 14.0   // 最后一个点的右边缘
            if n != 0 { _dots(ctx, lanes, n, frame) }
            if lanes.waiting > 0 {
                let text = "+\(lanes.waiting)"
                let w = _width(ctx, text, 12, true)
                _text(ctx, text, 12, right + 5, STRIP_Y, AMBER, true)
                x = right + 5 + w + 8
            } else {
                x = right + 8
            }
        }
        if !view.stateName.isEmpty {
            let w = _width(ctx, view.stateName, 14, true)
            _text(ctx, view.stateName, 14, x, STRIP_Y, TEXT, true)
            x += w + 8
        }
        var rightW = 0.0
        if !view.stripRight.isEmpty {
            let segs: [TextSeg] = view.stripRight.map { seg in
                let (b, c) = style(seg.style, MUTED)
                return (seg.text, 13, b, c, 0.0)
            }
            rightW = _drawLine(ctx, segs, 466, STRIP_Y, align: "right")
        }
        if !view.stripLeft.isEmpty {
            // 模型名太长时截短加“…”，不压到右边的文字
            let room = 466 - rightW - (rightW > 0 ? 10 : 0) - x
            _text(ctx, _fit(view.stripLeft, 13, room), 13, x, STRIP_Y, MUTED)
        }
    }

    /// 放不下 maxW 时从末尾删字、加“…”；一个字也放不下就返回空串。
    private func _fit(_ text: String, _ size: Double, _ maxW: Double) -> String {
        if _width(nil, text, size, false) <= maxW { return text }
        var s = text
        while !s.isEmpty {
            s.removeLast()
            let t = s.trimmingCharacters(in: .whitespaces) + "…"
            if _width(nil, t, size, false) <= maxW { return t }
        }
        return ""
    }

    // ------------------------------------------------------------ 仪表

    /// 仪表：底环、刻度缺口、灰色小点、数值弧、刻度数字。
    ///
    /// 圆弧位置 f 对应的角度 = 135° + 270°×f（y 轴向下，角度增大是顺时针）。
    private func _dial(_ ctx: CGContext, _ view: View, _ frame: Frame) {
        let (cx, cy, r) = DIAL
        if frame.trackAlpha > 0 {
            ctx.setLineWidth(14)
            ctx.setLineCap(.round)
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                       startAngle: rad(135), endAngle: rad(405), clockwise: false)
            ctx.setStrokeColor(withAlpha(TRACK, clamp01(frame.trackAlpha)))
            ctx.strokePath()
        }
        if frame.notchAlpha > 0 {
            // 刻度缺口：用底色在底环上画四道缺口（半透明时不能直接擦出洞）
            ctx.setLineWidth(2.5)
            ctx.setLineCap(.butt)
            for f in tickFracs {
                if !(0 < f && f < 1) { continue }
                let a = (135 + 270 * f) * .pi / 180
                let ca = cos(a), sa = sin(a)
                ctx.move(to: CGPoint(x: cx + (r - 8) * ca, y: cy + (r - 8) * sa))
                ctx.addLine(to: CGPoint(x: cx + (r + 8) * ca, y: cy + (r + 8) * sa))
            }
            ctx.setStrokeColor(withAlpha(BG, clamp01(frame.notchAlpha)))
            ctx.strokePath()
        }
        if let ghost = view.ghost, frame.ghostAlpha > 0 {
            let a = (135 + 270 * clamp01(ghost)) * .pi / 180
            _circle(ctx, cx + r * cos(a), cy + r * sin(a), 7, GHOST, frame.ghostAlpha)
        }
        if frame.valueAlpha > 0 {
            ctx.setLineWidth(14)
            ctx.setLineCap(.round)
            if frame.arcFrac <= 0 {
                // 弧长为零：画成起点处的一个圆点
                let a: Double = 135 * .pi / 180
                _circle(ctx, cx + r * cos(a), cy + r * sin(a), 7,
                        mix(ACCENT, AMBER, clamp01(frame.arcMix)), clamp01(frame.valueAlpha))
            } else {
                let a0: Double = 135 * .pi / 180
                ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                           startAngle: CGFloat(a0),
                           endAngle: CGFloat(a0 + 270 * clamp01(frame.arcFrac) * .pi / 180),
                           clockwise: false)
                // 数值弧的颜色：薄荷绿 → 琥珀色按 mix 混合
                ctx.setStrokeColor(withAlpha(mix(ACCENT, AMBER, clamp01(frame.arcMix)), clamp01(frame.valueAlpha)))
                ctx.strokePath()
            }
        }
        ctx.setLineCap(.butt)
    }

    /// 刻度数字：六个，位置见任务说明。
    private func _ticks(_ ctx: CGContext, _ view: View, _ frame: Frame) {
        if frame.ticksAlpha <= 0 { return }
        let labels = (scales[view.scale] ?? scales["decode"]!).labels
        let (cx, cy, r) = DIAL
        for (f, label) in zip(tickFracs, labels) {
            let a = (135 + 270 * f) * .pi / 180
            let c = cos(a)
            let r2: Double
            let align: String
            if c < -0.85 {
                r2 = r + 12; align = "right"
            } else if c > 0.85 {
                r2 = r + 12; align = "left"
            } else {
                r2 = r + 20; align = "center"
            }
            _text(ctx, label, 12, cx + r2 * cos(a), cy + r2 * sin(a), MUTED, true, align: align)
        }
    }

    /// 标题行：标题（· 单位），后面可能跟一个“精确”或“近期平均”标记，整体水平居中。
    private func _capLine(_ ctx: CGContext, _ view: View) {
        let text = view.unit.isEmpty ? view.cap : "\(view.cap) · \(view.unit)"
        let pillText = view.pillKind == "avg" ? "近期平均" : "精确"
        let wCap = text.isEmpty ? 0.0 : _width(ctx, text, 13, false)
        let wPill = view.pill ? _width(ctx, pillText, 12, true, 0.04) + 14 : 0.0
        let gap = (!text.isEmpty && view.pill) ? 6.0 : 0.0
        let x = 166 - (wCap + gap + wPill) / 2
        if !text.isEmpty {
            _text(ctx, text, 13, x, 128, MUTED)
        }
        guard view.pill else { return }
        let px = x + wCap + gap
        if view.muted {
            // 灰色画面：没有底色，改画 1 宽的内侧描边，文字变灰
            _rrect(ctx, px + 0.5, 119.5, wPill - 1, 17, 8.5)
            ctx.setLineWidth(1)
            ctx.setStrokeColor(FAINT)
            ctx.strokePath()
            _text(ctx, pillText, 12, px + 7, 128, MUTED, true, ls: 0.04)
        } else if view.pillKind == "avg" {
            // “近期平均”：不填底色，琥珀色描边 + 琥珀色文字，和实心的“精确”区分开
            _rrect(ctx, px + 0.5, 119.5, wPill - 1, 17, 8.5)
            ctx.setLineWidth(1)
            ctx.setStrokeColor(withAlpha(AMBER, 0.5))
            ctx.strokePath()
            _text(ctx, pillText, 12, px + 7, 128, AMBER, true, ls: 0.04)
        } else {
            _rrect(ctx, px, 119, wPill, 18, 9)
            ctx.setFillColor(withAlpha(PILL_BG, PILL_BG_ALPHA))
            ctx.fillPath()
            _text(ctx, pillText, 12, px + 7, 128, PILL_TEXT, true, ls: 0.04)
        }
    }

    /// 主数字：整数部分 + 小数部分，基线对齐，整体水平居中。
    private func _big(_ ctx: CGContext, _ view: View, _ frame: Frame) {
        let size: Double = ["normal": 96.0, "four": 76.0, "cost": 68.0][view.bigSize] ?? 96
        let color = view.muted ? TEXT_2 : TEXT
        if view.bigWhole {
            // 小数部分和整数部分同字号、同字距，紧接着排
            let segs: [TextSeg] = [frame.bigInt, frame.bigDec]
                .filter { !$0.isEmpty }
                .map { ($0, size, true, color, -0.035) }
            _drawLine(ctx, segs, 166, 185, align: "center", mode: "baseline")
        } else {
            var segs: [TextSeg] = [(frame.bigInt, size, true, color, -0.035)]
            if !frame.bigDec.isEmpty {
                segs.append((frame.bigDec, 40, true, color, -0.01))
            }
            _drawLine(ctx, segs, 166, 185, align: "center", mode: "baseline", gap: 1)
        }
    }

    /// 主数字下面那块：上下文条 / 预填充进度条 / 一行说明。
    private func _bar(_ ctx: CGContext, _ view: View, _ frame: Frame) {
        guard let bar = view.bar else { return }
        let y: Double
        if bar.kind == "ctx" || bar.kind == "prog" {
            _rrect(ctx, 106, 245, 120, 6, 3)
            ctx.setFillColor(TRACK)
            ctx.fillPath()
            let color: CGColor
            if bar.kind == "prog" {
                color = AMBER
            } else if bar.level == "full" {
                color = DANGER
            } else if bar.level == "warn" {
                color = AMBER
            } else {
                color = TEXT_2
            }
            _rrect(ctx, 106, 245, min(max(6, 120 * clamp01(frame.barFrac)), 120), 6, 3)
            ctx.setFillColor(color)
            ctx.fillPath()
            y = 263
        } else if bar.kind == "note" {
            y = 247
        } else {
            return
        }
        if !bar.text.isEmpty {
            let segs: [TextSeg] = bar.text.map { seg in
                let (b, c) = style(seg.style, MUTED)
                return (seg.text, 12, b, c, 0.0)
            }
            _drawLine(ctx, segs, 166, y, align: "center")
        }
    }

    /// 仪表盘中间那块。
    private func _center(_ ctx: CGContext, _ view: View, _ frame: Frame) {
        if view.state == "offline" {
            _text(ctx, "引擎离线", 28, 166, 166, TEXT_2, true, align: "center")
            _text(ctx, "等待引擎响应…", 13, 166, 199, MUTED, false, align: "center")
            return
        }
        if !view.cap.isEmpty || !view.unit.isEmpty { _capLine(ctx, view) }
        if !frame.bigInt.isEmpty || !frame.bigDec.isEmpty { _big(ctx, view, frame) }
        if view.bar != nil { _bar(ctx, view, frame) }
    }

    // ------------------------------------------------------------ 右侧三栏

    /// 一张卡片：圆角矩形 + 内侧描边，里面最多三行文字，整体垂直居中。
    private func _card(_ ctx: CGContext, _ view: View, _ card: Card, _ y0: Double) {
        _rrect(ctx, 336, y0, 132, 85.33, 14)
        ctx.setFillColor(CARD)
        ctx.fillPath()
        _rrect(ctx, 336.5, y0 + 0.5, 131, 84.33, 13.5)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CARD_LINE)
        ctx.strokePath()
        if card.label.isEmpty && card.value.isEmpty && card.foot.isEmpty { return }
        let hVal = card.unit.isEmpty ? 34.0 : 41.4
        let top = y0 + (85.33 - (16 + hVal + (card.foot.isEmpty ? 0 : 16))) / 2
        if !card.label.isEmpty {
            _text(ctx, card.label, 13, 349, top + 8, MUTED)
        }
        if !card.value.isEmpty {
            let color: CGColor
            if card.pending {
                color = FAINT
            } else if view.muted || view.state == "offline" {
                color = TEXT_2
            } else {
                color = TEXT
            }
            var segs: [TextSeg] = [(card.value, 30, true, color, -0.02)]
            if !card.unit.isEmpty {
                segs.append((card.unit, 13, true, MUTED, 0.0))
            }
            _drawLine(ctx, segs, 349, top + 16 + 17, align: "left", mode: "baseline", gap: 4)
        }
        if !card.foot.isEmpty {
            _text(ctx, card.foot, 13, 349, top + 16 + hVal + 8, MUTED)
        }
    }

    /// 右侧三栏。
    private func _cards(_ ctx: CGContext, _ view: View, _ frame: Frame) {
        for (i, card) in view.cards.prefix(3).enumerated() {
            _card(ctx, view, card, 40 + 91.33 * Double(i))
        }
    }

    // ------------------------------------------------------------ 入口

    /// 画一帧。开头 saveGState + scaleBy，结尾 restoreGState，并设回文字矩阵。
    public func draw(_ ctx: CGContext, view: View, frame: Frame, width: Double = 960, height: Double = 640) {
        let tm0 = ctx.textMatrix                       // save/restore 不保存文字矩阵，自己还原
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(width / 480), y: CGFloat(height / 320))
        ctx.setFillColor(BG)
        ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
        _block(ctx, frame.stripAlpha) { self._strip(ctx, view, frame) }
        _dial(ctx, view, frame)
        _block(ctx, frame.ticksAlpha) { self._ticks(ctx, view, frame) }
        _block(ctx, frame.centerAlpha) { self._center(ctx, view, frame) }
        _block(ctx, frame.statsAlpha) { self._cards(ctx, view, frame) }
        if frame.dim < 1 {
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CGFloat(1 - frame.dim)))
            ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
        }
        ctx.restoreGState()
        ctx.textMatrix = tm0
    }

    /// 新建一张左上角原点、y 向下的位图：sRGB，每像素 4 字节 R、G、B、A。
    public static func makeContext(width: Int, height: Int) -> CGContext? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)          // 左上角原点、y 向下
        return ctx
    }

    /// 画到新位图上，frame 为 nil 时用 Animator.settled(view)。
    public func makeImage(view: View, frame: Frame? = nil, width: Int = 960, height: Int = 640) -> CGImage? {
        guard let ctx = Renderer.makeContext(width: width, height: height) else { return nil }
        draw(ctx, view: view, frame: frame ?? Animator.settled(view),
             width: Double(width), height: Double(height))
        return ctx.makeImage()
    }

    /// 写成 PNG（960×640），成功返回 true。
    public func renderPNG(view: View, path: String, frame: Frame? = nil) -> Bool {
        guard let img = makeImage(view: view, frame: frame) else { return false }
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}
