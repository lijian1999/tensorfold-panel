// app 主体：把 PanelCore 的读取、轮询、采集、账本、视图模型和副屏窗口接起来。
// 接口照接口约定 9.5 节。
import AppKit
import Foundation
import PanelCore

@MainActor
final class AppController {
    let settings: AppSettings
    let screens: ScreenManager
    private(set) var issue: EngineIssue = .unreachable   // 最近一拍的引擎状态
    private(set) var modelIDs: [String] = []              // 最近一拍 oMLX 的模型列表
    private(set) var currentModel: String?                // 最近一拍的模型名（原文）
    var onStatusChange: (() -> Void)?                     // 上面三项或副屏状态变了时调

    /// 当前画面（nil = 还没有），给 PanelView 和截图用
    var view: View? { box.view }

    private let ledger: UsageLedger
    private let collector: Collector
    private let viewModel: ViewModel
    private var config: Config
    private let poller: Poller
    private var reader: OmlxReader
    private var readerAddress: String     // 当前读取器的地址
    private var readerKey: String?        // 当前读取器的 API key
    private var keyCheckAt = -Double.infinity    // auto 模式下 needsKey 的上次检查时刻
    private let box: Box                  // 和 PanelView 共享的画面/帧率

    /// AppController 建 PanelView 时传出去的共享状态（避免 init 里捕获 self）。
    private final class Box {
        var view: View?
        var animFps: Double = 10
    }

    init(noModeSwitch: Bool) {
        // 从 .app 包运行和命令行运行读写同一份设置
        let defaults: UserDefaults
        if Bundle.main.bundleIdentifier == "com.tensorfold.panel" {
            defaults = .standard
        } else {
            defaults = UserDefaults(suiteName: "com.tensorfold.panel")!
        }
        let settings = AppSettings(defaults: defaults)
        let config = settings.config()
        let ledger = UsageLedger(config: config)
        let collector = Collector(config: config, usage: ledger)
        let viewModel = ViewModel(config: config)
        let address = settings.address
        let key = settings.apiKey()
        let reader = OmlxReader(transport: URLSessionTransport(baseURL: address),
                                apiKey: key, maxStreams: omlxMaxStreams())
        let box = Box()
        box.animFps = config.animFps

        self.settings = settings
        self.config = config
        self.ledger = ledger
        self.collector = collector
        self.viewModel = viewModel
        self.reader = reader
        self.readerAddress = address
        self.readerKey = key
        self.box = box
        self.poller = Poller(source: reader, collector: collector)
        self.screens = ScreenManager(settings: settings, makeView: {
            PanelView(currentView: { box.view }, animFps: { box.animFps })
        }, noModeSwitch: noModeSwitch)
    }

    func start() {
        screens.onChange = { [weak self] in self?.onStatusChange?() }
        screens.start()
        // 快照在后台线程上交给主线程（只在这里碰读取器）
        let poller = self.poller
        poller.start { [poller, weak self] snapshot in
            let source = poller.source
            let issue = source.issue, ids = source.modelIDs, model = source.modelName
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(snapshot, issue: issue, modelIDs: ids, model: model) }
            }
        }
    }

    func stop() {
        poller.stop()
        ledger.flush()
        screens.stop()
    }

    /// 主线程：快照 → View；状态变了通知菜单，画面变了通知重画。
    private func deliver(_ snapshot: JSON, issue newIssue: EngineIssue, modelIDs newIDs: [String], model: String?) {
        var changed = false
        if newIssue != issue {
            issue = newIssue
            changed = true
            Log.write("引擎：\(newIssue.message ?? "已连接")")
        }
        if newIDs != modelIDs {
            modelIDs = newIDs
            changed = true
            settings.rememberModels(newIDs)
        }
        if model != currentModel {
            currentModel = model
            changed = true
        }
        if changed { onStatusChange?() }

        let v = viewModel.update(snapshot, now: monotonicNow())
        if v != view {
            box.view = v
            screens.redraw()
        }

        // API key 自动模式：引擎说要 key 时，每 5 秒重读一次设置/配置文件
        if settings.keyMode == .auto, newIssue == .needsKey {
            let now = monotonicNow()
            if now - keyCheckAt >= 5 {
                keyCheckAt = now
                let key = settings.apiKey()
                if key != readerKey { applyKey(key) }
            }
        }
    }

    /// 换 key 生效：交给轮询线程改读取器。
    private func applyKey(_ key: String?) {
        readerKey = key
        let poller = self.poller
        poller.perform {
            if let r = poller.source as? OmlxReader { r.apiKey = key; r.reset() }
        }
    }

    /// 菜单或设置窗口改了设置之后调，立刻生效。
    func settingsChanged() {
        config = settings.config()
        viewModel.config = config
        box.animFps = config.animFps
        let newConfig = config
        let ledger = self.ledger
        poller.perform { ledger.apply(config: newConfig) }

        let address = settings.address
        let key = settings.apiKey()
        if address != readerAddress {
            // 地址变了：整个读取器换掉
            let reader = OmlxReader(transport: URLSessionTransport(baseURL: address),
                                    apiKey: key, maxStreams: omlxMaxStreams())
            let poller = self.poller
            poller.perform { poller.source = reader }
            self.reader = reader
            readerAddress = address
            readerKey = key
        } else if key != readerKey {
            applyKey(key)
        }

        screens.settingsChanged()
        onStatusChange?()
    }
}
