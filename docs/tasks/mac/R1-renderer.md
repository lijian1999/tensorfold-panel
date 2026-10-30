# 任务 R1：绘制（Core Graphics + Core Text）

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（第 2、6、7 节和第 9 节）。本任务只改这两个文件（都已经有一个占位的空壳）：

- `mac/Sources/PanelRender/Renderer.swift`
- `mac/Tests/PanelRenderTests/RenderTests.swift`

不要改别的文件。已有文件里发现问题时不要改，写进结果报告。

## 背景

副屏画面由 `View`（画面上每块写什么）和 `Frame`（这一帧的动画状态）决定，`panel/render.py` 用 cairo + Pango 把它们画出来。本任务把它翻成 Swift，用 Core Graphics 画图形、Core Text 排字。坐标、尺寸、颜色、字号、字距、每个分支都照 `render.py`；字体换成系统字体（中文自动用苹方）。`panel/tests/test_render.py` 的 13 个测试逐条翻译。

## 已经验证过的底层写法（直接照用）

下面几段在这台机器上验证过，照抄即可。

**位图**（`makeContext`）：

```swift
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
ctx.translateBy(x: 0, y: CGFloat(height))
ctx.scaleBy(x: 1, y: -1)          // 左上角原点、y 向下
```

这样建出来的位图，内存里第 y 行就是图上从上往下数的第 y 行，每像素 4 字节依次是 R、G、B、A。

**字体和排字**：

```swift
func font(_ size: CGFloat, _ bold: Bool) -> CTFont {
    NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont   // 等宽数字
}
// 一段文字：颜色取自上下文的填充色，字距 = ls（em 数）× 字号
var attrs: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): f,
    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
]
if ls != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = ls * size }
let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))     // 宽
let h = CTFontGetAscent(f) + CTFontGetDescent(f)                      // 逻辑矩形的高
let base = CTFontGetAscent(f)                                         // 基线到逻辑矩形顶边
// 在 y 向下的上下文里把基线放在 (x, baselineY)：
ctx.setFillColor(color)
ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
ctx.textPosition = CGPoint(x: x, y: baselineY)
CTLineDraw(line, ctx)
```

Pango 的 `_box` 返回的 `(w, h, base)` 对应上面的 `w`、`h`、`base`。`render.py` 里的布局缓存不用搬：每次现建 `CTLine` 就够快。

**圆弧**：cairo 的 `arc(cx, cy, r, a0, a1)`（角度增大的方向）对应

```swift
ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: a0, endAngle: a1, clockwise: false)
```

**圆角矩形**：`_rrect` 用 `ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))`，其中 `r = min(r, w / 2, h / 2)`。

**整块乘不透明度**（`_block`）：

```swift
ctx.saveGState()
ctx.setAlpha(alpha)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
// 画这一块
ctx.endTransparencyLayer()
ctx.restoreGState()
```

**还原上下文**：`saveGState`/`restoreGState` 不保存文字矩阵。`draw` 开头记下 `ctx.textMatrix`，结尾 `restoreGState()` 之后再把它设回去。

## 第一步：写 `Renderer.swift`

接口照接口约定 9.2 节。把 `panel/render.py` 逐个函数翻译：

- 颜色常量照搬（`BG`、`CARD`、…、`PILL_TEXT`、`TRACK`），做成文件内的 `private let`，类型 `CGColor`（`CGColor(srgbRed:green:blue:alpha:)`）。带不透明度的地方（`set_source_rgba(*color, a)`）用 `color.copy(alpha: a)`。`_mix` 按 R、G、B 分量混合后新建颜色。
- `DIAL`、`STRIP_Y` 照搬。`FAMILY`、`_LAYOUTS`、`_desc`、`_attrs`、`_layout` 换成上面的字体和排字写法。
- `_draw_line`、`_text`、`_block`、`_rrect`、`_circle`、`_clamp01`、`_dots`、`_strip`、`_dial`、`_mix`、`_arc_color`、`_ticks`、`_cap_line`、`_big`、`_bar`、`_center`、`_card`、`_cards` 逐个翻成私有方法，每个分支、每个数值照抄。
  - `_draw_line` 的 `mode="center"`：每段的顶边是 `anchor_y - h / 2`，基线是顶边加 `base`。`mode="baseline"`：基线 `anchor_y - 主段h / 2 + 主段base`，各段都画在这条基线上。
  - 线宽、线帽：`set_line_width` → `setLineWidth`，`LINE_CAP_ROUND` → `.round`，`LINE_CAP_BUTT` → `.butt`。cairo 的“建路径 → stroke/fill”对应 `addArc`/`addPath`/`move(to:)`/`addLine(to:)` 之后 `strokePath()`/`fillPath()`。
  - 弧度：`math.radians(d)` → `d * .pi / 180`。
  - `_ticks` 里的刻度文字取 `(scales[view.scale] ?? scales["decode"]!).labels`，位置取 `tickFracs`。
- `draw`：`saveGState` → `scaleBy(x: width / 480, y: height / 320)` → 底色 → 各块 → 调暗 → `restoreGState` → 设回文字矩阵。
- `makeImage`：`makeContext` 建位图，`draw` 画满，`ctx.makeImage()`。
- `renderPNG`：`makeImage` 之后用 `CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)`、`CGImageDestinationAddImage`、`CGImageDestinationFinalize` 写文件（`import ImageIO`、`import UniformTypeIdentifiers`）。

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
```

最后一行是 `Build complete!`。

## 第二步：翻译测试 `RenderTests.swift`

把 `panel/tests/test_render.py` 翻成 swift-testing，规矩照接口约定第 7 节：四个类 → 四个 `@Suite struct`（`DrawCrash`、`DrawPixels`、`DrawRobust`、`DrawSpeed`），13 个测试方法 → 13 个 `@Test`，名字照抄。文件开头 `import Testing`、`import Foundation`、`import CoreGraphics`、`import PanelCore`、`@testable import PanelRender`。

辅助函数（都写成文件内的 `private`）：

- 仓库根目录：`URL(fileURLWithPath: #filePath)` 往上四级；样例目录是它下面的 `fixtures`。样例列表 = 这个目录下（不含子目录）所有 `.json` 文件名去掉扩展名，排序。
- `readFixture(name)`：读样例 JSON（`JSON.parse(data)`），`ViewModel(config: Config()).update(snapshot, now: 0.0)`。
- `surfaceOf(name)`：`Renderer.makeContext(width: 960, height: 640)` 建位图，`Renderer().draw(ctx, view: v, frame: Animator.settled(v))`，返回这个位图（不用写文件再读回来）。
- `pixel(ctx, x, y) -> (Int, Int, Int)`：`ctx.data!.assumingMemoryBound(to: UInt8.self)`，偏移 `y * ctx.bytesPerRow + x * 4`，依次是 R、G、B。
- `same`、`rowBrightest`、`ringPixel` 照 Python。颜色常量、`TOL = 3` 照搬。

翻译时的对应：

- `test_every_fixture`：每个样例 `renderPNG` 到临时目录（接口约定第 7 节的写法），断言文件存在，再用 `CGImageSourceCreateWithURL` + `CGImageSourceCreateImageAtIndex` 读回来，断言宽高是 960×640。
- `test_views`：`View()` 再逐个赋值构造 Python 里那 15 个 View；三个 Frame 用 `Frame()` 再赋值。Swift 里没有异常可捕获，这个测试的意思是“全部画完不崩溃”，循环画完后 `#expect(true)`。末尾那次画 `View(state="decode", muted=True, dim=0.4)` 也照做。
- `test_context_state`：位图先 `scaleBy(x: 2, y: 2)`，记下 `ctx.ctm` 和 `ctx.textMatrix`，画完后断言两个都和之前相等（替代 Python 里比较的矩阵、operator、tolerance、source 类型，写进结果报告）。
- `test_hundred_frames`：用 `Date()` 或 `ContinuousClock` 计时，断言 100 次 `draw` 少于 2 秒。

```sh
(cd mac && swift test --filter PanelRenderTests 2>&1 | grep -E '✘|error:' | head -30; swift test --filter PanelRenderTests 2>&1 | tail -1)
```

前面没有输出，最后一行以 `✔ Test run with 13 tests` 开头、以 `passed after` 加秒数结尾。

像素检查没通过时，先看是不是自己翻译的坐标、颜色、分支和 `render.py` 不一致；可以用 `renderPNG` 把那个样例画到 `mac/.build/` 下看。

## 第三步：新增一个测试

在 `RenderTests.swift` 末尾新增 `@Suite struct RenderShots`，一个测试 `test_写出全部样例`：把每个样例按 `surfaceOf` 的画法 `renderPNG` 到 `mac/.build/render-shots/<样例名>.png`（目录不存在就建），断言每个都返回 `true`。这个目录给编排者对照原型用，测试结束不删。

```sh
(cd mac && swift test --filter PanelRenderTests 2>&1 | tail -1; ls .build/render-shots | wc -l; ls ../fixtures/*.json | wc -l)
```

第一行以 `✔ Test run with 14 tests` 开头、以 `passed after` 加秒数结尾；后两行的数字相同。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | grep -E '✘' | head; swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelRenderTests/RenderTests.swift
git status --short
```

通过的标准：

- 第一条前面没有输出，最后一行以 `✔ Test run with` 开头、以 `passed after` 加秒数结尾（PanelCore 已有的测试加上本任务的 14 个）。
- 第二条输出 `14`。
- `git status --short` 只列出本任务的两个文件（` M`）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做；别的任务同时在别处改 PanelCore，这里不需要它们。
