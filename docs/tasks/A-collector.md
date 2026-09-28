# 任务 A：启动器 + 采集器 + /metrics（Python）

先读 `AGENTS.md`，再读 `docs/design.md` 的「整体架构」「数据采集」「指标接口」「更新与维护」四节。本任务只写 Python，不碰 `display/`。

## 交付文件

1. `collector/tfpanel.py`：全部逻辑，单文件，只用标准库。
2. `collector/tfpanel`：可执行 shell 脚本（`chmod +x`），找到 TensorFold 的 Python 并运行 `tfpanel.py`，参数原样传递。
3. `collector/tests/test_tfpanel.py`：`unittest` 测试，不依赖真实 TensorFold 和真实模型。

## TensorFold 的真实接口（已核对 v0.3.4 源码，照此实现）

- 模块 `tensorfold.server.app` 里的 `class ChatApp`，方法：
  `def chat(self, messages, *, max_tokens=None, temperature=0.0, on_delta=None, tools=None, sampling=None) -> dict`
  HTTP 层用关键字参数调用它；可能在多个线程里同时被调用。
- `on_delta(delta)` 收到三种东西：`str`（正文增量）、`{"reasoning_content": "..."}`（思考增量）、其他 dict（工具调用增量，文字在嵌套的字符串值里）。
- 非流式请求时 `on_delta` 为 `None`。**这时绝不能替它传一个回调进去**（会改变 TensorFold 行为），只能记开始和结束。
- 返回的 dict（称“成绩单”）里我们要用的字段：
  `prompt_tokens`、`cached_tokens`、`completion_tokens`、`finish_reason`、
  `runtime.tokens_per_second`、`runtime.time_to_first_token`、`speculative.acceptance_rate`。
  任何字段都可能缺失或改名：缺哪个，对应输出就是 `null`，其他照常。
- 实例属性：`self.served_name`（str，模型名）、`self.context_window`（int，0 表示无限制）、`self.tokenizer`（有 `encode(text, add_special_tokens=False)`，不支持该参数时退回 `encode(text)`）、`self.tokenizer_lock`（`threading.Lock`，调用 tokenizer 时必须持有它，持有时间要尽量短）。
- 版本：`tensorfold.__version__`。
- **重要**：`tensorfold.cli` 在设置好 MLX 环境变量之后才 import `tensorfold.server.app`。所以 tfpanel **不能**自己提前 import `tensorfold.server.app`，必须用 `sys.meta_path` 导入钩子，在该模块被 TensorFold 自己 import、执行完之后再打补丁。

## 启动器行为

`tfpanel <任意参数>` 等价于 `tensorfold <任意参数>`，只是多了外挂：

1. 记录启动时间（用于 `uptime_s`）。
2. 用 `importlib.util.find_spec("tensorfold.server.app")` 检查模块是否存在（这不会执行该模块）。不存在 → 直接判定 `hooks.chat = "missing"`。
3. 安装导入钩子。`tensorfold.server.app` 执行完后运行「启动自检」：`ChatApp` 存在、`ChatApp.chat` 可调用、`inspect.signature` 里有 `on_delta` 参数。
   - 通过：用包装函数替换 `ChatApp.chat`（`functools.wraps`），`hooks.chat = "ok"`。同时尽力包装 `ChatApp.__init__`，在构造完成后记下实例（拿模型名、上下文上限）；包装 `__init__` 失败就算了，退回到第一次 `chat()` 时再记。
   - 不通过：不打任何补丁，向 stderr 打印一行 `[tfpanel] 指标未挂载：TensorFold <版本> 的 ChatApp.chat 已变化，副屏将显示“指标不可用”`，`hooks.chat = "missing"`。
   - 环境变量 `TFPANEL_FORCE_HOOK_FAIL=1` 时强制走“不通过”分支（用于验收）。
4. 启动 `/metrics` HTTP 服务（守护线程，`ThreadingHTTPServer`），地址 `127.0.0.1`，端口取环境变量 `TFPANEL_METRICS_PORT`，默认 `8081`。端口被占用时向 stderr 打印一行提示并继续运行 TensorFold（不能让 TensorFold 起不来）。
5. 调用 `tensorfold.cli.main(sys.argv[1:])`，用它的返回值 `sys.exit`。

外挂的任何环节出错（钩子、自检、HTTP 服务、采集），都只打印/记录，**绝不能**让 TensorFold 起不来，也不能让请求失败。

## 包装后的 chat()

```
def wrapped(self, *args, **kwargs):
    原 on_delta = kwargs.get("on_delta")（也要兼容它以位置参数传入的极端情况：若 args 非空就不改 args，只做开始/结束记录）
    若原 on_delta 不是 None：换成一个新回调，新回调先调用原 on_delta（原样传参、原样返回、它抛的异常原样抛出），再把增量交给采集器（采集器出错吞掉）
    采集器.begin(...)（出错吞掉）
    try: reply = 原 chat(self, *args, **kwargs)
    except: 采集器.fail(...)（出错吞掉）; raise   # 原样抛出
    采集器.finish(reply)（出错吞掉）
    return reply   # 必须是同一个对象，不复制、不修改
```
增量回调里只做“追加 (时间, 文本) 到列表”这种 O(1) 的事，不在这里分词。时间用 `time.perf_counter()`。

## 采集器（class Collector）

构造参数要可注入，方便测试：`Collector(clock=time.perf_counter, done_hold_s=4.0, window_s=2.5, tick_s=0.1, start_worker=True)`。

- **请求记录**：每次 `begin` 创建一条（开始时间、是否流式、增量列表、已换算 token 数、token 事件列表 `[(时间, 数量)]`、首字时间、峰值）。允许多个请求同时在进行；“当前请求”= 进行中的请求里最后开始的那个。
- **换算线程**：每 `tick_s` 秒一次，对每个进行中的请求，把上次之后新到的增量文字拼起来，一次 `tokenizer.encode` 得到数量 n，按每段文字的长度比例把 n 分摊到各段的到达时间上，追加到 token 事件列表。持锁只包住 encode 那一句。没有 tokenizer 时按每 4 个字符 1 个 token 估算。提供 `tick(now=None)` 方法供测试直接调用（`start_worker=False` 时不启动线程）。
- **首字时间**：第一个增量到达的时间 − 开始时间。
- **实时速度 `decode_tps`**：时间落在 `(now − window_s, now]` 内的 token 数 ÷ `max(0.5, min(window_s, 解码已进行时间))`，解码已进行时间 = now − 首字时间点。
- **峰值 `decode_tps_peak`**：解码进行 1.0 秒之后，每次计算 `decode_tps` 时取最大值；1 秒之前为 0。
- **平均 `decode_tps_avg`**：解码进行满 0.5 秒后 = 首字之后的 token 数 ÷ 首字之后经过的秒数（和引擎算法一致：第一个事件时刻的 token 不算在内也可以，误差可忽略）；不满 0.5 秒为 `null`。
- **状态**（整个进程一个）：
  - 有进行中的请求：当前请求还没收到任何增量 → `prefill`；收到了 → `decode`。
  - 没有进行中的请求：最近一次成功完成距今 < `done_hold_s` → `done`；否则 `idle`。
  - 请求抛异常：该请求直接丢弃，不更新 `last`，不进入 `done`。
- **完成时**：用成绩单生成 `last`（见下），`totals.requests += 1`，`totals.peak_tps = max(旧值, 本次 decode_tps_peak)`。

## /metrics 输出（字段名一字不差）

`GET /metrics` → `200`，`Content-Type: application/json; charset=utf-8`，`Cache-Control: no-store`。其他路径 → `404`。不记访问日志（覆盖 `log_message`）。

```json
{
  "version": 1,
  "state": "idle | prefill | decode | done",
  "engine_ready": true,
  "model": "Qwen3.8-27B-MLX-4bit",
  "tensorfold_version": "0.3.4",
  "context_max": 262144,
  "hooks": { "chat": "ok | missing" },
  "current": {
    "elapsed_s": 3.21,
    "ttft_s": 0.457,
    "output_tokens": 312,
    "decode_tps": 58.4,
    "decode_tps_peak": 71.2,
    "decode_tps_avg": 57.9
  },
  "last": {
    "prompt_tokens": 22,
    "cached_tokens": 0,
    "completion_tokens": 570,
    "decode_tps": 58.2,
    "ttft_s": 0.457,
    "acceptance_rate": 0.64,
    "context_used": 592,
    "finish_reason": "stop"
  },
  "totals": { "requests": 42, "peak_tps": 189.3, "uptime_s": 3600 }
}
```

- `engine_ready`：已经拿到 ChatApp 实例（构造完成或处理过请求）为 `true`，否则 `false`（模型还在加载）。
- `model` / `context_max`：来自实例；未知为 `null`；`context_window` 为 0 时 `context_max` 为 `null`。
- `tensorfold_version`：`tensorfold.__version__`，取不到为 `null`。
- `current`：没有进行中的请求时为 `null`。`prefill` 时 `ttft_s`、`decode_tps_avg` 为 `null`，`output_tokens` 为 0，`decode_tps`、`decode_tps_peak` 为 0。
- `last`：从未完成过请求时为 `null`。字段取自成绩单：`decode_tps` ← `runtime.tokens_per_second`，`ttft_s` ← `runtime.time_to_first_token`，`acceptance_rate` ← `speculative.acceptance_rate`，`context_used` = `prompt_tokens + completion_tokens`（任一缺失则为 `null`）。
- 数值：速度和秒数保留 3 位小数以内即可；token 数为整数；`uptime_s` 为整数。
- 输出里绝不包含任何对话文字。

## collector/tfpanel 脚本

```sh
#!/bin/sh
# 找到 tensorfold 命令所用的 Python（读它第一行 #!），用它运行同目录下的 tfpanel.py
```
- 解析 `tfpanel` 脚本自身的真实路径（跟随符号链接，macOS 自带 `readlink -f` 可用），找到同目录的 `tfpanel.py`。
- 从 `command -v tensorfold` 的第一行 shebang 取 Python 路径；找不到 tensorfold 时打印中文错误并以 1 退出。
- `exec "$PY" "$DIR/tfpanel.py" "$@"`。

## 测试要求（collector/tests/test_tfpanel.py）

用假的 TensorFold：在测试里构造假的 `ChatApp` 类（签名和上面一致）、假 tokenizer（例如 `encode` 返回按空格切分的列表）和注入的假时钟，不 sleep 等真实时间（HTTP 测试除外）。至少覆盖：

1. 包装后返回值是同一个对象（`is`），参数原样传到原函数。
2. 原 chat 抛出的异常原样抛出（同一类型、同一对象），且不进入 `done`、`last` 不变。
3. `on_delta=None` 时，原函数收到的 `on_delta` 仍然是 `None`。
4. 原 `on_delta` 按顺序收到全部增量（str 和 dict 都有）。
5. 采集器内部出错（例如 tokenizer.encode 抛异常）时，请求照常成功返回。
6. 状态流转：idle → prefill → decode → done → （done_hold_s 之后）idle。
7. `decode_tps` 的窗口计算、`decode_tps_peak` 的 1 秒门槛、`decode_tps_avg` 的 0.5 秒门槛，用假时钟精确断言。
8. `last` 各字段映射正确；成绩单缺字段时对应为 `null`，其他字段正常。
9. 自检：`chat` 没有 `on_delta` 参数时不打补丁、`hooks.chat == "missing"`；`TFPANEL_FORCE_HOOK_FAIL=1` 同样。
10. 导入钩子：用一个临时假包（在临时目录里写一个假的 `tensorfold/server/app.py` 并加入 `sys.path`），验证在 import 之前补丁没有执行、import 之后 `ChatApp.chat` 已被包装。注意测试之间清理 `sys.modules` 和 `sys.meta_path`。
11. HTTP：在随机空闲端口启动 /metrics，`urllib` 请求得到合法 JSON，包含上面列出的全部顶层字段；`/other` 返回 404。

为便于测试，`tfpanel.py` 应把逻辑拆成可单独调用的函数/类（例如 `install_hook(...)`、`patch_chat_app(module)`、`Collector`、`make_metrics_server(port, collector)`、`main(argv)`），`import tfpanel` 本身不能有副作用。

## 完成前必须运行并全部通过

```sh
cd collector && ~/.local/share/uv/tools/tensorfold/bin/python -m unittest discover -s tests -v
~/.local/share/uv/tools/tensorfold/bin/python -c "import ast,sys; ast.parse(open('collector/tfpanel.py').read())"
sh -n collector/tfpanel && test -x collector/tfpanel
```
不要运行 `collector/tfpanel serve ...`（会再加载一份模型），真实联调由编排者来做。
