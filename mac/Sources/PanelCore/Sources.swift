// HTTP 读取、OmlxReader、读 oMLX 设置文件。
// OmlxReader 负责发请求、认出 oMLX、带上 API key、把读到的东西喂给适配器。
import Foundation

public struct HTTPResult: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// 发 GET 请求的东西；测试里换成假的
public protocol HTTPTransport: AnyObject {
    /// 连不上、超时返回 nil；连上了就返回状态码和内容（不管状态码是多少）
    func get(_ path: String, headers: [String: String]) -> HTTPResult?
}

/// 结果盒子：完成回调在别的线程里写，调用方等信号量之后读
private final class ResultBox: @unchecked Sendable {
    var value: HTTPResult?
}

public final class URLSessionTransport: HTTPTransport {
    private let base: String
    private let session: URLSession

    public init(baseURL: String, timeout: Double = 0.5) {
        var b = baseURL.trimmingCharacters(in: .whitespaces)
        if !b.contains("://") { b = "http://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        base = b
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.connectionProxyDictionary = [:]   // 本机地址不走系统代理
        session = URLSession(configuration: cfg)
    }

    public func get(_ path: String, headers: [String: String]) -> HTTPResult? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse {
                box.value = HTTPResult(status: http.statusCode, body: data ?? Data())
            }
            sem.signal()
        }.resume()
        sem.wait()
        return box.value
    }
}

public enum EngineIssue: String, Sendable {
    case none, unreachable, notOmlx, needsKey

    public var message: String? {
        switch self {
        case .none: return nil
        case .unreachable: return "未连接"
        case .notOmlx: return "这个地址上不是 oMLX"
        case .needsKey: return "oMLX 需要 API key · 在设置里填写"
        }
    }
}

public final class OmlxReader {
    private let transport: HTTPTransport
    private let adapter: OmlxAdapter
    public var apiKey: String?
    public private(set) var issue: EngineIssue = .none   // 最近一次读的结果
    public private(set) var modelIDs: [String] = []      // /v1/models 里的模型名，按原顺序
    private var verified = false                         // 认没认出 oMLX
    private var misses = 0                               // 连续读不到的次数
    private var modelsAt: Double?                        // 上次读 /v1/models 的时刻

    public init(transport: HTTPTransport, apiKey: String? = nil, maxStreams: Int = 8) {
        self.transport = transport
        self.apiKey = apiKey
        self.adapter = OmlxAdapter(maxStreams: maxStreams)
    }

    /// apiKey 不为 nil 也不是空串时带 Authorization；否则不带任何头
    private var headers: [String: String] {
        if let k = apiKey, !k.isEmpty { return ["Authorization": "Bearer \(k)"] }
        return [:]
    }

    /// 读一次；nil = 这次读不到
    public func read(now: Double, wall: Double) -> (health: JSON, metrics: JSON)? {
        // 1. 还没认出 oMLX：先 GET /health（永远不带头）
        if !verified {
            guard let r = transport.get("/health", headers: [:]) else {
                failOnce(.unreachable)
                return nil
            }
            guard r.status == 200, let j = JSON.parse(r.body), j.object != nil,
                  j["engine_pool"] != nil else {
                failOnce(.notOmlx)
                return nil
            }
            verified = true
        }
        // 2. 每 5 秒读一次模型列表
        if modelsAt == nil || now - modelsAt! >= 5 {
            modelsAt = now
            if let r = transport.get("/v1/models", headers: headers), r.status == 200,
               let j = JSON.parse(r.body), let data = j["data"]?.array {
                adapter.setModels(.array(data))
                modelIDs = data.compactMap { $0["id"]?.string }
            }
        }
        // 3. /api/status
        guard let r = transport.get("/api/status", headers: headers) else {
            failOnce(.unreachable)
            return nil
        }
        if r.status == 401 {
            failOnce(.needsKey)
            return nil
        }
        guard r.status == 200, let status = JSON.parse(r.body), status.object != nil else {
            failOnce(.notOmlx)
            return nil
        }
        // 4. /admin/api/stats：读不到就 nil（适配器会走降级）
        var stats: JSON?
        if let s = transport.get("/admin/api/stats", headers: headers), s.status == 200,
           let sj = JSON.parse(s.body), sj.object != nil {
            stats = sj
        }
        // 5. 喂给适配器
        guard let res = adapter.feed(now: now, wall: wall, status: status, stats: stats) else {
            failOnce(.notOmlx)
            return nil
        }
        misses = 0
        issue = .none
        return res
    }

    /// 记一次读不到，原因 X；连续 3 次后适配器清空、重新认引擎
    private func failOnce(_ why: EngineIssue) {
        misses += 1
        issue = why
        if misses >= 3 {
            adapter.reset()
            verified = false
            modelsAt = nil
            misses = 0
        }
    }

    /// 换地址、换 key 后调用：适配器清空、重新认引擎
    public func reset() {
        adapter.reset()
        verified = false
        modelsAt = nil
        misses = 0
        issue = .none
    }

    public var modelName: String? { adapter.modelName }
}

/// 读 oMLX 的设置文件；读不了、不是 JSON 时返回 nil
private func omlxSettings(_ settingsPath: String) -> JSON? {
    let path = (settingsPath as NSString).expandingTildeInPath
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return JSON.parse(data)
}

/// auth.api_key（不是字符串或空串时返回 nil）
public func omlxApiKey(settingsPath: String = "~/.omlx/settings.json") -> String? {
    guard let key = omlxSettings(settingsPath)?["auth"]?["api_key"]?.string, !key.isEmpty else {
        return nil
    }
    return key
}

/// scheduler.max_concurrent_requests（整数且大于 0 时），否则 8
public func omlxMaxStreams(settingsPath: String = "~/.omlx/settings.json") -> Int {
    if let n = omlxSettings(settingsPath)?["scheduler"]?["max_concurrent_requests"]?.int, n > 0 {
        return n
    }
    return 8
}
