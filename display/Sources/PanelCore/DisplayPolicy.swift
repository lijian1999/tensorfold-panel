import CoreGraphics

/// 副屏显示策略（纯逻辑，可测试）：缩放居中、调暗、显示模式选择。
public enum DisplayPolicy {
    /// 设计稿尺寸（480×320 pt）
    public static let designSize = CGSize(width: 480, height: 320)

    /// 目标显示模式（960 × 640，1 倍，正好等于面板像素）
    public static let target = (width: 960, height: 640, pixelWidth: 960, pixelHeight: 640)

    /// 把 480×320 的画面按屏幕尺寸等比缩放并居中，其余区域黑色。
    /// 返回 `(scale, origin)`，origin 为画面左上角相对屏幕左上角的偏移（pt）。
    public static func fit(screenSize: CGSize) -> (scale: CGFloat, origin: CGPoint) {
        let w = max(0, screenSize.width)
        let h = max(0, screenSize.height)
        guard w > 0, h > 0 else { return (1, .zero) }
        let scale = min(w / designSize.width, h / designSize.height)
        let origin = CGPoint(
            x: (w - designSize.width * scale) / 2,
            y: (h - designSize.height * scale) / 2
        )
        return (scale, origin)
    }

    /// idle 或 offline 持续超过 30 分钟 → 调暗；其他状态立即恢复。
    public static func dimmed(state: PanelState, stateSince: Double, now: Double) -> Bool {
        guard state == .idle || state == .offline else { return false }
        return now - stateSince > 30 * 60
    }

    /// 显示模式信息（从 CGDisplayMode 提取的纯数据）
    public struct ModeInfo: Sendable {
        public var width: Int
        public var height: Int
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var refreshRate: Double

        public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
            self.width = width
            self.height = height
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.refreshRate = refreshRate
        }
    }

    /// 从模式列表里选目标模式：只选 960×640 且像素也是 960×640 的；
    /// 多个时选刷新率最高的；没有返回 nil。返回选中模式的下标。
    public static func pickMode(_ modes: [ModeInfo]) -> Int? {
        var best: (index: Int, rate: Double)?
        for (i, m) in modes.enumerated() {
            guard m.width == target.width, m.height == target.height,
                  m.pixelWidth == target.pixelWidth, m.pixelHeight == target.pixelHeight
            else { continue }
            if best == nil || m.refreshRate > best!.rate {
                best = (i, m.refreshRate)
            }
        }
        return best?.index
    }
}
