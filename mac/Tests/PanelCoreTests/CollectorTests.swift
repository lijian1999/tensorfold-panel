// 翻译自 panel/tests/test_collector.py：采集模块的测试。
// 全部用假时刻，不 sleep；浮点用 assertAlmostEqual 比（这里用 almostEqual）。
import Foundation
import Testing
@testable import PanelCore

// MARK: - 辅助函数与辅助类型

/// 保留 6 位小数（对应 Python 的 round(t, 6)）
private func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }

/// 取 JSON 数字；取不到时返回 nan（让断言失败而不是崩溃）
private func num(_ j: JSON?) -> Double { j?.number ?? .nan }

/// 造一份 /health 读数；没给的累计值按 0 给。
/// kwargs 对应 Python 的 **dict 展开（total/c/prompt/cached/prefill_s/decode_s/drafted/accepted）。
private func health(
    _ kwargs: [String: JSON] = [:],
    running: Int = 0, total: JSON? = nil, prompt: JSON? = nil, cached: JSON? = nil, c: JSON? = nil,
    prefill_s: JSON? = nil, decode_s: JSON? = nil, drafted: JSON? = nil, accepted: JSON? = nil,
    dec: Int = 0, pre: Int = 0, maximum: Int = 5, context: Int = 262144, hook: JSON? = nil
) -> JSON {
    var data: [String: JSON] = [
        "ok": true,
        "busy": .bool(running != 0 || dec != 0 || pre != 0),
        "requests_running": .int(running),
        "requests_total": total ?? kwargs["total"] ?? .int(0),
        "completion_tokens_total": c ?? kwargs["c"] ?? .int(0),
        "prompt_tokens_total": prompt ?? kwargs["prompt"] ?? .int(0),
        "cached_tokens_total": cached ?? kwargs["cached"] ?? .int(0),
        "prefill_seconds_total": prefill_s ?? kwargs["prefill_s"] ?? .double(0.0),
        "decode_seconds_total": decode_s ?? kwargs["decode_s"] ?? .double(0.0),
        "drafted_total": drafted ?? kwargs["drafted"] ?? .int(0),
        "accepted_total": accepted ?? kwargs["accepted"] ?? .int(0),
        "streams": ["decoding": .int(dec), "prefilling": .int(pre), "max": .int(maximum)],
        "context_length": .int(context),
    ]
    if let hook = hook { data["tfpanel"] = hook }
    return .object(data)
}

/// 对应 Python 的 {**base, "k": v}（字典展开加覆盖）
private func mergeKwargs(_ base: [String: JSON], _ overrides: [String: JSON]) -> [String: JSON] {
    var d = base
    for (k, v) in overrides { d[k] = v }
    return d
}

/// 对应 Python 的 dict(d, k=v)
private func dict(_ json: JSON, _ extra: [String: JSON]) -> JSON {
    var o = json.object ?? [:]
    for (k, v) in extra { o[k] = v }
    return .object(o)
}

/// 从 start 到 stop（两头都含）每隔 dt 秒一个时刻，避开累加带来的误差。
private func every_tenth(_ start: Double, _ stop: Double, dt: Double = 0.1) -> [Double] {
    var out: [Double] = []
    var t = start
    while t <= stop + 1e-9 {
        out.append(round6(t))
        t = round6(t + dt)
    }
    return out
}

private struct UsageBroken: Error {}

/// 假账本：记下每次收到的 totals；today() 返回固定值；throw 时两个方法都抛。
fileprivate final class FakeUsage: UsageSink {
    static let TODAY: JSON = [
        "date": "2026-10-03",
        "prompt_tokens": 8260391,
        "cached_tokens": 5443627,
        "completion_tokens": 185305,
        "requests": 98,
        "cost": 0.597,
    ]
    var calls: [JSON] = []
    let `throw`: Bool
    init(throw: Bool = false) { self.`throw` = `throw` }
    func update(_ totals: JSON) throws {
        if `throw` { throw UsageBroken() }
        calls.append(totals)
    }
    func today() throws -> JSON {
        if `throw` { throw UsageBroken() }
        return FakeUsage.TODAY
    }
}

/// 把外挂行装进 /health 的 tfpanel 字段。
private func hook_rows(_ rows: JSON...) -> JSON {
    ["v": 1, "streams": .array(rows)]
}

/// 按时刻推进的读数脚本：记下每一次的快照，方便按时刻取。
fileprivate final class Scene {
    let collector: Collector
    var points: [(Double, JSON)] = []
    init(_ collector: Collector) { self.collector = collector }

    /// 在时刻 t 喂一次读数，返回这份快照。
    func at(_ t: Double, _ h: JSON?, metrics: JSON? = nil) -> JSON {
        let key = round6(t)
        let snap = collector.feed(now: key, health: h, metrics: metrics)
        points.append((key, snap))
        return snap
    }

    /// 最近一次喂出来的快照。
    func last_snap() -> JSON { points[points.count - 1].1 }

    /// 取时刻 t 上的那份快照（没有就报错，防止断言写错时刻）。
    func snap_at(_ t: Double) -> JSON {
        let key = round6(t)
        for (point, snap) in points {
            if abs(point - key) < 1e-6 { return snap }
        }
        preconditionFailure("没有喂过时刻 \(t) 的读数")
    }
}

// 场景 1 的空闲基线
private let BASE: [String: JSON] = [
    "total": 97, "c": 185105, "prompt": 8260333, "cached": 5443627,
    "prefill_s": 1457.3376, "decode_s": 2848.0993, "drafted": 178331, "accepted": 124265,
]

// 场景 1 里那个请求结束后的累计值：提示 58、输出 200、解码 3.3507 秒、草稿 171 接受 116
private let FINISHED: [String: JSON] = [
    "total": 98, "c": 185305, "prompt": 8260391, "cached": 5443627,
    "prefill_s": 1457.42, "decode_s": 2851.45, "drafted": 178502, "accepted": 124381,
]

/// 场景 1 里 t 时刻的 C：解码中每 0.1 秒加 6，最后一步只加 2，凑够 200。
private func scene1_c(_ t: Double) -> Int {
    if t < 10.1 { return 185105 }
    if t > 13.4 - 1e-9 { return 185305 }
    let grown = 6 * (Int(((t - 10.1) * 10).rounded()) + 1)
    return 185105 + (grown > 200 ? grown - 4 : grown)
}

/// 单个请求的全过程：空闲 → 预填充 → 解码 → 完成 → 空闲。
private func scene1_steps() -> [(Double, JSON)] {
    var steps: [(Double, JSON)] = [(1.0, health(BASE))]
    steps.append((10.0, health(BASE, running: 1, pre: 1)))
    for t in every_tenth(10.1, 13.4) {
        steps.append((t, health(mergeKwargs(BASE, ["c": .int(scene1_c(t))]), running: 1, dec: 1)))
    }
    for t in [13.5, 17.4, 17.6, 22.0] {
        steps.append((t, health(FINISHED)))
    }
    return steps
}

// MARK: - 1. 单个请求的全过程

@Suite struct TestSingleRequest {
    fileprivate let scene: Scene

    init() {
        scene = Scene(Collector(config: Config()))
        for (t, h) in scene1_steps() { scene.at(t, h) }
    }

    @Test func test_状态依次经过空闲预填充解码完成空闲() {
        #expect(scene.snap_at(1.0)["state"] == "idle")
        #expect(scene.snap_at(10.0)["state"] == "prefill")
        #expect(scene.snap_at(10.1)["state"] == "decode")
        #expect(scene.snap_at(13.4)["state"] == "decode")
        #expect(scene.snap_at(13.5)["state"] == "done", "结束后先停 4 秒完成画面")
        #expect(scene.snap_at(17.4)["state"] == "done")
        #expect(scene.snap_at(17.6)["state"] == "idle")
        #expect(scene.snap_at(22.0)["state"] == "idle")
        // 空闲 → 预填充 → 解码 → 完成（停 4 秒）→ 空闲
        #expect(scene.points[1].1["state"] == "prefill")
        #expect(scene.points[2].1["state"] == "decode")
        #expect(scene.points[35].1["state"] == "decode")
        #expect(scene.points[36].1["state"] == "done")
        #expect(scene.points[37].1["state"] == "done")
        #expect(scene.points[38].1["state"] == "idle")
        #expect(scene.points[39].1["state"] == "idle")
    }

    @Test func test_解码中的解码段和本轮() {
        for (t, _) in scene1_steps() {
            let decode = scene.snap_at(t)["decode"]
            if !(10.1 <= t && t <= 13.4) {
                #expect(decode.isNone, "t=\(t) 不该有解码段")
                continue
            }
            #expect((decode?["output_tokens"]) == .int(scene1_c(t) - 185105), "t=\(t)")
        }
        let decode = scene.snap_at(11.0)["decode"]!
        #expect(decode["output_tokens"] == .int(60))
        #expect(almostEqual(num(decode["ttft_s"]), 0.1, places: 6))
        #expect((scene.snap_at(13.4)["decode"]?["output_tokens"]) == .int(200))
        #expect(scene.snap_at(11.0)["round"] == [
            "requests": 0, "running": 1, "output_tokens": 60, "decode_tps_avg": .null,
            "exact": true, "elapsed_s": 1.0, "active": true,
        ])
    }

    @Test func test_结束后的快照() {
        let snap = scene.snap_at(13.5)
        let last = snap["last"]!
        #expect(last["prompt_tokens"] == .int(58))
        #expect(last["cached_tokens"] == .int(0))
        #expect(last["completion_tokens"] == .int(200))
        #expect(almostEqual(num(last["decode_tps"]), 200 / 3.3507, places: 4))
        #expect(almostEqual(num(last["prefill_tps"]), 58 / 0.0824, places: 4))
        #expect(almostEqual(num(last["acceptance_rate"]), 116 / 171, places: 4))
        #expect(almostEqual(num(last["ttft_s"]), 0.1, places: 6))
        #expect(last["context_used"] == .int(258))
        #expect(snap["context_used"] == .int(258))
        #expect(snap["decode"].isNone)
        #expect(snap["prefill"].isNone)
        let roundSnap = snap["round"]!
        #expect(roundSnap["requests"] == .int(1))
        #expect(roundSnap["running"] == .int(0))
        #expect(roundSnap["output_tokens"] == .int(200))
        #expect(almostEqual(num(roundSnap["decode_tps_avg"]), 200 / 3.3507, places: 4))
        #expect(roundSnap["exact"] == .bool(true))
    }

    @Test func test_每次成功读数都记进账本() {
        let usage = FakeUsage()
        let scene = Scene(Collector(config: Config(), usage: usage))
        let steps = scene1_steps()
        for (t, h) in steps { scene.at(t, h) }
        #expect(usage.calls.count == steps.count)
        #expect(usage.calls[0] == ["prompt": 8260333, "cached": 5443627, "completion": 185105, "requests": 97])
        #expect(usage.calls.last == ["prompt": 8260391, "cached": 5443627, "completion": 185305, "requests": 98])
    }
}

// MARK: - 2. 解码速度

@Suite struct TestDecodeSpeed {
    let BASE: [String: JSON] = [
        "total": 20, "c": 1000, "prompt": 500000, "cached": 300000,
        "prefill_s": 200.0, "decode_s": 500.0, "drafted": 20000, "accepted": 14000,
    ]

    /// t 时刻的 C：t=5.3 起每 0.1 秒加 6（60 tok/s），涨到 1300 后平 3 秒不涨。
    private func decode_c(_ t: Double) -> Int {
        if t <= 5.2 { return 1000 }
        if t <= 10.2 + 1e-9 { return 1000 + 6 * Int(((t - 5.2) * 10).rounded()) }
        return 1300
    }

    @Test func test_解码速度() {
        let scene = Scene(Collector(config: Config()))
        scene.at(1.0, health(BASE))
        scene.at(5.0, health(BASE, running: 1, pre: 1))
        var seen: [Double: JSON] = [:]
        for t in every_tenth(5.2, 13.2) {
            let snap = scene.at(t, health(mergeKwargs(BASE, ["c": .int(decode_c(t))]), running: 1, dec: 1))
            #expect(snap["state"] == "decode", "t=\(t) 应该还在解码")
            seen[round6(t)] = snap["decode"] ?? .null
        }

        for t in [5.2, 5.3, 5.4, 5.5, 5.6] {
            #expect((seen[round6(t)]?["tps_avg"]).isNone, "t=\(t) 的 tps_avg 应该是 None")
        }
        for t in [5.7, 6.2, 7.7] {
            let decode = seen[round6(t)]!
            let elapsed = round6(t - 5.2)
            #expect(almostEqual(num(decode["tps_avg"]), num(decode["output_tokens"]) / elapsed, places: 4),
                    "t=\(t) 的平均速度")
            #expect(almostEqual(num(decode["tps"]), 60.0, places: 4), "t=\(t) 的实时速度")
        }
        for t in [5.2, 5.6, 6.2] {
            #expect((seen[round6(t)]?["tps_peak"]) == 0, "t=\(t) 的峰值该是 0")
        }

        #expect(almostEqual(num(seen[5.4]?["tps"]), 24.0, places: 4), "el=0.2 时 12 / 0.5")
        #expect(almostEqual(num(seen[13.2]?["tps"]), 0.0, places: 4), "C 不再增长后速度降到 0")
        var peak = -Double.infinity
        for decode in seen.values { peak = max(peak, num(decode["tps_peak"])) }
        #expect(almostEqual(peak, 60.0, places: 4), "峰值是出现过的最大速度")
        #expect(almostEqual(num(seen[13.2]?["tps_peak"]), peak, places: 4), "峰值不降")
        #expect(almostEqual(num(seen[13.2]?["tps_avg"]), 300 / 8.0, places: 4))
        #expect((seen[13.2]?["output_tokens"]) == .int(300))
    }
}

// MARK: - 2.9 补充：离开解码再回来时，解码段重新开始算

@Suite struct TestDecodeRestart {
    let BASE: [String: JSON] = [
        "total": 20, "prompt": 500000, "cached": 300000,
        "prefill_s": 200.0, "decode_s": 500.0, "drafted": 20000, "accepted": 14000,
    ]

    @Test func test_回到解码时段落重新开始() {
        let scene = Scene(Collector(config: Config()))
        let base = BASE

        /// 解码中每 0.1 秒加 6：t=起点时刻时还是 start。
        func decode_c(_ t: Double, _ start: Int) -> Int {
            start + 6 * Int(((t - 5.0) * 10).rounded())
        }

        scene.at(1.0, health(base, c: .int(1000)))
        // 第一段解码：5.0 到 7.4，在跑数一直是 1
        for t in every_tenth(5.0, 7.4) {
            scene.at(t, health(mergeKwargs(base, ["c": .int(decode_c(t, 1000))]), running: 1, dec: 1))
        }
        // 7.5 上一个结束、下一个同时到达：在跑数还是 1，但这一条在预填充
        for t in every_tenth(7.5, 7.9) {
            scene.at(t, health(mergeKwargs(base, ["total": 21, "c": 1144]), running: 1, pre: 1))
        }
        // 8.0 起重新解码
        for t in every_tenth(8.0, 8.5) {
            scene.at(t, health(mergeKwargs(base, ["total": 21, "c": .int(decode_c(t, 1150))]), running: 1, dec: 1))
        }

        #expect(scene.snap_at(7.4)["state"] == "decode")
        for t in [7.5, 7.6, 7.7, 7.8, 7.9] {
            #expect(scene.snap_at(t)["state"] == "prefill", "t=\(t) 没有在解码的流")
            #expect(scene.snap_at(t)["decode"].isNone, "t=\(t) 不该有解码段")
        }
        #expect(scene.snap_at(8.0)["state"] == "decode")

        #expect(almostEqual(num(scene.snap_at(7.4)["decode"]?["tps"]), 60.0, places: 4))
        #expect(almostEqual(num(scene.snap_at(7.4)["decode"]?["tps_peak"]), 60.0, places: 4),
                "第一段解码跑了 2.4 秒，峰值早该记到 60")
        for t in [8.0, 8.1, 8.2, 8.3, 8.4] {
            let decode = scene.snap_at(t)["decode"]!
            #expect(decode["tps_avg"].isNone, "t=\(t) 刚回到解码，平均速度该是 None")
            #expect(decode["tps_peak"] == 0, "t=\(t) 的峰值从 0 重新算")
        }
        #expect(almostEqual(num(scene.snap_at(8.5)["decode"]?["tps_avg"]), 60.0, places: 4))
    }
}

// MARK: - 3. 首字的精确值

@Suite struct TestExactTtft {
    @Test func test_精确值盖掉估算值() {
        let scene = Scene(Collector(config: Config()))
        for (t, h) in scene1_steps() {
            if t <= 17.4 + 1e-9 { scene.at(t, h) }
        }
        #expect(almostEqual(num(scene.snap_at(13.5)["last"]?["ttft_s"]), 0.1, places: 6))
        #expect(almostEqual(num(scene.snap_at(17.4)["last"]?["ttft_s"]), 0.1, places: 6))
        let done = health(FINISHED)
        scene.at(17.5, done, metrics: ["waiting": 0, "kv_usage": [0.093899, 0.0], "ttft_sum": 100.0, "ttft_count": 97])
        let snap = scene.at(17.6, done, metrics: ["waiting": 0, "kv_usage": [0.093899, 0.0], "ttft_sum": 100.0824, "ttft_count": 98])
        #expect(almostEqual(num(snap["last"]?["ttft_s"]), 0.0824, places: 6))
    }

    @Test func test_计数变小说明重启() {
        let scene = Scene(Collector(config: Config()))
        let metrics: JSON = ["waiting": 0, "kv_usage": [], "ttft_sum": 100.0, "ttft_count": 97]
        scene.at(1.0, health(BASE))
        scene.at(2.0, health(BASE), metrics: metrics)
        let snap = scene.at(3.0, health(BASE), metrics: ["waiting": 0, "kv_usage": [], "ttft_sum": 5.0, "ttft_count": 2])
        #expect(snap["last"].isNone)
        #expect(snap["state"] == "idle")
    }
}

// MARK: - 4. 离线

@Suite struct TestOffline {
    private func scene_with_history() -> (Scene, FakeUsage) {
        let usage = FakeUsage()
        let scene = Scene(Collector(config: Config(), usage: usage))
        for (t, h) in scene1_steps() {
            if t <= 13.5 + 1e-9 { scene.at(t, h) }
        }
        return (scene, usage)
    }

    @Test func test_连续三次读不到才进入离线() {
        let (scene, usage) = scene_with_history()
        let before = scene.last_snap()
        #expect(!before["last"].isNone)
        #expect(scene.at(13.6, nil) == before)
        #expect(scene.at(13.7, nil) == before)
        let used = usage.calls.count
        let offline = scene.at(13.8, nil)
        #expect(offline["state"] == "offline")
        #expect(almostEqual(num(offline["offline_s"]), 0.2, places: 6), "离线秒数从第一次失败算起")
        #expect(offline["decode"].isNone)
        #expect(offline["prefill"].isNone)
        #expect(offline["round"].isNone)
        #expect(offline["last"] == before["last"], "last 要保留")
        #expect(offline["lanes"] == ["max": 5, "decoding": 0, "prefilling": 0, "waiting": 0])
        #expect(usage.calls.count == used, "离线期间不记账")
        let back = scene.at(14.0, health(FINISHED))
        #expect(back["state"] == "idle")
        #expect(back["offline_s"].isNone)
        #expect(usage.calls.count == used + 1, "恢复后又开始记账")
    }

    @Test func test_一上来就读不到() {
        let collector = Collector(config: Config())
        let snap = collector.feed(now: 1.0, health: nil)
        #expect(snap["state"] == "offline")
        #expect(snap["offline_s"] == 0.0)
        #expect(snap["decode"].isNone)
        #expect(snap["prefill"].isNone)
        #expect(snap["round"].isNone)
        #expect(snap["last"].isNone)
        #expect(snap["memory"] == ["used_gb": 0.0, "total_gb": 0.0])
        #expect(snap["model"] == "Qwen3.8-Flash-Next")
        #expect(snap["context_max"] == .int(262144))
        #expect(snap["hook"] == "missing")
        #expect(collector.feed(now: 2.0, health: nil)["state"] == "offline")
    }
}

// MARK: - 5. 模型重启

@Suite struct TestRestart {
    @Test func test_累计值变小不产生请求结束() {
        let scene = Scene(Collector(config: Config()))
        for (t, h) in scene1_steps() {
            if t <= 13.5 + 1e-9 { scene.at(t, h) }
        }
        let before = scene.last_snap()
        #expect(!before["last"].isNone)
        let after = scene.at(13.6, health(running: 1, total: 3, prompt: 5000, cached: 1000, c: 10,
                                          prefill_s: 2.0, decode_s: 4.0, drafted: 200, accepted: 120, dec: 1))
        #expect(after["last"] == before["last"], "重启不该产生新的请求结束")
        #expect(after["round"].isNone)
        #expect(after["state"] == "decode")
        #expect(after["hook"] == "missing")
    }
}

// MARK: - 6. 一轮

@Suite struct TestRound {
    let FIRST: [String: JSON] = [
        "total": 97, "c": 185105, "prompt": 8260333, "cached": 5443627,
        "prefill_s": 1457.3376, "decode_s": 2848.0993, "drafted": 178331, "accepted": 124265,
    ]
    let SECOND: [String: JSON] = [
        "total": 98, "c": 185305, "prompt": 8260391, "cached": 5443627,
        "prefill_s": 1457.42, "decode_s": 2851.45, "drafted": 178502, "accepted": 124381,
    ]
    let THIRD: [String: JSON] = [
        "total": 99, "c": 185479, "prompt": 8260449, "cached": 5443627,
        "prefill_s": 1457.5, "decode_s": 2853.95, "drafted": 178702, "accepted": 124501,
    ]

    @Test func test_顺序两个请求算同一轮() {
        let steps: [(Double, JSON)] = [
            (1.0, health(FIRST)),
            (10.0, health(FIRST, running: 1, pre: 1)),
            (13.5, health(SECOND)),
            (18.0, health(SECOND, running: 1, pre: 1)),
            (21.0, health(THIRD)),
        ]
        let scene = Scene(Collector(config: Config()))
        for (t, h) in steps { scene.at(t, h) }
        let during = scene.snap_at(18.0)["round"]!
        #expect(during["requests"] == .int(1))
        #expect(during["running"] == .int(1))
        #expect(during["active"] == .bool(true))
        let after = scene.snap_at(21.0)["round"]!
        #expect(after["requests"] == .int(2))
        #expect(after["running"] == .int(0))
        #expect(after["exact"] == .bool(true))
        // 本轮平均 = 两次输出之和 ÷ 两次解码秒数之和
        #expect(almostEqual(num(after["decode_tps_avg"]), (200 + 174) / (3.3507 + 2.5), places: 4))
    }

    @Test func test_隔了61秒算新一轮() {
        var steps: [(Double, JSON)] = [(1.0, health(BASE)), (10.0, health(BASE, running: 1, pre: 1)), (13.5, health(FINISHED))]
        for t in every_tenth(14.5, 74.5, dt: 1.0) { steps.append((t, health(FINISHED))) }
        steps.append((74.6, health(FINISHED, running: 1, pre: 1)))
        let scene = Scene(Collector(config: Config()))
        for (t, h) in steps { scene.at(t, h) }
        let idleLong = scene.snap_at(74.5)
        #expect((idleLong["round"]?["active"]) == .bool(false), "隔了 61 秒，这一轮该算结束")
        #expect(almostEqual(num(idleLong["round"]?["elapsed_s"]), 3.5, places: 4))
        #expect(almostEqual(num(idleLong["round"]?["decode_tps_avg"]), 200 / 3.3507, places: 4))
        let newRound = scene.snap_at(74.6)["round"]!
        #expect(newRound["requests"] == .int(0))
        #expect(newRound["running"] == .int(1))
        #expect(newRound["output_tokens"] == .int(0))
        #expect(newRound["active"] == .bool(true))
    }

    @Test func test_隔了59秒仍是同一轮() {
        var steps: [(Double, JSON)] = [(1.0, health(BASE)), (10.0, health(BASE, running: 1, pre: 1)), (13.5, health(FINISHED))]
        for t in every_tenth(14.5, 72.4, dt: 1.0) { steps.append((t, health(FINISHED))) }
        steps.append((72.4, health(FINISHED, running: 1, pre: 1)))
        let scene = Scene(Collector(config: Config()))
        for (t, h) in steps { scene.at(t, h) }
        let snap = scene.snap_at(72.4)
        #expect((snap["round"]?["active"]) == .bool(true))
        #expect((snap["round"]?["requests"]) == .int(1), "还在同一轮里，第二个请求算进同一轮")
        #expect((snap["round"]?["running"]) == .int(1))
    }

    @Test func test_上一个结束下一个到达在同一次读数里() {
        let scene = Scene(Collector(config: Config()))
        for (t, h) in scene1_steps() {
            if t <= 13.4 + 1e-9 { scene.at(t, h) }
        }
        let snap = scene.at(13.5, health(FINISHED, running: 1, pre: 1))
        #expect((snap["round"]?["exact"]) == .bool(true), "刚结束一个，间隔为 0，还算同一轮")
        #expect((snap["round"]?["requests"]) == .int(1))
        #expect((snap["round"]?["running"]) == .int(1))
        #expect((snap["last"]?["completion_tokens"]) == .int(200))
    }
}

// MARK: - 7. 并发

@Suite struct TestConcurrent {
    let BASE: [String: JSON] = [
        "total": 5, "c": 1000, "prompt": 400000, "cached": 200000,
        "prefill_s": 100.0, "decode_s": 300.0, "drafted": 10000, "accepted": 7000,
    ]

    @Test func test_两个请求同时在跑() {
        let base = BASE
        let scene = Scene(Collector(config: Config()))
        var seen: [Double: JSON] = [:]
        var seconds: [Double: Double] = [:]
        var total = 0.0

        /// 逐条喂读数，同时累加“处在解码状态的时长”。
        func drive(_ points: [(Double, Int, Int, Int, Int)]) {
            for (t, running, dec, c, totalRequests) in points {
                let snap = scene.at(t, health(mergeKwargs(base, ["c": .int(c), "total": .int(totalRequests)]),
                                              running: running, dec: dec))
                if snap["state"] == "decode" {
                    total = round6(total + 0.1)
                }
                seen[round6(t)] = snap
                seconds[round6(t)] = total
            }
        }

        /// (时刻, 在跑数, 解码数, C, 请求数)：C 从 start 起每 0.1 秒加 step。
        func c_list(_ t1: Double, _ t2: Double, _ start: Int, step: Int = 6) -> [(Double, Int, Int, Int, Int)] {
            var out: [(Double, Int, Int, Int, Int)] = []
            var c = start
            for t in every_tenth(t1, t2) {
                out.append((t, 2, 2, c, 5))
                c += step
            }
            return out
        }

        var points: [(Double, Int, Int, Int, Int)] = [(20.0, 1, 0, 1000, 5)]  // 第一个到达：在预填充
        for (i, t) in every_tenth(20.1, 20.4).enumerated() {                   // 第一个单独在解码
            points.append((t, 1, 1, 1000 + 6 * (i + 1), 5))
        }
        points += c_list(20.5, 22.9, 1030)                                      // 第二个到达：两个同时在跑
        for (i, t) in every_tenth(23.0, 24.9).enumerated() {                    // 第一个结束：还剩一个
            points.append((t, 1, 1, 1174 + 6 * (i + 1), 6))
        }
        points.append((25.0, 0, 0, 1294, 7))                                    // 都结束
        drive(points)

        #expect((seen[20.5]?["round"]?["exact"]) == .bool(false), "两个同时在跑，本轮不再算精确值")
        #expect((seen[21.1]?["round"]?["exact"]) == .bool(false))
        #expect((seen[20.5]?["round"]?["decode_tps_avg"]).isNone, "解码时长不到 0.5 秒时算不出本轮平均")
        // 并发时没有首字时间（这一忙碌段的在跑数峰值是 2）
        #expect((seen[21.1]?["decode"]?["ttft_s"]).isNone)
        #expect((seen[23.1]?["decode"]?["ttft_s"]).isNone)
        for (t, cNow, secondsInDecode) in [(20.6, 1036, 0.6), (21.1, 1066, 1.1), (23.1, 1186, 3.1)] {
            let snap = seen[round6(t)]!
            #expect(almostEqual(num(snap["round"]?["decode_tps_avg"]), Double(cNow - 1000) / secondsInDecode, places: 4),
                    "t=\(t)")
        }
        // 一个先结束：还在解码，不进完成
        #expect((seen[23.0]?["state"]) == "decode")
        #expect((seen[23.1]?["state"]) == "decode")
        // 都结束才进完成
        #expect((seen[25.0]?["state"]) == "done")
        // 两个请求的输出之和等于本轮输出
        let first = num(seen[23.0]!["last"]?["completion_tokens"])
        let second = num(seen[25.0]!["last"]?["completion_tokens"])
        #expect(first + second == num(seen[25.0]!["round"]?["output_tokens"]))
        #expect(almostEqual(seconds[23.1] ?? .nan, 3.1, places: 4))
    }
}

// MARK: - 11. 外挂失效时的预填充画面

@Suite struct TestNoHookPrefill {
    @Test func test_没有外挂时的预填充() {
        let collector = Collector(config: Config())
        let scene = Scene(collector)
        scene.at(1.0, health(BASE))
        let metrics: JSON = ["waiting": 0, "kv_usage": [0.093899, 0.0], "ttft_sum": 1599.727361, "ttft_count": 156]
        for t in [10.0, 10.1, 10.2, 10.3, 10.4] {
            scene.at(t, health(BASE, running: 1, pre: 1), metrics: metrics)
        }
        let first = scene.points[scene.points.count - 5].1
        let snap = scene.last_snap()
        #expect(snap["hook"] == "missing")
        #expect(snap["state"] == "prefill")
        #expect(almostEqual(num(first["prefill"]?["elapsed_s"]), 0.0, places: 6), "从预填充中变出来那次算起")
        #expect(almostEqual(num(snap["prefill"]?["elapsed_s"]), 0.4, places: 6))
        let prefill = snap["prefill"]!
        #expect(prefill["prompt_tokens"] == .int(24615))
        #expect(snap["context_used"] == .int(24615))
        for key in ["cached_tokens", "filled_tokens", "tps", "remaining_s", "est_s"] {
            #expect(prefill[key].isNone, "\(key)")
        }
        #expect(prefill["cache_miss"] == .bool(false))
    }

    @Test func test_排队数取自metrics() {
        let collector = Collector(config: Config())
        let scene = Scene(collector)
        scene.at(1.0, health(BASE))
        var snap = scene.at(2.0, health(BASE, running: 1, pre: 1),
                            metrics: ["waiting": 2, "kv_usage": [], "ttft_sum": .null, "ttft_count": .null])
        #expect(snap["lanes"] == ["max": 5, "decoding": 0, "prefilling": 1, "waiting": 2])
        snap = scene.at(3.0, health(BASE, running: 1, pre: 1),
                        metrics: ["waiting": .null, "kv_usage": [], "ttft_sum": .null, "ttft_count": .null])
        #expect(snap["lanes"] == ["max": 5, "decoding": 0, "prefilling": 1, "waiting": 0])
        snap = scene.at(4.0, health(BASE))
        #expect(snap["lanes"] == ["max": 5, "decoding": 0, "prefilling": 0, "waiting": 0])
    }
}

// MARK: - 13. 健壮性

@Suite struct TestRobustness {
    @Test func test_缺键不抛异常() {
        let collector = Collector(config: Config())
        let snap = collector.feed(now: 1.0, health: ["ok": true])
        #expect(snap["state"] == "idle")
        #expect(snap["context_used"] == .int(0))
        #expect(snap["lanes"] == ["max": 1, "decoding": 0, "prefilling": 0, "waiting": 0])
        #expect(JSON.parse(snap.serialized()) == snap)
    }

    @Test func test_账本抛异常不影响feed() {
        let collector = Collector(config: Config(), usage: FakeUsage(throw: true))
        for (t, h) in scene1_steps() {
            if t <= 13.5 + 1e-9 {
                let snap = collector.feed(now: t, health: h)
                #expect(["idle", "prefill", "decode", "done"].contains(snap["state"]?.string ?? ""))
                #expect(snap["today"] == ["date": "", "prompt_tokens": 0, "cached_tokens": 0,
                                          "completion_tokens": 0, "requests": 0, "cost": 0.0],
                        "today() 抛异常时退回默认空账本（说明 2.12）")
            }
        }
    }

    @Test func test_快照可以转成JSON() {
        let collector = Collector(config: Config())
        for (t, h) in scene1_steps() {
            let snap = collector.feed(now: t, health: h)
            #expect(JSON.parse(snap.serialized()) == snap)
        }
    }

    @Test func test_改动返回的字典不影响下一次() {
        let steps = scene1_steps()

        func run(_ mutate: Bool) -> [String] {
            let collector = Collector(config: Config(), usage: FakeUsage())
            var snaps: [String] = []
            for (t, h) in steps {
                var snap = collector.feed(now: t, health: h)
                snaps.append(snap.serialized())
                if mutate, var o = snap.object {
                    o["last"] = ["坏": 1]
                    o["round"] = ["坏": 2]
                    if case .object(var today) = o["today"] { today["cost"] = .double(999.0); o["today"] = .object(today) }
                    if case .object(var lanes) = o["lanes"] { lanes["decoding"] = .int(9); o["lanes"] = .object(lanes) }
                    if case .object(var memory) = o["memory"] { memory["used_gb"] = .double(999.0); o["memory"] = .object(memory) }
                    snap = .object(o)
                }
            }
            return snaps
        }

        #expect(run(false) == run(true))
    }

    @Test func test_顶层键和原型一致() {
        let fixture = loadFixture("idle.json")
        let collector = Collector(config: Config())
        let snap = collector.feed(now: 1.0, health: health(BASE))
        #expect(Set((snap.object ?? [:]).keys) == Set((fixture.object ?? [:]).keys))
    }
}

// MARK: - 8. 外挂好用时的预填充

@Suite struct TestHookPrefill {
    /// 预填充开始后的 elapsed 秒里已算到的位置：0.9/1.8/2.7 各涨 2048。
    private func filled_at(_ elapsed: Double) -> Int {
        if elapsed < 0.9 - 1e-9 { return 0 }
        if elapsed < 1.8 - 1e-9 { return 2048 }
        if elapsed < 2.7 - 1e-9 { return 4096 }
        return 6144
    }

    @Test func test_一条预填充流() {
        let scene = Scene(Collector(config: Config()))
        scene.at(1.0, health(BASE))
        for t in every_tenth(10.0, 12.7) {
            let filled = filled_at(round6(t - 10.0))
            let row: JSON = ["id": 1, "phase": "prefill", "prompt": 24615, "cached": 0, "filled": .int(filled)]
            scene.at(t, health(BASE, running: 1, pre: 1, hook: hook_rows(row)))
        }

        #expect(scene.snap_at(10.0)["hook"] == "ok")
        #expect(scene.snap_at(10.0)["state"] == "prefill")
        let early = scene.snap_at(10.5)["prefill"]!
        #expect(early["tps"].isNone, "只进了一个进度点，算不出速度")
        #expect(almostEqual(num(early["remaining_s"]), 24615 / 2300 - 0.5, places: 4))
        #expect(almostEqual(num(early["est_s"]), 10.70, places: 2), "24615 ÷ 2300")

        let first = scene.snap_at(10.9)["prefill"]!
        #expect(almostEqual(num(first["tps"]), 2048 / 0.9, places: 4), "2048 ÷ 0.9")
        #expect(almostEqual(num(first["remaining_s"]), (24615 - 2048) / (2048 / 0.9), places: 4))

        let last = scene.snap_at(12.7)["prefill"]!
        #expect(almostEqual(num(last["tps"]), 6144 / 2.7, places: 4), "6144 ÷ 2.7")
        #expect(last["filled_tokens"] == .int(6144))
        #expect(almostEqual(num(last["remaining_s"]), (24615 - 6144) / (6144 / 2.7), places: 4))
        #expect(almostEqual(num(last["elapsed_s"]), 2.7, places: 6), "预填充计时从这条流第一次被读到算起")
        #expect(last["prompt_tokens"] == .int(24615))
        #expect(last["cached_tokens"] == .int(0))
        #expect(scene.snap_at(12.7)["context_used"] == .int(24615), "上下文占用取占用最大的那条流")
    }

    @Test func test_两条预填充流取之和() {
        let scene = Scene(Collector(config: Config()))
        scene.at(1.0, health(BASE))
        for t in every_tenth(10.0, 12.7) {
            let filled = filled_at(round6(t - 10.0))
            let rows: [JSON] = [
                ["id": 1, "phase": "prefill", "prompt": 24615, "cached": 2048, "filled": .int(10240 + filled)],
                ["id": 2, "phase": "prefill", "prompt": 24615, "cached": 0, "filled": .int(8192 + filled)],
            ]
            scene.at(t, health(BASE, running: 2, pre: 2, hook: hook_rows(rows[0], rows[1])))
        }
        let totalTps = 2 * (6144 / 2.7)
        let snap = scene.snap_at(12.7)
        let prefill = snap["prefill"]!
        #expect(prefill["prompt_tokens"] == .int(49230), "两条流的提示长度之和")
        #expect(prefill["cached_tokens"] == .int(2048))
        #expect(prefill["filled_tokens"] == .int(30720), "两条流的已算 token 之和")
        #expect(almostEqual(num(prefill["tps"]), totalTps, places: 4), "两条流的速度之和")
        #expect(almostEqual(num(prefill["elapsed_s"]), 2.7, places: 6), "计时从最早那条流算起")
        #expect(almostEqual(num(prefill["remaining_s"]), (49230 - 30720) / totalTps, places: 4))
        #expect(snap["context_used"] == .int(24615), "两条流占用一样")
    }
}

// MARK: - 9. 缓存未命中的判定（只在没出现过并发的一轮里做）

@Suite struct TestHookCacheMiss {
    // 上一个请求：提示 40120、命中 39400（新算 720）
    let AFTER_FIRST: [String: JSON] = [
        "total": 98, "c": 185305, "prompt": 8300453, "cached": 5483027,
        "prefill_s": 1457.42, "decode_s": 2851.45, "drafted": 178502, "accepted": 124381,
    ]
    // 上一个请求提示只有 3000
    let AFTER_SHORT: [String: JSON] = [
        "total": 98, "c": 185305, "prompt": 8263333, "cached": 5445627,
        "prefill_s": 1457.42, "decode_s": 2851.45, "drafted": 178502, "accepted": 124381,
    ]

    @Test func test_新算token多才算缓存未命中() {
        let scene = Scene(Collector(config: Config()))
        let big = hook_rows(["id": 1, "phase": "prefill", "prompt": 41230, "cached": 0, "filled": 0])
        scene.at(1.0, health(BASE))
        scene.at(5.0, health(AFTER_FIRST, running: 1, pre: 1, hook: big))
        #expect((scene.snap_at(5.0)["prefill"]?["cache_miss"]) == .bool(true),
                "上一个请求提示 40120、这次几乎没复用")
    }

    @Test func test_复用了缓存不算缓存未命中() {
        let scene = Scene(Collector(config: Config()))
        let reused = hook_rows(["id": 1, "phase": "prefill", "prompt": 41230, "cached": 39000, "filled": 0])
        scene.at(1.0, health(BASE))
        scene.at(5.0, health(AFTER_FIRST, running: 1, pre: 1, hook: reused))
        #expect((scene.snap_at(5.0)["prefill"]?["cache_miss"]) == .bool(false),
                "39000 个是从缓存复用的，不算未命中")
    }

    @Test func test_提示短于上一个的一半不算() {
        let scene = Scene(Collector(config: Config()))
        let short = hook_rows(["id": 1, "phase": "prefill", "prompt": 5000, "cached": 0, "filled": 0])
        scene.at(1.0, health(BASE))
        scene.at(5.0, health(AFTER_FIRST, running: 1, pre: 1, hook: short))
        #expect((scene.snap_at(5.0)["prefill"]?["cache_miss"]) == .bool(false),
                "5000 个比上一个请求的一半还短")
    }

    @Test func test_本轮出现过并发就不判定() {
        let scene = Scene(Collector(config: Config()))
        let big = hook_rows(["id": 1, "phase": "prefill", "prompt": 41230, "cached": 0, "filled": 0],
                            ["id": 2, "phase": "prefill", "prompt": 41230, "cached": 0, "filled": 0])
        scene.at(1.0, health(BASE))
        scene.at(5.0, health(AFTER_FIRST, running: 2, pre: 2, hook: big))
        #expect((scene.snap_at(5.0)["round"]?["exact"]) == .bool(false), "这一轮已经有两条流同时在跑")
        #expect((scene.snap_at(5.0)["prefill"]?["cache_miss"]) == .bool(false),
                "并发的几个请求各有各的对话，不比上一个")
    }

    @Test func test_上一个请求提示不足4000不算() {
        let scene = Scene(Collector(config: Config()))
        let big = hook_rows(["id": 1, "phase": "prefill", "prompt": 41230, "cached": 0, "filled": 0])
        scene.at(1.0, health(BASE))
        scene.at(5.0, health(AFTER_SHORT, running: 1, pre: 1, hook: big))
        #expect((scene.snap_at(5.0)["prefill"]?["cache_miss"]) == .bool(false),
                "上一个请求提示只有 3000，不够判定")
    }
}

// MARK: - 10. 外挂好用时的解码

@Suite struct TestHookDecode {
    let ROWS: [JSON] = [
        ["id": 3, "phase": "decode", "prompt": 18420, "cached": 16384, "output": 312],
        ["id": 4, "phase": "decode", "prompt": 20000, "cached": 2048, "output": 100],
        ["id": 5, "phase": "prefill", "prompt": 61000, "cached": 2048, "filled": 10240],
    ]

    @Test func test_解码中取外挂行的条数() {
        let collector = Collector(config: Config())
        let scene = Scene(collector)
        scene.at(1.0, health(BASE))
        let snap = scene.at(5.0, health(BASE, running: 3, dec: 2, pre: 1,
                                        hook: hook_rows(ROWS[0], ROWS[1], ROWS[2])),
                            metrics: ["waiting": 2, "kv_usage": [0.5, 0.0], "ttft_sum": 1599.727361, "ttft_count": 156])
        #expect(snap["hook"] == "ok")
        #expect(snap["state"] == "decode", "有流在解码就是解码中")
        #expect(snap["lanes"] == ["max": 5, "decoding": 2, "prefilling": 1, "waiting": 2])
        let decode = snap["decode"]!
        #expect(decode["output_tokens"] == .int(412), "两条解码中的流已输出 312 + 100")
        #expect(snap["context_used"] == .int(61000), "占用最大的那条是 61000")
        #expect(!snap["prefill"].isNone, "解码中仍然看得到在预填充的那条流")
        let prefill = snap["prefill"]!
        #expect(prefill["prompt_tokens"] == .int(61000))
        #expect(prefill["cached_tokens"] == .int(2048))
        #expect(prefill["filled_tokens"] == .int(10240))
        #expect(prefill["tps"].isNone, "只进了一个进度点，算不出速度")
        #expect(almostEqual(num(prefill["est_s"]), (61000 - 2048) / 2300, places: 4))
        #expect(prefill["cache_miss"] == .bool(false), "这一轮还没有结束的请求")
    }
}

// MARK: - 12. 平均预填充速度的滚动更新（初始 2300）

@Suite struct TestPrefillSpeed {
    let FIRST: [String: JSON] = [
        "total": 50, "c": 100000, "prompt": 400000, "cached": 200000,
        "prefill_s": 100.0, "decode_s": 300.0, "drafted": 20000, "accepted": 14000,
    ]
    // 新算 20000 个 token、预填充 8 秒，即 2500 tok/s
    let SECOND: [String: JSON] = [
        "total": 51, "c": 102000, "prompt": 425000, "cached": 205000,
        "prefill_s": 108.0, "decode_s": 304.0, "drafted": 21000, "accepted": 14800,
    ]
    // 新算 500 个 token、预填充 0.5 秒：不足 2048，不参与滚动
    let THIRD: [String: JSON] = [
        "total": 52, "c": 104000, "prompt": 425500, "cached": 205000,
        "prefill_s": 108.5, "decode_s": 306.0, "drafted": 21500, "accepted": 15100,
    ]
    let ROW = hook_rows(["id": 1, "phase": "prefill", "prompt": 24615, "cached": 0, "filled": 0])

    @Test func test_滚动平均从2300往上滚动() {
        let scene = Scene(Collector(config: Config()))
        scene.at(1.0, health(FIRST))
        scene.at(5.0, health(SECOND))
        let snap = scene.at(5.1, health(SECOND, running: 1, pre: 1, hook: ROW))
        #expect(almostEqual(num(snap["prefill"]?["est_s"]), 24615 / 2360, places: 4),
                "平均预填充速度该滚动到 0.7×2300 + 0.3×2500 = 2360")
    }

    @Test func test_新算不足2048的请求不更新滚动平均() {
        let scene = Scene(Collector(config: Config()))
        let rows = hook_rows(["id": 2, "phase": "prefill", "prompt": 24615, "cached": 0, "filled": 0])
        scene.at(1.0, health(FIRST))
        scene.at(5.0, health(SECOND))
        scene.at(5.1, health(THIRD))
        let snap = scene.at(5.2, health(THIRD, running: 1, pre: 1, hook: rows))
        #expect(almostEqual(num(snap["prefill"]?["est_s"]), 24615 / 2360, places: 4),
                "500 个新算 token 太少，2360 不变")
    }
}

// MARK: - 14. 快照里的 engine 和 prefill 的 estimated

@Suite struct TestEngineField {
    @Test func test_新建时平均预填充速度是2300() {
        #expect(Collector(config: Config()).prefillTps == 2300.0)
    }

    @Test func test_engine取最近一次读数的backend() {
        let scene = Scene(Collector(config: Config()))
        #expect(scene.at(1.0, health(BASE))["engine"].isNone, "没有 backend 时是 None")
        #expect(scene.at(2.0, dict(health(BASE), ["backend": "tensorfold"]))["engine"] == "tensorfold")
        for t in [3.0, 4.0, 5.0] {
            let snap = scene.at(t, nil)
            #expect(snap["engine"] == "tensorfold", "t=\(t) 离线时该沿用最近一次的值")
        }
        #expect(scene.last_snap()["state"] == "offline", "第三次读不到才进离线")
    }

    /// 和 TestHookPrefill 一样：预填充开始后 0.9/1.8/2.7 秒各涨 2048。
    private func filled_at(_ elapsed: Double) -> Int {
        if elapsed < 0.9 - 1e-9 { return 0 }
        if elapsed < 1.8 - 1e-9 { return 2048 }
        if elapsed < 2.7 - 1e-9 { return 4096 }
        return 6144
    }

    @Test func test_外挂好用时estimated是False() {
        let scene = Scene(Collector(config: Config()))
        scene.at(1.0, health(BASE))
        for t in every_tenth(10.0, 10.5) {
            let row: JSON = ["id": 1, "phase": "prefill", "prompt": 24615, "cached": 0,
                             "filled": .int(filled_at(round6(t - 10.0)))]
            scene.at(t, health(BASE, running: 1, pre: 1, hook: hook_rows(row)))
        }
        #expect((scene.last_snap()["prefill"]?["estimated"]) == .bool(false), "有 filled 就是准数，不算估算")
    }

    @Test func test_外挂失效时estimated是False() {
        let scene = Scene(Collector(config: Config()))
        scene.at(1.0, health(BASE))
        let metrics: JSON = ["waiting": 0, "kv_usage": [0.093899, 0.0], "ttft_sum": 1599.727361, "ttft_count": 156]
        for t in [10.0, 10.1, 10.2, 10.3, 10.4] {
            scene.at(t, health(BASE, running: 1, pre: 1), metrics: metrics)
        }
        let prefill = scene.last_snap()["prefill"]!
        #expect(prefill["estimated"] == .bool(false), "降级分支也标成不是估算")
        #expect(prefill["filled_tokens"].isNone)
    }
}

// MARK: - vLLM 辅助

/// 造一份 vLLM 适配器给出的统一读数（空闲基线：结束过 20 个请求）。
private func vhealth(
    running: Int = 0, dec: Int = 0, pre: Int = 0,
    total: JSON? = nil, c: JSON? = nil, prompt: JSON? = nil, cached: JSON? = nil,
    prefill_s: JSON? = nil, decode_s: JSON? = nil, drafted: JSON? = nil, accepted: JSON? = nil,
    maximum: JSON? = nil, epoch: JSON? = nil, aborted: JSON? = nil, finished_c: JSON? = nil,
    usage: JSON? = nil, rows: [JSON] = []
) -> JSON {
    let totalV = total ?? .int(20)
    let cV = c ?? .int(2000)
    let data: [String: JSON] = [
        "ok": true,
        "backend": "vllm",
        "requests_running": .int(running),
        "streams": ["decoding": .int(dec), "prefilling": .int(pre), "max": maximum ?? .int(4)],
        "requests_total": totalV,
        "completion_tokens_total": cV,
        "prompt_tokens_total": prompt ?? .int(160000),
        "cached_tokens_total": cached ?? .int(30000),
        "prefill_seconds_total": prefill_s ?? .double(60.0),
        "decode_seconds_total": decode_s ?? .double(61.0),
        "drafted_total": drafted ?? .int(5000),
        "accepted_total": accepted ?? .int(1300),
        "context_length": 262144,
        "epoch": epoch ?? .double(1000.0),
        "aborted_total": aborted ?? .int(0),
        "completion_finished_total": finished_c ?? .int(1900),
        "usage_totals": usage ?? ["prompt": 160100, "cached": 30000, "completion": cV, "requests": totalV],
        "tfpanel": ["v": 1, "streams": .array(rows)],
    ]
    return .object(data)
}

private func vmetrics(ttft_sum: JSON = 60.0, ttft_count: JSON = 20) -> JSON {
    ["waiting": 0, "kv_usage": [], "ttft_sum": ttft_sum, "ttft_count": ttft_count]
}

/// vLLM 适配器合成的一行：没有 filled，有 start 和 ttft_s。
private func vrow(_ sid: Int, _ phase: String, _ prompt: Int, cached: Int = 0, output: Int = 0,
                  start: Double = 0.0, ttft: Double? = nil) -> JSON {
    ["id": .int(sid), "phase": .string(phase), "prompt": .int(prompt), "cached": .int(cached),
     "output": .int(output), "start": .double(start), "ttft_s": JSON(ttft)]
}

/// 一个 24085 token 的请求：1.5 开始，3.5 才第一次被读到，10.4 出首字，13.5 结束，输出 160。
fileprivate func vllm_long_scene(usage: FakeUsage? = nil) -> (Collector, Scene) {
    let collector = Collector(config: Config(), usage: usage)
    let scene = Scene(collector)
    scene.at(1.0, vhealth(), metrics: vmetrics())
    for t in every_tenth(3.5, 10.3) {
        scene.at(t, vhealth(running: 1, pre: 1, rows: [vrow(1, "prefill", 24085, start: 1.5)]),
                 metrics: vmetrics())
    }
    var n = 0
    for t in every_tenth(10.4, 13.4) {
        n += 5
        scene.at(t, vhealth(running: 1, dec: 1, c: .int(2000 + n),
                            usage: ["prompt": 184185, "cached": 30000, "completion": .int(2000 + n), "requests": 20],
                            rows: [vrow(1, "decode", 24085, output: n, start: 1.06, ttft: 9.34)]),
                 metrics: vmetrics())
    }
    scene.at(13.5, vhealth(total: 21, c: 2160, prompt: 184085, prefill_s: 69.284, decode_s: 64.155,
                           drafted: 5420, accepted: 1401, finished_c: 2060,
                           usage: ["prompt": 184185, "cached": 30000, "completion": 2160, "requests": 21]),
             metrics: vmetrics(ttft_sum: 69.34, ttft_count: 21))
    return (collector, scene)
}

// MARK: - 15. vLLM 单个请求的全过程

@Suite struct TestVllmSingle {
    @Test func test_预填充用行里的开始时刻估算() {
        let (_, scene) = vllm_long_scene()
        let snap = scene.snap_at(3.5)
        #expect(snap["state"] == "prefill")
        #expect(snap["hook"] == "ok")
        #expect(snap["engine"] == "vllm")
        #expect((snap["lanes"]?["max"]) == .int(4))
        let prefill = snap["prefill"]!
        #expect(prefill["estimated"] == .bool(true), "行里没有 filled，只能估算")
        #expect(almostEqual(num(prefill["elapsed_s"]), 2.0, places: 6), "从行里的 start 算，不是从第一次读到算")
        #expect(prefill["prompt_tokens"] == .int(24085))
        #expect(prefill["cached_tokens"] == .int(0))
        #expect(almostEqual(num(prefill["est_s"]), 24085 / 2300, places: 4))
        #expect(prefill["filled_tokens"] == .int(4600))
        #expect(prefill["tps"] == 2300.0)
        #expect(almostEqual(num(prefill["remaining_s"]), 24085 / 2300 - 2.0, places: 4))
        #expect(prefill["cache_miss"] == .bool(false))
    }

    @Test func test_预填充快到最后() {
        let (_, scene) = vllm_long_scene()
        let prefill = scene.snap_at(10.3)["prefill"]!
        #expect(prefill["filled_tokens"] == .int(20240), "8.8 秒 × 2300 tok/s")
        #expect(almostEqual(num(prefill["elapsed_s"]), 8.8, places: 6))
    }

    @Test func test_估算进度最多到99() {
        let scene = Scene(Collector(config: Config()))
        scene.at(1.0, vhealth(), metrics: vmetrics())
        for t in every_tenth(3.5, 40.0, dt: 0.5) {
            scene.at(t, vhealth(running: 1, pre: 1, rows: [vrow(1, "prefill", 24085, start: 1.5)]),
                     metrics: vmetrics())
        }
        let prefill = scene.snap_at(40.0)["prefill"]!
        #expect(prefill["filled_tokens"] == .int(jsRound(24085 * 0.99)), "23844：进度封顶")
        #expect(prefill["remaining_s"] == 0.0)
    }

    @Test func test_解码中的首字取行里给的() {
        let (_, scene) = vllm_long_scene()
        let snap = scene.snap_at(11.0)
        #expect(snap["state"] == "decode")
        #expect(almostEqual(num(snap["decode"]?["ttft_s"]), 9.34, places: 6),
                "行里给了 9.34，不该用估算的 6.9")
        #expect((snap["decode"]?["output_tokens"]) == .int(35))
        #expect(snap["context_used"] == .int(24120))
    }

    @Test func test_结束后的各项数字() {
        let (collector, scene) = vllm_long_scene()
        let snap = scene.snap_at(13.5)
        #expect(snap["state"] == "done")
        let last = snap["last"]!
        #expect(last["prompt_tokens"] == .int(24085))
        #expect(last["cached_tokens"] == .int(0))
        #expect(last["completion_tokens"] == .int(160), "用完成数之差 2060 − 1900")
        #expect(almostEqual(num(last["decode_tps"]), 160 / 3.155, places: 4))
        #expect(almostEqual(num(last["prefill_tps"]), 24085 / 9.284, places: 4))
        #expect(almostEqual(num(last["ttft_s"]), 9.34, places: 4))
        #expect(almostEqual(num(last["acceptance_rate"]), 101 / 420, places: 4))
        #expect(last["context_used"] == .int(24245))
        #expect(almostEqual(collector.prefillTps, 0.7 * 2300 + 0.3 * 24085 / 9.284, places: 4))
    }

    @Test func test_记账带引擎启动标记() {
        let usage = FakeUsage()
        let (_, scene) = vllm_long_scene(usage: usage)
        #expect(usage.calls[0] == ["prompt": 160100, "cached": 30000, "completion": 2000, "requests": 20, "epoch": 1000.0])
        #expect(usage.calls.last == ["prompt": 184185, "cached": 30000, "completion": 2160, "requests": 21, "epoch": 1000.0])
    }
}

// MARK: - 16. 并发时结束的那个请求的输出用完成数这个准数

@Suite struct TestVllmFinishExact {
    @Test func test_结束的输出用完成数之差() {
        let scene = Scene(Collector(config: Config()))
        scene.at(1.0, vhealth(), metrics: vmetrics())
        scene.at(2.0, vhealth(running: 2, dec: 2, c: 2287,
                              rows: [vrow(1, "decode", 71, output: 170, ttft: 0.13),
                                     vrow(2, "decode", 3066, output: 117, ttft: 1.25)]),
                 metrics: vmetrics())
        let snap = scene.at(2.1, vhealth(running: 1, dec: 1, total: 21, c: 2300, prompt: 163066,
                                         prefill_s: 61.21, decode_s: 63.83, finished_c: 2050,
                                         rows: [vrow(1, "decode", 71, output: 250, ttft: 0.13)]),
                            metrics: vmetrics(ttft_sum: 61.25, ttft_count: 21))
        let last = snap["last"]!
        #expect(last["completion_tokens"] == .int(150), "2050 − 1900，不是行里估的 117")
        #expect(last["prompt_tokens"] == .int(3066))
        #expect(almostEqual(num(last["ttft_s"]), 1.25, places: 4))
        #expect(snap["state"] == "decode", "还剩一条在解码，不进完成画面")
    }
}

// MARK: - 17. 中途断开：不产生完成画面，但算本轮的一次活动

@Suite struct TestVllmAbort {
    /// 10.0 到 19.9 一条在解码，20.0 断开。
    private func drive() -> (Collector, Scene) {
        let collector = Collector(config: Config())
        let scene = Scene(collector)
        scene.at(1.0, vhealth(), metrics: vmetrics())
        for t in every_tenth(10.0, 19.9) {
            let k = Int(((t - 10) * 10).rounded())
            scene.at(t, vhealth(running: 1, dec: 1, c: .int(2000 + k),
                                rows: [vrow(1, "decode", 67, output: k, start: 9.9, ttft: 0.13)]),
                     metrics: vmetrics())
        }
        scene.at(20.0, vhealth(c: 2100, aborted: 1), metrics: vmetrics())
        return (collector, scene)
    }

    @Test func test_断开那次是空闲() {
        let (_, scene) = drive()
        let snap = scene.snap_at(20.0)
        #expect(snap["state"] == "idle", "没有请求结束，不该有完成画面")
        #expect(snap["last"].isNone)
        #expect((snap["lanes"]?["decoding"]) == .int(0))
        #expect((snap["lanes"]?["prefilling"]) == .int(0))
        let rnd = snap["round"]!
        #expect(rnd["requests"] == .int(0))
        #expect(rnd["running"] == .int(0))
        #expect(rnd["output_tokens"] == .int(100))
    }

    @Test func test_断开的时刻算本轮的最后活动() {
        let (_, scene) = drive()
        scene.at(75.0, vhealth(c: 2100, aborted: 1), metrics: vmetrics())
        #expect((scene.snap_at(75.0)["round"]?["active"]) == .bool(true),
                "一轮的最后活动是断开的 20.0，不是这一轮开始的 10.0")
        scene.at(81.0, vhealth(c: 2100, aborted: 1), metrics: vmetrics())
        #expect((scene.snap_at(81.0)["round"]?["active"]) == .bool(false))
    }

    @Test func test_断开之后来了正常请求() {
        let (_, scene) = drive()
        scene.at(75.0, vhealth(c: 2100, aborted: 1), metrics: vmetrics())
        scene.at(81.0, vhealth(c: 2100, aborted: 1), metrics: vmetrics())
        scene.at(90.0, vhealth(running: 1, dec: 1, c: 2110, aborted: 1,
                               rows: [vrow(2, "decode", 65, output: 10, start: 89.9, ttft: 0.12)]),
                 metrics: vmetrics())
        let snap = scene.at(90.5, vhealth(total: 21, c: 2140, prompt: 160065,
                                          prefill_s: 60.1, decode_s: 61.6, aborted: 1, finished_c: 1940),
                            metrics: vmetrics(ttft_sum: 60.12, ttft_count: 21))
        #expect(snap["state"] == "done")
        let last = snap["last"]!
        #expect(last["completion_tokens"] == .int(40), "1940 − 1900")
        #expect(last["prompt_tokens"] == .int(65))
        #expect(almostEqual(num(last["ttft_s"]), 0.12, places: 4))
        #expect((snap["round"]?["requests"]) == .int(1), "断开不算一个请求")
        #expect((snap["round"]?["output_tokens"]) == .int(40))
    }
}

// MARK: - 18. 引擎换了启动标记：当作重启，既不产生结束也不开新一轮

@Suite struct TestVllmRestart {
    @Test func test_启动标记变了当作重启() {
        let scene = Scene(Collector(config: Config()))
        scene.at(1.0, vhealth(), metrics: vmetrics())
        scene.at(2.0, vhealth(running: 1, dec: 1, c: 2010,
                              rows: [vrow(1, "decode", 67, output: 10, ttft: 0.1)]), metrics: vmetrics())
        let snap = scene.at(2.1, vhealth(total: 30, c: 5000, prompt: 200000, epoch: 2000.0,
                                         finished_c: 4900), metrics: vmetrics())
        #expect(snap["state"] == "idle", "累计值都变大了，但只有启动标记变了")
        #expect(snap["round"].isNone)
        #expect(snap["last"].isNone)
        #expect(snap["engine"] == "vllm")
    }
}
