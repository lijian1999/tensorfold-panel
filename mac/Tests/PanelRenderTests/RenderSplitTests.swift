// 任务 T1：Renderer 拆静态/动态两趟绘制后的验证测试。
import Testing
import Foundation
import CoreGraphics
import PanelCore
@testable import PanelRender

// ---------------------------------------------------------------- 共用辅助（照 RenderTests.swift 抄）

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let fixturesDir = repoRoot.appendingPathComponent("fixtures")

private let fixtureNames: [String] = {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: fixturesDir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
    return items.filter { url in
        guard url.pathExtension == "json" else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
}()

private func readFixture(_ name: String) -> View {
    let data = try! Data(contentsOf: fixturesDir.appendingPathComponent("\(name).json"))
    let snapshot = JSON.parse(data)!
    return ViewModel(config: Config()).update(snapshot, now: 0.0)
}

/// 新建一张 960×640 的空位图。
private func newSurface() -> CGContext {
    Renderer.makeContext(width: 960, height: 640)!
}

/// 两张位图逐像素比较，返回不同的像素个数（每个通道误差超过 tol 算不同）。
private func diffCount(_ a: CGContext, _ b: CGContext, _ tol: Int = 0) -> Int {
    let pa = a.data!.assumingMemoryBound(to: UInt8.self)
    let pb = b.data!.assumingMemoryBound(to: UInt8.self)
    var n = 0
    for y in 0..<640 {
        let row = y * a.bytesPerRow
        for x in 0..<960 {
            let o = row + x * 4
            for c in 0..<3 where abs(Int(pa[o + c]) - Int(pb[o + c])) > tol {
                n += 1
                break
            }
        }
    }
    return n
}

// ---------------------------------------------------------------- 一、两趟连画等于整帧

@Suite(.serialized) struct RenderSplitTests {
    /// 对全部样例：draw() 与 drawStatic + drawDynamic 逐像素一致（含 dim<1 的 round-rest）。
    @Test func test_两趟等于整帧() {
        #expect(!fixtureNames.isEmpty)
        let r = Renderer()
        for name in fixtureNames {
            let view = readFixture(name)
            let frame = Animator.settled(view)
            let whole = newSurface()
            r.draw(whole, view: view, frame: frame)
            let split = newSurface()
            r.drawStatic(split, view: view, frame: frame)
            r.drawDynamic(split, view: view, frame: frame)
            let n = diffCount(whole, split)
            #expect(n == 0, "样例 \(name) 两趟连画与整帧有 \(n) 个像素不同")
        }
    }

    /// 静态趟与 frame 无关：换一个 α 全 0.5 的 frame，drawStatic 输出一模一样。
    @Test func test_静态趟与frame无关() {
        let view = readFixture("decode-multi")
        let settled = Animator.settled(view)
        var odd = Frame()
        odd.trackAlpha = 0.5; odd.notchAlpha = 0.5; odd.ghostAlpha = 0.5
        odd.valueAlpha = 0.5; odd.ticksAlpha = 0.5; odd.centerAlpha = 0.5
        odd.statsAlpha = 0.5; odd.stripAlpha = 0.5; odd.pulseDec = 0.5
        odd.pulsePre = 0.5; odd.arcFrac = 0.6; odd.arcMix = 0.5
        odd.barFrac = 0.7
        let r = Renderer()
        let a = newSurface()
        r.drawStatic(a, view: view, frame: settled)
        let b = newSurface()
        r.drawStatic(b, view: view, frame: odd)
        #expect(diffCount(a, b) == 0, "静态趟跟着 frame 变了，不能按 view 缓存")
    }

    /// 动态趟独立：同一 view、两个不同 frame，先画静态打底再画动态，输出至少一处不同。
    @Test func test_动态趟跟着frame变() {
        let view = readFixture("decode-multi")
        let settled = Animator.settled(view)
        var other = Animator.settled(view)
        other.arcFrac = max(0.0, settled.arcFrac - 0.4)
        other.barFrac = max(0.0, settled.barFrac - 0.5)
        other.bigInt = "1"
        other.bigDec = ".1"
        let r = Renderer()
        func paint(_ frame: Frame) -> CGContext {
            let ctx = newSurface()
            r.drawStatic(ctx, view: view, frame: frame)
            r.drawDynamic(ctx, view: view, frame: frame)
            return ctx
        }
        let n = diffCount(paint(settled), paint(other))
        #expect(n > 0, "两个不同 frame 画出的动态趟完全一样")
    }

    /// 极端 view/frame 下两趟各画一遍不崩。
    @Test func test_文字趟不崩() {
        var v = View()
        v.state = "offline"
        v.muted = true
        v.dim = 0.4
        v.stripRight = [Seg("内存 "), Seg("9.3", "strong"), Seg(" GB")]
        v.cards = [Card("今日费用", "$0.60", "", "")]
        let offline = v
        v = View()
        v.bigInt = "$"; v.bigDec = "0.60"; v.bigSize = "cost"
        v.bigWhole = true; v.state = "idle"
        let cost = v
        v = View()
        v.bar = Bar(kind: "prog", frac: 0.0, level: "normal", text: [Seg("已算 ")])
        v.lanes = Lanes(max: 5, decoding: 3, prefilling: 1, waiting: 2)
        let prog = v
        v = View()
        v.cards = []
        v.ghost = 0.5
        let bare = v

        var f = Frame()
        f.dim = 0.4
        let dimFrame = f
        f = Frame()
        f.trackAlpha = 0.5; f.notchAlpha = 0.5; f.ghostAlpha = 0.5
        f.valueAlpha = 0.5; f.ticksAlpha = 0.5; f.centerAlpha = 0.5
        f.statsAlpha = 0.5; f.stripAlpha = 0.5; f.pulseDec = 0.5
        f.pulsePre = 0.5; f.arcFrac = 0.6; f.arcMix = 0.5
        f.barFrac = 0.7
        let halfFrame = f

        // Swift 里没有异常可捕获，意思是“全部画完不崩溃”。
        let r = Renderer()
        let ctx = newSurface()
        for view in [offline, cost, prog, bare] {
            for frame in [dimFrame, halfFrame, Animator.settled(view)] {
                r.drawStatic(ctx, view: view, frame: frame)
                r.drawDynamic(ctx, view: view, frame: frame)
            }
        }
        #expect(true)
    }
}