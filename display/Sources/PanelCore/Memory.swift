import Foundation
import Darwin

/// 整机内存（已用 / 总量，GB 按 1024³ 换算，口径与活动监视器一致）。
public enum SystemMemory {
    public struct Sample: Sendable {
        public var usedGB: Double
        public var totalGB: Double
    }

    /// 读不到时返回 nil
    public static func read() -> (usedGB: Double, totalGB: Double)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let pageSize = Double(getpagesize())
        // 已用 =（不可压缩非 purge 内存 + 线用 + 压缩器占用）× 页大小，与活动监视器一致
        let usedPages = Double(stats.internal_page_count - stats.purgeable_count)
            + Double(stats.wire_count)
            + Double(stats.compressor_page_count)
        let usedGB = usedPages * pageSize / pow(1024, 3)

        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0 else { return nil }
        let totalGB = Double(total) / pow(1024, 3)

        return (usedGB: usedGB, totalGB: totalGB)
    }
}
