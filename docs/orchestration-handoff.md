# 交接：Mac 版副屏仪表盘

## 目标和依据

把副屏性能仪表盘从 DGX Spark（Python + GTK）搬到 Mac Studio：全 Swift 的 Mac 应用，在 MacBook Pro 上用 Swift 命令行工具构建；这一版只接 oMLX。

- 设计文档：`docs/design-mac.md`（已确认）；原型：`docs/dashboard-prototype.html`（已确认）。
- 接口约定：`docs/tasks/mac/00-contracts.md`（JSON 值类型、各模块签名、翻译规矩、测试翻译规矩）。
- 执行者约定：`AGENTS.md`（已改成 Mac 版）。
- 做法：`orchestrate-local-pi` skill；派工记录 `docs/orchestration-notes.md`。

## 已完成

| 任务 | 结果 |
| --- | --- |
| Swift 包基础（编排者直接写）：`JSON`、`Config`、`Fmt`、`Scale`、`View` + `TestSupport` | 21 个测试 |
| M1 采集 `Collector.swift`（含 `UsageSink` 协议） | 通过，48 个测试 |
| M2 今日用量 `Usage.swift`（`UsageLedger`） | 通过，25 个测试 |
| M3 视图模型 `ViewModel.swift` + 样例格式测试 | 通过，39 + 11 个测试 |
| M4 动画 `Animator.swift`（含 `Frame`） | 通过，34 个测试 |

当前状态：分支 `mac-v3`，`cd mac && swift test` 178 个测试全过。四个模块都是 Spark 版 Python 的原样翻译，行为没改：Mac 版要的新东西（oMLX、加载中、按模型计价、时区名、首字栏等）一项都还没做。

## 下一批（还没写说明）

1. **oMLX 读取和适配器**（`Sources.swift`、`Engine.swift`）：设计文档“引擎：oMLX”“适配器”两节。HTTP 用 `URLSession`、超时 0.5 秒；API key 从 `~/.omlx/settings.json` 读。需要先在本机 oMLX 上录一组 `fixtures/omlx/` 读数序列（录制节奏照程序实际轮询：忙时 0.1 秒、空闲 0.25 秒），适配器的测试拿它回放。适配器规则互相牵连（开始时刻、首字时间、断开带走的用量），按 skill 第 2 节先写参考实现、跑通，再派工。
2. **采集器加“模型加载中”状态**：统一读数带 `loading` 时进入新状态，快照和样例跟着加。
3. **今日用量按模型记账**：`usage_by_model`，设计文档“费用单价”一节；单价由菜单里按模型填，没填单价的模型的显示规则照原型（`&price=partial|none`）。
4. **视图模型的 Mac 版改动**：引擎名 oMLX、时区名（系统 / 北京 / 太平洋）、完成画面第三栏改成“首字”、未填单价时的写法。以原型为准逐条对照。
5. 再下一批：应用本身（绘制、窗口放到副屏、菜单栏、设置窗口三页、轮询、打包和登录时启动）。

2、3、4 都改已有模块，互相牵连少，可以并行；1 是新模块，可以和它们同时做（文件不重叠）。

## 需要知道的

- 两个 Python 测试文件里都有 `TestOffline`，Swift 里视图模型那份叫 `TestOfflineView`（套件名在整个测试目标里不能重复）。
- 视图模型里 Python 在费用 ≥ 100 时 `cost.index(".")` 会抛异常；Swift 版改成整串放进整数部分。做第 4 项时一并定下该怎么显示。
- 采集器里外挂失效、vLLM 估算进度的分支照样保留（设计文档“从 Spark 版搬什么”说明了原因）。
- 并行派工的方法：每个任务一个 `git worktree`（放在 `../tensorfold-panel-wt/<任务名>`，分支名小写），在里面放 `.orch` 符号链接指回主仓库的 `.orch`，用 `ORCH_ROOT=<worktree> start_pi.sh …` 启动；看板和 `wait.sh` 在主仓库根目录跑。验收后在 worktree 里提交，再合进 `mac-v3`，删掉 worktree 和分支。
- 环境：Swift 6.4 命令行工具（Xcode 没被选中，`xcodebuild` 用不了）；只有 swift-testing，没有 XCTest；`Package.swift` 里给测试目标加了 `-plugin-path`，不然测试宏找不到。
- 本机 oMLX 在跑（端口 8000）；原型预览服务在 18470 端口（`.claude/launch.json` 的 `prototype`）。
