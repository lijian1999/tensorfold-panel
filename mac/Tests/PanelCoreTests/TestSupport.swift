// 测试共用的小工具：仓库里的 fixtures、近似相等。
import Foundation
@testable import PanelCore

/// 仓库根目录（本文件在 mac/Tests/PanelCoreTests/ 下，往上四级）
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

let fixturesDir = repoRoot.appendingPathComponent("fixtures")

/// 读 fixtures/ 下的一个 JSON 文件，name 可以带子目录，例如 "decode.json"、"vllm/metrics-b.expect.json"
func loadFixture(_ name: String) -> JSON {
    let data = try! Data(contentsOf: fixturesDir.appendingPathComponent(name))
    return JSON.parse(data)!
}

/// 对应 unittest 的 assertAlmostEqual(a, b, places=places)：差值按 places 位小数四舍五入后为 0
func almostEqual(_ a: Double, _ b: Double, places: Int = 7) -> Bool {
    let scale = pow(10.0, Double(places))
    return ((a - b) * scale).rounded() == 0
}
