// 副屏出现时自动把显示模式切到 960 × 640（设置可关）。失败只写日志，不影响副屏。
import AppKit
import CoreGraphics

enum DisplayMode {
    /// 切换结果：已经是目标模式 / 切换成功 / 屏上没有目标模式 / 切换失败
    enum SwitchResult { case already, switched, noMode, failed }

    /// 目标显示模式（960 × 640，1 倍，正好等于面板像素）
    private static let target = (width: 960, height: 640, pixelWidth: 960, pixelHeight: 640)

    /// 显示模式信息（从 CGDisplayMode 提取的纯数据）
    private struct ModeInfo {
        var width: Int
        var height: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var refreshRate: Double
    }

    /// 从 NSScreen 取 CGDirectDisplayID
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(num.uint32Value)
    }

    /// 从模式列表里选目标模式：只选 960×640 且像素也是 960×640 的；
    /// 多个时选刷新率最高的；没有返回 nil。返回选中模式的下标。
    private static func pickMode(_ modes: [ModeInfo]) -> Int? {
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

    /// 副屏出现时调用：已是 960×640（像素也是）就什么都不做，否则选模式并切换。
    @discardableResult
    static func switchIfNeeded(screen: NSScreen) -> SwitchResult {
        guard let id = displayID(for: screen) else { return .failed }

        // 读当前模式；已经就是目标就返回
        if let cur = CGDisplayCopyDisplayMode(id) {
            if Int(cur.width) == target.width,
               Int(cur.height) == target.height,
               Int(cur.pixelWidth) == target.pixelWidth,
               Int(cur.pixelHeight) == target.pixelHeight {
                return .already
            }
        }
        // 列出所有模式（含低分辨率重复模式），交给 pickMode 选
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as CFString: true] as CFDictionary
        let cfModes = CGDisplayCopyAllDisplayModes(id, opts)
        let modes = (cfModes as? [CGDisplayMode]) ?? []
        let infos = modes.map {
            ModeInfo(
                width: Int($0.width),
                height: Int($0.height),
                pixelWidth: Int($0.pixelWidth),
                pixelHeight: Int($0.pixelHeight),
                refreshRate: $0.refreshRate
            )
        }
        guard let index = pickMode(infos) else {
            Log.write("副屏没有 960×640（1 倍）模式，跳过切换")
            return .noMode
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == CGError.success, let config else {
            Log.write("CGBeginDisplayConfiguration 失败，跳过切换")
            return .failed
        }
        let configure = CGConfigureDisplayWithDisplayMode(config, id, modes[index], nil)
        guard configure == CGError.success else {
            CGCancelDisplayConfiguration(config)
            Log.write("设置 960×640 失败（错误 \(Int(configure.rawValue))），保持当前模式")
            return .failed
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == CGError.success else {
            CGCancelDisplayConfiguration(config)
            Log.write("CGCompleteDisplayConfiguration 失败，保持当前模式")
            return .failed
        }
        Log.write("副屏已切换到 960 × 640")
        return .switched
    }
}
