import AppKit

// 占位：A2 实现（接口约定 9.5）
@MainActor final class ScreenManager {
    var statusText: String { "未找到 TYPE-C" }
    var modeNote: String? { nil }
    func applyAutoSwitch() {}
}
