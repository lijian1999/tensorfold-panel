// 翻译自 panel/tests/test_usage.py：今日用量模块的测试 UsageLedger。
// 用假时钟和临时目录，不 sleep，也不碰真实的 state 目录。
import Foundation
import Testing
@testable import PanelCore

/// 2026 年 10 月 day 日 hh:mm:ss（UTC）→ 时间戳。
///
/// 副屏按太平洋时间（夏令时，UTC−7）划分日期：
/// 太平洋时间 12:00:00 = UTC 19:00:00，太平洋时间 23:59:50 = UTC 次日 06:59:50。
private func utc_ts(_ day: Int, _ clockStr: String) -> Double {
    let parts = clockStr.split(separator: ":").map { Int($0)! }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var comps = DateComponents()
    comps.year = 2026; comps.month = 10; comps.day = day
    comps.hour = parts[0]; comps.minute = parts[1]; comps.second = parts[2]
    return Double(cal.date(from: comps)!.timeIntervalSince1970)
}

// 太平洋时间 2026-10-03 12:00:00
private let NOON = utc_ts(3, "19:00:00")
// 太平洋时间 2026-10-03 23:59:50
private let LATE_NIGHT = utc_ts(4, "06:59:50")
// 太平洋时间 2026-10-04 00:00:10
private let MIDNIGHT = utc_ts(4, "07:00:10")
// 太平洋时间 2026-10-03 23:00:00（和 UTC 的日期差一天，用来验时区）
private let EVENING = utc_ts(4, "06:00:00")

// 引擎启动时刻：太平洋时间 2026-10-03 01:00:00（今天）
private let TODAY_EPOCH = utc_ts(3, "07:00:00") + 3600
// 引擎启动时刻：太平洋时间 2026-10-01 00:00:00（几天前）
private let OLD_EPOCH = utc_ts(1, "07:00:00")

private let TOTALS: JSON = ["prompt": 1000, "cached": 400, "completion": 50, "requests": 3]
private let BIGGER: JSON = ["prompt": 1500, "cached": 600, "completion": 80, "requests": 5]
private let SMALLER: JSON = ["prompt": 120, "cached": 0, "completion": 30, "requests": 1]

/// 带原来默认单价的配置（单价改成按模型填后，原来的默认一组写在无名模型 "" 名下）。
private func pricedConfig() -> Config {
    var c = Config()
    c.prices[""] = ModelPrice(input: 0.15, cached: 0.016, output: 0.47)
    return c
}

/// by_model 里一个模型的四项（键同 SOURCE_KEYS），四项都写全。
private func bm(_ prompt: Int, _ cached: Int, _ completion: Int, _ requests: Int) -> JSON {
    ["prompt": .int(prompt), "cached": .int(cached), "completion": .int(completion), "requests": .int(requests)]
}

/// 假时钟：时间戳由测试拨。
private final class Clock {
    var ts: Double
    init(_ ts: Double) { self.ts = ts }
}

/// 在临时目录下新建一个唯一子目录，当作 state_dir。
private func newTempDir() -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tfpanel-usage-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

/// 公共部分（对应 LedgerTest）：临时目录当 state_dir，假时钟当时钟。
private final class Harness {
    let dir: String
    private(set) var clock = Clock(NOON)
    init() { dir = newTempDir() }

    func ledger(ts: Double = NOON, config: Config = pricedConfig(), interval: Double = 10.0,
                stateDir: String? = nil) -> UsageLedger {
        let c = Clock(ts)
        clock = c
        return UsageLedger(config: config, clock: { c.ts }, stateDir: stateDir ?? dir, saveIntervalS: interval)
    }

    /// 读磁盘上的账。
    func readUsage() -> JSON {
        let data = try! Data(contentsOf: URL(fileURLWithPath: dir + "/usage.json"))
        return JSON.parse(data)!
    }

    func writeUsage(_ text: String) {
        try! Data(text.utf8).write(to: URL(fileURLWithPath: dir + "/usage.json"))
    }
}

/// 今日账上的四项，方便比较。
private func four(_ today: JSON) -> (Int, Int, Int, Int) {
    (today["prompt_tokens"]!.int!, today["cached_tokens"]!.int!,
     today["completion_tokens"]!.int!, today["requests"]!.int!)
}

/// dict(base, **kv)：在 base 上加几个键。
private func plus(_ base: JSON, _ kv: [String: JSON]) -> JSON {
    var o = base.object ?? [:]
    for (k, v) in kv { o[k] = v }
    return .object(o)
}

/// 读历史文件的每一行。
private func readHistory(_ dir: String) -> [JSON] {
    let text = try! String(contentsOfFile: dir + "/usage-history.jsonl", encoding: .utf8)
    var out: [JSON] = []
    for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append(JSON.parse(line)!)
    }
    return out
}

/// 读文件修改时间（对应 os.stat(path).st_mtime_ns）。
private func mtime(_ path: String) -> Date {
    (try! FileManager.default.attributesOfItem(atPath: path))[.modificationDate] as! Date
}

@Suite struct TestFirstRun {
    @Test func test_first_update_records_nothing() {
        // 第一次读只记下累计值，不动账。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(TOTALS)
        #expect(four(ledger.today()) == (0, 0, 0, 0))
        #expect(ledger.today()["date"] == .string("2026-10-03"))
    }

    @Test func test_second_update_adds_increment() {
        // 第二次读：把比上次多的部分记到今天的账上。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(TOTALS)
        ledger.update(BIGGER)
        #expect(four(ledger.today()) == (500, 200, 30, 2))
    }
}

@Suite struct TestCost {
    @Test func test_cost() {
        // 费用 =（提示 − 缓存命中）× 输入价 + 缓存命中 × 缓存价 + 输出 × 输出价。
        let totals: JSON = ["prompt": 8260391, "cached": 5443627, "completion": 185305, "requests": 98]
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(["prompt": 0, "cached": 0, "completion": 0, "requests": 0])
        ledger.update(totals)
        #expect(almostEqual(ledger.today()["cost"]!.double!, 0.5967, places: 4))
    }

    @Test func test_cost_with_other_price() {
        // 改输出单价，费用跟着变。
        let totals: JSON = ["prompt": 8260391, "cached": 5443627, "completion": 185305, "requests": 98]
        var cfg = pricedConfig(); cfg.prices[""] = ModelPrice(input: 0.15, cached: 0.016, output: 1.0)
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger(config: cfg)
        ledger.update(["prompt": 0, "cached": 0, "completion": 0, "requests": 0])
        ledger.update(totals)
        #expect(almostEqual(ledger.today()["cost"]!.double!, 0.6949, places: 4))
    }
}

@Suite struct TestModelRestart {
    @Test func test_累计值变小且没有启动标记时只记基线() {
        // 累计值比上次小：模型重启过。没有启动时刻就分不清这份累计值里有多少是今天的，
        // 只当作新基线，不把整份算进今天（否则会把前几天的累计记到今天）。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(TOTALS)
        ledger.update(SMALLER)
        #expect(four(ledger.today()) == (0, 0, 0, 0))
        // 重启之后接着按差值记
        ledger.update(["prompt": 200, "cached": 10, "completion": 40, "requests": 2])
        #expect(four(ledger.today()) == (80, 10, 10, 1))
    }

    @Test func test_引擎今天启动时累计值变小算整个() {
        // 启动时刻在今天：整份累计值都是今天产生的，算进今天。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["epoch": .double(TODAY_EPOCH)]))
        ledger.update(plus(SMALLER, ["epoch": .double(TODAY_EPOCH)]))
        #expect(four(ledger.today()) == (120, 0, 30, 1))
        ledger.update(plus(["prompt": 200, "cached": 10, "completion": 40, "requests": 2],
                           ["epoch": .double(TODAY_EPOCH)]))
        #expect(four(ledger.today()) == (200, 10, 40, 2))
    }

    @Test func test_隔天接上几天前启动的引擎时只记基线() {
        // 文件里是昨天的账和一个旧引擎的大累计值；今天接上几天前就启动的引擎，累计值反而变小。
        // 整份累计值含前几天的用量，不能记进今天。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        h.writeUsage("""
        {"version": 2, "date": "2026-10-02", "prompt_tokens": 0, "cached_tokens": 0, \
        "completion_tokens": 0, "requests": 0, \
        "last_totals": {"prompt": 5000, "cached": 4000, "completion": 500, "requests": 50}, \
        "last_epoch": \(OLD_EPOCH)}
        """)
        let ledger = h.ledger()
        ledger.update(plus(SMALLER, ["epoch": .double(OLD_EPOCH)]))
        #expect(ledger.today()["date"] == .string("2026-10-03"))
        #expect(four(ledger.today()) == (0, 0, 0, 0))
        // 新基线之后的增量照常记
        ledger.update(plus(["prompt": 200, "cached": 10, "completion": 40, "requests": 2],
                           ["epoch": .double(OLD_EPOCH)]))
        #expect(four(ledger.today()) == (80, 10, 10, 1))
    }
}

@Suite struct TestProgramRestart {
    @Test func test_new_ledger_continues_the_day() {
        // 副屏程序重启：新账本接着上次的累计值补上这段空隙的用量。
        let dir = newTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = Clock(NOON)
        let first = UsageLedger(config: pricedConfig(), clock: { clock.ts }, stateDir: dir)
        first.update(TOTALS)
        first.update(BIGGER)
        first.flush()
        #expect(four(first.today()) == (500, 200, 30, 2))

        let second = UsageLedger(config: pricedConfig(), clock: { clock.ts }, stateDir: dir)
        second.update(["prompt": 2000, "cached": 900, "completion": 120, "requests": 8])
        // 之前的 500/200/30/2 加上这段空隙里的 500/300/40/3
        #expect(four(second.today()) == (1000, 500, 70, 5))
    }
}

@Suite struct TestDayRollover {
    @Test func test_rollover() {
        // 过 0 点：今天的账清零，前一天追加到历史文件。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger(ts: LATE_NIGHT)
        ledger.update(TOTALS)
        ledger.update(BIGGER)
        #expect(ledger.today()["date"] == .string("2026-10-03"))

        h.clock.ts = MIDNIGHT
        let today = ledger.today()  // today() 自己就会换日
        #expect(today["date"] == .string("2026-10-04"))
        #expect(four(today) == (0, 0, 0, 0))

        let lines = readHistory(h.dir)
        #expect(lines.count == 1)
        #expect(lines[0]["date"] == .string("2026-10-03"))
        #expect(four(lines[0]) == (500, 200, 30, 2))
        // 一天的账（增量）的费用：(500-200)×0.15 + 200×0.016 + 30×0.47 = 62.3（每百万 token 价 ÷ 1000000）
        #expect(almostEqual(lines[0]["cost"]!.double!, 6.23e-05, places: 7))

        // 10 月 4 日新记的账记在 10 月 4 日
        ledger.update(["prompt": 2200, "cached": 1000, "completion": 140, "requests": 10])
        let today2 = ledger.today()
        #expect(today2["date"] == .string("2026-10-04"))
        #expect(four(today2) == (700, 400, 60, 5))
    }

    @Test func test_empty_day_writes_no_history() {
        // 全为 0 的一天不写历史行。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger(ts: LATE_NIGHT)
        ledger.update(TOTALS)  // 只记基线，账还是 0
        h.clock.ts = MIDNIGHT
        #expect(four(ledger.today()) == (0, 0, 0, 0))
        #expect(!FileManager.default.fileExists(atPath: h.dir + "/usage-history.jsonl"))
    }
}

@Suite struct TestSaveFile {
    @Test func test_write_at_once_when_file_exists() {
        // 已经有账了：满 10 秒后的第一次读会写文件。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger(interval: 10.0)
        ledger.update(TOTALS)
        ledger.update(BIGGER)  // 满 10 秒后的第一次读
        h.clock.ts += 10.0
        ledger.update(BIGGER)
        #expect(ledger.today()["date"] == .string("2026-10-03"))
    }

    @Test func test_write_throttling() {
        // 写文件最多每 save_interval_s 秒一次；flush 立刻写。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger(interval: 10.0)
        ledger.update(TOTALS)
        #expect(h.readUsage()["last_totals"] == TOTALS)  // 第一次立刻写

        h.clock.ts += 5.0
        ledger.update(BIGGER)  // 5 秒：还到不了写文件的点
        #expect(h.readUsage()["last_totals"] == TOTALS)

        h.clock.ts += 5.0  // 满 10 秒
        ledger.update(SMALLER)
        #expect(h.readUsage()["last_totals"] == SMALLER)

        h.clock.ts += 1.0
        ledger.update(BIGGER)  // 距上次写才 1 秒：不写
        #expect(h.readUsage()["last_totals"] == SMALLER)

        ledger.flush()  // flush 不受间隔限制
        #expect(h.readUsage()["last_totals"] == BIGGER)
    }

    @Test func test_no_change_does_not_rewrite() {
        // 累计值没有变化时不重写文件。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger(interval: 10.0)
        ledger.update(TOTALS)
        let path = h.dir + "/usage.json"
        let stamp = mtime(path)

        h.clock.ts += 20.0
        ledger.update(TOTALS)  // 和上次一样：没有变化
        #expect(mtime(path) == stamp)

        h.clock.ts += 20.0
        ledger.update(BIGGER)  // 有变化：到点了就写
        #expect(mtime(path) != stamp)
    }

    @Test func test_creates_missing_state_dir() {
        // state_dir 是不存在的多级目录：第一次写时建出来。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let stateDir = h.dir + "/a/b/c"
        let ledger = h.ledger(stateDir: stateDir)
        ledger.update(TOTALS)
        #expect(FileManager.default.fileExists(atPath: stateDir + "/usage.json"))
    }

    @Test func test_unwritable_state_dir() {
        // state_dir 不可写：读和写都不抛异常。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let blocked = h.dir + "/file.txt"
        try! Data("不是目录\n".utf8).write(to: URL(fileURLWithPath: blocked))
        let ledger = h.ledger(stateDir: blocked + "/sub")
        ledger.update(TOTALS)
        ledger.update(BIGGER)
        #expect(four(ledger.today()) == (500, 200, 30, 2))
        ledger.flush()
    }
}

@Suite struct TestBadFile {
    @Test func test_unusable_file() {
        // 坏 JSON、不是对象、缺字段：都当没有这个文件，从空账开始。
        for text in ["{坏", "[1]",
                     "{\"date\": \"2026-10-03\", \"prompt_tokens\": 10, \"requests\": 2}",
                     "{}"] {
            let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
            h.writeUsage(text)
            let ledger = h.ledger()
            ledger.update(TOTALS)  // 按第一次运行处理：只记基线
            #expect(four(ledger.today()) == (0, 0, 0, 0), "text=\(text)")
            ledger.update(BIGGER)
            #expect(four(ledger.today()) == (500, 200, 30, 2), "text=\(text)")
        }
    }

    @Test func test_update_ignores_bad_totals() {
        // 缺键、值不是整数、传 None：整次忽略。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(TOTALS)
        let bad: [JSON] = [
            .null,
            [:],
            ["prompt": 1],
            ["prompt": "1", "cached": 0, "completion": 0, "requests": 0],
            ["prompt": true, "cached": 0, "completion": 0, "requests": 0],
        ]
        for b in bad {
            ledger.update(b)
        }
        #expect(four(ledger.today()) == (0, 0, 0, 0))
    }
}

@Suite struct TestTimezone {
    @Test func test_unknown_timezone_falls_back() {
        // 时区名无效时按太平洋时间算日期（和 UTC 差一天，能看出来）。
        var cfg = pricedConfig(); cfg.timezone = "不存在/时区"
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger(ts: EVENING, config: cfg)
        #expect(ledger.today()["date"] == .string("2026-10-03"))
    }

    @Test func test_config_timezone_is_used() {
        // 同一个时刻，按 UTC 算是 10 月 4 日。
        var cfg = pricedConfig(); cfg.timezone = "UTC"
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger(ts: EVENING, config: cfg)
        #expect(ledger.today()["date"] == .string("2026-10-04"))
    }
}

@Suite struct TestEpoch {
    // 引擎启动标记：vLLM 的 epoch 变了就把整个累计值算作增量。

    @Test func test_第一次读只记基线并写下标记() {
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["epoch": .double(1000.0)]))
        #expect(four(ledger.today()) == (0, 0, 0, 0))
        let saved = h.readUsage()
        #expect(saved["last_epoch"] == .double(1000.0))
        #expect(saved["last_totals"] == TOTALS, "存的就是四个累计值")
        #expect(Set(saved["last_totals"]!.object!.keys) == Set(["prompt", "cached", "completion", "requests"]))
    }

    @Test func test_同一个标记算差值() {
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["epoch": .double(1000.0)]))
        ledger.update(plus(BIGGER, ["epoch": .double(1000.0)]))
        #expect(four(ledger.today()) == (500, 200, 30, 2))
    }

    @Test func test_标记变了算整个() {
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["epoch": .double(TODAY_EPOCH)]))
        ledger.update(plus(BIGGER, ["epoch": .double(TODAY_EPOCH + 1800)]))
        #expect(four(ledger.today()) == (1500, 600, 80, 5),
                "换了引擎或重启了，且启动时刻在今天：这次的累计值整个算增量")
    }

    @Test func test_有标记变没标记只记基线() {
        // 新引擎没有启动时刻：分不清整份累计值里有多少是今天的，只当新基线。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["epoch": .double(TODAY_EPOCH)]))
        ledger.update(BIGGER)
        #expect(four(ledger.today()) == (0, 0, 0, 0))
        ledger.flush()
        #expect(h.readUsage()["last_epoch"] == nil, "没有标记就不写这个键")
    }

    @Test func test_没标记变有标记算整个() {
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(TOTALS)
        ledger.update(plus(BIGGER, ["epoch": .double(TODAY_EPOCH)]))
        #expect(four(ledger.today()) == (1500, 600, 80, 5))
    }

    @Test func test_两边都没标记算差值() {
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(TOTALS)
        ledger.update(BIGGER)
        #expect(four(ledger.today()) == (500, 200, 30, 2))
        #expect(h.readUsage()["last_epoch"] == nil, "只用 TensorFold 时文件内容和以前一样")
    }

    @Test func test_重新加载后接着算差值() {
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["epoch": .double(1000.0)]))
        ledger.flush()
        let second = h.ledger()
        second.update(plus(BIGGER, ["epoch": .double(1000.0)]))
        #expect(four(second.today()) == (500, 200, 30, 2))
    }

    @Test func test_标记不是数字按没有标记() {
        for bad: JSON in [.string("x"), .bool(true)] {
            let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
            let ledger = h.ledger()
            ledger.update(TOTALS)
            ledger.update(plus(BIGGER, ["epoch": bad]))
            #expect(four(ledger.today()) == (500, 200, 30, 2), "bad=\(bad)")
        }
    }
}

// MARK: - 按模型记账（O2）

@Suite struct TestByModel {
    @Test func test_按模型分开记() {
        // 每个模型分开记，今天的合计是各模型相加。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        // 第一次读只记基线
        ledger.update(plus(TOTALS, ["by_model": ["A": bm(0, 0, 0, 0), "B": bm(0, 0, 0, 0)]]))
        #expect(four(ledger.today()) == (0, 0, 0, 0))
        let next: JSON = ["prompt": 1150, "cached": 430, "completion": 65, "requests": 7]
        ledger.update(plus(next, ["by_model": ["A": bm(100, 10, 5, 1), "B": bm(50, 20, 10, 3)]]))
        let today = ledger.today()
        #expect(today["by_model"]?["A"]?["prompt_tokens"] == .int(100))
        #expect(today["by_model"]?["B"]?["prompt_tokens"] == .int(50))
        #expect(today["prompt_tokens"] == .int(150), "合计是各模型相加")
    }

    @Test func test_只算填了单价的模型() {
        // 用量同上一个测试，只给 A 填单价：费用只算 A，B 单独数出来。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        var cfg = Config()
        cfg.prices["A"] = ModelPrice(input: 0.15, cached: 0.016, output: 0.47)
        let ledger = h.ledger(config: cfg)
        ledger.update(plus(TOTALS, ["by_model": ["A": bm(0, 0, 0, 0), "B": bm(0, 0, 0, 0)]]))
        let next: JSON = ["prompt": 1150, "cached": 430, "completion": 65, "requests": 7]
        ledger.update(plus(next, ["by_model": ["A": bm(100, 10, 5, 1), "B": bm(50, 20, 10, 3)]]))
        let today = ledger.today()
        #expect(today["priced_models"] == .int(1))
        #expect(today["unpriced_models"] == .int(1))
        #expect(today["by_model"]?["B"]?["cost"] == .null, "没填单价的模型 cost 是 null")
        // A 的费用：((100−10)×0.15 + 10×0.016 + 5×0.47) ÷ 1_000_000
        let aCost = ((100.0 - 10) * 0.15 + 10 * 0.016 + 5 * 0.47) / 1_000_000
        #expect(almostEqual(today["cost"]!.double!, aCost, places: 9), "今日费用只算填了单价的模型")
    }

    @Test func test_按模型的和对不上时记在当前模型名下() {
        // 合计 prompt 增加 100，各模型加起来只有 60：整个 100 记在 model 给的 C 名下。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["by_model": ["A": bm(0, 0, 0, 0), "B": bm(0, 0, 0, 0)],
                                    "model": .string("C")]))
        let next = plus(TOTALS, ["prompt": .int(1100)])
        ledger.update(plus(next, ["by_model": ["A": bm(60, 0, 0, 0), "B": bm(0, 0, 0, 0)],
                                  "model": .string("C")]))
        let today = ledger.today()
        #expect(today["by_model"]?["C"]?["prompt_tokens"] == .int(100))
        #expect(today["prompt_tokens"] == .int(100))
    }

    @Test func test_没有按模型的累计值时记在当前模型名下() {
        // 不带 by_model、带 model：增量全记在那个模型名下。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["model": .string("D")]))
        ledger.update(plus(BIGGER, ["model": .string("D")]))
        var today = ledger.today()
        #expect(today["by_model"]?["D"]?["prompt_tokens"] == .int(500))
        #expect(today["by_model"]?["D"]?["requests"] == .int(2))
        // 既不带 by_model 也不带 model：记在 "" 名下（另一个临时目录，新账本）。
        let h2 = Harness(); defer { try? FileManager.default.removeItem(atPath: h2.dir) }
        let ledger2 = h2.ledger()
        ledger2.update(TOTALS)
        ledger2.update(BIGGER)
        today = ledger2.today()
        #expect(today["by_model"]?[""]?["prompt_tokens"] == .int(500))
        #expect(today["by_model"]?[""]?["requests"] == .int(2))
    }

    @Test func test_读第1版的文件() {
        // 第 1 版的文件只有四项合计：有用量时记在 "" 名下。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        h.writeUsage("""
        {"version": 1, "date": "2026-10-03", "prompt_tokens": 1000, "cached_tokens": 0, \
        "completion_tokens": 0, "requests": 0, \
        "last_totals": {"prompt": 0, "cached": 0, "completion": 0, "requests": 0}}
        """)
        let ledger = h.ledger()
        let today = ledger.today()
        #expect(today["by_model"]?[""]?["prompt_tokens"] == .int(1000))
        #expect(today["prompt_tokens"] == .int(1000))
    }

    @Test func test_程序重启后按模型接着算() {
        // 新账本从文件里的 by_model、last_by_model 接着算。
        let dir = newTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = Clock(NOON)
        let first = UsageLedger(config: pricedConfig(), clock: { clock.ts }, stateDir: dir)
        first.update(plus(TOTALS, ["by_model": ["A": bm(600, 200, 20, 1), "B": bm(400, 200, 30, 2)]]))
        let r2: JSON = ["prompt": 1200, "cached": 500, "completion": 70, "requests": 6]
        first.update(plus(r2, ["by_model": ["A": bm(800, 300, 40, 3), "B": bm(400, 200, 30, 3)]]))
        first.flush()
        #expect(first.today()["by_model"]?["A"]?["prompt_tokens"] == .int(200))
        #expect(first.today()["by_model"]?["B"]?["requests"] == .int(1))

        let second = UsageLedger(config: pricedConfig(), clock: { clock.ts }, stateDir: dir)
        let r3 = plus(r2, ["prompt": .int(1210)])
        second.update(plus(r3, ["by_model": ["A": bm(810, 300, 40, 3), "B": bm(400, 200, 30, 3)]]))
        let today = second.today()
        #expect(today["by_model"]?["A"]?["prompt_tokens"] == .int(210), "A 比重启前多 10")
        #expect(today["by_model"]?["B"]?["requests"] == .int(1), "B 不变")
        #expect(today["by_model"]?["B"]?["prompt_tokens"] == .int(0))

        let saved = JSON.parse(try! Data(contentsOf: URL(fileURLWithPath: dir + "/usage.json")))!
        #expect(saved["version"] == .int(2))
        #expect(saved["by_model"]?.object != nil)
        #expect(saved["last_by_model"]?.object != nil)
    }

    @Test func test_换日时历史行带各模型明细() {
        // 换日那一行：合计 + 有单价的模型的费用之和 + 各模型明细（含各自 cost 或 null）。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        var cfg = Config()
        cfg.prices["A"] = ModelPrice(input: 0.15, cached: 0.016, output: 0.47)
        let ledger = h.ledger(ts: LATE_NIGHT, config: cfg)
        ledger.update(plus(TOTALS, ["by_model": ["A": bm(0, 0, 0, 0), "B": bm(0, 0, 0, 0)]]))
        ledger.update(plus(BIGGER, ["by_model": ["A": bm(300, 100, 20, 1), "B": bm(200, 100, 10, 1)]]))

        h.clock.ts = MIDNIGHT
        #expect(ledger.today()["date"] == .string("2026-10-04"))
        let lines = readHistory(h.dir)
        #expect(lines.count == 1)
        let row = lines[0]
        #expect(row["date"] == .string("2026-10-03"))
        #expect(row["prompt_tokens"] == .int(500), "前五项是合计")
        #expect(row["by_model"]?["A"]?["cost"]?.number != nil, "填了单价的模型 cost 是数")
        #expect(row["by_model"]?["B"]?["cost"] == .null, "没填单价的模型 cost 是 null")
        // 这行的 cost 等于 A 的费用：((300−100)×0.15 + 100×0.016 + 20×0.47) ÷ 1_000_000
        let aCost = ((300.0 - 100) * 0.15 + 100 * 0.016 + 20 * 0.47) / 1_000_000
        #expect(almostEqual(row["cost"]!.double!, aCost, places: 9))
    }

    @Test func test_改单价和时区立刻生效() {
        // apply(config:)：换单价立刻重算今天；换时区后下一次换日检查按新时区处理。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger(ts: EVENING)   // 太平洋时间 2026-10-03，UTC 已是 2026-10-04
        ledger.update(plus(TOTALS, ["by_model": ["A": bm(0, 0, 0, 0)]]))
        let r2: JSON = ["prompt": 1200, "cached": 500, "completion": 70, "requests": 5]
        ledger.update(plus(r2, ["by_model": ["A": bm(200, 100, 20, 2)]]))
        #expect(ledger.today()["cost"] == .double(0.0), "没填单价时今日费用是 0")

        var cfg = Config()
        cfg.prices["A"] = ModelPrice(input: 0.15, cached: 0.016, output: 0.47)
        ledger.apply(config: cfg)
        // A 的费用：((200−100)×0.15 + 100×0.016 + 20×0.47) ÷ 1_000_000
        let aCost = ((200.0 - 100) * 0.15 + 100 * 0.016 + 20 * 0.47) / 1_000_000
        #expect(almostEqual(ledger.today()["cost"]!.double!, aCost, places: 9), "填上单价后立刻重算")

        cfg.timezone = "UTC"
        ledger.apply(config: cfg)
        let today = ledger.today()
        #expect(today["date"] == .string("2026-10-04"), "换到新时区已是第二天")
        #expect(today["prompt_tokens"] == .int(0), "换日后清零")
        let lines = readHistory(h.dir)
        #expect(lines.count == 1)
        #expect(lines[0]["date"] == .string("2026-10-03"))
    }

    @Test func test_启动标记差30秒以内算同一次启动() {
        // oMLX 的启动时刻是算出来的，重启后差一两秒：30 秒以内不算换引擎。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["epoch": .double(TODAY_EPOCH)]))   // 第一次：只记基线
        ledger.update(plus(BIGGER, ["epoch": .double(TODAY_EPOCH + 1)]))   // 差 1 秒：按差值记
        #expect(four(ledger.today()) == (500, 200, 30, 2))
        let r3: JSON = ["prompt": 1600, "cached": 700, "completion": 90, "requests": 6]
        ledger.update(plus(r3, ["epoch": .double(TODAY_EPOCH + 99)]))       // 差 99 秒，仍在今天：整个算
        #expect(four(ledger.today()) == (500 + 1600, 200 + 700, 30 + 90, 2 + 6))
    }

    @Test func test_启动标记变了但引擎昨天启动时只记基线() {
        // 换了引擎，但新引擎的启动时刻不在今天：整份累计值含前几天的用量，只当新基线。
        let h = Harness(); defer { try? FileManager.default.removeItem(atPath: h.dir) }
        let ledger = h.ledger()
        ledger.update(plus(TOTALS, ["epoch": .double(OLD_EPOCH - 1800)]))
        ledger.update(plus(BIGGER, ["epoch": .double(OLD_EPOCH)]))
        #expect(four(ledger.today()) == (0, 0, 0, 0))
        ledger.update(plus(["prompt": 1600, "cached": 700, "completion": 90, "requests": 6],
                           ["epoch": .double(OLD_EPOCH)]))
        #expect(four(ledger.today()) == (100, 100, 10, 1))
    }
}
