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

/// http 地址直接用套接字发 HTTP/1.1（每次一条连接，Connection: close）；
/// 每秒要读好几次，URLSession 每个请求的开销在空闲时就占掉 1% 左右的 CPU，套接字只要它的五分之一
public final class SocketTransport: HTTPTransport {
    private let host: String
    private let port: String
    private let prefix: String     // 地址里带的路径前缀，没有就是空串
    private let hostHeader: String
    private let timeout: Double

    /// baseURL 不是 http 地址时返回 nil
    public init?(baseURL: String, timeout: Double = 0.5) {
        var b = baseURL.trimmingCharacters(in: .whitespaces)
        if !b.contains("://") { b = "http://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        guard let c = URLComponents(string: b), c.scheme?.lowercased() == "http",
              let h = c.host, !h.isEmpty else { return nil }
        host = h
        port = String(c.port ?? 80)
        prefix = c.percentEncodedPath
        hostHeader = (h.contains(":") ? "[\(h)]" : h) + (c.port.map { ":\($0)" } ?? "")
        self.timeout = timeout
    }

    public func get(_ path: String, headers: [String: String]) -> HTTPResult? {
        let deadline = Date().timeIntervalSince1970 + timeout
        guard let fd = connectSocket(deadline: deadline) else { return nil }
        defer { close(fd) }
        var req = "GET \(prefix)\(path) HTTP/1.1\r\nHost: \(hostHeader)\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        req += "Accept: application/json\r\nConnection: close\r\n\r\n"
        let bytes = Array(req.utf8)
        var sent = 0
        while sent < bytes.count {
            guard wait(fd, for: Int16(POLLOUT), deadline: deadline) else { return nil }
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; return nil }
            sent += n
        }
        // 读到对方关连接为止
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            guard wait(fd, for: Int16(POLLIN), deadline: deadline) else { return nil }
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; return nil }
            if n == 0 { break }
            raw.append(buf, count: n)
        }
        return Self.parseResponse(raw)
    }

    /// 非阻塞连接，等到 deadline 为止；失败返回 nil
    private func connectSocket(deadline: Double) -> Int32? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            ai = a.pointee.ai_next
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { return fd }
            if errno == EINPROGRESS, wait(fd, for: Int16(POLLOUT), deadline: deadline) {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 { return fd }
            }
            close(fd)
        }
        return nil
    }

    /// 等套接字可读 / 可写，到 deadline 还不行返回 false
    private func wait(_ fd: Int32, for events: Int16, deadline: Double) -> Bool {
        while true {
            let left = deadline - Date().timeIntervalSince1970
            if left <= 0 { return false }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let r = poll(&p, 1, Int32(max(1, (left * 1000).rounded(.up))))
            if r > 0 { return true }
            if r == 0 || errno != EINTR { return false }
        }
    }

    /// 拆响应：状态行、头、内容（按 Content-Length、chunked，或者都没有时到结尾为止）
    static func parseResponse(_ raw: Data) -> HTTPResult? {
        let sep = Data("\r\n\r\n".utf8)
        guard let end = raw.range(of: sep),
              let head = String(data: raw[raw.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return nil }
        var length: Int?
        var chunked = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { length = Int(value) }
            if name == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
        }
        var body = Data(raw[end.upperBound...])
        if chunked {
            guard let b = dechunk(body) else { return nil }
            body = b
        } else if let n = length {
            guard body.count >= n else { return nil }   // 没收全
            body = body.prefix(n)
        }
        return HTTPResult(status: status, body: Data(body))
    }

    private static func dechunk(_ data: Data) -> Data? {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let r = data.range(of: crlf, in: i..<data.endIndex),
                  let line = String(data: data[i..<r.lowerBound], encoding: .ascii),
                  let size = Int(line.split(separator: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16)
            else { return nil }
            i = r.upperBound
            if size == 0 { return out }
            guard data.distance(from: i, to: data.endIndex) >= size + 2 else { return nil }
            let j = data.index(i, offsetBy: size)
            out.append(data[i..<j])
            i = data.index(j, offsetBy: 2)
        }
    }
}

/// 按地址选传输层：http 用套接字，其余（https）用 URLSession
public func makeTransport(baseURL: String, timeout: Double = 0.5) -> HTTPTransport {
    SocketTransport(baseURL: baseURL, timeout: timeout) ?? URLSessionTransport(baseURL: baseURL, timeout: timeout)
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
