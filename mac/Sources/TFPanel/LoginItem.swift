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

// 兜底实现：A2 会在 Log.swift 里实现真正的 Log（任务 A2 第一步），合并后请删除这一段。
// 行为和 A2 约定一致：追加一行 `yyyy-MM-dd HH:mm:ss <消息>` 到 ~/Library/Logs/TFPanel.log，同时写标准错误；写失败不抛、不崩。
private enum Log {
    private static let lock = NSLock()

    static func write(_ message: String) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(df.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data("TFPanel：\(message)\n".utf8))
        lock.lock()
        defer { lock.unlock() }
        let path = ("~/Library/Logs" as NSString).expandingTildeInPath + "/TFPanel.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}
