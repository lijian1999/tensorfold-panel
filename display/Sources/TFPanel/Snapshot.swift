import AppKit
import Foundation
import PanelCore
import SwiftUI

/// 离屏截图：渲染 `PanelScreenView`（settled 动画状态、scale = 2）输出 960×640 PNG。
enum Snapshot {
    /// display/Fixtures/ 目录（用 #filePath 相对定位）
    static func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TFPanel
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // display
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// 构造连接状态机：
    /// - fixture 路径：t=100 记录一次成功，now 用 100；
    /// - `offline`：先 idle.json 在 t=100 成功，再在 t=101/101.1/101.2 失败 3 次，now 用 143（「已离线 42 秒」）。
    static func makeTracker(_ source: String) throws -> ConnectionTracker {
        var tracker = ConnectionTracker(bootTime: 0)
        if source == "offline" {
            let m = try JSONDecoder().decode(
                Metrics.self,
                from: Data(contentsOf: fixturesDir().appendingPathComponent("idle.json"))
            )
            tracker.recordSuccess(m, at: 100)
            tracker.recordFailure(at: 101)
            tracker.recordFailure(at: 101.1)
            tracker.recordFailure(at: 101.2)
        } else {
            let m = try JSONDecoder().decode(
                Metrics.self,
                from: Data(contentsOf: URL(fileURLWithPath: source))
            )
            tracker.recordSuccess(m, at: 100)
        }
        // decode / done：注入 80 个确定性小曲线样本，保证截图可复现
        if let state = tracker.lastSuccess?.state, state == "decode" || state == "done" {
            tracker.sparkSamples = (0..<80).map { i in
                let d = Double(i)
                let smooth = 58 + 8 * sin(d / 9)
                let raw = smooth + 30 * sin(d * 1.7) * (0.5 + 0.5 * sin(d / 5))
                return SparkSample(raw: raw, smooth: smooth)
            }
        }
        return tracker
    }

    /// 内存固定 (21.4, 64)，保证截图可复现
    @MainActor
    static func render(_ tracker: ConnectionTracker, now: Double, scale: CGFloat) -> NSImage? {
        let model = PanelViewModel.make(tracker: tracker, now: now, memory: (21.4, 64))
        let frame = PanelAnimator().settled(model: model)
        let renderer = ImageRenderer(content: PanelScreenView(model: model, frame: frame, scale: scale))
        renderer.scale = 1   // 视图本身已按 scale 设计，输出 960×640 像素
        return renderer.nsImage
    }

    /// NSImage → PNG 落盘
    static func save(_ image: NSImage?, to url: URL) throws {
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed
        }
        try png.write(to: url)
    }

    enum SnapshotError: LocalizedError {
        case renderFailed
        var errorDescription: String? { "渲染图像失败" }
    }
}
