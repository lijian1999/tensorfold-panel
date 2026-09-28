import Foundation
import PanelCore

/// 面板共享状态：连接状态机、内存、当前画面、动画器。全部在主线程（@MainActor）更新。
/// 由 MetricsPoller 写入；窗口视图（ScreenManager 创建）读取。
@MainActor
final class PanelStore: ObservableObject {
    /// 程序启动时间（ConnectionTracker 的兜底）
    let bootTime: Double
    /// /metrics 连接状态机
    var tracker: ConnectionTracker
    /// 整机内存（每 1 秒刷新一次；读不到为 nil）
    @Published var memory: (usedGB: Double, totalGB: Double)?
    /// 当前画面（视图直接渲染它）
    @Published var model: PanelViewModel
    /// 是否调暗（整块画面 0.4 不透明度）
    @Published var dimmed = false
    /// 动画器（视图每帧调用 tick）
    let animator = PanelAnimator()
    /// TimelineView 是否暂停（非 @Published：由视图每次 body 求值时更新，避免发布循环）
    var settled = false
    /// 1 Hz 心跳（驱动 body 重算，让 TimelineView 的 paused 及时更新；
    /// 静止时最多每秒一次视图重算，动画进行中不额外起作用）
    @Published var tick = 0

    init(bootTime: Double = ProcessInfo.processInfo.systemUptime) {
        self.bootTime = bootTime
        let t = ConnectionTracker(bootTime: bootTime)
        self.tracker = t
        let now = bootTime
        self.model = PanelViewModel.make(tracker: t, now: now, memory: nil)
    }

    /// 记录一次 /metrics 结果（成功 = 指标，失败 = nil），刷新画面。
    /// 内容没变时不重新赋值，避免触发无谓的 SwiftUI 重绘。
    func record(_ metrics: Metrics?, at t: Double) {
        if let metrics {
            tracker.recordSuccess(metrics, at: t)
        } else {
            tracker.recordFailure(at: t)
        }
        let newModel = PanelViewModel.make(tracker: tracker, now: t, memory: memory)
        if newModel != model {
            model = newModel
        }
    }

    /// 刷新一次内存（每 1 秒调用）。内容没变时不重新赋值。
    func updateMemory(at t: Double) {
        let sample = SystemMemory.read()
        if sample?.usedGB != memory?.usedGB || sample?.totalGB != memory?.totalGB {
            memory = sample
        }
        let newModel = PanelViewModel.make(tracker: tracker, now: t, memory: memory)
        if newModel != model {
            model = newModel
        }
        // 心跳：无论内容是否变化都发布，保证 TimelineView 的 paused 及时生效
        tick += 1
    }

    /// 数据驱动路径推进一次动画（视图 body 求值时调用）：
    /// 返回本帧动画量，并更新已静止状态（供 TimelineView 的 paused 判断）。
    func tickFrame() -> PanelAnimator.Frame {
        animator.tick(now: ProcessInfo.processInfo.systemUptime, model: model)
        settled = animator.isSettled
        return animator.frame
    }
}
