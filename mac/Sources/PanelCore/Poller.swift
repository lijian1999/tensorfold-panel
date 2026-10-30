// 轮询：读引擎、读内存、喂采集器、算下一拍的间隔。
// 对应 panel/poller.py 的 Poller.tick；读哪些接口、多久读一次模型列表都由 OmlxReader 自己管。
import Foundation

/// 引擎读取：OmlxReader 满足它；测试里换成假的
public protocol EngineSource: AnyObject {
    var issue: EngineIssue { get }
    var modelIDs: [String] { get }
    var modelName: String? { get }
    func read(now: Double, wall: Double) -> (health: JSON, metrics: JSON)?
}

extension OmlxReader: EngineSource {}

/// 对应 Python 的 _lanes_sum：三个流指示点数加起来（不是字典、缺键、不是数都按 0，取整用 Int(x)）。
private func lanesSum(_ snapshot: JSON) -> Int {
    guard let snap = snapshot.object else { return 0 }
    let lanes = (snap["lanes"]?.truthy ?? false) ? (snap["lanes"]?.object ?? [:]) : [:]
    func num(_ value: JSON?) -> Int {
        guard let v = value, let n = v.number else { return 0 }   // bool、缺键、非数都算 0
        return Int(n)
    }
    return num(lanes["decoding"]) + num(lanes["prefilling"]) + num(lanes["waiting"])
}

/// 对应 Python 的 _is_busy：状态是 prefill/decode，或三个流指示数之和大于 0。
private func isBusy(_ snapshot: JSON) -> Bool {
    guard let snap = snapshot.object else { return false }
    if let s = snap["state"]?.string, s == "prefill" || s == "decode" { return true }
    return lanesSum(snapshot) > 0
}

/// 决定每一拍读什么、喂给采集器、算出下一拍的间隔。
public final class Poller: @unchecked Sendable {
    public var source: EngineSource
    private let collector: Collector
    private let readMemory: () -> JSON?
    private let clock: () -> Double
    private let wallClock: () -> Double

    private var memoryAt: Double?        // 上次读内存的时刻
    private var lastSnapshot: JSON?      // 上一次的快照（采集器坏了时沿用）

    private let lock = NSLock()
    private var pending: [() -> Void] = []
    private var stopped = false
    private var started = false
    private var onSnapshot: ((JSON) -> Void)?
    private let finished = DispatchSemaphore(value: 0)

    public init(source: EngineSource, collector: Collector,
                readMemory: @escaping () -> JSON? = readSystemMemory,
                clock: @escaping () -> Double = monotonicNow,
                wallClock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.source = source
        self.collector = collector
        self.readMemory = readMemory
        self.clock = clock
        self.wallClock = wallClock
    }

    /// 做一次读取，返回（快照，距下一次读取的秒数）。
    public func tick() -> (snapshot: JSON, wait: Double) {
        // 1. 先执行交来的动作（换读取等），按交来的顺序
        lock.lock()
        let actions = pending
        pending = []
        lock.unlock()
        for a in actions { a() }

        let now = clock()
        let wall = wallClock()

        // 2~3. 读引擎：读到了就是 health、metrics
        let r = source.read(now: now, wall: wall)
        let health = r?.health
        let metrics = r?.metrics

        // 4. 内存：从没读过、或距上次满 1 秒才读
        var memory: JSON? = nil
        if let at = memoryAt {
            if now - at >= 1.0 {
                memoryAt = now
                memory = readMemory()
            }
        } else {
            memoryAt = now
            memory = readMemory()
        }

        // 5. 喂给采集器
        var snapshot = collector.feed(now: now, health: health, metrics: metrics,
                                      memory: memory, model: source.modelName)

        // 6. 采集器坏了：沿用上一次，没有就用离线，间隔固定 0.5
        var interval: Double
        if snapshot.object == nil {
            snapshot = lastSnapshot ?? .object(["state": .string("offline")])
            interval = 0.5
        } else {
            // 7. 引擎有问题时带上一句话
            let issue = source.issue
            if issue == .notOmlx || issue == .needsKey, let msg = issue.message {
                var o = snapshot.object ?? [:]
                o["engine_note"] = .string(msg)
                snapshot = .object(o)
            }
            // 8. 间隔
            if isBusy(snapshot) {
                interval = 0.1
            } else if snapshot["state"]?.string == "offline" {
                interval = 0.5
            } else {
                interval = 0.25
            }
        }

        // 9. 记下快照，扣掉这次读取花掉的时间
        lastSnapshot = snapshot
        return (snapshot, max(0.01, interval - (clock() - now)))
    }

    /// 交给轮询线程：下一次 tick 开头按交来的顺序执行。
    public func perform(_ action: @escaping () -> Void) { lock.lock(); pending.append(action); lock.unlock() }

    /// 起后台线程：tick → onSnapshot（在后台线程上调）→ 等 wait 秒，循环。
    public func start(onSnapshot: @escaping (JSON) -> Void) {
        lock.lock()
        started = true
        self.onSnapshot = onSnapshot
        lock.unlock()
        let thread = Thread { [self] in
            while true {
                lock.lock(); let s = stopped; lock.unlock()
                if s { break }
                let (snapshot, wait) = tick()
                self.onSnapshot?(snapshot)
                // 分小段睡，stop 之后最多 0.05 秒就能退出
                var left = wait
                while left > 0 {
                    lock.lock(); let s2 = stopped; lock.unlock()
                    if s2 { break }
                    Thread.sleep(forTimeInterval: min(left, 0.05))
                    left -= 0.05
                }
            }
            finished.signal()
        }
        thread.start()
    }

    /// 让后台线程退出，最多等 1 秒；没 start 过时直接返回。
    public func stop() {
        lock.lock()
        stopped = true
        let was = started
        lock.unlock()
        guard was else { return }
        _ = finished.wait(timeout: .now() + 1)
    }
}
