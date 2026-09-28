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
        #expect(prefill.current?.elapsedS == 4.6)

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

    @Test("Metrics 解码 current 的 3 个预填充缓存字段；老 fixture 全 nil；3 个新 fixture 都能解码")
    func prefillCacheDecoding() throws {
        let m = try decodeFixture("prefill-cache.json")
        #expect(m.current?.prefillCached == 32768)
        #expect(m.current?.prefillEstS == 3.797)
        #expect(m.current?.cacheMiss == false)
        // 老 fixture 没有新字段，三者都为 nil
        let old = try decodeFixture("prefill.json")
        #expect(old.current?.prefillCached == nil)
        #expect(old.current?.prefillEstS == nil)
        #expect(old.current?.cacheMiss == nil)
        let rc = try decodeFixture("round-prefill-cache.json")
        #expect(rc.current?.prefillCached == 16384)
        #expect(rc.current?.prefillEstS == 2.921)
        #expect(rc.current?.cacheMiss == false)
        let rm = try decodeFixture("round-prefill-miss.json")
        #expect(rm.current?.prefillCached == 0)
        #expect(rm.current?.prefillEstS == 57.191)
        #expect(rm.current?.cacheMiss == true)
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

    @Test("prefill：3 秒以后显示已用时，圆弧不动")
    func prefill() throws {
        let tracker = try onlineTracker("prefill.json", at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 11, memory: mem)
        #expect(v.state == .prefill)
        #expect(v.stateName == "预填充中")
        #expect(v.stripLeft == "Qwen3.8-27B")
        // 已用时 = 4.6 + (11 − 10) = 5.6 ≥ 3 → 接管大数字
        #expect(v.stripRight == [StripSegment("提示较长，可能需要几秒")])
        #expect(v.cap == "已用时")
        #expect(v.whole)
        #expect(v.bigInt == "5")
        #expect(v.bigDec == ".6")
        #expect(v.unit == "秒")
        // 圆弧不动，小点留在上次平均位置
        #expect(v.arc == .rest)
        #expect(v.ghostFraction == Gauge.valueToFraction(58.2))
        #expect(v.arcTarget == 58.2)
        #expect(!v.muted)
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

    @Test("prefill：前 3 秒保持空闲画面，状态条显示已用时")
    func prefillShort() throws {
        // 已用时 = 0.3 + 0.7 = 1.0 < 3 → 短预填充
        var m = try decodeFixture("prefill.json")
        m.current?.elapsedS = 0.3
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10.7, memory: mem)
        #expect(v.stripRight == [StripSegment("已用时 "), StripSegment("1.0", bold: true), StripSegment(" s")])
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
        // 首字 0.10 s
        #expect(v.stripRight.map(\.text).joined() == "首字 0.10 s")
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
    }

    @Test("done：contextMax 为空时不显示上下文条")
    func doneNoContextMax() throws {
        var m = try decodeFixture("done.json")
        m.contextMax = nil
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.context == nil)
    }
}

@Suite("StripSegment：bold / warn")
struct StripSegmentTests {
    @Test("默认 warn 为 false，参与相等比较")
    func warnDefault() {
        #expect(StripSegment("a") == StripSegment("a", bold: false, warn: false))
        #expect(StripSegment("a", warn: true) != StripSegment("a"))
    }
}

@Suite("预填充：缓存命中 / 新算 token 数 / 预计时间")
struct PrefillCacheTests {
    let mem: (usedGB: Double, totalGB: Double) = (21.4, 64)

    /// 成功读到指定 fixture，在线
    func online(_ fixture: String, at t: Double) throws -> ConnectionTracker {
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(try decodeFixture(fixture), at: t)
        return tracker
    }

    @Test("prefill-cache（单请求，已用 1.0 但预计 3.797 ≥ 3 → 长）：新算 + 预计 + 缓存命中卡")
    func prefillCacheSingle() throws {
        let v = PanelViewModel.make(tracker: try online("prefill-cache.json", at: 10), now: 10, memory: mem)
        #expect(v.cap == "已用时")
        #expect(v.bigInt == "1")
        #expect(v.bigDec == ".0")
        #expect(!v.muted)
        #expect(v.arc == .rest)
        // 新算 35012 − 32768 = 2244 → 2.2K；预计 3.797 → 4（向上取整）
        #expect(v.stripRight == [
            StripSegment("新算 "),
            StripSegment("2.2K", bold: true),
            StripSegment(" tok"),
            StripSegment(" · 预计约 "),
            StripSegment("4", bold: true),
            StripSegment(" s"),
        ])
        #expect(v.cards[0] == Card(label: "缓存命中", value: "94", unit: "%", foot: "32.8K / 35.0K"))
        #expect((v.cards[1].label, v.cards[1].pending, v.cards[1].foot) == ("首字", true, "等待首个 token"))
        #expect(v.cards[2].label == "内存")
    }

    @Test("round-prefill-cache（一轮，已用 4.4）：缓存命中 89% + 新算 2.0K + 预计 3 s；卡片 = 一轮卡片")
    func roundPrefillCache() throws {
        let v = PanelViewModel.make(tracker: try online("round-prefill-cache.json", at: 10), now: 10, memory: mem)
        // 16384 / 18420 → 88.95% → 89%；新算 18420 − 16384 = 2036 → 2.0K；预计 2.921 → 3
        #expect(v.stripRight == [
            StripSegment("缓存命中 "),
            StripSegment("89%", bold: true),
            StripSegment(" · 新算 "),
            StripSegment("2.0K", bold: true),
            StripSegment(" · 预计约 "),
            StripSegment("3", bold: true),
            StripSegment(" s"),
        ])
        // 一轮卡片和 round-prefill-long 生成的完全相同
        let long = PanelViewModel.make(tracker: try online("round-prefill-long.json", at: 10), now: 10, memory: mem)
        #expect(v.cards == long.cards)
    }

    @Test("round-prefill-miss（一轮，已用 1.0，缓存未命中 → 长）：琥珀「缓存未命中」段")
    func roundPrefillMiss() throws {
        let v = PanelViewModel.make(tracker: try online("round-prefill-miss.json", at: 10), now: 10, memory: mem)
        #expect(v.cap == "已用时")
        // 未命中 → 命中率不算，直接显示琥珀「缓存未命中」；新算 41230 → 41.2K；预计 57.191 → 58
        #expect(v.stripRight == [
            StripSegment("缓存未命中", warn: true),
            StripSegment(" · 新算 "),
            StripSegment("41.2K", bold: true),
            StripSegment(" · 预计约 "),
            StripSegment("58", bold: true),
            StripSegment(" s"),
        ])
        #expect(v.cards[0].label == "本轮请求")
    }

    @Test("提前切换边界：预计 2.99 短 / 3.0 长 / 预计 nil 但缓存未命中也长")
    func prefillEstBoundary() throws {
        var m = try decodeFixture("prefill-cache.json")
        m.current?.elapsedS = 1.0
        var tracker = ConnectionTracker(bootTime: 0)
        m.current?.prefillEstS = 2.99
        m.current?.cacheMiss = false
        tracker.recordSuccess(m, at: 10)
        var v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cap == "上次平均")
        #expect(v.stripRight == [StripSegment("已用时 "), StripSegment("1.0", bold: true), StripSegment(" s")])
        m.current?.prefillEstS = 3.0
        tracker.recordSuccess(m, at: 10)
        v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cap == "已用时")
        m.current?.prefillEstS = nil
        m.current?.cacheMiss = true
        tracker.recordSuccess(m, at: 10)
        v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cap == "已用时")
    }

    @Test("prefill_est_s 为 nil：不带预计段，卡片仍是缓存命中卡")
    func prefillEstNil() throws {
        var m = try decodeFixture("prefill-cache.json")
        m.current?.elapsedS = 4.0
        m.current?.prefillEstS = nil
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.stripRight == [
            StripSegment("新算 "),
            StripSegment("2.2K", bold: true),
            StripSegment(" tok"),
        ])
        #expect(v.cards[0].label == "缓存命中")
    }

    @Test("拿不到缓存信息时退回原画面（cached nil / prompt nil / prompt 0）")
    func prefillCacheFallback() throws {
        // prefill_cached 为 nil（prompt 35012、已用 4.0）→ 退回
        var m = try decodeFixture("prefill-cache.json")
        m.current?.elapsedS = 4.0
        m.current?.prefillCached = nil
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        var v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.stripRight == [StripSegment("提示较长，可能需要几秒")])
        #expect(v.cards[0].label == "输出")
        // prompt_tokens 为 nil → 同样退回
        m = try decodeFixture("prefill-cache.json")
        m.current?.promptTokens = nil
        tracker.recordSuccess(m, at: 10)
        v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.stripRight == [StripSegment("提示较长，可能需要几秒")])
        #expect(v.cards[0].label == "输出")
        // prompt_tokens 为 0 → 同样退回
        m = try decodeFixture("prefill-cache.json")
        m.current?.promptTokens = 0
        tracker.recordSuccess(m, at: 10)
        v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.stripRight == [StripSegment("提示较长，可能需要几秒")])
        #expect(v.cards[0].label == "输出")
    }

    @Test("命中率取整和夹紧：2/3 → 67；cached 大于 prompt → 100、新算 0")
    func hitRoundingClamp() throws {
        var m = try decodeFixture("prefill-cache.json")
        m.current?.promptTokens = 3
        m.current?.prefillCached = 2
        m.current?.prefillEstS = 5.0
        m.current?.elapsedS = 1.0
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        var v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cards[0].value == "67")
        // cached 大于 prompt → 命中 100，新算 0
        m = try decodeFixture("prefill-cache.json")
        m.current?.promptTokens = 100
        m.current?.prefillCached = 200
        m.current?.elapsedS = 4.0
        tracker.recordSuccess(m, at: 10)
        v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cards[0].value == "100")
        #expect(v.stripRight == [
            StripSegment("新算 "),
            StripSegment("0", bold: true),
            StripSegment(" tok"),
            StripSegment(" · 预计约 "),
            StripSegment("4", bold: true),
            StripSegment(" s"),
        ])
    }
}

@Suite("一轮模式与短预填充")
struct RoundModeTests {
    let mem: (usedGB: Double, totalGB: Double) = (21.4, 64)

    /// 成功读到指定 fixture，在线
    func online(_ fixture: String, at t: Double) throws -> ConnectionTracker {
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(try decodeFixture(fixture), at: t)
        return tracker
    }

    @Test("Metrics 解码 round 全部 5 个字段；没有 round 键时为 nil；7 个新 fixture 都能解码")
    func roundDecoding() throws {
        let json = #"{"round": {"requests": 9, "output_tokens": 1834, "decode_tps_avg": 78.4, "elapsed_s": 96.5, "active": true}}"#
        let m = try JSONDecoder().decode(Metrics.self, from: Data(json.utf8))
        #expect(m.round?.requests == 9)
        #expect(m.round?.outputTokens == 1834)
        #expect(m.round?.decodeTpsAvg == 78.4)
        #expect(m.round?.elapsedS == 96.5)
        #expect(m.round?.active == true)
        // 没有 round 键时为 nil
        let empty = try JSONDecoder().decode(Metrics.self, from: Data("{}".utf8))
        #expect(empty.round == nil)
        // 7 个新 fixture 都能解码
        let prefillShort = try decodeFixture("prefill-short.json")
        #expect(prefillShort.state == "prefill")
        #expect(prefillShort.round == nil)
        let rPrefillShort = try decodeFixture("round-prefill-short.json")
        #expect(rPrefillShort.round?.requests == 9)
        #expect(rPrefillShort.current?.elapsedS == 0.8)
        let rPrefillLong = try decodeFixture("round-prefill-long.json")
        #expect(rPrefillLong.current?.elapsedS == 4.4)
        #expect(rPrefillLong.round?.active == true)
        let rDecode = try decodeFixture("round-decode.json")
        #expect(rDecode.state == "decode")
        #expect(rDecode.round?.decodeTpsAvg == 78.4)
        let rDone = try decodeFixture("round-done.json")
        #expect(rDone.state == "done")
        #expect(rDone.round?.requests == 10)
        let rIdle = try decodeFixture("round-idle.json")
        #expect(rIdle.state == "idle")
        #expect(rIdle.round?.active == true)
        let rIdleEnded = try decodeFixture("round-idle-ended.json")
        #expect(rIdleEnded.round?.active == false)
    }

    @Test("短预填充（单请求）：画面与 idle 相同，muted，只有状态条变化")
    func shortPrefillSingle() throws {
        let v = PanelViewModel.make(tracker: try online("prefill-short.json", at: 10), now: 10, memory: mem)
        let idle = PanelViewModel.make(tracker: try online("idle.json", at: 10), now: 10, memory: mem)
        #expect(v.state == .prefill)
        #expect(v.stateName == "预填充中")
        #expect(v.muted)
        #expect(v.arc == .rest)
        // 状态条右侧：已用时 1.2 s（now = fetchedAt）
        #expect(v.stripRight == [StripSegment("已用时 "), StripSegment("1.2", bold: true), StripSegment(" s")])
        // 其余与用同一份 last 生成的 idle 画面完全相同
        #expect(v.cap == idle.cap)
        #expect(v.pill == idle.pill)
        #expect(v.bigInt == idle.bigInt)
        #expect(v.bigDec == idle.bigDec)
        #expect(v.ghostFraction == idle.ghostFraction)
        #expect(v.arcTarget == idle.arcTarget)
        #expect(v.cards == idle.cards)
    }

    @Test("阈值边界：已用时 2.99 为短预填充，3.0 为长预填充")
    func prefillThreshold() throws {
        var m = try decodeFixture("prefill.json")
        var tracker = ConnectionTracker(bootTime: 0)
        m.current?.elapsedS = 2.99
        tracker.recordSuccess(m, at: 10)
        var v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cap == "上次平均")
        m.current?.elapsedS = 3.0
        tracker.recordSuccess(m, at: 10)
        v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cap == "已用时")
    }

    @Test("一轮判定：requests 1 且进行中 → 一轮模式；idle → 单请求；没有 round → 单请求")
    func roundDetection() throws {
        // round.requests == 1 且 state 为 prefill（进行中）→ roundCount 2 → 一轮模式
        var m = try decodeFixture("idle.json")
        m.state = "prefill"
        m.round = .init(requests: 1, active: true)
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        var v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cards[0].label == "本轮请求")
        #expect(v.cards[0].value == "2")
        // round.requests == 1 且 state 为 idle（不进行中）→ roundCount 1 → 单请求
        m = try decodeFixture("idle.json")
        m.round = .init(requests: 1, active: true)
        tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cards[0].label == "输出")
        // 没有 round 且 state 为 decode → 单请求
        tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(try decodeFixture("decode.json"), at: 10)
        v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.cards[0].label == "输出")
    }

    @Test("round-decode：右侧换一轮卡片，其余与单请求 decode 相同")
    func roundDecode() throws {
        let v = PanelViewModel.make(tracker: try online("round-decode.json", at: 10), now: 10, memory: mem)
        // 单请求 decode 对照
        let single = PanelViewModel.make(tracker: try online("decode.json", at: 10), now: 10, memory: mem)
        #expect(v.muted == false)
        #expect(v.cap == "解码速度")
        #expect(v.arcTarget == single.arcTarget)
        #expect(v.bigInt == single.bigInt)
        #expect(v.stripRight == single.stripRight)
        // 本轮请求：9 + 1（进行中）= 10 次；用时 96.5 秒 → 1 分钟
        #expect((v.cards[0].label, v.cards[0].value, v.cards[0].unit, v.cards[0].foot)
            == ("本轮请求", "10", "次", "用时 1 分钟"))
        // 累计输出：1834 + 312 = 2146 → 2.1K
        #expect((v.cards[1].label, v.cards[1].value, v.cards[1].unit) == ("累计输出", "2.1K", "tok"))
        // 本轮平均：78.4
        #expect((v.cards[2].label, v.cards[2].value, v.cards[2].unit, v.cards[2].foot)
            == ("本轮平均", "78.4", "", "tok/s"))
    }

    @Test("round-done：灰色画面显示本轮平均，状态条为首字")
    func roundDone() throws {
        let v = PanelViewModel.make(tracker: try online("round-done.json", at: 10), now: 10, memory: mem)
        #expect(v.state == .done)
        #expect(v.stateName == "完成")
        #expect(v.cap == "本轮平均")
        #expect(v.pill)
        #expect(v.bigInt == "79")
        #expect(v.bigDec == ".1")
        #expect(v.muted)
        #expect(v.arc == .rest)
        #expect(v.ghostFraction == Gauge.valueToFraction(79.1))
        #expect(v.cards[0].value == "10")
        #expect(v.stripRight.first == StripSegment("首字 "))
    }

    @Test("round-idle：状态名空闲，状态条右侧为空，卡片为一轮三项")
    func roundIdle() throws {
        let v = PanelViewModel.make(tracker: try online("round-idle.json", at: 10), now: 10, memory: mem)
        #expect(v.stateName == "空闲")
        #expect(v.stripRight.isEmpty)
        #expect(v.cards.map(\.label) == ["本轮请求", "累计输出", "本轮平均"])
        #expect(v.cards[1].value == "2.1K")
    }

    @Test("round-idle-ended：本轮已结束 → 上轮")
    func roundIdleEnded() throws {
        let v = PanelViewModel.make(tracker: try online("round-idle-ended.json", at: 10), now: 10, memory: mem)
        #expect(v.cap == "上轮平均")
        #expect(v.cards.map(\.label) == ["上轮请求", "上轮输出", "上轮平均"])
    }

    @Test("round-prefill-short：一轮卡片 + 状态条已用时 0.8")
    func roundPrefillShort() throws {
        let v = PanelViewModel.make(tracker: try online("round-prefill-short.json", at: 10), now: 10, memory: mem)
        #expect(v.cards[0].value == "10")
        #expect(v.cap == "本轮平均")
        #expect(v.bigInt == "78")
        #expect(v.stripRight == [StripSegment("已用时 "), StripSegment("0.8", bold: true), StripSegment(" s")])
    }

    @Test("round-prefill-long：接管已用时，卡片仍为一轮卡片，小点在本轮平均位置")
    func roundPrefillLong() throws {
        let v = PanelViewModel.make(tracker: try online("round-prefill-long.json", at: 10), now: 10, memory: mem)
        #expect(v.cap == "已用时")
        #expect(v.bigInt == "4")
        #expect(v.bigDec == ".4")
        #expect(v.muted == false)
        #expect(v.cards.map(\.label) == ["本轮请求", "累计输出", "本轮平均"])
        #expect(v.ghostFraction == Gauge.valueToFraction(78.4))
    }

    @Test("一轮模式下 decode_tps_avg 为 null：大数字 —、无残影、平均卡 pending")
    func roundAvgNull() throws {
        var m = try decodeFixture("round-idle.json")
        m.round?.decodeTpsAvg = nil
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.bigInt == "—")
        #expect(!v.pill)
        #expect(v.ghostFraction == nil)
        #expect(v.cards[2].label == "本轮平均")
        #expect(v.cards[2].pending)
    }

    @Test("淡入键：一轮模式里中间和右侧不随状态变化，单请求 decode 与 done 右侧不同")
    func fadeKeys() throws {
        let done = PanelViewModel.make(tracker: try online("round-done.json", at: 10), now: 10, memory: mem)
        let idle = PanelViewModel.make(tracker: try online("round-idle.json", at: 10), now: 10, memory: mem)
        let short = PanelViewModel.make(tracker: try online("round-prefill-short.json", at: 10), now: 10, memory: mem)
        let decode = PanelViewModel.make(tracker: try online("round-decode.json", at: 10), now: 10, memory: mem)
        let long = PanelViewModel.make(tracker: try online("round-prefill-long.json", at: 10), now: 10, memory: mem)
        // 一轮模式：done / idle / 短预填充三者中间淡入键相同，decode 不同
        #expect(done.centerFadeKey == idle.centerFadeKey)
        #expect(done.centerFadeKey == short.centerFadeKey)
        #expect(decode.centerFadeKey != done.centerFadeKey)
        // 一轮模式：decode / done / idle / 短预填充 / 长预填充右侧淡入键全部相同
        #expect(done.cardsFadeKey == idle.cardsFadeKey)
        #expect(done.cardsFadeKey == short.cardsFadeKey)
        #expect(done.cardsFadeKey == decode.cardsFadeKey)
        #expect(done.cardsFadeKey == long.cardsFadeKey)
        // 单请求：decode 与 done 的右侧标签不同
        let sDone = PanelViewModel.make(tracker: try online("done.json", at: 10), now: 10, memory: mem)
        let sDecode = PanelViewModel.make(tracker: try online("decode.json", at: 10), now: 10, memory: mem)
        #expect(sDone.cardsFadeKey != sDecode.cardsFadeKey)
    }

    @Test("muted：单请求 idle 为 true，done / decode / offline 为 false")
    func muted() throws {
        #expect(PanelViewModel.make(tracker: try online("idle.json", at: 10), now: 10, memory: mem).muted)
        #expect(PanelViewModel.make(tracker: try online("done.json", at: 10), now: 10, memory: mem).muted == false)
        #expect(PanelViewModel.make(tracker: try online("decode.json", at: 10), now: 10, memory: mem).muted == false)
        var tracker = ConnectionTracker(bootTime: 100)
        tracker.recordSuccess(try decodeFixture("idle.json"), at: 101)
        tracker.recordFailure(at: 150)
        tracker.recordFailure(at: 150.3)
        tracker.recordFailure(at: 150.6)
        #expect(PanelViewModel.make(tracker: tracker, now: 151, memory: mem).muted == false)
    }
}

@Suite("上下文条与标题行")
struct ContextBarTests {
    let mem: (usedGB: Double, totalGB: Double) = (21.4, 64)

    /// 读 fixture → 在线 tracker → 一帧画面
    func model(_ fixture: String, at t: Double, now: Double? = nil) throws -> PanelViewModel {
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(try decodeFixture(fixture), at: t)
        return PanelViewModel.make(tracker: tracker, now: now ?? t, memory: mem)
    }

    @Test("Metrics 解码 current.prompt_tokens；两个新 fixture 能解码")
    func promptTokensDecoding() throws {
        let decode = try decodeFixture("decode.json")
        #expect(decode.current?.promptTokens == 18420)
        #expect(try decodeFixture("decode-ctx-warn.json").current?.promptTokens == 215000)
        #expect(try decodeFixture("decode-ctx-full.json").current?.promptTokens == 250000)
    }

    @Test("capText：标题 · 单位；离线时为空")
    func capText() throws {
        #expect(try model("decode.json", at: 10).capText == "解码速度 · tok/s")
        #expect(try model("idle.json", at: 10).capText == "上次平均 · tok/s")
        #expect(try model("prefill.json", at: 10).capText == "已用时 · 秒")
        #expect(try model("round-done.json", at: 10).capText == "本轮平均 · tok/s")
        var tracker = ConnectionTracker(bootTime: 100)
        tracker.recordSuccess(try decodeFixture("idle.json"), at: 101)
        tracker.recordFailure(at: 150)
        tracker.recordFailure(at: 150.3)
        tracker.recordFailure(at: 150.6)
        #expect(PanelViewModel.make(tracker: tracker, now: 151, memory: mem).capText == "")
    }

    @Test("decode：上下文 = 提示 + 已输出，文字三段，normal")
    func decodeContext() throws {
        let v = try model("decode.json", at: 10)
        // 18420 + 312 = 18732
        #expect(v.context == ContextUsage(used: 18732, limit: 262144))
        #expect(v.context?.segments.map(\.text) == ["上下文 ", "18.7K", " / 262K"])
        #expect(v.context?.segments.map(\.bold) == [false, true, false])
        #expect(v.context?.level == .normal)
    }

    @Test("预填充只算提示（长短都一样，一轮模式也一样）")
    func prefillContext() throws {
        #expect(try model("prefill-short.json", at: 10).context?.used == 1240)
        #expect(try model("prefill.json", at: 10).context?.used == 35012)
        #expect(try model("round-prefill-long.json", at: 10).context?.used == 18420)
        #expect(try model("prefill.json", at: 10).context?.limit == 262144)
    }

    @Test("idle / done 用 last.context_used")
    func idleDoneContext() throws {
        #expect(try model("idle.json", at: 10).context?.used == 592)
        #expect(try model("done.json", at: 10).context?.used == 632)
        let r = try decodeFixture("round-done.json")
        #expect(try model("round-done.json", at: 10).context?.used == r.last?.contextUsed)
    }

    @Test("warn / full 等级与边界（含 fraction 钳制）")
    func contextLevels() throws {
        #expect(try model("decode-ctx-warn.json", at: 10).context?.level == .warn)
        #expect(try model("decode-ctx-full.json", at: 10).context?.level == .full)
        #expect(ContextUsage(used: 80, limit: 100).level == .warn)
        #expect(ContextUsage(used: 79, limit: 100).level == .normal)
        #expect(ContextUsage(used: 95, limit: 100).level == .full)
        #expect(ContextUsage(used: 120, limit: 100).fraction == 1)
    }

    @Test("fillWidth：最小 6 pt（圆点）；used ≤ 0 为 0；上限 120")
    func fillWidth() {
        #expect(ContextUsage(used: 632, limit: 262144).fillWidth == 6)
        #expect(ContextUsage(used: 0, limit: 100).fillWidth == 0)
        #expect(ContextUsage(used: 50, limit: 100).fillWidth == 60)
        #expect(ContextUsage(used: 200, limit: 100).fillWidth == 120)
    }

    @Test("缺数据时不显示上下文条")
    func contextMissing() throws {
        // decode 且 promptTokens 为 nil
        var m = try decodeFixture("decode.json")
        m.current?.promptTokens = nil
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        #expect(PanelViewModel.make(tracker: tracker, now: 10, memory: mem).context == nil)
        // contextMax 为 nil
        m = try decodeFixture("decode.json")
        m.contextMax = nil
        tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        #expect(PanelViewModel.make(tracker: tracker, now: 10, memory: mem).context == nil)
        // offline
        tracker = ConnectionTracker(bootTime: 100)
        tracker.recordSuccess(try decodeFixture("idle.json"), at: 101)
        tracker.recordFailure(at: 150)
        tracker.recordFailure(at: 150.3)
        tracker.recordFailure(at: 150.6)
        #expect(PanelViewModel.make(tracker: tracker, now: 151, memory: mem).context == nil)
        // unavailable / starting
        tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(try decodeFixture("unavailable.json"), at: 50)
        #expect(PanelViewModel.make(tracker: tracker, now: 50, memory: mem).context == nil)
        tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(try decodeFixture("starting.json"), at: 50)
        #expect(PanelViewModel.make(tracker: tracker, now: 50, memory: mem).context == nil)
    }

    @Test("完成画面：last.ttft_s 缺失时状态条为 首字 — s")
    func doneNoTtft() throws {
        var m = try decodeFixture("done.json")
        m.last?.ttftS = nil
        var tracker = ConnectionTracker(bootTime: 0)
        tracker.recordSuccess(m, at: 10)
        let v = PanelViewModel.make(tracker: tracker, now: 10, memory: mem)
        #expect(v.stripRight.map(\.text) == ["首字 ", "—", " s"])
        #expect(v.stripRight.map(\.bold) == [false, true, false])
    }
}
