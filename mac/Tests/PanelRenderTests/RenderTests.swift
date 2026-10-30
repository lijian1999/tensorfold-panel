// 任务 R1：panel/tests/test_render.py 的翻译。
import Testing
import Foundation
import CoreGraphics
import ImageIO
import PanelCore
@testable import PanelRender

// ---------------------------------------------------------------- 共用辅助（对应测试文件顶部的辅助函数）

private let BG = (10, 11, 13)
private let CARD = (20, 22, 26)
private let TRACK = (29, 32, 37)
private let TEXT = (243, 244, 246)
private let TEXT_2 = (167, 173, 182)
private let ACCENT = (118, 226, 183)
private let AMBER = (240, 180, 76)
private let DANGER = (226, 122, 114)
private let TOL = 3

/// 仓库根目录（本文件在 mac/Tests/PanelRenderTests/ 下，往上四级）
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let fixturesDir = repoRoot.appendingPathComponent("fixtures")

/// 样例列表：fixtures 目录下（不含子目录）所有 .json 文件名去掉扩展名，排序。
private let fixtureNames: [String] = {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: fixturesDir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
    return items.filter { url in
        guard url.pathExtension == "json" else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
}()

/// 读快照样例，变成 View。
private func readFixture(_ name: String) -> View {
    let data = try! Data(contentsOf: fixturesDir.appendingPathComponent("\(name).json"))
    let snapshot = JSON.parse(data)!
    return ViewModel(config: Config()).update(snapshot, now: 0.0)
}

/// 把样例画到内存位图上，直接返回位图（不用写文件再读回来）。
private func surfaceOf(_ name: String) -> CGContext {
    let v = readFixture(name)
    let ctx = Renderer.makeContext(width: 960, height: 640)!
    Renderer().draw(ctx, view: v, frame: Animator.settled(v))
    return ctx
}

/// 取一个像素的 (R, G, B)。位图内存里每像素 4 字节，顺序是 R、G、B、A。
private func pixel(_ ctx: CGContext, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let offset = y * ctx.bytesPerRow + x * 4
    return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
}

/// 每个通道允许 3 以内的误差。
private func same(_ color: (Int, Int, Int), _ expect: (Int, Int, Int), _ tol: Int = TOL) -> Bool {
    abs(color.0 - expect.0) <= tol && abs(color.1 - expect.1) <= tol && abs(color.2 - expect.2) <= tol
}

/// 一行里最亮的像素（用来判断文字写出来没有、是什么颜色）。
private func rowBrightest(_ ctx: CGContext, _ y: Int, _ x0: Int, _ x1: Int) -> (Int, Int, Int) {
    var best = (0, 0, 0)
    for x in x0..<x1 {
        let p = pixel(ctx, x, y)
        if p.0 + p.1 + p.2 > best.0 + best.1 + best.2 { best = p }
    }
    return best
}

/// 圆弧上位置 f 对应的像素（960×640 图里，取圆弧中间那条线）。
private func ringPixel(_ f: Double, _ radius: Double = 124) -> (Int, Int) {
    let a = (135 + 270 * f) * Double.pi / 180
    let x = (166 + radius * cos(a)) * 2
    let y = (184 + radius * sin(a)) * 2
    return (Int(x.rounded(.toNearestOrEven)), Int(y.rounded(.toNearestOrEven)))
}

// ---------------------------------------------------------------- 一、每个样例都能画出来

@Suite struct DrawCrash {
    @Test func test_every_fixture() {
        let names = fixtureNames
        #expect(!names.isEmpty)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("r1-every-fixture-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = Renderer()
        for name in names {
            let path = tmp.appendingPathComponent("\(name).png")
            #expect(r.renderPNG(view: readFixture(name), path: path.path), "样例 \(name) 画失败")
            #expect(FileManager.default.fileExists(atPath: path.path), "样例 \(name) 的文件不存在")
            let src = CGImageSourceCreateWithURL(path as CFURL, nil)!
            let back = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            #expect((back.width, back.height) == (960, 640), "样例 \(name) 的尺寸不是 960×640")
        }
    }
}

// ---------------------------------------------------------------- 二、取像素检查颜色

// 这些测试都要向字体服务取字体；同时跑的测试一多，测试线程池会全卡在等回复上，所以这一组按顺序跑
@Suite(.serialized) struct DrawPixels {
    @Test func test_background() {
        // 整屏底色，以及每张卡片里没有字的地方是卡片底色。
        for name in fixtureNames {
            let surface = surfaceOf(name)
            #expect(pixel(surface, 4, 4) == BG, "\(name) 的 (4, 4) 不是底色")
            for i in 0..<3 {
                let y0 = Int((40 + 91.33 * Double(i)) * 2)   // 第 i 张卡片顶边（960×640 图的像素坐标）
                // 每卡四内角：在填充区内、上文字块的上下两行，取在没字的地方
                for (x, y) in [(700, y0 + 12), (926, y0 + 12), (700, y0 + 158), (926, y0 + 158)] {
                    let got = pixel(surface, x, y)
                    #expect(same(got, CARD),
                            "\(name) 卡片 \(i) 的 (\(x), \(y)) 是 \(got)，不是卡片底色")
                }
            }
        }
    }

    @Test func test_card_points() {
        // 每张卡片左上角那一小块，取在卡片里、没有字的地方。
        for name in fixtureNames {
            let surface = surfaceOf(name)
            for i in 0..<3 {
                let y = Int(((40 + 91.33 * Double(i) + 4) * 2).rounded(.toNearestOrEven))
                let got = pixel(surface, 700, y)
                #expect(same(got, CARD), "\(name) 卡片 \(i) 的 (700, \(y)) 是 \(got)")
            }
        }
    }

    @Test func test_decode_arc() {
        // 解码：f=0.25 是薄荷绿，f=0.9 只剩底环。
        let surface = surfaceOf("decode")
        var (x, y) = ringPixel(0.25)
        var got = pixel(surface, x, y)
        #expect(same(got, ACCENT), "解码圆弧 f=0.25 是 \(got)")
        (x, y) = ringPixel(0.9)
        got = pixel(surface, x, y)
        #expect(same(got, TRACK), "解码圆弧 f=0.9 是 \(got)")
    }

    @Test func test_prefill_arc() {
        // 预填充：f=0.25 是琥珀色。
        let surface = surfaceOf("prefill")
        let (x, y) = ringPixel(0.25)
        let got = pixel(surface, x, y)
        #expect(same(got, AMBER), "预填充圆弧 f=0.25 是 \(got)")
    }

    @Test func test_idle_arc() {
        // 空闲：f=0.25 是半透明的底环，既不是薄荷绿也不是纯底色。
        let surface = surfaceOf("idle")
        let (x, y) = ringPixel(0.25)
        let got = pixel(surface, x, y)
        #expect(!same(got, ACCENT), "空闲圆弧 f=0.25 是 \(got)")
        #expect(!same(got, BG), "空闲圆弧 f=0.25 是 \(got)")
    }

    @Test func test_offline_dot() {
        // 离线：状态条上只有一个红点。
        let surface = surfaceOf("offline")
        let got = pixel(surface, 36, 46)
        #expect(same(got, DANGER), "离线红点是 \(got)")
    }

    @Test func test_tick_50() {
        // 刻度数字：解码的“50”处（f=0.4，半径 R+20）附近有比背景亮的像素；
        // 空闲同一小块全是背景。
        let a = (135 + 270 * 0.4) * Double.pi / 180
        let cx = Int(((166 + (124 + 20) * cos(a)) * 2).rounded(.toNearestOrEven))
        let cy = Int(((184 + (124 + 20) * sin(a)) * 2).rounded(.toNearestOrEven))

        func block(_ s: CGContext) -> [(Int, Int, Int)] {
            // “50”位置周围 24×16 的小块。
            var px: [(Int, Int, Int)] = []
            for x in (cx - 12)..<(cx + 12) {
                for y in (cy - 8)..<(cy + 8) {
                    px.append(pixel(s, x, y))
                }
            }
            return px
        }

        let dec = block(surfaceOf("decode"))
        #expect(dec.contains { max($0.0, max($0.1, $0.2)) > 80 },
                "解码里“50”那一小块没有一个明显比背景亮的像素")
        let idle = block(surfaceOf("idle"))
        #expect(idle.allSatisfy { same($0, BG) }, "空闲里“50”那一小块不是纯背景（刻度不该显示）")
    }

    @Test func test_muted_is_gray() {
        // 灰色画面（一轮空隙）：主数字和卡片数值都是灰的。
        let gray = surfaceOf("round-rest")
        let bright = surfaceOf("idle")
        let x0 = 220, x1 = 444                       // 主数字那一行
        #expect(same(rowBrightest(gray, 370, x0, x1), TEXT_2),
                "灰色画面的主数字是 \(rowBrightest(gray, 370, x0, x1))")
        #expect(same(rowBrightest(bright, 370, x0, x1), TEXT),
                "正常画面的主数字是 \(rowBrightest(bright, 370, x0, x1))")
        for i in 0..<3 {                              // 三张卡片的数值那一行
            let y0 = 40 + 91.33 * Double(i)
            let top = y0 + (85.33 - 73.4) / 2
            let y = Int(((top + 16 + 17) * 2).rounded(.toNearestOrEven))
            #expect(same(rowBrightest(gray, y, 698, 912), TEXT_2),
                    "灰色画面卡片 \(i) 的数值是 \(rowBrightest(gray, y, 698, 912))")
            #expect(same(rowBrightest(bright, y, 698, 912), TEXT),
                    "正常画面卡片 \(i) 的数值是 \(rowBrightest(bright, y, 698, 912))")
        }
    }

    @Test func test_avg_pill() {
        // “近期平均”是琥珀色的：估算版预填充的标题行里有，TensorFold 的预填充里没有。
        func has_amber(_ s: CGContext) -> Bool {
            // y=256 这一行里有没有琥珀色像素（标题后面那个标记）。
            for x in 380..<530 {
                let p = pixel(s, x, 256)
                if abs(p.0 - AMBER.0) <= 12 && abs(p.1 - AMBER.1) <= 12 && abs(p.2 - AMBER.2) <= 12 {
                    return true
                }
            }
            return false
        }
        #expect(has_amber(surfaceOf("prefill-est")), "prefill-est 里没有琥珀色的“近期平均”")
        #expect(!has_amber(surfaceOf("prefill")), "prefill（TensorFold）里出现了琥珀色像素")
    }
}

// ---------------------------------------------------------------- 三、draw 对任何 View 都不能崩溃

@Suite struct DrawRobust {
    @Test func test_views() {
        var v = View()
        var views = [v]
        v = View(); v.cards = []
        views.append(v)
        v = View(); v.state = "offline"
        views.append(v)
        v = View(); v.bigInt = ""; v.bigDec = ""
        views.append(v)
        v = View(); v.bigInt = "$"; v.bigDec = "0.60"; v.bigSize = "cost"
        v.bigWhole = true; v.state = "idle"
        views.append(v)
        v = View(); v.bar = Bar(kind: "ctx", frac: 0.5, level: "normal",
                                text: [Seg("上下文 "), Seg("6.2K", "strong")])
        views.append(v)
        v = View(); v.bar = Bar(kind: "ctx", frac: 0.9, level: "warn",
                                text: [Seg("上下文 ", "warn"), Seg("262K", "warn")])
        views.append(v)
        v = View(); v.bar = Bar(kind: "ctx", frac: 0.99, level: "full", text: [])
        views.append(v)
        v = View(); v.bar = Bar(kind: "prog", frac: 0.0, level: "normal", text: [Seg("已算 ")])
        views.append(v)
        v = View(); v.bar = Bar(kind: "note", frac: 0.0, level: "normal", text: [Seg("10月4日 · 太平洋时间")])
        views.append(v)
        v = View(); v.bar = Bar(kind: "note", frac: 0.0, level: "normal", text: [])
        views.append(v)
        v = View(); v.cards = [Card(),
                               Card("内存", "94.2", "GB", "共 121 GB", true),
                               Card("本轮平均", "62.3", "", "tok/s")]
        views.append(v)
        v = View(); v.state = "offline"; v.muted = true; v.dim = 0.4
        v.stripRight = [Seg("内存 "), Seg("9.3", "strong"), Seg(" GB")]
        v.cards = [Card("今日费用", "$0.60", "", "")]
        views.append(v)
        v = View(); v.lanes = Lanes(max: 5, decoding: 3, prefilling: 1, waiting: 2)
        views.append(v)
        v = View(); v.lanes = Lanes(max: 0, offline: true); v.state = "offline"
        views.append(v)

        var f = Frame()
        var frames = [f]
        f = Frame(); f.dim = 0.4
        frames.append(f)
        f = Frame()
        f.trackAlpha = 0.5; f.notchAlpha = 0.5; f.ghostAlpha = 0.5
        f.valueAlpha = 0.5; f.ticksAlpha = 0.5; f.centerAlpha = 0.5
        f.statsAlpha = 0.5; f.stripAlpha = 0.5; f.pulseDec = 0.5
        f.pulsePre = 0.5; f.arcFrac = 0.6; f.arcMix = 0.5
        f.barFrac = 0.7
        frames.append(f)

        // Swift 里没有异常可捕获，这个测试的意思是“全部画完不崩溃”。
        let ctx = Renderer.makeContext(width: 960, height: 640)!
        let r = Renderer()
        for view in views {
            for frame in frames {
                for (w, h) in [(960.0, 640.0), (480.0, 320.0)] {
                    r.draw(ctx, view: view, frame: frame, width: w, height: h)
                }
            }
        }
        ctx.saveGState()
        r.draw(ctx, view: { var x = View(); x.state = "decode"; x.muted = true; x.dim = 0.4; return x }(),
               frame: Animator.settled(readFixture("decode")))
        ctx.restoreGState()
        #expect(true)
    }

    @Test func test_context_state() {
        // 四、画完之后上下文状态和画之前一样。
        // Python 比较的是矩阵、operator、tolerance、source 类型；Swift 里
        // 用 ctm 和 textMatrix 两项替代（见结果报告）。
        let ctx = Renderer.makeContext(width: 960, height: 640)!
        ctx.scaleBy(x: 2, y: 2)
        let ctmBefore = ctx.ctm
        let tmBefore = ctx.textMatrix
        let view = readFixture("decode")
        Renderer().draw(ctx, view: view, frame: Animator.settled(view))
        #expect(ctx.ctm == ctmBefore, "画完之后上下文状态没还原")
        #expect(ctx.textMatrix == tmBefore, "画完之后文字矩阵没还原")
    }
}

// ---------------------------------------------------------------- 五、速度

@Suite struct DrawStripFit {
    /// 模型名太长时截短，右边的文字和没有模型名时画得一样
    @Test func test_长模型名不压右边() {
        var v = View()
        v.state = "idle"
        v.stateName = "空闲"
        v.lanes.max = 8
        v.stripRight = [Seg("内存 "), Seg("29.5", "strong"), Seg(" / 48 GB")]
        var bare = v
        v.stripLeft = "Qwen3-4B-Instruct-2507-4bit-very-long-name · oMLX"
        bare.stripLeft = ""
        let a = Renderer.makeContext(width: 960, height: 640)!
        let b = Renderer.makeContext(width: 960, height: 640)!
        Renderer().draw(a, view: v, frame: Animator.settled(v))
        Renderer().draw(b, view: bare, frame: Animator.settled(bare))
        var diff = 0
        for y in 30..<62 { for x in 730..<932 where !same(pixel(a, x, y), pixel(b, x, y), 0) { diff += 1 } }
        #expect(diff == 0)
        // 左边确实写了字
        #expect(rowBrightest(a, 46, 300, 600) != rowBrightest(b, 46, 300, 600))
    }
}

@Suite struct DrawSpeed {
    @Test func test_hundred_frames() {
        // 同一个画面画 100 次，总共不超过 2 秒。
        let view = readFixture("decode-multi")
        let frame = Animator.settled(view)
        let ctx = Renderer.makeContext(width: 960, height: 640)!
        let r = Renderer()
        r.draw(ctx, view: view, frame: frame)                 // 先热身一次
        let start = Date()
        for _ in 0..<100 {
            r.draw(ctx, view: view, frame: frame)
        }
        let used = Date().timeIntervalSince(start)
        #expect(used < 2.0, "画 100 次用了 \(used) 秒")
    }
}

// ---------------------------------------------------------------- 全部样例的截图（给编排者对照原型用）

@Suite struct RenderShots {
    @Test func test_写出全部样例() {
        let dir = repoRoot.appendingPathComponent("mac/.build/render-shots")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = Renderer()
        for name in fixtureNames {
            let path = dir.appendingPathComponent("\(name).png").path
            #expect(r.renderPNG(view: readFixture(name), path: path), "样例 \(name) 写出失败")
        }
    }
}
