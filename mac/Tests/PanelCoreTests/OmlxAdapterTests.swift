// 翻译自 docs/tasks/mac/ref/test_omlx_adapter.py 的 TestOmlxAdapter：参考适配器的单元测试。
import Foundation
import Testing
@testable import PanelCore

private let WALL0 = 1793330000.0

/// 造 /api/status 读数（参数名、默认值照 Python 的 status()；default 是关键字，Swift 里叫 def）
private func status(req: Int = 0, prompt: Int = 0, cached: Int = 0, comp: Int = 0, active: Int = 0,
                    waiting: Int = 0, uptime: Double = 100.0, def: String = "M") -> JSON {
    let d: [String: JSON] = [
        "total_requests": .int(req), "total_prompt_tokens": .int(prompt),
        "total_cached_tokens": .int(cached), "total_completion_tokens": .int(comp),
        "active_requests": .int(active), "waiting_requests": .int(waiting),
        "uptime_seconds": .double(uptime), "default_model": .string(def),
    ]
    return .object(d)
}

private func stats(_ models: JSON...) -> JSON {
    ["active_models": ["models": .array(models)]]
}

private func model(name: String = "M", waiting: [JSON] = [], prefilling: [JSON] = [],
                   generating: [JSON] = [], loading: JSON? = nil) -> JSON {
    var m: [String: JSON] = [
        "id": .string(name), "is_loading": .bool(loading != nil),
        "waiting": .array(waiting), "prefilling": .array(prefilling),
        "generating": .array(generating),
    ]
    if let loading, let lo = loading.object {
        for (k, v) in lo { m[k] = v }  // m.update(loading)
    }
    return .object(m)
}

private func w(_ rid: String, _ elapsed: Double, _ prompt: Int) -> JSON {
    let d: [String: JSON] = ["request_id": .string(rid), "queue_position": .int(1),
                             "elapsed_seconds": .double(elapsed), "prompt_tokens": .int(prompt)]
    return .object(d)
}

private func p(_ rid: String, _ processed: Int, _ prompt: Int, cached: Int = 0, elapsed: Double = 0.0) -> JSON {
    let d: [String: JSON] = ["request_id": .string(rid), "processed": .int(processed),
                             "total": .int(prompt), "speed": .double(0.0),
                             "elapsed": .double(elapsed), "prompt_tokens": .int(prompt),
                             "cached_tokens": .int(cached)]
    return .object(d)
}

private func g(_ rid: String, _ out: Int, _ elapsed: Double, _ prompt: Int) -> JSON {
    let d: [String: JSON] = ["request_id": .string(rid), "generated_tokens": .int(out),
                             "elapsed_seconds": .double(elapsed), "prompt_tokens": .int(prompt),
                             "max_tokens": .int(1000)]
    return .object(d)
}

@Suite struct TestOmlxAdapter {
    let ad: OmlxAdapter

    init() {
        ad = OmlxAdapter()
        let ms: [JSON] = [["id": "M", "max_model_len": 40960], ["id": "N", "max_model_len": 8192],
                          ["id": "bad", "max_model_len": true]]
        ad.setModels(.array(ms))
    }

    private func feed(_ t: Double, _ st: JSON?, _ sx: JSON?, uptimeShift: Double = 0.0) -> (health: JSON, metrics: JSON)? {
        ad.feed(now: t, wall: WALL0 + t + uptimeShift, status: st, stats: sx)
    }

    @Test func test_状态不是字典或累计值缺了返回None() {
        #expect(feed(0.0, nil, stats()) == nil)
        #expect(feed(0.0, .int(401), stats()) == nil)
        var bad = status().object!
        bad["total_cached_tokens"] = nil
        #expect(feed(0.0, .object(bad), stats()) == nil)
        bad = status().object!
        bad["total_requests"] = .bool(true)
        #expect(feed(0.0, .object(bad), stats()) == nil)
    }

    @Test func test_第一次读数带基线和固定字段() {
        let (h, m) = feed(0.0, status(req: 3, prompt: 100, cached: 20, comp: 50), stats(model()))!
        #expect(h["backend"] == "omlx")
        #expect(h["ok"] == .bool(true))
        #expect(h["requests_total"] == 3)
        #expect(h["completion_tokens_total"] == 50)
        #expect(h["completion_finished_total"] == 50)
        let streamsWant: JSON = ["decoding": 0, "prefilling": 0, "max": 8]
        #expect(h["streams"] == streamsWant)
        #expect(h["drafted_total"] == 0)
        #expect(h["accepted_total"] == 0)
        #expect(h["epoch"] == .int(Int((WALL0 - 100.0).rounded(.toNearestOrEven))))  // int(round(WALL0 - 100.0))
        #expect(h["context_length"] == 40960)
        let utWant: JSON = ["prompt": 100, "cached": 20, "completion": 50, "requests": 3]
        #expect(h["usage_totals"] == utWant)
        let ubmWant: JSON = ["M": ["prompt": 100, "cached": 20, "completion": 50, "requests": 3]]
        #expect(h["usage_by_model"] == ubmWant)
        let tfWant: JSON = ["v": 1, "streams": []]
        #expect(h["tfpanel"] == tfWant)
        let mWant: JSON = ["waiting": 0, "kv_usage": [], "ttft_sum": 0.0, "ttft_count": 0]
        #expect(m == mWant)
        #expect(h["loading"] == nil)
        #expect(ad.modelName == "M")
    }

    @Test func test_第一次读数里正在解码的行不知道首字时间() {
        let (h, _) = feed(10.0, status(active: 1), stats(model(generating: [g("a", 30, 2.0, 500)])))!
        let row = h["tfpanel"]!["streams"]![0]!
        #expect(row["phase"] == "decode")
        #expect(row["start"] == 8.0)
        #expect(row["ttft_s"].isNone)
        #expect(row["filled"] == 500)
        #expect(h["completion_tokens_total"] == 30)
    }

    @Test func test_占位领开始时刻且有占位时不带tfpanel() {
        _ = feed(0.0, status(), stats(model()))
        let (h1, _) = feed(1.0, status(active: 1), stats(model()))!
        #expect(h1["tfpanel"] == nil)
        #expect(h1["streams"]!["prefilling"] == 1)
        #expect(h1["requests_running"] == 1)
        _ = feed(1.1, status(active: 1), stats(model()))  // 占位的开始时刻不变
        let (h2, _) = feed(1.5, status(active: 1),
                           stats(model(prefilling: [p("a", 2048, 9000, elapsed: 0.2)])))!
        let row2 = h2["tfpanel"]!["streams"]![0]!
        #expect(row2["start"] == 1.0)
        #expect(row2["filled"] == 2048)
        let (h3, _) = feed(4.0, status(active: 1),
                           stats(model(generating: [g("a", 3, 0.25, 9000)])))!
        let row3 = h3["tfpanel"]!["streams"]![0]!
        #expect(almostEqual(row3["ttft_s"]!.number!, 2.75))
        #expect(row3["cached"] == 0)
    }

    @Test func test_排队的行按已等待秒数回推开始时刻且不进tfpanel() {
        _ = feed(0.0, status(), stats(model()))
        let (h, m) = feed(2.0, status(active: 2, waiting: 1),
                          stats(model(waiting: [w("b", 0.5, 300)], generating: [g("a", 5, 0.4, 100)])))!
        #expect(m["waiting"] == 1)
        let phases = (h["tfpanel"]!["streams"]!.array!).map { $0["phase"]?.string ?? "" }
        #expect(phases == ["decode"])
        #expect(h["requests_running"] == 2)
        let (h2, _) = feed(3.0, status(active: 2),
                           stats(model(prefilling: [p("b", 512, 300, cached: 256, elapsed: 0.3)],
                                       generating: [g("a", 9, 1.4, 100)])))!
        var rows: [Int: JSON] = [:]
        for r in h2["tfpanel"]!["streams"]!.array! { rows[r["id"]!.int!] = r }
        #expect(rows[1]!["start"] == 1.5)  // 排队的行先编号
        #expect(rows[1]!["cached"] == 256)
        #expect(rows[1]!["filled"] == 512)
        #expect(rows[2]!["start"] == 0.8)  // 第一次见到就在解码：取上次读数（0）和开始解码（1.6）的中点
    }

    @Test func test_正常结束记首字和两项累计秒数() {
        _ = feed(0.0, status(), stats(model()))
        _ = feed(1.0, status(active: 1), stats(model(prefilling: [p("a", 2048, 4000, elapsed: 0.5)])))
        _ = feed(3.0, status(active: 1), stats(model(generating: [g("a", 10, 0.5, 4000)])))
        _ = feed(4.0, status(active: 1), stats(model(generating: [g("a", 40, 1.5, 4000)])))
        let (h, m) = feed(4.2, status(req: 1, prompt: 4000, comp: 45), stats(model()))!
        #expect(m["ttft_count"] == 1)
        #expect(almostEqual(m["ttft_sum"]!.number!, 2.0))                // 3.0 − 0.5 − 0.5
        #expect(almostEqual(h["prefill_seconds_total"]!.number!, 2.0))    // 没排队，首字时间全算预填充
        #expect(almostEqual(h["decode_seconds_total"]!.number!, 1.6875))  // 1.5 × 45 / 40：补上最后一次读数之后的那段
        #expect(h["tfpanel"]!["streams"] == [])
        #expect(h["completion_tokens_total"] == 45)
        #expect(h["aborted_total"] == 0)
    }

    @Test func test_短回答按最终输出补上解码秒数() {
        _ = feed(0.0, status(), stats(model()))
        _ = feed(1.0, status(active: 1), stats(model(generating: [g("a", 8, 0.08, 13)])))
        let (h, _) = feed(1.25, status(req: 1, prompt: 13, comp: 15), stats(model()))!
        #expect(almostEqual(h["decode_seconds_total"]!.number!, 0.15))   // 0.08 × 15 / 8
    }

    @Test func test_对不上个数时不补解码秒数() {
        _ = feed(0.0, status(), stats(model()))
        _ = feed(1.0, status(active: 2), stats(model(generating: [g("a", 8, 0.08, 13), g("b", 4, 0.04, 13)])))
        // 累计请求数只加了 1：结束一行，另一行还在等，增量里分不清是谁的输出
        let (h, _) = feed(1.25, status(req: 1, prompt: 13, comp: 15), stats(model()))!
        #expect(almostEqual(h["decode_seconds_total"]!.number!, 0.08))
    }

    @Test func test_排队时间不算预填充秒数() {
        _ = feed(0.0, status(), stats(model()))
        _ = feed(1.0, status(active: 1, waiting: 1), stats(model(waiting: [w("a", 0.0, 100)])))
        _ = feed(2.0, status(active: 1), stats(model(prefilling: [p("a", 50, 100, elapsed: 0.4)])))
        _ = feed(3.0, status(active: 1), stats(model(generating: [g("a", 2, 0.2, 100)])))
        let (h, m) = feed(3.5, status(req: 1, prompt: 100, comp: 5), stats(model()))!
        #expect(almostEqual(m["ttft_sum"]!.number!, 1.8))              // 3.0 − 0.2 − 1.0
        #expect(almostEqual(h["prefill_seconds_total"]!.number!, 1.2))  // 减去排队的 0.6 秒
    }

    @Test func test_消失后累计请求数晚到也算正常结束() {
        _ = feed(0.0, status(), stats(model()))
        _ = feed(1.0, status(active: 1), stats(model(generating: [g("a", 5, 0.1, 10)])))
        let (h1, _) = feed(1.1, status(active: 1), stats(model()))!
        let phases = (h1["tfpanel"]!["streams"]!.array!).map { $0["phase"]?.string ?? "" }
        #expect(phases == ["decode"])  // 还留着
        #expect(h1["completion_tokens_total"] == 5)
        let (h2, _) = feed(1.4, status(req: 1, prompt: 10, comp: 8), stats(model()))!
        #expect(h2["tfpanel"]!["streams"] == [])
        #expect(h2["aborted_total"] == 0)
        #expect(h2["completion_tokens_total"] == 8)
    }

    @Test func test_消失一秒还没对上算中途断开() {
        _ = feed(0.0, status(), stats(model()))
        _ = feed(1.0, status(active: 1), stats(model(generating: [g("a", 50, 0.5, 30)])))
        let (h1, _) = feed(1.1, status(), stats(model()))!
        #expect(h1["aborted_total"] == 0)
        let (h2, _) = feed(2.05, status(), stats(model()))!
        #expect(h2["aborted_total"] == 0)
        let (h3, _) = feed(2.1, status(), stats(model()))!
        #expect(h3["aborted_total"] == 1)
        #expect(h3["tfpanel"]!["streams"] == [])
        #expect(h3["completion_tokens_total"] == 50)  // 断开带走的输出照样算
        #expect(h3["completion_finished_total"] == 0)
        let utWant: JSON = ["prompt": 30, "cached": 0, "completion": 50, "requests": 0]
        #expect(h3["usage_totals"] == utWant)
        let ubmWant: JSON = ["prompt": 30, "cached": 0, "completion": 50, "requests": 0]
        #expect(h3["usage_by_model"]!["M"] == ubmWant)
    }

    @Test func test_排队时断开不计用量() {
        _ = feed(0.0, status(), stats(model()))
        _ = feed(1.0, status(active: 1, waiting: 1), stats(model(waiting: [w("a", 0.2, 900)])))
        _ = feed(2.5, status(), stats(model()))
        let (h, _) = feed(3.5, status(), stats(model()))!
        #expect(h["aborted_total"] == 1)
        #expect(h["usage_totals"]!["prompt"] == 0)
    }

    @Test func test_重新出现的行接着用() {
        _ = feed(0.0, status(), stats(model()))
        _ = feed(1.0, status(active: 1), stats(model(prefilling: [p("a", 512, 2000, elapsed: 0.3)])))
        let (h1, _) = feed(1.1, status(active: 1), stats(model()))!
        #expect(h1["streams"]!["prefilling"] == 1)
        #expect(h1["requests_running"] == 1)
        let (h2, _) = feed(1.2, status(active: 1),
                           stats(model(generating: [g("a", 1, 0.05, 2000)])))!
        let rows = h2["tfpanel"]!["streams"]!.array!
        #expect(rows.count == 1)
        #expect(rows[0]["id"] == 1)
        #expect(rows[0]["phase"] == "decode")
    }

    @Test func test_多条同时结束取最早的且解码行优先() {
        _ = feed(0.0, status(), stats(model()))
        _ = feed(1.0, status(active: 3),
                 stats(model(prefilling: [p("c", 10, 500, elapsed: 0.0)],
                             generating: [g("a", 5, 0.5, 100), g("b", 5, 0.2, 200)])))
        let (h, _) = feed(1.2, status(req: 1, prompt: 100, comp: 9, active: 2), stats(model()))!
        let ids = (h["tfpanel"]!["streams"]!.array!).map { $0["id"]?.int ?? -1 }
        // 新行按排队、预填充、解码的顺序编号：c=1、a=2、b=3；a 开始最早，先算它结束
        #expect(ids == [1, 3])
    }

    @Test func test_用量按结束的行的提示长度分到各模型() {
        _ = feed(0.0, status(), stats(model(name: "M"), model(name: "N")))
        _ = feed(1.0, status(active: 2),
                 stats(model(name: "M", generating: [g("a", 5, 0.5, 300)]),
                       model(name: "N", generating: [g("b", 5, 0.5, 100)])))
        let (h, _) = feed(1.5, status(req: 2, prompt: 400, cached: 10, comp: 21),
                          stats(model(name: "M"), model(name: "N")))!
        let mWant: JSON = ["prompt": 300, "cached": 8, "completion": 16, "requests": 2]
        #expect(h["usage_by_model"]!["M"] == mWant)
        let nWant: JSON = ["prompt": 100, "cached": 2, "completion": 5, "requests": 0]
        #expect(h["usage_by_model"]!["N"] == nWant)
        let ubm = h["usage_by_model"]!.object!
        var total: [String: JSON] = [:]
        for k in ["prompt", "cached", "completion", "requests"] {
            total[k] = .int(ubm.values.reduce(0) { $0 + ($1[k]?.int ?? 0) })
        }
        #expect(JSON.object(total) == h["usage_totals"])
    }

    @Test func test_没对上行的增量记在最近开始的模型名下() {
        _ = feed(0.0, status(), stats(model(name: "M"), model(name: "N")))
        _ = feed(1.0, status(active: 1),
                 stats(model(name: "M"), model(name: "N", generating: [g("b", 1, 0.1, 10)])))
        let (h, _) = feed(1.1, status(req: 1, prompt: 7, comp: 3, active: 1),
                          stats(model(name: "M"), model(name: "N", generating: [g("b", 2, 0.2, 10)])))!
        let nWant: JSON = ["prompt": 7, "cached": 0, "completion": 3, "requests": 1]
        #expect(h["usage_by_model"]!["N"] == nWant)
        #expect(ad.modelName == "N")
        #expect(h["context_length"] == 8192)
    }

    @Test func test_累计值变小算重启() {
        _ = feed(0.0, status(req: 5, prompt: 50, comp: 50), stats(model()))
        _ = feed(1.0, status(req: 5, prompt: 50, comp: 50, active: 1), stats(model(generating: [g("a", 5, 0.5, 10)])))
        let (h, _) = feed(2.0, status(req: 0, uptime: 1.0), stats(model()))!
        #expect(h["tfpanel"]!["streams"] == [])
        #expect(h["completion_tokens_total"] == 0)
        #expect(h["epoch"] == .int(Int((WALL0 + 2.0 - 1.0).rounded(.toNearestOrEven))))  // int(round(WALL0 + 2.0 - 1.0))
        let ubmWant: JSON = ["M": ["prompt": 0, "cached": 0, "completion": 0, "requests": 0]]
        #expect(h["usage_by_model"] == ubmWant)
    }

    @Test func test_启动时刻抖动不算重启跳得多才算() {
        let (h0, _) = feed(0.0, status(req: 1), stats(model()))!
        let (h1, _) = feed(1.0, status(req: 1, uptime: 100.0), stats(model()), uptimeShift: -0.4)!
        #expect(h1["epoch"] == h0["epoch"])
        _ = feed(2.0, status(req: 1, active: 1), stats(model(generating: [g("a", 1, 0.1, 10)])))
        let (h2, _) = feed(3.0, status(req: 1, uptime: 103.0), stats(model()), uptimeShift: 60.0)!
        #expect(h2["epoch"] != h0["epoch"])
        #expect(h2["tfpanel"]!["streams"] == [])
        #expect(h2["aborted_total"] == 0)
    }

    @Test func test_完成输出累计只增不减() {
        _ = feed(0.0, status(), stats(model()))
        let (h1, _) = feed(1.0, status(active: 1), stats(model(generating: [g("a", 40, 0.5, 10)])))!
        #expect(h1["completion_tokens_total"] == 40)
        // 累计请求数先跟上、行还在：合计会重复算一次，之后不往回掉
        let (h2, _) = feed(1.1, status(req: 1, prompt: 10, comp: 42, active: 0),
                           stats(model(generating: [g("a", 42, 0.6, 10)])))!
        #expect(h2["completion_tokens_total"] == 84)
        let (h3, _) = feed(1.2, status(req: 1, prompt: 10, comp: 42), stats(model()))!
        #expect(h3["completion_tokens_total"] == 84)
        #expect(h3["tfpanel"]!["streams"] == [])
    }

    @Test func test_加载中带loading字段() {
        let ld1: JSON = ["loading_elapsed_seconds": 1.5, "loading_estimated_seconds": 20,
                        "estimated_size": .int(2 * 1073741824)]
        let (h1, _) = feed(0.0, status(), stats(model(loading: ld1)))!
        let want1: JSON = ["model": "M", "elapsed_s": 1.5, "estimated_s": 20.0, "size_gb": 2.0]
        #expect(h1["loading"] == want1)
        #expect(ad.modelName == "M")
        let ld2: JSON = ["loading_elapsed_seconds": 2.0, "loading_estimated_seconds": .null,
                        "estimated_size": .null]
        let (h2, _) = feed(0.5, status(), stats(model(loading: ld2)))!
        let want2: JSON = ["model": "M", "elapsed_s": 2.0, "estimated_s": .null, "size_gb": .null]
        #expect(h2["loading"] == want2)
        let (h3, _) = feed(1.0, status(), stats(model()))!
        #expect(h3["loading"] == nil)
    }

    @Test func test_详情读不到时降级() {
        let ld: JSON = ["loading_elapsed_seconds": 1.0, "loading_estimated_seconds": 9]
        _ = feed(0.0, status(req: 1, prompt: 5, comp: 5), stats(model(loading: ld)))
        let (h, m) = feed(0.5, status(req: 2, prompt: 9, comp: 7, active: 3, waiting: 1), nil)!
        #expect(h["tfpanel"] == nil)
        #expect(h["requests_running"] == 3)
        let streamsWant: JSON = ["decoding": 2, "prefilling": 0, "max": 8]
        #expect(h["streams"] == streamsWant)
        #expect(m["waiting"] == 1)
        #expect(h["requests_total"] == 2)
        let utWant: JSON = ["prompt": 5, "cached": 0, "completion": 5, "requests": 1]
        #expect(h["usage_totals"] == utWant)
        #expect(h["loading"]!["elapsed_s"] == 1.5)
        // 详情恢复后，增量照常记账
        let (h2, _) = feed(1.0, status(req: 2, prompt: 9, comp: 7), stats(model()))!
        let utWant2: JSON = ["prompt": 9, "cached": 0, "completion": 7, "requests": 2]
        #expect(h2["usage_totals"] == utWant2)
        #expect(h2["usage_by_model"]!["M"]!["requests"] == 2)
    }

    @Test func test_上下文上限读不到用默认值() {
        let ad2 = OmlxAdapter()
        let (h, _) = ad2.feed(now: 0.0, wall: WALL0, status: status(def: "X"), stats: stats())!
        #expect(h["context_length"] == 262144)
        #expect(ad2.modelName == "X")
    }

    @Test func test_并发上限可以设() {
        let ad2 = OmlxAdapter(maxStreams: 16)
        let (h, _) = ad2.feed(now: 0.0, wall: WALL0, status: status(), stats: stats())!
        #expect(h["streams"]!["max"] == 16)
    }
}
