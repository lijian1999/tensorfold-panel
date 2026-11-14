// 分时单价编辑与旧格式解码的测试（PriceForm / ModelPrice）。
import Foundation
import Testing
@testable import PanelCore

@Suite struct TestPeakPriceForm {
    @Test func test_分时六项都填() {
        let r = parseEditedPrice(input: "1", cached: "0.02", output: "4",
                                  peakInput: "2", peakCached: "0.04", peakOutput: "8",
                                  tiered: true, aliases: "")
        #expect(r == .valid(ModelPrice(input: 1, cached: 0.02, output: 4,
                                       peakInput: 2, peakCached: 0.04, peakOutput: 8)))
    }

    @Test func test_分时缺高峰项() {
        let r = parseEditedPrice(input: "1", cached: "0.02", output: "4",
                                  peakInput: "2", peakCached: "", peakOutput: "8",
                                  tiered: true, aliases: "")
        #expect(r == .invalid)
    }

    @Test func test_平坦忽略高峰框() {
        let r = parseEditedPrice(input: "0.8", cached: "0.1", output: "2.7",
                                  peakInput: "99", peakCached: "99", peakOutput: "99",
                                  tiered: false, aliases: "")
        #expect(r == .valid(ModelPrice(input: 0.8, cached: 0.1, output: 2.7)))
    }

    @Test func test_全空是清空() {
        let r = parseEditedPrice(input: " ", cached: "", output: "",
                                  peakInput: "2", peakCached: "0.04", peakOutput: "8",
                                  tiered: true, aliases: "deepseek-v4-flash")
        #expect(r == .empty)
    }

    @Test func test_别名解析() {
        #expect(parseAliases(" deepseek-v4-flash ， deepseek-v4-flash-vision-exp ,, ")
            == ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"])
        #expect(parseAliases("a, A") == ["a", "A"], "只按完全相同去重")
        #expect(parseAliases("") == nil)
    }

    @Test func test_别名跟着单价保存() {
        let r = parseEditedPrice(input: "1", cached: "0.02", output: "4",
                                  peakInput: "2", peakCached: "0.04", peakOutput: "8",
                                  tiered: true, aliases: "deepseek-v4-flash, deepseek-v4-flash-vision-exp")
        guard case .valid(let p) = r else { Issue.record("应合法"); return }
        #expect(p.aliases == ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"])
        #expect(p.hasPeak)
    }

    @Test func test_旧JSON没有峰价也能decode() {
        let old = #"{"input":0.15,"cached":0.016,"output":0.47}"#.data(using: .utf8)!
        let p = try! JSONDecoder().decode(ModelPrice.self, from: old)
        #expect(p.input == 0.15 && p.output == 0.47)
        #expect(p.peakInput == nil && p.aliases == nil && !p.hasPeak)
    }

    @Test func test_分时价JSON往返() {
        let p = ModelPrice(input: 1, cached: 0.02, output: 4,
                            peakInput: 2, peakCached: 0.04, peakOutput: 8,
                            aliases: ["deepseek-v4-flash"])
        let data = try! JSONEncoder().encode(p)
        let q = try! JSONDecoder().decode(ModelPrice.self, from: data)
        #expect(q == p)
    }

    @Test func test_单独的峰价不算分时() {
        let p = ModelPrice(input: 1, cached: 0.02, output: 4, peakInput: 2)
        #expect(!p.hasPeak)
    }
}
