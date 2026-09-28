import AppKit
import Foundation
import PanelCore

/// 程序形态：.accessory（不占 Dock、不出现在 ⌘Tab），启动时不在主屏弹任何窗口。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 默认指标地址
    static let defaultMetricsURL = "http://127.0.0.1:8081/metrics"

    let settings = Settings()
    let store: PanelStore
    private let metricsURL: URL
    private var poller: MetricsPoller?
    private let screenManager: ScreenManager
    private var statusMenu: StatusMenu?
    /// 调试截图输出目录（--debug-capture；为 nil 时不注册信号）
    private let debugCaptureDir: URL?
    private var captureSource: DispatchSourceProtocol?

    init(metricsURL: String?, screenName: String?, debugCapture: String?) {
        // 优先级：命令行 --metrics-url > 环境变量 TFPANEL_METRICS_URL > 默认
        let raw = metricsURL
            ?? ProcessInfo.processInfo.environment["TFPANEL_METRICS_URL"]
            ?? Self.defaultMetricsURL
        self.metricsURL = URL(string: raw) ?? URL(string: Self.defaultMetricsURL)!
        self.debugCaptureDir = debugCapture.map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.store = PanelStore()
        self.screenManager = ScreenManager(
            settings: settings,
            store: self.store,
            screenName: screenName ?? settings.screenName
        )
        self.statusMenu = StatusMenu(settings: settings, screenManager: self.screenManager)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        poller = MetricsPoller(store: store, url: metricsURL) { [weak self] in
            self?.screenManager.refreshDim()
        }
        poller?.start()
        screenManager.start()
        if let dir = debugCaptureDir {
            registerCaptureSignal(dir: dir)
        }
    }

    /// SIGUSR1 → 把副屏窗口当前画面截图（先忽略信号，再用 DispatchSource 在主队列处理）。
    private func registerCaptureSignal(dir: URL) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: DispatchQueue.main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let path = self.screenManager.debugCapture(to: dir) {
                    print(path)
                } else {
                    print("TFPanel：副屏窗口不存在，截图失败")
                }
            }
        }
        source.resume()
        captureSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureSource?.cancel()
        poller?.stop()
        screenManager.stop()
    }
}
