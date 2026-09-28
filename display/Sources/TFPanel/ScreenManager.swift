import AppKit
import Foundation
import PanelCore
import SwiftUI

/// 无边框全屏窗口：不抢焦点、不接收点击。
final class PanelWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// 不约束 frame：窗口必须恰好铺满整块屏幕（包括菜单栏区域，不留任何缩进）。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 窗口内容：整块黑色，480×320 画面按屏幕等比缩放居中。
/// TimelineView 每 1/30 秒驱动 animator.tick；已静止时暂停，指标/内存变化仍触发重绘。
struct PanelWindowView: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        GeometryReader { geo in
            let fit = DisplayPolicy.fit(screenSize: geo.size)
            let s = fit.scale
            // 数据驱动的 body 求值时也推进一次动画，让 paused 用最新动画状态判断
            let _ = store.tickFrame()
            let _ = store.tick   // 注册 1 Hz 心跳依赖：内容不变时 body 每秒重算一次，保证 paused 及时生效
            ZStack(alignment: .topLeading) {
                Color.black
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: store.settled)) { _ in
                    PanelScreenView(model: store.model, frame: store.tickFrame(), scale: s)
                }
                .frame(width: DisplayPolicy.designSize.width * s, height: DisplayPolicy.designSize.height * s)
                .position(x: fit.origin.x + DisplayPolicy.designSize.width * s / 2,
                          y: fit.origin.y + DisplayPolicy.designSize.height * s / 2)
                // 调暗：整块画面 0.4 不透明度（调暗过渡 1 s，恢复 0.3 s）
                .opacity(store.dimmed ? 0.4 : 1.0)
                .animation(.easeInOut(duration: store.dimmed ? 1.0 : 0.3), value: store.dimmed)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

/// 副屏与窗口管理：
/// 按名字找副屏 → 建窗口；副屏消失 → 关窗口；尺寸变化 → 重新铺满。
/// 任何情况下都不在其他屏幕上显示窗口。同时负责调暗判断（记录当前状态从何时开始）。
@MainActor
final class ScreenManager {
    private let settings: Settings
    private let store: PanelStore
    /// 命令行 --screen 覆盖后的本次运行副屏名
    let screenName: String
    private var window: PanelWindow?
    private var secondaryScreen: NSScreen?
    private var observer: Any?
    /// 当前状态从何时开始（调暗用）
    private var lastState: PanelState?
    private var stateSince: Double = ProcessInfo.processInfo.systemUptime

    init(settings: Settings, store: PanelStore, screenName: String?) {
        self.settings = settings
        self.store = store
        self.screenName = screenName ?? settings.screenName
    }

    /// 当前是否找到副屏（菜单栏显示用）
    var isConnected: Bool { secondaryScreen != nil }

    /// 调试截图序号（capture-1.png、capture-2.png……）
    private var captureCount = 1

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
    }

    /// 副屏连接状态或属性变化时调用。
    private func rescan() {
        let match = NSScreen.screens.first { $0.localizedName == screenName }
        if match === secondaryScreen {
            // 同一块屏：尺寸/位置可能变了，重新铺满
            if let match, window != nil {
                layout(to: match)
            }
            refreshDim()
            return
        }
        if let match {
            secondaryScreen = match
            if settings.autoSwitchMode {
                DisplayMode.switchIfNeeded(screen: match)
            }
            stateSince = ProcessInfo.processInfo.systemUptime
            // 先关旧窗口再建新窗口，避免副屏对象变化（如切换显示模式）时残留孤儿窗口
            teardownWindow()
            createWindow(on: match)
            refreshDim()
        } else {
            secondaryScreen = nil
            teardownWindow()
        }
    }

    private func createWindow(on screen: NSScreen) {
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
        w.contentView = NSHostingView(rootView: PanelWindowView(store: store))
        // frame = 整块屏（包括菜单栏区域）
        w.setFrame(screen.frame, display: false)
        w.orderFrontRegardless()
        window = w
    }

    private func layout(to screen: NSScreen) {
        guard let window, window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: true)
    }

    private func teardownWindow() {
        window?.orderOut(nil)
        window = nil
    }

    /// 调试截图：把副屏窗口 contentView 当前画面写 PNG，返回文件路径；窗口不存在返回 nil。
    func debugCapture(to dir: URL) -> String? {
        guard let window, let view = window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("capture-\(captureCount).png")
        do {
            try png.write(to: url)
            captureCount += 1
            return url.path
        } catch {
            print("TFPanel：调试截图失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 指标/内存更新后刷新调暗状态（由 MetricsPoller 回调）。
    func refreshDim() {
        let now = ProcessInfo.processInfo.systemUptime
        let state = store.model.state
        if state != lastState {
            lastState = state
            stateSince = now
        }
        let dimmed = DisplayPolicy.dimmed(state: state, stateSince: stateSince, now: now)
        if store.dimmed != dimmed {
            store.dimmed = dimmed
        }
    }
}
