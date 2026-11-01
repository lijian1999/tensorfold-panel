// 副屏与窗口管理：按名字找副屏 → 建窗口铺满；副屏消失 → 关窗口；屏幕参数变化 → 重新铺满。
// 窗口属性照第 1 版（git 6c9ad9a）：无边框、不抢焦点、不吃点击、盖住副屏菜单栏。
import AppKit
import CoreGraphics
import ImageIO
import PanelCore
import UniformTypeIdentifiers

/// 无边框全屏窗口：不抢焦点、不接收点击。
final class PanelWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// 不约束 frame：窗口必须恰好铺满整块屏幕（包括菜单栏区域，不留任何缩进）。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class ScreenManager {
    private let settings: AppSettings
    private let makeView: () -> PanelView   // 每次建窗口时调一次，得到内容视图
    private let noModeSwitch: Bool          // 本次运行不切显示模式

    /// 副屏名（来自设置；设置变了时由 settingsChanged 重新找屏）
    var screenName: String { settings.screenName }

    var onChange: (() -> Void)?             // 状态变了时调（菜单、设置窗口刷新用）
    private(set) var modeNote: String?      // 切不到 960 × 640 时的一句提示，否则 nil

    private var window: PanelWindow?
    private var panelView: PanelView?
    private var secondaryScreen: NSScreen?
    private var observer: Any?
    private var previewWindow: NSWindow?    // --window 的预览窗口
    private var previewView: PanelView?
    private var scannedName: String         // 上次找屏时用的屏幕名
    private var scannedAutoSwitch: Bool     // 上次找屏时的自动切换设置

    init(settings: AppSettings, makeView: @escaping () -> PanelView, noModeSwitch: Bool) {
        self.settings = settings
        self.makeView = makeView
        self.noModeSwitch = noModeSwitch
        self.scannedName = settings.screenName
        self.scannedAutoSwitch = settings.autoSwitchMode
    }

    /// 菜单栏显示的状态文字。
    var statusText: String {
        if let screen = secondaryScreen {
            return "\(screen.localizedName) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))"
        }
        return "未找到 \(screenName)"
    }

    /// 副屏是否已连接（菜单栏「副屏截图」能不能点）。
    var isSecondaryConnected: Bool { secondaryScreen != nil }

    func start() {
        rescan()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.observer = nil
        teardownWindow()
        closePreview()
    }

    /// 屏幕名或自动切换的设置变了就重新找屏。
    func settingsChanged() {
        if settings.screenName != scannedName || settings.autoSwitchMode != scannedAutoSwitch {
            rescan()
        }
    }

    /// 画面内容变了：通知现有的每个 PanelView。
    func redraw() {
        panelView?.viewChanged()
        previewView?.viewChanged()
    }

    /// 对已连接的副屏按设置切一次显示模式。
    func applyAutoSwitch() {
        guard let screen = secondaryScreen, !noModeSwitch else { return }
        applyMode(to: screen)
    }

    /// 菜单栏「副屏截图」：把副屏此刻真实显示的内容截成 PNG（真实像素，不是重画），
    /// 存到 ~/Library/Logs/TFPanel/（文件名带日期时间），存好后在 Finder 里定位，并写一行日志。
    /// 截屏用的是系统已标记弃用的 CG 老接口，实测 macOS 26 上不需要「屏幕录制」权限；
    /// 失败只写日志，不影响主功能。
    func captureScreenshot() {
        guard let screen = secondaryScreen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            Log.write("副屏截图失败：拿不到副屏")
            return
        }
        guard let image = CGDisplayCreateImage(displayID) else {
            Log.write("副屏截图失败：系统没有返回画面（截屏可能已被系统限制）")
            return
        }
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/TFPanel")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let path = (dir as NSString).appendingPathComponent("截图-\(formatter.string(from: Date())).png")
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            Log.write("副屏截图失败：无法创建 PNG 写入器")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            Log.write("副屏截图失败：\(path)")
            return
        }
        Log.write("副屏截图已保存：\(path)")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 在主屏上开一个普通的带标题栏预览窗口（给命令行 --window 用）。
    func showPreview() {
        guard previewWindow == nil else { return }
        let view = makeView()
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "TFPanel 预览"
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.center()
        w.makeKeyAndOrderFront(nil)
        previewWindow = w
        previewView = view
    }

    private func closePreview() {
        previewView?.stop()
        previewView = nil
        previewWindow?.orderOut(nil)
        previewWindow = nil
    }

    /// 副屏连接状态或属性变化时调用。
    private func rescan() {
        scannedName = settings.screenName
        scannedAutoSwitch = settings.autoSwitchMode
        let match = NSScreen.screens.first { $0.localizedName == screenName }
        if match === secondaryScreen {
            // 同一块屏：尺寸/位置可能变了，重新铺满
            if let match, window != nil {
                layout(to: match)
            }
            return
        }
        if let match {
            secondaryScreen = match
            if settings.autoSwitchMode && !noModeSwitch {
                applyMode(to: match)
            } else {
                modeNote = nil
            }
            // 先关旧窗口再建新窗口，避免副屏对象变化（如切换显示模式）时残留孤儿窗口
            teardownWindow()
            createWindow(on: match)
            Log.write("副屏已连接：\(match.localizedName)")
            onChange?()
        } else {
            let was = secondaryScreen
            secondaryScreen = nil
            teardownWindow()
            if modeNote != nil { modeNote = nil }
            if let was {
                Log.write("副屏已移除：\(was.localizedName)")
                onChange?()
            }
        }
    }

    /// 切一次显示模式并按结果更新提示；提示变了就调 onChange。
    private func applyMode(to screen: NSScreen) {
        let old = modeNote
        switch DisplayMode.switchIfNeeded(screen: screen) {
        case .noMode, .failed:
            modeNote = "切不到 960 × 640，请在“显示器”设置里手动选"
        case .already, .switched:
            modeNote = nil
        }
        if modeNote != old { onChange?() }
    }

    private func createWindow(on screen: NSScreen) {
        let view = makeView()
        let w = PanelWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.ignoresMouseEvents = true
        // 盖住副屏上的菜单栏
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.contentView = view
        // frame = 整块屏（包括菜单栏区域）
        w.setFrame(screen.frame, display: false)
        w.orderFrontRegardless()
        window = w
        panelView = view
    }

    private func layout(to screen: NSScreen) {
        guard let window, window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: true)
    }

    private func teardownWindow() {
        panelView?.stop()
        panelView = nil
        window?.orderOut(nil)
        window = nil
    }
}
