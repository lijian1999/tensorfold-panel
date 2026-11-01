// 菜单栏图标和菜单（接口约定 9.5）。打开时、或引擎/副屏状态变化时刷新各项。
import AppKit
import PanelCore

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let item: NSStatusItem
    /// 设置窗口由菜单持有
    private let settingsWindow: SettingsWindowController

    private var screenRow: NSMenuItem!
    private var noteRow: NSMenuItem!
    private var shotRow: NSMenuItem!
    private var engineRow: NSMenuItem!
    private var zoneSubmenu: NSMenu!
    private var priceRow: NSMenuItem!
    private var autoSwitchRow: NSMenuItem!
    private var loginRow: NSMenuItem!

    init(controller: AppController) {
        self.controller = controller
        self.settingsWindow = SettingsWindowController(controller: controller)
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // 图标照第 1 版：SF Symbol，找不到就写文字 TF
        if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                               accessibilityDescription: "TensorFold 副屏") {
            item.button?.image = image
        } else {
            item.button?.title = "TF"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false  // 各项能否点击由我们控制

        screenRow = NSMenuItem(title: "副屏", action: nil, keyEquivalent: "")
        screenRow.isEnabled = false
        menu.addItem(screenRow)

        noteRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")  // 切不到 960 × 640 时的提示
        noteRow.isEnabled = false
        noteRow.isHidden = true
        menu.addItem(noteRow)

        shotRow = NSMenuItem(title: "副屏截图（调试）", action: #selector(captureScreenshot), keyEquivalent: "")
        shotRow.target = self
        menu.addItem(shotRow)

        engineRow = NSMenuItem(title: "引擎", action: nil, keyEquivalent: "")
        engineRow.isEnabled = false
        menu.addItem(engineRow)

        menu.addItem(.separator())

        let zoneItem = NSMenuItem(title: "时区", action: nil, keyEquivalent: "")
        zoneSubmenu = NSMenu()
        zoneSubmenu.autoenablesItems = false
        zoneItem.submenu = zoneSubmenu
        menu.addItem(zoneItem)

        priceRow = NSMenuItem(title: "费用单价…", action: #selector(openPricePage), keyEquivalent: "")
        priceRow.target = self
        menu.addItem(priceRow)

        autoSwitchRow = NSMenuItem(title: "自动切换到 960 × 640", action: #selector(toggleAutoSwitch), keyEquivalent: "")
        autoSwitchRow.target = self
        menu.addItem(autoSwitchRow)

        loginRow = NSMenuItem(title: "登录时启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginRow.target = self
        menu.addItem(loginRow)

        let settingsRow = NSMenuItem(title: "设置…", action: #selector(openEnginePage), keyEquivalent: ",")
        settingsRow.target = self
        menu.addItem(settingsRow)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu

        // 状态回调只有一个，由 StatusMenu 设置，再转给设置窗口
        controller.onStatusChange = { [weak self] in
            self?.statusChanged()
        }
    }

    /// 打开菜单时刷新所有标题、勾选状态、提示行的有无。
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    /// AppController.onStatusChange 转过来：菜单开着就刷新，并转给设置窗口。
    func statusChanged() {
        refresh()
        settingsWindow.statusChanged()
    }

    private func refresh() {
        let s = controller.settings
        screenRow.title = "副屏：" + controller.screens.statusText
        if let note = controller.screens.modeNote {
            noteRow.title = note
            noteRow.isHidden = false
        } else {
            noteRow.isHidden = true
        }
        engineRow.title = engineMenuText(issue: controller.issue, address: s.address)
        // 副屏没接上时「副屏截图」置灰
        shotRow.isEnabled = controller.screens.isSecondaryConnected

        // 时区子菜单：三项，顺序同 ZoneChoice.allCases，当前的打勾
        zoneSubmenu.removeAllItems()
        let zones = ZoneChoice.allCases
        for (i, title) in zoneMenuTitles(systemZone: TimeZone.current.identifier).enumerated() {
            let it = NSMenuItem(title: title, action: #selector(pickZone(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.state = s.zone == zones[i] ? .on : .off
            zoneSubmenu.addItem(it)
        }

        priceRow.title = priceMenuTitle(currentModel: controller.currentModel, prices: s.prices)
        autoSwitchRow.state = s.autoSwitchMode ? .on : .off
        loginRow.state = LoginItem.enabled ? .on : .off
        loginRow.isEnabled = LoginItem.available
    }

    // MARK: - 动作

    @objc private func pickZone(_ sender: NSMenuItem) {
        controller.settings.zone = ZoneChoice.allCases[sender.tag]
        controller.settingsChanged()
    }

    @objc private func openPricePage() {
        settingsWindow.show(page: .price)
    }

    @objc private func openEnginePage() {
        settingsWindow.show(page: .engine)
    }

    /// 菜单栏「副屏截图」：截副屏真实显示，存盘后在 Finder 里定位（结果写日志）。
    @objc private func captureScreenshot() {
        controller.screens.captureScreenshot()
    }

    @objc private func toggleAutoSwitch() {
        controller.settings.autoSwitchMode.toggle()
        autoSwitchRow.state = controller.settings.autoSwitchMode ? .on : .off
        controller.settingsChanged()
        // 变成开的时候立刻对已连接的副屏切一次
        if controller.settings.autoSwitchMode {
            controller.screens.applyAutoSwitch()
        }
    }

    @objc private func toggleLoginItem() {
        let on = !LoginItem.enabled
        if LoginItem.set(on) {
            controller.settings.launchAtLogin = on
        }
        loginRow.state = LoginItem.enabled ? .on : .off
    }
}
