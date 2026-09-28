# TensorFold 副屏性能仪表盘 · 工作约定

你是执行者。任务说明由编排者（Claude）给出，完成后由编排者独立验收，所以：
- 严格按任务说明做，不要做说明之外的功能，不要改说明没提到的文件。
- 说明里写的接口、字段名、文件路径必须一字不差。
- 说明有歧义时，按 `docs/design.md` 和 `docs/dashboard-prototype.html` 判断；两者冲突以原型为准。
- 完成前必须亲自运行说明里列出的检查命令，全部通过才算完成。不能跳过测试、不能为了通过而删改测试断言。
- 最后一行只输出 `DONE` 或 `FAILED: <原因>`。

## 目录

- `docs/` 设计文档与原型（只读，除非任务明确要求修改）
- `collector/` 启动器 + 采集器 + `/metrics`（Python，单文件 `tfpanel.py`）
- `collector/tests/` 采集器测试（只用标准库 `unittest`，不装依赖）
- `display/` 副屏显示程序（SwiftPM 包，SwiftUI，macOS 14+）
- `scripts/` 构建、安装脚本

## 技术约束

- Python：只能用标准库；运行在 TensorFold 自己的 Python 3.12 环境：`~/.local/share/uv/tools/tensorfold/bin/python`。
- 绝不修改 TensorFold 安装目录 `~/.local/share/uv/tools/tensorfold/` 下的任何文件。
- Swift：只有 Command Line Tools（没有 Xcode）。用 `swift build` / `swift test`，测试用 swift-testing（`import Testing`），不用 XCTest。
- 不安装任何第三方依赖（pip / brew / SwiftPM 远程包都不行）。
- 不要启动、停止或重启 TensorFold 进程（8080 端口上的服务是你自己正在使用的模型）。
- 代码注释用中文，简洁；用户可见文字用中文。
