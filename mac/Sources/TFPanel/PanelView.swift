// 副屏画面视图：480×320 画面等比缩放居中、四周涂黑；重画定时器按动画状态启停。
// 定时器逻辑照 panel/app.py 的 draw、frame_interval_ms、ensure_timer、stop_timer。
// T2：画面拆静态、动态两层，稳定帧只重画动态层（静态层缓存）。
import AppKit
import PanelCore
import PanelRender

final class PanelView: NSView {
    let renderer = Renderer()
    let animator = Animator()
    /// 取当前画面（由 AppController 给）
    let currentView: () -> View?
    /// 持续动画的帧率来源（由 AppController 给，用时限制在 1～60）
    let animFps: () -> Double

    private var timer: Timer?       // 重画定时器
    private var timerMs: Int?       // 当前定时器的间隔，毫秒
    private let staticDrawer = LayerDrawer(kind: .static)
    private let dynamicDrawer = LayerDrawer(kind: .dynamic)
    /// 静态层、动态层（动态层盖在静态层上面）
    private let staticLayer = CALayer()
    private let dynamicLayer = CALayer()
    /// 最近一拍的画面和帧：step 只在 tick() 里调一次，两层画的时候共用
    private var lastView: View?
    private var lastFrame: Frame?
    /// 静态层需要重画（画面数据或 backing scale 变了）
    private var staticDirty = true

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
        layer = l
        wantsLayer = true
        // 静态层在下面，动态层在上面
        staticLayer.isOpaque = true
        staticLayer.backgroundColor = NSColor.black.cgColor
        staticLayer.needsDisplayOnBoundsChange = true
        staticLayer.delegate = staticDrawer
        l.addSublayer(staticLayer)
        dynamicLayer.needsDisplayOnBoundsChange = true
        dynamicLayer.delegate = dynamicDrawer
        l.addSublayer(dynamicLayer)
        staticDrawer.owner = self
        dynamicDrawer.owner = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // 两个子层铺满容器，contentsScale 跟随窗口 backing scale
        let scale = window?.backingScaleFactor ?? 1
        for sub in [staticLayer, dynamicLayer] {
            sub.frame = bounds
            sub.contentsScale = scale
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 1
        for sub in [staticLayer, dynamicLayer] {
            sub.contentsScale = scale
        }
        // backing scale 变了：静态层要跟着重画
        staticDirty = true
        if timer == nil { tick() }
    }

    /// 走一拍：step 一次，按稳定与否安排两层重画，并启停定时器。
    private func tick() {
        let view = currentView()
        lastView = view
        guard let view else {
            // 还没有任何画面：停掉重画定时器。两层不在这里标脏——
            // 标脏会同步触发图层重画，图层里又走一拍，无画面时构成无界递归
            //（主线程被卡住，快照永远进不来，画面永远是空）。首帧由
            // needsDisplayOnBoundsChange / 之后的 viewChanged() 驱动。
            lastFrame = nil
            staticDirty = true
            stopTimer()
            return
        }
        // 动画每拍只 step 一次，两层共用这一帧
        let frame = animator.step(view, now: monotonicNow())
        lastFrame = frame
        if frame.isSettled {
            // 稳定帧：静态层只在标记脏了时重画，动态层每拍都重画
            if staticDirty {
                staticDirty = false
                staticLayer.setNeedsDisplay()
            }
            // 动态层只标动态元素的三个区域（480×320 逻辑坐标，铺满时 ×2 是像素）：
            // 状态条点、仪表环带（含 ghost、数值弧）、主数字和进度条块
            let scale = staticLayer.contentsScale
            markDynamic(CGRect(x: 14, y: 17, width: 172 + 11 * min(12, max(0, view.lanes.max)), height: 12), scale: scale)
            markDynamic(CGRect(x: 30, y: 48, width: 272, height: 276), scale: scale)
            markDynamic(CGRect(x: 14, y: 126, width: 304, height: 142), scale: scale)
            ensureTimer(frameIntervalMs(fps: animFps(), fadingIn: false))
        } else {
            // 非稳定帧：两层都重画（静态层画整帧、动态层清空）
            staticDirty = false
            staticLayer.setNeedsDisplay()
            dynamicLayer.setNeedsDisplay()
            // 正在淡入固定 33 毫秒，其余按配置帧率
            let fadingIn = min(frame.centerAlpha, frame.statsAlpha, frame.stripAlpha) < 1.0
            ensureTimer(frameIntervalMs(fps: animFps(), fadingIn: fadingIn))
        }
        if !frame.animating { stopTimer() }
    }

    /// 给动态层标一个逻辑坐标（480×320）脏区，换算成图层像素坐标。
    private func markDynamic(_ rect: CGRect, scale: CGFloat) {
        guard let boundsSize = layer?.bounds.size, boundsSize.width > 0 else {
            dynamicLayer.setNeedsDisplay()
            return
        }
        let s = min(boundsSize.width / 480, boundsSize.height / 320)
        let ox = (boundsSize.width - 480 * s) / 2
        let oy = (boundsSize.height - 320 * s) / 2
        // 图层坐标是点（原点左下），脏区按逻辑 480×320 的左上原点算：y 翻转
        let r = CGRect(x: (ox + rect.minX * s),
                       y: boundsSize.height - (oy + rect.maxY * s),
                       width: rect.width * s,
                       height: rect.height * s)
        dynamicLayer.setNeedsDisplay(r)
    }

    /// 画静态层或动态层。ctx 原点在左下角，size 是图层大小（点）。
    fileprivate func drawLayer(_ kind: LayerKind, _ ctx: CGContext, size: CGSize) {
        guard let view = lastView, let frame = lastFrame else {
            // 没有画面：静态层涂黑、动态层清空
            if kind == .static {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
            } else {
                ctx.clear(CGRect(origin: .zero, size: size))
            }
            return
        }
        // 换成左上角原点、y 向下
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        // 480×320 画面按图层大小等比缩放居中，只把两边空出来的地方涂黑（画面自己会铺满底色）
        let s = min(size.width / 480, size.height / 320)
        let ox = (size.width - 480 * s) / 2
        let oy = (size.height - 320 * s) / 2
        if kind == .static {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill([CGRect(x: 0, y: 0, width: size.width, height: oy),
                      CGRect(x: 0, y: size.height - oy, width: size.width, height: oy),
                      CGRect(x: 0, y: 0, width: ox, height: size.height),
                      CGRect(x: size.width - ox, y: 0, width: ox, height: size.height)])
        } else {
            // 动态层每帧先清空（非稳定帧时它必须保持透明）
            ctx.clear(CGRect(origin: .zero, size: size))
        }
        ctx.saveGState()
        ctx.translateBy(x: ox, y: oy)
        switch (kind, frame.isSettled) {
        case (.static, true):
            renderer.drawStatic(ctx, view: view, frame: frame, width: 480 * s, height: 320 * s)
        case (.dynamic, true):
            renderer.drawDynamic(ctx, view: view, frame: frame, width: 480 * s, height: 320 * s)
        case (.static, false):
            renderer.draw(ctx, view: view, frame: frame, width: 480 * s, height: 320 * s)
        case (.dynamic, false):
            break   // 已在上面清空
        }
        ctx.restoreGState()
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
                self?.tick()
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

    /// 画面内容变了时由 AppController 调：定时器没在跑时立刻走一拍
    ///（在跑时下一帧会用上新画面，不用额外重画）。
    func viewChanged() {
        staticDirty = true
        if timer == nil { tick() }
    }

    /// 窗口关掉时调。
    func stop() {
        stopTimer()
    }
}

/// 图层种类：静态层、动态层。
enum LayerKind {
    case `static`
    case dynamic
}

/// 图层的绘制代理（图层的 delegate 不能是 NSView 自己，否则 AppKit 会接管绘制）
@MainActor
private final class LayerDrawer: NSObject, @preconcurrency CALayerDelegate {
    let kind: LayerKind
    weak var owner: PanelView?

    init(kind: LayerKind) {
        self.kind = kind
    }

    func draw(_ layer: CALayer, in ctx: CGContext) {
        owner?.drawLayer(kind, ctx, size: layer.bounds.size)   // 图层在主线程上画
    }

    /// 不要图层自带的隐式动画（换内容时的淡入淡出）
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}