import Foundation
import PanelCore

/// 定期拉 /metrics（超时 0.25 s，上一次没返回就跳过），全部状态在主线程更新。
/// 拉取频率自适应：预填充/解码每 0.1 s 一次，其他状态每 0.25 s 一次，状态变化后立即切换。
@MainActor
final class MetricsPoller {
    private let store: PanelStore
    private let url: URL
    private let session: URLSession
    /// 复用的解码器（避免每次拉取新建）
    private let decoder = JSONDecoder()
    private var pending = false
    private var pollTimer: Timer?
    private var memTimer: Timer?
    /// 每次指标/内存更新后的回调（主线程），供调暗等窗口逻辑使用。
    var onUpdate: @MainActor () -> Void = {}

    init(store: PanelStore, url: URL, onUpdate: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.url = url
        self.onUpdate = onUpdate
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.25
        config.timeoutIntervalForResource = 0.25
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 只允许一条到该主机的连接：配合服务端 keep-alive 复用同一条 TCP
        config.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: config)
    }

    func start() {
        // 加到 .common 模式，菜单栏菜单打开（事件追踪模式）时不停摆
        schedule()
        memTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.updateMemory(at: ProcessInfo.processInfo.systemUptime)
                self.onUpdate()
            }
        }
        RunLoop.main.add(memTimer!, forMode: .common)
        poll()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        memTimer?.invalidate()
        memTimer = nil
        session.invalidateAndCancel()
    }

    /// 发一次请求；上一次请求还没返回就跳过本次。
    private func poll() {
        guard !pending else { return }
        pending = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.25
        session.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending = false
                    // HTTP 200 且 JSON 能解析成 Metrics 才算成功；其余一律记失败
                    var metrics: Metrics?
                    if let http = response as? HTTPURLResponse, http.statusCode == 200, let data {
                        metrics = try? self.decoder.decode(Metrics.self, from: data)
                    }
                    let t = ProcessInfo.processInfo.systemUptime
                    self.store.record(metrics, at: t)
                    self.onUpdate()
                    self.schedule()   // 按新状态重新调度，状态变化时立即切换间隔
                }
            }
        }.resume()
    }

    /// 当前画面状态对应的拉取间隔：预填充/解码 0.1 s，其余 0.25 s
    private var interval: TimeInterval {
        switch store.model.state {
        case .prefill, .decode:
            return 0.1
        default:
            return 0.25
        }
    }

    /// 按当前间隔重新调度下一次拉取（一次性 Timer，.common 模式）
    private func schedule() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}
