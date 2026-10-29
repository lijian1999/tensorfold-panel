// JSON 值的解析、输出、相等（Mac 版新增）。
import Foundation
import Testing
@testable import PanelCore

@Suite struct TestJSON {
    @Test func test_parse_numbers() {
        #expect(JSON.parse("1") == .int(1))
        #expect(JSON.parse("1")?.int == 1)
        #expect(JSON.parse("1.0")?.int == nil)
        #expect(JSON.parse("1.0")?.number == 1.0)
        #expect(JSON.parse("-2.5e3")?.number == -2500)
        #expect(JSON.parse("true")?.number == nil)
        #expect(JSON.parse("true")?.bool == true)
    }

    @Test func test_parse_nested() {
        let v = JSON.parse(#"{"a": [1, 2.5, "中文\n", null, {"b": false}], "c": "é😀"}"#)
        #expect(v == ["a": [1, 2.5, "中文\n", .null, ["b": false]], "c": "é😀"])
        #expect(v?["a"]?[3]?.isNull == true)
        #expect(v?["missing"] == nil)
        #expect(v?["a"]?[9] == nil)
    }

    @Test func test_parse_invalid() {
        #expect(JSON.parse("") == nil)
        #expect(JSON.parse("{") == nil)
        #expect(JSON.parse("[1,]") == nil)
        #expect(JSON.parse("{\"a\":1} x") == nil)
        #expect(JSON.parse("nul") == nil)
    }

    @Test func test_equality_like_python() {
        #expect(JSON.int(1) == JSON.double(1.0))
        #expect(JSON.bool(true) != JSON.int(1))
        #expect(JSON.null != JSON.int(0))
    }

    @Test func test_serialized() {
        let v: JSON = ["b": 1, "a": [1.0, 0.597, "中\"文"], "c": .null, "d": true]
        #expect(v.serialized() == #"{"a": [1.0, 0.597, "中\"文"], "b": 1, "c": null, "d": true}"#)
        #expect(JSON.parse(v.serialized()) == v)
    }

    @Test func test_truthy_and_none() {
        #expect(!JSON.int(0).truthy)
        #expect(JSON.string("x").truthy)
        #expect(!JSON.array([]).truthy)
        let o: JSON = ["a": .null]
        #expect(o["a"].isNone)
        #expect(o["b"].isNone)
        #expect(!JSON.object(["a": 0])["a"].isNone)
    }
}
