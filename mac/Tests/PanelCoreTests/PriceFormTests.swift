// 单价表逻辑的测试（PriceForm）。
import Foundation
import Testing
@testable import PanelCore

@Suite struct TestPriceForm {
    @Test func test_行的顺序() {
        let priceA = ModelPrice(input: 0.15, cached: 0.016, output: 0.47)
        let priceD = ModelPrice(input: 1, cached: 2, output: 3)
        let rows = priceRows(current: ["B", "A"],
                             known: ["C", "A", ""],
                             prices: ["D": priceD, "A": priceA])
        #expect(rows == [
            PriceRow(model: "B", present: true, price: nil),
            PriceRow(model: "A", present: true, price: priceA),
            PriceRow(model: "C", present: false, price: nil),
            PriceRow(model: "D", present: false, price: priceD),
        ])
    }

    @Test func test_没有模型() {
        #expect(priceRows(current: [], known: [], prices: [:]) == [])
    }

    @Test func test_三个都空() {
        #expect(parsePrice(input: "", cached: " ", output: "") == .empty)
    }

    @Test func test_填对和填错() {
        #expect(parsePrice(input: "0.15", cached: "0.016", output: "0.47")
            == .valid(ModelPrice(input: 0.15, cached: 0.016, output: 0.47)))
        #expect(parsePrice(input: "0.15", cached: "", output: "0.47") == .invalid)
        #expect(parsePrice(input: "-1", cached: "0", output: "0") == .invalid)
        #expect(parsePrice(input: "abc", cached: "0", output: "0") == .invalid)
        #expect(parsePrice(input: "inf", cached: "0", output: "0") == .invalid)
        #expect(parsePrice(input: " 1 ", cached: "0", output: "2")
            == .valid(ModelPrice(input: 1, cached: 0, output: 2)))
    }

    @Test func test_单价文字() {
        #expect(priceText(0.15) == "0.15")
        #expect(priceText(1.0) == "1")
        #expect(priceText(0.016) == "0.016")
        #expect(priceText(0) == "0")
        #expect(priceText(2.5) == "2.5")
    }
}
