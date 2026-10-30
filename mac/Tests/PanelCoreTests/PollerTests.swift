// 轮询：间隔规则、内存每秒一次、引擎提示、perform、后台线程。
import Foundation
import Testing
@testable import PanelCore

/// 假单调时钟
private final class FakeClock {
    var t: Double = 0
}

/// 假引擎读取：按队列回放读数，每次 read 让时钟前进 advance
private final class FakeSource: EngineSource {
    var issue: EngineIssue = .none
    var modelIDs: [String] = []
    var modelName: String?
    var reads = 0
    var advance = 0.0
    var queue: [(health: JSON, metrics: JSON)?] = []
    var log: [String] = []
    let clk: FakeClock

    init(clock: FakeClock) { clk = clock }

    func read(now: Double, wall: Double) -> (health: JSON, metrics: JSON)? {
        reads += 1
        log.append("read")
        clk.t += advance
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// 记录内存读了几次
private final class MemorySpy {
    var calls = 0
    func read() -> JSON? {
        calls += 1
        return ["used_gb": 10.0, "total_gb": 48.0]
    }
}

/// 数回调次数（跨线程）
private final class Counter {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// 按行读 fixtures/omlx/short.expected.jsonl
private func shortLines() -> [JSON] {
    let url = fixturesDir.appendingPathComponent("omlx/short.expected.jsonl")
    let text = try! String(contentsOf: url, encoding: .utf8)
    return text.components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { JSON.parse(Data($0.utf8))! }
}

/// 一行读数 → read 的返回值
private func rowOf(_ line: JSON) -> (health: JSON, metrics: JSON)? {
    return (line["health"]!, line["metrics"]!)
}

@Suite struct TestPoller {
    /// 造一组对象：假时钟、假读取、假内存（t 为这一拍的起始时刻）
    private func makePair(lines: [JSON], t: Double? = nil, advance: Double = 0.0,
                          issue: EngineIssue = .none, model: String? = nil)
        -> (Poller, FakeSource, FakeClock, MemorySpy) {
        let clk = FakeClock()
        let src = FakeSource(clock: clk)
        src.queue = lines.map { rowOf($0) }
        src.advance = advance
        src.issue = issue
        src.modelName = model
        let spy = MemorySpy()
        let poller = Poller(source: src, collector: Collector(config: Config()),
                            readMemory: { spy.read() }, clock: { clk.t }, wallClock: { 0 })
        if let t { clk.t = t }
        return (poller, src, clk, spy)
    }

    @Test func test_空闲间隔是0点25() {
        let lines = shortLines()
        let (poller, _, _, _) = makePair(lines: [lines[0]], t: lines[0]["t"]!.number!)
        let (snap, wait) = poller.tick()
        let state = snap["state"]?.string
        #expect(state != "offline")
        #expect(state != "prefill" && state != "decode")   // 不忙
        let lanes = snap["lanes"] ?? .object([:])
        #expect(lanes["decoding"]?.int == 0)
        #expect(lanes["prefilling"]?.int == 0)
        #expect(lanes["waiting"]?.int == 0)
        #expect(wait == 0.25)
    }

    @Test func test_忙时间隔是0点1() {
        let lines = Array(shortLines().prefix(5))
        let (poller, _, clk, _) = makePair(lines: lines)
        var wait = 0.0
        for line in lines {
            clk.t = line["t"]!.number!
            wait = poller.tick().wait
        }
        #expect(lines[4]["t"]?.number == 1.062)
        #expect(lines[4]["health"]!["streams"]!["prefilling"]?.int == 1)
        #expect(wait == 0.1)
    }

    @Test func test_离线间隔是0点5() {
        let (poller, _, clk, _) = makePair(lines: [])
        var snap: JSON = .null
        var wait = 0.0
        for _ in 0..<10 {
            let r = poller.tick()
            snap = r.snapshot
            wait = r.wait
            if snap["state"]?.string == "offline" { break }
            clk.t += 0.5
        }
        #expect(snap["state"]?.string == "offline")
        #expect(wait == 0.5)
    }

    @Test func test_扣掉读取花的时间() {
        let lines = shortLines()
        // 第 1 行：读花 0.04 秒 → 0.25 - 0.04
        let (p1, _, _, _) = makePair(lines: [lines[0]], t: lines[0]["t"]!.number!, advance: 0.04)
        let r1 = p1.tick()
        #expect(abs(r1.wait - 0.21) < 1e-9)
        // 第 2 行：读花 1.0 秒 → 兜到 0.01
        let (p2, _, _, _) = makePair(lines: [lines[1]], t: lines[1]["t"]!.number!, advance: 1.0)
        let r2 = p2.tick()
        #expect(r2.wait == 0.01)
    }

    @Test func test_内存每秒读一次() {
        let lines = Array(shortLines().prefix(9))
        let (poller, _, clk, spy) = makePair(lines: lines)
        var snap: JSON = .null
        for i in 0..<9 {
            clk.t = Double(i) * 0.25          // 0, 0.25, ..., 2.0
            snap = poller.tick().snapshot
        }
        #expect(spy.calls == 3)
        #expect(snap["memory"]?["used_gb"]?.number == 10.0)
    }

    @Test func test_引擎提示() {
        // needsKey
        let (p1, src1, clk1, _) = makePair(lines: [], issue: .needsKey)
        src1.issue = .needsKey
        let s1 = tickToOffline(p1, clk1)
        #expect(s1["engine_note"] == .string("oMLX 需要 API key · 在设置里填写"))
        // notOmlx
        let (p2, src2, clk2, _) = makePair(lines: [], issue: .notOmlx)
        src2.issue = .notOmlx
        let s2 = tickToOffline(p2, clk2)
        #expect(s2["engine_note"] == .string("这个地址上不是 oMLX"))
        // unreachable：没有这个键
        let (p3, src3, clk3, _) = makePair(lines: [], issue: .unreachable)
        src3.issue = .unreachable
        let s3 = tickToOffline(p3, clk3)
        #expect(s3["engine_note"] == nil)
    }

    /// 一直 tick 到离线（每拍时钟加 0.5，最多 10 拍）
    private func tickToOffline(_ poller: Poller, _ clk: FakeClock) -> JSON {
        var snap: JSON = .null
        for _ in 0..<10 {
            snap = poller.tick().snapshot
            if snap["state"]?.string == "offline" { break }
            clk.t += 0.5
        }
        return snap
    }

    @Test func test_模型名交给采集器() {
        let lines = shortLines()
        let (poller, _, _, _) = makePair(lines: [lines[0]], t: lines[0]["t"]!.number!,
                                         model: "mlx-community--X-4bit")
        let (snap, _) = poller.tick()
        #expect(snap["model"] == .string("mlx-community--X-4bit"))
    }

    @Test func test_perform在下一拍开头执行() {
        let lines = shortLines()
        let (poller, src, _, _) = makePair(lines: [lines[0]], t: lines[0]["t"]!.number!)
        poller.perform { src.log.append("a") }
        poller.perform { src.log.append("b") }
        #expect(src.log == [])
        _ = poller.tick()
        #expect(src.log == ["a", "b", "read"])
        _ = poller.tick()
        #expect(src.log == ["a", "b", "read", "read"])   // 动作只执行一次
    }

    @Test func test_换读取() {
        let lines = shortLines()
        let clk = FakeClock()
        clk.t = lines[0]["t"]!.number!
        let first = FakeSource(clock: clk)
        let second = FakeSource(clock: clk)
        second.queue = [rowOf(lines[0])]
        let spy = MemorySpy()
        let poller = Poller(source: first, collector: Collector(config: Config()),
                            readMemory: { spy.read() }, clock: { clk.t }, wallClock: { 0 })
        poller.perform { poller.source = second }
        _ = poller.tick()
        #expect(second.reads == 1)
        #expect(first.reads == 0)
    }

    @Test func test_后台线程() {
        let clk = FakeClock()
        let src = FakeSource(clock: clk)          // queue 为空
        let spy = MemorySpy()
        let poller = Poller(source: src, collector: Collector(config: Config()),
                            readMemory: { spy.read() })   // 真时钟
        let counter = Counter()
        poller.start { _ in counter.bump() }
        Thread.sleep(forTimeInterval: 1.2)
        poller.stop()
        let n = counter.value
        #expect(n >= 2)
        Thread.sleep(forTimeInterval: 0.6)
        #expect(counter.value == n)               // 停了以后不再回调
    }
}
