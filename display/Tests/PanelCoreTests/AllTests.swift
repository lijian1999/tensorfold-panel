import CoreGraphics
import Foundation
import Testing
import PanelCore

/// 构造一份 decode 状态的指标（可指定 current）
func decodeMetrics(state: String? = "decode", model: String? = "Qwen3.8-27B-MLX-4bit") -> Metrics {
    Metrics(
        state: state,
        model: model,
        hooks: .init(chat: "ok"),
        current: .init(elapsedS: 3.21, ttftS: 0.457, outputTokens: 312, decodeTps: 58.4, decodeTpsPeak: 71.2),
        last: .init(
            promptTokens: 22, cachedTokens: 0, completionTokens: 570,
            decodeTps: 58.2, ttftS: 0.457, acceptanceRate: 0.64,
            contextUsed: 592, finishReason: "stop"
        )
    )
}

@Suite("ConnectionTracker：连接状态机")
struct ConnectionTrackerTests {
    @Test("启动后还没有成功过 = 离线")
    func neverSucceeded() {
        let t = ConnectionTracker(bootTime: 100)
        #expect(t.isOffline)
        #expect(t.offlineSince == 100)
    }

    @Test("2 次失败仍在线，第 3 次失败离线")
    func threeFailures() {
        var t = ConnectionTracker(bootTime: 100)
        t.recordSuccess(decodeMetrics(), at: 101)
        #expect(!t.isOffline)
        t.recordFailure(at: 102)
        #expect(!t.isOffline)
        t.recordFailure(at: 102.3)
        #expect(!t.isOffline)
        t.recordFailure(at: 102.6)
        #expect(t.isOffline)
        #expect(t.offlineSince == 102)   // 第一次失败的时间
    }

    @Test("成功后恢复在线，offlineSince 复位")
    func recovers() {
        var t = ConnectionTracker(bootTime: 100)
        t.recordSuccess(decodeMetrics(), at: 101)
        t.recordFailure(at: 102)
        t.recordFailure(at: 102.3)
        t.recordFailure(at: 102.6)
        #expect(t.isOffline)
        t.recordSuccess(decodeMetrics(), at: 105)
        #expect(!t.isOffline)
        #expect(t.failureCount == 0)
        #expect(t.fetchedAt == 105)
    }

    @Test("从未成功时 offlineSince = 启动时间（即使失败过）")
    func offlineSinceBoot() {
        var t = ConnectionTracker(bootTime: 100)
        t.recordFailure(at: 101)
        t.recordFailure(at: 101.3)
        t.recordFailure(at: 101.6)
        #expect(t.isOffline)
        #expect(t.offlineSince == 100)
    }

    @Test("离线后仍保留 rememberedLast / rememberedModel")
    func remembers() {
        var t = ConnectionTracker(bootTime: 100)
        t.recordSuccess(decodeMetrics(), at: 101)
        t.recordFailure(at: 102)
        t.recordFailure(at: 102.3)
        t.recordFailure(at: 102.6)
        #expect(t.isOffline)
        #expect(t.rememberedModel == "Qwen3.8-27B-MLX-4bit")
        #expect(t.rememberedLast?.decodeTps == 58.2)
        #expect(t.rememberedLast?.contextUsed == 592)
        #expect(t.lastSuccess?.state == "decode")
    }

    @Test("小曲线：0.1 秒节流")
    func sparkThrottle() {
        var t = ConnectionTracker(bootTime: 100)
        t.recordSuccess(decodeMetrics(state: "idle"), at: 101)
        t.recordSuccess(decodeMetrics(), at: 102)          // 第一次 decode：1 个样本
        #expect(t.sparkSamples.count == 1)
        t.recordSuccess(decodeMetrics(), at: 102.05)       // 距上次 0.05s < 0.1：不追加
        #expect(t.sparkSamples.count == 1)
        t.recordSuccess(decodeMetrics(), at: 102.15)       // 距上次 0.15s ≥ 0.1：追加
        #expect(t.sparkSamples.count == 2)
        #expect(t.sparkSamples.last?.smooth == 58.4)
    }

    @Test("小曲线：最多保留 80 个")
    func sparkCap() {
        var t = ConnectionTracker(bootTime: 100)
        var time = 0.0
        for _ in 0..<200 {
            time += 0.1
            t.recordSuccess(decodeMetrics(), at: time)
        }
        #expect(t.sparkSamples.count == 80)
    }

    @Test("小曲线：进入 prefill 清空")
    func sparkClearedOnPrefill() {
        var t = ConnectionTracker(bootTime: 100)
        t.recordSuccess(decodeMetrics(), at: 102)
        t.recordSuccess(decodeMetrics(), at: 102.15)
        #expect(t.sparkSamples.count == 2)
        t.recordSuccess(decodeMetrics(state: "prefill"), at: 103)
        #expect(t.sparkSamples.isEmpty)
    }

    @Test("小曲线：raw = 最近 1 秒 output_tokens 增量 ÷ max(0.25, min(1, 已进行秒数))")
    func sparkRaw() {
        var t = ConnectionTracker(bootTime: 100)
        var m1 = decodeMetrics()
        m1.current?.elapsedS = 3.0
        m1.current?.outputTokens = 100
        t.recordSuccess(m1, at: 100)
        var m2 = decodeMetrics()
        m2.current?.elapsedS = 3.25
        m2.current?.outputTokens = 130
        t.recordSuccess(m2, at: 100.25)
        let s = t.sparkSamples.last!
        #expect(s.smooth == 58.4)
        // 增量 30 ÷ max(0.25, min(1, 3.25 − 0.457)) = 30 ÷ 1 = 30
        #expect(abs(s.raw - 30) < 1e-9)
    }

    @Test("小曲线：raw 分母 = 解码已进行秒数（elapsed_s − ttft_s）")
    func sparkRawDenominator() {
        var t = ConnectionTracker(bootTime: 0)
        // 预填充 5 秒、解码 0.5 秒：分母应为 0.5，而不是含预填充的 elapsed_s（→ 1）
        var m1 = decodeMetrics()
        m1.current = .init(elapsedS: 5.0, ttftS: 5.0, outputTokens: 100, decodeTps: 50, decodeTpsPeak: nil)
        t.recordSuccess(m1, at: 10)                    // 首字刚到：首个样本，raw = smooth
        var m2 = decodeMetrics()
        m2.current = .init(elapsedS: 5.5, ttftS: 5.0, outputTokens: 125, decodeTps: 50, decodeTpsPeak: nil)
        t.recordSuccess(m2, at: 10.5)
        let s = t.sparkSamples.last!
        // 增量 25 ÷ 0.5 = 50（若误用含预填充的 elapsed_s 则为 25 ÷ 1 = 25）
        #expect(abs(s.raw - 50) < 1e-9)
    }

    @Test("小曲线：elapsed_s/ttft_s 缺失时用 t − 首个 decode 样本时间（下限 0.25 秒）")
    func sparkRawFallback() {
        var t = ConnectionTracker(bootTime: 0)
        var m1 = decodeMetrics()
        m1.current = .init(elapsedS: nil, ttftS: nil, outputTokens: 100, decodeTps: 50, decodeTpsPeak: nil)
        t.recordSuccess(m1, at: 10)
        var m2 = decodeMetrics()
        m2.current = .init(elapsedS: nil, ttftS: nil, outputTokens: 130, decodeTps: 50, decodeTpsPeak: nil)
        t.recordSuccess(m2, at: 10.15)
        let s = t.sparkSamples.last!
        // 增量 30 ÷ max(0.25, min(1, 0.15)) = 30 ÷ 0.25 = 120
        #expect(abs(s.raw - 120) < 1e-9)
    }

    @Test("decode → done 保留小曲线样本，新请求才清空")
    func decodeContinues() {
        var t = ConnectionTracker(bootTime: 100)
        t.recordSuccess(decodeMetrics(), at: 100)
        t.recordSuccess(decodeMetrics(), at: 100.15)
        t.recordSuccess(decodeMetrics(), at: 100.3)
        #expect(t.sparkSamples.count == 3)
        t.recordSuccess(decodeMetrics(), at: 101)          // 仍在 decode：不清空
        #expect(t.sparkSamples.count == 4)
        t.recordSuccess(decodeMetrics(state: "done"), at: 102)
        #expect(t.sparkSamples.count == 4)                 // decode → done：保留
        t.recordSuccess(decodeMetrics(state: "idle"), at: 107)
        #expect(t.sparkSamples.count == 4)                 // done → idle：仍保留
        t.recordSuccess(decodeMetrics(state: "prefill"), at: 108)
        #expect(t.sparkSamples.isEmpty)                    // 新请求（prefill）：清空
    }

    @Test("done 画面：有小曲线样本时 showSpark 且 spark 非空")
    func doneShowsSpark() {
        var t = ConnectionTracker(bootTime: 100)
        for i in 0..<8 {
            t.recordSuccess(decodeMetrics(), at: 100 + Double(i) * 0.15)
        }
        #expect(t.sparkSamples.count == 8)
        t.recordSuccess(decodeMetrics(state: "done"), at: 110)
        let v = PanelViewModel.make(tracker: t, now: 110, memory: nil)
        #expect(v.state == .done)
        #expect(v.showSpark)
        #expect(!v.spark.isEmpty)
        #expect(v.spark.count == 8)
    }
}

@Suite("Format：与原型 JS 逐字一致")
struct FormatTests {
    @Test("tokFmt：原值 / 一位小数 K / 整数 K")
    func tokFmt() {
        #expect(Format.tokFmt(1000) == "1.0K")
        #expect(Format.tokFmt(6200) == "6.2K")
        #expect(Format.tokFmt(12400) == "12.4K")
        #expect(Format.tokFmt(99949) == "99.9K")
        #expect(Format.tokFmt(99950) == "100K")
        #expect(Format.tokFmt(262144) == "262K")
        #expect(Format.tokFmt(999) == "999")
        #expect(Format.tokFmt(0) == "0")
        #expect(Format.tokFmt(600) == "600")
        // 先四舍五入（999.6 → 1000 → 一位小数 K）
        #expect(Format.tokFmt(999.6) == "1.0K")
        #expect(Format.tokFmt(99999.4) == "100K")
    }

    @Test("split1：一位小数处切开")
    func split1() {
        #expect(Format.split1(58.2) == ("58", ".2"))
        #expect(Format.split1(109.64) == ("109", ".6"))
        #expect(Format.split1(7) == ("7", ".0"))
        #expect(Format.split1(99.96) == ("100", ".0"))
    }

    @Test("fixed：等同 JS toFixed")
    func fixed() {
        #expect(Format.fixed(0.457, 2) == "0.46")
        #expect(Format.fixed(21.44, 1) == "21.4")
        #expect(Format.fixed(58.2, 1) == "58.2")
        #expect(Format.fixed(2.3, 0) == "2")
    }

    @Test("shortModelName：量化/格式后缀截断")
    func shortModelName() {
        #expect(Format.shortModelName("Qwen3.8-27B-MLX-4bit") == "Qwen3.8-27B")
        #expect(Format.shortModelName("Qwen3.8-27B-oQ4e-mtp") == "Qwen3.8-27B-oQ4e")
        #expect(Format.shortModelName("Llama-3-8B") == "Llama-3-8B")
        // 不区分大小写
        #expect(Format.shortModelName("Qwen-MLX-4bit") == "Qwen")
        #expect(Format.shortModelName("Foo-4bit") == "Foo")
        #expect(Format.shortModelName("Bar-exl2_") == "Bar")
        // 第一个匹配处截断
        #expect(Format.shortModelName("A-MLX-4bit") == "A")
    }
}

@Suite("Gauge：仪表几何（原型常量）")
struct GaugeTests {
    @Test("valueToFraction：分段线性，边界钳制")
    func valueToFraction() {
        #expect(Gauge.valueToFraction(0) == 0)
        #expect(abs(Gauge.valueToFraction(25) - 0.2) < 1e-9)
        // 58 落在 50–100 段：0.4 + 0.16×0.2 = 0.432
        #expect(abs(Gauge.valueToFraction(58) - 0.432) < 1e-9)
        #expect(abs(Gauge.valueToFraction(100) - 0.6) < 1e-9)
        #expect(Gauge.valueToFraction(200) == 1)
        #expect(Gauge.valueToFraction(250) == 1)
        #expect(Gauge.valueToFraction(-3) == 0)
        #expect(abs(Gauge.valueToFraction(125) - 0.7) < 1e-9)
    }

    @Test("fractionToDegrees：225 − 270·f")
    func fractionToDegrees() {
        #expect(Gauge.fractionToDegrees(0) == 225)
        #expect(Gauge.fractionToDegrees(1) == -45)
        #expect(abs(Gauge.fractionToDegrees(0.5) - 90) < 1e-9)
    }

    @Test("point：y 向下 = cy − r·sin")
    func point() {
        // 225°：cos 与 sin 都取 √2/2
        let p = Gauge.point(225, 100)
        #expect(abs(p.x - (154 - 100 * 0.7071067811865476)) < 1e-9)
        #expect(abs(p.y - (144 + 100 * 0.7071067811865476)) < 1e-9)
        // 90°：正上方
        let up = Gauge.point(90, 10)
        #expect(abs(up.x - 154) < 1e-9)
        #expect(abs(up.y - 134) < 1e-9)
    }

    @Test("常量照抄原型")
    func constants() {
        #expect(Gauge.ticks == [0, 25, 50, 100, 150, 200])
        #expect(Gauge.tickFractions == [0, 0.2, 0.4, 0.6, 0.8, 1])
        // 刻度角度左右镜像对称：f 与 1−f 关于 90° 对称
        for f in Gauge.tickFractions {
            let a = Gauge.fractionToDegrees(f), b = Gauge.fractionToDegrees(1 - f)
            #expect(abs((a + b) / 2 - 90) < 1e-9)
        }
        #expect(Gauge.cx == 154)
        #expect(Gauge.cy == 144)
        #expect(Gauge.R == 124)
        #expect(Gauge.strokeWidth == 14)
    }
}

/// 测试里按 #filePath 相对定位 display/Fixtures/
func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PanelCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // display
        .appendingPathComponent("Fixtures/\(name)")
}

func decodeFixture(_ name: String) throws -> Metrics {
    try JSONDecoder().decode(Metrics.self, from: Data(contentsOf: fixtureURL(name)))
}

@Suite("Metrics：/metrics 解码")
struct MetricsTests {
    @Test("各 fixture 都能解码")
    func fixturesDecode() throws {
        let idle = try decodeFixture("idle.json")
        #expect(idle.state == "idle")
        #expect(idle.model == "Qwen3.8-27B-MLX-4bit")
        #expect(idle.tensorfoldVersion == "0.3.4.1")
        #expect(idle.contextMax == 262144)
        #expect(idle.hooks?.chat == "ok")
        #expect(idle.last?.promptTokens == 22)
        #expect(idle.last?.completionTokens == 570)
        #expect(idle.last?.decodeTps == 58.2)
        #expect(idle.last?.ttftS == 0.457)
        #expect(idle.last?.acceptanceRate == 0.64)
        #expect(idle.last?.contextUsed == 592)
        #expect(idle.last?.finishReason == "stop")
        #expect(idle.totals?.requests == 42)
        #expect(idle.totals?.peakTps == 189.3)
        #expect(idle.totals?.uptimeS == 3600)
        #expect(idle.current == nil)

        let prefill = try decodeFixture("prefill.json")
        #expect(prefill.state == "prefill")
        #expect(prefill.current?.elapsedS == 2.3)

        let decode = try decodeFixture("decode.json")
        #expect(decode.current?.elapsedS == 3.21)
        #expect(decode.current?.ttftS == 0.457)
        #expect(decode.current?.outputTokens == 312)
        #expect(decode.current?.decodeTps == 58.4)
        #expect(decode.current?.decodeTpsPeak == 71.2)

        let done = try decodeFixture("done.json")
        #expect(done.state == "done")
        #expect(done.last?.promptTokens == 32)
        #expect(done.last?.cachedTokens == 0)
        #expect(done.last?.completionTokens == 600)
        #expect(done.last?.decodeTps == 109.6)
        #expect(done.last?.ttftS == 0.102)
        #expect(done.last?.acceptanceRate == 0.78)
        #expect(done.last?.contextUsed == 632)

        let unavailable = try decodeFixture("unavailable.json")
        #expect(unavailable.hooks?.chat == "missing")

        let starting = try decodeFixture("starting.json")
        #expect(starting.engineReady == false)
        #expect(starting.model == nil)
        #expect(starting.hooks?.chat == "pending")
    }

    @Test("缺字段也能解码（全 nil）")
    func missingFields() throws {
        let m = try JSONDecoder().decode(Metrics.self, from: Data("{}".utf8))
        #expect(m.version == nil)
        #expect(m.state == nil)
        #expect(m.engineReady == nil)
        #expect(m.model == nil)
        #expect(m.hooks == nil)
        #expect(m.current == nil)
        #expect(m.last == nil)
        #expect(m.totals == nil)
    }

    @Test("多余字段不影响解码")
    func extraFields() throws {
        let json = #"{"version": 1, "state": "idle", "unknown_new_field": [1,2,3]}"#
        let m = try JSONDecoder().decode(Metrics.self, from: Data(json.utf8))
        #expect(m.state == "idle")
    }

    @Test("null 字段也能解码")
    func nullFields() throws {
        let json = #"{"version": null, "state": "decode", "model": null, "hooks": null, "current": null, "last": null, "totals": null}"#
        let m = try JSONDecoder().decode(Metrics.self, from: Data(json.utf8))
        #expect(m.state == "decode")
        #expect(m.model == nil)
        #expect(m.totals == nil)
    }
}

@Suite("PanelViewModel.make：状态 → 画面")
struct PanelViewModelTests {
    let mem: (usedGB: Double, totalGB: Double) = (21.4, 64)

    /// 成功读到指定 fixture，在线
    func onlineTracker(_ fixture: String, at t: Double) throws -> ConnectionTracker {
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(try decodeFixture(fixture), at: t)
        return tracker
    }

    /// 连续失败 3 次，离线
    func offlineTracker(_ fixture: String, firstFailureAt: Double) throws -> ConnectionTracker {
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(try decodeFixture(fixture), at: 0)
        tracker.recordFailure(at: firstFailureAt)
        tracker.recordFailure(at: firstFailureAt + 0.3)
        tracker.recordFailure(at: firstFailureAt + 0.6)
        return tracker
    }

    // MARK: offline

    @Test("offline：引擎离线")
    func offline() throws {
        var tracker = ConnectionTracker(bootTime: 100)
        tracker.recordSuccess(try decodeFixture("idle.json"), at: 101)
        tracker.recordFailure(at: 150)
        tracker.recordFailure(at: 150.3)
        tracker.recordFailure(at: 150.6)
        #expect(tracker.isOffline)
        let v = PanelViewModel.make(tracker: tracker, now: 152.9, memory: mem)
        #expect(v.state == .offline)
        #expect(v.stateName == "引擎离线")
        #expect(v.stripLeft == "上次模型 Qwen3.8-27B")
        #expect(v.stripRight.isEmpty)
        #expect(v.arc == .off)
        #expect(v.cap.isEmpty)
        #expect(v.message?.title == "引擎离线")
        #expect(v.message?.subtitle == "等待 TensorFold 响应…")
        // 已离线 = floor(152.9 − 150) = 2 秒
        let off = v.cards[1]
        #expect(off.label == "已离线")
        #expect(off.value == "2")
        #expect(off.unit == "秒")
        // 上次平均（rememberedLast.decodeTps 一位小数）
        let avg = v.cards[0]
        #expect(avg.label == "上次平均")
        #expect(avg.value == "58.2")
        #expect(avg.foot == "tok/s")
        #expect(!avg.pending)
        // 内存
        let m = v.cards[2]
        #expect(m.label == "内存")
        #expect(m.value == "21.4")
        #expect(m.unit == "GB")
        #expect(m.foot == "共 64 GB")
        #expect(!m.pending)
    }

    @Test("offline：从未成功，没有记住的模型")
    func offlineNeverSucceeded() {
        var tracker = ConnectionTracker(bootTime: 10)
        tracker.recordFailure(at: 11)
        tracker.recordFailure(at: 11.3)
        tracker.recordFailure(at: 11.6)
        let v = PanelViewModel.make(tracker: tracker, now: 12, memory: mem)
        #expect(v.state == .offline)
        #expect(v.stripLeft == "TensorFold")
        // 已离线 = floor(12 − 10) = 2 秒（从未成功用启动时间）
        #expect(v.cards[1].value == "2")
        // 没有记住的 last：上次平均 — pending
        #expect(v.cards[0].value == "—")
        #expect(v.cards[0].pending)
    }

    @Test("offline：读不到内存时 — pending")
    func offlineNoMemory() throws {
        let v = PanelViewModel.make(
            tracker: try offlineTracker("idle.json", firstFailureAt: 20),
            now: 20.5,
            memory: nil
        )
        #expect(v.state == .offline)
        #expect(v.cards[2].value == "—")
        #expect(v.cards[2].pending)
    }

    // MARK: unavailable / starting

    @Test("unavailable：hooks.chat == missing")
    func unavailable() throws {
        let v = PanelViewModel.make(
            tracker: try onlineTracker("unavailable.json", at: 50),
            now: 50,
            memory: mem
        )
        #expect(v.state == .unavailable)
        #expect(v.stateName == "指标不可用")
        #expect(v.stripLeft == "Qwen3.8-27B")
        #expect(v.arc == .off)
        #expect(v.message?.title == "指标不可用")
        #expect(v.message?.subtitle == "TensorFold 已更新，需要适配")
        // 上次平均：last 为 null 且无记忆 → — pending
        #expect(v.cards[0].label == "上次平均")
        #expect(v.cards[0].value == "—")
        #expect(v.cards[0].pending)
        // 运行：600 秒 → 10 分钟
        #expect(v.cards[1].label == "运行")
        #expect(v.cards[1].value == "10")
        #expect(v.cards[1].unit == "分钟")
        #expect(v.cards[2].label == "内存")
        #expect(v.cards[2].value == "21.4")
    }

    @Test("starting：engine_ready == false")
    func starting() throws {
        let v = PanelViewModel.make(
            tracker: try onlineTracker("starting.json", at: 50),
            now: 50,
            memory: mem
        )
        #expect(v.state == .starting)
        #expect(v.stateName == "启动中")
        #expect(v.stripLeft == "TensorFold")
        #expect(v.arc == .off)
        #expect(v.message?.title == "模型加载中")
        #expect(v.message?.subtitle == "TensorFold 正在启动…")
        // 运行：8 秒
        #expect(v.cards[1].value == "8")
        #expect(v.cards[1].unit == "秒")
        #expect(v.cards[0].label == "上次平均")
        #expect(v.cards[0].value == "—")
        #expect(v.cards[0].pending)
    }

    // MARK: idle

    @Test("idle：上次最终速度 + 输出/首字/内存")
    func idle() throws {
        let tracker = try onlineTracker("idle.json", at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.state == .idle)
        #expect(v.stateName == "空闲")
        #expect(v.stripLeft == "Qwen3.8-27B")
        #expect(v.stripRight.isEmpty)
        #expect(v.cap == "上次平均")
        #expect(v.pill)
        #expect(v.bigInt == "58")
        #expect(v.bigDec == ".2")
        #expect(v.unit == "tok/s")
        #expect(v.arc == .rest)
        #expect(v.arcTarget == 58.2)
        #expect(v.ghostFraction == Gauge.valueToFraction(58.2))
        let (c0, c1, c2) = (v.cards[0], v.cards[1], v.cards[2])
        #expect((c0.label, c0.value, c0.unit) == ("输出", "570", "tok"))
        #expect(!c0.pending)
        #expect((c1.label, c1.value, c1.unit) == ("首字", "0.46", "s"))
        #expect(!c1.pending)
        #expect((c2.label, c2.value, c2.unit, c2.foot) == ("内存", "21.4", "GB", "共 64 GB"))
    }

    @Test("idle：last 为 null 且无记忆 → — pending")
    func idleEmpty() throws {
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(try decodeFixture("idle-empty.json"), at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.state == .idle)
        #expect(v.bigInt == "—")
        #expect(v.bigDec == "")
        #expect(!v.pill)
        #expect(v.ghostFraction == nil)
        #expect(v.cards[0].value == "—")
        #expect(v.cards[0].pending)
        #expect(v.cards[1].value == "—")
        #expect(v.cards[1].pending)
        #expect(v.cards[2].value == "21.4")
    }

    // MARK: prefill

    @Test("prefill：已用时本地插值 + 扫动弧段")
    func prefill() throws {
        let tracker = try onlineTracker("prefill.json", at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 11, memory: mem)
        #expect(v.state == .prefill)
        #expect(v.stateName == "预填充中")
        #expect(v.stripLeft == "Qwen3.8-27B")
        // 已用时 = 2.3 + (11 − 10) = 3.3 > 1.5 → 提示较长
        #expect(v.stripRight == [StripSegment("提示较长，可能需要几秒")])
        #expect(v.cap == "已用时")
        #expect(v.whole)
        #expect(v.bigInt == "3")
        #expect(v.bigDec == ".3")
        #expect(v.unit == "秒")
        #expect(v.arc == .comet)
        // (3.3 mod 1.5)/1.5 = 0.2
        #expect(abs(v.cometPhase! - 0.2) < 1e-9)
        // 卡片：输出 —、首字 —（等待首个 token）、内存
        #expect(v.cards[0].label == "输出")
        #expect(v.cards[0].value == "—")
        #expect(v.cards[0].pending)
        #expect(v.cards[1].label == "首字")
        #expect(v.cards[1].value == "—")
        #expect(v.cards[1].foot == "等待首个 token")
        #expect(v.cards[1].pending)
        #expect(v.cards[2].label == "内存")
        #expect(v.cards[2].value == "21.4")
    }

    @Test("prefill：刚进入时状态条右侧为空")
    func prefillShort() throws {
        // 已用时 = 0.3 + 0.7 = 1.0 < 1.5 → 不提示
        var m = try decodeFixture("prefill.json")
        m.current?.elapsedS = 0.3
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10.7, memory: mem)
        #expect(v.stripRight.isEmpty)
        #expect(v.cometPhase! < 1)
    }

    // MARK: decode

    @Test("decode：实时 tok/s + 输出/平均/峰值")
    func decode() throws {
        let tracker = try onlineTracker("decode.json", at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.state == .decode)
        #expect(v.stateName == "解码中")
        #expect(v.stripLeft == "Qwen3.8-27B")
        #expect(v.cap == "解码速度")
        #expect(!v.pill)
        // bigInt = round(arcTarget)；arcTarget = current.decodeTps = 58.4
        #expect(v.arcTarget == 58.4)
        #expect(v.bigInt == "58")
        #expect(v.bigDec == "")
        #expect(v.unit == "tok/s")
        #expect(v.arc == .value)
        #expect(v.showSpark)
        // 状态条：首字 0.46 s · 内存 21.4 / 64 GB
        #expect(v.stripRight.map(\.text).joined() == "首字 0.46 s · 内存 21.4 / 64 GB")
        #expect(v.stripRight.map(\.bold) == [false, true, false, true, false])
        // 卡片
        #expect((v.cards[0].label, v.cards[0].value, v.cards[0].unit) == ("输出", "312", "tok"))
        // 平均：decode_tps_avg 一位小数
        #expect((v.cards[1].label, v.cards[1].value, v.cards[1].foot) == ("平均", "57.9", "tok/s"))
        #expect(!v.cards[1].pending)
        // 峰值：71.2 > 0 → 四舍五入
        #expect((v.cards[2].label, v.cards[2].value, v.cards[2].unit) == ("峰值", "71", "tok/s"))
        #expect(!v.cards[2].pending)
    }

    @Test("decode：峰值 ≤ 0 时 — pending")
    func decodeNoPeak() throws {
        var m = try decodeFixture("decode.json")
        m.current?.decodeTpsPeak = 0
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cards[2].value == "—")
        #expect(v.cards[2].pending)
        // 状态条内存段读不到内存时省略
        let v2 = PanelViewModel.make(tracker: tracker, now: 10, memory: nil)
        #expect(v2.stripRight.map(\.text).joined() == "首字 0.46 s · 内存 ")
    }

    @Test("decode：ttft 缺失时状态条显示 —（不能拿别的字段或示例值顶）")
    func decodeNoTtft() throws {
        var m = try decodeFixture("decode.json")
        m.current?.ttftS = nil
        m.current?.decodeTpsAvg = 55.3   // 速度字段存在，也不能拿来当前字时间
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: nil)
        #expect(v.stripRight.map(\.text).joined() == "首字 — s · 内存 ")
    }

    // MARK: done

    @Test("done：引擎精确成绩")
    func done() throws {
        let tracker = try onlineTracker("done.json", at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.state == .done)
        #expect(v.stateName == "完成")
        #expect(v.stripLeft == "Qwen3.8-27B")
        // 上下文 632 / 262K
        #expect(v.stripRight.map(\.text).joined() == "上下文 632 / 262K")
        #expect(v.stripRight.map(\.bold) == [false, true, false])
        // 大数字 = 本次平均速度
        #expect(v.cap == "平均速度")
        #expect(v.pill)
        #expect(v.bigInt == "109")
        #expect(v.bigDec == ".6")
        #expect(v.arc == .value)
        #expect(v.arcTarget == 109.6)
        // 卡片
        #expect((v.cards[0].label, v.cards[0].value, v.cards[0].unit, v.cards[0].foot)
            == ("输出", "600", "tok", "提示 32 tok"))
        #expect((v.cards[1].label, v.cards[1].value, v.cards[1].unit, v.cards[1].foot)
            == ("缓存命中", "0", "%", "0 tok"))
        #expect((v.cards[2].label, v.cards[2].value, v.cards[2].unit) == ("接受率", "78", "%"))
        // 样本数 1 ≤ 5 → 不显示小曲线
        #expect(!v.showSpark)
    }

    @Test("done：contextMax 为空时省略「 / …」；样本数 > 5 显示小曲线")
    func doneNoContextMax() throws {
        var m = try decodeFixture("done.json")
        m.contextMax = nil
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        var v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.stripRight.map(\.text).joined() == "上下文 632")
        #expect(!v.showSpark)
        // 塞 6 个样本 → showSpark
        tracker.sparkSamples = (0..<6).map { _ in SparkSample(raw: 50, smooth: 55) }
        v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.showSpark)
    }
}
