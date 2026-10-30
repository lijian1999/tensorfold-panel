// 副屏画面视图：整块涂黑，480×320 画面等比缩放居中；重画定时器按动画状态启停。
// 定时器逻辑照 panel/app.py 的 draw、frame_interval_ms、ensure_timer、stop_timer。
import AppKit
import PanelCore
import PanelRender

final class PanelView: NSView {
    let renderer = Renderer()
    let animator = Animator()
    /// 取当前画面（由 AppController 给）
    let currentView: () -> View?
    /// 持续动画的帧率来源（由 AppController 给，用时限制在 1～30）
    let animFps: () -> Double

    private var timer: Timer?       // 重画定时器
    private var timerMs: Int?       // 当前定时器的间隔，毫秒

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    init(currentView: @escaping () -> View?, animFps: @escaping () -> Double) {
        self.currentView = currentView
        self.animFps = animFps
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 画一帧。
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 整块涂黑
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        guard let view = currentView() else {
            // 还没有任何画面：到此为止，停掉重画定时器
            stopTimer()
            return
        }
        let frame = animator.step(view, now: monotonicNow())
        // 480×320 画面按 bounds 等比缩放居中
        let s = min(bounds.width / 480, bounds.height / 320)
        let ox = (bounds.width - 480 * s) / 2
        let oy = (bounds.height - 320 * s) / 2
        ctx.saveGState()
        ctx.translateBy(x: ox, y: oy)
        renderer.draw(ctx, view: view, frame: frame, width: 480 * s, height: 320 * s)
        ctx.restoreGState()
        // 正在动画就保证定时器在跑，静止就停掉
        if frame.animating {
            ensureTimer(frameIntervalMs(frame))
        } else {
            stopTimer()
        }
    }

    /// 这一帧之后隔多久画下一帧：正在淡入时 33 毫秒，其余按配置的帧率（限制在每秒 1 到 30 帧）。
    private func frameIntervalMs(_ frame: Frame) -> Int {
        if min(frame.centerAlpha, frame.statsAlpha, frame.stripAlpha) < 1.0 { return 33 }
        var fps = animFps()
        if fps.isNaN { fps = 10.0 }
        fps = max(1.0, min(30.0, fps))
        return max(33, Int((1000.0 / fps).rounded()))
    }

    /// 保证有一个间隔为 intervalMs 的重画定时器在跑（同一时刻不允许多个）。
    /// 间隔和正在跑的不一样：先停掉旧的，再按新间隔起一个。
    private func ensureTimer(_ intervalMs: Int) {
        if timer != nil {
            if timerMs == intervalMs { return }
            stopTimer()
        }
        let t = Timer(timeInterval: Double(intervalMs) / 1000.0, repeats: true) { [weak self] _ in
            // 定时器只加在 RunLoop.main 上，回调必在主线程
            MainActor.assumeIsolated {
                self?.needsDisplay = true
            }
        }
        // .common 模式：菜单打开时也不停
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerMs = intervalMs
    }

    /// 停掉重画定时器。
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        timerMs = nil
    }

    /// 画面内容变了时由 AppController 调：定时器没在跑时重画一次
    ///（在跑时下一帧会用上新画面，不用额外重画）。
    func viewChanged() {
        if timer == nil { needsDisplay = true }
    }

    /// 窗口关掉时调。
    func stop() {
        stopTimer()
    }
}
