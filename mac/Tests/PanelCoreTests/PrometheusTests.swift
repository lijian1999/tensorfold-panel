import Foundation
import Testing
@testable import PanelCore

/// TF1：Prometheus 文本格式解析（只看格式，不看语义）
@Suite struct TestPrometheus {

    // 普通十进制取值：整数、小数、负数、指数
    @Test func test_数值格式() {
        let p = PrometheusText("""
        simple_int 7
        a_decimal 3.14
        a_negative -42
        neg_decimal -0.25
        exp_form 1e5
        exp_upper 1E5
        exp_neg 1e-4
        neg_exp -1.5e10
        plus_sign +1
        leading_dot .5
        trailing_dot 5.
        zero 0
        neg_zero -0
        spaced_out\t 9 \t
        """)
        #expect(p.number("simple_int") == 7.0)
        #expect(p.number("a_decimal") == 3.14)
        #expect(p.number("a_negative") == -42.0)
        #expect(p.number("neg_decimal") == -0.25)
        #expect(p.number("exp_form") == 100_000.0)
        #expect(p.number("exp_upper") == 100_000.0)
        #expect(p.number("exp_neg") == 0.0001)
        #expect(p.number("neg_exp") == -1.5e10)
        #expect(p.number("plus_sign") == 1.0)
        #expect(p.number("leading_dot") == 0.5)
        #expect(p.number("trailing_dot") == 5.0)
        #expect(p.number("zero") == 0.0)
        #expect(p.number("spaced_out") == 9.0)
    }

    // Swift 自带的 Double(字符串) 读得通 16 进制和 inf/nan（大小写随意），解析器必须把它们当"读不通的取值"
    @Test func test_数值解析边界() {
        #expect(Double("0x10") == 16.0)      // Swift 认 16 进制
        #expect(Double("+Inf") == Double.infinity)
        #expect(Double("InF") == Double.infinity)  // inf 的拼写大小写随意
        #expect(Double("nan") != nil)        // nan 也读得通
        let p = PrometheusText("""
        hex_value 0x10
        inf_value +Inf
        neginf_value -Inf
        nan_value NaN
        bare_inf inf
        infinity_word infinity
        overflow 1e999
        bad_exponent 1e
        double_sign --1
        bad_decimal 1.5.5
        trailing_garbage 1abc
        empty_value
        only_name 1 extra
        """)
        for name in ["hex_value", "inf_value", "neginf_value", "nan_value", "bare_inf",
                     "infinity_word", "overflow", "bad_exponent", "double_sign",
                     "bad_decimal", "trailing_garbage", "empty_value", "only_name"] {
            #expect(p.number(name) == nil, "「\(name)」不该被收下")
        }
    }

    // +Inf / -Inf / NaN 与读不通的取值：整行不当样本
    @Test func test_特殊值与读不通的数值() {
        let p = PrometheusText("""
        gauge_inf +Inf
        gauge_neginf -Inf
        gauge_nan NaN
        gauge_ok 1
        """)
        #expect(p.number("gauge_inf") == nil)
        #expect(p.number("gauge_neginf") == nil)
        #expect(p.number("gauge_nan") == nil)
        #expect(p.number("gauge_ok") == 1.0)

        // 带标签的取值读不通：该行的标签取值也不留
        let q = PrometheusText("""
        series{lane="0"} NaN
        series{lane="1"} 2
        """)
        #expect(q.numbers("series") == ["1": 2.0])

        let r = PrometheusText("""
        only_lane{lane="3"} 3
        bad_lane{lane="4"} not_a_number
        """)
        #expect(r.numbers("only_lane")["3"] == 3.0)
        #expect(r.numbers("bad_lane").isEmpty)
    }

    // 以 # 打头的行与空行：整行忽略
    @Test func test_注释与空行() {
        let p = PrometheusText("""
        # TYPE tensorfold:lanes gauge
        # HELP tensorfold:lanes 池个数
        # 一行随便写的注释

        tensorfold:lanes 4

        \t
        # 注释夹在中间
        tail 1
        """)
        #expect(p.number("tensorfold:lanes") == 4.0)
        #expect(p.number("tail") == 1.0)
        // 注释行本身不产生任何指标族
        #expect(p.number("TYPE") == nil)
        #expect(p.numbers("tensorfold").isEmpty)
    }

    // 换行分隔行（兼容 CRLF），空格与制表符分隔记号
    @Test func test_换行与制表符() {
        let unix = PrometheusText("a 1\nb 2\nc 3")
        #expect(unix.number("a") == 1.0)
        #expect(unix.number("b") == 2.0)
        #expect(unix.number("c") == 3.0)

        // CRLF：行尾的 \r 不影响取值
        let crlf = PrometheusText("a 1\r\nb\t2\r\n")
        #expect(crlf.number("a") == 1.0)
        #expect(crlf.number("b") == 2.0)

        // 制表符当记号分隔符，取值后有多余空白
        let tabs = PrometheusText("\tfamily_name\t1.5\t")
        #expect(tabs.number("family_name") == 1.5)

        // 多行、取值相同的重复行（最后一行生效）
        let many = PrometheusText("x 1\nx 2\nx 3")
        #expect(many.number("x") == 3.0)
    }

    // 记号之间只认空格和制表符，别的字符不算分隔符
    @Test func test_非法空白() {
        // 取值后面紧跟别的字符：整行不算样本
        #expect(PrometheusText("m 1x").number("m") == nil)
        #expect(PrometheusText("m 1.5abc").number("m") == nil)
        // 取值和时间戳之间只粘了一个非空白字符
        #expect(PrometheusText("m 1,1760000000000").number("m") == nil)
        // 名和取值挤在一起：读不通
        #expect(PrometheusText("m1.0").number("m") == nil)
        #expect(PrometheusText("m{a=\"1\"}2").number("m") == nil)
    }

    // 行尾的整数时间戳：忽略
    @Test func test_时间戳() {
        let p = PrometheusText("""
        plain_stamp 11 1760000000000
        decimal_stamp -2.5e1 1760000000000
        labeled_stamp{lane="0"} 3 1760000000000
        tab_stamp 4\t1760000000000
        """)
        #expect(p.number("plain_stamp") == 11.0)
        #expect(p.number("decimal_stamp") == -25.0)
        #expect(p.numbers("labeled_stamp")["0"] == 3.0)
        #expect(p.number("tab_stamp") == 4.0)

        // 时间戳不是纯整数，或者后面还有东西：整行不算样本
        #expect(PrometheusText("m 1 12.5").number("m") == nil)
        #expect(PrometheusText("m 1 -5").number("m") == nil)
        #expect(PrometheusText("m 1 12 extra").number("m") == nil)
    }

    // 标签集与标签取值：指标族名相同、标签取值不同 → 按第一个标签取值分开存
    @Test func test_标签取值() {
        let p = PrometheusText("""
        tensorfold:kv_cache_usage_ratio{pool="0"} 0.11
        tensorfold:kv_cache_usage_ratio{pool="1"} 0.22
        tensorfold:kv_cache_usage_ratio{pool="3"} 0.5
        tensorfold:kv_cache_usage_perc{stream="default"} 0.5
        """)
        #expect(p.numbers("tensorfold:kv_cache_usage_ratio")["0"] == 0.11)
        #expect(p.numbers("tensorfold:kv_cache_usage_ratio")["1"] == 0.22)
        #expect(p.numbers("tensorfold:kv_cache_usage_ratio")["3"] == 0.5)
        #expect(p.numbers("tensorfold:kv_cache_usage_perc")["default"] == 0.5)
        // 带标签的行不会污染无标签的读法
        #expect(p.number("tensorfold:kv_cache_usage_ratio") == nil)

        // 多标签：只按第一个标签取值分开
        let q = PrometheusText("""
        server_info{model="A",backend="B",version="C"} 1
        http_requests_active{route="/v1/completions",method="POST"} 2
        """)
        #expect(q.numbers("server_info")["A"] == 1.0)
        #expect(q.numbers("http_requests_active")["/v1/completions"] == 2.0)

        // 空标签集 {} 等于没有标签
        let r = PrometheusText("""
        empty_labels{} 5
        """)
        #expect(r.number("empty_labels") == 5.0)
        #expect(r.numbers("empty_labels").isEmpty)

        // 同一族里既有无标签又有带标签：各存各的
        let mixed = PrometheusText("""
        both 1
        both{lane="0"} 2
        both{lane="1"} 3
        """)
        #expect(mixed.number("both") == 1.0)
        #expect(mixed.numbers("both") == ["0": 2.0, "1": 3.0])
    }

    // 标签取值里的转义：\\ \" \n 三种，别的反斜杠组合原样留着
    @Test func test_标签转义() {
        let p = PrometheusText(#"""
        esc{le="1.5"} 1
        quote{path="a\"b"} 2
        backslash{path="a\\b"} 3
        newline{path="a\nb"} 4
        raw_t{n="\t"} 5
        raw_x{n="\x"} 6
        mixed{n="a\\\"b"} 7
        """#)
        #expect(p.numbers("esc")["1.5"] == 1.0)
        #expect(p.numbers("quote")["a\"b"] == 2.0)
        #expect(p.numbers("backslash")["a\\b"] == 3.0)
        #expect(p.numbers("newline")["a\nb"] == 4.0)
        #expect(p.numbers("raw_t")["\\t"] == 5.0)
        #expect(p.numbers("raw_x")["\\x"] == 6.0)
        #expect(p.numbers("mixed")["a\\\"b"] == 7.0)
    }

    // 标签取值里可以出现空格、花括号、等号、逗号等特殊字符
    @Test func test_标签取值里的字符() {
        let p = PrometheusText(#"""
        sp{le="a b"} 1
        braces{le="{x}"} 2
        eq{le="a=b"} 3
        comma{le="a,b"} 4
        colon{le="a:b"} 5
        utf8{le="中文"} 6
        inf_le{le="+Inf"} 7
        empty_value_le{le=""} 8
        """#)
        #expect(p.numbers("sp")["a b"] == 1.0)
        #expect(p.numbers("braces")["{x}"] == 2.0)
        #expect(p.numbers("eq")["a=b"] == 3.0)
        #expect(p.numbers("comma")["a,b"] == 4.0)
        #expect(p.numbers("colon")["a:b"] == 5.0)
        #expect(p.numbers("utf8")["中文"] == 6.0)
        #expect(p.numbers("inf_le")["+Inf"] == 7.0)
        #expect(p.numbers("empty_value_le")[""] == 8.0)
    }

    // 指标族名：字母、数字、下划线、冒号，首字符不能是数字
    @Test func test_指标族名() {
        let p = PrometheusText("""
        tensorfold:kv_cache_usage_ratio 0.5
        node:cpu_seconds_total 1
        plain_name 2
        name123 3
        _under 4
        :colon_first 5
        a:b_c-d.e 6
        """)
        #expect(p.number("tensorfold:kv_cache_usage_ratio") == 0.5)
        #expect(p.number("node:cpu_seconds_total") == 1.0)
        #expect(p.number("plain_name") == 2.0)
        #expect(p.number("name123") == 3.0)
        #expect(p.number("_under") == 4.0)
        #expect(p.number(":colon_first") == 5.0)
        // 名字里出现连字符：读到 "a:b_c" 为止，后面粘着 "-d.e"，整行不算样本
        #expect(p.number("a:b_c-d.e") == nil)
        #expect(p.number("a:b_c") == nil)

        // 数字打头不算指标族名
        let bad = PrometheusText("1bad 7")
        #expect(bad.number("1bad") == nil)
        #expect(bad.numbers("1bad").isEmpty)
    }

    // 格式不对的样本行：整行不算样本，但同一文本里别的行照常解析
    @Test func test_畸形样本() {
        let cases = [
            "",
            "   ",
            "# 注释",
            "no_value",
            "name_only_but_with_label{lane=\"0\"}",
            "no_name 1",
            "1bad 1",
            "bad{lane=0} 1",              // 标签取值没加引号
            "bad{lane=\"0\"} x 1",        // 取值不是数
            "bad{lane=\"0\"}1",           // 标签集后面没有分隔符
            "bad{lane=\"unclosed} 1",    // 引号没闭合
            "bad{lane=\"0\" 1}",          // 花括号没闭合
            "bad{,} 1",
            "bad{lane=\"0\",} 1",         // 逗号后面缺标签
            "bad{=\"0\"} 1",              // 缺标签名
            "中文族名 1",
            "m 1 2 3",
        ]
        for line in cases {
            #expect(PrometheusText(line).numbers("bad").isEmpty, "\(line)")
        }
        // 畸形行不影响同一文本里的正常行
        let mixed = PrometheusText("good 1\nbad{lane=0} 2\ngood_more{lane=\"0\"} 3")
        #expect(mixed.number("good") == 1.0)
        #expect(mixed.numbers("good_more")["0"] == 3.0)
    }

    // 同一指标族 + 同一标签取值重复出现：后面写的生效
    @Test func test_重复样本后写生效() {
        let plain = PrometheusText("dup 1\ndup 2\ndup 3")
        #expect(plain.number("dup") == 3.0)

        let labeled = PrometheusText("""
        dup{lane="0"} 1
        dup{lane="0"} 2
        dup{lane="1"} 10
        dup{lane="0"} 3
        """)
        #expect(labeled.numbers("dup")["0"] == 3.0)
        #expect(labeled.numbers("dup")["1"] == 10.0)

        // 无标签的重复与带标签的重复互不影响
        let both = PrometheusText("x 1\nx{a=\"0\"} 2\nx 9\nx{a=\"0\"} 8")
        #expect(both.number("x") == 9.0)
        #expect(both.numbers("x")["0"] == 8.0)
    }

    // 文本里没有的指标族：number 返回 nil，numbers 返回空字典
    @Test func test_缺失指标族() {
        let p = PrometheusText("present 1\npresent{lane=\"0\"} 2")
        #expect(p.number("present") == 1.0)
        #expect(p.numbers("present")["0"] == 2.0)
        #expect(p.number("absent") == nil)
        #expect(p.numbers("absent").isEmpty)
        // 只有带标签的样本时，无标签的读法也是 nil
        let onlyLabeled = PrometheusText("labeled{lane=\"0\"} 1")
        #expect(onlyLabeled.number("labeled") == nil)
        #expect(onlyLabeled.numbers("labeled").isEmpty == false)
    }

    // 空文本：什么都不给
    @Test func test_空文本() {
        let empty = PrometheusText("")
        #expect(empty.number("anything") == nil)
        #expect(empty.numbers("anything").isEmpty)

        let onlyComments = PrometheusText("# TYPE x gauge\n# HELP x 说明\n\n")
        #expect(onlyComments.number("x") == nil)
        #expect(onlyComments.numbers("x").isEmpty)
    }

    // 真实快照样例：每段 /metrics 响应体都能解析，关键家族都在
    @Test func test_fixtures_全部可解析() throws {
        for name in ["tensorfold/idle.jsonl", "tensorfold/scenarios.jsonl"] {
            let bodies = try metricsBodies(name)
            #expect(!bodies.isEmpty, "\(name) 里应该有 /metrics 响应体")
            for (i, body) in bodies.enumerated() {
                let p = PrometheusText(body)
                #expect(p.number("tensorfold:process_start_time_seconds") != nil,
                        "\(name) 第 \(i) 段缺 process_start_time_seconds")
                #expect(p.numbers("tensorfold:server_info").count == 1,
                        "\(name) 第 \(i) 段 server_info 不止一条")
                #expect(p.numbers("tensorfold:kv_cache_usage_ratio").count <= 8,
                        "\(name) 第 \(i) 段 kv_cache_usage_ratio 太多")
            }
        }
    }

    // 独立模型对照：用一个不共享实现的正则扫描器把每段正文再扫一遍，两边结果必须一致；
    // 模型不认的行，解析器也必须整行忽略
    @Test func test_与独立扫描模型对照() throws {
        var checkedSamples = 0
        for name in ["tensorfold/idle.jsonl", "tensorfold/scenarios.jsonl"] {
            for body in try metricsBodies(name) {
                let parsed = PrometheusText(body)
                // 整段：模型按「后写生效」聚合出的每个家族，解析器必须一模一样
                var plain: [String: Double] = [:]
                var labeled: [String: [String: Double]] = [:]
                for s in scanModel(body) {
                    if let labelValue = s.labelValue {
                        labeled[s.family, default: [:]][labelValue] = s.value
                    } else {
                        plain[s.family] = s.value
                    }
                    checkedSamples += 1
                }
                for (family, expected) in plain {
                    #expect(parsed.number(family) == expected, "\(name) \(family)")
                }
                for (family, expected) in labeled {
                    #expect(parsed.numbers(family) == expected, "\(name) \(family)")
                }
                // 逐行：模型认下的样本，单独喂给解析器也得给出同样的结果
                for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
                    let text = String(raw)
                    let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                    if let s = scanModel(text).first {
                        let alone = PrometheusText(text)
                        if let labelValue = s.labelValue {
                            #expect(alone.numbers(s.family)[labelValue] == s.value, "\(text.prefix(160))")
                        } else {
                            #expect(alone.number(s.family) == s.value, "\(text.prefix(160))")
                        }
                    } else {
                        // 模型不认的行，解析器也必须整行忽略（状态和空文本完全一样）
                        #expect(PrometheusText(text) == PrometheusText(""), "\(text.prefix(160))")
                    }
                }
            }
        }
        #expect(checkedSamples > 100)
    }
}

// MARK: - 测试用的独立模型：自己按格式扫一遍，不用解析器

private struct ModelSample {
    var family: String
    var labelValue: String?
    var value: Double
}

/// 整行：族名 + 可选标签表 + 数值 + 可选整数时间戳
private let modelLinePattern = try! NSRegularExpression(
    pattern: #"^[ \t]*([a-zA-Z_:][a-zA-Z0-9_:]*)[ \t]*(?:\{([^}]*)\})?[ \t]+([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)(?:[ \t]+[0-9]+)?[ \t]*$"#)

/// 按 TF1 的格式规则独立扫一遍文本，返回应当被收下的样本
private func scanModel(_ text: String) -> [ModelSample] {
    var result: [ModelSample] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = modelLinePattern.firstMatch(in: line, range: range),
              let family = modelSubstring(line, match.range(at: 1)),
              let token = modelSubstring(line, match.range(at: 3)) else { continue }
        // Double(_:) 认字面量 inf / nan（格式里没有），按格式规则不算样本
        guard let value = Double(token), value.isFinite else { continue }
        var labelValue: String? = nil
        if match.range(at: 2).location != NSNotFound {
            let labels = modelSubstring(line, match.range(at: 2)) ?? ""
            let parsed = modelLabels(labels)
            guard parsed.ok else { continue }
            labelValue = parsed.firstValue
        }
        result.append(ModelSample(family: family, labelValue: labelValue, value: value))
    }
    return result
}

private func modelSubstring(_ text: String, _ range: NSRange) -> String? {
    let ns = text as NSString
    guard range.location != NSNotFound,
          range.location >= 0, range.length >= 0,
          range.location + range.length <= ns.length else { return nil }
    return ns.substring(with: range) as String
}

/// 扫标签表（不含两侧花括号）：合法与否，加上第一个标签的取值
private func modelLabels(_ labels: String) -> (ok: Bool, firstValue: String?) {
    let chars = Array(labels.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")))
    var pos = 0
    var first: String? = nil
    if chars.isEmpty { return (true, nil) }  // {} 或只有空格：等于没有标签
    var ignored = ""
    while true {
        guard scanModelName(chars, &ignored, &pos) != nil else { return (false, nil) }
        pos = skipModelSpace(chars, pos)
        guard pos < chars.count, chars[pos] == "=" else { return (false, nil) }
        pos = skipModelSpace(chars, pos + 1)
        guard pos < chars.count, chars[pos] == "\"" else { return (false, nil) }
        guard let value = scanModelLabelValue(chars, &pos) else { return (false, nil) }
        if first == nil { first = value }
        pos = skipModelSpace(chars, pos)
        if pos >= chars.count { return (true, first) }  // 扫到内串末尾（'}' 不在捕获组里）＝合法收尾
        if chars[pos] == "," { pos += 1; continue }
        return (false, nil)  // 逗号后面没标签、多余字符等
    }
}

private func skipModelSpace(_ chars: [Character], _ from: Int) -> Int {
    var i = from
    while i < chars.count, chars[i] == " " || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
    return i
}

/// 标签名（不含冒号，数字打头不行）
private func scanModelName(_ chars: [Character], _ name: inout String, _ pos: inout Int) -> String? {
    guard pos < chars.count else { return nil }
    let head = chars[pos]
    guard head.isASCII, head == "_" || head.isLetter else { return nil }
    let start = pos
    pos += 1
    while pos < chars.count {
        let c = chars[pos]
        guard c.isASCII, c == "_" || c.isNumber || c.isLetter else { break }
        pos += 1
    }
    name = String(chars[start..<pos])
    return name
}

/// pos 停在开引号上；只解 \\ \" \n 三种转义；引号未闭合返回 nil
private func scanModelLabelValue(_ chars: [Character], _ pos: inout Int) -> String? {
    var i = pos + 1
    var out = ""
    while i < chars.count {
        let c = chars[i]
        if c == "\"" { pos = i + 1; return out }
        if c == "\\" {
            guard i + 1 < chars.count else { return nil }
            let next = chars[i + 1]
            if next == "\\" { out.append("\\"); i += 2; continue }
            if next == "\"" { out.append("\""); i += 2; continue }
            if next == "n" { out.append("\n"); i += 2; continue }
            out.append("\\"); out.append(next); i += 2; continue
        }
        out.append(c)
        i += 1
    }
    return nil
}

/// 读 fixtures 下的一个 jsonl（一行一个 JSON，单行可能极长），返回 status 200 且 ep 为 /metrics 的 body
private func metricsBodies(_ name: String) throws -> [String] {
    let url = fixturesDir.appendingPathComponent(name)
    let text = try String(contentsOf: url, encoding: .utf8)
    var bodies: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let record = JSON.parse(String(line)) else { continue }
        guard let ep = record["ep"]?.string, ep == "/metrics",
              let status = record["status"]?.number, status == 200,
              let body = record["body"]?.string else { continue }
        bodies.append(body)
    }
    return bodies
}