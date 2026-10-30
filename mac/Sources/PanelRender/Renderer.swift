// 绘制：View + Frame → Core Graphics。任务 R1 照 panel/render.py 填写（见接口约定 9.2 节）。
import AppKit
import CoreText
import PanelCore

public final class Renderer {
    public init() {}

    public func draw(_ ctx: CGContext, view: View, frame: Frame, width: Double = 960, height: Double = 640) {}

    public static func makeContext(width: Int, height: Int) -> CGContext? { nil }

    public func makeImage(view: View, frame: Frame? = nil, width: Int = 960, height: Int = 640) -> CGImage? { nil }

    public func renderPNG(view: View, path: String, frame: Frame? = nil) -> Bool { false }
}
