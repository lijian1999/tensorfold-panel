# 交接：Mac 版副屏仪表盘

## 目标和依据

把副屏性能仪表盘从 DGX Spark（Python + GTK）搬到 Mac Studio：全 Swift 的 Mac 应用，在 MacBook Pro 上用 Swift 命令行工具构建；这一版只接 oMLX。

- 设计文档：`docs/design-mac.md`（已确认）；原型：`docs/dashboard-prototype.html`（已确认）。
- 接口约定：`docs/tasks/mac/00-contracts.md`（第 9 节是 app 层：绘制、轮询、设置、app 内部类型）。
- 执行者约定：`AGENTS.md`。
- 做法：`orchestrate-local-pi` skill；派工记录 `docs/orchestration-notes.md`。

## 已完成

| 任务 | 结果 |
| --- | --- |
| 第一批 M1–M4：采集、今日用量、视图模型、动画（Python 原样翻译）+ 基础类型 | 通过 |
| 第二批 O1 oMLX 适配器和读取器（`Sources.swift`、`Engine.swift`） | 通过；实机读本机 oMLX 正常 |
| 第二批 O2 今日用量按模型记账 | 通过 |
| 第二批 O3 视图模型的 Mac 版文案（首字卡、时区名、未填单价） | 通过 |
| 第三批 R1 绘制 `PanelRender/Renderer.swift` | 通过，和原型截图对照一致 |
| 第三批 A1 轮询 `Poller.swift`、设置 `AppSettings.swift`、内存 `Memory.swift` | 通过 |
| TFPanel 可执行目标 + 8 个占位文件 + 图标（编排者直接写） | 能编译 |

当前状态：分支 `mac-v3`，`cd mac && swift test` PanelCore 251 + PanelRender 14 全过。

## 正在做（第三批后半）

- A2 `docs/tasks/mac/A2-app-core.md`：入口、AppController、找副屏和切显示模式、PanelView、日志、Info.plist、`mac/scripts/build-app.sh`。worktree `../tensorfold-panel-wt/A2-app-core`。
- A3 `docs/tasks/mac/A3-menu-settings.md`：菜单栏、设置窗口三页、登录时启动，PanelCore 里的 `MenuText.swift`、`PriceForm.swift`。worktree `../tensorfold-panel-wt/A3-menu-settings`。

两个任务的文件不重叠，都按约定 9.5 节用对方的占位类型。

## 之后

1. A2、A3 验收合并后，用 `--window --no-mode-switch` 实测 app：画面和原型对照、本机 oMLX 的空闲 / 解码 / 完成、菜单和设置窗口三页、改单价和时区后立刻生效、打包、空闲和忙时 CPU。
2. 对照设计文档的验收项逐条做端到端检查，写完工报告。

## 需要知道的

- 套件名在整个测试目标里不能重复：视图模型那份叫 `TestOfflineView`；内存读数的套件叫 `TestSystemMemory`（视图模型里已有 `TestMemory`）。
- SwiftPM 每个测试目标打印一行 `Test run with N tests`，看总数用 `grep 'Test run with'`，不要只看 `tail -1`。
- 副屏 TYPE-C 现在接在这台 MBP 上（1920×1080）。app 默认会把它切到 960×640，实测时加 `--no-mode-switch`；“自动切显示模式”这一项留给用户在 Studio 上确认。
- 并行派工：每个任务一个 `git worktree`（`../tensorfold-panel-wt/<任务名>`，分支名小写），里面放 `.orch` 符号链接指回主仓库，用 `ORCH_ROOT=<worktree> start_pi.sh …` 启动；看板和 `wait.sh` 在主仓库根目录跑。验收后在 worktree 里提交，合进 `mac-v3`，删掉 worktree 和分支。
- 环境：Swift 6.4 命令行工具（没有 Xcode）；只有 swift-testing；`Package.swift` 给测试目标加了 `-plugin-path`。
- 本机 oMLX 在跑（端口 8000）；原型预览服务在 18470 端口（`.claude/launch.json` 的 `prototype`）。
