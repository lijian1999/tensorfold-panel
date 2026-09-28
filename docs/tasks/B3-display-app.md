# 任务 B3：副屏程序外壳（窗口、副屏、菜单栏、打包）

先读 `AGENTS.md`，再读 `docs/design.md` 的「显示程序行为」「已定事项」。B1（PanelCore）、B2（PanelScreenView / PanelAnimator / 截图）已完成，**不要改它们的行为**，现有测试和 `--snapshot-all` 必须继续正常。

## 交付

- `display/Sources/PanelCore/DisplayPolicy.swift`（纯逻辑，可测试）
- `display/Sources/TFPanel/` 下新增：`AppDelegate.swift`、`MetricsPoller.swift`、`ScreenManager.swift`、`DisplayMode.swift`、`StatusMenu.swift`、`Settings.swift`（文件名可微调，职责要清晰）
- `display/Sources/TFPanel/main.swift`：无参数（或只有下面的选项）时启动窗口程序；`--snapshot` / `--snapshot-all` 行为不变。
- `scripts/build-app.sh`：打包 `display/dist/TFPanel.app`。
- 测试：`display/Tests/PanelCoreTests/DisplayPolicyTests.swift`。

## 1. 命令行选项（启动窗口程序时）

- `--metrics-url <url>`：覆盖指标地址（默认 `http://127.0.0.1:8081/metrics`；也可用环境变量 `TFPANEL_METRICS_URL`）。
- `--screen <名字>`：覆盖副屏名（默认取设置里的值，初始 `TYPE-C`）。

## 2. 设置（Settings.swift）

`UserDefaults(suiteName: "com.tensorfold.panel")`：`screenName`（默认 `"TYPE-C"`）、`autoSwitchMode`（默认 `true`）。命令行选项只影响本次运行，不写回设置。

## 3. 程序形态（AppDelegate）

- `NSApplication.shared.setActivationPolicy(.accessory)`：不占 Dock、不出现在 ⌘Tab。
- 启动时不在主屏弹出任何窗口；找不到副屏就安静等待。

## 4. 拉取指标（MetricsPoller）

- 每 0.1 s 一次 GET 指标地址；`URLSession(configuration: .ephemeral)`，请求超时 0.25 s，不缓存。上一次请求还没返回就跳过本次。
- HTTP 200 且 JSON 能解析成 `Metrics` → `tracker.recordSuccess`；其他一切情况（连接失败、超时、非 200、解析失败）→ `tracker.recordFailure`。时间用 `ProcessInfo.processInfo.systemUptime`。
- 内存每 1 s 用 `SystemMemory.read()` 读一次。
- 全部状态在主线程（`@MainActor`）更新。

## 5. 副屏与窗口（ScreenManager）

- 按 `NSScreen.localizedName == screenName` 找副屏。监听 `NSApplication.didChangeScreenParametersNotification`：副屏出现 → 建窗口；副屏消失 → 关窗口；副屏尺寸变化 → 重新铺满。**任何情况下都不在其他屏幕上显示窗口。**
- 窗口：`NSWindow` 子类，`styleMask = [.borderless]`，重写 `canBecomeKey`、`canBecomeMain` 返回 `false`；`ignoresMouseEvents = true`；`level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)`（盖住副屏上的菜单栏）；`collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`；`isOpaque = true`、`backgroundColor = .black`、`hasShadow = false`；`isReleasedWhenClosed = false`；frame = **`screen.frame`**（整块屏，包括菜单栏区域）。用 `orderFrontRegardless()` 显示，不激活程序。
- 内容：`NSHostingView`，根视图用 `TimelineView(.animation(minimumInterval: 1.0/30, paused: 已静止))` 每帧调用 `animator.tick` 并画 `PanelScreenView`。“已静止”= 没有缓动、没有脉冲、没有彗星、没有淡入在进行；静止时指标或内存变化仍要触发重绘（例如离线秒数每秒变化）。目标：空闲时 CPU < 1%。
- 缩放与留边：`DisplayPolicy.fit(screenSize:) -> (scale, origin)`：`scale = min(w/480, h/320)`，画面居中，其余区域黑色。

## 6. 调暗

`DisplayPolicy.dimmed(state:, stateSince:, now:) -> Bool`：状态为 `idle` 或 `offline` 持续超过 30 分钟 → 调暗；其他状态立即恢复。调暗时整块画面不透明度 0.4（过渡 1 s），恢复时 0.3 s。ScreenManager 自己记录“当前状态从何时开始”。

## 7. 自动切换显示模式（DisplayMode.swift）

- 副屏出现时（包括程序启动时就已连接），若设置 `autoSwitchMode` 为 true：
  - 从 `NSScreen.deviceDescription["NSScreenNumber"]` 取 `CGDirectDisplayID`；
  - 读当前模式；若已是 `width 960, height 640, pixelWidth 960, pixelHeight 640` 就什么都不做；
  - 否则用 `CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true])` 列出模式，交给 `DisplayPolicy.pickMode` 选；选到就 `CGBeginDisplayConfiguration` → `CGConfigureDisplayWithDisplayMode` → `CGCompleteDisplayConfiguration(.permanently)`；选不到或失败只打印日志。
- `DisplayPolicy.pickMode(_ modes: [ModeInfo]) -> Int?`（`ModeInfo { width, height, pixelWidth, pixelHeight, refreshRate }`，返回下标）：只选 `960×640` 且像素也是 `960×640` 的；多个时选刷新率最高的；没有返回 nil。

## 8. 菜单栏（StatusMenu）

`NSStatusItem`（SF Symbol `gauge.with.dots.needle.67percent`，找不到就用文字 `TF`），菜单：
1. `TensorFold 副屏`（禁用，作标题）
2. 副屏状态（禁用）：`副屏：已连接 TYPE-C` / `副屏：未找到 TYPE-C`（菜单打开时刷新）
3. 分隔线
4. `自动切换到 960 × 640`（勾选项，读写 `autoSwitchMode`；打开时立即对已连接的副屏执行一次）
5. `登录时启动`（勾选项，用 `SMAppService.mainApp` 注册/注销；不是从 .app 包运行时该项禁用）
6. 分隔线
7. `退出`（⌘Q）

## 9. 打包（scripts/build-app.sh）

```
cd display && swift build -c release
生成 display/dist/TFPanel.app/Contents/{MacOS/TFPanel, Info.plist}
Info.plist：CFBundleIdentifier com.tensorfold.panel、CFBundleName TFPanel、CFBundleDisplayName TensorFold 副屏、
            CFBundleExecutable TFPanel、CFBundlePackageType APPL、CFBundleShortVersionString 1.0、CFBundleVersion 1、
            LSMinimumSystemVersion 14.0、LSUIElement true
codesign --force --sign - display/dist/TFPanel.app   # ad-hoc 签名
```
脚本 `set -euo pipefail`，可重复运行（先删旧的 dist/TFPanel.app）。

## 10. 测试（DisplayPolicyTests）至少覆盖

- `pickMode`：没有匹配 → nil；有 960×640 但像素 1920×1280 的（HiDPI）不选；多个匹配时选刷新率最高。
- `fit`：960×640 → scale 2、origin (0,0)；1920×1080 → scale 3.375、水平居中；480×320 → scale 1。
- `dimmed`：idle 29 分钟不暗、31 分钟暗；offline 31 分钟暗；decode 永不暗。

## 完成前必须运行并全部通过

```sh
cd display && swift build && swift test
cd display && .build/debug/TFPanel --snapshot-all /tmp/tfpanel-shots && ls /tmp/tfpanel-shots
sh scripts/build-app.sh && plutil -lint display/dist/TFPanel.app/Contents/Info.plist && codesign -v display/dist/TFPanel.app
```
**不要**启动窗口程序本身（它会接管副屏），真机验证由编排者来做。
