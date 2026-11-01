# 交接：Mac 版副屏仪表盘

## 进行中（2026-11-01）：分支 `mac-60fps`，方案②：60fps 静态/动态分层渲染

目标：持续动画帧率默认 10 → 60，但不增加 CPU/解码拖慢。用户已确认方案②并授权自行决策；设计文档、接口约定已改好（见下），**代码还没动**。

### 已完成（已在 `mac-60fps` 分支提交）

- `docs/design-mac.md` 三处：整体架构 App 条目补两层画法；“defaults write”清单里动画帧率（10）→（60，可设 1–60）；已定事项加一条（2026-11-01，含“预期稳定解码 CPU 与 10 帧持平，约 5% 单核，实现后实测核对”）。
- `docs/tasks/mac/00-contracts.md`：Config 行加例外说明——`animFps` mac 版默认 60（可设 1–60），Python 版仍是 10。
- 原型不用改：动画本来就是 requestAnimationFrame（原生约 60fps），原型已经是 60fps 的效果。
- 实测依据：稳定解码 2 倍屏 10fps 全帧画 = 5.5% 单核（提交 b8d2054）；临时基准测纯光栅 0.634 ms/帧（临时文件已删）。稳定解码时每帧真变的只有：流指示点脉冲、数值弧、进度条、主数字（文字本身节流 4Hz）。

### 待做：代码实现计划

1. `mac/Sources/PanelRender/Renderer.swift`：把 `draw` 拆成 `drawStatic` + `drawDynamic`。静态 = 背景、状态条文字、底环和缺口、离线文字/标题行、刻度数字、右侧三栏；动态 = 流指示点、灰点、数值弧、主数字、进度条整块、调暗遮罩。`draw()` 本身重构成先静态后动态的同一批元素函数，行为不变（RenderTests 逐像素断言会抓回归）。正确性条件：各路不透明度和 dim 全为 1（稳定画面）时，两趟先后画与 `draw()` 逐像素一致；组不透明度 <1（淡入中）时 _block 的透明图层语义会改变合成顺序，所以淡入期间必须整帧画。注意交叉叠序已逐一核实：圆点与状态条文字、弧与刻度数字/标题、弧与卡片互不重叠；弧→主数字的先后关系保持。
2. `mac/Sources/TFPanel/PanelView.swift`：单层改双层（容器层下加静态层 + 动态层，各带 delegate）。每拍只 step 一次动画（帧存起来给两层共用，不能各画各的 step）。稳定帧（各 α 与 dim ≥0.999）时静态层 drawStatic、动态层 drawDynamic，重画定时器只驱动动态层；非稳定帧静态层画整帧 draw()、动态层清空。静态层重画时机：换画面数据、缩放变、模式切换。`frameIntervalMs` 钳制 1–30 → 1–60（下限 33ms → 16ms；淡入仍固定 33ms）。
3. `mac/Sources/PanelCore/Config.swift`：`animFps` 默认 10.0 → 60.0（AppSettings 读同名键，无需改）。
4. 测试：新增套件（RenderTests 风格）——(a) 每个稳定样例：drawStatic+drawDynamic 与 draw() 逐像素一致（容差 0–1）；(b) 同一 view、两个不同 frame 的 drawStatic 输出逐像素一致（证明静态层可缓存）；(c) 已有测试全不动。若有断言 Config 默认 10 的测试一并改 60。
5. 完成检查：`cd mac && swift build && swift test`；再用临时基准测 drawStatic / drawDynamic+清屏耗时，推算 60fps CPU 写进交接文件；真机实测（活动监视器 + 实解码）留给用户/Studio。
6. 实测 CPU 的办法：`mac/dist/TFPanel.app/Contents/MacOS/TFPanel --no-mode-switch` 跑真实解码，活动监视器看 TFPanel CPU；超标就把 `anim_fps` 降（defaults 域 `com.tensorfold.panel`）或把动态层范围收窄，再不行退 30fps。

## 完工报告（2026-10-30）

目标：按设计文档 `docs/design-mac.md` 和原型 `docs/dashboard-prototype.html` 完整实现 Mac 版（全 Swift、一个进程、只接 oMLX），沿用派工方式（pi 执行、编排者验收）。代码在分支 `mac-v3`，`cd mac && swift test`：PanelCore 269 个 + PanelRender 15 个测试全过；`mac/scripts/build-app.sh` 出 `mac/dist/TFPanel.app`。

### 设计要求逐条

| 要求 | 状态 | 依据 |
| --- | --- | --- |
| 全 Swift、一个进程、菜单栏 app | 做到 | `mac/` 三个目标 PanelCore / PanelRender / TFPanel；Info.plist `LSUIElement`、`.accessory`；实测第二次启动日志“已有 TFPanel 在运行，本次退出” |
| 采集、今日用量、视图模型、动画照 Spark 版行为 | 做到 | M1–M4 逐条翻译 Python 测试（第一批 178 个测试）；之后一直全过 |
| 只接 oMLX，设置里选引擎 | 做到 | O1 适配器 + 读取器；9 段实录序列（`fixtures/omlx/`：短请求、3 万长提示、带缓存、4 并发、10 排队、解码中断开、预填充中断开、加载、混合）回放测试；设置窗口“引擎”页 |
| 按模型记账、单价按模型填、无默认价 | 做到 | O2；设置窗口“费用”页（A3）；实测：没填 → 主数字 `—` + “未填单价 · 在菜单栏里填”；填 Qwen3-4B → `$5.30`，和手算 9×0.1+11×0.4 一致；“不含 N 个模型”由 `ViewModelTests` 覆盖（只有一个能对话的模型，实机凑不出两个） |
| 时区：系统 / 北京 / 太平洋 | 做到 | 菜单子菜单（A3）；实测切太平洋显示“10月29日 · 太平洋时间”，切回北京按换日处理（设计第 280 行） |
| 完成画面第三张卡是首字 | 做到 | O3；实测短请求首字 0.13 s（oMLX 自报 0.07 s，误差在一次轮询内），3.8 万 token 长提示首字 31.33 s |
| 画面和原型一致 | 做到 | R1 和原型截图逐张对照；实机空闲 / 预填充 / 解码 / 完成 / 本轮 / 离线 / 需要 key 截图都对 |
| 验收 1：`swift test` 全过，测试数对得上 | 做到 | 269 + 15 全过；翻译任务的测试和 Python 1:1（见派工记录 M1–M4 行） |
| 验收 2：一条命令打包，只有菜单栏图标，不开第二个 | 做到 | build-app.sh 出包、codesign 检查通过；拷进 `/Applications` 用 `open` 启动（和双击同一条路），`lsappinfo` 报 `UIElement`（无 Dock 图标），再 `open` 一次仍只有 1 个进程；直接再跑一次二进制，日志“已有 TFPanel 在运行，本次退出”。测试时关了自动切显示模式，测完删掉拷贝、还原设置 |
| 验收 3：接上副屏自动切 960×640、铺满、不抢焦点 | 铺满、不吃点击、选模式做到；真正切过去和拔插只能在 Studio 上做 | 临时自测钩子在 app 里对实机副屏只读跑了一遍选模式：TYPE-C 当前 960×540（像素 1920×1080），38 个模式里 `pickMode` 选中 960×640、像素 960×640、60 Hz；主屏 CS40X 没有这个模式，选 nil（不会误切主屏）。没有调用切换（用户要求这台 MBP 不切副屏模式，`AGENTS.md` 也禁止改显示器设置）。窗口 `canBecomeKey/Main = false`、`ignoresMouseEvents`；画面按图层实际像素渲染核对过铺满和居中 |
| 验收 4：七种情况和原型一致、数字对得上 | 做到 | 实录序列回放（上面 9 段）+ 实机短请求、长提示、本轮；速度 97.4 对 oMLX 100.5 |
| 验收 5：加载中画面；离线 3 次、重开自动连上 | 做到 | `CollectorTests` 加载状态；`OmlxReaderTests.test_连续3次读不到后重新认引擎`；实机：app 经本地转发端口 18471 连 oMLX，关掉转发 → 日志“引擎：未连接”，重开 → 4 秒内“引擎：已连接”（不能关 oMLX 本身，用转发模拟）；地址写错 → “引擎离线”画面 |
| 验收 6：三个时区、跨 0 点清零 | 做到 | 见上；跨 0 点由 M2 的换日测试覆盖 |
| 验收 7：费用单价 | 做到 | 见上 |
| 验收 8：改 key、改地址立刻生效 | 做到 | 设置窗口实机操作（临时自测钩子，测完删掉）：点菜单栏菜单真实的“设置…”项打开窗口，在“接口地址”框里选中、打字、回车，和用户操作走同一条路（字段编辑器 → SwiftUI `onSubmit`）。改成 `127.0.0.1:18999` → 1 秒内日志“引擎：未连接”，窗口状态行“未连接”；改回 `127.0.0.1:8000` → 立刻“已连接”；点分段控件“手填” → 出现密码框，立刻“oMLX 需要 API key”；密码框输入错 key 回车 → 仍是需要 key，设置里存下了这个 key；点“自动” → 立刻“已连接”；关窗 → 各框写回设置。窗口截图核对过状态行文字 |
| 验收 9：登录时启动 | 实现做到；真正登记和注销重登只能由用户做 | 实现见 `LoginItem.swift`（SMAppService.mainApp）。从 .app 包运行时只读查过：`available = true`，状态 `notFound`（包不在 `/Applications`，没登记过）。没有调用 `register()`：登记登录项属于 `AGENTS.md` 和安全规则禁止的“改系统设置（登录项）”，验证还要注销再登录 |
| 验收 10：CPU 空闲 < 1%、解码 < 5% | 做到（Studio 上用活动监视器再看一次） | 空闲 0.5%；稳定解码在这台 MBP 的 2 倍屏（1920×1080 像素）5.5%，按 1 倍画（960×540，接近 Studio 的 960×640）3.4% |

### 分工

派给本地模型（pi，全部 low 档）的 11 个任务：

- 第一批 M1 采集、M2 今日用量、M3 视图模型、M4 动画：通过。
- 第二批 O1 oMLX 适配器和读取器、O2 按模型记账、O3 Mac 版画面文字：通过。
- 第三批 R1 绘制、A1 轮询 / 设置 / 内存、A2 app 主体、A3 菜单栏和设置窗口：通过（A1 报 FAILED，是说明里的套件名和已有的重名，编排者改名后全过）。

编排者直接做的：接口约定和全部任务说明、oMLX 参考实现和实录回放数据、每批开工前的公共底座（Swift 包、PanelRender / TFPanel 目标、占位文件、图标），以及实机调出来的几处修正（套件改名、删临时 Log、状态条长模型名截短、绘制测试卡死、首字恒为 0、短回答速度偏高、CPU 占用）。这些修正按 `orchestrate-local-pi` skill 第 1 节自己改：定位之后改动已经确定，任务说明写出来基本就是 diff，或者比改动本身还长，派工反而更费 token。难的是定位（`sample`、对照程序、实机对照 oMLX 自报的数字），这一步本来就得编排者自己做。每处都在派工记录里记了一行。

### 没做的、留给用户的

1. **只能由用户 / 在 Studio 上做的验收**：副屏真正切到 960×640 和拔插（验收 3，选模式已在实机上只读验证）、登录项真正登记并注销重登（验收 9），以及按设计“Studio 到了再在 Studio 上重复一遍”的整套验收（含活动监视器看 CPU）。原因：用户要求这台 MBP 的副屏不切显示模式，`AGENTS.md` 和安全规则禁止改显示器、登录项这类系统设置，拔插和注销重登要有人动手，Studio 不在手边。
2. **删 Spark 版代码**：已定的做法是 Studio 上验收通过后单独一个提交删，所以现在不删。
3. 这台机器上留有测试时产生的今日用量（`~/Library/Application Support/TFPanel/`），设置已经还原（只剩 app 自己记的 `known_models`）。

## 目标和依据

- 设计文档：`docs/design-mac.md`；原型：`docs/dashboard-prototype.html`。
- 接口约定：`docs/tasks/mac/00-contracts.md`；执行者约定：`AGENTS.md`；派工记录：`docs/orchestration-notes.md`。
- oMLX 参考实现和回放：`docs/tasks/mac/ref/`（`python3 docs/tasks/mac/ref/test_omlx_adapter.py`、`replay.py --write` 生成 `fixtures/omlx/*.expected.jsonl`），和 Swift 版行为一致。

## 需要知道的

- 实测 app：`mac/dist/TFPanel.app/Contents/MacOS/TFPanel --no-mode-switch`（不要 `open`，会切副屏的显示模式）；`--capture <目录>` 后 `kill -USR1 <pid>` 存一张当前画面；`--window` 在主屏开预览窗口。
- 设置在 `defaults` 域 `com.tensorfold.panel`；单价是 JSON Data，每个模型三项 `input`、`cached`、`output` 都要有，少一项整张表读不出来。
- 这台机器上 bash 进程没有录屏权限，`screencapture` 只得到黑图；看画面用 `--capture`。
- 读 oMLX 走 `SocketTransport`（http 地址），https 才用 URLSession；画面由 `PanelView` 自管的 CALayer 直接画，别改回 `NSView.draw`（解码时 CPU 高好几倍）。
- 套件名在整个测试目标里不能重复；`swift test` 每个测试目标各打一行 `Test run with N tests`。
- 没有 `timeout` 命令；本机 oMLX 在 8000 端口，原型预览服务在 18470。
