// 设置：UserDefaults 的读写、默认值、换算成 Config。
import Foundation
import Testing
@testable import PanelCore

@Suite struct TestAppSettings {
    /// 每个测试一个新的临时域，结束清掉
    private func makeDefaults() -> (String, UserDefaults) {
        let name = "tfpanel-test-" + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test func test_默认值() {
        let (name, d) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        #expect(s.engine == "omlx")
        #expect(s.address == "127.0.0.1:8000")
        #expect(s.keyMode == .auto)
        #expect(s.manualKey == "")
        #expect(s.zone == .system)
        #expect(s.currency == "$")
        #expect(s.prices.isEmpty)
        #expect(s.knownModels.isEmpty)
        #expect(s.screenName == "TYPE-C")
        #expect(s.autoSwitchMode == true)
        #expect(s.launchAtLogin == false)
        let c = s.config(systemZone: "Asia/Shanghai")
        #expect(c.timezone == "Asia/Shanghai")
        #expect(c.currency == "$")
        #expect(c.prices.isEmpty)
        #expect(c.roundGapS == 60)
        #expect(c.animFps == 10)
        #expect(c.modelName == "未加载模型")
    }

    @Test func test_存了再读() {
        let (name, d) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        s.engine = "vllm"
        s.address = "10.0.0.2:8000"
        s.keyMode = .manual
        s.manualKey = "k9"
        s.zone = .beijing
        s.currency = "¥"
        s.prices = ["A": ModelPrice(input: 0.15, cached: 0.016, output: 0.47)]
        s.knownModels = ["A", "B"]
        s.screenName = "HDMI"
        s.autoSwitchMode = false
        s.launchAtLogin = true
        let t = AppSettings(defaults: d)
        #expect(t.engine == "vllm")
        #expect(t.address == "10.0.0.2:8000")
        #expect(t.keyMode == .manual)
        #expect(t.manualKey == "k9")
        #expect(t.zone == .beijing)
        #expect(t.currency == "¥")
        #expect(t.prices == ["A": ModelPrice(input: 0.15, cached: 0.016, output: 0.47)])
        #expect(t.knownModels == ["A", "B"])
        #expect(t.screenName == "HDMI")
        #expect(t.autoSwitchMode == false)
        #expect(t.launchAtLogin == true)
    }

    @Test func test_空白当默认() {
        let (name, d) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        s.address = "  "
        #expect(s.address == "127.0.0.1:8000")
        s.screenName = ""
        #expect(s.screenName == "TYPE-C")
        s.address = " 10.0.0.2:8000 "
        #expect(s.address == "10.0.0.2:8000")
    }

    @Test func test_货币() {
        let (name, d) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        s.currency = "¥"
        #expect(AppSettings(defaults: d).currency == "¥")
        #expect(AppSettings(defaults: d).config().currency == "¥")
        s.currency = ""
        #expect(s.currency == "$")   // 空白当默认
        s.currency = " ¥ "
        #expect(s.currency == "¥")   // 去掉首尾空白
        s.currency = "€"
        #expect(s.currency == "€")   // 别的值原样保留，画面上原样显示
    }

    @Test func test_认不出的选项用默认() {
        let (name, d) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        d.set("xx", forKey: "api_key_mode")
        d.set("xx", forKey: "timezone_choice")
        let s = AppSettings(defaults: d)
        #expect(s.keyMode == .auto)
        #expect(s.zone == .system)
    }

    @Test func test_单价() {
        let (name, d) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        let price = ModelPrice(input: 0.15, cached: 0.016, output: 0.47)
        s.prices = ["A": price]
        #expect(s.prices == ["A": price])
        #expect(s.config().prices == ["A": price])
        d.set(Data("x".utf8), forKey: "prices")
        #expect(s.prices.isEmpty)
    }

    @Test func test_时区() {
        let (name, d) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        s.zone = .system
        #expect(s.zoneIdentifier(systemZone: "Asia/Tokyo") == "Asia/Tokyo")
        #expect(s.config(systemZone: "Asia/Tokyo").timezone == "Asia/Tokyo")
        s.zone = .beijing
        #expect(s.zoneIdentifier(systemZone: "Asia/Tokyo") == "Asia/Shanghai")
        #expect(s.config(systemZone: "Asia/Tokyo").timezone == "Asia/Shanghai")
        s.zone = .pacific
        #expect(s.zoneIdentifier(systemZone: "Asia/Tokyo") == "America/Los_Angeles")
        #expect(s.config(systemZone: "Asia/Tokyo").timezone == "America/Los_Angeles")
    }

    @Test func test_只能用defaults改的键() {
        // 每次一个新的临时域，免得互相影响
        func configWith(_ key: String, _ value: Any?) -> Config {
            let (name, d) = makeDefaults()
            defer { d.removePersistentDomain(forName: name) }
            if let value { d.set(value, forKey: key) }
            return AppSettings(defaults: d).config()
        }
        #expect(configWith("round_gap_s", 30.0).roundGapS == 30)
        #expect(configWith("round_gap_s", -1.0).roundGapS == 60)
        #expect(configWith("round_gap_s", "abc").roundGapS == 60)
        #expect(configWith("round_gap_s", true).roundGapS == 60)
        #expect(configWith("anim_fps", 20).animFps == 20)
        #expect(configWith("dim_after_s", Double.infinity).dimAfterS == 1800)
    }

    @Test func test_apiKey() {
        let (name, d) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tfpanel-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        try! #"{"auth": {"api_key": "k1"}}"#.write(to: file, atomically: true, encoding: .utf8)
        let s = AppSettings(defaults: d)
        s.keyMode = .auto
        #expect(s.apiKey(settingsPath: file.path) == "k1")
        s.keyMode = .manual
        s.manualKey = "k2"
        #expect(s.apiKey(settingsPath: file.path) == "k2")
        s.manualKey = ""
        #expect(s.apiKey(settingsPath: file.path) == nil)
    }

    @Test func test_记住和忘掉模型() {
        let (name, d) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        s.rememberModels(["A", "B"])
        s.rememberModels(["B", "", "C"])
        #expect(s.knownModels == ["A", "B", "C"])
        s.prices = ["B": ModelPrice(input: 0.15, cached: 0.016, output: 0.47)]
        s.forgetModel("B")
        #expect(s.knownModels == ["A", "C"])
        #expect(s.prices.isEmpty)
    }
}
