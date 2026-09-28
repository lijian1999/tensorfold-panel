import Foundation

/// 设置（UserDefaults 共享组 com.tensorfold.panel）。
/// 命令行选项只影响本次运行，不写回设置。
@MainActor
final class Settings {
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: "com.tensorfold.panel") ?? .standard
    }

    /// 副屏名（默认 "TYPE-C"）
    var screenName: String {
        get { defaults.string(forKey: "screenName") ?? "TYPE-C" }
        set { defaults.set(newValue, forKey: "screenName") }
    }

    /// 副屏接入时自动切换到 960 × 640（默认开启）
    var autoSwitchMode: Bool {
        get {
            if defaults.object(forKey: "autoSwitchMode") == nil { return true }
            return defaults.bool(forKey: "autoSwitchMode")
        }
        set { defaults.set(newValue, forKey: "autoSwitchMode") }
    }
}
