import AppKit
import PanelCore

// 占位：A2 实现（接口约定 9.5）
@MainActor final class AppController {
    let settings = AppSettings(defaults: .standard)
    let screens = ScreenManager()
    private(set) var issue: EngineIssue = .unreachable
    private(set) var modelIDs: [String] = []
    private(set) var currentModel: String? = nil
    var onStatusChange: (() -> Void)?
    func settingsChanged() {}
}
