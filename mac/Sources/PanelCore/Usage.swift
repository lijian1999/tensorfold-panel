// 今日用量：把 /health 里的累计值换算成当天的增量，记在当天的账上。
// 翻译自 panel/usage.py。读文件、写文件都不抛异常：读不懂就当没有，写不进去就留着“待写”，下次再试。
import Foundation

private let USAGE_FILE = "usage.json"
private let HISTORY_FILE = "usage-history.jsonl"

// 今日账上的四项，和 /health 里的累计值一一对应
private let COUNTERS = ["prompt_tokens", "cached_tokens", "completion_tokens", "requests"]
// /health 里对应的键名
private let SOURCE_KEYS = ["prompt", "cached", "completion", "requests"]

private let FALLBACK_TIMEZONE = "America/Los_Angeles"

public final class UsageLedger: UsageSink {
    private let config: Config
    private let clock: () -> Double
    private let stateDir: String
    private let zone: TimeZone
    private let saveIntervalS: Double

    private var counters: [String: Int]
    private var lastTotals: [String: Int]?   // 上一次读到的累计值；nil 表示还没有基线
    private var lastEpoch: JSON?             // 上次读数的引擎启动标记（vLLM 才有）；nil 表示没有
    private var date: String?
    private var pending = false              // 文件和内存里的账一致，没有要写的东西
    private var lastWrite: Double?           // 上次写文件时的时刻

    public init(config: Config, clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                stateDir: String? = nil, saveIntervalS: Double = 10.0) {
        self.config = config
        self.clock = clock
        self.stateDir = ((stateDir ?? config.stateDir) as NSString).expandingTildeInPath
        self.zone = UsageLedger.makeZone(config.timezone)
        self.saveIntervalS = saveIntervalS
        self.counters = UsageLedger.zeroCounters()
        self.lastTotals = nil
        self.lastEpoch = nil
        self.date = nil
        self.pending = false
        self.lastWrite = nil
        load()
    }

    public func update(_ totals: JSON) {
        // 把一组累计值记进账：先换日，再算增量，最后按需写文件。
        guard totals.object != nil else { return }
        let now = clock()
        rollDay(now)
        guard valid(totals) else { return }   // 缺键或值不是整数：整次忽略
        // 引擎启动标记：不是数字就当没有（只用 TensorFold 时一直是 nil）
        let epochJSON = totals["epoch"]
        let epoch: JSON? = (epochJSON?.number != nil) ? epochJSON : nil
        let epochChanged = epoch != lastEpoch
        var delta: [String: Int]?
        if let last = lastTotals {
            if epochChanged {
                delta = whole(totals)   // 引擎重启或换了引擎：整个算增量
            } else if SOURCE_KEYS.contains(where: { totals[$0]!.int! < last[$0]! }) {
                delta = whole(totals)   // 模型重启过：整个算增量
            } else {
                delta = Dictionary(uniqueKeysWithValues: SOURCE_KEYS.map { ($0, totals[$0]!.int! - last[$0]!) })
            }
        } else {
            delta = nil   // 第一次运行：只记下基线，不动账
        }
        lastTotals = whole(totals)
        lastEpoch = epoch
        if delta == nil || epochChanged || delta!.values.contains(where: { $0 != 0 }) {
            pending = true
        }
        if let delta {
            for (counter, src) in zip(COUNTERS, SOURCE_KEYS) {
                counters[counter, default: 0] += delta[src]!
            }
        }
        maybeWrite(now)
    }

    public func today() -> JSON {
        // 今天的账（费用现算）。先处理换日，离线时过了 0 点这里也会清零。
        let now = clock()
        rollDay(now)
        let result: JSON = [
            "date": JSON(date),
            "prompt_tokens": .int(counters["prompt_tokens"]!),
            "cached_tokens": .int(counters["cached_tokens"]!),
            "completion_tokens": .int(counters["completion_tokens"]!),
            "requests": .int(counters["requests"]!),
            "cost": .double(cost(counters)),
        ]
        return result
    }

    public func flush() {
        // 有没写的改动就立刻写文件（不受写文件间隔的限制）。
        if pending { _ = write() }
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

    /// 按配置的时区算出今天的日期。
    private func dateStr(_ now: Double) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: now))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// 换日：前一天写进历史，四项清零，日期改成今天，并立刻写文件。
    private func rollDay(_ now: Double) {
        let t = dateStr(now)
        if t == date { return }
        if date != nil && counters.values.contains(where: { $0 != 0 }) {
            appendHistory(date!, cost(counters))
        }
        date = t
        counters = UsageLedger.zeroCounters()
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
        var obj: [String: JSON] = [
            "version": .int(1),
            "date": JSON(date),
            "prompt_tokens": .int(counters["prompt_tokens"]!),
            "cached_tokens": .int(counters["cached_tokens"]!),
            "completion_tokens": .int(counters["completion_tokens"]!),
            "requests": .int(counters["requests"]!),
            "last_totals": lastTotalsJSON,
        ]
        if let lastEpoch { obj["last_epoch"] = lastEpoch }
        if writeText(USAGE_FILE, JSON.object(obj).serialized() + "\n") {
            pending = false
            lastWrite = clock()
            return true
        }
        return false
    }

    /// 把一天的合计追加到历史文件；写不进去就丢掉这一行，不抛异常。
    private func appendHistory(_ day: String, _ costValue: Double) {
        var obj: [String: JSON] = ["date": .string(day)]
        for key in COUNTERS { obj[key] = .int(counters[key]!) }
        obj["cost"] = .double(costValue)
        _ = writeText(HISTORY_FILE, JSON.object(obj).serialized() + "\n", append: true)
    }

    /// 按配置的单价算费用（单价都是每百万 token）。
    private func cost(_ counters: [String: Int]) -> Double {
        let cached = counters["cached_tokens"]!
        let total = Double(counters["prompt_tokens"]! - cached) * config.priceInput
            + Double(cached) * config.priceCached
            + Double(counters["completion_tokens"]!) * config.priceOutput
        return total / 1_000_000
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

    /// 文件里的账能用就采用，用不了返回 nil（按第一次运行处理）。
    private func loadFrom(_ data: JSON) -> Bool {
        guard let d = data["date"]?.string, !d.isEmpty else { return false }
        for key in COUNTERS {
            if data[key]?.int == nil { return false }
        }
        guard let last = data["last_totals"]?.object else { return false }
        for key in SOURCE_KEYS {
            if last[key]?.int == nil { return false }
        }
        date = d
        counters = Dictionary(uniqueKeysWithValues: COUNTERS.map { ($0, data[$0]!.int!) })
        lastTotals = Dictionary(uniqueKeysWithValues: SOURCE_KEYS.map { ($0, last[$0]!.int!) })
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

// 临时：合并时删掉，以 Collector.swift 里的为准
public protocol UsageSink: AnyObject {
    func update(_ totals: JSON) throws
    func today() throws -> JSON
}
