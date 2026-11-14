// 分时计价的测试：峰谷时段、节假日、官方 DeepSeek Flash 价目与旧模型名。
import Foundation
import Testing
@testable import PanelCore

/// 2026-11 day hh:mm:ss（北京时间）→ Unix 秒。
private func bj_ts(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    var comps = DateComponents()
    comps.year = 2026; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute
    return Double(cal.date(from: comps)!.timeIntervalSince1970)
}

@Suite struct TestPricePeriod {
    @Test func test_工作日高峰窗口() {
        // 周一 2026-11-09：9:00–12:00、14:00–18:00 是高峰
        #expect(pricePeriod(atUnix: bj_ts(11, 9, 9)) == .peak)
        #expect(pricePeriod(atUnix: bj_ts(11, 9, 11, 59)) == .peak)
        #expect(pricePeriod(atUnix: bj_ts(11, 9, 12)) == .offPeak, "12:00 边界算空闲")
        #expect(pricePeriod(atUnix: bj_ts(11, 9, 13, 59)) == .offPeak)
        #expect(pricePeriod(atUnix: bj_ts(11, 9, 14)) == .peak)
        #expect(pricePeriod(atUnix: bj_ts(11, 9, 17, 59)) == .peak)
        #expect(pricePeriod(atUnix: bj_ts(11, 9, 18)) == .offPeak, "18:00 边界算空闲")
    }

    @Test func test_周末全天空闲() {
        #expect(pricePeriod(atUnix: bj_ts(11, 15, 10)) == .offPeak)
        #expect(pricePeriod(atUnix: bj_ts(11, 15, 15)) == .offPeak)
    }

    @Test func test_法定节假日全天空闲() {
        // 2026-10-01（周四，国庆假期）10:00 原本是高峰窗口
        #expect(pricePeriod(atUnix: bj_ts(10, 1, 10)) == .offPeak)
        // 2026-10-08（周四）假期结束，10:00 回到高峰
        #expect(pricePeriod(atUnix: bj_ts(10, 8, 10)) == .peak)
        // 2027-02-10（周三，春节假期）10:00 空闲
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var c = DateComponents()
        c.year = 2027; c.month = 2; c.day = 10; c.hour = 10
        let ts = Double(cal.date(from: c)!.timeIntervalSince1970)
        #expect(pricePeriod(atUnix: ts) == .offPeak)
    }
}

@Suite struct TestOfficialFlashPrice {
    @Test func test_官方美元价() {
        let p = officialDeepSeekFlashPrice(currency: "$")!
        #expect(p.input == 0.15 && p.cached == 0.003 && p.output == 0.60)
        #expect(p.peakInput == 0.30 && p.peakCached == 0.006 && p.peakOutput == 1.20)
        #expect(p.hasPeak)
    }

    @Test func test_官方人民币价() {
        let p = officialDeepSeekFlashPrice(currency: "¥")!
        #expect(p.input == 1 && p.cached == 0.02 && p.output == 4)
        #expect(p.peakInput == 2 && p.peakCached == 0.04 && p.peakOutput == 8)
    }

    @Test func test_其它货币没有官方价() {
        #expect(officialDeepSeekFlashPrice(currency: "€") == nil)
    }

    @Test func test_新旧模型名都拿官方价() {
        for name in ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp",
                      "DeepSeek-V4.1-Flash-1017-Abliterated-MLX"] {
            let m = priceForUse(model: name, prices: [:], currency: "$")
            #expect(m?.official == true, "\(name) 应使用官方价目")
            #expect(m?.price.peakOutput == 1.20)
        }
        #expect(isDeepSeekFlashModel("DeepSeek-V4-Pro-0813") == false)
    }

    @Test func test_用户价覆盖官方价() {
        var prices: [String: ModelPrice] = [:]
        prices["deepseek-flash"] = ModelPrice(input: 0.2, cached: 0.01, output: 0.8)
        let m = priceForUse(model: "deepseek-flash", prices: prices, currency: "$")
        #expect(m?.official == false)
        #expect(m?.price.input == 0.2)
    }

    @Test func test_别名共用用户价() {
        var prices: [String: ModelPrice] = [:]
        prices["本地 Flash"] = ModelPrice(input: 0.2, cached: 0.01, output: 0.8,
                                            aliases: ["deepseek-v4-flash"])
        let m = priceForUse(model: "DEEPSEEK-V4-FLASH", prices: prices, currency: "¥")
        #expect(m?.official == false)
        #expect(m?.key == "本地 Flash")
        #expect(m?.price.output == 0.8)
    }

    @Test func test_名字只差大小写也能匹配() {
        var prices: [String: ModelPrice] = [:]
        prices["Qwen3.8-Flash"] = ModelPrice(input: 0.8, cached: 0.1, output: 2.7)
        let m = priceForUse(model: "qwen3.8-flash", prices: prices, currency: "¥")
        #expect(m?.price.input == 0.8)
    }
}
