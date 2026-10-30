# 任务 A2：app 主体（窗口、绘制循环、副屏、打包）

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（第 9 节），再读设计文档 `docs/design-mac.md` 的“整体架构”“打包、安装、登录时启动”两节。本任务只改这些文件（`mac/Sources/TFPanel/` 下的五个是占位的空壳，改成真的实现；其余新建）：

- `mac/Sources/TFPanel/main.swift`
- `mac/Sources/TFPanel/AppController.swift`
- `mac/Sources/TFPanel/ScreenManager.swift`
- `mac/Sources/TFPanel/PanelView.swift`
- `mac/Sources/TFPanel/Log.swift`
- `mac/Sources/TFPanel/DisplayMode.swift`（新建）
- `mac/Resources/Info.plist`（新建）
- `mac/scripts/build-app.sh`（新建）

不要改别的文件。`StatusMenu.swift`、`SettingsWindow.swift`、`LoginItem.swift` 是别的任务的，这里保持占位的样子，只按接口约定 9.5 节调用它们。

**不要启动窗口程序**（不带参数运行 `TFPanel`、打开 `TFPanel.app`）：它会在副屏上铺满窗口、切换显示模式。本任务只用下面写的命令行截图模式检查，窗口程序由编排者实测。

## 背景

PanelCore 里已经有了全部逻辑：`OmlxReader` 读 oMLX，`Poller` 在后台线程一拍一拍地读、喂给 `Collector` 得到快照，`UsageLedger` 记今日用量，`ViewModel` 把快照变成 `View`，`Animator` 每帧算出 `Frame`，`PanelRender` 的 `Renderer` 把 `View` + `Frame` 画出来，`AppSettings` 管设置。本任务把它们接成一个菜单栏 app：找到名叫 `TYPE-C` 的副屏，在上面铺满一个不抢焦点、不吃点击的窗口，按动画需要重画。

第 1 版有一套能用的外壳，在 git 提交 `6c9ad9a` 的 `display/Sources/TFPanel/` 下，用 `git show 6c9ad9a:display/Sources/TFPanel/<文件>` 看（只读，不要 checkout）。`ScreenManager.swift`（`PanelWindow`、找屏、建窗口、铺满）、`DisplayMode.swift`（切显示模式）、`main.swift`（命令行参数）、`AppDelegate.swift` 可以照着改；`DisplayPolicy` 在 `git show 6c9ad9a:display/Sources/PanelCore/DisplayPolicy.swift`。它们画画面用的 SwiftUI、`PanelStore`、`MetricsPoller` 这一版都不要了。

## 第一步：`Log.swift`

- `enum Log`：`static func start()`、`static func write(_ message: String)`。
- 日志文件 `~/Library/Logs/TFPanel.log`。`start()`：文件超过 1,000,000 字节就清空；写一行 `TFPanel 启动`。
- `write`：追加一行 `yyyy-MM-dd HH:mm:ss <message>`（本地时间），同时写到标准错误。加锁（`NSLock`），任何线程都能调；写失败不抛、不崩。

## 第二步：`DisplayMode.swift`

照第 1 版的 `DisplayMode.switchIfNeeded` 和 `DisplayPolicy.pickMode`、`DisplayPolicy.target` 写，放在这一个文件里（不放进 PanelCore）。改动：

- `switchIfNeeded(screen:)` 返回 `enum SwitchResult { case already, switched, noMode, failed }`。
- 原来的 `print` 改成 `Log.write`。

## 第三步：`PanelView.swift`

`final class PanelView: NSView`：

- `override var isFlipped: Bool { true }`、`override var isOpaque: Bool { true }`。
- 持有 `let renderer = Renderer()`、`let animator = Animator()`，和一个取当前 `View` 的闭包 `let currentView: () -> View?`（由 `AppController` 给）。
- `draw(_:)`：`NSGraphicsContext.current?.cgContext` 拿不到就返回。整块涂黑；`currentView()` 是 nil 就到此为止（停掉重画定时器）。否则 `frame = animator.step(view, now: monotonicNow())`；画面按 480×320 等比缩放居中：`s = min(bounds.width / 480, bounds.height / 320)`，左上角 `((bounds.width - 480 * s) / 2, (bounds.height - 320 * s) / 2)`；`saveGState` → 平移到左上角 → `renderer.draw(ctx, view: view, frame: frame, width: 480 * s, height: 320 * s)` → `restoreGState`。
- 重画定时器照 `panel/app.py` 的 `draw`、`frame_interval_ms`、`ensure_timer`、`stop_timer`：`frame.animating` 时保证有一个定时器在跑，否则停掉。间隔：`min(frame.centerAlpha, frame.statsAlpha, frame.stripAlpha) < 1` 时 33 毫秒；否则按 `animFps`（由 `AppController` 给，限制在 1～30），`max(33, Int((1000 / fps).rounded()))` 毫秒。间隔和正在跑的不一样就先停旧的再起新的。定时器每次触发 `needsDisplay = true`。定时器用 `Timer(timeInterval:repeats:block:)` 加到 `RunLoop.main` 的 `.common` 模式（菜单打开时也不停）。
- `func viewChanged()`：画面内容变了时由 `AppController` 调；定时器没在跑时 `needsDisplay = true`（在跑时下一帧会用上新画面）。
- `func stop()`：停掉定时器（窗口关掉时调）。

## 第四步：`ScreenManager.swift`

照第 1 版的 `ScreenManager` 和 `PanelWindow` 写，接口照接口约定 9.5 节，另外：

- `init(settings: AppSettings, makeView: @escaping () -> PanelView, noModeSwitch: Bool)`：`makeView` 每次建窗口时调一次，得到这个窗口的内容视图。
- `var screenName: String`：从 `settings.screenName` 来；`func settingsChanged()`：屏幕名或自动切换的设置变了就重新找屏（`rescan`）。
- `func start()`、`func stop()`、`func redraw()`（对现有的每个 `PanelView` 调 `viewChanged()`）。
- 找屏：`NSScreen.screens.first { $0.localizedName == screenName }`。找到新屏时：`settings.autoSwitchMode` 为真且 `noModeSwitch` 为假才调 `DisplayMode.switchIfNeeded`；结果是 `noMode` 或 `failed` 时 `modeNote = "切不到 960 × 640，请在“显示器”设置里手动选"`，其他结果 `modeNote = nil`。然后建窗口（窗口属性照第 1 版：无边框、不能成为 key/main、`ignoresMouseEvents`、层级 `mainMenuWindow + 2`、`collectionBehavior`、铺满整块屏）。屏不见了：关窗口（先对它的 `PanelView` 调 `stop()`）。屏幕参数变化的通知照第 1 版。状态变了就调 `onChange`（`var onChange: (() -> Void)?`）。每次找到、丢失副屏时 `Log.write` 一行。
- `statusText`：找到时 `"<屏幕名> · <宽> × <高>"`，宽高是 `screen.frame` 的整数点数；没找到 `"未找到 <屏幕名>"`。
- `applyAutoSwitch()`：已连接且 `noModeSwitch` 为假时调一次 `switchIfNeeded`，按上面的规则更新 `modeNote`。
- `func showPreview()`：在主屏上开一个普通的带标题栏的窗口（标题 `TFPanel 预览`，内容 960×640，可以关），内容是 `makeView()`。给命令行 `--window` 用。
- 第 1 版的 `refreshDim`、`dimmed`、调试截图不要了（调暗由 `ViewModel` 和 `Renderer` 处理）。

## 第五步：`AppController.swift`

接口照接口约定 9.5 节。

- `init(noModeSwitch: Bool)`：
  - 设置用的 `UserDefaults`：`Bundle.main.bundleIdentifier == "com.tensorfold.panel"` 时用 `.standard`，否则用 `UserDefaults(suiteName: "com.tensorfold.panel")!`（两者读写的是同一份设置）。`settings = AppSettings(defaults: 它)`。
  - `config = settings.config()`；`ledger = UsageLedger(config: config)`；`collector = Collector(config: config, usage: ledger)`；`viewModel = ViewModel(config: config)`。
  - `reader = OmlxReader(transport: URLSessionTransport(baseURL: settings.address), apiKey: settings.apiKey(), maxStreams: omlxMaxStreams())`；`poller = Poller(source: reader, collector: collector)`。记下当前的地址和 key。
  - `screens = ScreenManager(settings: settings, makeView: { PanelView(…) }, noModeSwitch: noModeSwitch)`，`PanelView` 的 `currentView` 返回 `self.view`（当前的 `View?`），`animFps` 取 `config.animFps`。`screens.onChange` 调 `onStatusChange`。
- `func start()`：`screens.start()`；启动轮询（写法见下）。
- `func stop()`：`poller.stop()`，然后 `ledger.flush()`，`screens.stop()`。
- 把快照交给主线程（这段在后台线程上跑，只在这里碰读取器；下面的写法照用）：

```swift
poller.start { [poller, weak self] snapshot in
    let source = poller.source
    let issue = source.issue, ids = source.modelIDs, model = source.modelName
    DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.deliver(snapshot, issue: issue, modelIDs: ids, model: model) }
    }
}
```

- `deliver`（主线程）：
  - `issue`、`modelIDs`、`currentModel` 有任何一个变了就更新并调 `onStatusChange`；`issue` 变了时 `Log.write("引擎：<issue.message ?? "已连接">")`；`modelIDs` 变了时 `settings.rememberModels(modelIDs)`。
  - `let v = viewModel.update(snapshot, now: monotonicNow())`；和当前的 `view` 不同就换上，调 `screens.redraw()`。
  - API key 自动模式下（`settings.keyMode == .auto`）且 `issue == .needsKey`：距上次检查满 5 秒就重读一次 `settings.apiKey()`，和当前的 key 不同就按下面换 key 的方式生效。
- `settingsChanged()`：
  - `config = settings.config()`；`viewModel.config = config`；各 `PanelView` 的帧率跟着 `config.animFps`。
  - `poller.perform { ledger.apply(config: config) }`。
  - 地址变了：新建一个 `OmlxReader`（同上），`poller.perform { poller.source = 新的 }`，记下新地址和 key。
  - 地址没变、key 变了：`poller.perform { if let r = poller.source as? OmlxReader { r.apiKey = key; r.reset() } }`，记下新 key。
  - `screens.settingsChanged()`；最后调 `onStatusChange`。

## 第六步：`main.swift`

照第 1 版的 `main.swift` 写命令行，参数换成这几个：

| 参数 | 作用 |
| --- | --- |
| （没有参数） | 启动菜单栏 app |
| `--window` | 启动 app，另外在主屏上开一个预览窗口（`screens.showPreview()`） |
| `--no-mode-switch` | 启动 app，这次运行不切副屏的显示模式 |
| `--capture <目录>` | 启动 app；收到 `SIGUSR1` 时把当前画面画成 PNG 写到 `<目录>/capture-<序号>.png`（序号从 1 开始），`Log.write` 写出路径 |
| `--snapshot <样例.json> <out.png>` | 不启动 app：读样例，`ViewModel(config: Config()).update(样例, now: 0)`，`Renderer().renderPNG(view:path:)`，成功退出码 0，失败打印原因、退出码 1 |
| `--snapshot-all <样例目录> <输出目录>` | 不启动 app：样例目录下（不含子目录）每个 `.json` 各画一张 `<输出目录>/<名字>.png`，目录不存在就建 |

前三个可以一起用。认不出的参数：打印用法，退出码 1。

- `--capture` 的截图：在主线程上用 `Renderer().makeImage(view:frame:)`，`frame` 用 `Animator.settled(view)`，`view` 是 `AppController` 当前的 `View`（没有就不写，`Log.write` 一行说明）；信号处理照第 1 版 `AppDelegate.registerCaptureSignal` 的写法（`signal(SIGUSR1, SIG_IGN)` + `DispatchSource.makeSignalSource`）。写 PNG 用 `CGImageDestination`。
- 只开一个：`Bundle.main.bundleIdentifier` 不是 nil 时，`NSRunningApplication.runningApplications(withBundleIdentifier:)` 里有别的进程（`processIdentifier` 不是自己），就 `Log.write` 一行后退出。
- 启动 app：`Log.start()`；`NSApplication.shared`，`setActivationPolicy(.accessory)`；建一个 `NSApplicationDelegate`（写在 `main.swift` 里）：`applicationDidFinishLaunching` 里建 `AppController`、调 `start()`、建 `StatusMenu(controller:)` 并持有它，按参数开预览窗口、注册截图信号；`applicationWillTerminate` 里调 `controller.stop()`。

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
(cd mac && swift run TFPanel --snapshot ../fixtures/decode.json .build/snap-decode.png; echo "exit $?"; sips -g pixelWidth -g pixelHeight .build/snap-decode.png | tail -2)
(cd mac && swift run TFPanel --snapshot-all ../fixtures .build/snap-all; echo "exit $?"; ls .build/snap-all | wc -l; ls ../fixtures/*.json | wc -l)
(cd mac && swift run TFPanel --bogus; echo "exit $?")
```

通过的标准：第一条最后一行是 `Build complete!`；第二条有 `exit 0`、`pixelWidth: 960`、`pixelHeight: 640`；第三条 `exit 0`，后两行数字相同；第四条打印用法、`exit 1`。

## 第七步：打包

`mac/Resources/Info.plist`：`CFBundleIdentifier` = `com.tensorfold.panel`，`CFBundleName` = `TFPanel`，`CFBundleDisplayName` = `TFPanel`，`CFBundleExecutable` = `TFPanel`，`CFBundleIconFile` = `AppIcon`，`CFBundlePackageType` = `APPL`，`CFBundleShortVersionString` = `3.0`，`CFBundleVersion` = `3`，`LSMinimumSystemVersion` = `14.0`，`LSUIElement` = true，`NSHighResolutionCapable` = true。

`mac/scripts/build-app.sh`（`#!/bin/bash`，`set -euo pipefail`，可以在任何目录下运行）：

1. 切到 `mac/`（脚本所在目录的上一级），`swift build -c release --product TFPanel`。
2. 删掉旧的 `dist/TFPanel.app`，建 `dist/TFPanel.app/Contents/MacOS`、`Contents/Resources`。
3. 拷 `.build/release/TFPanel` → `Contents/MacOS/TFPanel`；`Resources/Info.plist` → `Contents/Info.plist`；`Resources/AppIcon.icns` → `Contents/Resources/AppIcon.icns`（图标文件已经在仓库里）。
4. `codesign --force --sign - dist/TFPanel.app`（ad-hoc 签名）。
5. 最后打印 `已生成 <dist/TFPanel.app 的绝对路径>`。

给脚本加执行权限。

```sh
mac/scripts/build-app.sh 2>&1 | tail -1
plutil -lint mac/dist/TFPanel.app/Contents/Info.plist
codesign -v mac/dist/TFPanel.app && echo signed
ls mac/dist/TFPanel.app/Contents/MacOS mac/dist/TFPanel.app/Contents/Resources
```

通过的标准：第一条以 `已生成` 开头；第二条以 `OK` 结尾；第三条输出 `signed`；第四条列出 `TFPanel` 和 `AppIcon.icns`。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | tail -1)
git status --short
```

通过的标准：

- 第一条以 `✔ Test run with` 开头、以 `passed after` 加秒数结尾（本任务不加测试，个数和开始时一样）。
- `git status --short` 只列出本任务的文件：`mac/Sources/TFPanel/` 下的五个改过的（` M`）和 `DisplayMode.swift`、`mac/Resources/Info.plist`、`mac/scripts/`（`??`）。`mac/dist/` 不应出现（已在 `.gitignore` 里）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做；菜单栏和设置窗口由别的任务同时在别处做。
