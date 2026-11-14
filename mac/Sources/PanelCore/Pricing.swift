// 计费时段与价目：官方价目（DeepSeek Flash）、旧模型名解析、用户自定义分时价。
//
// DeepSeek 的峰谷规则（2026-11-15 官方价目页）：北京时间周一至周五（不含中国
// 法定节假日）9:00–12:00、14:00–18:00 为高峰，其余时段及周末、节假日为空闲；
// 空闲价是高峰价的一半。官方价目同时给美元和人民币两组价，按设置里的货币取。
import Foundation

/// 一次计费落在哪个时段。
public enum PricePeriod: String, Sendable {
    case peak
    case offPeak
}

/// 一次单价匹配：用户自己填的优先，没填时 DeepSeek Flash 走内置官方价目。
public struct PriceMatch: Equatable, Sendable {
    public var price: ModelPrice
    public var official: Bool          // true = 内置官方价目，不是用户填的
    public var key: String             // 用户价的模型键；官方价是“DeepSeek Flash 官方价”

    public init(price: ModelPrice, official: Bool, key: String) {
        self.price = price
        self.official = official
        self.key = key
    }
}

/// 官方价目共用的旧模型名。deepseek-flash 是当前模型名，两个旧名字仍可调用。
public let deepSeekFlashAliases = ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"]

/// 判断一个模型名是不是 DeepSeek Flash（含旧名和本地加后缀的版本）。
/// 规则很保守：名字里同时有 deepseek 和 flash，且没有 pro；否则不当成 Flash。
public func isDeepSeekFlashModel(_ model: String) -> Bool {
    let n = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !n.isEmpty else { return false }
    return n.contains("deepseek") && n.contains("flash") && !n.contains("pro")
}

/// DeepSeek Flash 官方价目（按所选货币）。其它货币没有内置价，返回 nil。
public func officialDeepSeekFlashPrice(currency: String) -> ModelPrice? {
    if currency == "$" {
        return ModelPrice(input: 0.15, cached: 0.003, output: 0.60,
                           peakInput: 0.30, peakCached: 0.006, peakOutput: 1.20,
                           aliases: deepSeekFlashAliases)
    }
    if currency == "¥" {
        return ModelPrice(input: 1, cached: 0.02, output: 4,
                           peakInput: 2, peakCached: 0.04, peakOutput: 8,
                           aliases: deepSeekFlashAliases)
    }
    return nil
}

/// 模型名比较用的规范化：去掉首尾空白、转小写。价格键和别名都按这个比较。
public func normalizedModelName(_ model: String) -> String {
    model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// 一个模型的单价来源。用户填的价最优先（先同名，再按它写的别名）；
/// 都没有时，DeepSeek Flash 用内置官方价目。
public func priceForUse(model: String, prices: [String: ModelPrice],
                         currency: String) -> PriceMatch? {
    let target = normalizedModelName(model)
    // 1. 同名（原文或只差大小写/空白）
    for (key, price) in prices.sorted(by: { $0.key < $1.key }) {
        if normalizedModelName(key) == target {
            return PriceMatch(price: price, official: false, key: key)
        }
    }
    // 2. 某个价目里写了这个模型作别名
    for (key, price) in prices.sorted(by: { $0.key < $1.key }) {
        for alias in price.aliases ?? [] where normalizedModelName(alias) == target {
            return PriceMatch(price: price, official: false, key: key)
        }
    }
    // 3. DeepSeek Flash 官方价目
    if let official = officialDeepSeekFlashPrice(currency: currency), isDeepSeekFlashModel(model) {
        return PriceMatch(price: official, official: true, key: "DeepSeek Flash 官方价")
    }
    return nil
}

/// 北京时间日期（年、月、日）→ 一个可比较的整数。
private func ymd(_ date: Date) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let c = cal.dateComponents([.year, .month, .day], from: date)
    return c.year! * 10000 + c.month! * 100 + c.day!
}

/// 中国法定节假日放假区间（含首尾）。2026 / 2027 年的安排来自国务院办公厅通知；
/// 表里没有的年份只按“周末全天空闲”算，不猜未来的节假日。
private let holidayRanges: [(Int, Int)] = [
    // 2026（国办发明电〔2025〕7号）
    (20260101, 20260103),   // 元旦
    (20260215, 20260223),   // 春节
    (20260404, 20260406),   // 清明
    (20260501, 20260505),   // 劳动节
    (20260619, 20260621),   // 端午
    (20260925, 20260927),   // 中秋
    (20261001, 20261007),   // 国庆
    // 2027（国办发明电〔2026〕10号）
    (20270101, 20270103),   // 元旦
    (20270205, 20270213),   // 春节
    (20270403, 20270405),   // 清明
    (20270501, 20270505),   // 劳动节
    (20270609, 20270609),   // 端午
    (20270915, 20270915),   // 中秋
    (20271001, 20271007),   // 国庆
]

/// 这一天是不是中国法定节假日（按北京时间的日期）。
public func isChineseHoliday(_ date: Date) -> Bool {
    let d = ymd(date)
    return holidayRanges.contains { d >= $0.0 && d <= $0.1 }
}

/// Unix 秒 → 计费时段。按北京时间：周一至周五 9–12 点、14–18 点是高峰，
/// 节假日和周末全天空闲；12:00、18:00 这两个边界算空闲（区间右开）。
public func pricePeriod(atUnix seconds: Double) -> PricePeriod {
    let date = Date(timeIntervalSince1970: seconds)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let c = cal.dateComponents([.year, .month, .day, .weekday, .hour], from: date)
    // 1 = 周日，7 = 周六；2–6 是周一到周五
    guard let weekday = c.weekday, (2...6).contains(weekday), !isChineseHoliday(date) else {
        return .offPeak
    }
    let hour = c.hour ?? 0
    if (9..<12).contains(hour) || (14..<18).contains(hour) { return .peak }
    return .offPeak
}
