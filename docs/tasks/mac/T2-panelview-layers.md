# 任务 T2：PanelView 双层绘制 + Config 默认帧率 60

仓库：`/Users/kris/projects/tensorfold-panel`（分支 `mac-60fps`）。全部改动在 `mac/` 目录下，构建测试用 `cd mac && swift build`、`cd mac && swift test`。

## 背景

副屏仪表盘按 60fps 持续动画（解码、预填充期间），整帧重画太费 CPU。方案②：画面拆静态、动态两幅，稳定状态下静态层缓存、每帧只重画动态层。绘制器这一半（`Renderer.drawStatic` / `drawDynamic`）由并行任务 T1 做，本任务做视图接线这一半 + 配置默认值。你可以假定 T1 的接口（签名见下）已经存在；**开工时先看一眼 `Renderer.swift` 里有没有这两个方法，没有就先做第三步（Config），并在报告里说明**。

T1 交付的接口（`mac/Sources/PanelRender/Renderer.swift`）：

```swift
func drawStatic(_ ctx: CGContext, view: View, frame: Frame, width: Double = 960, height: Double = 640)
func drawDynamic(_ ctx: CGContext, view: View, frame: Frame, width: Double = 960, height: Double = 640)
```

保证：各路不透明度（`stripAlpha`、`centerAlpha`、`statsAlpha`、`valueAlpha`、`ghostAlpha`、`ticksAlpha`、`trackAlpha`、`notchAlpha`）与 `frame.dim` 全为 1 时，先 `drawStatic` 后 `drawDynamic` 与一次 `draw` 逐像素一致。这些 α 任一小于 1（切换画面的淡入、刻度淡入）时两趟连画不等价。

## 第一步：Config 默认帧率 10 → 60

`mac/Sources/PanelCore/Config.swift`：`animFps` 默认值 `10.0` → `60.0`，行尾注释里的“切换画面的淡入固定 30”保留；再补一句“60fps 配双层绘制”（意思到位即可）。

两处既有断言跟着改（这是本任务允许改的仅有的两处旧测试）：

- `mac/Tests/PanelCoreTests/BaseTests.swift` `TestConfig.test_defaults`：`#expect(c.animFps == 10.0)` → `== 60.0`
- `mac/Tests/PanelCoreTests/AppSettingsTests.swift`（约 33 行）：`#expect(c.animFps == 10)` → `== 60`

运行：`cd mac && swift build 2>&1 | tail -3 && swift test --filter PanelCoreTests 2>&1 | tail -5`，预期 269 个测试全过。

## 第二步：PanelView 单层改双层

改 `mac/Sources/TFPanel/PanelView.swift`。现状：一个 `CALayer`，`LayerDrawer.draw` 里 `animator.step` + `renderer.draw` 整帧，重画定时器按帧率调 `layer.setNeedsDisplay()`。目标结构：

- 容器层（现在的层改造）：不自己画，黑色背景，带 `needsDisplayOnBoundsChange`。
- 静态层、动态层：两个子 layer，`frame` = 容器 bounds，`contentsScale` 跟随窗口 backing scale，各带一个 delegate（照现有 `LayerDrawer` 的写法，两个实例或带 `kind` 的一个类，delegate 不能是 NSView 自己）。动态层盖在静态层上面。
- **动画每拍只 step 一次**：`step` 只在容器层（或 PanelView 自己的协调代码）里调，算出的 `Frame` 存下来，静态、动态两层画的时候共用，绝不能两层各调各的 `step`。
- **稳定帧**（`centerAlpha`、`statsAlpha`、`stripAlpha`、`valueAlpha`、`ghostAlpha`、`ticksAlpha`、`trackAlpha`、`notchAlpha`、`dim` 全部 ≥ 0.999）：静态层画 `drawStatic`（重画时机见下），动态层画 `drawDynamic`；重画定时器每拍只让**动态层** `setNeedsDisplay()`。
- **非稳定帧**（上面任一 α < 0.999）：静态层画整帧 `draw`、动态层画成透明（`ctx.clear(...)` 后确保内容为空即可）；重画定时器每拍让**两层**都重画。
- `dim < 1` 不影响这个判断——遮罩在 `drawDynamic` 末尾，稳定判定把它和其他 α 一样对待（`frame.dim ≥ 0.999`）。调暗/变亮过程本身是动画（`animating`），走非稳定路。
- **静态层重画时机**：画面数据变了（`viewChanged()`，即 AppController 传来的 View 变了）、 backing scale 变了（`viewDidChangeBackingProperties`）、模式切换。注意 `viewChanged()` 在定时器没跑时才被调（AppController 只在画面变了且定时器停着时通知），此时静态层必须立刻跟着重画；定时器在跑时，下一拍稳定帧会让静态层用新 view 重画，不用额外触发。实现时把“静态层是否需要重画”记成一个标志，在每一拍的开头（step 之后）统一处理，避免同一层一拍内被标两次。
- `frameIntervalMs` 的钳制 1–30 → 1–60：`fps = max(1.0, min(60.0, fps))`，返回 `max(16, Int((1000.0 / fps).rounded()))`；淡入期间固定 33 毫秒不变。注释里的“限制在每秒 1 到 30 帧”改成 60。
- 没有任何画面时（`currentView()` 为 nil）：两层都画成空/黑（静态层画黑、动态层清空），停定时器，行为同现在。

对外接口不变：`init(currentView:animFps:)`、`viewChanged()`、`stop()`、`redraw` 的行为（整幅重画下一次刷新时生效）不变。`AppController.swift` 不用改，但要确认它对 PanelView 的调用兼容（只是建、`viewChanged`、`stop`）。

运行：`cd mac && swift build 2>&1 | tail -3`，编译通过即可（TFPanel 没有测试；行为正确性靠第三步的新测试和既有像素测试）。

## 第三步：新增测试套件 LayerSplitTests

新建 `mac/Tests/PanelRenderTests/LayerSplitTests.swift`，风格照 `RenderTests.swift`。测试的是“双层画的合成结果”和“step 次数约定”，**不建 NSView**（无窗口环境），把 T2 接线里的核心规则直接对着 Renderer + Frame 断言：

1. **稳定帧两趟 = 整帧**：对 `fixtures/decode.json`、`fixtures/idle.json`、`fixtures/offline.json`，`Animator.settled(view)` 分别画一次 `draw`、一次 `drawStatic` + `drawDynamic`（各 960×640 位图），逐像素一致（容差 1）。（和 T1 的套件重复是刻意的：T1、T2 合并时只要一边有就能过。）
2. **稳定判定**：自造 frame，把每个 α 和 dim 逐一设成 0.99（其余为 1），每个都足以让“稳定判定”判为非稳定；全部 ≥ 0.999 时判为稳定。判定逻辑抽成一个可测的纯函数或 `Frame` 扩展（名字自定，比如 `isSettled`），放在 PanelRender（`Frame` 在 PanelCore，`Frame` 扩展放 PanelRender 也行——注意 PanelRender 不能改 PanelCore 的文件，扩展写在 PanelRender 的某个文件里即可）并写测试。
3. **帧率钳制**：帧率换算逻辑（fps → 毫秒间隔、上下限 1–60、NaN → 10、淡入 33）抽成纯函数（如 `frameIntervalMs(fps: Double, fadingIn: Bool) -> Int`，放 PanelRender 或 TFPanel 里能被测试 import 的位置——TFPanel 是可执行目标，测试引不进来，所以放 PanelRender），写测试：`60 → 16`、`1 → 1000`、`0.5 → 1000`（钳到 1）、`100 → 16`（钳到 60）、`NaN → 100`（10fps）、淡入 `true → 33`。

运行：`cd mac && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -15`。预期全部通过：PanelCoreTests 269、PanelRenderTests 15 + 新增若干（RenderSplitTests 若 T1 已合并，个数以实际为准）。

## 边界

- 只改：`mac/Sources/PanelCore/Config.swift`、`mac/Sources/TFPanel/PanelView.swift`、`mac/Tests/PanelCoreTests/BaseTests.swift`（1 行）、`mac/Tests/PanelCoreTests/AppSettingsTests.swift`（1 行）、新建 `mac/Tests/PanelRenderTests/LayerSplitTests.swift`；若帧率/稳定判定的纯函数放 PanelRender，可以新建或改 `mac/Sources/PanelRender/` 下的一个文件（推荐新建 `Helpers.swift`）。其他文件一律不动。
- T1 在并行改 `Renderer.swift` 和新增 `RenderSplitTests.swift`，你**不要**动这两个文件；万一编译时撞上 T1 的半成品，等几分钟后重试。
- 注释用中文、简洁。
- 结果报告：改动的文件、检查命令通过情况、歧义的处理、最后一行 `DONE` 或 `FAILED: <原因>`。