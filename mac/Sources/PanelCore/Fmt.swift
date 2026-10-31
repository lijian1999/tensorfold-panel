// 数字、时间的显示格式，行为和 panel/fmt.py 一致。
import Foundation

/// JS 的 Math.round：0.5 向上取整。
public func jsRound(_ x: Double) -> Int {
    Int((x + 0.5).rounded(.down))
}

/// token 数：先取整，再按量级换成 K / M。
public func tokFmt(_ value: Double) -> String {
    let n = jsRound(value)
    if n < 1000 { return String(n) }
    if n < 99950 { return String(format: "%.1fK", Double(n) / 1000) }
    if n < 999500 { return "\(jsRound(Double(n) / 1000))K" }
    if n < 9995000 { return String(format: "%.2fM", Double(n) / 1e6) }
    return String(format: "%.1fM", Double(n) / 1e6)
}

/// 一位小数拆成整数部分和小数部分，小数部分带小数点：62.3 → ("62", ".3")。
public func split1(_ x: Double) -> (String, String) {
    let s = String(format: "%.1f", x)
    let i = s.firstIndex(of: ".")!
    return (String(s[..<i]), String(s[i...]))
}

/// 费用：100 以上不带小数，其余两位小数。
public func costFmt(_ c: Double, currency: String = "$") -> String {
    if c >= 100 { return "\(currency)\(jsRound(c))" }
    return currency + String(format: "%.2f", c)
}

/// 货币的单位名：`$` 写“美元”、`¥` 写“人民币”，别的值原样显示。
public func currencyName(_ currency: String) -> String {
    if currency == "$" { return "美元" }
    if currency == "¥" { return "人民币" }
    return currency
}

/// 时长：秒 / 分钟 / 小时，向下取整。
public func durFmt(_ sec: Double) -> String {
    let x = max(0, Int(sec.rounded(.down)))
    if x < 60 { return "\(x) 秒" }
    if x < 3600 { return "\(x / 60) 分钟" }
    return "\(x / 3600) 小时"
}

/// "2026-10-03" → "10月3日"；解析不了就写“今日”。
public func dateLabel(_ date: String) -> String {
    let parts = date.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let m = Int(parts[1].trimmingCharacters(in: .whitespaces)),
          let d = Int(parts[2].trimmingCharacters(in: .whitespaces)) else { return "今日" }
    return "\(m)月\(d)日"
}

/// 百分比取整；总数为 0 或缺失时为 0。
public func pct(_ part: Double, _ whole: Double?) -> Int {
    guard let whole, whole != 0 else { return 0 }
    return jsRound(part / whole * 100)
}
