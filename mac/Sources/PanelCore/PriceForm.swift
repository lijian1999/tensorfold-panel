// 设置窗口“费用”一页的单价表：行的组成、输入框文字和单价的互转（纯逻辑）。
import Foundation

/// 单价表的一行。
public struct PriceRow: Equatable, Sendable {
    public var model: String
    public var present: Bool          // 在 oMLX 现在的模型列表里
    public var price: ModelPrice?

    public init(model: String, present: Bool, price: ModelPrice?) {
        self.model = model
        self.present = present
        self.price = price
    }
}

/// 单价表的行：现在的模型按原顺序在前（present = true）；
/// 以前用过的、填过单价的、现在不在列表里的排在后面，按名字排序（present = false）。
/// 同名只出现一次。
public func priceRows(current: [String], known: [String], prices: [String: ModelPrice]) -> [PriceRow] {
    var rows: [PriceRow] = []
    var seen = Set<String>()
    for m in current where !m.isEmpty {
        guard seen.insert(m).inserted else { continue }
        rows.append(PriceRow(model: m, present: true, price: prices[m]))
    }
    // 后半部分：known 和 prices.keys 的并集，去掉 current 里有的、去掉空名字，按 < 排序
    var rest = Set<String>()
    for m in known where !m.isEmpty { rest.insert(m) }
    for m in prices.keys where !m.isEmpty { rest.insert(m) }
    for m in current { rest.remove(m) }
    for m in rest.sorted(by: <) {
        rows.append(PriceRow(model: m, present: false, price: prices[m]))
    }
    return rows
}

/// 三个输入框的文字 → 单价的结果。
public enum PriceInput: Equatable, Sendable {
    case empty
    case valid(ModelPrice)
    case invalid
}

/// 三个输入框的文字 → 单价。
/// 去掉首尾空白后三个都是空串 → empty；三个都能转成有限的、不小于 0 的 Double → valid；其余 → invalid。
public func parsePrice(input: String, cached: String, output: String) -> PriceInput {
    let a = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let b = cached.trimmingCharacters(in: .whitespacesAndNewlines)
    let c = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if a.isEmpty && b.isEmpty && c.isEmpty { return .empty }
    guard let x = Double(a), let y = Double(b), let z = Double(c),
          x.isFinite, y.isFinite, z.isFinite, x >= 0, y >= 0, z >= 0 else {
        return .invalid
    }
    return .valid(ModelPrice(input: x, cached: y, output: z))
}

/// 单价显示成输入框里的文字：最多 6 位小数，去掉末尾的 0 和小数点。
public func priceText(_ value: Double) -> String {
    var s = String(format: "%.6f", value)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

/// 别名输入框 → 别名数组。
/// 用英文或中文逗号分隔，去掉首尾空白和空段，按原顺序去重；全是空 → nil。
public func parseAliases(_ text: String) -> [String]? {
    let pieces = text
        .replacingOccurrences(of: "，", with: ",")
        .split(separator: ",", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    var out: [String] = []
    var seen = Set<String>()
    for p in pieces where seen.insert(p).inserted { out.append(p) }
    return out.isEmpty ? nil : out
}

/// 编辑一行的六个单价框（分时计价时还要高峰三项）+ 别名框 → 单价。
/// 空闲三项（input/cached/output）与平坦计价的三个框同义。
/// 规则：
/// - 三个空闲框全空 → empty（分时的高峰框、别名框有字也当清空）；
/// - 分时：六个框都要是有限的、不小于 0 的数，否则 invalid；峰价三项存进峰值字段；
/// - 平坦：三个框都要合法，忽略高峰框，否则 invalid；
/// - 别名框按 parseAliases 存进 aliases；空就是 nil。
public func parseEditedPrice(input: String, cached: String, output: String,
                              peakInput: String, peakCached: String, peakOutput: String,
                              tiered: Bool, aliases: String) -> PriceInput {
    let a = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let b = cached.trimmingCharacters(in: .whitespacesAndNewlines)
    let c = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let pa = peakInput.trimmingCharacters(in: .whitespacesAndNewlines)
    let pb = peakCached.trimmingCharacters(in: .whitespacesAndNewlines)
    let pc = peakOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    if a.isEmpty && b.isEmpty && c.isEmpty { return .empty }
    let aliasesValue = parseAliases(aliases)
    if tiered {
        guard let x = Double(a), let y = Double(b), let z = Double(c),
              let px = Double(pa), let py = Double(pb), let pz = Double(pc),
              x.isFinite, y.isFinite, z.isFinite, px.isFinite, py.isFinite, pz.isFinite,
              x >= 0, y >= 0, z >= 0, px >= 0, py >= 0, pz >= 0 else {
            return .invalid
        }
        return .valid(ModelPrice(input: x, cached: y, output: z,
                                  peakInput: px, peakCached: py, peakOutput: pz,
                                  aliases: aliasesValue))
    }
    guard let x = Double(a), let y = Double(b), let z = Double(c),
          x.isFinite, y.isFinite, z.isFinite, x >= 0, y >= 0, z >= 0 else {
        return .invalid
    }
    return .valid(ModelPrice(input: x, cached: y, output: z, aliases: aliasesValue))
}
