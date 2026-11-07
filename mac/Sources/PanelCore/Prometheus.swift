import Foundation

// Prometheus 文本格式（exposition format 0.0.4）解析：只认格式，不做语义。
// _sum/_count/_bucket 等一律当作普通指标族；读不通的样本（值不是普通十进制数）直接忽略。
// 不带标签的样本进 plain，带标签的样本按「第一个标签的值」索引进 labeled，后写的样本生效。
public struct PrometheusText: Sendable, Equatable {
    private var plain: [String: Double] = [:]
    private var labeled: [String: [String: Double]] = [:]

    public init(_ text: String) {
        // 按行扫描，不用正则；行内靠游标逐个读记号。
        // \r\n 在 Swift 里是一个字符（连在一起的 grapheme cluster），三种行尾都要认
        for line in text.split(omittingEmptySubsequences: false,
                               whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            addSample(Array(line))
        }
    }

    /// 该指标族不带标签的那个值；没有则 nil。
    public func number(_ family: String) -> Double? { plain[family] }

    /// 该指标族带标签的样本：第一个标签的值 → 数值；没有则空字典。
    public func numbers(_ family: String) -> [String: Double] { labeled[family] ?? [:] }

    // MARK: - 单行扫描

    private mutating func addSample(_ chars: [Character]) {
        var pos = 0

        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\r" }
        func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
        func isLetter(_ c: Character) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
        // 跳过空格/制表符，返回跳了几个（0 表示两个记号之间没有分隔）
        func skipSpace() -> Int {
            var n = 0
            while pos < chars.count, isSpace(chars[pos]) { pos += 1; n += 1 }
            return n
        }
        // 名字：指标族是 [a-zA-Z_:][a-zA-Z0-9_:]*（冒号在任何位置都行）；
        // 标签名是 [a-zA-Z_][a-zA-Z0-9_]*（不带冒号，数字打头不行）
        func scanName(isFamily: Bool) -> String? {
            guard pos < chars.count else { return nil }
            let first = chars[pos]
            guard isLetter(first) || first == "_" || (isFamily && first == ":") else { return nil }
            let start = pos
            pos += 1
            while pos < chars.count {
                let c = chars[pos]
                guard isLetter(c) || isDigit(c) || c == "_" || (isFamily && c == ":") else { break }
                pos += 1
            }
            return String(chars[start..<pos])
        }
        // 引号内的标签值：转义只认 \\、\"、\n，其余按字面量保留
        func scanLabelValue() -> String? {
            guard pos < chars.count, chars[pos] == "\"" else { return nil }
            pos += 1
            var value = ""
            while pos < chars.count {
                let c = chars[pos]
                if c == "\\" {
                    pos += 1
                    guard pos < chars.count else { return nil }
                    let escaped = chars[pos]
                    if escaped == "\\" || escaped == "\"" || escaped == "n" {
                        value.append(escaped == "n" ? "\n" : escaped)
                    } else {
                        value.append("\\")
                        value.append(escaped)
                    }
                    pos += 1
                } else if c == "\"" {
                    pos += 1
                    return value
                } else {
                    value.append(c)
                    pos += 1
                }
            }
            return nil  // 引号没闭合
        }
        // 数值：只接受普通十进制（可带正负号、小数点、e/E 指数），16 进制/inf/nan 一律不收
        func scanNumber() -> Double? {
            let start = pos
            if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { pos += 1 }
            var wholeDigits = 0
            while pos < chars.count, isDigit(chars[pos]) { pos += 1; wholeDigits += 1 }
            var fracDigits = 0
            if pos < chars.count, chars[pos] == "." {
                pos += 1
                while pos < chars.count, isDigit(chars[pos]) { pos += 1; fracDigits += 1 }
            }
            // 整数部分和小数部分至少要有一位数字（.5、5. 这类可以，单独的 - 或孤零零的 . 不行）
            if wholeDigits == 0 && fracDigits == 0 { return nil }
            // 可选指数：e/E 后面必须有数字，否则整个记号不算数（1e、1e+ 都不行）
            if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
                pos += 1
                if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { pos += 1 }
                var expDigits = 0
                while pos < chars.count, isDigit(chars[pos]) { pos += 1; expDigits += 1 }
                if expDigits == 0 { return nil }
            }
            if pos < chars.count && !isSpace(chars[pos]) { return nil }  // 记号后面还粘着别的内容
            guard let value = Double(String(chars[start..<pos])) else { return nil }
            return value.isFinite ? value : nil  // 溢出成 ±inf 的也不当样本
        }

        skipSpace()
        if pos >= chars.count { return }              // 空行
        if chars[pos] == "#" { return }               // 注释行（# HELP、# TYPE、其他注释都算）

        guard let family = scanName(isFamily: true) else { return }
        var gap = skipSpace()

        // 可选标签集：{name="value",name="value"}，{} 等于没有标签
        var labelValues: [String] = []
        if pos < chars.count, chars[pos] == "{" {
            pos += 1
            skipSpace()
            if pos < chars.count, chars[pos] == "}" {
                pos += 1
            } else {
                while true {
                    skipSpace()
                    guard scanName(isFamily: false) != nil else { return }
                    skipSpace()
                    guard pos < chars.count, chars[pos] == "=" else { return }
                    pos += 1
                    skipSpace()
                    guard let value = scanLabelValue() else { return }
                    labelValues.append(value)
                    skipSpace()
                    guard pos < chars.count else { return }
                    if chars[pos] == "," { pos += 1; continue }
                    if chars[pos] == "}" { pos += 1; break }
                    return
                }
            }
            gap = skipSpace()
        }

        // 值前面必须有空格或制表符（m1.0、m{a="1"}1 这种粘连的不算样本）
        guard gap > 0 else { return }
        guard let value = scanNumber() else { return }

        // 可选时间戳：只认纯数字整数；认了以后后面不能再有东西
        skipSpace()
        if pos < chars.count {
            var digits = 0
            while pos < chars.count, isDigit(chars[pos]) { pos += 1; digits += 1 }
            if digits == 0 { return }
            skipSpace()
            if pos < chars.count { return }
        }

        if labelValues.isEmpty {
            plain[family] = value
        } else {
            labeled[family, default: [:]][labelValues[0]] = value
        }
    }
}