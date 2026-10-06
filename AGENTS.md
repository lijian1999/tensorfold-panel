# TensorFold 副屏性能仪表盘 · 工作约定

你是执行者。任务说明由编排者（Claude）给出，完成后由编排者独立验收，所以：
- 严格按任务说明做，不要做说明之外的功能，不要改说明没提到的文件。
- 说明里写的接口、字段名、文件路径必须一字不差。
- 说明有歧义时，按 `docs/design.md` 和 `docs/dashboard-prototype.html` 判断；两者冲突以原型为准。
- 完成前必须亲自运行说明里列出的检查命令，全部通过才算完成。不能跳过测试、不能为了通过而删改测试断言。
- 最后一行只输出 `DONE` 或 `FAILED: <原因>`。

## 工作方式

- 任务说明里写了“第一步”“第二步”的，按顺序做，每一步做完就运行那一步给出的命令。
- 说明里有歧义或自相矛盾的地方：按最直接的理解做，继续往下，最后在结果里写明你是怎么理解的。
- 检查命令的输出里出现说明没提到的无害提示（例如管道被提前关闭时 Python 打印的 `BrokenPipeError`）：不用处理，在结果里提一句即可。
- 一项检查试了两次仍然通不过、又判断不了是代码的问题还是说明的问题：停下来，最后一行写 `FAILED: <卡在哪里>`，由编排者处理。

## 环境

- 你运行在 MacBook Pro 上，代码仓库也在这里。
- 程序最终运行在 DGX Spark 上（Ubuntu 24.04，aarch64）。用 `ssh spark` 登录，已配置免密。
- 你自己就是 Spark 上正在跑的那个模型：vLLM，8000 端口，容器 `qwen38-flash-next`。Spark 上的推理引擎会换（TensorFold 在 8888 端口，vLLM 在 8888 或 8000 端口），以 `docker ps` 看到的为准。

## 目录

- `docs/` 设计文档、原型、任务说明（只读，除非任务明确要求修改）
- `docs/prototype-shots/` 原型各画面在副屏上的实拍截图（只读）
- `docs/spike-hook/` 验证外挂机制时的草稿（只读，仅供参考，不是正式实现）
- `panel/` 副屏程序（Python 包）：读取、采集、今日用量、视图模型、绘制、窗口
- `panel/tests/` 测试（只用标准库 `unittest`）
- `hook/` 容器内外挂的两个文件和生成补丁的脚本
- `fixtures/` 各状态的指标快照样例（JSON）
- `scripts/` 同步到 Spark、安装启动项、离屏截图
- `scripts/dev/` 在副屏上看原型、截副屏的小工具

## 技术约束

- Python：按 3.12 写（Spark 的系统 Python 是 3.12.3，路径 `/usr/bin/python3`）。
- 读取、采集、今日用量、视图模型只能用标准库，不能依赖 GTK。它们的测试在 MacBook Pro（`python3`）和 Spark 上都要能跑。
- 绘制和窗口用 Spark 系统自带的 GTK 4、cairo、Pango（通过 `gi`）。这部分只能在 Spark 上运行和测试。
- 测试只用标准库 `unittest`。
- 不安装任何第三方依赖：`pip`、`apt`、`npm`、`brew` 都不行。
- 在 Spark 上不使用 `sudo`。

## 绝对不能做的事

- 不要启动、停止或重启任何推理引擎的容器（TensorFold、vLLM），也不要执行各部署目录里的启动、停止脚本。需要重启模型时在结果里说明，由编排者处理。
- 不要修改容器里的任何文件，不要用 `docker exec` 改东西（只读查看可以）。
- 不要修改各部署目录（`~/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold/`、`~/Qwen3.8-Flash-Next-Single-DGX-Spark/`、`~/models/qwen38-flash-next-recipe/`）里的任何文件，包括往 `patches/` 里放文件。
- 不要为了测试向推理引擎（8888、8000 端口）发推理请求。读 `/health`、`/metrics`、`/v1/models` 可以。
- 不要修改 Spark 的系统设置（显示、息屏、登录、时区等）。

## 在 Spark 上运行

- 通过 SSH 运行需要显示器的程序时先设置环境变量：`DISPLAY=:1`、`XAUTHORITY=/run/user/1000/gdm/Xauthority`、`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`。
- 临时文件放在 Spark 的 `/tmp/tfpanel-*` 下，用完清理。
- 测试时在副屏上开的窗口，结束前必须关掉。结束进程时不要用 `pkill -f <脚本名>`，那会把你自己的 ssh 命令也杀掉；用 `pgrep -f` 配合方括号写法（例如 `pgrep -f "python3 pre[v]iew.py"`）找到进程号再 `kill`。

## 风格

- 代码注释用中文，简洁；用户可见文字用中文。
