# 任务 D1：采集器增加“一轮”统计（Python）

先读 `AGENTS.md`，再读 `collector/tfpanel.py` 的 `Collector` 类和 `collector/tests/test_tfpanel.py`。本任务只改这两个文件，不碰 `display/`、`docs/`。

## 背景

编程代理每调用一次工具就是一个新请求：预填充 1–2 秒 → 解码 1–2 秒 → 工具执行几秒 → 下一个请求。副屏按单个请求显示，画面每一两秒就整体跳一次。改法是把连续的请求算成“一轮”，副屏在一轮里显示累计值。本任务只负责在 `/metrics` 里提供一轮的统计，画面由后续任务处理。

## 一轮的定义

- 构造参数新增 `round_gap_s=60.0`：`Collector(clock=time.perf_counter, done_hold_s=4.0, window_s=2.5, tick_s=0.1, start_worker=True, round_gap_s=60.0)`。其他参数和默认值不变。
- 新增内部记录“最近一次活动结束时刻” `last_activity`（clock 时间）：`finish()` 和 `fail()` 都把它设为当时的 `now`。初始为 `None`。
- `begin()` 时（在把新请求加入 `_requests` **之前**判断）：如果**当前没有进行中的请求**，并且 `last_activity is None` 或 `now − last_activity > round_gap_s`，就**开始新的一轮**：记下本轮开始时刻 = `now`，本轮各项计数清零。否则新请求并入当前这一轮。
- `finish(req, reply)`：本轮 `requests += 1`；从成绩单取 `completion_tokens`（整数）和 `runtime.tokens_per_second`（数字）：
  - `completion_tokens` 是有效数字 → 本轮 `output_tokens += completion_tokens`；
  - 两者都是有效数字、且 `completion_tokens > 0`、`tokens_per_second > 0` → 本轮“参与平均的 token 数” `+= completion_tokens`，本轮“解码秒数” `+= completion_tokens / tokens_per_second`。
  - 有效数字的判断沿用现有 `_int_or_none` / `_num_or_none` 的规则（`bool` 不算数字）。
- `fail(req)`：只更新 `last_activity`，不改本轮任何计数。
- 所有读写本轮数据的地方都在 `self._lock` 内，和现有 `last` / `totals` 一样。

## /metrics 新增字段 `round`（字段名一字不差）

顶层新增一个键 `"round"`，其他字段一律不变（`version` 仍为 1）：

```json
"round": {
  "requests": 11,
  "output_tokens": 2345,
  "decode_tps_avg": 62.345,
  "elapsed_s": 183.2,
  "active": true
}
```

| 字段 | 含义 |
| --- | --- |
| `requests` | 本轮已成功完成的请求数（进行中的不算，失败的不算），整数 |
| `output_tokens` | 本轮已完成请求的 `completion_tokens` 之和，整数 |
| `decode_tps_avg` | 本轮平均解码速度 = 参与平均的 token 数 ÷ 解码秒数，保留 3 位小数；解码秒数为 0 时为 `null` |
| `elapsed_s` | 有进行中的请求时 = `now − 本轮开始时刻`；没有时 = `last_activity − 本轮开始时刻`；保留 3 位小数，不小于 0 |
| `active` | 有进行中的请求，或 `now − last_activity ≤ round_gap_s` 时为 `true`，否则 `false` |

- 进程启动后还没有任何请求 `begin` 过时，`"round": null`。
- 第一个请求 `begin` 之后 `round` 就不再是 `null`（此时 `requests` 为 0、`output_tokens` 为 0、`decode_tps_avg` 为 `null`、`active` 为 `true`）。
- `round` 里没有任何对话文字。

## 启动器

`main()` 里构造 `Collector` 时，`round_gap_s` 取环境变量 `TFPANEL_ROUND_GAP_S`（浮点数，秒）；没设、解析失败、或不是正数时用 `60.0`。

## 测试要求（加到 collector/tests/test_tfpanel.py，现有测试一条都不能删改）

用注入的假时钟、`start_worker=False`，直接调用 `begin` / `finish` / `fail` / `snapshot`。至少覆盖：

1. 启动后未 begin 过：`snapshot()["round"] is None`。
2. 第一个请求 begin 后：`round == {"requests": 0, "output_tokens": 0, "decode_tps_avg": None, "elapsed_s": ..., "active": True}`。
3. 两个请求间隔 ≤ `round_gap_s`（例如 finish 在 t=10，下一个 begin 在 t=70，`round_gap_s=60`）→ 同一轮，`requests` 累加到 2。
4. 间隔 > `round_gap_s`（下一个 begin 在 t=70.001）→ 新的一轮，`requests` 从 0 开始，`output_tokens` 清零。
5. 平均速度按 token 加权：请求 A `completion_tokens=100, tokens_per_second=50`（2 秒），请求 B `completion_tokens=300, tokens_per_second=100`（3 秒）→ `decode_tps_avg == 80.0`（400 ÷ 5），不是 75。
6. 成绩单缺 `tokens_per_second`、或 `tokens_per_second` 为 0、或 `completion_tokens` 为 0 的请求：计入 `requests`，`completion_tokens` 有效时计入 `output_tokens`，但不参与平均；只有这种请求时 `decode_tps_avg is None`。
7. `fail()`：不计入 `requests`，但刷新 `last_activity`——例如 finish 在 t=0，fail 在 t=50，下一个 begin 在 t=100（`round_gap_s=60`）仍是同一轮。
8. 有请求在进行中时，另一个请求 begin 一定并入当前轮（即使距 `last_activity` 已超过 `round_gap_s`）。
9. `elapsed_s`：进行中 = now − 开始；空闲时停在 `last_activity − 开始`，之后时间再流逝也不变。
10. `active`：最后一次结束后 60 秒内为 `true`，60.001 秒时为 `false`；有请求进行中时为 `true`。
11. HTTP 测试里断言顶层字段包含 `round`。
12. `main()` 的环境变量解析：把解析逻辑写成可单独测试的函数 `round_gap_from_env(environ)`，返回浮点秒数；测 `{}` → 60.0、`{"TFPANEL_ROUND_GAP_S": "30"}` → 30.0、`"abc"` → 60.0、`"0"` → 60.0、`"-5"` → 60.0。

## 完成前必须运行并全部通过

```sh
cd collector && ~/.local/share/uv/tools/tensorfold/bin/python -m unittest discover -s tests -v
~/.local/share/uv/tools/tensorfold/bin/python -c "import ast,sys; ast.parse(open('collector/tfpanel.py').read())"
```

不要运行 `collector/tfpanel serve ...`，不要启动、停止或重启 TensorFold。真实联调由编排者来做。
