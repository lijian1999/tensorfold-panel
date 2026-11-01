# 任务 T1：Renderer 拆静态/动态两趟绘制

仓库：`/Users/kris/projects/tensorfold-panel`（分支 `mac-60fps`，工作区干净，起点提交 `f0ea3f8`）。
全部改动在 `mac/` 目录下完成，构建和测试用 `cd mac && swift build`、`cd mac && swift test`。第一次构建要一两分钟。

## 背景

副屏仪表盘要按 60fps 画，但整帧重画太费 CPU。方案：把一帧拆成静态、动态两趟，稳定状态下静态层缓存、每帧只重画动态层。本任务只做绘制器这一半（拆两个方法 + 测试），视图的双层接线是另一个任务，你不用做。

现状：`mac/Sources/PanelRender/Renderer.swift`（约 560 行）的 `draw(_ ctx: CGContext, view: View, frame: Frame, width: Double, height: Double)` 每次画整帧。内部已有的私有绘制方法（`_strip`、`_dial`、`_ticks`、`_center`、`_cards` 等）不用改逻辑，任务是把它们按静态/动态归到两个新公开方法里。测试文件是 `mac/Tests/PanelRenderTests/RenderTests.swift`（15 个测试，风格照它）。

## 拆分内容

**静态**（稳定画面里每帧画出来都一样的元素）：
背景、状态条里的文字和“+N”排队数（不含流指示点圆点）、底环、刻度缺口、刻度数字、标题行（含“精确”/“近期平均”标记）、右侧三栏卡片、离线画面的“引擎离线”两行文字。

**动态**（每帧可能变的元素）：
流指示点（`_dots`，含离线时状态条上那个红点）、灰色小点（ghost）、数值弧、主数字、进度条整块（底槽 + 填充条 + 说明文字，`_bar` 的全部）、调暗遮罩（draw 末尾 `dim < 1` 时的那块黑色覆盖）。

归属细节（照做，不要自己再分）：

- 状态条离线时的红点归**动态**，所以状态条要拆：`_strip` 拆出点的那部分归动态，其余（`"+N"`、状态名、左右两段文字）归静态。静态的起点横坐标 x 的计算里用到的“点的右边缘”，动态画点、静态画文字，两边各自算。
- 底环的透明度 `frame.trackAlpha` 在淡入期间会小于 1，但稳定后恒为 1；归静态（判断稳定与否由调用方负责，见 T2，你不用管）。
- 刻度缺口（`notchAlpha`）、刻度数字（`ticksAlpha`）同样归静态。

## 接口（名字一字不差）

```swift
public extension Renderer {
    /// 画静态一趟：背景 + 稳定画面里每帧不变的元素。签名和 draw 一样。
    func drawStatic(_ ctx: CGContext, view: View, frame: Frame, width: Double = 960, height: Double = 640)
    /// 画动态一趟：每帧可能变的元素。ctx 此时已经画过静态。
    func drawDynamic(_ ctx: CGContext, view: View, frame: Frame, width: Double = 960, height: Double = 640)
}
```

两个方法都要做 `draw` 开头那段 `saveGState + scaleBy(width/480, height/320)` 和结尾的 `restoreGState + textMatrix` 还原，行为与 `draw` 一致。

`draw()` 改成：`drawStatic` 紧接 `drawDynamic`，其余行为一字不变。已有 15 个绘制测试不许改（逐像素断言会抓住回归）。

## 正确性条件

各路不透明度（`stripAlpha`、`centerAlpha`、`statsAlpha`、`valueAlpha`、`ghostAlpha`、`ticksAlpha`、`trackAlpha`、`notchAlpha`）和 `frame.dim` 全为 1 时（即 `Animator.settled(view)` 产出的稳定帧，除了 `settled` 里 `dim = clamp01(view.dim)` 可能小于 1 的那些 view），**两趟先后画与 `draw()` 逐像素一致**。核对要点：

- 叠序：静态先画、动态后画，动态压在静态上。已逐个核实过互不重叠的有：流指示点与状态条文字、数值弧与刻度数字/标题、数值弧与右侧卡片。唯一有序关系“主数字压在弧上”（`_center` 里弧先进 `_dial`、`_big` 后画）拆开后仍保持：弧在动态趟里先画，主数字后画。
- `_block`（透明图层）语义：组不透明度 < 1 时，静态、动态两块各自开图层再叠加，与整帧一个图层里叠加的结果不同。所以 `drawStatic`/`drawDynamic` 只要求在“各 α 与 dim 全为 1”时逐像素一致；α<1 的场合由调用方整帧画（`draw()` 保持原样，天然正确）。
- `settled` 帧里 `dim` 可能小于 1（view 自带 `dim` 字段，空闲 30 分钟后调暗的画面）：调暗遮罩画在动态趟末尾，两趟连画时遮罩仍盖住整帧，与 `draw()` 一致。

## 测试要求

新建 `mac/Tests/PanelRenderTests/RenderSplitTests.swift`，风格照 `RenderTests.swift`（swift-testing，`import Testing` + `@testable import PanelRender`，辅助函数照它的写法抄）。套件名 `RenderSplitTests` 全测试目标唯一。至少这些测试：

1. **两趟等于整帧**：对 `fixtures/` 目录下全部 .json 样例（照 `RenderTests.swift` 里 `fixtureNames` 的做法取），用 `Animator.settled(view)` 分别画一次 `draw()`、一次 `drawStatic` + `drawDynamic`（各自新建 960×640 位图），逐像素比较，每个通道容差 0（若因文字抗锯齿等偶然原因对不齐，容差最多放宽到 1，并在报告里说明）。`dim < 1` 的样例（`round-rest`）也要比——遮罩在动态趟末尾，两趟连画应一致。
2. **静态趟与 frame 无关**：同一个 view（用 `decode-multi`），两次画 `drawStatic`，frame 分别用 `Animator.settled(view)` 和一个自造的不同 frame（各 α 取 0.5、`barFrac` 0.7 之类），两次 `drawStatic` 输出逐像素一致（容差 0）——证明静态层可以按 view 缓存。
3. **动态趟独立**：同一个 view、两个不同 frame 画 `drawDynamic`（先画静态打底），输出**不**逐像素一致（至少一处不同）——证明动态趟确实跟着 frame 变。
4. **文字趟不崩**：照 `RenderTests.swift` 的 `DrawRobust.test_views` 挑 3–4 组极端 view/frame，`drawStatic`、`drawDynamic` 各画一遍不崩即可。

已有测试一个都不许动。检查命令（第一步末尾和最后都要跑）：

```sh
cd mac && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -15
```

预期：编译无错误；测试全过，`Test run with 15 tests`（PanelRender 既有）+ 新套件的个数，`PanelCoreTests` 的 269 不受影响。

## 边界

- 只改 `mac/Sources/PanelRender/Renderer.swift`、新建 `mac/Tests/PanelRenderTests/RenderSplitTests.swift`。其他文件（含 `Package.swift`、`RenderTests.swift`、PanelCore、TFPanel）一律不动。
- 注释用中文、简洁；新方法的注释说明各自画什么、什么条件下两趟连画与整帧一致。
- 步骤：第一步先改 Renderer 并跑一次上面的命令（此时新测试还没写，确认 15 个旧测试全过、`draw` 行为没变）；第二步写新测试文件再跑，全过。
- 结果报告：改动的文件、检查命令通过情况、歧义的处理（没有写“无”）、最后一行 `DONE` 或 `FAILED: <原因>`。