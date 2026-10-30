// 登录项（SMAppService），接口约定 9.5。只有从 .app 包运行时才可用。
import Foundation
import ServiceManagement

enum LoginItem {
    /// 从 .app 包运行时才可用
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static var enabled: Bool { available && SMAppService.mainApp.status == .enabled }

    /// 登记 / 取消登记，成功返回 true。
    static func set(_ on: Bool) -> Bool {
        guard available else { return false }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.write("登录项设置失败：\(error.localizedDescription)")
            return false
        }
    }
}
