// 视图数据结构：视图模型 → 绘制。只描述画面上写什么，不做计算。和 panel/view.py 一一对应，字段名换成驼峰。
import Foundation

public struct Seg: Equatable, Sendable {                // 一段文字
    public var text: String
    public var style: String = "normal"                // "normal" 普通 | "strong" 加粗提亮 | "warn" 琥珀色加粗

    public init(_ text: String, _ style: String = "normal") {
        self.text = text
        self.style = style
    }
}

public struct Lanes: Equatable, Sendable {             // 流指示点
    public var max: Int = 5
    public var decoding: Int = 0
    public var prefilling: Int = 0
    public var waiting: Int = 0
    public var offline: Bool = false                   // true 时只画一个红点

    public init(max: Int = 5, decoding: Int = 0, prefilling: Int = 0, waiting: Int = 0, offline: Bool = false) {
        self.max = max
        self.decoding = decoding
        self.prefilling = prefilling
        self.waiting = waiting
        self.offline = offline
    }
}

public struct Card: Equatable, Sendable {              // 右侧一栏
    public var label: String = ""
    public var value: String = ""
    public var unit: String = ""
    public var foot: String = ""
    public var pending: Bool = false                   // true 时数值用暗色（“—”）

    public init(_ label: String = "", _ value: String = "", _ unit: String = "", _ foot: String = "", _ pending: Bool = false) {
        self.label = label
        self.value = value
        self.unit = unit
        self.foot = foot
        self.pending = pending
    }
}

public struct Bar: Equatable, Sendable {               // 主数字下方那一块
    public var kind: String = "ctx"                    // "ctx" 上下文条 | "prog" 预填充进度条 | "note" 只有一行字、没有条
    public var frac: Double = 0.0                      // 条的长度 0–1
    public var level: String = "normal"                // 只对 ctx 有意义："normal" 灰 | "warn" 琥珀（≥ 80%）| "full" 红（≥ 95%）
    public var text: [Seg] = []

    public init(kind: String = "ctx", frac: Double = 0.0, level: String = "normal", text: [Seg] = []) {
        self.kind = kind
        self.frac = frac
        self.level = level
        self.text = text
    }
}

public struct View: Equatable, Sendable {
    public var state: String = "idle"                  // offline | idle | prefill | decode | done
    public var stateName: String = "空闲"               // 状态条上的状态名
    public var stripLeft: String = ""                  // 状态名后面的模型名，可为空
    public var stripRight: [Seg] = []
    public var lanes: Lanes = Lanes()
    public var cap: String = ""                        // 仪表盘标题，如“解码速度”
    public var unit: String = ""                       // 标题后的单位，如“tok/s”
    public var pill: Bool = false                      // “精确”标记
    public var pillKind: String = "exact"              // pill 为 true 时画哪一种："exact" 实心的“精确” | "avg" 琥珀色描边的“近期平均”
    public var bigInt: String = ""                     // 主数字的整数部分（含货币符号）
    public var bigDec: String = ""                     // 主数字的小数部分（含小数点），可为空
    public var bigWhole: Bool = false                  // true：小数部分和整数部分同字号
    public var bigSize: String = "normal"              // "normal" 96 | "four" 76 | "cost" 68
    public var bigValue: Double? = nil                 // 主数字是实时解码速度时填数值，其余为 nil
    public var arc: String = "blank"                   // "value" | "prefill" | "rest" | "blank" | "off"
    public var scale: String = "decode"                // "decode" | "prefill"
    public var arcTarget: Double? = nil                // 圆弧目标位置 0–1；blank、off 时为 nil
    public var ghost: Double? = nil                    // arc 为 rest 时灰色小点的位置 0–1；没有则 nil
    public var muted: Bool = false                     // 灰色画面
    public var bar: Bar? = nil
    public var cards: [Card] = []                      // 恰好 3 个
    public var dim: Double = 1.0                       // 整屏亮度，长时间空闲时 0.4
    public var slowFade: Bool = false                  // 这次切换用 0.8 秒慢淡入（完成 → 空闲）

    public init() {}
}

// MARK: - 和 JSON 互转（对应 to_dict / from_dict，键名用 Python 版的下划线写法）

extension Seg {
    public func toJSON() -> JSON { ["text": .string(text), "style": .string(style)] }
    public init(json d: JSON) { self.init(d["text"]?.string ?? "", d["style"]?.string ?? "normal") }
}

extension Lanes {
    public func toJSON() -> JSON {
        ["max": .int(max), "decoding": .int(decoding), "prefilling": .int(prefilling), "waiting": .int(waiting), "offline": .bool(offline)]
    }
    public init(json d: JSON?) {
        self.init()
        guard let d, d.object != nil else { return }
        max = d["max"]?.int ?? 5
        decoding = d["decoding"]?.int ?? 0
        prefilling = d["prefilling"]?.int ?? 0
        waiting = d["waiting"]?.int ?? 0
        offline = d["offline"]?.bool ?? false
    }
}

extension Card {
    public func toJSON() -> JSON {
        ["label": .string(label), "value": .string(value), "unit": .string(unit), "foot": .string(foot), "pending": .bool(pending)]
    }
    public init(json d: JSON) {
        self.init(d["label"]?.string ?? "", d["value"]?.string ?? "", d["unit"]?.string ?? "",
                  d["foot"]?.string ?? "", d["pending"]?.bool ?? false)
    }
}

extension Bar {
    public func toJSON() -> JSON {
        ["kind": .string(kind), "frac": .double(frac), "level": .string(level), "text": .array(text.map { $0.toJSON() })]
    }
    /// nil、null、不是对象 → nil
    public static func from(json d: JSON?) -> Bar? {
        guard let d, d.object != nil else { return nil }
        return Bar(kind: d["kind"]?.string ?? "ctx", frac: d["frac"]?.number ?? 0.0, level: d["level"]?.string ?? "normal",
                   text: (d["text"]?.array ?? []).filter { $0.object != nil }.map { Seg(json: $0) })
    }
}

extension View {
    public func toJSON() -> JSON {
        [
            "state": .string(state), "state_name": .string(stateName), "strip_left": .string(stripLeft),
            "strip_right": .array(stripRight.map { $0.toJSON() }), "lanes": lanes.toJSON(),
            "cap": .string(cap), "unit": .string(unit), "pill": .bool(pill), "pill_kind": .string(pillKind),
            "big_int": .string(bigInt), "big_dec": .string(bigDec), "big_whole": .bool(bigWhole), "big_size": .string(bigSize),
            "big_value": JSON(bigValue), "arc": .string(arc), "scale": .string(scale),
            "arc_target": JSON(arcTarget), "ghost": JSON(ghost), "muted": .bool(muted),
            "bar": bar?.toJSON() ?? .null, "cards": .array(cards.map { $0.toJSON() }),
            "dim": .double(dim), "slow_fade": .bool(slowFade),
        ]
    }

    /// toJSON 的逆运算：缺的键、类型不对的值用默认值，多出来的键忽略。
    public init(json d: JSON) {
        self.init()
        state = d["state"]?.string ?? "idle"
        stateName = d["state_name"]?.string ?? "空闲"
        stripLeft = d["strip_left"]?.string ?? ""
        stripRight = (d["strip_right"]?.array ?? []).filter { $0.object != nil }.map { Seg(json: $0) }
        lanes = Lanes(json: d["lanes"])
        cap = d["cap"]?.string ?? ""
        unit = d["unit"]?.string ?? ""
        pill = d["pill"]?.bool ?? false
        pillKind = d["pill_kind"]?.string ?? "exact"
        bigInt = d["big_int"]?.string ?? ""
        bigDec = d["big_dec"]?.string ?? ""
        bigWhole = d["big_whole"]?.bool ?? false
        bigSize = d["big_size"]?.string ?? "normal"
        bigValue = d["big_value"]?.number
        arc = d["arc"]?.string ?? "blank"
        scale = d["scale"]?.string ?? "decode"
        arcTarget = d["arc_target"]?.number
        ghost = d["ghost"]?.number
        muted = d["muted"]?.bool ?? false
        bar = Bar.from(json: d["bar"])
        cards = (d["cards"]?.array ?? []).filter { $0.object != nil }.map { Card(json: $0) }
        dim = d["dim"]?.number ?? 1.0
        slowFade = d["slow_fade"]?.bool ?? false
    }
}
