// 副屏画面视图：480×320 画面等比缩放居中、四周涂黑；重画定时器按动画状态启停。
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
    private let drawer = LayerDrawer()

    init(currentView: @escaping () -> View?, animFps: @escaping () -> Double) {
        self.currentView = currentView
        self.animFps = animFps
        super.init(frame: .zero)
        // 自己管图层（先设 layer 再 wantsLayer）：图层直接调 drawer 画。
        // 走 NSView.draw(_:) 时 AppKit 每帧先录一遍绘制命令、再整屏回放一遍，解码时 CPU 占用要高好几倍
        let l = CALayer()
        l.isOpaque = true
        l.backgroundColor = NSColor.black.cgColor
        l.needsDisplayOnBoundsChange = true
        l.delegate = drawer
        layer = l
        wantsLayer = true
        drawer.owner = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 重画一次（下一次刷新屏幕时画）
    private func redraw() { layer?.setNeedsDisplay() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
        redraw()
    }

    /// 画一帧。ctx 是图层的，原点在左下角，size 是图层大小（点）。
    fileprivate func drawFrame(_ ctx: CGContext, size: CGSize) {
        ctx.setFillColor(NSColor.black.cgColor)
        guard let view = currentView() else {
            // 还没有任何画面：整块涂黑，停掉重画定时器
            ctx.fill(CGRect(origin: .zero, size: size))
            stopTimer()
            return
        }
        let frame = animator.step(view, now: monotonicNow())
        // 换成左上角原点、y 向下
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        // 480×320 画面按图层大小等比缩放居中，只把两边空出来的地方涂黑（画面自己会铺满底色）
        let s = min(size.width / 480, size.height / 320)
        let ox = (size.width - 480 * s) / 2
        let oy = (size.height - 320 * s) / 2
        ctx.fill([CGRect(x: 0, y: 0, width: size.width, height: oy),
                  CGRect(x: 0, y: size.height - oy, width: size.width, height: oy),
                  CGRect(x: 0, y: 0, width: ox, height: size.height),
                  CGRect(x: size.width - ox, y: 0, width: ox, height: size.height)])
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
                self?.redraw()
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
        if timer == nil { redraw() }
    }

    /// 窗口关掉时调。
    func stop() {
        stopTimer()
    }
}

/// 图层的绘制代理（图层的 delegate 不能是 NSView 自己，否则 AppKit 会接管绘制）
@MainActor
private final class LayerDrawer: NSObject, @preconcurrency CALayerDelegate {
    weak var owner: PanelView?

    func draw(_ layer: CALayer, in ctx: CGContext) {
        owner?.drawFrame(ctx, size: layer.bounds.size)   // 图层在主线程上画
    }

    /// 不要图层自带的隐式动画（换内容时的淡入淡出）
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}
