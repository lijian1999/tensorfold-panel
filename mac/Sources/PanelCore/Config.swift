// 配置：Spark 版 Config 里和 Mac 版有关的字段，默认值相同。app 从 UserDefaults 读出来再填进这里。
import Foundation

// 一个模型的 API 单价（所选货币 / 百万 token），由用户自己查了填。
public struct ModelPrice: Equatable, Sendable, Codable {
    public var input: Double     // 未命中的输入 token
    public var cached: Double    // 缓存命中的输入 token
    public var output: Double    // 输出 token

    public init(input: Double, cached: Double, output: Double) {
        self.input = input
        self.cached = cached
        self.output = output
    }
}

public struct Config: Equatable, Sendable {
    public var roundGapS: Double = 60.0           // 一轮间隔
    public var prefillShortS: Double = 3.0        // 短预填充阈值
    public var doneHoldS: Double = 4.0            // 完成画面停留
    public var dimAfterS: Double = 1800.0         // 空闲多久后调暗
    public var animFps: Double = 10.0             // 持续动画（解码、预填充期间）的帧率；切换画面的淡入固定 30
    public var timezone: String = "America/Los_Angeles"
    /// 按模型的单价（所选货币 / 百万 token），键是引擎给的模型名原文；没有的模型不算费用
    public var prices: [String: ModelPrice] = [:]
    /// 货币符号：单价按它填，`$`（默认）或 `¥`；换货币只换符号和文字，数字不换算
    public var currency: String = "$"
    public var stateDir: String = "~/Library/Application Support/TFPanel"
    public var modelName: String = "Qwen3.8-Flash-Next"   // 读不到模型名时用

    public init() {}
}
