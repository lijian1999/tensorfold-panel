# TensorFold 副屏性能仪表盘（TFPanel）

## 这是什么

让拓展坞上那块 3.5 英寸小副屏实时显示本地 TensorFold 模型的运行状态（主要是解码速度 tok/s）。客户端照常连 8080 端口，什么都不用改：用一个同名启动器 `tfpanel` 代替 `tensorfold` 启动模型，外挂一个采集器在 8081 端口提供只读的 `/metrics`，副屏程序读它并全屏绘制。

设计细节见 [`docs/design.md`](docs/design.md)，界面效果见可交互原型 [`docs/dashboard-prototype.html`](docs/dashboard-prototype.html)（浏览器直接打开，地址后加 `?kiosk=1` 进入只显示屏幕的 Kiosk 模式）。

## 安装

```sh
sh scripts/install.sh
```

脚本会：release 构建副屏程序并装到 `~/Applications/TFPanel.app`，在 `~/.local/bin/tfpanel` 建指向仓库 `collector/tfpanel` 的符号链接，检查 `tensorfold` 命令是否在 PATH 里。可重复运行；`~/.local/bin` 需要在你的 PATH 里。

## 日常使用

```sh
tfpanel serve Vontra/Qwen3.8-27B-MLX-4bit
```

参数和 `tensorfold serve` 完全相同，只是额外挂上指标采集。

- 副屏程序默认找名为 `TYPE-C` 的屏幕，可用 `defaults write com.tensorfold.panel screenName "<屏幕名>"` 永久修改，或用 `--screen <名字>` 临时指定（屏幕名可在“系统设置 > 显示器”里看到）；没插副屏时不弹任何窗口，插上后自动全屏铺满。
- 菜单栏的小 gauge 图标里有三个选项：
  - **自动切换到 960 × 640**（默认开）：副屏接入时如果不是 960×640 就自动切过去。
  - **登录时启动**：加入登录项（从 `~/Applications/TFPanel.app` 启动时可用）。
  - **退出**：退出副屏程序。
- 采集器在 `127.0.0.1:8081` 提供只读的 `/metrics`；TensorFold 进程退出后它随之消失。

## /metrics 接口

```sh
curl http://127.0.0.1:8081/metrics
```

端口可用环境变量 `TFPANEL_METRICS_PORT` 修改（如 `TFPANEL_METRICS_PORT=9000 tfpanel serve …`）。接口只监听本机地址、只读，不含任何对话内容。字段含义（`state`、`engine_ready`、`hooks`、`current`、`last`、`totals`）见 [design.md 的「指标接口」一节](docs/design.md)。

## 副屏上各状态的含义

| 状态 | 什么时候出现 | 显示什么 |
| --- | --- | --- |
| 引擎离线 | TensorFold 没在运行，或连续 3 次读不到 `/metrics` | “引擎离线”，圆弧灰掉，右侧显示上次平均 / 已离线时长 / 内存 |
| 启动中 | TensorFold 进程在，但模型还在加载（`engine_ready` 为 `false`） | “模型加载中”，右侧显示上次平均 / 运行时长 / 内存 |
| 指标不可用 | TensorFold 更新后启动自检失败（`hooks.chat` 为 `missing`） | “指标不可用 · TensorFold 已更新，需要适配”；推理本身不受影响 |
| 空闲 | 没有请求（或请求结束后 4 秒淡回） | 上次最终速度（灰色），右侧显示输出 / 首字 / 内存 |
| 预填充中 | 收到请求，还在等第一个 token | 已等待秒数，圆弧循环扫动；不显示假进度 |
| 解码中 | 首字到达，模型在输出 | 实时解码速度（2.5 秒平滑），右侧显示输出 / 平均 / 峰值 |
| 完成 | 请求结束，停留 4 秒 | 引擎给出的精确平均速度（带“精确”标记），右侧显示输出 / 缓存命中 / 接受率 |

## TensorFold 更新后

`tfpanel` 启动器在 TensorFold 安装目录之外，`tensorfold update` 不会碰到它，参数原样透传。更新后的处理：

- **大多数更新**：什么都不用做。
- **副屏出现“指标不可用”**：说明 TensorFold 的 `chat()` 接口变了。把终端里那行 `[tfpanel] 指标未挂载…` 提示发给 Claude，一般改几行就能修好。期间 TensorFold 推理照常工作。
- **急着用**：先退回上一个能用的 TensorFold 版本。

想试降级显示效果，可以模拟自检失败：

```sh
TFPANEL_FORCE_HOOK_FAIL=1 tfpanel serve Vontra/Qwen3.8-27B-MLX-4bit
```

副屏会显示“指标不可用”，TensorFold 本身照常运行。

## 开发

```sh
# 采集器测试（Python 标准库 unittest）
cd collector && ~/.local/share/uv/tools/tensorfold/bin/python -m unittest discover -s tests

# 显示程序测试（swift-testing）
cd display && swift test

# 离屏截图：对 display/Fixtures 下每个状态的 JSON 各出一张 960×640 PNG
cd display && .build/debug/TFPanel --snapshot-all <目录>
```

调试参数（只影响本次运行，不写回设置）：

- `--metrics-url <url>`：覆盖指标地址（默认 `http://127.0.0.1:8081/metrics`）
- `--screen <名字>`：覆盖副屏名（默认取设置里的值，初始 `TYPE-C`）
- `--snapshot <fixture.json | offline> <out.png>`：离屏截一张
- `--debug-capture <目录>`：收到 SIGUSR1 时把副屏画面截图

## 卸载

```sh
sh scripts/uninstall.sh
```

删除 `~/Applications/TFPanel.app` 和 `~/.local/bin/tfpanel`（只删指向本仓库的符号链接），仓库里的源代码不受影响。如果勾选过“登录时启动”，请先在菜单栏图标里取消。
