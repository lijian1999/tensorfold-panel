import Foundation

/// 文本格式化，结果与原型 JS（docs/dashboard-prototype.html 的 `tokFmt` / `split1`）逐字一致。
public enum Format {
    /// token 数：先四舍五入；< 1000 原样整数；< 99950 一位小数加 K；否则整数 K。
    /// 1000→"1.0K"、6200→"6.2K"、12400→"12.4K"、99949→"99.9K"、99950→"100K"、262144→"262K"
    public static func tokFmt(_ n: Double) -> String {
        let v = Int64((n).rounded())
        if v < 1000 { return String(v) }
        if v < 99_950 { return fixed(Double(v) / 1000, 1) + "K" }
        return "\(Int64((Double(v) / 1000).rounded()))K"
    }

    /// 一位小数后在小数点处切开：58.2→("58", ".2")、109.64→("109", ".6")、7→("7", ".0")
    public static func split1(_ x: Double) -> (int: String, dec: String) {
        let s = fixed(x, 1)
        let i = s.firstIndex(of: ".")
        guard let i else { return (s, "") }
        return (String(s[s.startIndex..<i]), String(s[i...]))
    }

    /// 等同 JS 的 `toFixed(digits)`。
    public static func fixed(_ x: Double, _ digits: Int) -> String {
        guard digits >= 0 else { return "NaN" }
        let scale = pow(10, Double(digits))
        let r = (x * scale).rounded() / scale
        if digits == 0 { return String(Int64(r)) }
        return String(format: "%.\(digits)lf", r)
    }

    /// 去掉量化/格式后缀（从第一个匹配处截断，不区分大小写）：
    /// 以 `-` 开头的 MLX / GGUF / AWQ / GPTQ / EXL+数字 / 数字+bit / MTP / DFlash。
    /// "Qwen3.8-27B-MLX-4bit"→"Qwen3.8-27B"、"Llama-3-8B" 不变
    public static func shortModelName(_ s: String) -> String {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            guard chars[i] == "-" else { i += 1; continue }
            let rest = Array(chars[(i + 1)...])
            if prefixMatch(rest, "mlx") || prefixMatch(rest, "gguf")
                || prefixMatch(rest, "awq") || prefixMatch(rest, "gptq")
                || prefixMatch(rest, "mtp") || prefixMatch(rest, "dflash") {
                return String(chars[..<i])
            }
            // EXL 后跟任意数字
            if prefixMatch(rest, "exl") {
                var j = i + 1 + 3
                while j < chars.count, chars[j].isNumber { j += 1 }
                if j > i + 4 { return String(chars[..<i]) }
            }
            // 数字 + bit
            if i + 1 < chars.count, chars[i + 1].isNumber {
                var j = i + 1
                while j < chars.count, chars[j].isNumber { j += 1 }
                if j > i + 1, j + 3 <= chars.count, String(chars[j..<(j + 3)]) == "bit" {
                    return String(chars[..<i])
                }
            }
            i += 1
        }
        return s
    }

    /// 前缀不区分大小写匹配
    private static func prefixMatch(_ chars: [Character], _ prefix: String) -> Bool {
        let p = Array(prefix)
        guard chars.count >= p.count else { return false }
        for k in 0..<p.count where chars[k].lowercased() != p[k].lowercased() { return false }
        return true
    }
}
