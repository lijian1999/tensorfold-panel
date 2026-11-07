// TensorFold 适配器和读取：把 /health、/metrics（Prometheus 文本）、/v1/models 换算成统一读数。
// 适配器无状态：同样的输入永远同样的输出，不记上一次；读取器每一拍都重新认引擎。
// 输出的键位照 OmlxAdapter 的统一读数：主字段在 health 里，waiting/kv_usage/ttft 在 metrics 里
// （采集器就从这两个字典里取，见 Collector._onRead 和 _metrics 的用法）。
import Foundation

private let DEFAULT_CONTEXT = 262144    // /v1/models 里读不到上下文上限时用
private let DEFAULT_MAX_STREAMS = 8     // /health 里读不到 max_batch_size 时用

public final class TensorfoldAdapter {
    public init() {}

    /// 喂一次读数。health：/health 的解析结果；models：/v1/models 的 data 数组；
    /// metrics：/metrics 的解析结果。哪个是 nil 就当这次没读到它（metrics 为 nil 时家族全按缺处理）。
    /// health 不是 JSON 对象 → 返回 nil（这次读不到）。
    public func feed(now: Double, health: JSON?, models: JSON?, metrics: PrometheusText?) -> (health: JSON, metrics: JSON)? {
        guard let h = health, h.object != nil else { return nil }
        let m = metrics ?? PrometheusText("")

        // health 字典：计数、累计值、账本要用的都在这里
        let running = truncInt(m.number("tensorfold:requests_running") ?? 0)
        let genTotal = m.number("tensorfold:generation_tokens_total") ?? 0
        let genRunning = m.number("tensorfold:generation_tokens_running")   // 缺就取前者（减 0）
        let finished = truncInt(genTotal - (genRunning ?? 0))
        let promptTotal = truncInt(m.number("tensorfold:prompt_tokens_total") ?? 0)
        let cachedTotal = truncInt(m.number("tensorfold:prompt_tokens_cached_total") ?? 0)
        let requestsTotal = truncInt(m.number("tensorfold:request_latency_seconds_count") ?? 0)
        // TF native 的 latency_count 把客户端断开的请求也算成"结束"（实测 2026-11-07：
        // 13 发起 = 13 结束，其中 1 次断开）。"本轮请求/账本请求数"的口径是正常结束，
        // 不含断开 → 减掉 client_disconnections_total（缺失按 0）。token 侧不用减：
        // prompt_tokens_total 本来就不含断开的提示，generation_tokens_total 含断开前
        // 已生成的输出，正是"断开带走的用量"。
        let disconnections = truncInt(m.number("tensorfold:client_disconnections_total") ?? 0)
        let successTotal = max(0, requestsTotal - disconnections)

        var out: [String: JSON] = [
            "ok": .bool(true),
            "backend": .string("tensorfold"),
            "requests_running": .int(running),
            "streams": Self.streams(running: running, health: h, metrics: m),
            "requests_total": .int(successTotal),
            "prompt_tokens_total": .int(promptTotal),
            "cached_tokens_total": .int(cachedTotal),
            "completion_tokens_total": .int(truncInt(genTotal)),
            "prefill_seconds_total": .double(m.number("tensorfold:request_prefill_seconds_sum") ?? 0.0),
            "decode_seconds_total": .double(m.number("tensorfold:request_decode_seconds_sum") ?? 0.0),
            "completion_finished_total": .int(finished),
            "usage_totals": ["prompt": .int(promptTotal), "cached": .int(cachedTotal),
                             "completion": .int(finished), "requests": .int(successTotal)],
            "context_length": .int(Self.contextLength(models: models, health: h)),
        ]
        // epoch：process_start_time_seconds 取整到 10 秒；缺 → .null
        out["epoch"] = m.number("tensorfold:process_start_time_seconds")
            .map { .int(truncInt(($0 / 10).rounded(.down) * 10)) } ?? .null
        // 缺失就缺失：家族不在就不带这个键，不造假零
        if let v = m.number("tensorfold:mtp_drafted_total") { out["drafted_total"] = .int(truncInt(v)) }
        if let v = m.number("tensorfold:mtp_accepted_total") { out["accepted_total"] = .int(truncInt(v)) }
        if let v = m.number("tensorfold:client_disconnections_total") { out["aborted_total"] = .int(truncInt(v)) }

        // metrics 字典：waiting、kv_usage、ttft（采集器从 metrics 里取这几个）
        var metricsOut: [String: JSON] = [:]
        if let w = m.number("tensorfold:requests_waiting") { metricsOut["waiting"] = .int(truncInt(w)) }
        let pools = m.numbers("tensorfold:kv_cache_usage_ratio")
        if !pools.isEmpty {
            // 按 pool 键的数值升序；键读不成数的忽略
            let values: [JSON] = pools.filter { Int($0.key) != nil }
                .sorted { Int($0.key)! < Int($1.key)! }
                .map { .double($0.value) }
            metricsOut["kv_usage"] = .array(values)
        }
        // ttft：_sum 缺 → 这对键都不带；_count 单独缺 → 只不带 _count
        if let s = m.number("tensorfold:time_to_first_token_seconds_sum") {
            metricsOut["ttft_sum"] = .double(s)
            if let c = m.number("tensorfold:time_to_first_token_seconds_count") {
                metricsOut["ttft_count"] = .int(truncInt(c))
            }
        }
        return (.object(out), .object(metricsOut))
    }

    // ---- 派生字段 ----

    /// streams：没有流表明细，按聚合值推。prefilling = filling_prompt_tokens_left > 0 算 1 否则 0；
    /// decoding = max(0, requests_running − prefilling)；max = /health 的 max_batch_size（是数且 > 0），否则 8。
    private static func streams(running: Int, health: JSON, metrics: PrometheusText) -> JSON {
        let prefilling = (metrics.number("tensorfold:filling_prompt_tokens_left") ?? 0) > 0 ? 1 : 0
        let decoding = max(0, running - prefilling)
        var maxStreams = DEFAULT_MAX_STREAMS
        if let v = health["max_batch_size"]?.number, v > 0 { maxStreams = truncInt(v) }
        return ["decoding": .int(decoding), "prefilling": .int(prefilling), "max": .int(maxStreams)]
    }

    /// context_length：models 的 data 数组里找 id 等于 /health 的 model 的项，取它的
    /// context_length（没有再取 max_model_len）；找不到项用数组第一项的；数组空或缺 → 262144。
    private static func contextLength(models: JSON?, health: JSON) -> Int {
        guard let data = models?.array, !data.isEmpty else { return DEFAULT_CONTEXT }
        let name = health["model"]?.string
        let item = name.flatMap { n in data.first { $0["id"]?.string == n } } ?? data[0]
        if let n = item["context_length"]?.number { return truncInt(n) }
        if let n = item["max_model_len"]?.number { return truncInt(n) }
        return DEFAULT_CONTEXT
    }
}

/// 取整（向零截断）。
private func truncInt(_ v: Double) -> Int { Int(v) }

// MARK: - 读取

public final class TensorfoldReader: EngineSource {
    private let transport: HTTPTransport
    private let adapter = TensorfoldAdapter()
    public var apiKey: String?
    public private(set) var issue: EngineIssue = .none   // 最近一次读的结果
    public private(set) var modelIDs: [String] = []      // /health 的 model_ids；没有就用 /v1/models 的 id 列表
    private var model: String?                           // /health 的 model

    public init(transport: HTTPTransport, apiKey: String? = nil) {
        self.transport = transport
        self.apiKey = apiKey
    }

    /// apiKey 不为 nil 也不是空串时带 Authorization；否则不带任何头
    private var headers: [String: String] {
        if let k = apiKey, !k.isEmpty { return ["Authorization": "Bearer \(k)"] }
        return [:]
    }

    /// 画面上显示的模型：/health 的 model；缺取 modelIDs 第一个。
    public var modelName: String? {
        if let m = model, !m.isEmpty { return m }
        return modelIDs.first
    }

    /// 读一次；nil = 这次读不到。每次按顺序发三个 GET：/health、/metrics、/v1/models。
    public func read(now: Double, wall: Double) -> (health: JSON, metrics: JSON)? {
        // 1. /health：认引擎（永远不带头，配了 key 它也开放，只是只回 {"status":"ok"}）
        guard let hr = transport.get("/health", headers: [:]) else { return fail(.unreachable) }
        guard hr.status == 200 else { return fail(.unreachable) }
        guard let h = JSON.parse(hr.body), h.object != nil else { return fail(.notTensorfold) }

        // 2. 认出没有：带 version 和 backend → 认出；只有 status（配了 key 的样子）→ 拿 /metrics 试探
        var metricsResult: HTTPResult?
        if h["version"] == nil || h["backend"] == nil {
            guard h["status"] != nil else { return fail(.notTensorfold) }
            guard let pr = transport.get("/metrics", headers: headers) else { return fail(.unreachable) }
            if pr.status == 401 { return fail(.needsKeyTensorfold) }
            guard pr.status == 200 else { return fail(.notTensorfold) }
            metricsResult = pr   // 试探拿到的就是这次的 /metrics，不用再读一遍
        }

        // 3. /metrics：没在试探里拿到就读一次；失败这次就算读不到
        if metricsResult == nil {
            guard let mr = transport.get("/metrics", headers: headers), mr.status == 200 else {
                return fail(.unreachable)
            }
            metricsResult = mr
        }

        // 4. /v1/models：失败这次也算读不到
        guard let vr = transport.get("/v1/models", headers: headers), vr.status == 200 else {
            return fail(.unreachable)
        }
        let modelsJSON = JSON.parse(vr.body)?["data"]

        // 5. 模型列表和模型名
        var ids = h["model_ids"]?.array?.compactMap { $0.string } ?? []
        if ids.isEmpty, let data = modelsJSON?.array {
            ids = data.compactMap { $0["id"]?.string }
        }
        modelIDs = ids
        model = h["model"]?.string

        // 6. 喂适配器（health 已确认是对象，不会返回 nil）
        let text = String(data: metricsResult!.body, encoding: .utf8) ?? ""
        guard let res = adapter.feed(now: now, health: h, models: modelsJSON,
                                     metrics: PrometheusText(text)) else {
            return fail(.notTensorfold)
        }
        issue = .none
        return res
    }

    /// 这次读不到：记下原因，返回 nil（连续 3 次离线的判断在采集器/轮询层）
    private func fail(_ why: EngineIssue) -> (health: JSON, metrics: JSON)? {
        issue = why
        return nil
    }

    /// 换地址、换 key 后调用：清状态，下一拍重新认引擎（适配器无状态，无需清）
    public func reset() {
        issue = .none
        modelIDs = []
        model = nil
    }
}