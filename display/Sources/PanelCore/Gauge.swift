import CoreGraphics

/// 仪表几何，常量照抄原型（480×320 设计单位）。
public enum Gauge {
    /// 刻度值 tok/s（前密后疏）
    public static let ticks: [Double] = [0, 25, 50, 100, 150, 200]
    /// 刻度在弧上的位置（0–1）：5 段等分（每段 54°），刻度左右镜像对称；
    /// 前两段各 25 tok/s、后三段各 50 tok/s，低速区更疏朗
    public static let tickFractions: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1]

    /// 几何常量（cx/cy 圆心、R 半径、strokeWidth 线宽）
    public static let cx: Double = 154
    public static let cy: Double = 144
    public static let R: Double = 124
    public static let strokeWidth: Double = 14

    /// 数值 → 弧上位置（原型 v2f，分段线性；≤0 为 0，≥200 为 1）
    public static func valueToFraction(_ v: Double) -> Double {
        if v <= 0 { return 0 }
        if v >= 200 { return 1 }
        var f = 1.0
        for i in 1..<ticks.count {
            if v <= ticks[i] {
                let t = (v - ticks[i - 1]) / (ticks[i] - ticks[i - 1])
                f = tickFractions[i - 1] + t * (tickFractions[i] - tickFractions[i - 1])
                break
            }
        }
        return f
    }

    /// 弧上位置 → 角度（原型 f2deg，y 向下坐标系里从 225° 扫到 -45°）
    public static func fractionToDegrees(_ f: Double) -> Double {
        return 225 - 270 * f
    }

    /// 极坐标转直角坐标（y 向下：cy − r·sin）
    public static func point(_ deg: Double, _ r: Double) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: cx + r * cos(a), y: cy - r * sin(a))
    }
}
