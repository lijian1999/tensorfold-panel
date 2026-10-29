// 翻译自 panel/tests/test_viewmodel.py：视图模型（指标快照 → View）。
// 每个快照样例都用新建的 ViewModel(Config())，now=100.0。
import Foundation
import Testing
@testable import PanelCore

// ---------- 辅助函数（对应 test_viewmodel.py 里的 plain、marks、read、view_of、cards、FixtureCase.check） ----------

/// 把 Seg 列表拼成纯文字。
private func plain(_ segs: [Seg]) -> String { segs.map { $0.text }.joined() }

/// 一段非 normal 的文字（文字, 样式）；用结构体代替 Python 的元组，方便比较。
private struct Mark: Equatable {
    let text: String
    let style: String
    init(_ text: String, _ style: String) { self.text = text; self.style = style }
}

/// 只要非 normal 的段，返回 (文字, 样式)。
private func marks(_ segs: [Seg]) -> [Mark] {
    segs.filter { $0.style != "normal" }.map { Mark($0.text, $0.style) }
}

/// 读快照样例，可以顺手改几个字段。
private func read(_ name: String, _ overrides: [String: JSON] = [:]) -> JSON {
    var o = loadFixture("\(name).json").object ?? [:]
    for (k, v) in overrides { o[k] = v }
    return .object(o)
}

/// 把几个键盖到已有对象上（对应 Python 的 `x | {...}`、`dict(x, k=v)`）。
private func merged(_ base: JSON, _ overrides: [String: JSON]) -> JSON {
    var o = base.object ?? [:]
    for (k, v) in overrides { o[k] = v }
    return .object(o)
}

/// 用全新的 ViewModel 画一个样例。
private func view_of(_ name: String, _ now: Double = 100.0, _ overrides: [String: JSON] = [:]) -> View {
    ViewModel(config: Config()).update(read(name, overrides), now: now)
}

/// 右侧一栏写成 (标签, 数值, 单位, 脚注)；用结构体代替 Python 的四元组，方便比较。
private struct CardRow: Equatable {
    let label: String
    let value: String
    let unit: String
    let foot: String
    init(_ label: String, _ value: String, _ unit: String, _ foot: String) {
        self.label = label
        self.value = value
        self.unit = unit
        self.foot = foot
    }
}

/// 右侧三栏写成 (标签, 数值, 单位, 脚注)。
private func cards(_ view: View) -> [CardRow] {
    view.cards.map { CardRow($0.label, $0.value, $0.unit, $0.foot) }
}

/// 每个样例都检查：恰好三栏、能原样转成字典再转回来。（对应 FixtureCase.check）
private func checkFixture(_ name: String, _ now: Double = 100.0, _ overrides: [String: JSON] = [:]) -> View {
    let view = view_of(name, now, overrides)
    #expect(view.cards.count == 3, "\(name)")
    #expect(View(json: view.toJSON()) == view, "\(name)")
    return view
}

@Suite struct TestOfflineView {
    @Test func test_offline() {
        let view = checkFixture("offline")
        #expect(view.stateName == "引擎离线")
        #expect(view.stripLeft == "")
        #expect(plain(view.stripRight) == "上次模型 Qwen3.8-Flash-Next · TensorFold")
        #expect(marks(view.stripRight) == [])
        #expect(view.lanes.offline)
        #expect(view.arc == "off")
        #expect(view.bar == nil)
        #expect(view.bigInt == "")
        #expect(cards(view) == [
            CardRow("今日费用", "$0.60", "", ""),
            CardRow("已离线", "44", "秒", ""),
            CardRow("内存", "9.3", "GB", "共 121 GB"),
        ])
    }
}

@Suite struct TestIdle {
    @Test func test_idle() {
        let view = checkFixture("idle")
        #expect(view.stateName == "空闲")
        #expect(view.stripLeft == "Qwen3.8-Flash-Next · TensorFold")
        #expect(plain(view.stripRight) == "内存 94.2 / 121 GB")
        #expect(marks(view.stripRight) == [Mark("94.2", "strong")])
        #expect(view.cap == "今日费用")
        #expect(view.unit == "美元")
        #expect(view.bigInt == "$0")
        #expect(view.bigDec == ".60")
        #expect(view.bigWhole)
        #expect(view.bigSize == "cost")
        #expect(view.arc == "blank")
        #expect(view.arcTarget == nil)
        #expect(view.bar?.kind == "note")
        #expect(plain(view.bar?.text ?? []) == "10月3日 · 太平洋时间")
        #expect(!view.muted)
        #expect(almostEqual(view.dim, 1.0, places: 3))
        #expect(cards(view) == [
            CardRow("今日输入", "8.26M", "tok", "缓存命中 66%"),
            CardRow("今日输出", "185K", "tok", ""),
            CardRow("今日请求", "98", "次", "上次 63.6 tok/s"),
        ])
    }

    @Test func test_idle_nohook() {
        let view = checkFixture("idle-nohook")
        #expect(plain(view.stripRight) == "外挂未生效 · 内存 94.2 / 121 GB")
        #expect(marks(view.stripRight) == [Mark("外挂未生效", "warn"), Mark("94.2", "strong")])
        #expect(view.cap == "今日费用")
        #expect(view.unit == "美元")
        #expect(view.bigInt == "$0")
        #expect(view.bigDec == ".60")
        #expect(view.arc == "blank")
        #expect(plain(view.bar?.text ?? []) == "10月3日 · 太平洋时间")
        #expect(cards(view) == [
            CardRow("今日输入", "8.26M", "tok", "缓存命中 66%"),
            CardRow("今日输出", "185K", "tok", ""),
            CardRow("今日请求", "98", "次", "上次 63.6 tok/s"),
        ])
    }
}

@Suite struct TestPrefill {
    @Test func test_prefill() {
        let view = checkFixture("prefill")
        #expect(view.stateName == "预填充中")
        #expect(view.stripLeft == "")
        #expect(plain(view.stripRight) == "新算 20.2K tok")
        #expect(marks(view.stripRight) == [Mark("20.2K", "strong")])
        #expect(view.lanes.prefilling == 1)
        #expect(view.cap == "预填充速度")
        #expect(view.unit == "tok/s")
        #expect(view.bigInt == "2412")
        #expect(view.bigDec == "")
        #expect(view.bigSize == "four")
        #expect(view.arc == "prefill")
        #expect(view.scale == "prefill")
        #expect(almostEqual(view.arcTarget ?? -1, 0.804, places: 3))
        #expect(view.bar?.kind == "prog")
        #expect(almostEqual(view.bar?.frac ?? -1, 0.8701, places: 3))
        #expect(plain(view.bar?.text ?? []) == "已算 53.2K / 61.2K")
        #expect(marks(view.bar?.text ?? []) == [Mark("53.2K", "strong")])
        #expect(cards(view) == [
            CardRow("缓存命中", "67", "%", "41.0K / 61.2K"),
            CardRow("已等待", "5.7", "s", "剩余约 4 s"),
            CardRow("内存", "95.1", "GB", "共 121 GB"),
        ])
    }

    @Test func test_prefill_fresh() {
        let view = checkFixture("prefill-fresh")
        #expect(plain(view.stripRight) == "新算 24.6K tok")
        #expect(view.bigInt == "2354")
        #expect(almostEqual(view.bar?.frac ?? -1, 0.5824, places: 3))
        #expect(plain(view.bar?.text ?? []) == "已算 14.3K / 24.6K")
        #expect(cards(view) == [
            CardRow("缓存命中", "0", "%", "0 / 24.6K"),
            CardRow("已等待", "6.7", "s", "剩余约 5 s"),
            CardRow("内存", "94.4", "GB", "共 121 GB"),
        ])
    }

    @Test func test_prefill_miss() {
        let view = checkFixture("prefill-miss")
        #expect(plain(view.stripRight) == "已用时 5.7 s · 缓存未命中 · 剩余约 13 s")
        #expect(marks(view.stripRight) == [Mark("5.7", "strong"), Mark("缓存未命中", "warn"), Mark("13", "strong")])
        #expect(view.bigInt == "2368")
        #expect(view.arc == "prefill")
        #expect(plain(view.bar?.text ?? []) == "已算 12.3K / 41.2K")
        #expect(cards(view) == [
            CardRow("本轮请求", "6", "次", "用时 1 分钟"),
            CardRow("累计输出", "1.8K", "tok", ""),
            CardRow("本轮平均", "61.8", "", "tok/s"),
        ])
    }

    @Test func test_prefill_nohook() {
        let view = checkFixture("prefill-nohook")
        #expect(plain(view.stripRight) == "提示较长，可能需要几秒")
        #expect(view.cap == "已用时")
        #expect(view.unit == "秒")
        #expect(view.bigInt == "5")
        #expect(view.bigDec == ".6")
        #expect(view.bigWhole)
        #expect(view.bigSize == "normal")
        #expect(view.arc == "rest")
        #expect(view.scale == "decode")
        #expect(almostEqual(view.ghost ?? -1, 0.4544, places: 3))
        #expect(!view.muted)
        #expect(view.bar?.kind == "ctx")
        #expect(plain(view.bar?.text ?? []) == "上下文 24.6K / 262K")
        #expect(almostEqual(view.bar?.frac ?? -1, 0.0939, places: 3))
        #expect(view.bar?.level == "normal")
        #expect(cards(view) == [
            CardRow("输出", "—", "", ""),
            CardRow("首字", "—", "", "等待首个 token"),
            CardRow("内存", "94.4", "GB", "共 121 GB"),
        ])
        #expect(view.cards[0].pending)
        #expect(view.cards[1].pending)
    }

    @Test func test_prefill_short() {
        let view = checkFixture("prefill-short")
        #expect(view.stateName == "预填充中")
        #expect(view.stripLeft == "")
        #expect(plain(view.stripRight) == "已用时 1.2 s")
        #expect(marks(view.stripRight) == [Mark("1.2", "strong")])
        #expect(view.lanes.prefilling == 1)
        // 其余同 idle：短预填充保持原来的今日统计
        #expect(view.cap == "今日费用")
        #expect(view.bigInt == "$0")
        #expect(view.arc == "blank")
        #expect(cards(view) == [
            CardRow("今日输入", "8.26M", "tok", "缓存命中 66%"),
            CardRow("今日输出", "185K", "tok", ""),
            CardRow("今日请求", "98", "次", "上次 63.6 tok/s"),
        ])
    }
}

@Suite struct TestDecode {
    @Test func test_decode() {
        let view = checkFixture("decode")
        #expect(view.stateName == "解码中")
        #expect(plain(view.stripRight) == "首字 0.10 s · 内存 94.2 / 121 GB")
        #expect(marks(view.stripRight) == [Mark("0.10", "strong"), Mark("94.2", "strong")])
        #expect(view.lanes.decoding == 1)
        #expect(view.cap == "解码速度")
        #expect(view.unit == "tok/s")
        #expect(view.bigInt == "74")
        #expect(view.bigDec == "")
        #expect(almostEqual(view.bigValue ?? -1, 74.3, places: 3))
        #expect(view.arc == "value")
        #expect(almostEqual(view.arcTarget ?? -1, 0.4972, places: 3))
        #expect(view.bar?.kind == "ctx")
        #expect(plain(view.bar?.text ?? []) == "上下文 441 / 262K")
        #expect(view.bar?.level == "normal")
        #expect(cards(view) == [
            CardRow("输出", "383", "tok", ""),
            CardRow("平均", "69.7", "", "tok/s"),
            CardRow("峰值", "79", "tok/s", ""),
        ])
    }

    @Test func test_decode_multi() {
        let view = checkFixture("decode-multi")
        #expect(plain(view.stripRight) == "解码 3 · 预填充 1 · 内存 94.9 / 121 GB")
        #expect(marks(view.stripRight) == [Mark("3", "strong"), Mark("1", "strong"), Mark("94.9", "strong")])
        #expect(view.lanes.decoding == 3)
        #expect(view.lanes.prefilling == 1)
        #expect(view.lanes.waiting == 0)
        #expect(view.bigInt == "100")
        #expect(view.arc == "value")
        #expect(plain(view.bar?.text ?? []) == "上下文 61.0K / 262K")
        #expect(cards(view) == [
            CardRow("本轮请求", "7", "次", "用时 46 秒"),
            CardRow("累计输出", "1.7K", "tok", ""),
            CardRow("本轮平均", "107.6", "", "tok/s"),
        ])
    }

    @Test func test_decode_ctx_warn() {
        let view = checkFixture("decode-ctx-warn")
        #expect(plain(view.stripRight) == "首字 0.35 s · 内存 97.9 / 121 GB")
        #expect(view.bigInt == "88")
        #expect(view.bar?.level == "warn")
        #expect(almostEqual(view.bar?.frac ?? -1, 0.8392, places: 3))
        #expect(plain(view.bar?.text ?? []) == "上下文 220K / 262K")
        #expect(cards(view) == [
            CardRow("输出", "12.4K", "tok", ""),
            CardRow("平均", "87.9", "", "tok/s"),
            CardRow("峰值", "96", "tok/s", ""),
        ])
    }

    @Test func test_queue() {
        let view = checkFixture("queue")
        #expect(plain(view.stripRight) == "解码 5 · 排队 2 · 内存 94.9 / 121 GB")
        #expect(view.lanes.decoding == 5)
        #expect(view.lanes.prefilling == 0)
        #expect(view.lanes.waiting == 2)
        #expect(view.bigInt == "136")
        #expect(plain(view.bar?.text ?? []) == "上下文 9.5K / 262K")
        #expect(cards(view) == [
            CardRow("本轮请求", "9", "次", "用时 17 秒"),
            CardRow("累计输出", "1.4K", "tok", ""),
            CardRow("本轮平均", "128.2", "", "tok/s"),
        ])
    }
}

@Suite struct TestDone {
    @Test func test_done() {
        let view = checkFixture("done")
        #expect(view.stateName == "完成")
        #expect(plain(view.stripRight) == "首字 0.09 s")
        #expect(marks(view.stripRight) == [Mark("0.09", "strong")])
        #expect(view.cap == "平均速度")
        #expect(view.unit == "tok/s")
        #expect(view.pill)
        #expect(view.bigInt == "97")
        #expect(view.bigDec == ".2")
        #expect(!view.bigWhole)
        #expect(view.bigValue == nil)
        #expect(view.arc == "value")
        #expect(almostEqual(view.arcTarget ?? -1, 0.5888, places: 3))
        #expect(!view.muted)
        #expect(plain(view.bar?.text ?? []) == "上下文 696 / 262K")
        #expect(cards(view) == [
            CardRow("输出", "600", "tok", "提示 96 tok"),
            CardRow("缓存命中", "0", "%", "0 tok"),
            CardRow("接受率", "81", "%", ""),
        ])
    }
}

@Suite struct TestRoundRest {
    @Test func test_round_rest() {
        let view = checkFixture("round-rest")
        #expect(view.stateName == "空闲")
        #expect(view.stripLeft == "")
        #expect(plain(view.stripRight) == "内存 94.2 / 121 GB")
        #expect(view.cap == "本轮平均")
        #expect(view.unit == "tok/s")
        #expect(view.pill)
        #expect(view.bigInt == "62")
        #expect(view.bigDec == ".3")
        #expect(view.muted)
        #expect(view.arc == "rest")
        #expect(almostEqual(view.ghost ?? -1, 0.4492, places: 3))
        #expect(plain(view.bar?.text ?? []) == "上下文 14.5K / 262K")
        #expect(cards(view) == [
            CardRow("本轮请求", "7", "次", "用时 2 分钟"),
            CardRow("累计输出", "2.3K", "tok", ""),
            CardRow("本轮平均", "62.3", "", "tok/s"),
        ])
    }
}

@Suite struct TestMemory {
    // 两次 update 之间记住的东西。
    @Test func test_short_prefill_keeps_previous_view() {
        let roundModified: JSON = [
            "requests": 7, "running": 1, "output_tokens": 2345,
            "decode_tps_avg": 62.3, "exact": true, "elapsed_s": 140,
            "active": true,
        ]
        // 先是一轮中间的空隙（本轮统计），再来短预填充：还是本轮统计
        let vm = ViewModel(config: Config())
        _ = vm.update(read("round-rest"), now: 100.0)
        let view = vm.update(read("prefill-short", ["round": roundModified]), now: 100.0)
        #expect(view.cap == "本轮平均")
        #expect(view.muted)
        #expect(view.stateName == "预填充中")
        #expect(plain(view.stripRight) == "已用时 1.2 s")
        #expect(view.cards[0].label == "本轮请求")
        #expect(view.cards[0].value == "8")
        // 之前是今日统计：短预填充也保持今日统计
        let vm2 = ViewModel(config: Config())
        _ = vm2.update(read("idle"), now: 100.0)
        let view2 = vm2.update(read("prefill-short", ["round": roundModified]), now: 100.0)
        #expect(view2.cap == "今日费用")
    }

    @Test func test_take_over_stays_taken() {
        let short: JSON = ["elapsed_s": 1.0, "prompt_tokens": 24615, "cached_tokens": 0,
                           "filled_tokens": 14336, "tps": 2354.0, "remaining_s": 4.37,
                           "est_s": 0.5, "cache_miss": false]
        // 接管过之后，同一轮预填充里不再退回短预填充画面
        let vm = ViewModel(config: Config())
        _ = vm.update(read("prefill"), now: 100.0)
        #expect(vm.update(read("prefill", ["prefill": short]), now: 100.0).cap == "预填充速度")
        // 中间插一次空闲：重新计时，短预填充不接管
        let vm2 = ViewModel(config: Config())
        _ = vm2.update(read("prefill"), now: 100.0)
        _ = vm2.update(read("idle"), now: 100.0)
        #expect(vm2.update(read("prefill", ["prefill": short]), now: 100.0).cap != "预填充速度")
    }

    @Test func test_slow_fade() {
        let vm = ViewModel(config: Config())
        _ = vm.update(read("done"), now: 100.0)
        #expect(vm.update(read("idle"), now: 100.0).slowFade)
        #expect(!vm.update(read("idle"), now: 101.0).slowFade)
        _ = vm.update(read("decode"), now: 102.0)
        #expect(!vm.update(read("idle"), now: 103.0).slowFade)
    }

    @Test func test_dim() {
        var config = Config()
        config.dimAfterS = 1800
        let vm = ViewModel(config: config)
        let cases: [(String, Double, Double)] = [("idle", 0, 1.0), ("idle", 1799, 1.0), ("idle", 1800, 0.4),
                                                 ("decode", 1801, 1.0), ("idle", 1802, 1.0)]
        for (state, now, want) in cases {
            let view = vm.update(read(state), now: now)
            #expect(almostEqual(view.dim, want, places: 3), "state=\(state) now=\(now)")
        }
        // 本轮统计和离线画面不调暗
        let vm2 = ViewModel(config: config)
        _ = vm2.update(read("round-rest"), now: 0)
        #expect(almostEqual(vm2.update(read("round-rest"), now: 5000).dim, 1.0, places: 3))
        let vm3 = ViewModel(config: config)
        _ = vm3.update(read("offline"), now: 0)
        #expect(almostEqual(vm3.update(read("offline"), now: 5000).dim, 1.0, places: 3))
    }
}

@Suite struct TestMissingData {
    // 缺字段、空值不能抛异常，缺的写“—”或留空。
    @Test func test_idle_without_last() {
        let view = checkFixture("idle", 100.0, ["last": .null])
        #expect(view.cards[2].foot == "")
    }

    @Test func test_decode_missing_values() {
        let decode: JSON = ["tps": 74.3, "tps_peak": 0, "tps_avg": .null,
                            "output_tokens": 383, "ttft_s": .null]
        let view = checkFixture("decode", 100.0, ["decode": decode])
        #expect(view.cards[1].value == "—")
        #expect(view.cards[1].pending)
        #expect(view.cards[2].value == "—")
        #expect(view.cards[2].pending)
        #expect(plain(view.stripRight) == "内存 94.2 / 121 GB")
    }

    @Test func test_done_missing_acceptance() {
        let last = merged(read("done")["last"] ?? [:], ["acceptance_rate": .null])
        let view = checkFixture("done", 100.0, ["last": last])
        #expect(view.cards[2].value == "—")
        #expect(view.cards[2].pending)
    }

    @Test func test_prefill_missing_tps() {
        let prefill = merged(read("prefill")["prefill"] ?? [:], ["tps": .null])
        let view = checkFixture("prefill", 100.0, ["prefill": prefill])
        #expect(view.bigInt == "—")
        #expect(view.arcTarget == 0)
    }

    @Test func test_round_rest_missing_average() {
        let rnd = merged(read("round-rest")["round"] ?? [:], ["decode_tps_avg": .null])
        let view = checkFixture("round-rest", 100.0, ["round": rnd])
        #expect(view.bigInt == "—")
        #expect(!view.pill)
        #expect(view.ghost == nil)
    }

    @Test func test_context_bar_levels() {
        let view = checkFixture("decode", 100.0, ["context_used": 250000])
        #expect(view.bar?.level == "full")
        let view2 = checkFixture("decode", 100.0, ["context_used": 300000])
        #expect(view2.bar?.frac == 1.0)
        #expect(plain(view2.bar?.text ?? []) == "上下文 262K / 262K")
    }

    @Test func test_offline_over_a_minute() {
        let view = checkFixture("offline", 100.0, ["offline_s": 185])
        #expect(cards(view)[1] == CardRow("已离线", "3", "分钟", ""))
    }

    @Test func test_done_inside_a_round() {
        let rnd: JSON = ["requests": 3, "running": 0, "output_tokens": 900,
                         "decode_tps_avg": 70.0, "exact": true, "elapsed_s": 30,
                         "active": true]
        let view = checkFixture("done", 100.0, ["round": rnd])
        #expect(view.muted)
        #expect(view.cap == "本轮平均")
        #expect(view.pill)
        #expect(view.stateName == "完成")
        #expect(plain(view.stripRight) == "首字 0.09 s")
        // 本轮出现过并发：不写首字，改写内存
        let view2 = checkFixture("done", 100.0, ["round": merged(rnd, ["exact": false])])
        #expect(!view2.pill)
        #expect(plain(view2.stripRight) == "内存 94.2 / 121 GB")
    }

    @Test func test_back_to_today_after_round() {
        let rnd = merged(read("round-rest")["round"] ?? [:], ["active": false])
        let view = checkFixture("round-rest", 100.0, ["round": rnd])
        #expect(view.cap == "今日费用")
        #expect(view.stripLeft == "Qwen3.8-Flash-Next · TensorFold")
    }

    @Test func test_empty_snapshots() {
        let snapshots: [JSON] = [[:], ["state": "prefill"], ["state": "decode"],
                                 ["state": "done"], ["state": "offline"]]
        for snapshot in snapshots {
            let view = ViewModel(config: Config()).update(snapshot, now: 0.0)
            #expect(view.cards.count == 3, "state=\(snapshot["state"]?.string ?? "None")")
        }
    }
}

@Suite struct TestSegs {
    // 段与段之间：检查拼出来的纯文字里没有多余空格。
    @Test func test_plain_helper() {
        #expect(plain([Seg("内存 "), Seg("94.2", "strong"), Seg(" / 121 GB")]) == "内存 94.2 / 121 GB")
        #expect(marks([Seg("内存 ")]) == [])
    }
}

@Suite struct TestEngineLabel {
    // 模型名只写最后一段，后面标出当前引擎。
    @Test func test_idle_vllm() {
        let view = checkFixture("idle-vllm")
        #expect(view.stripLeft == "Qwen3.8-Flash-Next · vLLM")
        #expect(plain(view.stripRight) == "内存 94.2 / 121 GB")
        #expect(view.lanes.max == 4)
    }

    @Test func test_offline_vllm() {
        let view = checkFixture("offline-vllm")
        #expect(view.stripLeft == "")
        #expect(plain(view.stripRight) == "上次模型 Qwen3.8-Flash-Next · vLLM")
    }

    @Test func test_hook_missing_drops_engine() {
        let view = checkFixture("idle-nohook")
        #expect(view.stripLeft == "Qwen3.8-Flash-Next")
    }

    @Test func test_engine_unknown() {
        let view = checkFixture("idle", 100.0, ["engine": .null])
        #expect(view.stripLeft == "Qwen3.8-Flash-Next")
        let view2 = checkFixture("offline", 100.0, ["engine": .null])
        #expect(plain(view2.stripRight) == "上次模型 Qwen3.8-Flash-Next")
    }

    @Test func test_vllm_never_warns_hook() {
        let view = checkFixture("idle-vllm", 100.0, ["hook": "missing"])
        #expect(view.stripLeft == "Qwen3.8-Flash-Next · vLLM")
        #expect(plain(view.stripRight) == "内存 94.2 / 121 GB")
    }

    @Test func test_model_falls_back_to_config() {
        let view = checkFixture("idle", 100.0, ["model": .null])
        #expect(view.stripLeft == "Qwen3.8-Flash-Next · TensorFold")
    }
}

@Suite struct TestPrefillEstimated {
    // 估算版预填充（vLLM）：标“近期平均”，进度按时间估算。
    @Test func test_prefill_est() {
        let view = checkFixture("prefill-est")
        #expect(view.stateName == "预填充中")
        #expect(view.cap == "预填充速度")
        #expect(view.unit == "tok/s")
        #expect(view.pill)
        #expect(view.pillKind == "avg")
        #expect(view.bigInt == "2200")
        #expect(view.bigSize == "four")
        #expect(view.arc == "prefill")
        #expect(view.scale == "prefill")
        #expect(almostEqual(view.arcTarget ?? -1, 0.7333, places: 3))
        #expect(view.bar?.kind == "prog")
        #expect(almostEqual(view.bar?.frac ?? -1, 0.3696, places: 3))
        #expect(plain(view.bar?.text ?? []) == "已算约 14.7K / 39.9K")
        #expect(marks(view.bar?.text ?? []) == [Mark("14.7K", "strong")])
        #expect(plain(view.stripRight) == "新算 39.9K tok")
        #expect(cards(view) == [
            CardRow("缓存命中", "0", "%", "0 / 39.9K"),
            CardRow("已等待", "6.7", "s", "剩余约 12 s"),
            CardRow("内存", "94.4", "GB", "共 121 GB"),
        ])
        #expect(view.lanes.max == 4)
        #expect(view.lanes.prefilling == 1)
    }

    @Test func test_prefill_est_inside_a_round() {
        let miss = loadFixture("prefill-miss.json")
        let view = checkFixture("prefill-est", 100.0, ["round": miss["round"] ?? [:]])
        #expect(plain(view.stripRight) == "已用时 6.7 s · 缓存命中 0% · 剩余约 12 s")
        #expect(view.cards.map { $0.label } == ["本轮请求", "累计输出", "本轮平均"])
    }

    @Test func test_prefill_est_almost_done() {
        let base = read("prefill-est")["prefill"] ?? [:]
        let view = checkFixture("prefill-est", 100.0,
                                ["prefill": merged(base, ["elapsed_s": 30.0,
                                                          "filled_tokens": 39485, "remaining_s": 0.0])])
        #expect(cards(view)[1] == CardRow("已等待", "30.0", "s", "剩余约 1 s"))
        #expect(almostEqual(view.bar?.frac ?? -1, 0.99, places: 2))
    }

    @Test func test_tensorfold_prefill_unchanged() {
        let view = checkFixture("prefill")
        #expect(!view.pill)
        #expect(view.pillKind == "exact")
        #expect(plain(view.bar?.text ?? []) == "已算 53.2K / 61.2K")
        let view2 = checkFixture("done")
        #expect(view2.pill)
        #expect(view2.pillKind == "exact")
    }
}
