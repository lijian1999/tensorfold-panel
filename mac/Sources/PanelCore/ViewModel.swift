// 视图模型：指标快照 → 视图（View）。翻译自 panel/viewmodel.py。
// 不读时钟、不做 I/O；快照里缺字段或字段为 null 时照常出画面，缺的那部分写“—”或留空。
import Foundation

// ---------- 模块级函数（对应 viewmodel.py 的 _join、_num） ----------

/// 把若干段文字接起来，相邻的同样式文字合成一段。
private func segJoin(_ parts: [Seg]) -> [Seg] {
    var out: [Seg] = []
    for part in parts {
        if !out.isEmpty && out[out.count - 1].style == part.style {
            out[out.count - 1].text += part.text
        } else {
            out.append(Seg(part.text, part.style))
        }
    }
    return out
}

/// 取不到的数字退回默认值（画面上写成 0 或“—”）。
/// 保留整数/小数两种类型，Python 的 str() 要区分 1 和 1.0。
private func _num(_ value: JSON?, _ fallback: Int = 0) -> JSON {
    if let v = value {
        if let i = v.int { return .int(i) }
        if let d = v.double { return .double(d) }
    }
    return .int(fallback)
}

/// _num 的数值形式，用于算术和格式化。
private func _numD(_ value: JSON?, _ fallback: Int = 0) -> Double {
    _num(value, fallback).number ?? 0
}

/// Python 的两个 _num 结果相加：都是整数时结果仍是整数。
private func _numAdd(_ a: JSON, _ b: JSON) -> JSON {
    if case .int(let x) = a, case .int(let y) = b { return .int(x + y) }
    return .double((a.number ?? 0) + (b.number ?? 0))
}

/// Python 的 str()：数字按类型写（1 → "1"，1.0 → "1.0"），字符串原样。
private func _pyStr(_ value: JSON) -> String {
    switch value {
    case .int(let i): return String(i)
    case .double(let d): return d.description
    case .string(let s): return s
    case .bool(let b): return b ? "True" : "False"
    case .null: return "None"
    default: return value.serialized()
    }
}

/// 取整（对应 Python 的 int(x)，向零截断）。
private func _trunc(_ x: Double) -> Int { Int(x) }

/// Python 的 max(1, math.ceil(x))（x 不是有限数时退回 1，Swift 里转 Int 会崩）。
private func _ceilAtLeast1(_ x: Double) -> Int {
    guard x.isFinite else { return 1 }
    return max(1, Int(ceil(x)))
}

/// 时区的中文显示名：Asia/Shanghai → 北京时间，America/Los_Angeles → 太平洋时间，其他用系统给的中文名。
public func zoneDisplayName(_ identifier: String) -> String {
    if identifier == "Asia/Shanghai" { return "北京时间" }
    if identifier == "America/Los_Angeles" { return "太平洋时间" }
    if let name = TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: Locale(identifier: "zh_CN")),
       !name.isEmpty {
        return name
    }
    return identifier
}

public final class ViewModel {
    /// 把一份指标快照变成一个 View。
    ///
    /// 两次 update 之间记住四件事：休息画面是哪一种、预填充有没有接管画面、
    /// 上一次的状态（慢淡入）、今日统计开始显示的时刻（调暗）。

    private let config: Config
    private var restKind = "today"                 // 上一次休息画面：today 或 round
    private var tookOver = false                   // 预填充是否接管了画面
    private var prevState: String? = nil           // 上一次的状态
    private var todaySince: Double? = nil          // 今日统计开始显示的时刻

    public init(config: Config) {
        self.config = config
    }

    /// 按快照出画面。now 是单调时钟秒数，只用来算调暗。
    public func update(_ snapshot: JSON, now: Double) -> View {
        let snap: JSON = snapshot.object != nil ? snapshot : [:]
        let stateValue = snap["state"]
        let state = (stateValue?.truthy ?? false) ? _pyStr(stateValue!) : "idle"
        let prev = prevState
        prevState = state

        var view = View()
        view.state = state
        // 记忆 3：完成 → 空闲用 0.8 秒慢淡入
        view.slowFade = (prev == "done") && state == "idle"
        view.lanes = lanes(snap)

        let rm = roundMode(snap)
        let memText = memoryText(snap)
        let memCard = memoryCard(snap)

        if state == "offline" {
            offline(&view, snap, memCard)
        } else if state == "idle" {
            // 一轮中间的空隙显示本轮统计，一轮结束后才是今日统计
            if rm {
                roundRest(&view, snap)
                view.stripRight = segJoin(memText)
            } else {
                today(&view, snap)
            }
        } else if state == "prefill" {
            prefill(&view, snap, rm, memCard)
        } else if state == "decode" {
            decode(&view, snap, rm, memText)
        } else if state == "loading" {
            loading(&view, snap, memCard)
        } else {
            // 完成，以及认不出的状态：都按完成画
            done(&view, snap, rm, memText)
        }

        // 记忆 1：休息画面是哪一种（预填充不改）
        if state == "idle" || state == "offline" {
            restKind = (state == "idle" && rm) ? "round" : "today"
        } else if state == "done" || state == "decode" {
            restKind = "round"
        }

        // 记忆 2：离开预填充就清掉接管标记
        if state != "prefill" {
            tookOver = false
        }

        // 记忆 4：长时间停在今日统计上就调暗
        if state == "idle" && !rm {
            if todaySince == nil {
                todaySince = now
            }
            if now - todaySince! >= config.dimAfterS {
                view.dim = 0.4
            }
        } else {
            todaySince = nil
        }

        return view
    }

    // ---------- 公共片段 ----------

    /// 流指示点：照抄快照里的流数；离线时只画一个红点。
    private func lanes(_ snap: JSON) -> Lanes {
        var lanesJSON: JSON = [:]
        if let l = snap["lanes"], l.object != nil { lanesJSON = l }
        if snap["state"]?.string == "offline" {
            return Lanes(max: _trunc(_numD(lanesJSON["max"], 5)), offline: true)
        }
        return Lanes(max: _trunc(_numD(lanesJSON["max"], 5)),
                     decoding: _trunc(_numD(lanesJSON["decoding"])),
                     prefilling: _trunc(_numD(lanesJSON["prefilling"])),
                     waiting: _trunc(_numD(lanesJSON["waiting"])))
    }

    /// 原始模型名 → 显示名：取最后一个 '/' 后面的那段，再去掉最后一个 '--' 及它前面的部分
    /// （mlx-community--Qwen3-ASR-0.6B-8bit → Qwen3-ASR-0.6B-8bit）；去掉后为空就不去。
    private func displayName(_ raw: String) -> String {
        let last = raw.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? raw
        let base = last.isEmpty ? raw : last
        if let r = base.range(of: "--", options: .backwards) {
            let stripped = String(base[r.upperBound...])
            if !stripped.isEmpty { return stripped }
        }
        return base
    }

    /// 显示用的模型名。
    private func modelName(_ snap: JSON) -> String {
        let m = snap["model"]?.string ?? ""
        return displayName(m.isEmpty ? config.modelName : m)
    }

    /// 引擎名：认不出的（包括没有这个键）都是 None。
    private func engineName(_ snap: JSON) -> String? {
        let engine = snap["engine"]
        if engine?.string == "tensorfold" { return "TensorFold" }
        if engine?.string == "vllm" { return "vLLM" }
        if engine?.string == "omlx" { return "oMLX" }
        return nil
    }

    /// 状态条右侧的“内存 x.x / 121 GB”。
    private func memoryText(_ snap: JSON) -> [Seg] {
        let (used, total) = memory(snap)
        return [Seg("内存 "), Seg(used, "strong"), Seg(" / \(total) GB")]
    }

    /// 内存已用和总量各写成字符串，读不到写“—”。
    private func memory(_ snap: JSON) -> (String, String) {
        var memJSON: JSON = [:]
        if let mem = snap["memory"], mem.object != nil { memJSON = mem }
        let used = memJSON["used_gb"]
        let total = memJSON["total_gb"]
        let usedText = used.isNone ? "—" : String(format: "%.1f", used!.number ?? 0)
        let totalText = (total?.truthy ?? false) ? String(_trunc(total!.number ?? 0)) : "—"
        return (usedText, totalText)
    }

    private func memoryCard(_ snap: JSON) -> Card {
        let (used, total) = memory(snap)
        return Card("内存", used, "GB", "共 \(total) GB")
    }

    /// 上下文条：长度按占用比例，颜色按档位分三档。
    private func contextBar(_ snap: JSON, _ usedJSON: JSON?) -> Bar {
        let used = _numD(usedJSON, 0)
        let contextMax = _numD(snap["context_max"], 0)
        let frac = contextMax != 0 ? min(1.0, used / contextMax) : 0.0
        let level: String
        if frac >= 0.95 {
            level = "full"
        } else if frac >= 0.8 {
            level = "warn"
        } else {
            level = "normal"
        }
        let shown = contextMax != 0 ? min(used, contextMax) : used
        let usedText = shown != 0 ? tokFmt(shown) : "—"
        let maxText = contextMax != 0 ? tokFmt(contextMax) : "—"
        let text = segJoin([Seg("上下文 "), Seg(usedText, "strong"), Seg(" / \(maxText)")])
        return Bar(kind: "ctx", frac: frac, level: level, text: text)
    }

    /// 一轮模式：这一轮请求数（含进行中的）≥ 2 且这一轮还没结束。
    private func roundMode(_ snap: JSON) -> Bool {
        guard let rnd = snap["round"], rnd.object != nil, rnd["active"]?.truthy ?? false else { return false }
        return _numD(rnd["requests"]) + _numD(rnd["running"]) >= 2
    }

    /// 一轮模式右侧三栏，标签在这一轮里不变。
    private func roundCards(_ snap: JSON) -> [Card] {
        var rndJSON: JSON = [:]
        if let rnd = snap["round"], rnd.object != nil { rndJSON = rnd }
        let requests = _num(rndJSON["requests"])
        let running = _num(rndJSON["running"])
        let avg = rndJSON["decode_tps_avg"]
        let third: Card
        if avg.isNone {
            third = Card("本轮平均", "—", "", "", true)
        } else {
            third = Card("本轮平均", String(format: "%.1f", avg!.number ?? 0), "", "tok/s")
        }
        return [
            Card("本轮请求", _pyStr(_numAdd(requests, running)), "次",
                 "用时 " + durFmt(_numD(rndJSON["elapsed_s"]))),
            Card("累计输出", tokFmt(_numD(rndJSON["output_tokens"])), "tok", ""),
            third,
        ]
    }

    // ---------- 两种休息画面 ----------

    /// 本轮统计（灰色）。
    private func roundRest(_ view: inout View, _ snap: JSON) {
        var rndJSON: JSON = [:]
        if let rnd = snap["round"], rnd.object != nil { rndJSON = rnd }
        let avg = rndJSON["decode_tps_avg"]
        view.muted = true
        view.arc = "rest"
        view.cap = "本轮平均"
        view.unit = "tok/s"
        view.pill = !avg.isNone && (rndJSON["exact"]?.truthy ?? false)
        if !avg.isNone {
            let parts = split1(avg!.number ?? 0)
            view.bigInt = parts.0
            view.bigDec = parts.1
        } else {
            view.bigInt = "—"
            view.bigDec = ""
        }
        view.ghost = avg.isNone ? nil : v2f(avg!.number, "decode")
        view.arcTarget = view.ghost
        view.stripLeft = ""
        view.bar = contextBar(snap, snap["context_used"])
        view.cards = roundCards(snap)
    }

    /// 今日统计。
    private func today(_ view: inout View, _ snap: JSON) {
        var todayJSON: JSON = [:]
        if let t = snap["today"], t.object != nil { todayJSON = t }
        var lastJSON: JSON = [:]
        if let l = snap["last"], l.object != nil { lastJSON = l }

        let model = modelName(snap)
        let engine = engineName(snap)
        // oMLX 不用外挂：只有既不是 vLLM 也不是 oMLX 时才提示外挂未生效
        let engineStr = snap["engine"]?.string
        if snap["hook"]?.string == "missing" && engineStr != "vllm" && engineStr != "omlx" {
            // 写了“外挂未生效”就不再重复写引擎名
            view.stripLeft = model
            view.stripRight = segJoin([Seg("外挂未生效", "warn"), Seg(" · ")] + memoryText(snap))
        } else {
            view.stripLeft = engine != nil ? "\(model) · \(engine!)" : model
            view.stripRight = segJoin(memoryText(snap))
        }

        // 单价按模型填：一个都没填时整行换成提示；有的没填时在日期后面标出不含几个模型
        let priced = _num(todayJSON["priced_models"])
        let unpriced = _num(todayJSON["unpriced_models"])
        let none = (unpriced.number ?? 0) > 0 && (priced.number ?? 0) == 0

        let currency = config.currency
        view.cap = "今日费用"
        view.unit = currency == "$" ? "美元" : currency
        if none {
            view.bigInt = "—"
            view.bigDec = ""
        } else {
            let cost = costFmt(_numD(todayJSON["cost"]), currency: currency)
            if let dot = cost.firstIndex(of: ".") {
                view.bigInt = String(cost[..<dot])
                view.bigDec = String(cost[dot...])
            } else {
                view.bigInt = cost
                view.bigDec = ""
            }
        }
        view.bigWhole = true
        view.bigSize = "cost"
        view.arc = "blank"
        view.arcTarget = nil
        let zoneName = zoneDisplayName(config.timezone)
        let dateText = dateLabel(todayJSON["date"]?.string ?? "")
        let barText: [Seg]
        if none {
            barText = [Seg("未填单价 · 在菜单栏里填", "warn")]
        } else if (unpriced.number ?? 0) > 0 {
            barText = [Seg("\(dateText) · \(zoneName) · "), Seg("不含 \(_pyStr(unpriced)) 个模型", "warn")]
        } else {
            barText = [Seg("\(dateText) · \(zoneName)")]
        }
        view.bar = Bar(kind: "note", frac: 0.0, level: "normal", text: barText)

        let prompt = _numD(todayJSON["prompt_tokens"])
        let cached = _numD(todayJSON["cached_tokens"])
        let tps = lastJSON["decode_tps"]
        view.cards = [
            Card("今日输入", tokFmt(prompt), "tok",
                 "缓存命中 \(pct(cached, prompt))%"),
            Card("今日输出", tokFmt(_numD(todayJSON["completion_tokens"])), "tok", ""),
            Card("今日请求", _pyStr(_num(todayJSON["requests"])), "次",
                 (tps?.truthy ?? false) ? "上次 \(String(format: "%.1f", tps!.number ?? 0)) tok/s" : ""),
        ]
    }

    // ---------- 各状态 ----------

    /// 引擎离线。
    private func offline(_ view: inout View, _ snap: JSON, _ memCard: Card) {
        let model = modelName(snap)
        let engine = engineName(snap)
        view.stateName = "引擎离线"
        // 引擎有问题时（app 写入 engine_note）状态条右侧改显示那句话
        let note = snap["engine_note"]?.string ?? ""
        if !note.isEmpty {
            view.stripRight = [Seg(note, "warn")]
        } else {
            var parts = [Seg("上次模型 \(model)")]
            if engine != nil { parts.append(Seg(" · \(engine!)")) }
            view.stripRight = segJoin(parts)
        }
        view.lanes.offline = true
        view.arc = "off"
        var todayJSON: JSON = [:]
        if let t = snap["today"], t.object != nil { todayJSON = t }
        // 单价按模型填：同今日画面的规则
        let priced = _num(todayJSON["priced_models"])
        let unpriced = _num(todayJSON["unpriced_models"])
        let none = (unpriced.number ?? 0) > 0 && (priced.number ?? 0) == 0
        let costValue = none ? "—" : costFmt(_numD(todayJSON["cost"]), currency: config.currency)
        let costFoot: String
        if none {
            costFoot = "未填单价"
        } else if (unpriced.number ?? 0) > 0 {
            costFoot = "不含 \(_pyStr(unpriced)) 个模型"
        } else {
            costFoot = ""
        }
        let secs = Int(floor(_numD(snap["offline_s"])))
        let offCard: Card
        if secs < 60 {
            offCard = Card("已离线", String(secs), "秒", "")
        } else {
            offCard = Card("已离线", String(Int(floor(Double(secs) / 60))), "分钟", "")
        }
        view.bar = nil
        view.cards = [
            Card("今日费用", costValue, "", costFoot),
            offCard,
            memCard,
        ]
    }

    /// 模型加载中（oMLX 按需加载）：已用时 + 按预计时间走的进度条，请求在后面排着。
    private func loading(_ view: inout View, _ snap: JSON, _ memCard: Card) {
        var ld: JSON = [:]
        if let l = snap["loading"], l.object != nil { ld = l }
        let el = _numD(ld["elapsed_s"])
        let estJ = ld["estimated_s"]
        let est: Double? = (estJ?.number).flatMap { $0 > 0 ? $0 : nil }

        view.stateName = "模型加载中"
        view.stripLeft = ""
        // 显示名：loading 里的模型名，取不到就用快照的
        let raw = ld["model"]?.string ?? ""
        let name = raw.isEmpty ? modelName(snap) : displayName(raw)
        let engine = engineName(snap)
        view.stripRight = [Seg(engine != nil ? "\(name) · \(engine!)" : name)]

        // 流指示点：照快照；三个数都是 0 时把排队设成 1（至少有个请求在等）
        if view.lanes.decoding + view.lanes.prefilling + view.lanes.waiting == 0 {
            view.lanes.waiting = 1
        }

        view.cap = "已用时"
        view.unit = "秒"
        view.bigWhole = true
        if el < 10 {
            let parts = split1(el)
            view.bigInt = parts.0
            view.bigDec = parts.1
        } else {
            view.bigInt = String(Int(floor(el)))
            view.bigDec = ""
        }
        view.arc = "blank"
        view.arcTarget = nil

        if let est {
            let estText = est < 10 ? String(format: "%.1f", est) : String(jsRound(est))
            let rem = _ceilAtLeast1(est - el)
            view.bar = Bar(kind: "prog", frac: min(0.99, el / est), level: "normal",
                           text: segJoin([Seg("预计 "), Seg(estText, "strong"), Seg(" s · 剩余约 "),
                                          Seg(String(rem), "strong"), Seg(" s")]))
        } else {
            view.bar = Bar(kind: "prog", frac: 0.0, level: "normal", text: [Seg("首次加载 · 没有预计时间")])
        }

        let sizeCard: Card
        if let size = ld["size_gb"]?.number {
            sizeCard = Card("模型大小", String(format: "%.1f", size), "GB", "")
        } else {
            sizeCard = Card("模型大小", "—", "", "", true)
        }
        view.cards = [
            sizeCard,
            Card("等待中", String(view.lanes.waiting), "个", "加载完开始"),
            memCard,
        ]
    }

    /// 预填充：够长（或预计够长、缓存未命中）才换成预填充画面。
    private func prefill(_ view: inout View, _ snap: JSON, _ rm: Bool, _ memCard: Card) {
        view.stateName = "预填充中"
        view.stripLeft = ""

        var prefillJSON: JSON = [:]
        if let p = snap["prefill"], p.object != nil { prefillJSON = p }
        let el = _numD(prefillJSON["elapsed_s"])
        let short = config.prefillShortS
        let hookMissing = snap["hook"]?.string == "missing"
        var take: Bool
        if hookMissing {
            // 外挂失效：没有缓存命中和进度信息，只按 3 秒切
            take = el >= short
        } else {
            let est = _numD(prefillJSON["est_s"])
            take = (el >= short || est >= short || (prefillJSON["cache_miss"]?.truthy ?? false))
        }
        if tookOver {
            // 一旦接管，在离开预填充之前一直是接管状态
            take = true
        }
        tookOver = take

        if !take {
            // 短预填充：画面保持之前的样子，只有状态条和流指示点变化
            if restKind == "today" || !rm {
                today(&view, snap)
            } else {
                roundRest(&view, snap)
            }
            view.stateName = "预填充中"
            view.stripLeft = ""
            view.stripRight = segJoin([Seg("已用时 "), Seg(String(format: "%.1f", el), "strong"), Seg(" s")])
            return
        }

        if hookMissing {
            prefillDegraded(&view, snap, el, rm)
            return
        }

        let prompt = _numD(prefillJSON["prompt_tokens"])
        let cached = _numD(prefillJSON["cached_tokens"])
        let filled = _numD(prefillJSON["filled_tokens"])
        let newTokens = prompt - cached
        let hit = pct(cached, prompt)
        let tps = prefillJSON["tps"]
        let estimated = prefillJSON["estimated"]?.truthy ?? false
        if estimated {
            // vLLM 读不到真实进度：主数字是近期平均速度，进度只能按时间估
            view.pill = true
            view.pillKind = "avg"
        }
        view.cap = "预填充速度"
        view.unit = "tok/s"
        view.bigInt = (tps?.truthy ?? false) ? String(jsRound(tps!.number ?? 0)) : "—"
        view.bigDec = ""
        view.bigSize = "four"
        view.arc = "prefill"
        view.scale = "prefill"
        view.arcTarget = v2f((tps?.truthy ?? false) ? tps!.number ?? 0 : 0, "prefill")
        view.bar = Bar(
            kind: "prog",
            frac: prompt != 0 ? filled / prompt : 0,
            level: "normal",
            text: segJoin([Seg(estimated ? "已算约 " : "已算 "),
                           Seg(tokFmt(filled), "strong"),
                           Seg(" / \(tokFmt(prompt))")])
        )

        let elTxt = el < 100 ? String(format: "%.1f", el) : String(Int(floor(el)))
        let rem: Int
        if estimated {
            // 剩余时间不看速度，固定按预计时间减去已用时
            rem = _ceilAtLeast1(_numD(prefillJSON["est_s"]) - el)
        } else {
            rem = remaining(prefillJSON, prompt, filled, el, tps)
        }
        if rm {
            view.cards = roundCards(snap)
            if prefillJSON["cache_miss"]?.truthy ?? false {
                view.stripRight = segJoin([
                    Seg("已用时 "), Seg(elTxt, "strong"), Seg(" s · "),
                    Seg("缓存未命中", "warn"),
                    Seg(" · 剩余约 "), Seg(String(rem), "strong"), Seg(" s"),
                ])
            } else {
                view.stripRight = segJoin([
                    Seg("已用时 "), Seg(elTxt, "strong"), Seg(" s · 缓存命中 "),
                    Seg("\(hit)%", "strong"),
                    Seg(" · 剩余约 "), Seg(String(rem), "strong"), Seg(" s"),
                ])
            }
        } else {
            view.cards = [
                Card("缓存命中", String(hit), "%",
                     "\(tokFmt(cached)) / \(tokFmt(prompt))"),
                Card("已等待", elTxt, "s", "剩余约 \(rem) s"),
                memCard,
            ]
            view.stripRight = segJoin([Seg("新算 "),
                                        Seg(tokFmt(newTokens), "strong"),
                                        Seg(" tok")])
        }
    }

    /// 外挂失效时的预填充画面：只剩“已用时”。
    private func prefillDegraded(_ view: inout View, _ snap: JSON, _ el: Double, _ rm: Bool) {
        view.cap = "已用时"
        view.unit = "秒"
        view.bigWhole = true
        if el < 10 {
            let parts = split1(el)
            view.bigInt = parts.0
            view.bigDec = parts.1
        } else {
            view.bigInt = String(Int(floor(el)))
            view.bigDec = ""
        }
        view.arc = "rest"
        view.scale = "decode"
        view.arcTarget = nil
        var lastJSON: JSON = [:]
        if let l = snap["last"], l.object != nil { lastJSON = l }
        let tps = lastJSON["decode_tps"]
        view.ghost = (tps?.truthy ?? false) ? v2f(tps!.number, "decode") : nil
        view.muted = false
        view.stripRight = [Seg("提示较长，可能需要几秒")]
        view.bar = contextBar(snap, snap["context_used"])
        if rm {
            view.cards = roundCards(snap)
        } else {
            view.cards = [
                Card("输出", "—", "", "", true),
                Card("首字", "—", "", "等待首个 token", true),
                memoryCard(snap),
            ]
        }
    }

    /// 剩余时间估算，至少 1 秒。
    private func remaining(_ prefillJSON: JSON, _ prompt: Double, _ filled: Double,
                           _ el: Double, _ tps: JSON?) -> Int {
        if tps?.truthy ?? false {
            return _ceilAtLeast1((prompt - filled) / (tps!.number ?? 0))
        }
        let est = _numD(prefillJSON["est_s"])
        return _ceilAtLeast1(est - el)
    }

    /// 解码：主数字是所有正在解码的流的合计速度。
    private func decode(_ view: inout View, _ snap: JSON, _ rm: Bool, _ memText: [Seg]) {
        view.stateName = "解码中"
        var decodeJSON: JSON = [:]
        if let d = snap["decode"], d.object != nil { decodeJSON = d }
        let tps = decodeJSON["tps"]
        view.cap = "解码速度"
        view.unit = "tok/s"
        view.bigValue = tps?.number
        view.bigInt = tps.isNone ? "" : String(jsRound(tps!.number ?? 0))
        view.bigDec = ""
        view.arc = "value"
        view.arcTarget = v2f((tps?.truthy ?? false) ? tps!.number ?? 0 : 0, "decode")
        view.bar = contextBar(snap, snap["context_used"])

        var lanesJSON: JSON = [:]
        if let l = snap["lanes"], l.object != nil { lanesJSON = l }
        let decoding = _numD(lanesJSON["decoding"])
        let prefilling = _numD(lanesJSON["prefilling"])
        let waiting = _numD(lanesJSON["waiting"])
        if decoding + prefilling >= 2 || waiting > 0 {
            // 多条流（或有排队）：把各路数量列出来
            var parts = [Seg("解码 "), Seg(_pyStr(_num(lanesJSON["decoding"])), "strong")]
            if prefilling != 0 {
                parts += [Seg(" · "), Seg("预填充 "), Seg(_pyStr(_num(lanesJSON["prefilling"])), "strong")]
            }
            if waiting != 0 {
                parts += [Seg(" · "), Seg("排队 "), Seg(_pyStr(_num(lanesJSON["waiting"])), "strong")]
            }
            parts += [Seg(" · ")] + memText
            view.stripRight = segJoin(parts)
        } else {
            let ttft = decodeJSON["ttft_s"]
            if !ttft.isNone {
                view.stripRight = segJoin([Seg("首字 "), Seg(String(format: "%.2f", ttft!.number ?? 0), "strong"),
                                           Seg(" s · ")] + memText)
            } else {
                view.stripRight = segJoin(memText)
            }
        }

        if rm {
            view.cards = roundCards(snap)
            return
        }
        let output = _numD(decodeJSON["output_tokens"])
        let avg = decodeJSON["tps_avg"]
        let peak = decodeJSON["tps_peak"]
        view.cards = [
            Card("输出", tokFmt(output), "tok", ""),
            !avg.isNone ? Card("平均", String(format: "%.1f", avg!.number ?? 0), "", "tok/s")
                : Card("平均", "—", "", "", true),
            (peak?.truthy ?? false) ? Card("峰值", String(jsRound(peak!.number ?? 0)), "tok/s", "")
                : Card("峰值", "—", "", "", true),
        ]
    }

    /// 完成：一轮里画本轮统计，单个请求画上一个请求的成绩。
    private func done(_ view: inout View, _ snap: JSON, _ rm: Bool, _ memText: [Seg]) {
        view.stateName = "完成"
        let last = snap["last"]

        if rm {
            roundRest(&view, snap)
            view.stateName = "完成"
            let rnd = snap["round"]
            let exact = rnd?.object != nil && (rnd!["exact"]?.truthy ?? false)
            let ttft = last?.object != nil ? last!["ttft_s"] : nil
            if exact && !ttft.isNone {
                view.stripRight = segJoin([Seg("首字 "), Seg(String(format: "%.2f", ttft!.number ?? 0), "strong"),
                                           Seg(" s")])
            } else {
                view.stripRight = segJoin(memText)
            }
            return
        }

        if last?.object == nil {
            // 没有上一个请求的成绩（不该发生）：按今日统计画
            today(&view, snap)
            view.stateName = "完成"
            return
        }
        let lastJSON = last!

        let tps = lastJSON["decode_tps"]
        let ttft = lastJSON["ttft_s"]
        view.cap = "平均速度"
        view.unit = "tok/s"
        view.pill = true
        if !tps.isNone {
            let parts = split1(tps!.number ?? 0)
            view.bigInt = parts.0
            view.bigDec = parts.1
        } else {
            view.bigInt = "—"
            view.bigDec = ""
        }
        view.arc = "value"
        view.arcTarget = v2f((tps?.truthy ?? false) ? tps!.number ?? 0 : 0, "decode")
        view.bar = contextBar(snap, lastJSON["context_used"])
        // oMLX 没有推测解码的接受率：第三格改成首字，状态条就不再重复写首字
        view.stripRight = segJoin(memText)

        let prompt = _numD(lastJSON["prompt_tokens"])
        let cached = _numD(lastJSON["cached_tokens"])
        view.cards = [
            Card("输出", tokFmt(_numD(lastJSON["completion_tokens"])), "tok",
                 "提示 \(tokFmt(prompt)) tok"),
            Card("缓存命中", String(pct(cached, prompt)), "%",
                 "\(tokFmt(cached)) tok"),
            !ttft.isNone ? Card("首字", String(format: "%.2f", ttft!.number ?? 0), "s", "")
                : Card("首字", "—", "", "", true),
        ]
    }
}
