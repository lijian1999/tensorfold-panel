import AppKit

// 占位：A3 实现（接口约定 9.5）
enum SettingsPage: String, CaseIterable { case engine, price, screen }

@MainActor final class SettingsWindowController {
    init(controller: AppController) {}
    func show(page: SettingsPage) {}
}
