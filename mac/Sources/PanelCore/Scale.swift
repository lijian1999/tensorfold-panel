// 仪表盘两套刻度：数值 → 圆弧位置 0–1，和 panel/scale.py 一致。

/// 刻度位置（0–1）：5 段等分，左右对称
public let tickFracs: [Double] = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]

public struct GaugeScale: Sendable {
    public let ticks: [Double]
    public let labels: [String]
}

/// 键是 "decode"、"prefill"
public let scales: [String: GaugeScale] = [
    "decode": GaugeScale(ticks: [0, 25, 50, 100, 200, 300], labels: ["0", "25", "50", "100", "200", "300"]),
    "prefill": GaugeScale(ticks: [0, 600, 1200, 1800, 2400, 3000], labels: ["0", "600", "1.2K", "1.8K", "2.4K", "3K"]),
]

/// 数值 → 圆弧位置。nil、≤ 0（含 NaN）返回 0，≥ 最大刻度返回 1。scale 不是两套之一时按 "decode"。
public func v2f(_ v: Double?, _ scale: String) -> Double {
    guard let v, v > 0 else { return 0 }
    let ticks = (scales[scale] ?? scales["decode"]!).ticks
    if v >= ticks[ticks.count - 1] { return 1 }
    for i in 1..<ticks.count where v <= ticks[i] {
        let f0 = tickFracs[i - 1], f1 = tickFracs[i]
        return f0 + (v - ticks[i - 1]) / (ticks[i] - ticks[i - 1]) * (f1 - f0)
    }
    return 1
}
