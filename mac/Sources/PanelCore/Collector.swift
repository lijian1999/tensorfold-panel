// 采集：把 /health、/metrics、/proc/meminfo 的原始读数变成一份指标快照。
// Collector.feed 只做计算：不读时钟、不访问网络、不读写文件、不起线程。
// 同样的输入序列一定得到同样的输出，返回的字典每次都是新的。
//
// `hook` 字段照 2.3 判断：外报告知了每条流（tfpanel.v 是 1、streams 是列表）就是
// “好用”，这时现存输出、预填充进度和缓存命中、上下文占用都从外挂行里取；
// 不好用时走降级算法（现存输出取 0、进度和缓存命中读不到、上下文占用用占用比换算）。
import Foundation

/// 今日用量账本的接口（UsageLedger 实现它；测试里可以写一个假的）
public protocol UsageSink: AnyObject {
    func update(_ totals: JSON) throws
    func today() throws -> JSON
}

// 没有账本（或账本抛异常）时快照里的 today
private let NO_TODAY: JSON = [
    "date": "",
    "prompt_tokens": 0,
    "cached_tokens": 0,
    "completion_tokens": 0,
    "requests": 0,
    "cost": 0.0,
]

// 从没读到过内存读数时快照里的 memory
private let NO_MEMORY: JSON = ["used_gb": 0.0, "total_gb": 0.0]

private let DEFAULT_CONTEXT_MAX = 262144   // 上下文上限的兜底值
private let DEFAULT_LANES_MAX = 5          // 流数上限的兜底值
private let DEFAULT_PREFILL_TPS = 2300.0   // 平均预填充速度的初始值
private let SMOOTH_WINDOW_S = 10.0         // 解码采样的保留时长
private let SMOOTH_LAG_S = 2.5             // 解码速度的平滑滞后

/// 取一个读数；缺键、不是数字都按默认值处理。
private func _number(_ source: JSON, _ key: String, _ defaultValue: Double = 0) -> Double {
    guard let value = source[key], let n = value.number else { return defaultValue }
    return n
}

/// 同 _number，但保留原始 JSON 的数字类型（int / double），供需要保持输出类型的地方用。
private func _numberRaw(_ source: JSON, _ key: String, _ defaultValue: JSON) -> JSON {
    guard let value = source[key], value.number != nil else { return defaultValue }
    return value
}

/// 两个 JSON 数字相加，int + int 仍是 int（对应 Python 的 int 加法）。
private func _addNum(_ a: JSON, _ b: JSON) -> JSON {
    switch (a, b) {
    case let (.int(x), .int(y)): return .int(x + y)
    case let (.int(x), .double(y)): return .double(Double(x) + y)
    case let (.double(x), .int(y)): return .double(x + Double(y))
    default: return .double((a.number ?? 0) + (b.number ?? 0))
    }
}

/// 上一次成功读到 /health 时的那组数（下面简称“上次”）。
private struct _Prev {
    var t: Double
    var running: Int      // 上次的在跑数
    var arrive: Int       // 上次的到达计数
    var c: Int
    var requests: Int
    var prompt: Int
    var cached: Int
    var prefillS: Double
    var decodeS: Double
    var drafted: Int
    var accepted: Int
    var rows: [JSON]?     // 上次的外挂行（没有外挂时为 nil）
    var epoch: JSON?      // 上次的引擎启动标记（vLLM 才有）
    var aborted: Int      // 上次的中途断开累计数（vLLM 才有）
    var finishedC: Double?  // 上次的“已结束请求的输出 token 累计”（vLLM 才有）
}

/// 忙碌段（2.6）。
private struct _Busy {
    var start: Double
    var startC: Int
    var used: Int
    var first: Double?
    var peak: Int
}

/// 解码段（2.9）。
private struct _DecodeSeg {
    var start: Double
    var startC: Int
    var samples: [(Double, Int)]
    var peak: Double
}

/// 本轮（2.5/2.12）。
private struct _Round {
    var start: Double
    var startC: Int
    var done: Int
    var output: Int
    var decodeSum: Double
    var decodeLen: Double
    var concurrent: Bool
    var end: Double
    var lastPrompt: Int?
}

/// 2.7 的流表条目：开始时刻 + 预填充进度点。
private struct _StreamEntry {
    var start: Double
    var points: [(Double, Double)]
}

/// 采集器：每读到一次 /health 调一次 feed，吐出一份快照。
public final class Collector {
    private let config: Config
    private let usage: UsageSink?
    // 0. 沿用的输入
    private var _metrics: JSON?
    private var _memory: JSON?
    private var _model: String?
    private var _contextMax: Int = DEFAULT_CONTEXT_MAX
    private var _contextUsed: JSON = .int(0)
    private var _hook: String = "missing"
    private var _engine: String?        // 最近一次读数的 backend

    // 1. 读不到的处理
    private var _fails = 0
    private var _failStart: Double?
    private var _everOk = false
    private var _lastSnapshot: JSON?
    // 2. 正在跑的状态
    private var _prev: _Prev?           // 上次的读数
    private var _busy: _Busy?           // 忙碌段
    private var _decode: _DecodeSeg?    // 解码段
    private var _round: _Round?         // 本轮
    private var _last: [String: JSON]?  // 上一个结束的请求
    private var _doneAt: Double?        // 全部结束时刻
    private var _prefillStart: Double?  // 预填充起点（没有外挂时用）
    private var _stream: [(JSON, _StreamEntry)] = []  // 2.7 的流表：id -> {开始时刻, 进度点}
    private var _arriveAt: Double?      // 最近到达时刻
    private var _rows: [JSON]?          // 这次的外挂行（外挂失效时为 nil）
    private var _streamTps: [(JSON, Double)] = []     // 流表算出来的每条流的预填充速度
    private var _ttftPair: (Double, Double)?           // 上一组 (ttft_sum, ttft_count)
    private var _ttftPending = 0        // 等着用精确值替换的首字数
    /// 当前的平均预填充速度（滚动更新，只读）。
    public private(set) var prefillTps: Double = DEFAULT_PREFILL_TPS
    // 一次 feed 里几个段落共用的中间量
    private var _now = 0.0
    private var _c = 0
    private var _running = 0
    private var _dec = 0
    private var _pre = 0
    private var _lanesMax = DEFAULT_LANES_MAX

    public init(config: Config, usage: UsageSink? = nil) {
        self.config = config
        self.usage = usage
    }

    // 入口

    /// 吃一次读数，吐出一份快照。health 为 nil 表示这次读不到。
    public func feed(now: Double, health: JSON?, metrics: JSON? = nil, memory: JSON? = nil, model: String? = nil) -> JSON {
        _now = now
        if let metrics = metrics { _metrics = metrics }
        if let memory = memory { _memory = memory }
        if let model = model, !model.isEmpty { _model = model }
        let snap: JSON
        if health == nil {
            snap = _onFail(now)
        } else {
            snap = _onRead(now, health!)
        }
        _lastSnapshot = snap
        return snap
    }

    // 1. 读不到

    /// 读不到：头两次原样返回上一次的快照；第三次（或从来没成功过）进入离线。
    private func _onFail(_ now: Double) -> JSON {
        _fails += 1
        if _failStart == nil { _failStart = now }
        if _everOk && _fails < 3, let last = _lastSnapshot, var snap = last.object {
            snap["today"] = _today()
            return .object(snap)
        }
        _clearRunning()
        return _offlineSnapshot(now)
    }

    /// 清掉所有“正在跑”的状态。
    private func _clearRunning() {
        _busy = nil
        _decode = nil
        _round = nil
        _prev = nil
        _doneAt = nil
        _prefillStart = nil
        _stream = []
        _streamTps = []
        _arriveAt = nil
    }

    /// 离线快照：状态、离线秒数以外的东西沿用上一次。
    private func _offlineSnapshot(_ now: Double) -> JSON {
        let previous = _lastSnapshot ?? .object([:])
        var lanes: [String: JSON] = [:]
        if let l = previous["lanes"], l.truthy, let o = l.object { lanes = o }
        var snap = _blankSnapshot()
        snap["state"] = .string("offline")
        snap["hook"] = previous["hook"] ?? .string("missing")
        snap["lanes"] = .object([
            "max": lanes["max"] ?? .int(DEFAULT_LANES_MAX),
            "decoding": .int(0),
            "prefilling": .int(0),
            "waiting": .int(0),
        ])
        snap["decode"] = .null
        snap["prefill"] = .null
        snap["round"] = .null
        snap["context_used"] = _contextUsed
        snap["offline_s"] = .double(now - (_failStart ?? now))
        return .object(snap)
    }

    // 2. 读到了

    /// 一次成功读数：按 2.1 到 2.12 的顺序算完，最后拼快照。
    private func _onRead(_ now: Double, _ health: JSON) -> JSON {
        _fails = 0
        _failStart = nil
        _everOk = true

        if let backend = health["backend"]?.string, !backend.isEmpty {
            _engine = backend
        }

        let requests = Int(_number(health, "requests_total"))
        let c = Int(_number(health, "completion_tokens_total"))
        let prompt = Int(_number(health, "prompt_tokens_total"))
        let cached = Int(_number(health, "cached_tokens_total"))
        let prefillS = _number(health, "prefill_seconds_total", 0.0)
        let decodeS = _number(health, "decode_seconds_total", 0.0)
        let drafted = Int(_number(health, "drafted_total"))
        let accepted = Int(_number(health, "accepted_total"))
        let (running, dec, pre, lanesMax) = Self._streams(health)
        // vLLM 才有的三个可选键：取不到都当没有
        var epoch: JSON?
        if let raw = health["epoch"], raw.number != nil { epoch = raw }
        let aborted = Int(_number(health, "aborted_total"))
        var finishedC: Double?
        if let raw = health["completion_finished_total"], raw.number != nil { finishedC = raw.number }

        // 2.1 记账：把这次的累计值交给账本（账本自己算增量）；抛的异常一律吃掉
        // vLLM 的读数把四项累计值放在 usage_totals 里；带引擎启动标记时一并交给账本
        if let usage = usage {
            var forUsage: [String: JSON]
            if let totals = health["usage_totals"], totals.object != nil {
                forUsage = [:]
                for key in ["prompt", "cached", "completion", "requests"] {
                    forUsage[key] = totals[key] ?? .null
                }
            } else {
                forUsage = ["prompt": .int(prompt), "cached": .int(cached), "completion": .int(c), "requests": .int(requests)]
            }
            if let e = epoch { forUsage["epoch"] = e }
            // oMLX/vLLM 的读数把四项累计值按模型分开：一并交给账本
            if let byModel = health["usage_by_model"], byModel.object != nil {
                forUsage["by_model"] = byModel
            }
            // 采集器记着的当前模型名（最近一次非空的 model 参数）也交给账本，供账本兑底
            if let m = _model, !m.isEmpty { forUsage["model"] = .string(m) }
            try? usage.update(.object(forUsage))
        }

        if let contextLength = health["context_length"]?.number, contextLength > 0 {
            _contextMax = Int(contextLength)
        }
        // self._context_max = int(self._context_max)：Swift 里本来就是 Int，省去

        // 2.3 外挂：先定下这次有没有外挂行，后面几段都按它选算法
        _hook = Self._hookOf(health)
        _rows = _hookRows(health)
        _dec = dec
        _pre = pre
        _lanesMax = lanesMax

        var prev = _prev
        // 2.2 模型重启：累计值变小，或引擎换了个启动标记，这次当作没有上次
        var restart = false
        if let p = prev {
            restart = requests < p.requests || c < p.c
                || (p.epoch != nil && epoch != nil && epoch! != p.epoch!)
        }
        if restart {
            prev = nil
            _clearRunning()
            _ttftPair = nil
            _ttftPending = 0
        }

        _c = c
        _running = running

        // 2.4 请求结束
        var finished = 0
        if let p = prev {
            finished = requests - p.requests
            if finished >= 1 {
                _onFinish(now, p, finished, c, prompt, cached,
                          prefillS, decodeS, drafted, accepted, running, finishedC)
            }
        }

        // 2.5 请求到达（模型重启那次连到达也不记：重启那次读数不产生新一轮）
        let arrive = requests + Int(_number(health, "requests_running")) + aborted
        let arrived: Int
        if restart {
            arrived = 0
        } else if prev == nil {
            arrived = running
        } else {
            arrived = max(0, arrive - prev!.arrive)
        }
        if arrived >= 1 {
            _arriveAt = now
            _onArrive(now, prev, finished, c)
        }

        // 中途断开也算本轮的一次活动：本轮的最后活动时刻记成断开的这次
        if !restart, let p = prev, aborted > p.aborted, _round != nil {
            var rnd = _round!
            rnd.end = now
            _round = rnd
        }

        // 2.6 忙碌段
        _busySection(now, prev, finished, running, c)

        // 2.7 流表：只有外报告知了每条流才维护
        if running > 0 {
            _streamTable(now, _rows)
        }

        // 2.8 状态（含首个 token 时刻）
        let state = _stateOf(now, dec, running)
        _firstToken(now, dec, c)

        // 2.9 解码段
        let decode = _decodeSection(now, c, state)

        // 2.10 预填充段
        let prefill = _prefillSection(now, state, pre, running)

        // 2.11 首字的精确值
        _ttftExact()

        var snap = _buildSnapshot(state, decode, prefill, running)
        // 模型加载中（oMLX）：只有空闲/预填充时给出去的快照改成 loading 并带上 loading 内容；
        // 采集器内部记的状态（忙碌段、一轮、完成时刻等）照旧按原来的状态算。
        if (state == "idle" || state == "prefill"), let loading = health["loading"], loading.object != nil,
           var o = snap.object {
            o["state"] = .string("loading")
            o["loading"] = loading
            snap = .object(o)
        }
        _prev = _Prev(t: now, running: running, arrive: arrive, c: c, requests: requests,
                      prompt: prompt, cached: cached, prefillS: prefillS, decodeS: decodeS,
                      drafted: drafted, accepted: accepted, rows: _rows,
                      epoch: epoch, aborted: aborted, finishedC: finishedC)
        return snap
    }

    /// 2.3：tfpanel 是字典、v 是 1、streams 是列表才算外挂好用。
    private static func _hookOf(_ health: JSON) -> String {
        guard let tfpanel = health["tfpanel"], tfpanel.object != nil else { return "missing" }
        if tfpanel["v"] == .int(1) && tfpanel["streams"]?.array != nil {
            return "ok"
        }
        return "missing"
    }

    /// 取这次的外挂行；外挂不好用（包括有 tfpanel 但 streams 不是列表）时为 nil。
    private func _hookRows(_ health: JSON) -> [JSON]? {
        if _hook != "ok" { return nil }
        return health["tfpanel"]?["streams"]?.array?.filter { $0.object != nil }
    }

    /// 外挂行里指定阶段那些行的 output 之和；没有外挂行时为 0。
    private static func _rowsOutput(_ rows: [JSON]?, phase: String = "decode", ids: [JSON]? = nil) -> Int {
        guard let rows = rows, !rows.isEmpty else { return 0 }
        var total = 0
        for row in rows {
            guard row["phase"] == .string(phase) else { continue }
            if let ids = ids, !ids.contains(where: { $0 == (row["id"] ?? .null) }) { continue }
            total += Int(_number(row, "output", 0))
        }
        return total
    }

    /// 取在跑数、正在解码、正在预填充的流数和上限。
    /// 没有 `streams` 时当作 decoding = requests_running、prefilling = 0、max = 1。
    private static func _streams(_ health: JSON) -> (Int, Int, Int, Int) {
        let running = Int(_number(health, "requests_running"))
        if let streams = health["streams"], streams.object != nil {
            let dec = Int(_number(streams, "decoding"))
            let pre = Int(_number(streams, "prefilling"))
            let maximum = Int(_number(streams, "max", Double(DEFAULT_LANES_MAX)))
            return (max(running, dec + pre), dec, pre, maximum)
        }
        let dec = running
        let pre = 0
        let maximum = 1  // 没有 streams 时上限按 1 算
        return (max(running, dec + pre), dec, pre, maximum)
    }

    /// 2.4 请求结束：差值算成这个请求的成绩，并记进本轮。
    private func _onFinish(_ now: Double, _ prev: _Prev, _ finished: Int, _ c: Int, _ prompt: Int,
                           _ cached: Int, _ prefillS: Double, _ decodeS: Double, _ drafted: Int,
                           _ accepted: Int, _ running: Int, _ finishedC: Double?) {
        let survivors = prev.running - finished
        var busy = _busy
        // 现存输出：这次还在解码的外挂行已输出的 token 之和
        let existing = Self._rowsOutput(_rows)
        var completion = 0
        if let pc = prev.finishedC, let fc = finishedC {
            // vLLM 给了“已结束请求的输出 token 累计”：直接相减，不用估算
            completion = max(0, Int(fc - pc))
            if survivors > 0, busy != nil {
                busy!.used += completion
                _busy = busy
            }
        } else if survivors <= 0 {
            // 之前在跑的全结束了：从忙碌起点的 C 减出精确值
            if let b = busy {
                completion = c - b.startC - b.used - existing
            } else {
                completion = 0
            }
        } else {
            // 还有别的流在跑：只能估算，先拿上次的外挂行比出结束的几条
            var nowIds: [JSON] = []
            if let rows = _rows, !rows.isEmpty {
                nowIds = rows.map { $0["id"] ?? .null }
            }
            let gone = (prev.rows ?? []).filter { row in
                row["phase"] == .string("decode") && !nowIds.contains(where: { $0 == (row["id"] ?? .null) })
            }
            if gone.count == finished {
                completion = Self._rowsOutput(gone)
            } else {
                completion = c - prev.c
            }
            if busy != nil {
                busy!.used += completion
                _busy = busy
            }
        }
        if completion < 0 { completion = 0 }

        let deltaPrompt = prompt - prev.prompt
        let deltaCached = cached - prev.cached
        let deltaDecode = decodeS - prev.decodeS
        let deltaPrefill = prefillS - prev.prefillS
        let deltaDraft = drafted - prev.drafted
        let deltaAccept = accepted - prev.accepted
        let fresh = deltaPrompt - deltaCached

        var last: [String: JSON] = [:]
        last["prompt_tokens"] = .int(deltaPrompt)
        last["cached_tokens"] = .int(deltaCached)
        last["completion_tokens"] = .int(completion)
        last["decode_tps"] = JSON(deltaDecode > 0 ? Double(completion) / deltaDecode : nil)
        last["prefill_tps"] = JSON((fresh > 0 && deltaPrefill > 0) ? Double(fresh) / deltaPrefill : nil)
        last["ttft_s"] = JSON(_lastTTft(busy))
        last["acceptance_rate"] = JSON(deltaDraft > 0 ? Double(deltaAccept) / Double(deltaDraft) : nil)
        last["context_used"] = .int(deltaPrompt + completion)
        _last = last

        // 本轮：没有就先新开一轮，再把这个请求记进本轮
        var rnd: _Round
        if _round == nil {
            rnd = _newRound(now, c)
        } else {
            rnd = _round!
        }
        rnd.done += finished
        rnd.output += completion
        rnd.decodeSum += deltaDecode
        rnd.end = now
        rnd.lastPrompt = (finished == 1) ? deltaPrompt : nil
        _round = rnd

        // 平均预填充速度的滚动更新
        if finished == 1 && fresh >= 2048 && deltaPrefill > 0 {
            prefillTps = 0.7 * prefillTps + 0.3 * (Double(fresh) / deltaPrefill)
        }

        _ttftPending = finished
        if running == 0 {
            _doneAt = now
        }
    }

    /// 2.4 的 ttft_s：这一忙碌段只跑过一条流时，等于首个 token 时刻 − 忙碌起点时刻。
    private func _lastTTft(_ busy: _Busy?) -> Double? {
        guard let busy = busy, busy.peak == 1, let first = busy.first else { return nil }
        return first - busy.start
    }

    /// 新开一轮。
    private func _newRound(_ now: Double, _ startC: Int) -> _Round {
        _Round(start: now, startC: startC, done: 0, output: 0, decodeSum: 0.0, decodeLen: 0.0,
               concurrent: false, end: now, lastPrompt: nil)
    }

    /// 2.5 请求到达：隔得太久的新请求算新一轮。
    private func _onArrive(_ now: Double, _ prev: _Prev?, _ finished: Int, _ c: Int) {
        if _round == nil {
            _round = _newRound(now, prev == nil ? c : prev!.c)
            return
        }
        let survivors = (prev == nil) ? 0 : prev!.running - finished
        if survivors <= 0 && (now - _round!.end) > config.roundGapS {
            _round = _newRound(now, prev == nil ? c : prev!.c)
        }
    }

    /// 2.6 忙碌段：在跑数从 0 变正算开始，回到 0 算结束。
    private func _busySection(_ now: Double, _ prev: _Prev?, _ finished: Int, _ running: Int, _ c: Int) {
        if running <= 0 {
            _busy = nil
            _decode = nil
            _stream = []
            _streamTps = []
            return
        }
        let freshStart = prev == nil || (prev!.running - finished) <= 0
        if freshStart {
            let startC: Int
            if finished >= 1 {
                // 这一次读数里刚结束了请求：起点从这次的 C 减去还在跑的几条算
                startC = c - Self._rowsOutput(_rows)
            } else if prev == nil {
                startC = c
            } else {
                startC = prev!.c
            }
            _busy = _Busy(start: now, startC: startC, used: 0, first: nil, peak: 0)
        }
        var busy = _busy!
        busy.peak = max(busy.peak, running)
        _busy = busy
        if _round != nil && running >= 2 {
            var rnd = _round!
            rnd.concurrent = true
            _round = rnd
        }
    }

    /// 2.7 流表：按 id 记下每条流的开始时刻和预填充进度点，顺带算出每条流的预填充速度。
    /// 没有外挂行（外挂失效或这次一条都没有）时清空，下次重新记。
    private func _streamTable(_ now: Double, _ rows: [JSON]?) {
        guard let rows = rows, !rows.isEmpty else {
            _stream = []
            _streamTps = []
            return
        }
        var table: [(JSON, _StreamEntry)] = []
        var speeds: [(JSON, Double)] = []
        for row in rows {
            guard let sid = row["id"], !sid.isNull else { continue }
            let entry = _streamEntry(sid)
            let rowStart = row["start"]
            let hasStart = rowStart?.number != nil
            let start: Double
            var points: [(Double, Double)]
            if entry == nil {
                // 新出现的 id：行里有开始时刻就用它，否则按这次读到算
                if hasStart {
                    start = rowStart!.number!
                } else {
                    start = _arriveAt ?? now
                }
                points = []
                if row["phase"] == .string("prefill") {
                    points = [(now, _number(row, "filled", 0))]
                }
            } else {
                // 每次读数都按行里的开始时刻更新
                start = hasStart ? rowStart!.number! : entry!.start
                points = entry!.points
                if row["phase"] == .string("prefill") {
                    let filled = _number(row, "filled", 0)
                    if !points.isEmpty && filled > points[points.count - 1].1 {
                        points.append((now, filled))
                        if points.count > 4 { points.removeFirst(points.count - 4) }  // 只留最后 4 个
                    }
                }
            }
            Self._upsert(&table, sid, _StreamEntry(start: start, points: points))
            if points.count >= 2 && points[points.count - 1].0 > points[0].0 {
                let speed = (points[points.count - 1].1 - points[0].1) / (points[points.count - 1].0 - points[0].0)
                Self._upsert(&speeds, sid, speed)
            } else if points.count == 1, row["phase"] == .string("prefill"), now > start {
                // 只有第一个进度点（oMLX 每块才更新一次）：按“从到达算起的新 token 平均速度”先给一个值，
                // 免得进度条出现时速度一直是“—”。下一块到了再换成块间实测值。
                let fresh = points[0].1 - _number(row, "cached", 0)
                if fresh > 0 {
                    Self._upsert(&speeds, sid, fresh / (now - start))
                }
            }
        }
        _stream = table
        _streamTps = speeds
    }

    private func _streamEntry(_ sid: JSON) -> _StreamEntry? {
        for (k, v) in _stream where k == sid { return v }
        return nil
    }

    private func _streamTpsGet(_ sid: JSON) -> Double? {
        for (k, v) in _streamTps where k == sid { return v }
        return nil
    }

    private static func _upsert<V>(_ list: inout [(JSON, V)], _ key: JSON, _ value: V) {
        if let idx = list.firstIndex(where: { $0.0 == key }) {
            list[idx].1 = value
        } else {
            list.append((key, value))
        }
    }

    /// 2.8 状态。
    private func _stateOf(_ now: Double, _ dec: Int, _ running: Int) -> String {
        if dec > 0 { return "decode" }
        if running > 0 { return "prefill" }
        if let done = _doneAt, (now - done) < config.doneHoldS { return "done" }
        return "idle"
    }

    /// 2.8 首个 token 时刻。
    private func _firstToken(_ now: Double, _ dec: Int, _ c: Int) {
        guard var busy = _busy, busy.first == nil else { return }
        if dec > 0 || (c - busy.startC - busy.used) > 0 {
            busy.first = now
            _busy = busy
        }
    }

    /// 2.9 解码段：只有状态是 decode 时才有；离开解码状态就清掉，回来算新的一段。
    private func _decodeSection(_ now: Double, _ c: Int, _ state: String) -> JSON? {
        if state != "decode" {
            _decode = nil
            return nil
        }
        var seg: _DecodeSeg
        if let existing = _decode {
            seg = existing
            seg.samples.append((now, c))
            let cutoff = now - SMOOTH_WINDOW_S
            while let first = seg.samples.first, first.0 < cutoff {
                seg.samples.removeFirst()
            }
        } else {
            seg = _DecodeSeg(start: now, startC: c, samples: [(now, c)], peak: 0.0)
        }
        _decode = seg
        let busy = _busy
        let elapsed = now - seg.start
        if _prev != nil && _round != nil {
            var rnd = _round!
            rnd.decodeLen += min(now - _prev!.t, 1.0)
            _round = rnd
        }
        var reference: (Double, Int)?
        for point in seg.samples {
            if point.0 <= now - SMOOTH_LAG_S {
                reference = point
            }
        }
        let ref = reference ?? seg.samples[0]
        let tps = Double(c - ref.1) / max(0.5, now - ref.0)
        if elapsed > 1.0 {
            seg.peak = max(seg.peak, tps)
            _decode = seg
        }
        let tpsAvg: Double? = elapsed >= 0.5 ? Double(c - seg.startC) / elapsed : nil
        var ttft: Double?
        if let busy = busy, busy.peak == 1, let first = busy.first {
            ttft = first - busy.start
        }
        // vLLM：只有一条流时，行里直接给了这条流的首字时间
        if let rows = _rows, rows.count == 1, _running == 1 {
            if let value = rows[0]["ttft_s"]?.number {
                ttft = value
            }
        }
        let output: Int
        if _hook == "ok" {
            // 外挂好用：直接数解码中那几条已输出的 token
            output = Self._rowsOutput(_rows)
        } else if let busy = busy {
            output = max(0, c - busy.startC - busy.used)
        } else {
            output = 0
        }
        return [
            "tps": .double(tps),
            "tps_peak": .double(seg.peak),
            "tps_avg": JSON(tpsAvg),
            "output_tokens": .int(output),
            "ttft_s": JSON(ttft),
        ]
    }

    /// 2.10 预填充段：外挂好用时从外挂行取，失效时只算得出秒数和占用比换算的提示数。
    private func _prefillSection(_ now: Double, _ state: String, _ pre: Int, _ running: Int) -> JSON? {
        if !(pre > 0 || state == "prefill") {
            _prefillStart = nil
            return nil
        }
        if _hook == "ok" {
            return _prefillFromHook(now)
        }
        if _prefillStart == nil { _prefillStart = now }
        var promptTokens: JSON = .null
        if running > 0, let metrics = _metrics {
            let top = Self._kvTop(metrics)
            if top > 0 {
                promptTokens = .int(jsRound(top * Double(_contextMax)))
            }
        }
        return [
            "elapsed_s": .double(now - _prefillStart!),
            "prompt_tokens": promptTokens,
            "cached_tokens": .null,
            "filled_tokens": .null,
            "tps": .null,
            "remaining_s": .null,
            "est_s": .null,
            "cache_miss": .bool(false),
            "estimated": .bool(false),
        ]
    }

    /// 2.10：把这次还在预填充的那几条的外挂行加起来。
    private func _prefillFromHook(_ now: Double) -> JSON {
        let rows = (_rows ?? []).filter { $0["phase"] == .string("prefill") }
        var prompt = 0
        var cached = 0
        var filled = 0
        for row in rows {
            prompt += Int(_number(row, "prompt", 0))
            cached += Int(_number(row, "cached", 0))
            filled += Int(_number(row, "filled", 0))
        }
        var starts: [Double] = []
        for row in rows {
            if let id = row["id"], !id.isNull, let entry = _streamEntry(id) {
                starts.append(entry.start)
            }
        }
        let elapsed: Double
        if let earliest = starts.min() {
            elapsed = now - earliest
        } else if let busy = _busy {
            elapsed = now - busy.start
        } else {
            elapsed = 0.0
        }
        var speeds: [Double] = []
        for row in rows {
            if let id = row["id"], !id.isNull, let s = _streamTpsGet(id) {
                speeds.append(s)
            }
        }
        let tps: Double? = speeds.isEmpty ? nil : speeds.reduce(0, +)
        let est = Double(prompt - cached) / prefillTps
        if !rows.isEmpty && rows.contains(where: { $0["filled"] == nil }) {
            // vLLM 的行里没有 filled：只能按平均速度估已算到的位置，进度最高按 99%
            let frac = est <= 0 ? 0.99 : min(0.99, elapsed / est)
            return [
                "elapsed_s": .double(elapsed),
                "prompt_tokens": .int(prompt),
                "cached_tokens": .int(cached),
                "filled_tokens": .int(cached + jsRound(Double(prompt - cached) * frac)),
                "tps": .double(prefillTps),
                "remaining_s": .double(max(0.0, est - elapsed)),
                "est_s": .double(est),
                "cache_miss": .bool(_cacheMiss(prompt, cached)),
                "estimated": .bool(true),
            ]
        }
        let remaining: Double
        if let tps = tps, tps > 0 {
            remaining = Double(prompt - filled) / tps
        } else {
            remaining = max(0.0, est - elapsed)
        }
        return [
            "elapsed_s": .double(elapsed),
            "prompt_tokens": .int(prompt),
            "cached_tokens": .int(cached),
            "filled_tokens": .int(filled),
            "tps": JSON(tps),
            "remaining_s": .double(remaining),
            "est_s": .double(est),
            "cache_miss": .bool(_cacheMiss(prompt, cached)),
            "estimated": .bool(false),
        ]
    }

    /// 2.10：这一轮上一个请求新算的 token 多、这次几乎没复用才算缓存未命中。
    private func _cacheMiss(_ prompt: Int, _ cached: Int) -> Bool {
        guard let rnd = _round, !rnd.concurrent, rnd.done >= 1 else { return false }
        guard let before = rnd.lastPrompt, before >= 4000 else { return false }
        return Double(prompt) >= Double(before) * 0.5 && Double(cached) < Double(before) * 0.5
            && (prompt - cached) >= 4000
    }

    /// 2.11：读到了首字直方图就用精确值盖掉估算值。
    private func _ttftExact() {
        guard let metrics = _metrics else { return }
        let countJ = metrics["ttft_count"]
        let totalJ = metrics["ttft_sum"]
        if countJ.isNone || totalJ.isNone { return }
        guard let count = countJ?.number, let total = totalJ?.number else { return }
        if let pair = _ttftPair, count > pair.1, _ttftPending >= 1, _last != nil {
            _last!["ttft_s"] = .double((total - pair.0) / (count - pair.1))
            _ttftPending = 0
        }
        _ttftPair = (total, count)
    }

    /// 2.12 的本轮。
    private func _roundView(_ now: Double) -> JSON? {
        guard let rnd = _round else { return nil }
        let elapsed: Double
        if _running > 0 {
            elapsed = now - rnd.start
        } else {
            elapsed = rnd.end - rnd.start
        }
        let avg: Double?
        if rnd.concurrent {
            avg = rnd.decodeLen > 0.5 ? Double(_c - rnd.startC) / rnd.decodeLen : nil
        } else if rnd.decodeSum > 0 {
            avg = Double(rnd.output) / rnd.decodeSum
        } else {
            avg = nil
        }
        let gap = config.roundGapS
        return [
            "requests": .int(rnd.done),
            "running": .int(_running),
            "output_tokens": .int(_c - rnd.startC),
            "decode_tps_avg": JSON(avg),
            "exact": .bool(!rnd.concurrent),
            "elapsed_s": .double(elapsed),
            "active": .bool(_running > 0 || (now - rnd.end) <= (gap + 1e-9)),
        ]
    }

    /// 2.12 的上下文占用：外挂好用时取占用最大的那条流，失效时用占用比换算。
    private func _contextUsedOf(_ running: Int) -> JSON {
        if running > 0 {
            if let used = Self._slotUsed(_rows) {
                return used
            }
            if let metrics = _metrics {
                let top = Self._kvTop(metrics)
                if top > 0 {
                    return .int(jsRound(top * Double(_contextMax)))
                }
            }
            return _contextUsed
        }
        if let last = _last {
            return last["context_used"] ?? .int(0)
        }
        return .int(0)
    }

    /// 每条外挂行的 提示 + 已输出（预填充行只算提示），取最大的；一行都没有时 nil。
    private static func _slotUsed(_ rows: [JSON]?) -> JSON? {
        var values: [JSON] = []
        for row in rows ?? [] {
            let prompt = _numberRaw(row, "prompt", .int(0))
            let output: JSON = (row["phase"] == .string("decode")) ? _numberRaw(row, "output", .int(0)) : .int(0)
            if prompt.truthy || output.truthy {
                values.append(_addNum(prompt, output))
            }
        }
        return values.max { ($0.number ?? 0) < ($1.number ?? 0) }
    }

    /// /metrics 的 kv_usage 里的最大值；没有或为空时 0。
    private static func _kvTop(_ metrics: JSON) -> Double {
        guard let usage = metrics["kv_usage"], usage.truthy, let arr = usage.array else { return 0 }
        return arr.compactMap { $0.number }.max() ?? 0
    }

    /// 2.12 的今日用量：账本给的东西一律照抄，抛异常就当没有。
    private func _today() -> JSON {
        guard let usage = usage else { return NO_TODAY }
        return (try? usage.today()) ?? NO_TODAY
    }

    /// 快照骨架：顶层键和顺序照 docs/design.md 的示例。
    private func _blankSnapshot() -> [String: JSON] {
        var snap: [String: JSON] = [:]
        snap["version"] = .int(2)
        snap["state"] = .string("idle")
        snap["hook"] = .string(_hook)
        snap["engine"] = JSON(_engine)
        snap["model"] = .string((_model != nil && !_model!.isEmpty) ? _model! : config.modelName)
        snap["context_max"] = .int(_contextMax)
        snap["lanes"] = .object([
            "max": .int(_lanesMax), "decoding": .int(_dec), "prefilling": .int(_pre), "waiting": .int(0),
        ])
        snap["decode"] = .null
        snap["prefill"] = .null
        snap["context_used"] = _contextUsed
        snap["last"] = _last.map { JSON.object($0) } ?? .null
        snap["round"] = .null
        snap["today"] = _today()
        snap["memory"] = _memory ?? NO_MEMORY
        snap["offline_s"] = .null
        return snap
    }

    /// 2.12：把各段算出来的东西拼成快照。
    private func _buildSnapshot(_ state: String, _ decode: JSON?, _ prefill: JSON?, _ running: Int) -> JSON {
        var snap = _blankSnapshot()
        snap["state"] = .string(state)
        snap["decode"] = decode ?? .null
        snap["prefill"] = prefill ?? .null
        var waiting = 0
        if running > 0, let metrics = _metrics, let value = metrics["waiting"], let i = value.int, i > 0 {
            waiting = i
        }
        snap["lanes"] = .object([
            "max": .int(_lanesMax), "decoding": .int(_dec), "prefilling": .int(_pre), "waiting": .int(waiting),
        ])
        let used = _contextUsedOf(running)
        snap["context_used"] = used
        _contextUsed = used
        snap["round"] = _roundView(_now) ?? .null
        return .object(snap)
    }
}
