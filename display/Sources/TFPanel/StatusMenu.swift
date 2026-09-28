import AppKit
import ServiceManagement

/// 菜单栏图标与菜单（打开时刷新各项状态）。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem
    private let settings: Settings
    private let screenManager: ScreenManager
    private var screenRow: NSMenuItem!
    private var autoSwitchRow: NSMenuItem!
    private var loginItemRow: NSMenuItem!

    init(settings: Settings, screenManager: ScreenManager) {
        self.settings = settings
        self.screenManager = screenManager
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // SF Symbol 找不到就退化为文字 TF
        if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "TensorFold 副屏") {
            item.button?.image = image
        } else {
            item.button?.title = "TF"
        }

        let menu = NSMenu()
        menu.delegate = self

        let title = NSMenuItem(title: "TensorFold 副屏", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        screenRow = NSMenuItem(title: "副屏：未找到 \(settings.screenName)", action: nil, keyEquivalent: "")
        screenRow.isEnabled = false
        menu.addItem(screenRow)

        menu.addItem(.separator())

        autoSwitchRow = NSMenuItem(title: "自动切换到 960 × 640", action: #selector(toggleAutoSwitch), keyEquivalent: "")
        autoSwitchRow.target = self
        menu.addItem(autoSwitchRow)

        loginItemRow = NSMenuItem(title: "登录时启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItemRow.target = self
        menu.addItem(loginItemRow)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
    }

    /// 打开菜单时刷新各项状态。
    func menuWillOpen(_ menu: NSMenu) {
        let name = screenManager.screenName
        screenRow.title = screenManager.isConnected
            ? "副屏：已连接 \(name)"
            : "副屏：未找到 \(name)"
        autoSwitchRow.state = settings.autoSwitchMode ? .on : .off
        // 自动切换打开时，立即对已连接的副屏执行一次
        if settings.autoSwitchMode,
           screenManager.isConnected,
           let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            DisplayMode.switchIfNeeded(screen: screen)
        }
        loginItemRow.state = loginItemAvailable && SMAppService.mainApp.status == .enabled ? .on : .off
        loginItemRow.isEnabled = loginItemAvailable
    }

    /// SMAppService 只在从 .app 包运行时可用；直接跑二进制时该项禁用。
    private var loginItemAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    @objc private func toggleAutoSwitch() {
        settings.autoSwitchMode.toggle()
        autoSwitchRow.state = settings.autoSwitchMode ? .on : .off
        // 打开时立即对已连接的副屏执行一次
        if settings.autoSwitchMode,
           screenManager.isConnected,
           let screen = NSScreen.screens.first(where: { $0.localizedName == screenManager.screenName }) {
            DisplayMode.switchIfNeeded(screen: screen)
        }
    }

    @objc private func toggleLoginItem() {
        guard loginItemAvailable else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            loginItemRow.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch {
            print("TFPanel：登录项设置失败：\(error.localizedDescription)")
        }
    }
}
