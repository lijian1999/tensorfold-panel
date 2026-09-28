import Foundation

/// 画面状态（offline/unavailable/starting 由副屏程序判定，其余来自 /metrics 的 state）
public enum PanelState: String, Sendable {
    case offline
    case unavailable
    case starting
    case idle
    case prefill
    case decode
    case done
}

/// 圆弧模式（对应原型 .gauge 的 data-arc）
public enum ArcMode: String, Sendable {
    case value
    case rest
    case off
}

/// 右侧数据卡片（恰好 3 张）
public struct Card: Equatable, Sendable {
    public var label: String
    public var value: String
    public var unit: String
    public var foot: String
    public var pending: Bool

    public init(label: String, value: String, unit: String = "", foot: String = "", pending: Bool = false) {
        self.label = label
        self.value = value
        self.unit = unit
        self.foot = foot
        self.pending = pending
    }

    /// 缺数据时的占位卡
    public static func pending(_ label: String, foot: String = "") -> Card {
        Card(label: label, value: "—", foot: foot, pending: true)
    }
}

/// 状态条右侧文本段（bold 段用 --text-2 颜色加深）
public struct StripSegment: Equatable, Sendable {
    public var text: String
    public var bold: Bool

    public init(_ text: String, bold: Bool = false) {
        self.text = text
        self.bold = bold
    }
}

/// 上下文占用等级：< 80% 普通，80%–95% 警告，≥ 95% 快满
public enum ContextLevel: String, Sendable { case normal, warn, full }

/// 上下文占用（已用 / 上限），仪表下方上下文条的数据
public struct ContextUsage: Equatable, Sendable {
    public var used: Int
    public var limit: Int

    public init(used: Int, limit: Int) {
        self.used = used
        self.limit = limit
    }

    /// used ÷ limit，钳制在 0…1
    public var fraction: Double {
        min(1, max(0, Double(used) / Double(limit)))
    }

    /// 填充宽度（设计单位 pt）：used ≤ 0 时为 0；否则 max(6, 120 × fraction)（6 = 长条高度，最小画成一个圆点）
    public var fillWidth: Double {
        used <= 0 ? 0 : max(6, 120 * fraction)
    }

    /// ≥ 0.95 → .full；≥ 0.8 → .warn；否则 .normal
    public var level: ContextLevel {
        let r = Double(used) / Double(limit)
        if r >= 0.95 { return .full }
        if r >= 0.8 { return .warn }
        return .normal
    }

    /// 文字行：["上下文 ", 已用（bold）, " / " + 上限]
    public var segments: [StripSegment] {
        [
            StripSegment("上下文 "),
            StripSegment(Format.tokFmt(Double(used)), bold: true),
            StripSegment(" / " + Format.tokFmt(Double(limit))),
        ]
    }
}

// MARK: - 连接状态机

/// 记录 /metrics 请求的成败（值类型，纯逻辑，时间由参数传入）。
/// 连续 3 次失败才算离线；启动后从未成功过也算离线。
public struct ConnectionTracker: Sendable {
    /// 程序启动时间（从未成功过时的 offlineSince 兜底）
    public var bootTime: Double
    /// 当前是否离线
    public var isOffline: Bool
    /// 连续失败次数（成功后归零）
    public var failureCount: Int
    /// 离线期间的第一次失败时间（在线时为 nil）
    public var firstFailureAt: Double?
    /// 最近一次成功的指标
    public var lastSuccess: Metrics?
    /// 最近一次成功的时间
    public var fetchedAt: Double?
    /// 最近一次非空的 last（离线画面继续用）
    public var rememberedLast: Metrics.Last?
    /// 最近一次非空的模型名（离线画面继续用）
    public var rememberedModel: String?

    public init(bootTime: Double) {
        self.bootTime = bootTime
        self.isOffline = true
        self.failureCount = 0
    }

    /// 第一次失败的时间（启动后从未成功则返回 bootTime）
    public var offlineSince: Double {
        guard isOffline else { return 0 }
        if lastSuccess == nil { return bootTime }
        return firstFailureAt ?? bootTime
    }

    public mutating func recordSuccess(_ m: Metrics, at t: Double) {
        isOffline = false
        failureCount = 0
        firstFailureAt = nil
        lastSuccess = m
        fetchedAt = t
        if let last = m.last { rememberedLast = last }
        if let model = m.model, !model.isEmpty { rememberedModel = model }
    }

    public mutating func recordFailure(at t: Double) {
        if firstFailureAt == nil { firstFailureAt = t }
        guard !isOffline else { return }
        failureCount += 1
        if failureCount >= 3 { isOffline = true }
    }
}

/// 离线/不可用/启动中时显示在仪表中央的消息
public struct CenterMessage: Equatable, Sendable {
    public var title: String
    public var subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
}

// MARK: - 画面模型

/// 对应原型 `view()` 返回的 V。
public struct PanelViewModel: Equatable, Sendable {
    public var state: PanelState
    public var stateName: String
    public var stripLeft: String
    public var stripRight: [StripSegment]
    public var cap: String
    public var pill: Bool
    public var bigInt: String
    public var bigDec: String
    public var whole: Bool
    public var unit: String
    /// “不在解码时的灰色画面”：大数字、卡片数值用灰色，药丸用描边样式
    public var muted: Bool
    public var arc: ArcMode
    /// 圆弧目标值（tok/s，界面层用它做缓动）
    public var arcTarget: Double
    /// 不在解码时圆弧上「上次位置/本轮平均位置」小点
    public var ghostFraction: Double?
    /// 上下文占用（nil = 不显示上下文条）
    public var context: ContextUsage?
    /// 离线/不可用/启动中时显示在仪表中央
    public var message: CenterMessage?
    /// 恰好 3 张
    public var cards: [Card]

    /// 短预填充阈值（秒），之前不接管画面
    public static let shortPrefillS: Double = 3.0

    /// 标题行文字 = 标题 · 单位；两者任一为空时只用标题
    public var capText: String {
        (!cap.isEmpty && !unit.isEmpty) ? "\(cap) · \(unit)" : cap
    }

    /// 中间区域（标题、单位、提示文字）淡入键
    public var centerFadeKey: String {
        "\(cap)|\(unit)|\(whole)|\(muted)|\(message?.title ?? "")"
    }

    /// 右侧三项标签淡入键
    public var cardsFadeKey: String { cards.map(\.label).joined(separator: "|") }

    /// 由连接状态 + 当前时间 + 系统内存生成一帧画面。
    /// 状态判定顺序：离线 → hooks.chat == "missing"（unavailable）
    /// → engine_ready == false（starting）→ 按 metrics.state（未知值按 idle）。
    public static func make(
        tracker: ConnectionTracker,
        now: Double,
        memory: (usedGB: Double, totalGB: Double)?
    ) -> PanelViewModel {
        let m = tracker.lastSuccess
        let state: PanelState
        if tracker.isOffline {
            state = .offline
        } else if m?.hooks?.chat == "missing" {
            state = .unavailable
        } else if m?.engineReady == false {
            state = .starting
        } else {
            state = Self.state(from: m?.state)
        }

        // 当前模型名（短名）；idle/prefill/decode/done 的 stripLeft 都用它
        let modelName = Self.shortModelName(from: m, tracker: tracker)
        // 一轮模式判定（只对 idle / prefill / decode / done 生效）
        let round = m?.round
        let inFlight = (state == .prefill || state == .decode)
        let roundCount = (round?.requests ?? 0) + (inFlight ? 1 : 0)
        let roundMode = round != nil && roundCount >= 2
        let roundActive = inFlight || (round?.active ?? false)
        var vm: PanelViewModel
        switch state {
        case .offline:
            vm = Self.offlineView(m: m, tracker: tracker, now: now, memory: memory)
        case .unavailable:
            vm = Self.unavailableView(m: m, tracker: tracker, memory: memory, modelName: modelName)
        case .starting:
            vm = Self.startingView(m: m, tracker: tracker, memory: memory)
        case .idle:
            vm = Self.restView(
                state: .idle, stateName: "空闲",
                m: m, tracker: tracker, memory: memory, modelName: modelName,
                roundMode: roundMode, roundCount: roundCount, roundActive: roundActive
            )
        case .prefill:
            vm = Self.prefillView(
                m: m, tracker: tracker, now: now, memory: memory, modelName: modelName,
                roundMode: roundMode, roundCount: roundCount, roundActive: roundActive
            )
        case .decode:
            vm = Self.decodeView(
                m: m, tracker: tracker, memory: memory, modelName: modelName,
                roundMode: roundMode, roundCount: roundCount, roundActive: roundActive
            )
        case .done:
            vm = Self.doneView(
                m: m, tracker: tracker, memory: memory, modelName: modelName,
                roundMode: roundMode, roundCount: roundCount, roundActive: roundActive
            )
        }
        // 上下文条：limit = context_max（为空或 ≤ 0 时为 nil）；
        // 离线/指标不可用/启动中一律不显示
        if let limit = m?.contextMax, limit > 0 {
            switch state {
            case .prefill:
                // 预填充（长短都一样）：只算提示 token 数
                if let used = m?.current?.promptTokens {
                    vm.context = ContextUsage(used: used, limit: limit)
                }
            case .decode:
                // 解码：提示 + 已输出
                if let prompt = m?.current?.promptTokens {
                    vm.context = ContextUsage(used: prompt + (m?.current?.outputTokens ?? 0), limit: limit)
                }
            case .done:
                if let used = m?.last?.contextUsed {
                    vm.context = ContextUsage(used: used, limit: limit)
                }
            case .idle:
                if let used = (m?.last ?? tracker.rememberedLast)?.contextUsed {
                    vm.context = ContextUsage(used: used, limit: limit)
                }
            default:
                break
            }
        }
        return vm
    }

    // MARK: 各状态画面（逐字照抄原型 view() 的 case，原型模拟数据换成真实数据）

    private static func state(from raw: String?) -> PanelState {
        switch raw {
        case "idle": return .idle
        case "prefill": return .prefill
        case "decode": return .decode
        case "done": return .done
        default: return .idle
        }
    }

    private static func shortModelName(from m: Metrics?, tracker: ConnectionTracker) -> String {
        let raw = m?.model ?? tracker.rememberedModel
        return raw.map { Format.shortModelName($0) } ?? "TensorFold"
    }

    /// 内存卡；读不到内存时 — pending
    private static func memoryCard(_ memory: (usedGB: Double, totalGB: Double)?) -> Card {
        guard let memory else { return .pending("内存") }
        return Card(
            label: "内存",
            value: Format.fixed(memory.usedGB, 1),
            unit: "GB",
            foot: "共 \(Int(memory.totalGB.rounded())) GB"
        )
    }

    /// 上次平均卡；没有记住的 last 时 — pending
    private static func lastAvgCard(_ tracker: ConnectionTracker) -> Card {
        guard let tps = tracker.rememberedLast?.decodeTps else { return .pending("上次平均", foot: "tok/s") }
        return Card(label: "上次平均", value: Format.fixed(tps, 1), unit: "", foot: "tok/s")
    }

    /// 秒/分钟/小时（向下取整，与「已离线」同一规则）
    private static func durationParts(_ seconds: Double) -> (value: String, unit: String) {
        let s = max(0, Int(seconds))
        if s < 60 { return ("\(s)", "秒") }
        if s < 3600 { return ("\(s / 60)", "分钟") }
        return ("\(s / 3600)", "小时")
    }

    private static func offlineView(
        m: Metrics?, tracker: ConnectionTracker, now: Double,
        memory: (usedGB: Double, totalGB: Double)?
    ) -> PanelViewModel {
        let secs = max(0, now - tracker.offlineSince)
        let (v, u) = durationParts(secs)
        // 有记住的模型 →「上次模型 <短名>」；没有 → TensorFold
        let model = [m?.model, tracker.rememberedModel].compactMap { $0 }.first { !$0.isEmpty }
        let stripLeft = model.map { "上次模型 \(Format.shortModelName($0))" } ?? "TensorFold"
        return PanelViewModel(
            state: .offline,
            stateName: "引擎离线",
            stripLeft: stripLeft,
            stripRight: [],
            cap: "", pill: false, bigInt: "", bigDec: "",
            whole: false, unit: "tok/s", muted: false,
            arc: .off, arcTarget: 0, ghostFraction: nil,
            context: nil,
            message: CenterMessage(title: "引擎离线", subtitle: "等待 TensorFold 响应…"),
            cards: [lastAvgCard(tracker), Card(label: "已离线", value: v, unit: u), memoryCard(memory)]
        )
    }

    private static func unavailableView(
        m: Metrics?, tracker: ConnectionTracker,
        memory: (usedGB: Double, totalGB: Double)?, modelName: String
    ) -> PanelViewModel {
        let (v, u) = durationParts(Double(m?.totals?.uptimeS ?? 0))
        return PanelViewModel(
            state: .unavailable,
            stateName: "指标不可用",
            stripLeft: modelName,
            stripRight: [],
            cap: "", pill: false, bigInt: "", bigDec: "",
            whole: false, unit: "tok/s", muted: false,
            arc: .off, arcTarget: 0, ghostFraction: nil,
            context: nil,
            message: CenterMessage(title: "指标不可用", subtitle: "TensorFold 已更新，需要适配"),
            cards: [lastAvgCard(tracker), Card(label: "运行", value: v, unit: u), memoryCard(memory)]
        )
    }

    private static func startingView(
        m: Metrics?, tracker: ConnectionTracker,
        memory: (usedGB: Double, totalGB: Double)?
    ) -> PanelViewModel {
        let (v, u) = durationParts(Double(m?.totals?.uptimeS ?? 0))
        return PanelViewModel(
            state: .starting,
            stateName: "启动中",
            stripLeft: "TensorFold",
            stripRight: [],
            cap: "", pill: false, bigInt: "", bigDec: "",
            whole: false, unit: "tok/s", muted: false,
            arc: .off, arcTarget: 0, ghostFraction: nil,
            context: nil,
            message: CenterMessage(title: "模型加载中", subtitle: "TensorFold 正在启动…"),
            cards: [lastAvgCard(tracker), Card(label: "运行", value: v, unit: u), memoryCard(memory)]
        )
    }

    /// 一轮模式的三张卡片（标签随 roundActive 变化）
    private static func roundCards(
        round: Metrics.Round?, roundCount: Int, roundActive: Bool,
        state: PanelState, m: Metrics?
    ) -> [Card] {
        let req = roundActive ? "本轮请求" : "上轮请求"
        let out = roundActive ? "累计输出" : "上轮输出"
        let avg = roundActive ? "本轮平均" : "上轮平均"
        // 用时：秒/分钟/小时向下取整；为空时不显示
        let foot: String
        if let e = round?.elapsedS {
            let (v, u) = durationParts(e)
            foot = "用时 \(v) \(u)"
        } else {
            foot = ""
        }
        // 累计输出 = 已完成请求之和 + 进行中请求的换算输出
        let inFlightOutput = (state == .decode) ? (m?.current?.outputTokens ?? 0) : 0
        let output = Format.tokFmt(Double((round?.outputTokens ?? 0) + inFlightOutput))
        let avgCard: Card
        if let tps = round?.decodeTpsAvg {
            avgCard = Card(label: avg, value: Format.fixed(tps, 1), unit: "", foot: "tok/s")
        } else {
            avgCard = .pending(avg)
        }
        return [
            Card(label: req, value: "\(roundCount)", unit: "次", foot: foot),
            Card(label: out, value: output, unit: "tok"),
            avgCard,
        ]
    }

    /// “灰色画面”：不在解码时的公共画面（空闲 / 一轮完成 / 短预填充，圆弧不动、小点留在原位）。
    private static func restView(
        state: PanelState, stateName: String,
        m: Metrics?, tracker: ConnectionTracker,
        memory: (usedGB: Double, totalGB: Double)?, modelName: String,
        roundMode: Bool, roundCount: Int, roundActive: Bool
    ) -> PanelViewModel {
        let round = m?.round
        var vm = PanelViewModel(
            state: state,
            stateName: stateName,
            stripLeft: modelName,
            stripRight: [],
            cap: "", pill: false,
            bigInt: "", bigDec: "", whole: false, unit: "tok/s",
            muted: true,
            arc: .rest, arcTarget: 0,
            ghostFraction: nil,
            context: nil,
            message: nil,
            cards: []
        )
        if !roundMode {
            // 单请求：与空闲画面相同（数据用 metrics.last，为空时用 rememberedLast）
            let last = m?.last ?? tracker.rememberedLast
            vm.cap = "上次平均"
            vm.pill = true
            if let last {
                let final = last.decodeTps ?? 0
                let (i, d) = Format.split1(final)
                vm.bigInt = i
                vm.bigDec = d
                vm.arcTarget = final
                vm.ghostFraction = last.decodeTps.map(Gauge.valueToFraction)
                let output = last.completionTokens.map { Format.tokFmt(Double($0)) }
                let ttft = last.ttftS.map { Format.fixed($0, 2) }
                vm.cards = [
                    output.map { Card(label: "输出", value: $0, unit: "tok") } ?? .pending("输出"),
                    ttft.map { Card(label: "首字", value: $0, unit: "s") } ?? .pending("首字"),
                    memoryCard(memory),
                ]
            } else {
                // 没有上次结果：大数字为 —，不带「精确」标记
                vm.bigInt = "—"
                vm.bigDec = ""
                vm.pill = false
                vm.cards = [.pending("输出"), .pending("首字"), memoryCard(memory)]
            }
            return vm
        }
        // 一轮模式：本轮/上轮平均
        let avg = round?.decodeTpsAvg
        vm.cap = roundActive ? "本轮平均" : "上轮平均"
        vm.pill = avg != nil
        if let avg {
            let (i, d) = Format.split1(avg)
            vm.bigInt = i
            vm.bigDec = d
            vm.arcTarget = avg
            vm.ghostFraction = Gauge.valueToFraction(avg)
        } else {
            vm.bigInt = "—"
            vm.bigDec = ""
        }
        vm.cards = Self.roundCards(
            round: round, roundCount: roundCount, roundActive: roundActive,
            state: state, m: m
        )
        return vm
    }

    private static func prefillView(
        m: Metrics?, tracker: ConnectionTracker,
        now: Double,
        memory: (usedGB: Double, totalGB: Double)?, modelName: String,
        roundMode: Bool, roundCount: Int, roundActive: Bool
    ) -> PanelViewModel {
        // 已用时 = current.elapsed_s + (now − fetchedAt)，本地插值让画面连续走秒
        var elapsed = m?.current?.elapsedS ?? 0
        if let fetchedAt = tracker.fetchedAt { elapsed += max(0, now - fetchedAt) }
        // 先取“灰色画面”，再按已用时决定接管程度
        var vm = Self.restView(
            state: .prefill, stateName: "预填充中",
            m: m, tracker: tracker, memory: memory, modelName: modelName,
            roundMode: roundMode, roundCount: roundCount, roundActive: roundActive
        )
        if elapsed < Self.shortPrefillS {
            // 短预填充：画面和预填充之前一样，只把状态条右侧换成已用时
            vm.stripRight = [
                StripSegment("已用时 "),
                StripSegment(Format.fixed(elapsed, 1), bold: true),
                StripSegment(" s"),
            ]
            return vm
        }
        // 长预填充：接管大数字（圆弧不动，小点留在原位）
        vm.muted = false
        vm.pill = false
        vm.cap = "已用时"
        vm.whole = true
        vm.unit = "秒"
        let (i, d) = elapsed < 10 ? Format.split1(elapsed) : ("\(Int(elapsed))", "")
        vm.bigInt = i
        vm.bigDec = d
        vm.stripRight = [StripSegment("提示较长，可能需要几秒")]
        if !roundMode {
            vm.cards = [
                .pending("输出"),
                .pending("首字", foot: "等待首个 token"),
                memoryCard(memory),
            ]
        }
        return vm
    }

    private static func decodeView(
        m: Metrics?, tracker: ConnectionTracker,
        memory: (usedGB: Double, totalGB: Double)?, modelName: String,
        roundMode: Bool, roundCount: Int, roundActive: Bool
    ) -> PanelViewModel {
        let cur = m?.current
        let target = cur?.decodeTps ?? 0
        // 状态条首字时间：用 current.ttft_s；缺失时显示 —（不用任何示例值）
        let ttftText = cur?.ttftS.map { Format.fixed($0, 2) } ?? "—"
        var stripRight = [
            StripSegment("首字 ", bold: false),
            StripSegment(ttftText, bold: true),
            StripSegment(" s · 内存 ", bold: false),
        ]
        if let memory {
            stripRight.append(StripSegment(Format.fixed(memory.usedGB, 1), bold: true))
            stripRight.append(StripSegment(" / \(Int(memory.totalGB.rounded())) GB", bold: false))
        }
        let output = cur?.outputTokens.map { Format.tokFmt(Double($0)) }
        let avg = cur?.decodeTpsAvg
        let peakCard: Card = {
            guard let peak = cur?.decodeTpsPeak, peak > 0 else { return .pending("峰值") }
            return Card(label: "峰值", value: "\(Int(peak.rounded()))", unit: "tok/s")
        }()
        // 一轮模式只把右侧三项换成本轮累计，其余不变
        let cards: [Card] = roundMode
            ? Self.roundCards(
                round: m?.round, roundCount: roundCount, roundActive: roundActive,
                state: .decode, m: m
              )
            : [
                output.map { Card(label: "输出", value: $0, unit: "tok") } ?? .pending("输出"),
                avg.map { Card(label: "平均", value: Format.fixed($0, 1), foot: "tok/s") }
                    ?? .pending("平均"),
                peakCard,
            ]
        return PanelViewModel(
            state: .decode,
            stateName: "解码中",
            stripLeft: modelName,
            stripRight: stripRight,
            cap: "解码速度", pill: false,
            bigInt: "\(Int(target.rounded()))", bigDec: "",
            whole: false, unit: "tok/s", muted: false,
            arc: .value, arcTarget: target,
            ghostFraction: (m?.last ?? tracker.rememberedLast)?.decodeTps.map(Gauge.valueToFraction),
            context: nil,
            message: nil,
            cards: cards
        )
    }

    private static func doneView(
        m: Metrics?, tracker: ConnectionTracker,
        memory: (usedGB: Double, totalGB: Double)?, modelName: String,
        roundMode: Bool, roundCount: Int, roundActive: Bool
    ) -> PanelViewModel {
        // 一轮模式：不单独显示“完成”画面，用灰色画面，只换状态名和状态条
        // 状态条：首字时间；缺失时显示 —
        let ttftText = (m?.last?.ttftS).map { Format.fixed($0, 2) } ?? "—"
        let stripRight = [
            StripSegment("首字 ", bold: false),
            StripSegment(ttftText, bold: true),
            StripSegment(" s", bold: false),
        ]
        if roundMode {
            var vm = Self.restView(
                state: .done, stateName: "完成",
                m: m, tracker: tracker, memory: memory, modelName: modelName,
                roundMode: roundMode, roundCount: roundCount, roundActive: roundActive
            )
            vm.stripRight = stripRight
            return vm
        }
        let last = m?.last
        let target = last?.decodeTps ?? 0
        let (i, d) = Format.split1(target)
        let output = last?.completionTokens.map { Format.tokFmt(Double($0)) }
        let cached = last?.cachedTokens
        let hit = last.flatMap { l -> Int? in
            guard let prompt = l.promptTokens, let cached = l.cachedTokens else { return nil }
            return prompt == 0 ? 0 : Int((Double(cached) / Double(prompt) * 100).rounded())
        }
        let accept = last?.acceptanceRate.map { Int(($0 * 100).rounded()) }
        let hitFoot = cached.map { "\(Format.tokFmt(Double($0))) tok" } ?? ""
        return PanelViewModel(
            state: .done,
            stateName: "完成",
            stripLeft: modelName,
            stripRight: stripRight,
            cap: "平均速度", pill: true,
            bigInt: i, bigDec: d, whole: false, unit: "tok/s", muted: false,
            arc: .value, arcTarget: target,
            ghostFraction: last?.decodeTps.map(Gauge.valueToFraction),
            context: nil,
            message: nil,
            cards: [
                output.map { o -> Card in
                    let f = last?.promptTokens.map { "提示 \(Format.tokFmt(Double($0))) tok" } ?? ""
                    return Card(label: "输出", value: o, unit: "tok", foot: f)
                } ?? .pending("输出"),
                hit.map { Card(label: "缓存命中", value: "\($0)", unit: "%", foot: hitFoot) } ?? .pending("缓存命中"),
                accept.map { Card(label: "接受率", value: "\($0)", unit: "%") } ?? .pending("接受率"),
            ]
        )
    }
}
