// 设置：存在 UserDefaults 里，由菜单栏和设置窗口改，再换算成 PanelCore 用的 Config。
import Foundation

public enum ZoneChoice: String, CaseIterable, Sendable { case system, beijing, pacific }
public enum KeyMode: String, CaseIterable, Sendable { case auto, manual }

public final class AppSettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    // MARK: - 读写的小工具

    /// 字符串：去掉首尾空白；没有、或去掉后是空串 → 默认值
    private func trimmedString(_ key: String, _ fallback: String) -> String {
        guard let s = defaults.string(forKey: key) else { return fallback }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    /// 只能用 defaults write 改的键：是 NSNumber、不是布尔值、而且是有限的正数才采用
    private func positiveNumber(_ key: String) -> Double? {
        guard let obj = defaults.object(forKey: key), let n = obj as? NSNumber else { return nil }
        if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return nil }
        let v = n.doubleValue
        guard v.isFinite && v > 0 else { return nil }
        return v
    }

    /// 布尔：没存过用默认值
    private func boolValue(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    // MARK: - 各项设置

    /// 各引擎的默认地址
    private static func defaultAddress(_ engine: String) -> String {
        engine == "tensorfold" ? "127.0.0.1:8080" : "127.0.0.1:8000"
    }

    public var engine: String {
        get { trimmedString("engine", "omlx") }
        set {
            // 改引擎时：地址还等于原引擎的默认值 → 跟着换成新引擎的默认值；用户手改过的地址不动
            let oldAddress = address
            let oldDefault = Self.defaultAddress(engine)
            defaults.set(newValue, forKey: "engine")
            if oldAddress == oldDefault {
                address = Self.defaultAddress(newValue)
            }
        }
    }

    public var address: String {
        get { trimmedString("address", Self.defaultAddress(engine)) }
        set { defaults.set(newValue, forKey: "address") }
    }

    public var keyMode: KeyMode {
        get { KeyMode(rawValue: defaults.string(forKey: "api_key_mode") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "api_key_mode") }
    }

    public var manualKey: String {
        get { (defaults.string(forKey: "api_key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue, forKey: "api_key") }
    }

    public var zone: ZoneChoice {
        get { ZoneChoice(rawValue: defaults.string(forKey: "timezone_choice") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "timezone_choice") }
    }

    /// 货币符号：单价按它填（`$` 默认，或 `¥`）；换货币只换符号和文字，数字不按汇率换算
    public var currency: String {
        get { trimmedString("currency", "$") }
        set { defaults.set(newValue, forKey: "currency") }
    }

    public var prices: [String: ModelPrice] {
        get {
            guard let data = defaults.data(forKey: "prices"),
                  let p = try? JSONDecoder().decode([String: ModelPrice].self, from: data) else { return [:] }
            return p
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "prices")
            }
        }
    }

    public var knownModels: [String] {
        get { defaults.stringArray(forKey: "known_models") ?? [] }
        set { defaults.set(newValue, forKey: "known_models") }
    }

    public var screenName: String {
        get { trimmedString("screenName", "TYPE-C") }
        set { defaults.set(newValue, forKey: "screenName") }
    }

    public var autoSwitchMode: Bool {
        get { boolValue("autoSwitchMode", true) }
        set { defaults.set(newValue, forKey: "autoSwitchMode") }
    }

    /// 只记用户的选择，登记由 app 做
    public var launchAtLogin: Bool {
        get { boolValue("launchAtLogin", false) }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    // MARK: - 换算

    public func zoneIdentifier(systemZone: String = TimeZone.current.identifier) -> String {
        switch zone {
        case .system: return systemZone
        case .beijing: return "Asia/Shanghai"
        case .pacific: return "America/Los_Angeles"
        }
    }

    public func config(systemZone: String = TimeZone.current.identifier) -> Config {
        var c = Config()
        c.timezone = zoneIdentifier(systemZone: systemZone)
        c.prices = prices
        c.currency = currency
        c.modelName = "未加载模型"
        // 这几个键只能在终端上用 defaults write 改
        if let v = positiveNumber("round_gap_s") { c.roundGapS = v }
        if let v = positiveNumber("prefill_short_s") { c.prefillShortS = v }
        if let v = positiveNumber("done_hold_s") { c.doneHoldS = v }
        if let v = positiveNumber("dim_after_s") { c.dimAfterS = v }
        if let v = positiveNumber("anim_fps") { c.animFps = v }
        return c
    }

    public func apiKey(settingsPath: String = "~/.omlx/settings.json") -> String? {
        switch keyMode {
        case .auto:
            // 自动模式只有 oMLX 读配置文件；TensorFold 默认无 key，不读任何文件
            guard engine == "omlx" else { return nil }
            return omlxApiKey(settingsPath: settingsPath)
        case .manual: return manualKey.isEmpty ? nil : manualKey
        }
    }

    /// 把没见过的模型名按原顺序追加到末尾；没有新的就不写
    public func rememberModels(_ ids: [String]) {
        var known = knownModels
        var changed = false
        for id in ids where !id.isEmpty && !known.contains(id) {
            known.append(id)
            changed = true
        }
        if changed { knownModels = known }
    }

    public func forgetModel(_ id: String) {
        knownModels = knownModels.filter { $0 != id }
        var p = prices
        p.removeValue(forKey: id)
        prices = p
    }
}
