// 今日用量：把 /health 里的累计值换算成当天的增量，按模型分开记在当天的账上。
// 翻译自 panel/usage.py，按模型记账是 Mac 版的新规则（见 docs/design-mac.md 的“费用单价”）。
// 读文件、写文件都不抛异常：读不懂就当没有，写不进去就留着“待写”，下次再试。
import Foundation

private let USAGE_FILE = "usage.json"
private let HISTORY_FILE = "usage-history.jsonl"

// 今日账上的四项，和 /health 里的累计值一一对应
private let COUNTERS = ["prompt_tokens", "cached_tokens", "completion_tokens", "requests"]
// /health 里对应的键名
private let SOURCE_KEYS = ["prompt", "cached", "completion", "requests"]

private let FALLBACK_TIMEZONE = "America/Los_Angeles"

// 引擎启动标记的容差：oMLX 的启动时刻是算出来的，程序重启后会差一两秒，30 秒以内算同一次启动
private let EPOCH_TOLERANCE_S = 30.0

public final class UsageLedger: UsageSink {
    private var config: Config
    private let clock: () -> Double
    private let stateDir: String
    private var zone: TimeZone
    private let saveIntervalS: Double

    private var byModel: [String: [String: Int]]   // 模型名 → 四项（键同 COUNTERS）；今天的合计是各模型相加
    private var lastTotals: [String: Int]?          // 上一次读到的四项合计；nil 表示还没有基线
    private var lastByModel: [String: [String: Int]]?  // 上一次读数里的 by_model（键同 SOURCE_KEYS）；nil 表示没有
    private var lastEpoch: JSON?                    // 上次读数的引擎启动标记（vLLM 才有）；nil 表示没有
    private var date: String?
    private var pending = false                     // 文件和内存里的账一致，没有要写的东西
    private var lastWrite: Double?                  // 上次写文件时的时刻

    public init(config: Config, clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                stateDir: String? = nil, saveIntervalS: Double = 10.0) {
        self.config = config
        self.clock = clock
        self.stateDir = ((stateDir ?? config.stateDir) as NSString).expandingTildeInPath
        self.zone = UsageLedger.makeZone(config.timezone)
        self.saveIntervalS = saveIntervalS
        self.byModel = [:]
        self.lastTotals = nil
        self.lastByModel = nil
        self.lastEpoch = nil
        self.date = nil
        self.pending = false
        self.lastWrite = nil
        load()
    }

    public func update(_ totals: JSON) {
        // 把一组累计值记进账：先换日，再算增量，分到各模型名下，最后按需写文件。
        guard totals.object != nil else { return }
        let now = clock()
        rollDay(now)
        guard valid(totals) else { return }   // 缺键或值不是整数：整次忽略
        // 引擎启动标记：不是数字就当没有（只用 TensorFold 时一直是 nil）
        let epochJSON = totals["epoch"]
        let epoch: JSON? = (epochJSON?.number != nil) ? epochJSON : nil
        let epochChanged = Self.epochChanged(epoch, lastEpoch)
        var delta: [String: Int]?
        var wholeAsDelta = false   // 这次是不是“整个算增量”（第一次以外的重启、标记变了）
        if let last = lastTotals {
            if epochChanged {
                delta = whole(totals)   // 引擎重启或换了引擎：整个算增量
                wholeAsDelta = true
            } else if SOURCE_KEYS.contains(where: { totals[$0]!.int! < last[$0]! }) {
                delta = whole(totals)   // 模型重启过：整个算增量
                wholeAsDelta = true
            } else {
                delta = Dictionary(uniqueKeysWithValues: SOURCE_KEYS.map { ($0, totals[$0]!.int! - last[$0]!) })
            }
        } else {
            delta = nil   // 第一次运行：只记下基线，不动账
        }
        // 这次的按模型累计值：结构不合格就当没有
        let byM = Self.parseByModel(totals["by_model"], valueKeys: SOURCE_KEYS)
        let fallback = totals["model"]?.string ?? ""
        if let delta {
            distribute(delta, byM: byM, whole: wholeAsDelta, fallback: fallback)
        }
        lastTotals = whole(totals)
        lastByModel = byM
        lastEpoch = epoch
        if delta == nil || epochChanged || delta!.values.contains(where: { $0 != 0 }) {
            pending = true
        }
        maybeWrite(now)
    }

    public func today() -> JSON {
        // 今天的账（费用现算）。先处理换日，离线时过了 0 点这里也会清零。
        let now = clock()
        rollDay(now)
        let totals = summed()
        let snap = modelsSnapshot()
        return [
            "date": JSON(date),
            "prompt_tokens": .int(totals["prompt_tokens"]!),
            "cached_tokens": .int(totals["cached_tokens"]!),
            "completion_tokens": .int(totals["completion_tokens"]!),
            "requests": .int(totals["requests"]!),
            "cost": .double(snap.cost),
            "by_model": .object(snap.models),
            "priced_models": .int(snap.priced),
            "unpriced_models": .int(snap.unpriced),
        ]
    }

    public func flush() {
        // 有没写的改动就立刻写文件（不受写文件间隔的限制）。
        if pending { _ = write() }
    }

    /// 换单价、换时区，立刻生效：不写文件、不动账，下一次 update 或 today 的换日检查会按新时区处理。
    public func apply(config: Config) {
        self.config = config
        self.zone = UsageLedger.makeZone(config.timezone)
    }

    // 以下都是内部方法

    /// 时区名；配置里的时区名无效时退回太平洋时间，再不行按 UTC−8。
    private static func makeZone(_ name: String) -> TimeZone {
        if let z = TimeZone(identifier: name) { return z }
        if let z = TimeZone(identifier: FALLBACK_TIMEZONE) { return z }
        return TimeZone(secondsFromGMT: -8 * 3600)!
    }

    private static func zeroCounters() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: COUNTERS.map { ($0, 0) })
    }

    /// 引擎启动标记变没变：一边有一边没有算变了；两边都有时相差超过 30 秒才算变了；两边都没有算没变。
    private static func epochChanged(_ epoch: JSON?, _ last: JSON?) -> Bool {
        guard let e = epoch?.number, let l = last?.number else { return (epoch != nil) != (last != nil) }
        return abs(e - l) > EPOCH_TOLERANCE_S
    }

    /// 四项齐全且都是整数（bool 不算整数）才算一次有效读数。
    private func valid(_ totals: JSON) -> Bool {
        for key in SOURCE_KEYS {
            if totals[key]?.int == nil { return false }
        }
        return true
    }

    private func whole(_ totals: JSON) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: SOURCE_KEYS.map { ($0, totals[$0]!.int!) })
    }

    /// 解析按模型的累计值：`{模型名: {四个键: 整数}}`；每个值都是对象、四个键都是整数才算有，否则 nil。
    private static func parseByModel(_ value: JSON?, valueKeys: [String]) -> [String: [String: Int]]? {
        guard let o = value?.object else { return nil }
        var out: [String: [String: Int]] = [:]
        for (m, v) in o {
            guard let vo = v.object else { return nil }
            var entry: [String: Int] = [:]
            for key in valueKeys {
                guard let n = vo[key]?.int else { return nil }
                entry[key] = n
            }
            out[m] = entry
        }
        return out
    }

    /// 把合计的增量分到各模型名下，每一项（四个 SOURCE_KEYS）分别处理。
    private func distribute(_ delta: [String: Int], byM: [String: [String: Int]]?, whole: Bool, fallback: String) {
        guard let byM else {
            // 没有按模型的累计值：整个增量记在当前模型名下
            for (counter, src) in zip(COUNTERS, SOURCE_KEYS) {
                add(fallback, counter: counter, value: delta[src]!)
            }
            return
        }
        for (counter, src) in zip(COUNTERS, SOURCE_KEYS) {
            var parts: [(String, Int)] = []
            var sum = 0
            for (m, vals) in byM {
                let v: Int
                if whole || lastByModel == nil || lastByModel![m] == nil {
                    v = vals[src]!
                } else {
                    v = max(0, vals[src]! - lastByModel![m]![src]!)
                }
                parts.append((m, v))
                sum += v
            }
            if sum == delta[src]! {
                for (m, v) in parts { add(m, counter: counter, value: v) }
            } else {
                // 各模型加起来对不上合计：整个增量记在当前模型名下
                add(fallback, counter: counter, value: delta[src]!)
            }
        }
    }

    /// 记一笔：加到某模型的四项上；增量为 0 时不新建模型条目（今天的账里只出现真有用量的模型）。
    private func add(_ model: String, counter: String, value: Int) {
        if value == 0 && byModel[model] == nil { return }
        var entry = byModel[model] ?? UsageLedger.zeroCounters()
        entry[counter, default: 0] += value
        byModel[model] = entry
    }

    /// 今天四项的合计：各模型相加。
    private func summed() -> [String: Int] {
        var totals = UsageLedger.zeroCounters()
        for entry in byModel.values {
            for k in COUNTERS { totals[k] = totals[k]! + entry[k]! }
        }
        return totals
    }

    /// 按模型的明细（含各自的费用）+ 填了单价、没填单价的模型个数 + 有单价的模型的费用之和。
    private func modelsSnapshot() -> (models: [String: JSON], priced: Int, unpriced: Int, cost: Double) {
        var models: [String: JSON] = [:]
        var priced = 0
        var unpriced = 0
        var cost = 0.0
        for (m, entry) in byModel {
            var o: [String: JSON] = [:]
            for k in COUNTERS { o[k] = .int(entry[k]!) }
            if let price = config.prices[m] {
                let c = Self.cost(entry, price: price)
                o["cost"] = .double(c)
                cost += c
                priced += 1
            } else {
                o["cost"] = .null
                unpriced += 1
            }
            models[m] = .object(o)
        }
        return (models, priced, unpriced, cost)
    }

    /// 一个模型的费用（单价都是每百万 token）。
    private static func cost(_ entry: [String: Int], price: ModelPrice) -> Double {
        let cached = entry["cached_tokens"]!
        let total = Double(entry["prompt_tokens"]! - cached) * price.input
            + Double(cached) * price.cached
            + Double(entry["completion_tokens"]!) * price.output
        return total / 1_000_000
    }

    /// 按配置的时区算出今天的日期。
    private func dateStr(_ now: Double) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: now))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// 换日：前一天写进历史，按模型的账清零，日期改成今天，并立刻写文件。
    private func rollDay(_ now: Double) {
        let t = dateStr(now)
        if t == date { return }
        if date != nil && byModel.values.contains(where: { $0.values.contains(where: { $0 != 0 }) }) {
            appendHistory(date!)
        }
        date = t
        byModel = [:]
        pending = true
        _ = write()
    }

    /// 到点了才写文件，免得每秒写一次磁盘。
    private func maybeWrite(_ now: Double) {
        guard pending else { return }
        if let lastWrite, now - lastWrite < saveIntervalS { return }
        _ = write()
    }

    /// 把账写进文件；写成功就清掉“待写”标记，写失败就留着下次再试。
    private func write() -> Bool {
        var lastTotalsJSON: JSON = .null
        if let lt = lastTotals {
            var o: [String: JSON] = [:]
            for (k, v) in lt { o[k] = .int(v) }
            lastTotalsJSON = .object(o)
        }
        var lastByModelJSON: JSON = .null
        if let lbm = lastByModel {
            var o: [String: JSON] = [:]
            for (m, entry) in lbm {
                var e: [String: JSON] = [:]
                for k in SOURCE_KEYS { e[k] = .int(entry[k]!) }
                o[m] = .object(e)
            }
            lastByModelJSON = .object(o)
        }
        var byModelJSON: [String: JSON] = [:]
        for (m, entry) in byModel {
            var e: [String: JSON] = [:]
            for k in COUNTERS { e[k] = .int(entry[k]!) }
            byModelJSON[m] = .object(e)
        }
        // 四项合计（各模型相加）只供人看，读文件时以 by_model 为准
        let totals = summed()
        var obj: [String: JSON] = [
            "version": .int(2),
            "date": JSON(date),
            "prompt_tokens": .int(totals["prompt_tokens"]!),
            "cached_tokens": .int(totals["cached_tokens"]!),
            "completion_tokens": .int(totals["completion_tokens"]!),
            "requests": .int(totals["requests"]!),
            "last_totals": lastTotalsJSON,
            "by_model": .object(byModelJSON),
            "last_by_model": lastByModelJSON,
        ]
        if let lastEpoch { obj["last_epoch"] = lastEpoch }
        if writeText(USAGE_FILE, JSON.object(obj).serialized() + "\n") {
            pending = false
            lastWrite = clock()
            return true
        }
        return false
    }

    /// 把一天的账（合计 + 各模型明细）追加到历史文件；写不进去就丢掉这一行，不抛异常。
    private func appendHistory(_ day: String) {
        var obj: [String: JSON] = ["date": .string(day)]
        let totals = summed()
        for k in COUNTERS { obj[k] = .int(totals[k]!) }
        let snap = modelsSnapshot()
        obj["cost"] = .double(snap.cost)
        obj["by_model"] = .object(snap.models)
        _ = writeText(HISTORY_FILE, JSON.object(obj).serialized() + "\n", append: true)
    }

    /// 读账本文件；读不了或者不是合法的 JSON 对象就返回 nil。
    private func read() -> JSON? {
        let path = stateDir + "/" + USAGE_FILE
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let parsed = JSON.parse(data), parsed.object != nil else { return nil }
        return parsed
    }

    /// 读 usage.json；读不懂就当作第一次运行（账为 0，没有基线）。
    private func load() {
        if let data = read(), loadFrom(data) { return }
        date = dateStr(clock())
    }

    /// 文件里的账能用就采用，用不了返回 false（按第一次运行处理）。
    private func loadFrom(_ data: JSON) -> Bool {
        guard let d = data["date"]?.string, !d.isEmpty else { return false }
        for key in COUNTERS {
            if data[key]?.int == nil { return false }
        }
        guard let last = data["last_totals"]?.object else { return false }
        for key in SOURCE_KEYS {
            if last[key]?.int == nil { return false }
        }
        var bm: [String: [String: Int]]
        if data["by_model"] != nil {
            // 第 2 版的文件：有任何一项不合格就整个按读不懂处理
            guard let parsed = Self.parseByModel(data["by_model"], valueKeys: COUNTERS) else { return false }
            bm = parsed
        } else {
            // 第 1 版的文件（只有四项合计）：有用量就记在无名模型 "" 名下
            bm = [:]
            let totals = Dictionary(uniqueKeysWithValues: COUNTERS.map { ($0, data[$0]!.int!) })
            if totals.values.contains(where: { $0 != 0 }) { bm[""] = totals }
        }
        date = d
        byModel = bm
        lastTotals = Dictionary(uniqueKeysWithValues: SOURCE_KEYS.map { ($0, last[$0]!.int!) })
        lastByModel = Self.parseByModel(data["last_by_model"], valueKeys: SOURCE_KEYS)
        let e = data["last_epoch"]
        lastEpoch = (e?.number != nil) ? e : nil
        return true
    }

    /// 写文件；目录建不出来或文件动不了就返回 false。
    private func writeText(_ name: String, _ text: String, append: Bool = false) -> Bool {
        let path = stateDir + "/" + name
        do {
            try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            if append {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(text.utf8))
                } else {
                    try Data(text.utf8).write(to: url)
                }
                return true
            }
            return replaceText(path, text)
        } catch {
            return false
        }
    }

    /// 原子替换：先写临时文件再改名换过去，避免读到写了一半的文件。
    private func replaceText(_ path: String, _ text: String) -> Bool {
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
