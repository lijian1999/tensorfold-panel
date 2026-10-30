// 回放 fixtures/omlx/ 的九段实录：每拍输出和参考实现的期望逐字段比较（做法同 docs/tasks/mac/ref/replay.py 的 run）。
import Foundation
import Testing
@testable import PanelCore

private let scenarios = ["load-short", "short", "long", "cached", "concurrent4",
                         "queue10", "abort-decode", "abort-prefill", "mixed"]

/// 逐字段比较两个 JSON：一样返回 nil，不一样返回第一个不一样的位置（如 health.tfpanel.streams[0].start）和两边的值。
/// 两个数（int、double 混着也算）差的绝对值不超过 1e-9 算一样。
private func jsonDiff(_ a: JSON, _ b: JSON, _ path: String) -> String? {
    switch (a, b) {
    case let (.int(x), .int(y)):
        return x == y ? nil : diffText(a, b, path)
    case let (x, y) where x.number != nil && y.number != nil:
        return abs(x.number! - y.number!) <= 1e-9 ? nil : diffText(a, b, path)
    case let (.object(x), .object(y)):
        guard Set(x.keys) == Set(y.keys) else { return diffText(a, b, path) }
        for k in x.keys.sorted() {
            if let d = jsonDiff(x[k]!, y[k]!, path.isEmpty ? k : "\(path).\(k)") { return d }
        }
        return nil
    case let (.array(x), .array(y)):
        guard x.count == y.count else { return diffText(a, b, path) }
        for i in x.indices {
            if let d = jsonDiff(x[i], y[i], "\(path)[\(i)]") { return d }
        }
        return nil
    default:
        return a == b ? nil : diffText(a, b, path)
    }
}

private func diffText(_ a: JSON, _ b: JSON, _ path: String) -> String {
    "at \(path): got \(a.serialized()) want \(b.serialized())"
}

@Suite struct TestOmlxFixtures {
    @Test func test_回放九段实录() {
        for name in scenarios {
            let lines = readJSONL("omlx/\(name).jsonl")
            let expected = readJSONL("omlx/\(name).expected.jsonl")
            #expect(lines.count == expected.count + 1, "\(name): 行数对不上")
            let ad = OmlxAdapter()
            ad.setModels(lines[0]["models"])
            for (i, d) in lines.dropFirst().enumerated() {
                let t = d["t"]!.number!
                let wall = d["wall"]!.number!
                let exp = expected[i]
                let res = ad.feed(now: t, wall: wall, status: d["status"], stats: d["stats"])
                let expHealth = exp["health"] ?? .null
                let expMetrics = exp["metrics"] ?? .null
                if res == nil {
                    #expect(expHealth.isNull && expMetrics.isNull, "\(name) t=\(t): 期望读到但实际读不到")
                } else {
                    let dh = jsonDiff(res!.health, expHealth, "health")
                    let dm = jsonDiff(res!.metrics, expMetrics, "metrics")
                    let diff = dh ?? dm
                    #expect(diff == nil, "\(name) t=\(t): \(diff ?? "")")
                    if diff != nil { break }  // 一个场景出现第一处不同就停止，接着比下一个场景
                }
                let expModel = exp["model"]
                if expModel.isNone {
                    #expect(ad.modelName == nil, "\(name) t=\(t): model 期望 null")
                } else {
                    #expect(ad.modelName == expModel?.string, "\(name) t=\(t): model 不符")
                }
            }
        }
    }
}

/// 读 fixtures/ 下的一个 jsonl（一行一个 JSON），按 \n 切行、跳过空行。
private func readJSONL(_ name: String) -> [JSON] {
    let url = fixturesDir.appendingPathComponent(name)
    let text = try! String(contentsOf: url, encoding: .utf8)
    var out: [JSON] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.isEmpty { continue }
        guard let v = JSON.parse(String(line)) else {
            Issue.record("不是合法 JSON 的行：\(name): \(line.prefix(80))")
            continue
        }
        out.append(v)
    }
    return out
}
