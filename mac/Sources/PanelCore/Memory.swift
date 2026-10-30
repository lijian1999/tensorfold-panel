// 读整机内存（口径同活动监视器）和单调时钟。
import Foundation

/// 整机内存：{"used_gb": 已用, "total_gb": 总量}（GB 按 1024³）；读不到返回 nil。
public func readSystemMemory() -> JSON? {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    let pageSize = getpagesize()
    guard pageSize > 0 else { return nil }
    // 已用 = 内部页 - 可清除页 + 接线页 + 压缩页
    let usedPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        + Double(stats.wire_count) + Double(stats.compressor_page_count)
    let gb = 1024.0 * 1024.0 * 1024.0
    let usedGB = usedPages * Double(pageSize) / gb
    var memsize: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    guard sysctlbyname("hw.memsize", &memsize, &len, nil, 0) == 0 else { return nil }
    guard memsize > 0 else { return nil }
    let totalGB = Double(memsize) / gb
    return ["used_gb": .double(usedGB), "total_gb": .double(totalGB)]
}

/// 单调时钟（秒），给轮询和动画用。
public func monotonicNow() -> Double {
    ProcessInfo.processInfo.systemUptime
}
