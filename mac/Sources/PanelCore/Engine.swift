// oMLX 适配器：把 /api/status 和 /admin/api/stats 换算成和 TensorFold /health 同格式的
// “统一读数”（health、metrics 两个 JSON 对象），并维护一张按 request_id 记的流表。
// 翻译自 docs/tasks/mac/ref/omlx_adapter.py，行为以它为准；不读时钟、不做 I/O。
import Foundation

private let LIMBO_S: Double = 1.0             // 一行从表里消失后最多保留多久，等累计请求数跟上
private let DEFAULT_CONTEXT = 262144          // /v1/models 里读不到上下文上限时用
private let DEFAULT_MAX_STREAMS = 8           // oMLX 的默认并发上限
private let EPOCH_TOLERANCE_S: Double = 30.0  // 启动时刻算出来的值抖动多少以内算同一次启动
private let GIB: Double = 1073741824

private let totalKeys = ["total_requests", "total_prompt_tokens", "total_cached_tokens",
                         "total_completion_tokens"]

/// 整数（bool 不算）原样返回，其余 nil。
private func _int(_ v: JSON?) -> Int? { v?.int }

/// 数（bool 不算）转成 Double，其余返回 default。
private func _num(_ v: JSON?, _ `default`: Double = 0.0) -> Double { v?.number ?? `default` }

/// 整数或浮点数取整（向零截断），其余返回 default。
private func _int_or(_ v: JSON?, _ `default`: Int = 0) -> Int {
    if let n = v?.number { return Int(n) }
    return `default`
}

/// 对应 Python 里表里的行（可变字典，几处代码拿着同一个字典改）。字段照 _new_row 的键。
private final class Row {
    let id: Int
    let rid: String
    let model: String
    var phase = "wait"
    var prompt = 0
    var cached = 0
    var filled = 0
    var output = 0
    var start: Double
    var ttftS: Double?
    var pstart: Double?
    var decS = 0.0
    var seen = true
    var goneAt: Double?
    var ttftKnown = true

    init(id: Int, rid: String, model: String, start: Double) {
        self.id = id
        self.rid = rid
        self.model = model
        self.start = start
    }
}

/// _parse_stats 的 tables 里的一条：request_id → (表名, 行, 模型名)。
private struct TableEntry {
    let rid: String
    let table: String
    let r: JSON
    let model: String
}

public final class OmlxAdapter {
    public var maxStreams: Int
    public private(set) var contexts: [String: Int] = [:]  // 模型名 → 上下文上限，由调用方用 setModels 给

    private var prev: [Int]?          // 上一次完整读数的四项累计值，nil 表示还没有
    private var uptime: Double?       // 上一次的 uptime_seconds
    private var epoch: Int?           // 粘住的启动时刻（整数秒）
    private var rowList: [Row] = []      // 按第一次见到的顺序
    private var placeholders: [Double] = []  // “行还没出来”的占位的开始时刻，从早到晚
    private var credits: [(Double, Int)] = []  // [(时刻, 个数)]：累计请求数增加了、还没对上消失的行
    private var nextId = 1
    private var aborted = 0
    private var abPrompt = 0          // 断开带走的提示、缓存命中、输出
    private var abCached = 0
    private var abOutput = 0
    private var ttftSum = 0.0
    private var ttftCount = 0
    private var prefillS = 0.0
    private var decodeS = 0.0
    private var byModel: [String: [Int]] = [:]  // 模型名 → [prompt, cached, completion, requests]
    private var lastModel: String?    // 最近开始的那条流所属的模型
    private var defaultModel: String?
    private var lastC = 0             // 上一次给出的 completion_tokens_total（只增不减）
    private var usageTotals: JSON?    // 上一次完整读数给出的 usage_totals / usage_by_model
    private var usageByModel: JSON?
    private var loading: (Double, JSON)?  // 上一次读到的加载信息 (时刻, 字典)

    public init(maxStreams: Int = 8) {
        self.maxStreams = maxStreams
    }

    /// 回到刚建好的状态（contexts、maxStreams 不动）。
    public func reset() {
        prev = nil
        uptime = nil
        epoch = nil
        rowList = []
        placeholders = []
        credits = []
        nextId = 1
        aborted = 0
        abPrompt = 0
        abCached = 0
        abOutput = 0
        ttftSum = 0.0
        ttftCount = 0
        prefillS = 0.0
        decodeS = 0.0
        byModel = [:]
        lastModel = nil
        defaultModel = nil
        lastC = 0
        usageTotals = nil
        usageByModel = nil
        loading = nil
    }

    /// /v1/models 的 data 列表 → 记下各模型的上下文上限。
    public func setModels(_ models: JSON?) {
        contexts = [:]
        for m in models?.array ?? [] {
            guard m.object != nil, let id = m["id"]?.string else { continue }
            if let n = _int(m["max_model_len"]), n > 0 {
                contexts[id] = n
            }
        }
    }

    /// 画面上显示的模型：加载中的 → 最近开始的 → oMLX 的默认模型。
    public var modelName: String? {
        if let (_, info) = loading { return info["model"]?.string }
        return orEmpty(lastModel, defaultModel)
    }

    /// 当前流表（公开的 8 个键），按第一次见到的顺序。
    public func rows() -> [JSON] { rowList.map { pub($0) } }

    // ---- 对外接口 ----

    /// 喂一次读数。status 是 /api/status 的对象；stats 是 /admin/api/stats 的对象或 nil。
    ///
    /// now：单调时钟秒数（和采集器同一个钟）；wall：Unix 时间戳（只用来算启动时刻）。
    /// status 不是对象、或四项累计值缺了 / 不是整数 → 返回 nil（当作这次读不到）。
    public func feed(now: Double, wall: Double, status: JSON?, stats: JSON?) -> (health: JSON, metrics: JSON)? {
        guard let status else { return nil }
        var totals: [Int] = []
        for k in totalKeys {
            guard let v = _int(status[k]) else { return nil }
            totals.append(v)
        }
        let active = max(0, _int_or(status["active_requests"]))
        let waitingStatus = max(0, _int_or(status["waiting_requests"]))
        let dm = status["default_model"]
        let up = status["uptime_seconds"]
        let upSeconds = up?.number  // 不是数（含 bool）时为 nil

        // 1. 重启：累计值变小、uptime 变小、或者启动时刻跳了 → 全部清空，这次当第一次读数
        var rawEpoch: Double?
        if let u = upSeconds { rawEpoch = wall - u }
        if let p = prev {
            var restarted = false
            for i in 0..<4 where totals[i] < p[i] { restarted = true }
            if let u = upSeconds, let old = uptime, u < old { restarted = true }
            if let re = rawEpoch, let e = epoch, abs(re - Double(e)) > EPOCH_TOLERANCE_S { restarted = true }
            if restarted { reset() }
        }
        if let d = dm?.string, !d.isEmpty { defaultModel = d }
        if let re = rawEpoch, epoch == nil || abs(re - Double(epoch!)) > EPOCH_TOLERANCE_S {
            epoch = Int(re.rounded(.toNearestOrEven))  // Python 的 round 是逢五取偶
        }
        if let u = upSeconds { uptime = u }

        guard let stats, stats.object != nil else {
            return degraded(now: now, totals: totals, active: active, waitingStatus: waitingStatus)
        }

        let (tables, loadingInfo) = parseStats(stats)
        if let li = loadingInfo {
            loading = (now, li)
        } else {
            loading = nil
        }

        if prev == nil {
            first(now: now, tables: tables)
            prev = totals
            fitPlaceholders(now: now, tables: tables, active: active, waitingStatus: waitingStatus)
            let base = orEmpty(lastModel, defaultModel) ?? ""
            byModel = [base: [totals[1], totals[2], totals[3], totals[0]]]
            return output(now: now, totals: totals, active: active, waitingStatus: waitingStatus, tables: tables)
        }

        // 2. 表里的行：更新已知的，新建第一次见到的
        updateRows(now: now, tables: tables)
        // 3. 结束：累计请求数增加了 k，对上这次没出现在表里的行
        let inc = totals[0] - prev![0]
        if inc > 0 {
            credits.append((now, inc))
        }
        let finished = matchFinished(now: now, tables: tables)
        // 4. 这次累计值的增量记到模型名下
        attribute(totals: totals, finished: finished)
        // 5. 消失超过 LIMBO_S 的行算中途断开；过期的累计请求数增量作废
        expire(now: now)
        // 6. 占位
        fitPlaceholders(now: now, tables: tables, active: active, waitingStatus: waitingStatus)
        prev = totals
        return output(now: now, totals: totals, active: active, waitingStatus: waitingStatus, tables: tables)
    }

    // ---- 解析 ----

    /// → (tables, loading)。tables 按模型在列表里的顺序、每个模型内 waiting、prefilling、
    /// generating 的顺序、每张表内行的顺序；另加 rid → 下标 的字典查找。
    /// loading：第一个 is_loading 为真的模型 → {model, elapsed_s, estimated_s, size_gb}，没有就 nil。
    private func parseStats(_ stats: JSON) -> ([TableEntry], JSON?) {
        var tables: [TableEntry] = []
        var index: [String: Int] = [:]  // rid → tables 里的下标
        var loading: JSON? = nil
        let am = stats["active_models"]
        let modelList = am?["models"]?.array
        for m in modelList ?? [] {
            guard m.object != nil else { continue }
            let name = m["id"]?.string ?? ""
            if m["is_loading"] == .bool(true), loading == nil {
                let est = m["loading_estimated_seconds"]
                let size = m["estimated_size"]
                var info: [String: JSON] = [:]
                info["model"] = .string(name)
                info["elapsed_s"] = .double(_num(m["loading_elapsed_seconds"], 0.0))
                if let e = est?.number, e > 0 {
                    info["estimated_s"] = .double(e)
                } else {
                    info["estimated_s"] = .null
                }
                if let s = size?.number, s > 0 {
                    info["size_gb"] = .double(s / GIB)
                } else {
                    info["size_gb"] = .null
                }
                loading = .object(info)
            }
            for table in ["waiting", "prefilling", "generating"] {
                guard let tableRows = m[table]?.array else { continue }
                for r in tableRows {
                    guard let rid = r["request_id"]?.string, !rid.isEmpty, index[rid] == nil else { continue }
                    index[rid] = tables.count
                    tables.append(TableEntry(rid: rid, table: table, r: r, model: name))
                }
            }
        }
        return (tables, loading)
    }

    // ---- 流表 ----

    @discardableResult
    private func newRow(rid: String, model: String, start: Double) -> Row {
        let row = Row(id: nextId, rid: rid, model: model, start: start)
        nextId += 1
        rowList.append(row)
        lastModel = model
        return row
    }

    private func findRow(_ rid: String) -> Row? { rowList.first { $0.rid == rid } }

    private func removeRow(_ rid: String) { rowList.removeAll { $0.rid == rid } }

    /// 这一行自己报的已用秒数：waiting、generating 是 elapsed_seconds，prefilling 是 elapsed。
    private func elapsed(_ table: String, _ r: JSON) -> Double {
        let key = table == "prefilling" ? "elapsed" : "elapsed_seconds"
        return max(0.0, _num(r[key], 0.0))
    }

    /// 第一次读数：表里已有的行照各自报的已用秒数回推开始时刻；正在解码的不知道首字时间。
    private func first(now: Double, tables: [TableEntry]) {
        for e in tables {
            let row = newRow(rid: e.rid, model: e.model, start: now - elapsed(e.table, e.r))
            if e.table == "generating" {
                row.ttftKnown = false
            }
            apply(now: now, row: row, table: e.table, r: e.r)
        }
    }

    /// 先按 waiting、prefilling、generating 的顺序新建行（新行按这个顺序领占位），再更新所有行。
    private func updateRows(now: Double, tables: [TableEntry]) {
        for row in rowList { row.seen = false }
        for order in ["waiting", "prefilling", "generating"] {
            for e in tables {
                guard e.table == order, findRow(e.rid) == nil else { continue }
                let start: Double
                if order == "waiting" {
                    start = now - elapsed(e.table, e.r)
                } else if !placeholders.isEmpty {
                    start = placeholders.removeFirst()
                } else {
                    start = now - elapsed(e.table, e.r)
                }
                newRow(rid: e.rid, model: e.model, start: start)
            }
        }
        for e in tables {
            if let row = findRow(e.rid) {
                apply(now: now, row: row, table: e.table, r: e.r)
            }
        }
    }

    /// 用表里的这一行更新流表的行。
    private func apply(now: Double, row: Row, table: String, r: JSON) {
        row.seen = true
        row.goneAt = nil
        row.prompt = max(0, _int_or(r["prompt_tokens"]))
        if table == "waiting" {
            row.phase = "wait"
            return
        }
        if table == "prefilling" {
            row.phase = "prefill"
            row.cached = max(0, _int_or(r["cached_tokens"]))
            row.filled = max(row.cached, _int_or(r["processed"]))
            row.output = 0
            if row.pstart == nil {
                row.pstart = now - elapsed(table, r)
            }
            return
        }
        // generating
        let el = elapsed(table, r)
        if row.phase != "decode", row.ttftKnown, row.ttftS == nil {
            row.ttftS = max(0.0, now - el - row.start)
        }
        row.phase = "decode"
        row.filled = row.prompt
        row.output = max(0, _int_or(r["generated_tokens"]))
        row.decS = el
    }

    /// 这次没出现在表里的行：先记下消失的时刻；再用攒着的累计请求数增量对上，
    /// 解码行优先，同类里开始早的优先。对上的行算正常结束，从流表删掉。返回这些行。
    private func matchFinished(now: Double, tables: [TableEntry]) -> [Row] {
        var gone: [Row] = []
        for row in rowList {
            if tables.contains(where: { $0.rid == row.rid }) { continue }
            if row.goneAt == nil { row.goneAt = now }
            gone.append(row)
        }
        // 键：(phase != "decode", start, id)；id 唯一，排序是确定的
        gone.sort { a, b in
            let ka = a.phase != "decode"
            let kb = b.phase != "decode"
            if ka != kb { return !ka }
            if a.start != b.start { return a.start < b.start }
            return a.id < b.id
        }
        let credit = credits.reduce(0) { $0 + $1.1 }
        let k = min(credit, gone.count)
        let finished = Array(gone[0..<k])
        // 从最早的增量开始扣
        var left = k
        var kept: [(Double, Int)] = []
        for (t, n) in credits {
            let use = min(n, left)
            left -= use
            if n - use > 0 { kept.append((t, n - use)) }
        }
        credits = kept
        for row in finished {
            removeRow(row.rid)
            if let ttft = row.ttftS {
                ttftSum += ttft
                ttftCount += 1
                let queue = row.pstart.map { max(0.0, $0 - row.start) } ?? 0.0
                prefillS += max(0.0, ttft - queue)
            }
            if row.phase == "decode" {
                decodeS += row.decS
            }
        }
        return finished
    }

    /// 四项累计值的增量记到模型名下：有对上结束的行就按它们的提示长度分，
    /// 没有就记在最近开始的模型（再没有就是默认模型）名下。
    private func attribute(totals: [Int], finished: [Row]) {
        let p = prev!
        let delta = [totals[1] - p[1], totals[2] - p[2], totals[3] - p[3], totals[0] - p[0]]
        if !delta.contains(where: { $0 != 0 }) { return }
        var names: [String]
        var weights: [Int]
        if !finished.isEmpty {
            names = finished.map { $0.model }
            weights = finished.map { $0.prompt }
        } else {
            names = [orEmpty(lastModel, defaultModel) ?? ""]
            weights = [1]
        }
        if weights.reduce(0, +) == 0 {
            weights = [Int](repeating: 1, count: names.count)
        }
        let wsum = weights.reduce(0, +)
        for (i, d) in delta.enumerated() {
            // d、weights 都不是负数（累计值变小会在上面算重启），Swift 的 / 与 Python 的 // 结果相同
            var shares = weights.map { d * $0 / wsum }
            shares[0] += d - shares.reduce(0, +)
            for (name, s) in zip(names, shares) {
                byModel[name, default: [0, 0, 0, 0]][i] += s
            }
        }
    }

    /// 消失超过 LIMBO_S 的行算中途断开；超过 LIMBO_S 还没对上的累计请求数增量作废。
    private func expire(now: Double) {
        for row in Array(rowList) {
            guard let goneAt = row.goneAt, now - goneAt >= LIMBO_S else { continue }
            removeRow(row.rid)
            aborted += 1
            // 排队时就断开的请求还没算过，不计用量
            let prompt = row.phase != "wait" ? row.prompt : 0
            let cached = row.phase != "wait" ? row.cached : 0
            let out = row.phase == "decode" ? row.output : 0
            abPrompt += prompt
            abCached += cached
            abOutput += out
            var acc = byModel[row.model] ?? [0, 0, 0, 0]
            acc[0] += prompt
            acc[1] += cached
            acc[2] += out
            byModel[row.model] = acc
        }
        credits = credits.filter { now - $0.0 < LIMBO_S }
    }

    /// 在跑数比表里的行多出来的部分记成占位：多了从最晚的删，少了按这次的时刻补。
    private func fitPlaceholders(now: Double, tables: [TableEntry], active: Int, waitingStatus: Int) {
        let nWait = tables.filter { $0.table == "waiting" }.count
        let wait = max(waitingStatus, nWait)
        let nRun = tables.filter { $0.table != "waiting" }.count
        let gone = rowList.filter { $0.goneAt != nil }.count
        let target = max(0, active - wait - nRun - gone)
        while placeholders.count > target { placeholders.removeLast() }
        while placeholders.count < target { placeholders.append(now) }
    }

    // ---- 输出 ----

    private func pub(_ row: Row) -> JSON {
        var o: [String: JSON] = [
            "id": .int(row.id), "phase": .string(row.phase), "prompt": .int(row.prompt),
            "cached": .int(row.cached), "filled": .int(row.filled), "output": .int(row.output),
            "start": .double(row.start),
        ]
        o["ttft_s"] = JSON(row.ttftS)
        return .object(o)
    }

    private func loadingNow(_ now: Double) -> JSON? {
        guard let (t, info) = loading, var o = info.object else { return nil }
        o["elapsed_s"] = .double((info["elapsed_s"]?.number ?? 0.0) + (now - t))
        return .object(o)
    }

    private func context() -> Int {
        guard let name = modelName, !name.isEmpty else { return DEFAULT_CONTEXT }
        return contexts[name] ?? DEFAULT_CONTEXT
    }

    private func healthBase(now: Double, totals: [Int], running: Int, decoding: Int,
                            prefilling: Int, completion: Int) -> [String: JSON] {
        lastC = max(lastC, completion)
        var health: [String: JSON] = [
            "ok": .bool(true),
            "backend": .string("omlx"),
            "requests_running": .int(running),
            "streams": ["decoding": .int(decoding), "prefilling": .int(prefilling), "max": .int(maxStreams)],
            "requests_total": .int(totals[0]),
            "completion_tokens_total": .int(lastC),
            "prompt_tokens_total": .int(totals[1]),
            "cached_tokens_total": .int(totals[2]),
            "prefill_seconds_total": .double(prefillS),
            "decode_seconds_total": .double(decodeS),
            "drafted_total": .int(0),
            "accepted_total": .int(0),
            "epoch": JSON(epoch),
            "aborted_total": .int(aborted),
            "completion_finished_total": .int(totals[3]),
            "context_length": .int(context()),
        ]
        if let ld = loadingNow(now) { health["loading"] = ld }
        return health
    }

    private func output(now: Double, totals: [Int], active: Int, waitingStatus: Int,
                        tables: [TableEntry]) -> (health: JSON, metrics: JSON) {
        let curRows = rowList
        let nWait = curRows.filter { $0.phase == "wait" }.count
        let dec = curRows.filter { $0.phase == "decode" }
        let pre = curRows.filter { $0.phase == "prefill" }
        let wait = max(waitingStatus, nWait)
        let ph = placeholders.count
        let running = wait + dec.count + pre.count + ph
        let live = dec.reduce(0) { $0 + $1.output }
        var health = healthBase(now: now, totals: totals, running: running, decoding: dec.count,
                                prefilling: pre.count + ph,
                                completion: totals[3] + live + abOutput)
        usageTotals = ["prompt": .int(totals[1] + abPrompt), "cached": .int(totals[2] + abCached),
                       "completion": .int(totals[3] + abOutput), "requests": .int(totals[0])]
        var ubm: [String: JSON] = [:]
        for name in byModel.keys.sorted() {
            let v = byModel[name]!
            ubm[name] = ["prompt": .int(v[0]), "cached": .int(v[1]),
                         "completion": .int(v[2]), "requests": .int(v[3])]
        }
        usageByModel = .object(ubm)
        health["usage_totals"] = usageTotals!
        health["usage_by_model"] = usageByModel!
        if ph == 0 {
            health["tfpanel"] = ["v": .int(1), "streams": .array(curRows.filter { $0.phase != "wait" }.map { pub($0) })]
        }
        let metrics: JSON = ["waiting": .int(wait), "kv_usage": .array([]),
                             "ttft_sum": .double(ttftSum), "ttft_count": .int(ttftCount)]
        return (.object(health), metrics)
    }

    /// /admin/api/stats 读不到：只用 /api/status，不带 tfpanel；流表、累计秒数都不动。
    private func degraded(now: Double, totals: [Int], active: Int,
                          waitingStatus: Int) -> (health: JSON, metrics: JSON) {
        var health = healthBase(now: now, totals: totals, running: active,
                                decoding: max(0, active - waitingStatus), prefilling: 0,
                                completion: totals[3] + abOutput)
        if usageTotals == nil {
            let base = orEmpty(lastModel, defaultModel) ?? ""
            let ut: JSON = ["prompt": .int(totals[1]), "cached": .int(totals[2]),
                            "completion": .int(totals[3]), "requests": .int(totals[0])]
            usageTotals = ut
            usageByModel = .object([base: ut])
        }
        health["usage_totals"] = usageTotals!
        health["usage_by_model"] = usageByModel!
        let metrics: JSON = ["waiting": .int(waitingStatus), "kv_usage": .array([]),
                             "ttft_sum": .double(ttftSum), "ttft_count": .int(ttftCount)]
        return (.object(health), metrics)
    }
}

/// Python 的 `a or b`（空串也算假）。
private func orEmpty(_ a: String?, _ b: String?) -> String? {
    if let a, !a.isEmpty { return a }
    return b
}
