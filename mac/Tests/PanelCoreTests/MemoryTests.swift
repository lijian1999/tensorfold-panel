// 整机内存读数。
import Foundation
import Testing
@testable import PanelCore

@Suite struct TestSystemMemory {
    @Test func test_读整机内存() {
        let m = readSystemMemory()
        #expect(m != nil)
        guard let m else { return }
        let used = m["used_gb"]?.number
        let total = m["total_gb"]?.number
        #expect(used != nil)
        #expect(total != nil)
        guard let used, let total else { return }
        #expect(total > 0)
        #expect(used > 0)
        #expect(used <= total)
    }
}
