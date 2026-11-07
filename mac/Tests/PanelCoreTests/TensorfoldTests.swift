// TensorfoldAdapter 和 TensorfoldReader 的测试：手工构造读数 + fixtures 回放，不连真的 TensorFold。
import Foundation
import Testing
@testable import PanelCore

// ---- 类型断言的小工具：该 .int 的 .int、该 .double 的 .double（JSON 相等里 1 == 1.0，类型要另外钉住）----

private func isInt(_ v: JSON?) -> Bool {
    if case .int = v { return true }
    return false
}

private func isDouble(_ v: JSON?) -> Bool {
    if case .double = v { return true }
    return false
}

// ---- 手工样例 ----

/// /health 的完整样子（不配 key）
private let healthFull: JSON = ["status": "ok", "model": "M", "model_ids": ["M", "M-alt"],
                                "max_batch_size": 8, "version": "1.2.2", "backend": "metal",
                                "device": "Apple M5 Ultra"]

private let modelsFull: JSON = ["object": "list",
                                "data": [["id": "M", "context_length": 8192, "max_model_len": 8192]]]

/// 适配器收的是 /v1/models 的 data 数组（不是整个响应）
private let modelsArr: JSON = .array([["id": "M", "context_length": 8192, "max_model_len": 8192]])

/// /metrics 的完整样子（要读的家族都在，另带两行不该认的）
private let metricsFull = """
# HELP tensorfold:requests_running Requests in prefill or decode.
# TYPE tensorfold:requests_running gauge
tensorfold:requests_running 3
tensorfold:requests_waiting 2
tensorfold:generation_tokens_running 7
tensorfold:generation_tokens_total 5000
tensorfold:prompt_tokens_total 1000
tensorfold:prompt_tokens_cached_total 200
tensorfold:kv_cache_usage_ratio{pool="1"} 0.25
tensorfold:kv_cache_usage_ratio{pool="0"} 0.5
tensorfold:mtp_drafted_total 30
tensorfold:mtp_accepted_total 12
tensorfold:request_latency_seconds_bucket{le="+Inf"} 9
tensorfold:request_latency_seconds_count 9
tensorfold:time_to_first_token_seconds_sum 1.5
tensorfold:time_to_first_token_seconds_count 8
tensorfold:request_decode_seconds_sum 33.25
tensorfold:request_prefill_seconds_sum 4.5
tensorfold:client_disconnections_total 2
tensorfold:process_start_time_seconds 1794046709
tensorfold:filling_prompt_tokens_left 0
"""

/// 删掉 mtp_*、client_disconnections_total、prompt_tokens_cached_total、
/// time_to_first_token_seconds_*、kv_cache_usage_ratio 之后的 /metrics
private let metricsSparse = """
tensorfold:requests_running 3
tensorfold:requests_waiting 2
tensorfold:generation_tokens_running 7
tensorfold:generation_tokens_total 5000
tensorfold:request_latency_seconds_count 9
tensorfold:request_decode_seconds_sum 33.25
tensorfold:request_prefill_seconds_sum 4.5
tensorfold:process_start_time_seconds 1794046709
tensorfold:filling_prompt_tokens_left 0
"""

/// 再删掉 generation_tokens_running（completion_finished_total 取 generation_tokens_total）
private let metricsNoRunning = """
tensorfold:requests_running 3
tensorfold:generation_tokens_total 5000
tensorfold:request_latency_seconds_count 9
tensorfold:process_start_time_seconds 1794046709
tensorfold:filling_prompt_tokens_left 0
"""

/// 正在预填充（filling_prompt_tokens_left > 0）
private let metricsFilling = """
tensorfold:requests_running 3
tensorfold:filling_prompt_tokens_left 500
"""

// ---- 适配器 ----

@Suite struct TestTensorfold {
    private func feed(health: JSON? = healthFull, models: JSON? = modelsArr,
                      metrics: String? = metricsFull) -> (health: JSON, metrics: JSON)? {
        TensorfoldAdapter().feed(now: 0.0, health: health, models: models,
                                 metrics: metrics.map { PrometheusText($0) })
    }

    @Test func test_全字段都在() {
        let r = feed()!
        let h = r.health
        #expect(h["ok"] == .bool(true))
        #expect(h["backend"] == "tensorfold")
        #expect(h["requests_running"] == 3)
        #expect(isInt(h["requests_running"]))
        let streamsWant: JSON = ["decoding": 3, "prefilling": 0, "max": 8]
        #expect(h["streams"] == streamsWant)
        // requests_total = latency_count − 断开数（9 − 2 = 7，正常结束口径）
        #expect(h["requests_total"] == 7)
        #expect(isInt(h["requests_total"]))
        #expect(h["prompt_tokens_total"] == 1000)
        #expect(h["cached_tokens_total"] == 200)
        #expect(h["completion_tokens_total"] == 5000)
        #expect(h["prefill_seconds_total"] == 4.5)
        #expect(isDouble(h["prefill_seconds_total"]))
        #expect(h["decode_seconds_total"] == 33.25)
        #expect(isDouble(h["decode_seconds_total"]))
        #expect(h["drafted_total"] == 30)
        #expect(h["accepted_total"] == 12)
        #expect(h["aborted_total"] == 2)
        #expect(h["epoch"] == 1794046700)   // (1794046709 / 10).rounded(.down) * 10
        #expect(isInt(h["epoch"]))
        #expect(h["completion_finished_total"] == 4993)   // 5000 − 7
        let utWant: JSON = ["prompt": 1000, "cached": 200, "completion": 4993, "requests": 7]
        #expect(h["usage_totals"] == utWant)
        #expect(h["context_length"] == 8192)
        let m = r.metrics
        #expect(m["waiting"] == 2)
        #expect(m["kv_usage"] == [.double(0.5), .double(0.25)])   // pool 0 在前
        #expect(isDouble(m["kv_usage"]?[0]))
        #expect(m["ttft_sum"] == 1.5)
        #expect(isDouble(m["ttft_sum"]))
        #expect(m["ttft_count"] == 8)
        #expect(isInt(m["ttft_count"]))
        // 不带的键
        #expect(h["usage_by_model"] == nil)
        #expect(h["loading"] == nil)
        #expect(h["tfpanel"] == nil)
    }

    @Test func test_缺失就缺失() {
        let r = feed(metrics: metricsSparse)!
        #expect(r.health["drafted_total"] == nil)
        #expect(r.health["accepted_total"] == nil)
        #expect(r.health["aborted_total"] == nil)
        // 缓存家族缺 → 按 0，不缺键
        #expect(r.health["cached_tokens_total"] == 0)
        #expect(r.health["usage_totals"]?["cached"] == 0)
        let m = r.metrics
        #expect(m["ttft_sum"] == nil)
        #expect(m["ttft_count"] == nil)
        #expect(m["kv_usage"] == nil)
        #expect(m["waiting"] == 2)   // waiting 家族还在
    }

    @Test func test_generation_tokens_running缺时取总数() {
        let r = feed(metrics: metricsNoRunning)!
        #expect(r.health["completion_tokens_total"] == 5000)
        #expect(r.health["completion_finished_total"] == 5000)
        #expect(r.health["usage_totals"]?["completion"] == 5000)
    }

    @Test func test_metrics整体缺时全按缺处理() {
        guard let r = feed(metrics: nil) else {
            Issue.record("feed 返回 nil")
            return
        }
        #expect(r.health["requests_running"] == 0)
        #expect(r.health["requests_total"] == 0)
        #expect(r.health["completion_finished_total"] == 0)
        let utWant: JSON = ["prompt": 0, "cached": 0, "completion": 0, "requests": 0]
        #expect(r.health["usage_totals"] == utWant)
        #expect(r.health["epoch"] == .null)
        #expect(r.metrics["waiting"] == nil)
        #expect(r.metrics["kv_usage"] == nil)
    }

    @Test func test_max_batch_size缺失或非法时按8() {
        #expect(feed(health: ["version": "1.2.2", "backend": "metal"])!.health["streams"]?["max"] == 8)
        #expect(feed(health: ["version": "1.2.2", "backend": "metal", "max_batch_size": 0])!.health["streams"]?["max"] == 8)
        #expect(feed(health: ["version": "1.2.2", "backend": "metal", "max_batch_size": -2])!.health["streams"]?["max"] == 8)
        #expect(feed(health: ["version": "1.2.2", "backend": "metal", "max_batch_size": "big"])!.health["streams"]?["max"] == 8)
        #expect(feed(health: ["version": "1.2.2", "backend": "metal", "max_batch_size": 4])!.health["streams"]?["max"] == 4)
    }

    @Test func test_streams按filling推() {
        // 没在预填充：decoding = running
        let idle = feed(metrics: """
        tensorfold:requests_running 3
        tensorfold:filling_prompt_tokens_left 0
        """)!
        #expect(idle.health["streams"] == ["decoding": 3, "prefilling": 0, "max": 8])
        // 在预填充：prefilling = 1，decoding = running − 1
        let filling = feed(metrics: metricsFilling)!
        #expect(filling.health["streams"] == ["decoding": 2, "prefilling": 1, "max": 8])
        // 家族缺 → filling 按 0
        let noFilling = feed(metrics: "tensorfold:requests_running 2")!
        #expect(noFilling.health["streams"] == ["decoding": 2, "prefilling": 0, "max": 8])
    }

    @Test func test_kv_usage按pool数值排序() {
        let r = feed(metrics: """
        tensorfold:kv_cache_usage_ratio{pool="10"} 0.9
        tensorfold:kv_cache_usage_ratio{pool="2"} 0.2
        tensorfold:kv_cache_usage_ratio{pool="abc"} 0.7
        tensorfold:kv_cache_usage_ratio{pool="0"} 0.1
        """)!
        #expect(r.metrics["kv_usage"] == [.double(0.1), .double(0.2), .double(0.9)])
    }

    @Test func test_health不是对象时返回nil() {
        #expect(feed(health: nil) == nil)               // 没读到 /health
        #expect(feed(health: .int(401)) == nil)         // 不是对象
        #expect(feed(health: .null) == nil)
    }

    @Test func test_context_length() {
        // models 里有当前模型：取它的 context_length
        #expect(feed()!.health["context_length"] == 8192)
        // 当前模型没有 context_length → 取 max_model_len
        let noCtx: JSON = .array([["id": "M", "max_model_len": 4096]])
        #expect(feed(models: noCtx)!.health["context_length"] == 4096)
        // 没有当前模型的项 → 用数组第一项的
        let others: JSON = .array([["id": "X", "context_length": 2048]])
        #expect(feed(models: others)!.health["context_length"] == 2048)
        // models 缺 → 262144
        #expect(feed(models: nil)!.health["context_length"] == 262144)
        #expect(feed(models: .array([]))!.health["context_length"] == 262144)
    }

    // ---- 读取 ----

    /// 假传输层：按路径存要返回的结果（可以随时改），并记下每次调用的 (path, headers)
    private final class FakeTransport: HTTPTransport {
        var responses: [String: HTTPResult?] = [:]
        var calls: [(path: String, headers: [String: String])] = []

        func get(_ path: String, headers: [String: String]) -> HTTPResult? {
            calls.append((path, headers))
            return responses[path] ?? nil
        }

        func count(_ path: String) -> Int { calls.filter { $0.path == path }.count }

        func lastHeaders(_ path: String) -> [String: String]? {
            calls.last { $0.path == path }?.headers
        }
    }

    private func okJSON(_ json: JSON) -> HTTPResult {
        HTTPResult(status: 200, body: Data(json.serialized().utf8))
    }

    private func okText(_ text: String) -> HTTPResult {
        HTTPResult(status: 200, body: Data(text.utf8))
    }

    /// 三个路径都给正常内容
    private func setupOK(_ t: FakeTransport) {
        t.responses["/health"] = okJSON(healthFull)
        t.responses["/metrics"] = okText(metricsFull)
        t.responses["/v1/models"] = okJSON(modelsFull)
    }

    @Test func test_无key认出并读数() {
        let t = FakeTransport()
        setupOK(t)
        let rd = TensorfoldReader(transport: t)
        let r = rd.read(now: 0.0, wall: 1000.0)
        #expect(r != nil)
        #expect(rd.issue == .none)
        #expect(rd.modelIDs == ["M", "M-alt"])
        #expect(rd.modelName == "M")
        let h = r!.health
        #expect(h["backend"] == "tensorfold")
        #expect(h["requests_total"] == 7)      // 读数来自 /metrics 的文本（9 − 断开 2）
        #expect(h["completion_finished_total"] == 4993)
        #expect(h["epoch"] == 1794046700)
        #expect(r!.metrics["waiting"] == 2)
        // 三个 GET 按顺序；/health 不带头，没配 key 时其余也不带头
        #expect(t.calls.map { $0.path } == ["/health", "/metrics", "/v1/models"])
        for c in t.calls { #expect(c.headers.isEmpty) }
    }

    @Test func test_有key时health只有status用metrics试探() {
        let t = FakeTransport()
        t.responses["/health"] = okJSON(["status": "ok"])
        t.responses["/metrics"] = okText(metricsFull)
        t.responses["/v1/models"] = okJSON(modelsFull)
        let rd = TensorfoldReader(transport: t, apiKey: "k1")
        let r = rd.read(now: 0.0, wall: 1000.0)
        #expect(r != nil)
        #expect(rd.issue == .none)
        // 配了 key 的 /health 只有 status、没有 model_ids → 回退到 /v1/models 的 id 列表
        #expect(rd.modelIDs == ["M"])
        #expect(rd.modelName == "M")
        // 试探拿到的 /metrics 直接当这次的用：只请求了一次，带头
        #expect(t.count("/metrics") == 1)
        #expect(t.lastHeaders("/metrics")?["Authorization"] == "Bearer k1")
        #expect(t.lastHeaders("/v1/models")?["Authorization"] == "Bearer k1")
        // /health 永远不带头
        #expect(t.lastHeaders("/health")?.isEmpty == true)
        #expect(r!.health["requests_total"] == 7)
    }

    @Test func test_试探401时needsKeyTensorfold() {
        let t = FakeTransport()
        t.responses["/health"] = okJSON(["status": "ok"])
        t.responses["/metrics"] = HTTPResult(status: 401, body: Data())
        let rd = TensorfoldReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd.issue == .needsKeyTensorfold)
        #expect(rd.issue.message == "TensorFold 需要 API key · 在设置里填写")
        #expect(t.count("/v1/models") == 0)   // 没认出就不往下读
    }

    @Test func test_试探404时notTensorfold() {
        let t = FakeTransport()
        t.responses["/health"] = okJSON(["status": "ok"])
        t.responses["/metrics"] = HTTPResult(status: 404, body: Data())
        let rd = TensorfoldReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd.issue == .notTensorfold)
        #expect(rd.issue.message == "这个地址上不是 TensorFold")
    }

    @Test func test_health返回HTML时notTensorfold() {
        let t = FakeTransport()
        t.responses["/health"] = HTTPResult(status: 200, body: Data("<html>hi</html>".utf8))
        let rd = TensorfoldReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd.issue == .notTensorfold)
    }

    @Test func test_health非200或连不上时unreachable() {
        let t = FakeTransport()
        t.responses["/health"] = HTTPResult(status: 500, body: Data())
        let rd = TensorfoldReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd.issue == .unreachable)
        let t2 = FakeTransport()   // 所有路径都连不上
        let rd2 = TensorfoldReader(transport: t2)
        #expect(rd2.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd2.issue == .unreachable)
    }

    @Test func test_health没有status时不用metrics试探() {
        let t = FakeTransport()
        t.responses["/health"] = okJSON(["foo": 1])
        let rd = TensorfoldReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd.issue == .notTensorfold)
        #expect(t.count("/metrics") == 0)
    }

    @Test func test_metrics或models失败时unreachable() {
        let t = FakeTransport()
        setupOK(t)
        t.responses["/metrics"] = nil
        let rd = TensorfoldReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd.issue == .unreachable)
        // /metrics 正常、/v1/models 500 → 也算读不到
        setupOK(t)
        t.responses["/v1/models"] = HTTPResult(status: 500, body: Data())
        #expect(rd.read(now: 1.0, wall: 1001.0) == nil)
        #expect(rd.issue == .unreachable)
    }

    @Test func test_model_ids缺时回退到models列表() {
        let t = FakeTransport()
        t.responses["/health"] = okJSON(["status": "ok", "max_batch_size": 8,
                                         "version": "1.2.2", "backend": "metal"])
        t.responses["/metrics"] = okText(metricsFull)
        t.responses["/v1/models"] = okJSON(modelsFull)
        let rd = TensorfoldReader(transport: t)
        let r = rd.read(now: 0.0, wall: 1000.0)
        #expect(r != nil)
        #expect(rd.modelIDs == ["M"])
        #expect(rd.modelName == "M")   // /health 没有 model → modelIDs 第一个
    }

    @Test func test_reset清状态() {
        let t = FakeTransport()
        setupOK(t)
        let rd = TensorfoldReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) != nil)
        rd.reset()
        #expect(rd.modelIDs.isEmpty)
        #expect(rd.modelName == nil)
        #expect(rd.issue == .none)
    }

    // ---- fixtures 回放 ----

    @Test func test_回放实录() throws {
        // 逐行读 fixtures/tensorfold/scenarios.jsonl（每行 {"t","ep","status","body"}），
        // 按时间顺序把每拍的 /health、/v1/models、/metrics 喂给适配器
        let url = fixturesDir.appendingPathComponent("tensorfold/scenarios.jsonl")
        let data = try Data(contentsOf: url)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)

        let ad = TensorfoldAdapter()
        var health: JSON?
        var models: JSON?
        var metricsText: String?
        var currentT = Double.nan
        var ticks = 0
        var prevTotal: Int?
        var epochs: Set<Int> = []
        var lastAborted: Int?

        func feedTick() {
            guard let h = health, !currentT.isNaN else { return }
            let t = currentT
            guard let res = ad.feed(now: t, health: h, models: models,
                                    metrics: metricsText.map { PrometheusText($0) }) else {
                Issue.record("feed 返回 nil：t=\(t)")
                return
            }
            ticks += 1
            #expect(res.health["ok"] == .bool(true))
            #expect(res.health["backend"] == "tensorfold")
            // streams 推导和 running 对得上
            let running = res.health["requests_running"]?.int ?? 0
            let dec = res.health["streams"]?["decoding"]?.int ?? 0
            let pre = res.health["streams"]?["prefilling"]?.int ?? 0
            #expect(dec + pre == running, "t=\(t)：decoding \(dec) + prefilling \(pre) != running \(running)")
            // requests_total 单调不减
            let total = res.health["requests_total"]?.int ?? 0
            if let prevTotal {
                #expect(total >= prevTotal, "t=\(t)：requests_total \(prevTotal) → \(total)")
            }
            prevTotal = total
            // epoch 不变（没有重启）：只收集，最后断言全程一个值
            if case .int(let e) = res.health["epoch"] {
                epochs.insert(e)
            }
            if let ab = res.health["aborted_total"]?.int { lastAborted = ab }
        }

        for line in lines {
            guard let rec = JSON.parse(String(line)), let t = rec["t"]?.number,
                  let ep = rec["ep"]?.string, let body = rec["body"]?.string else {
                continue
            }
            if t != currentT {
                feedTick()
                health = nil
                models = nil
                metricsText = nil
                currentT = t
            }
            switch ep {
            case "/health":
                if rec["status"]?.int == 200 { health = JSON.parse(body) }
            case "/v1/models":
                if rec["status"]?.int == 200 { models = JSON.parse(body)?["data"] }
            case "/metrics":
                if rec["status"]?.int == 200 { metricsText = body }
            default:
                break   // /v1/load、/stats 不喂适配器
            }
        }
        feedTick()   // 最后一拍

        // 实录是 105 秒、约每秒 4 拍：至少得喂上几百拍，只喂一两拍说明分组错了
        #expect(ticks >= 100, "ticks = \(ticks)")
        // 实录里有一次客户端中断：最后一拍 aborted_total >= 1
        #expect(lastAborted != nil && lastAborted! >= 1, "最后一拍 aborted_total = \(String(describing: lastAborted))")
        // 全程一个 epoch（没有重启）
        #expect(epochs.count == 1)
    }
}