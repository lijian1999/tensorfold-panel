// SocketTransport 的测试：本进程里起一个只回一次的小服务器。
import Foundation
import Testing
@testable import PanelCore

/// 监听 127.0.0.1 的随机端口，接一个连接：读到请求头结束，回 reply（nil = 不回、拖到 hold 秒后关掉）
private final class OneShotServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var _request = ""
    private let done = DispatchSemaphore(value: 0)

    init(reply: Data?, hold: Double = 0) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(fd, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = Int(UInt16(bigEndian: addr.sin_port))
        let listener = fd
        Thread { [self] in
            let c = accept(listener, nil, nil)
            var got = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while got.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = recv(c, &buf, buf.count, 0)
                if n <= 0 { break }
                got.append(buf, count: n)
            }
            lock.lock(); _request = String(decoding: got, as: UTF8.self); lock.unlock()
            if let r = reply {
                _ = r.withUnsafeBytes { send(c, $0.baseAddress, $0.count, 0) }
            } else {
                Thread.sleep(forTimeInterval: hold)
            }
            close(c)
            close(listener)
            done.signal()
        }.start()
    }

    /// 等服务器那边处理完，返回收到的请求
    func request() -> String {
        _ = done.wait(timeout: .now() + 2)
        lock.lock(); defer { lock.unlock() }
        return _request
    }
}

private func reply(_ s: String) -> Data { Data(s.utf8) }

@Suite struct TestSocketTransport {
    @Test func test_按ContentLength读内容_请求带路径和头() throws {
        let srv = OneShotServer(reply: reply("HTTP/1.1 200 OK\r\ncontent-length: 5\r\ncontent-type: application/json\r\n\r\n{\"a\":1}"))
        let t = try #require(SocketTransport(baseURL: "127.0.0.1:\(srv.port)"))
        let r = t.get("/api/status", headers: ["Authorization": "Bearer k"])
        #expect(r == HTTPResult(status: 200, body: Data("{\"a\":".utf8)))
        let req = srv.request()
        #expect(req.hasPrefix("GET /api/status HTTP/1.1\r\n"))
        #expect(req.contains("\r\nAuthorization: Bearer k\r\n"))
        #expect(req.contains("\r\nHost: 127.0.0.1:\(srv.port)\r\n"))
        #expect(req.contains("\r\nConnection: close\r\n"))
    }

    @Test func test_chunked内容拼回原样() throws {
        let srv = OneShotServer(reply: reply("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3;x=1\r\n:12\r\n1\r\n}\r\n0\r\n\r\n"))
        let t = try #require(SocketTransport(baseURL: "http://127.0.0.1:\(srv.port)/"))
        #expect(t.get("/health", headers: [:]) == HTTPResult(status: 200, body: Data("{\"a\":12}".utf8)))
    }

    @Test func test_没有长度时读到连接关闭_非200也照样返回() throws {
        let srv = OneShotServer(reply: reply("HTTP/1.0 401 Unauthorized\r\n\r\nno key"))
        let t = try #require(SocketTransport(baseURL: "127.0.0.1:\(srv.port)"))
        #expect(t.get("/api/status", headers: [:]) == HTTPResult(status: 401, body: Data("no key".utf8)))
    }

    @Test func test_地址里的路径前缀加在请求路径前面() throws {
        let srv = OneShotServer(reply: reply("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
        let t = try #require(SocketTransport(baseURL: "http://127.0.0.1:\(srv.port)/omlx/"))
        #expect(t.get("/health", headers: [:])?.status == 200)
        #expect(srv.request().hasPrefix("GET /omlx/health HTTP/1.1\r\n"))
    }

    @Test func test_连不上返回nil() throws {
        let srv = OneShotServer(reply: reply("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
        let port = srv.port
        let t0 = try #require(SocketTransport(baseURL: "127.0.0.1:\(port)"))
        _ = t0.get("/", headers: [:])
        _ = srv.request()   // 服务器已经关了监听
        let t = try #require(SocketTransport(baseURL: "127.0.0.1:\(port)"))
        #expect(t.get("/health", headers: [:]) == nil)
    }

    @Test func test_对方不回话到超时返回nil() throws {
        let srv = OneShotServer(reply: nil, hold: 1.0)
        let t = try #require(SocketTransport(baseURL: "127.0.0.1:\(srv.port)", timeout: 0.2))
        let start = Date()
        #expect(t.get("/health", headers: [:]) == nil)
        #expect(Date().timeIntervalSince(start) < 0.6)
        _ = srv.request()
    }

    @Test func test_内容没收全算读不到() {
        #expect(SocketTransport.parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)) == nil)
        #expect(SocketTransport.parseResponse(Data("garbage".utf8)) == nil)
    }

    @Test func test_https用URLSession_http用套接字() {
        #expect(SocketTransport(baseURL: "https://example.com") == nil)
        #expect(makeTransport(baseURL: "https://example.com") is URLSessionTransport)
        #expect(makeTransport(baseURL: "127.0.0.1:8000") is SocketTransport)
        #expect(makeTransport(baseURL: " http://localhost:8000/ ") is SocketTransport)
    }
}
