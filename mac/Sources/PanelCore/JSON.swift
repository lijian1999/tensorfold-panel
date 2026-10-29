// JSON 值：读数、快照、账本文件都用它表示，对应 Python 版里的 dict / list / int / float / str / None。
import Foundation

public enum JSON: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

// MARK: - 取值（对应 Python 的 isinstance 判断）

extension JSON {
    /// 对象里的一个键；不是对象或没有这个键时为 nil。值为 null 时返回 `.null`（Python 的 `.get` 两种情况都是 None，用 `isNone` 判断）。
    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// 数组里的一个元素；不是数组或越界时为 nil。
    public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    /// 整数或小数（不含 bool），对应 `isinstance(v, (int, float)) and not isinstance(v, bool)`。
    public var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// 只认整数（不含 bool、不含小数），对应 `isinstance(v, int) and not isinstance(v, bool)`。
    public var int: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var double: Double? { number }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Python 的真值判断：None、False、0、0.0、空串、空列表、空字典为假，其余为真。
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }
}

extension Optional where Wrapped == JSON {
    /// 缺键或值为 null，对应 Python 的 `d.get(k) is None`。
    public var isNone: Bool {
        switch self {
        case .none: return true
        case .some(let v): return v.isNull
        }
    }
}

// MARK: - 相等：和 Python 一样，整数和小数按数值比较（1 == 1.0）；bool 不和数字相等

extension JSON: Equatable {
    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.int(x), .double(y)): return Double(x) == y
        case let (.double(x), .int(y)): return x == Double(y)
        case let (.double(x), .double(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)): return x == y
        default: return false
        }
    }
}

// MARK: - 字面量：测试里可以直接写 `let h: JSON = ["ok": true, "requests_total": 5, "epoch": .null]`
// 故意不支持 nil 字面量：JSON 的 null 一律写 `.null`，nil 只表示“没有这个值”

extension JSON: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

// MARK: - 和 Swift 值互转

extension JSON {
    public init(_ value: Int?) { self = value.map { .int($0) } ?? .null }
    public init(_ value: Double?) { self = value.map { .double($0) } ?? .null }
    public init(_ value: String?) { self = value.map { .string($0) } ?? .null }
    public init(_ value: Bool?) { self = value.map { .bool($0) } ?? .null }
}

// MARK: - 解析和输出

extension JSON {
    /// 解析 JSON 文本。整数（不带小数点和指数）解析成 `.int`，其余数字解析成 `.double`，和 Python 的 `json.loads` 一致。
    /// 不是合法 JSON 时返回 nil。顶层可以是任何值。
    public static func parse(_ data: Data) -> JSON? {
        var p = Parser(bytes: [UInt8](data))
        p.skipSpace()
        guard let v = p.value() else { return nil }
        p.skipSpace()
        guard p.i == p.bytes.count else { return nil }
        return v
    }

    public static func parse(_ text: String) -> JSON? { parse(Data(text.utf8)) }

    /// 输出 JSON 文本：键按字典序排列，不转义中文，小数用最短的能还原的写法（`0.1` 写成 `0.1`，`1.0` 写成 `1.0`）。
    public func serialized() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isFinite {
                // Swift 的 description 就是最短能还原的写法；整数值补上 ".0"，和 Python 一致
                var s = d.description
                if !s.contains(".") && !s.contains("e") && !s.contains("E") { s += ".0" }
                out += s
            } else {
                out += "null"
            }
        case .string(let s): JSON.writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (n, v) in a.enumerated() {
                if n > 0 { out += ", " }
                v.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (n, k) in o.keys.sorted().enumerated() {
                if n > 0 { out += ", " }
                JSON.writeString(k, to: &out)
                out += ": "
                o[k]!.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}

// 手写的解析器：JSONSerialization 分不清 1 和 1.0，这里要分清
private struct Parser {
    let bytes: [UInt8]
    var i = 0

    mutating func skipSpace() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    mutating func value() -> JSON? {
        skipSpace()
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string().map { .string($0) }
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return number()
        }
    }

    mutating func literal(_ word: String, _ v: JSON) -> JSON? {
        let w = [UInt8](word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { return nil }
        i += w.count
        return v
    }

    mutating func number() -> JSON? {
        let start = i
        var isInt = true
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        let digitsStart = i
        while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
        guard i > digitsStart else { return nil }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            isInt = false
            i += 1
            let f = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            guard i > f else { return nil }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            isInt = false
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            let e = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            guard i > e else { return nil }
        }
        guard let text = String(bytes: bytes[start..<i], encoding: .utf8) else { return nil }
        if isInt, let n = Int(text) { return .int(n) }
        return Double(text).map { .double($0) }
    }

    mutating func string() -> String? {
        guard bytes[i] == UInt8(ascii: "\"") else { return nil }
        i += 1
        var buf: [UInt8] = []
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                i += 1
                return String(bytes: buf, encoding: .utf8)
            }
            if b == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { return nil }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): buf.append(0x22)
                case UInt8(ascii: "\\"): buf.append(0x5C)
                case UInt8(ascii: "/"): buf.append(0x2F)
                case UInt8(ascii: "b"): buf.append(0x08)
                case UInt8(ascii: "f"): buf.append(0x0C)
                case UInt8(ascii: "n"): buf.append(0x0A)
                case UInt8(ascii: "r"): buf.append(0x0D)
                case UInt8(ascii: "t"): buf.append(0x09)
                case UInt8(ascii: "u"):
                    guard var code = hex4() else { return nil }
                    // 代理对
                    if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { return nil }
                    buf.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: return nil
                }
                continue
            }
            buf.append(b)
            i += 1
        }
        return nil
    }

    mutating func hex4() -> UInt32? {
        guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<i + 4], encoding: .ascii),
              let v = UInt32(s, radix: 16) else { return nil }
        i += 4
        return v
    }

    mutating func array() -> JSON? {
        i += 1
        var out: [JSON] = []
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
        while true {
            guard let v = value() else { return nil }
            out.append(v)
            skipSpace()
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
            return nil
        }
    }

    mutating func object() -> JSON? {
        i += 1
        var out: [String: JSON] = [:]
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
        while true {
            skipSpace()
            guard i < bytes.count, let k = string() else { return nil }
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            guard let v = value() else { return nil }
            out[k] = v
            skipSpace()
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
            return nil
        }
    }
}
