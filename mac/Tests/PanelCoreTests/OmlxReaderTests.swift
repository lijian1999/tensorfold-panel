// OmlxReader 的测试：用假的传输层，不连真的 oMLX。
import Foundation
import Testing
@testable import PanelCore

/// 假传输层：按路径存要返回的结果（可以随时改），并记下每次调用的 (path, headers)
private final class FakeTransport: HTTPTransport {
    var responses: [String: HTTPResult?] = [:]
    var calls: [(path: String, headers: [String: String])] = []

    func get(_ path: String, headers: [String: String]) -> HTTPResult? {
        calls.append((path, headers))
        return responses[path] ?? nil
    }

    /// 某个路径被请求的次数
    func count(_ path: String) -> Int { calls.filter { $0.path == path }.count }
}

private func ok(_ json: JSON) -> HTTPResult {
    HTTPResult(status: 200, body: Data(json.serialized().utf8))
}

private let okStatus: JSON = [
    "total_requests": 0, "total_prompt_tokens": 0, "total_cached_tokens": 0,
    "total_completion_tokens": 0, "active_requests": 0, "waiting_requests": 0,
    "uptime_seconds": 100.0, "default_model": "M",
]
private let okStats: JSON = ["active_models": ["models": []]]
private let okHealth: JSON = ["status": "healthy", "engine_pool": [:]]
private let okModels: JSON = ["data": [["id": "M", "max_model_len": 4096]]]

/// 四个路径都给正常内容
private func setupOK(_ t: FakeTransport) {
    t.responses["/health"] = ok(okHealth)
    t.responses["/v1/models"] = ok(okModels)
    t.responses["/api/status"] = ok(okStatus)
    t.responses["/admin/api/stats"] = ok(okStats)
}

@Suite struct TestOmlxReader {
    @Test func test_health不是oMLX时读不到() {
        let t = FakeTransport()
        t.responses["/health"] = ok(["status": "ok"])
        let rd = OmlxReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd.issue == .notOmlx)
    }

    @Test func test_连不上时是unreachable() {
        let t = FakeTransport()  // 所有路径都返回 nil
        let rd = OmlxReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd.issue == .unreachable)
    }

    @Test func test_401时是needsKey() {
        let t = FakeTransport()
        setupOK(t)
        t.responses["/api/status"] = HTTPResult(status: 401, body: Data())
        let rd = OmlxReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) == nil)
        #expect(rd.issue == .needsKey)
        #expect(rd.issue.message == "oMLX 需要 API key · 在设置里填写")
    }

    @Test func test_正常读数带key且health只认一次() {
        let t = FakeTransport()
        setupOK(t)
        let rd = OmlxReader(transport: t, apiKey: "k1")
        let r1 = rd.read(now: 0.0, wall: 1000.0)
        let r2 = rd.read(now: 0.1, wall: 1000.1)
        #expect(r1 != nil)
        #expect(r2 != nil)
        #expect(r1!.health["backend"] == "omlx")
        #expect(r2!.health["backend"] == "omlx")
        #expect(rd.issue == .none)
        // /health 只被请求过一次且不带任何头
        #expect(t.count("/health") == 1)
        let healthCall = t.calls.first { $0.path == "/health" }!
        #expect(healthCall.headers.isEmpty)
        // /api/status 每次都带 Authorization: Bearer k1
        let statusCalls = t.calls.filter { $0.path == "/api/status" }
        #expect(statusCalls.count == 2)
        for c in statusCalls {
            #expect(c.headers["Authorization"] == "Bearer k1")
        }
        #expect(rd.modelIDs == ["M"])
        #expect(r1!.health["context_length"] == 4096)  // 模型名来自 default_model 的 "M"
    }

    @Test func test_详情读不到时降级() {
        let t = FakeTransport()
        setupOK(t)
        t.responses["/admin/api/stats"] = HTTPResult(status: 500, body: Data())
        let rd = OmlxReader(transport: t)
        let r = rd.read(now: 0.0, wall: 1000.0)
        #expect(r != nil)
        #expect(r!.health["tfpanel"] == nil)
    }

    @Test func test_连续3次读不到后重新认引擎() {
        let t = FakeTransport()
        setupOK(t)
        let rd = OmlxReader(transport: t)
        #expect(rd.read(now: 0.0, wall: 1000.0) != nil)  // 先正常读一次（认了一次）
        t.responses["/api/status"] = nil                  // 连读三次都读不到
        #expect(rd.read(now: 1.0, wall: 1001.0) == nil)
        #expect(rd.read(now: 2.0, wall: 1002.0) == nil)
        #expect(rd.read(now: 3.0, wall: 1003.0) == nil)
        setupOK(t)                                        // 改回正常再读一次
        let r = rd.read(now: 4.0, wall: 1004.0)
        // 第一次认、清空后再认一次
        #expect(t.count("/health") == 2)
        #expect(r != nil)
    }

    @Test func test_模型列表每5秒读一次() {
        let t = FakeTransport()
        setupOK(t)
        let rd = OmlxReader(transport: t)
        _ = rd.read(now: 0.0, wall: 1000.0)
        _ = rd.read(now: 1.0, wall: 1001.0)
        _ = rd.read(now: 4.9, wall: 1004.9)
        _ = rd.read(now: 5.0, wall: 1005.0)
        #expect(t.count("/v1/models") == 2)
    }

    @Test func test_读设置文件里的key和并发上限() {
        // 临时目录：temporaryDirectory 下新建唯一子目录，测试结束删掉
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omlx-settings-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let content: JSON = ["auth": ["api_key": "abc"], "scheduler": ["max_concurrent_requests": 6]]
        try! Data(content.serialized().utf8).write(to: file)
        #expect(omlxApiKey(settingsPath: file.path) == "abc")
        #expect(omlxMaxStreams(settingsPath: file.path) == 6)
        let missing = dir.appendingPathComponent("nope.json").path
        #expect(omlxApiKey(settingsPath: missing) == nil)
        #expect(omlxMaxStreams(settingsPath: missing) == 8)
    }
}
