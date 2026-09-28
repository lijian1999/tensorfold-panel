import AppKit
import CoreGraphics
import PanelCore

/// 副屏出现时自动把显示模式切到 960 × 640（设置可关）。失败只打印日志，不影响副屏。
enum DisplayMode {
    /// 从 NSScreen 取 CGDirectDisplayID
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(num.uint32Value)
    }

    /// 副屏出现时调用：已是 960×640（像素也是）就什么都不做，否则选模式并切换。
    static func switchIfNeeded(screen: NSScreen) {
        guard let id = displayID(for: screen) else { return }

        // 读当前模式；已经就是目标就返回
        if let cur = CGDisplayCopyDisplayMode(id) {
            let t = DisplayPolicy.target
            if Int(cur.width) == t.width,
               Int(cur.height) == t.height,
               Int(cur.pixelWidth) == t.pixelWidth,
               Int(cur.pixelHeight) == t.pixelHeight {
                return
            }
        }
        // 列出所有模式（含低分辨率重复模式），交给 DisplayPolicy.pickMode 选
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as CFString: true] as CFDictionary
        let cfModes = CGDisplayCopyAllDisplayModes(id, opts)
        let modes = (cfModes as? [CGDisplayMode]) ?? []
        let infos = modes.map {
            DisplayPolicy.ModeInfo(
                width: Int($0.width),
                height: Int($0.height),
                pixelWidth: Int($0.pixelWidth),
                pixelHeight: Int($0.pixelHeight),
                refreshRate: $0.refreshRate
            )
        }
        guard let index = DisplayPolicy.pickMode(infos) else {
            print("TFPanel：副屏没有 960×640（1 倍）模式，跳过切换")
            return
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == CGError.success, let config else {
            print("TFPanel：CGBeginDisplayConfiguration 失败，跳过切换")
            return
        }
        let configure = CGConfigureDisplayWithDisplayMode(config, id, modes[index], nil)
        guard configure == CGError.success else {
            CGCancelDisplayConfiguration(config)
            print("TFPanel：设置 960×640 失败（错误 \(Int(configure.rawValue))），保持当前模式")
            return
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == CGError.success else {
            CGCancelDisplayConfiguration(config)
            print("TFPanel：CGCompleteDisplayConfiguration 失败，保持当前模式")
            return
        }
        print("TFPanel：副屏已切换到 960 × 640")
    }
}
