import SwiftUI
import PanelCore

/// 整块 480×320 屏幕（所有尺寸 = 设计单位 × `scale`，不用 scaleEffect，避免糊）。
/// 坐标原点 = 屏幕左上角，与原型 CSS px 一一对应。
struct PanelScreenView: View {
    let model: PanelViewModel
    let frame: PanelAnimator.Frame
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.bg)
            StripView(model: model, frame: frame, s: s)
                .frame(width: 456 * s, height: 22 * s)
                .position(x: (12 + 456 / 2) * s, y: (12 + 11) * s)          // 状态条 x=12,y=12
            GaugeView(model: model, frame: frame, s: s)
                .frame(width: 316 * s, height: 268 * s)
                .position(x: (12 + 316 / 2) * s, y: (40 + 268 / 2) * s)      // 仪表区 x=12,y=40
            CardsView(model: model, frame: frame, s: s)
                .frame(width: 132 * s, height: 268 * s)
                .position(x: (336 + 132 / 2) * s, y: (40 + 268 / 2) * s)     // 卡片列 x=336,y=40
        }
        .frame(width: 480 * s, height: 320 * s, alignment: .topLeading)
    }
}

// MARK: - 状态条

/// 圆点 → 状态名 → stripLeft → 弹性空白 → stripRight；超长时右侧尾部截断。
struct StripView: View {
    let model: PanelViewModel
    let frame: PanelAnimator.Frame
    let s: CGFloat

    var body: some View {
        HStack(spacing: 8 * s) {
            Circle()
                .fill(dotColor)
                .frame(width: 8 * s, height: 8 * s)
                .opacity(frame.pulseOpacity)
            Text(model.stateName)
                .font(.system(size: 14 * s, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .fixedSize()
            Text(model.stripLeft)
                .font(.system(size: 13 * s).monospacedDigit())
                .foregroundColor(Theme.muted)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8 * s)
            if !model.stripRight.isEmpty {
                stripRightText
            }
        }
        .padding(.horizontal, 2 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(frame.stripOpacity)
    }

    /// 圆点颜色：offline danger、unavailable/starting/prefill amber、idle faint、decode/done accent
    private var dotColor: Color {
        switch model.state {
        case .offline: return Theme.danger
        case .unavailable: return Theme.amber
        case .starting: return Theme.amber
        case .idle: return Theme.faint
        case .prefill: return Theme.amber
        case .decode: return Theme.accent
        case .done: return Theme.accent
        }
    }

    /// 右侧文本段连成一条（bold 段用 text2 + semibold），整条尾部截断
    private var stripRightText: some View {
        var a = AttributedString()
        for seg in model.stripRight {
            var piece = AttributedString(seg.text)
            piece.font = .system(size: 13 * s, weight: seg.bold ? .semibold : .regular).monospacedDigit()
            piece.foregroundColor = seg.bold ? Theme.text2 : Theme.muted
            a += piece
        }
        return Text(a).lineLimit(1).truncationMode(.tail)
    }
}

// MARK: - 仪表（270° 圆弧 + 中心文字）

struct GaugeView: View {
    let model: PanelViewModel
    let frame: PanelAnimator.Frame
    let s: CGFloat

    var body: some View {
        ZStack {
            DialView(model: model, display: frame.display, s: s)
            CenterView(model: model, frame: frame, s: s)
                .opacity(frame.centerOpacity)
        }
    }
}

/// 整条 270° 弧的 Shape（路径坐标 = 仪表区左上角原点，支持 .trim 画部分弧）
struct DialArc: InsettableShape {
    var inset: CGFloat = 0
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        DialView.arcPath(s: scale)
    }

    func inset(by amount: CGFloat) -> DialArc {
        var c = self
        c.inset += amount
        return c
    }
}

/// 圆弧部分：轨道 → 刻痕 → 残影点 → 数值弧 → 刻度数字
struct DialView: View {
    let model: PanelViewModel
    /// 缓动后的弧值（tok/s）
    let display: Double
    let s: CGFloat

    var body: some View {
        let arc = model.arc
        let full = DialArc(scale: s)
        let sw = CGFloat(Gauge.strokeWidth) * s
        ZStack {
            // 1. 轨道（off 时 0.5）
            full
                .stroke(Theme.track, style: StrokeStyle(lineWidth: sw, lineCap: .round))
                .opacity(arc == .off ? 0.5 : 1)
            // 2. 刻痕（轨道上的缺口，bg 色）
            Self.notches(s: s)
                .stroke(Theme.bg, lineWidth: CGFloat(2.5) * s)
            // 3. 空闲时的「上次位置」残影点
            if arc == .rest, let g = model.ghostFraction {
                Circle()
                    .fill(Theme.ghost)
                    .frame(width: 14 * s, height: 14 * s)
                    .position(Self.pt(g, s: s))
                    .opacity(0.9)
            }
            // 4. 数值弧（decode/done）
            if arc == .value {
                full.trim(from: 0, to: Gauge.valueToFraction(display))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: sw, lineCap: .round))
            }
            // 5. 刻度数字（off 0.35、rest 0.75、其他 1）
            tickLabels.opacity(arc == .off ? 0.35 : (arc == .rest ? 0.75 : 1))
        }
    }

    /// 整条 225° → −45° 弧（≥180 个采样点连成，供 trim 用）
    nonisolated static func arcPath(s: CGFloat) -> Path {
        var p = Path()
        let n = 180
        for i in 0...n {
            let f = Double(i) / Double(n)
            let pt = scaled(Gauge.point(Gauge.fractionToDegrees(f), Gauge.R), s)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    /// 刻痕：tickFractions 中 0 和 1 之间的位置，R−8 → R+8
    nonisolated static func notches(s: CGFloat) -> Path {
        var p = Path()
        for f in Gauge.tickFractions where f > 0 && f < 1 {
            let deg = Gauge.fractionToDegrees(f)
            p.move(to: scaled(Gauge.point(deg, Gauge.R - 8), s))
            p.addLine(to: scaled(Gauge.point(deg, Gauge.R + 8), s))
        }
        return p
    }

    /// 弧上某位置的中心点（× scale）
    nonisolated static func pt(_ f: Double, s: CGFloat) -> CGPoint {
        scaled(Gauge.point(Gauge.fractionToDegrees(f), Gauge.R), s)
    }

    nonisolated static func scaled(_ p: CGPoint, _ s: CGFloat) -> CGPoint {
        CGPoint(x: p.x * s, y: p.y * s)
    }

    /// 刻度数字：12 号 semibold muted。
    /// 44 宽框的**边缘**落在锚点 x（模拟 text-anchor）：
    /// end 锚点 → 框右边缘在锚点、文字框内右对齐；start 锚点 → 框左边缘在锚点、左对齐；
    /// 中间 → 框中心在锚点、居中。垂直方向居中。
    private var tickLabels: some View {
        ForEach(Array(Gauge.ticks.enumerated()), id: \.offset) { i, v in
            let deg = Gauge.fractionToDegrees(Gauge.tickFractions[i])
            let c = cos(deg * .pi / 180)
            let r = (c < -0.85 || c > 0.85) ? Gauge.R + 12 : Gauge.R + 20
            let p = Gauge.point(deg, r)
            let align: Alignment = c < -0.85 ? .trailing : (c > 0.85 ? .leading : .center)
            let shift: CGFloat = c < -0.85 ? -22 : (c > 0.85 ? 22 : 0)   // 半框宽，让框边缘落在锚点
            Text("\(Int(v))")
                .font(.system(size: 12 * s, weight: .semibold).monospacedDigit())
                .foregroundColor(Theme.muted)
                .frame(width: 44 * s, height: 16 * s, alignment: align)
                .position(x: (p.x + shift) * s, y: p.y * s)
        }
    }
}

/// 仪表中心文字：标题行 + 药丸 / 大数字 / 上下文条；message 非空时只显示消息
struct CenterView: View {
    let model: PanelViewModel
    let frame: PanelAnimator.Frame
    let s: CGFloat

    var body: some View {
        ZStack {
            if let msg = model.message {
                VStack(spacing: 6 * s) {
                    Text(msg.title)
                        .font(.system(size: 28 * s, weight: .semibold))
                        .foregroundColor(Theme.text2)
                    Text(msg.subtitle)
                        .font(.system(size: 13 * s).monospacedDigit())
                        .foregroundColor(Theme.muted)
                }
                .frame(width: 220 * s, height: 80 * s, alignment: .top)
                .position(x: 154 * s, y: (108 + 40) * s)   // y=108 顶对齐
            } else {
                capRow
                bigRow
                if let ctx = model.context { ctxBar(ctx) }
            }
        }
    }

    /// 标题行（y=78，高 20）：capText（标题 · 单位）13 号 muted +「精确」药丸（间距 6）
    private var capRow: some View {
        HStack(spacing: 6 * s) {
            Text(model.capText)
                .font(.system(size: 13 * s))
                .foregroundColor(Theme.muted)
            if model.pill {
                let dimPill = model.muted
                Text("精确")
                    .font(.system(size: 12 * s, weight: .semibold).monospacedDigit())
                    .tracking(0.04 * 12 * s)
                    .foregroundColor(dimPill ? Theme.muted : Theme.pillText)
                    .frame(height: 18 * s)
                    .padding(.horizontal, 7 * s)
                    .background(
                        RoundedRectangle(cornerRadius: 9 * s)
                            .fill(dimPill ? Color.clear : Theme.pillBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9 * s)
                            .stroke(dimPill ? Theme.faint : Color.clear, lineWidth: 1 * s)
                    )
            }
        }
        .frame(width: 220 * s, height: 20 * s)
        .position(x: 154 * s, y: (78 + 10) * s)
    }

    /// 大数字（y=97，高 96）：整数 96 号 bold + 小数 40 号，基线对齐；muted（不在解码时的灰色画面）用 text2；
    /// 占位 “—”（无上次结果/无本轮成绩）用 56 号 faint，避免 96 号粗体像一根横条。
    /// 全部等宽数字（design.md 硬性要求：数字变化时不左右抖动，解码大数字每秒刷新 4 次）。
    /// 字距 −0.035em（整数）/ −0.01em（小数）；整段在 220 宽区内居中；y 相对行盒中心上移 3 单位（对照原型实测）。
    private var bigRow: some View {
        let isDash = frame.bigInt == "—"
        let color = isDash ? Theme.faint : (model.muted ? Theme.text2 : Theme.text)
        let intSize = isDash ? 56.0 : 96.0
        let decSize = model.whole ? 96.0 : 40.0
        let decTrack = -(model.whole ? 0.035 * 96 : 0.01 * 40)   // 字距（设计单位）
        return HStack(alignment: .lastTextBaseline, spacing: model.whole ? 0 : 1 * s) {
            Text(frame.bigInt)
                .font(.system(size: intSize * s, weight: .bold).monospacedDigit())
                .tracking(-CGFloat(0.035 * intSize) * s)
                .foregroundColor(color)
            if !frame.bigDec.isEmpty {
                Text(frame.bigDec)
                    .font(.system(size: decSize * s, weight: .bold).monospacedDigit())
                    .tracking(CGFloat(decTrack) * s)
                    .foregroundColor(color)
            }
        }
        .frame(width: 220 * s, height: 96 * s)
        .position(x: 154 * s, y: (97 + 48 - 3) * s)
    }

    /// 上下文条（与原型 .ctx 一致）：长条 x=94、y=205、120×6、圆角 3；
    /// 下方 5 处一行文字（y=216，行高 14，220 宽居中，12 号）；
    /// 填充颜色：normal → text2，warn → amber，full → danger
    private func ctxBar(_ ctx: ContextUsage) -> some View {
        let fillColor: Color
        switch ctx.level {
        case .normal: fillColor = Theme.text2
        case .warn: fillColor = Theme.amber
        case .full: fillColor = Theme.danger
        }
        var text = AttributedString()
        for seg in ctx.segments {
            var piece = AttributedString(seg.text)
            piece.font = .system(size: 12 * s, weight: seg.bold ? .semibold : .regular).monospacedDigit()
            piece.foregroundColor = seg.bold ? Theme.text2 : Theme.muted
            text += piece
        }
        return ZStack {
            // 长条：底色 + 从左开始的填充（宽 = fillWidth；0 时不画填充）
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3 * s).fill(Theme.track)
                if ctx.fillWidth > 0 {
                    RoundedRectangle(cornerRadius: 3 * s)
                        .fill(fillColor)
                        .frame(width: ctx.fillWidth * s)
                }
            }
            .frame(width: 120 * s, height: 6 * s)
            .position(x: (94 + 60) * s, y: (205 + 3) * s)
            Text(text)
                .frame(width: 220 * s, height: 14 * s)
                .position(x: 154 * s, y: (216 + 7) * s)
        }
    }
}

// MARK: - 右侧卡片列

/// 3 张卡片等高（(268 − 2·6)/3），间距 6
struct CardsView: View {
    let model: PanelViewModel
    let frame: PanelAnimator.Frame
    let s: CGFloat

    var body: some View {
        VStack(spacing: 6 * s) {
            ForEach(Array(model.cards.enumerated()), id: \.offset) { _, c in
                CardView(
                    card: c,
                    muted: model.muted || model.state == .offline || model.state == .unavailable || model.state == .starting,
                    s: s
                )
            }
        }
        .opacity(frame.cardsOpacity)
    }
}

struct CardView: View {
    let card: Card
    let muted: Bool
    let s: CGFloat

    /// 数值颜色：pending 用 faint；muted（含 offline / unavailable / starting）用 text2；其他 text
    private var valueColor: Color {
        if card.pending { return Theme.faint }
        return muted ? Theme.text2 : Theme.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(card.label)
                .font(.system(size: 13 * s))
                .foregroundColor(Theme.muted)
                .lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 4 * s) {
                Text(card.value)
                    .font(.system(size: 30 * s, weight: .bold).monospacedDigit())
                    .tracking(-CGFloat(0.6) * s)
                    .foregroundColor(valueColor)
                    .lineLimit(1)
                if !card.unit.isEmpty {
                    Text(card.unit)
                        .font(.system(size: 13 * s, weight: .semibold))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
            }
            if !card.foot.isEmpty {   // foot 为空时不占位
                Text(card.foot)
                    .font(.system(size: 13 * s).monospacedDigit())
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12 * s)
        .padding(.vertical, 8 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // 内容垂直居中
        .background(
            RoundedRectangle(cornerRadius: 14 * s).fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14 * s)
                .stroke(Theme.cardLine, lineWidth: 1 * s)
        )
    }
}
