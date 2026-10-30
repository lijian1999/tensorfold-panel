// 日志：追加写 ~/Library/Logs/TFPanel.log，同时写标准错误。任何线程都能调，写失败不抛、不崩。
import Foundation

enum Log {
    private static let lock = NSLock()
    private static let path: String =
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/TFPanel.log")

    /// 启动时调一次：文件超过 1,000,000 字节先清空，再写一行「TFPanel 启动」。
    static func start() {
        let fm = FileManager.default
        if let attr = try? fm.attributesOfItem(atPath: path),
           let size = attr[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(atPath: path)
        }
        write("TFPanel 启动")
    }

    /// 追加一行「yyyy-MM-dd HH:mm:ss <message>」（本地时间）。
    static func write(_ message: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let data = Data(line.utf8)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(data)
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            // 文件还不存在：直接建一份
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
