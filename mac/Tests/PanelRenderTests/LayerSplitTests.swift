// 任务 T2：双层绘制的合成结果和接线约定（稳定判定、帧率钳制）。
import Testing
import Foundation
import CoreGraphics
import PanelCore
@testable import PanelRender

/// 读快照样例，变成 View。
private func readFixture(_ name: String) -> View {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try! Data(contentsOf: repoRoot
        .appendingPathComponent("fixtures").appendingPathComponent("\(name).json"))
    let snapshot = JSON.parse(data)!
    return ViewModel(config: Config()).update(snapshot, now: 0.0)
}

/// 逐像素比较两个位图，返回不同的像素个数（每通道容差 tol）。
private func diffPixels(_ a: CGContext, _ b: CGContext, tol: Int = 1) -> Int {
    precondition((a.width, a.height) == (b.width, b.height))
    let pa = a.data!.assumingMemoryBound(to: UInt8.self)
    let pb = b.data!.assumingMemoryBound(to: UInt8.self)
    var diff = 0
    for i in 0..<(a.width * a.height * 4) where abs(Int(pa[i]) - Int(pb[i])) > tol {
        diff += 1
    }
    return diff
}

// ---------------------------------------------------------------- 一、稳定帧两趟 = 整帧

@Suite struct LayerSplitCompose {
    @Test(arguments: ["decode", "idle", "offline"])
    func test_稳定帧两趟连画等于整帧(_ name: String) {
        let view = readFixture(name)
        let frame = Animator.settled(view)
        let whole = Renderer.makeContext(width: 960, height: 640)!
        Renderer().draw(whole, view: view, frame: frame)
        let split = Renderer.makeContext(width: 960, height: 640)!
        Renderer().drawStatic(split, view: view, frame: frame)
        Renderer().drawDynamic(split, view: view, frame: frame)
        let diff = diffPixels(whole, split)
        #expect(diff == 0, "\(name)：两趟连画和整帧有 \(diff) 个像素不一致")
    }
}

// ---------------------------------------------------------------- 二、稳定判定

@Suite struct LayerSplitSettled {
    /// 九个 α 和 dim 逐一设成 0.99（其余为 1），每个都足以判为非稳定。
    @Test(arguments: [("centerAlpha", 0.99), ("statsAlpha", 0.99), ("stripAlpha", 0.99),
                      ("valueAlpha", 0.99), ("ghostAlpha", 0.99), ("ticksAlpha", 0.99),
                      ("trackAlpha", 0.99), ("notchAlpha", 0.99), ("dim", 0.99)])
    func test_单个alpha偏低就不是稳定帧(_ key: String, _ value: Double) {
        var f = Frame()
        f.centerAlpha = 1; f.statsAlpha = 1; f.stripAlpha = 1
        f.valueAlpha = 1; f.ghostAlpha = 1; f.ticksAlpha = 1
        f.trackAlpha = 1; f.notchAlpha = 1; f.dim = 1
        // 用 KVC 不行（struct 不支持），逐个字段比名字
        switch key {
        case "centerAlpha": f.centerAlpha = value
        case "statsAlpha": f.statsAlpha = value
        case "stripAlpha": f.stripAlpha = value
        case "valueAlpha": f.valueAlpha = value
        case "ghostAlpha": f.ghostAlpha = value
        case "ticksAlpha": f.ticksAlpha = value
        case "trackAlpha": f.trackAlpha = value
        case "notchAlpha": f.notchAlpha = value
        case "dim": f.dim = value
        default: Issue.record("未知字段 \(key)")
        }
        #expect(!f.isSettled, "\(key)=0.99 时仍被判为稳定帧")
    }

    @Test func test_全部到位才是稳定帧() {
        var f = Frame()
        f.centerAlpha = 1; f.statsAlpha = 1; f.stripAlpha = 1
        f.valueAlpha = 1; f.ghostAlpha = 1; f.ticksAlpha = 1
        f.trackAlpha = 1; f.notchAlpha = 1; f.dim = 1
        #expect(f.isSettled)
        // 0.999 的边界值也算稳定
        var edge = f
        edge.trackAlpha = 0.999
        #expect(edge.isSettled)
    }
}

// ---------------------------------------------------------------- 三、帧率钳制

@Suite struct LayerSplitFps {
    @Test(arguments: [(60.0, 16), (1.0, 1000), (0.5, 1000), (100.0, 16), (Double.nan, 100)])
    func test_帧率换算(_ fps: Double, _ expect: Int) {
        #expect(frameIntervalMs(fps: fps, fadingIn: false) == expect, "fps=\(fps)")
    }

    @Test func test_淡入固定33() {
        #expect(frameIntervalMs(fps: 60.0, fadingIn: true) == 33)
        #expect(frameIntervalMs(fps: 1.0, fadingIn: true) == 33)
    }
}