# 任务 A3：菜单栏、设置窗口、登录项

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（8.3、8.5、8.7 和第 9 节），再读设计文档 `docs/design-mac.md` 的“费用单价”“设置”“时区”三节。界面以原型 `docs/dashboard-prototype.html` 里“菜单栏和设置窗口”那一块为准（搜 `mac-menu` 和 `mac-win`）。本任务只改这些文件：

- `mac/Sources/PanelCore/PriceForm.swift`（新建）
- `mac/Sources/PanelCore/MenuText.swift`（新建）
- `mac/Tests/PanelCoreTests/PriceFormTests.swift`（新建）
- `mac/Tests/PanelCoreTests/MenuTextTests.swift`（新建）
- `mac/Sources/TFPanel/StatusMenu.swift`（现在是占位的空壳，改成真的实现）
- `mac/Sources/TFPanel/SettingsWindow.swift`（同上）
- `mac/Sources/TFPanel/LoginItem.swift`（同上）

不要改别的文件。`AppController.swift`、`ScreenManager.swift` 等是别的任务的，这里只按接口约定 9.5 节用它们（现在是占位的空壳，能编译，属性有默认值）。

**不要启动窗口程序**（不带参数运行 `TFPanel`、打开 `TFPanel.app`）。本任务用单元测试和编译检查，界面由编排者实测。

## 背景

副屏 app 只有一个菜单栏图标。点开是一个菜单，能看副屏和引擎的状态、选时区、开关自动切换和登录时启动、打开设置窗口。设置窗口三页：引擎（地址、API key）、费用（每个模型的单价）、副屏（屏幕名）。所有设置存在 `AppSettings`（PanelCore，已有）里，改完调 `controller.settingsChanged()` 立刻生效。

菜单文字和单价表的规则是纯逻辑，放进 PanelCore 写测试；菜单和窗口本身放在 app 里。

## 第一步：`MenuText.swift`（PanelCore）

```swift
/// 菜单里引擎那一行
public func engineMenuText(issue: EngineIssue, address: String) -> String
/// 时区子菜单的三项标题，顺序同 ZoneChoice.allCases
public func zoneMenuTitles(systemZone: String) -> [String]
/// 菜单里“费用单价…”那一项的标题
public func priceMenuTitle(currentModel: String?, prices: [String: ModelPrice]) -> String
```

- `engineMenuText`：`.none` → `"引擎：oMLX · <address>"`；`.unreachable` → `"引擎：未连接"`；`.notOmlx`、`.needsKey` → `"引擎：" + issue.message!`。
- `zoneMenuTitles`：`["跟随系统（<zoneDisplayName(systemZone)>）", "北京时间", "太平洋时间"]`（括号是全角的）。
- `priceMenuTitle`：`currentModel` 是非空字符串且 `prices[currentModel]` 是 nil → `"费用单价…（当前模型未填）"`；否则 `"费用单价…"`。

测试 `MenuTextTests.swift`：`@Suite struct TestMenuText`，3 个测试：

1. `test_引擎一行`：四种 `issue` 各断言一次（地址用 `"127.0.0.1:8000"`）。
2. `test_时区标题`：`systemZone: "Asia/Shanghai"` → `["跟随系统（北京时间）", "北京时间", "太平洋时间"]`；`"Asia/Tokyo"` → 第一项是 `"跟随系统（日本标准时间）"`。
3. `test_费用单价标题`：当前模型没填 → 带“（当前模型未填）”；填了 → 不带；`currentModel` 是 nil 或 `""` → 不带。

## 第二步：`PriceForm.swift`（PanelCore）

```swift
public struct PriceRow: Equatable, Sendable {
    public var model: String
    public var present: Bool          // 在 oMLX 现在的模型列表里
    public var price: ModelPrice?
    public init(model: String, present: Bool, price: ModelPrice?)
}
/// 单价表的行：现在的模型按原顺序在前（present = true）；以前用过的、填过单价的、现在不在列表里的排在后面，按名字排序（present = false）。同名只出现一次。
public func priceRows(current: [String], known: [String], prices: [String: ModelPrice]) -> [PriceRow]

public enum PriceInput: Equatable, Sendable { case empty, valid(ModelPrice), invalid }
/// 三个输入框的文字 → 单价。去掉首尾空白后三个都是空串 → empty；三个都能转成有限的、不小于 0 的 Double → valid；其余 → invalid
public func parsePrice(input: String, cached: String, output: String) -> PriceInput

/// 单价显示成输入框里的文字：最多 6 位小数，去掉末尾的 0 和小数点（0.15 → "0.15"，1.0 → "1"，0.016 → "0.016"）
public func priceText(_ value: Double) -> String
```

- `priceRows`：`current` 里的空名字跳过；后半部分是 `known` 和 `prices.keys` 的并集去掉 `current` 里有的、去掉空名字，按 `<` 排序。
- `parsePrice`：用 `Double(String)` 转；`"1e3"` 这种 `Double` 认得的写法也算。
- `priceText`：`String(format: "%.6f", v)` 之后去掉末尾的 `0`，再去掉末尾的 `.`。

测试 `PriceFormTests.swift`：`@Suite struct TestPriceForm`，5 个测试：

1. `test_行的顺序`：`current = ["B", "A"]`，`known = ["C", "A", ""]`，`prices` 有 `"D"`、`"A"` → 行依次是 `B(present)`、`A(present, 带单价)`、`C(gone)`、`D(gone, 带单价)`。
2. `test_没有模型`：三个都空 → `[]`。
3. `test_三个都空`：`("", " ", "")` → `.empty`。
4. `test_填对和填错`：`("0.15", "0.016", "0.47")` → `.valid(ModelPrice(input: 0.15, cached: 0.016, output: 0.47))`；`("0.15", "", "0.47")`、`("-1", "0", "0")`、`("abc", "0", "0")`、`("inf", "0", "0")` → `.invalid`；`(" 1 ", "0", "2")` → `.valid`。
5. `test_单价文字`：`0.15 → "0.15"`，`1.0 → "1"`，`0.016 → "0.016"`，`0 → "0"`，`2.5 → "2.5"`。

```sh
(cd mac && swift test --filter '\.Test(MenuText|PriceForm)/' 2>&1 | grep -E '✘|error:' | head -20; swift test --filter '\.Test(MenuText|PriceForm)/' 2>&1 | tail -1)
```

前面没有输出，最后一行以 `✔ Test run with 8 tests` 开头、以 `passed after` 加秒数结尾。

## 第三步：`LoginItem.swift`

接口照接口约定 9.5 节，照第 1 版（`git show 6c9ad9a:display/Sources/TFPanel/StatusMenu.swift` 里的 `loginItemAvailable`、`toggleLoginItem`）：

- `available`：`Bundle.main.bundleIdentifier != nil`。
- `enabled`：`available && SMAppService.mainApp.status == .enabled`。
- `set(_ on:)`：不可用返回 false；`on` 时 `register()`、否则 `unregister()`，抛错时 `Log.write("登录项设置失败：<错误>")` 返回 false；成功返回 true。

## 第四步：`StatusMenu.swift`

`@MainActor final class StatusMenu: NSObject, NSMenuDelegate`，`init(controller: AppController)`。图标照第 1 版（SF Symbol `gauge.with.dots.needle.67percent`，找不到就写文字 `TF`），`NSStatusItem` 用 `squareLength`。菜单从上到下（照原型的 `mac-menu`）：

| 项 | 内容和行为 |
| --- | --- |
| 副屏 | `"副屏：" + controller.screens.statusText`，不能点 |
| （提示） | `controller.screens.modeNote` 不是 nil 时多一行，内容就是它，不能点 |
| 引擎 | `engineMenuText(issue: controller.issue, address: controller.settings.address)`，不能点 |
| 分隔线 | |
| 时区 ▸ | 子菜单三项，标题是 `zoneMenuTitles(systemZone: TimeZone.current.identifier)`，当前的 `controller.settings.zone` 打勾；点了就设 `settings.zone`，调 `controller.settingsChanged()` |
| 费用单价… | 标题 `priceMenuTitle(currentModel: controller.currentModel, prices: controller.settings.prices)`；点了打开设置窗口的“费用”一页 |
| 自动切换到 960 × 640 | 勾选项，`settings.autoSwitchMode`；点了取反、调 `controller.settingsChanged()`，变成开的时候再调 `controller.screens.applyAutoSwitch()` |
| 登录时启动 | 勾选项，状态是 `LoginItem.enabled`；`LoginItem.available` 为假时不能点。点了 `LoginItem.set(!LoginItem.enabled)`，成功后把 `settings.launchAtLogin` 设成新状态 |
| 设置… | 快捷键 `,`（⌘,），打开设置窗口的“引擎”一页 |
| 分隔线 | |
| 退出 | 快捷键 `q`（⌘Q），`NSApplication.terminate` |

- `menuWillOpen` 时刷新所有标题、勾选状态、提示行的有无。
- 设置窗口由 `StatusMenu` 持有一个 `SettingsWindowController(controller:)`，用 `show(page:)` 打开。

## 第五步：`SettingsWindow.swift`

`@MainActor final class SettingsWindowController`，接口照接口约定 9.5 节。窗口是一个普通的 `NSWindow`（标题 `设置`，可关闭，不可缩放；关掉后再打开复用同一个窗口），内容是 SwiftUI（`NSHostingController`），顶上三页（`TabView` 或分段控件），页名 `引擎`、`费用`、`副屏`。`show(page:)`：切到那一页，`NSApp.activate(ignoringOtherApps: true)`，`makeKeyAndOrderFront`。

界面照原型的 `mac-win`：

- **引擎**：
  - `引擎`：下拉框，只有一项 `oMLX`；下面一行灰字 `这一版只有 oMLX；以后接入的引擎会出现在这里`。
  - `接口地址`：输入框，初始是 `settings.address`。
  - `API key`：分段控件 `自动` / `手填`（`settings.keyMode`）。自动时下面一行灰字 `读 ~/.omlx/settings.json 里的 auth.api_key`；手填时显示一个密码输入框（`SecureField`），初始是 `settings.manualKey`。
  - 最下面一行灰字显示当前状态：`controller.issue.message ?? "已连接"`，随 `controller.onStatusChange` 刷新。
- **费用**：
  - 上面一行灰字 `美元 / 百万 token。自己查了 API 价格填；没填的模型不算进今日费用`。
  - 一张表，列 `模型`、`输入`、`缓存命中`、`输出`；行是 `priceRows(current: controller.modelIDs, known: settings.knownModels, prices: settings.prices)`。每行三个输入框，初始是已填单价的 `priceText`，没填是空的（占位文字 `—`）。`present` 为假的行模型名用灰色，行末有一个删除按钮（`forgetModel` 后刷新表）。
  - 一行的三个框按 `parsePrice` 的结果生效：`valid` → 写进 `settings.prices`；`empty` → 从 `settings.prices` 删掉这个模型；`invalid` → 不写，这一行下面红字 `三项都要填，填不小于 0 的数`。
- **副屏**：`屏幕名`：输入框，初始是 `settings.screenName`。

什么时候生效：分段控件、删除按钮改了马上写进 `settings` 并调 `controller.settingsChanged()`；输入框在按回车时、以及窗口关闭时（`NSWindowDelegate.windowWillClose`）写进 `settings` 并调一次 `controller.settingsChanged()`。地址、屏幕名去掉首尾空白后为空就不写。

表的数据、各输入框的文字放在一个 `@MainActor final class SettingsModel: ObservableObject` 里，SwiftUI 视图只读写它；`controller.onStatusChange` 触发时更新它的状态行和模型列表（`controller.onStatusChange` 只有一个，由 `StatusMenu` 设置；`StatusMenu` 在自己的回调里再转给设置窗口）。

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
```

最后一行是 `Build complete!`。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | grep -E '✘' | head; swift test 2>&1 | tail -1)
git status --short
```

通过的标准：

- 第一条前面没有输出，最后一行以 `✔ Test run with` 开头、以 `passed after` 加秒数结尾，比开始前多 8 个测试。
- `git status --short` 只列出本任务的文件：四个新建的（`??`）和三个改过的（` M`）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做；app 主体（`AppController`、`ScreenManager`、窗口）由别的任务同时在别处做。
