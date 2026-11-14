// 菜单文字规则的测试（MenuText）。
import Foundation
import Testing
@testable import PanelCore

@Suite struct TestMenuText {
    @Test func test_引擎一行() {
        #expect(engineMenuText(issue: .none, address: "127.0.0.1:8000", engine: "omlx") == "引擎：oMLX · 127.0.0.1:8000")
        #expect(engineMenuText(issue: .unreachable, address: "127.0.0.1:8000", engine: "omlx") == "引擎：未连接")
        #expect(engineMenuText(issue: .notOmlx, address: "127.0.0.1:8000", engine: "omlx") == "引擎：这个地址上不是 oMLX")
        #expect(engineMenuText(issue: .needsKey, address: "127.0.0.1:8000", engine: "omlx") == "引擎：oMLX 需要 API key · 在设置里填写")
        #expect(engineMenuText(issue: .none, address: "127.0.0.1:8080", engine: "tensorfold") == "引擎：TensorFold · 127.0.0.1:8080")
        #expect(engineMenuText(issue: .none, address: "127.0.0.1:8000", engine: "别的") == "引擎：oMLX · 127.0.0.1:8000")
    }

    @Test func test_时区标题() {
        #expect(zoneMenuTitles(systemZone: "Asia/Shanghai")
            == ["跟随系统（北京时间）", "北京时间", "太平洋时间"])
        #expect(zoneMenuTitles(systemZone: "Asia/Tokyo")[0] == "跟随系统（日本标准时间）")
    }

    @Test func test_费用单价标题() {
        let prices: [String: ModelPrice] = ["A": ModelPrice(input: 0.15, cached: 0.016, output: 0.47)]
        // 当前模型没填 → 带“（当前模型未填）”
        #expect(priceMenuTitle(currentModel: "B", prices: prices) == "费用单价…（当前模型未填）")
        // 填了 → 不带
        #expect(priceMenuTitle(currentModel: "A", prices: prices) == "费用单价…")
        // nil 或空串 → 不带
        #expect(priceMenuTitle(currentModel: nil, prices: prices) == "费用单价…")
        #expect(priceMenuTitle(currentModel: "", prices: prices) == "费用单价…")
    }
    @Test func test_官方价目也算填了() {
        // DeepSeek Flash 没填用户价，但内置官方价目算已填
        #expect(priceMenuTitle(currentModel: "deepseek-flash", prices: [:], currency: "¥")
            == "费用单价…")
    }

    @Test func test_别名也算填了() {
        let prices: [String: ModelPrice] = ["A": ModelPrice(input: 1, cached: 0.02, output: 4,
                                                              aliases: ["B"])]
        #expect(priceMenuTitle(currentModel: "B", prices: prices) == "费用单价…")
    }

}
