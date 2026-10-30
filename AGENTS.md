# 副屏性能仪表盘（Mac 版）· 工作约定

你是执行者。任务说明由编排者（Claude）给出，完成后由编排者独立验收，所以：
- 严格按任务说明做，不要做说明之外的功能，不要改说明没提到的文件。
- 说明里写的接口、字段名、文件路径必须一字不差。
- 说明有歧义时，先看接口约定 `docs/tasks/mac/00-contracts.md`，再看 `docs/design-mac.md` 和原型 `docs/dashboard-prototype.html`；文档和原型冲突以原型为准。翻译任务里，Python 代码（`panel/`）的行为就是规格。
- 完成前必须亲自运行说明里列出的检查命令，全部通过才算完成。不能跳过测试、不能为了通过而删改测试断言。
- 不要执行改动 git 状态的命令（`add`、`commit`、`reset`、`checkout`、`stash`、`merge` 等），版本由编排者管理；`git diff`、`git status`、`git log` 这类只读命令可以用。
- 最后一行只输出 `DONE` 或 `FAILED: <原因>`。

## 工作方式

- 任务说明里写了“第一步”“第二步”的，按顺序做，每一步做完就运行那一步给出的命令。
- 说明里有歧义或自相矛盾的地方：按最直接的理解做，继续往下，最后在结果里写明你是怎么理解的。
- 检查命令的输出里出现说明没提到的无害提示：不用处理，在结果里提一句即可。
- 一项检查试了两次仍然通不过、又判断不了是代码的问题还是说明的问题：停下来，最后一行写 `FAILED: <卡在哪里>`，由编排者处理。

## 结果报告

结束时的最后一条回复只写这几项，不要复述任务说明，不要贴代码：

- 改动的文件：每个一行。
- 检查命令：每条一行，写通过还是没通过；没通过的附上关键的报错行。
- 歧义的处理、说明里的漏洞或错误、没能照原样翻译的测试断言：逐条写；没有就写“无”。
- 最后一行：`DONE` 或 `FAILED: <原因>`。

## 环境

- 你运行在 MacBook Pro 上（Apple 芯片，macOS 26），代码仓库也在这里。程序最终运行在 Mac Studio 上。
- 开发工具是 Swift 6.4 命令行工具。在 `mac/` 目录下用 `swift build`、`swift test` 构建和测试；`swift test --filter <套件名>` 只跑一部分。第一次构建要一两分钟。
- 你自己是一台 DGX Spark 上跑的模型（vLLM，容器 `qwen38-flash-next`）。
- 本机装了 oMLX（本地推理引擎，端口 8000）。

## 目录

- `mac/` Mac 版（Swift 包）：`Sources/PanelCore/` 纯逻辑，`Sources/PanelRender/` 绘制，`Sources/TFPanel/` app，`Tests/PanelCoreTests/`、`Tests/PanelRenderTests/` 测试
- `panel/` Spark 版的 Python 实现，翻译时的参照（只读）
- `panel/tests/` Spark 版的测试，翻译时的参照（只读）
- `fixtures/` 各状态的指标快照样例（只读）
- `docs/` 设计文档、原型、任务说明（只读）
- `hook/`、`scripts/` Spark 版用的东西（只读，Mac 版用不到）

## 技术约束

- Swift 6，最低 macOS 14。`PanelCore` 只能 `import Foundation`；`PanelRender`、`TFPanel` 能用哪些系统框架见接口约定第 9 节。
- 测试只用 swift-testing（`import Testing`、`@Test`、`#expect`）。这台机器上没有 XCTest，不要用它。
- 不安装任何依赖，不加 Swift 包依赖：`pip`、`brew`、`npm`、SwiftPM 的远程包都不行。
- 不要改 `mac/Package.swift`。

## 绝对不能做的事

- 不要启动、停止或重启 oMLX，也不要向它（端口 8000）发推理请求。
- 不要登录 DGX Spark，不要动它上面的任何容器和文件。
- 不要修改系统设置（显示器、登录项等）。

## 风格

- 代码注释用中文，简洁；用户可见文字用中文。
