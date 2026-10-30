// 翻译自 panel/tests/test_base.py：格式、刻度、配置默认值、视图数据结构。
// 配置文件、接口地址列表的测试不翻（Mac 版没有配置文件）。
import Foundation
import Testing
@testable import PanelCore

@Suite struct TestTokFmt {
    @Test func test_values() {
        let cases: [(Double, String)] = [
            (0, "0"), (999, "999"), (999.6, "1.0K"), (1000, "1.0K"), (6000, "6.0K"), (6249, "6.2K"),
            (24615, "24.6K"), (99949, "99.9K"), (99950, "100K"), (262144, "262K"), (999499, "999K"),
            (999500, "1.00M"), (8260391, "8.26M"), (9995000, "10.0M"), (12345678, "12.3M"),
        ]
        for (n, want) in cases {
            #expect(tokFmt(n) == want, "n=\(n)")
        }
    }
}

@Suite struct TestSplit1 {
    @Test func test_values() {
        #expect(split1(62.3) == ("62", ".3"))
        #expect(split1(97.2) == ("97", ".2"))
        #expect(split1(5) == ("5", ".0"))
        #expect(split1(107.64) == ("107", ".6"))
    }
}

@Suite struct TestCostFmt {
    @Test func test_values() {
        #expect(costFmt(0.597) == "$0.60")
        #expect(costFmt(0) == "$0.00")
        #expect(costFmt(99.994) == "$99.99")
        #expect(costFmt(100) == "$100")
        #expect(costFmt(1234.5) == "$1235")
        #expect(costFmt(1.5, currency: "¥") == "¥1.50")
    }
}

@Suite struct TestDurFmt {
    @Test func test_values() {
        let cases: [(Double, String)] = [
            (0, "0 秒"), (46.9, "46 秒"), (60, "1 分钟"), (132, "2 分钟"), (3599, "59 分钟"), (3600, "1 小时"), (-5, "0 秒"),
        ]
        for (sec, want) in cases {
            #expect(durFmt(sec) == want, "sec=\(sec)")
        }
    }
}

@Suite struct TestDateLabel {
    @Test func test_values() {
        #expect(dateLabel("2026-10-03") == "10月3日")
        #expect(dateLabel("2026-12-25") == "12月25日")
        #expect(dateLabel("") == "今日")
        #expect(dateLabel("x") == "今日")
    }
}

@Suite struct TestPct {
    @Test func test_values() {
        #expect(pct(5443627, 8260391) == 66)
        #expect(pct(0, 0) == 0)
        #expect(pct(1, nil) == 0)
        #expect(pct(40960, 61200) == 67)
    }
}

@Suite struct TestJsRound {
    @Test func test_values() {
        #expect(jsRound(0.5) == 1)
        #expect(jsRound(1.5) == 2)
        #expect(jsRound(2.5) == 3)
        #expect(jsRound(2.4) == 2)
    }
}

@Suite struct TestV2F {
    @Test func test_decode() {
        let cases: [(Double?, Double)] = [
            (0, 0), (-3, 0), (nil, 0), (25, 0.2), (50, 0.4), (74, 0.496), (100, 0.6), (150, 0.7), (200, 0.8), (300, 1), (500, 1),
        ]
        for (v, want) in cases {
            #expect(almostEqual(v2f(v, "decode"), want, places: 6), "v=\(String(describing: v))")
        }
    }

    @Test func test_prefill() {
        #expect(almostEqual(v2f(600, "prefill"), 0.2, places: 6))
        #expect(almostEqual(v2f(2412, "prefill"), 0.804, places: 6))
        #expect(almostEqual(v2f(3000, "prefill"), 1, places: 6))
    }

    @Test func test_scale_data() {
        #expect(tickFracs == [0.0, 0.2, 0.4, 0.6, 0.8, 1.0])
        #expect(scales["decode"]!.ticks == [0, 25, 50, 100, 200, 300])
        #expect(scales["prefill"]!.ticks == [0, 600, 1200, 1800, 2400, 3000])
        #expect(scales["decode"]!.labels == ["0", "25", "50", "100", "200", "300"])
        #expect(scales["prefill"]!.labels == ["0", "600", "1.2K", "1.8K", "2.4K", "3K"])
    }
}

@Suite struct TestConfig {
    @Test func test_defaults() {
        let c = Config()
        #expect(c.roundGapS == 60.0)
        #expect(c.prefillShortS == 3.0)
        #expect(c.doneHoldS == 4.0)
        #expect(c.dimAfterS == 1800.0)
        #expect(c.animFps == 10.0)
        #expect(c.timezone == "America/Los_Angeles")
        #expect(c.currency == "$")
        #expect(c.stateDir == "~/Library/Application Support/TFPanel")
        #expect(c.modelName == "Qwen3.8-Flash-Next")
    }
}

@Suite struct TestView {
    @Test func test_defaults() {
        let v = View()
        #expect(v.state == "idle")
        #expect(v.arc == "blank")
        #expect(v.cards == [])
        #expect(v.bar == nil)
        #expect(v.dim == 1.0)
    }

    @Test func test_round_trip() {
        var v = View()
        v.state = "decode"
        v.stateName = "解码中"
        v.stripLeft = "Qwen3.8-Flash-Next"
        v.stripRight = [Seg("新算 "), Seg("24.6K", "strong"), Seg(" tok")]
        v.lanes = Lanes(max: 6, decoding: 3, prefilling: 1, waiting: 2, offline: true)
        v.cap = "解码速度"
        v.unit = "tok/s"
        v.pill = true
        v.bigInt = "62"
        v.bigDec = ".3"
        v.bigWhole = true
        v.bigSize = "four"
        v.bigValue = 62.3
        v.arc = "value"
        v.scale = "prefill"
        v.arcTarget = 0.496
        v.ghost = 0.25
        v.muted = true
        v.bar = Bar(kind: "prog", frac: 0.6, level: "warn", text: [Seg("已算 "), Seg("6.2K", "warn")])
        v.cards = [Card("输出", "24.6K", "tok", "", false), Card("缓存命中", "66", "%", "4.0M / 6.1M", true),
                   Card("今日费用", "$0.60", "", "用时 2 分钟")]
        v.dim = 0.4
        v.slowFade = true
        #expect(View(json: v.toJSON()) == v)
        #expect(v.toJSON()["strip_right"]?[1]?.object != nil)
        #expect(v.toJSON()["lanes"]?.object != nil)
        #expect(v.toJSON()["bar"]?["text"]?[0]?.object != nil)
        // 输出再解析回来不变
        #expect(View(json: JSON.parse(v.toJSON().serialized())!) == v)
    }

    @Test func test_from_empty() {
        #expect(View(json: [:]) == View())
    }

    @Test func test_from_partial() {
        let v = View(json: ["bar": .null, "多余": 1, "cards": [["label": "输出"]]])
        #expect(v.cards.count == 1)
        #expect(v.cards[0] == Card("输出"))
        #expect(v.bar == nil)
        #expect(v.state == "idle")
    }
}
