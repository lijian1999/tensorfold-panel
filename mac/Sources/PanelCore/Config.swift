// 配置：Spark 版 Config 里和 Mac 版有关的字段，默认值相同。app 从 UserDefaults 读出来再填进这里。
import Foundation

public struct Config: Equatable, Sendable {
    public var roundGapS: Double = 60.0           // 一轮间隔
    public var prefillShortS: Double = 3.0        // 短预填充阈值
    public var doneHoldS: Double = 4.0            // 完成画面停留
    public var dimAfterS: Double = 1800.0         // 空闲多久后调暗
    public var animFps: Double = 10.0             // 持续动画（解码、预填充期间）的帧率；切换画面的淡入固定 30
    public var timezone: String = "America/Los_Angeles"
    public var priceInput: Double = 0.15          // 每百万 token
    public var priceCached: Double = 0.016
    public var priceOutput: Double = 0.47
    public var currency: String = "$"
    public var stateDir: String = "~/Library/Application Support/TFPanel"
    public var modelName: String = "Qwen3.8-Flash-Next"   // 读不到模型名时用

    public init() {}
}
