# 任务 E：采集（collector）

先读 `AGENTS.md`，再读 `docs/tasks/00-contracts.md` 的第 1、2、4、5、6 节，和 `docs/design.md` 的“数据来源”“状态与并发规则”“连续请求（一轮）与短预填充”“指标快照（采集 → 绘制）”四节。本任务只用标准库，全部在 MacBook Pro 上完成，不需要 `ssh spark`。

`panel/config.py` 已经有了。`panel/sources.py`、`panel/usage.py` 由别的任务同时在写，**本任务不导入它们**：采集器只接收已经解析好的字典，`usage` 是从外面传进来的对象。

## 交付文件

1. `panel/collector.py`
2. `panel/tests/test_collector.py`

不要创建或修改别的文件。

## 分两步交付

这个任务分两步，由先后两次派工完成。派工时会告诉你这次做哪一步，**只做那一步**。

- **第一步（不含外挂）**：实现整个 `feed`，但把外挂当作永远不存在来处理——`hook` 字段照 2.3 判断并填进快照，其余凡是写着“`hook == "ok"` 时”的分支先不实现，一律走 `hook == "missing"` 的那条路（2.4 的 `现存输出` 取 0、估算取 `C − 上次的 C`；不做 2.7；2.9 的 `output_tokens`、2.10、2.12 的 `context_used` 都走没有外挂的算法）。测试写“测试要求”里的第 1–7、11、13 条（第 7 条里和外挂无关的部分）。
- **第二步（外挂）**：在第一步的代码上补全所有 `hook == "ok"` 的分支（2.4、2.7、2.9、2.10、2.12），测试补第 8、9、10、12 条。第一步的测试必须继续通过。

建议的写法：把每个小节写成一个私有方法（例如 `_on_finish`、`_on_arrive`、`_decode_section`、`_prefill_section`、`_round_section`），`feed` 按顺序调用它们。先让测试第 1 条（单个请求全过程）跑通，再一条一条加。

## 接口

```python
class Collector:
    def __init__(self, config: Config, usage=None)
    def feed(self, now: float, health: dict | None, metrics: dict | None = None,
             memory: dict | None = None, model: str | None = None) -> dict
```

`feed` 是纯计算：不读时钟、不访问网络、不读写文件、不起线程。同样的输入序列必须得到同样的输出。

输入的样子：

```python
health = {"ok": True, "busy": True, "requests_running": 1, "requests_total": 98,
          "prompt_tokens_total": 8260391, "completion_tokens_total": 185305,
          "prefill_seconds_total": 1457.42, "decode_seconds_total": 2851.45,
          "cached_tokens_total": 5443627, "rounds_total": 60827,
          "drafted_total": 178502, "accepted_total": 124381,
          "streams": {"decoding": 1, "prefilling": 0, "max": 5}, "context_length": 262144,
          "tfpanel": {"v": 1, "streams": [
              {"id": 3, "phase": "decode",  "prompt": 18420, "cached": 16384, "output": 312},
              {"id": 4, "phase": "prefill", "prompt": 24615, "cached": 2048,  "filled": 10240}]}}
metrics = {"waiting": 0, "kv_usage": [0.093899, 0.0], "ttft_sum": 1599.72, "ttft_count": 156}
memory = {"used_gb": 94.21, "total_gb": 121.62}
```

- `tfpanel` 可能没有（外挂失效）。`streams` 也可能没有（当作 `decoding = requests_running`、`prefilling = 0`、`max = 1`）。
- `health` 里缺任何一个累计值时按 0 处理，不抛异常。

## 名词

下面用这些记号，`上次` 指上一次成功读到 `/health` 的那次 `feed`：

- `C` = `completion_tokens_total`（**包含正在生成的请求已输出的 token，解码时实时增长**），`R` = `requests_total`。
- `dec`、`pre` = `streams.decoding`、`streams.prefilling`。
- `在跑数` = `max(requests_running, dec + pre)`。
- `外挂行` = `tfpanel.streams`（`hook` 为 `ok` 时）。
- 其余累计值（`prompt_tokens_total`、`cached_tokens_total`、`prefill_seconds_total`、`decode_seconds_total`、`drafted_total`、`accepted_total`）只在请求结束时增加，下面用 `Δ名字` 表示“这次 − 上次”。

## 每次 `feed` 的处理顺序

### 0. 输入沿用

`metrics`、`memory`、`model` 为 `None` 时沿用上一次的值。从没有过 `model` 时用 `config.model_name`。

### 1. 读不到（`health is None`）

- 连续失败次数加 1；第一次失败时记下 `失败起点 = now`。
- 从来没成功过，或连续失败 ≥ 3 次：进入离线。离线时清掉所有“正在跑”的状态（忙碌段、解码段、流表、本轮设为没有、`上次` 设为没有），返回离线快照：`state = "offline"`、`offline_s = now − 失败起点`、`lanes` 的 `decoding`、`prefilling`、`waiting` 为 0（`max` 沿用，从没读到过用 5）、`decode`、`prefill`、`round` 为 `null`，其余沿用（`last`、`today`、`memory`、`model`、`context_max`、`hook`）。
- 连续失败 1–2 次：原样返回上一次的快照（同样的内容）。
- 读不到时不调用 `usage.update`，但 `today` 仍然每次取 `usage.today()`。

### 2. 读到了

连续失败次数清零。然后依次：

**2.1 记账**：`usage.update({"prompt": prompt_tokens_total, "cached": cached_tokens_total, "completion": C, "requests": R})`（`usage` 不为 `None` 时）。`usage` 抛的异常要吃掉。

**2.2 模型重启**：有 `上次` 且（`R < 上次的 R` 或 `C < 上次的 C`）：清掉所有“正在跑”的状态（同离线时那样），把这次当作没有 `上次` 来处理。

**2.3 `hook`**：`health["tfpanel"]` 是字典、`v == 1`、`streams` 是列表，则 `hook = "ok"`，否则 `"missing"`。

**2.4 请求结束**（有 `上次` 且 `结束数 = R − 上次的 R ≥ 1`）：

- `幸存数 = 上次的在跑数 − 结束数`。
- 这批结束的请求的输出 token 数 `completion`：
  - `幸存数 ≤ 0`（之前在跑的全结束了）：`completion = C − 忙碌起点的 C − 本忙碌段已归属的输出 − 现存输出`。其中 `现存输出` = 外挂行里 `phase == "decode"` 的 `output` 之和（`hook` 为 `missing` 时为 0）。这是精确值。
  - `幸存数 > 0`（还有别的流在跑）：估算。`上次` 的外挂行里有、这次没有的那些 `decode` 行，如果正好是 `结束数` 条，取它们上次的 `output` 之和；否则取 `C − 上次的 C`。然后 `本忙碌段已归属的输出 += completion`。
  - 结果小于 0 时取 0。
- 生成 `last`（全部来自差值）：

| 字段 | 值 |
| --- | --- |
| `prompt_tokens` | `Δprompt_tokens_total` |
| `cached_tokens` | `Δcached_tokens_total` |
| `completion_tokens` | `completion` |
| `decode_tps` | `completion ÷ Δdecode_seconds_total`；分母 ≤ 0 时 `null` |
| `prefill_tps` | `(Δprompt − Δcached) ÷ Δprefill_seconds_total`；分子或分母 ≤ 0 时 `null` |
| `ttft_s` | 这个忙碌段里只有过一条流时 = `首个 token 时刻 − 忙碌起点时刻`（见 2.8），否则 `null`；之后会被 2.11 的精确值覆盖 |
| `acceptance_rate` | `Δaccepted_total ÷ Δdrafted_total`；分母 ≤ 0 时 `null` |
| `context_used` | `prompt_tokens + completion_tokens` |

- 本轮（没有就先按 2.5 的方式新开一轮，起点取 `now`）：`已完成 += 结束数`；`输出和 += completion`；`解码秒数和 += Δdecode_seconds_total`；`最后结束时刻 = now`；`上一个提示 = Δprompt_tokens_total`（`结束数 == 1` 时，否则 `None`）。
- 平均预填充速度（初始 2300）：`结束数 == 1`、`Δprompt − Δcached ≥ 2048`、`Δprefill_seconds_total > 0` 时，`新值 = 0.7 × 旧值 + 0.3 × (Δprompt − Δcached) ÷ Δprefill_seconds_total`。
- `等待首字精确值 = 结束数`（给 2.11 用）。
- 这次 `在跑数 == 0`：`全部结束时刻 = now`。

**2.5 请求到达**：`到达计数 = R + requests_running`。`到达数` = 有 `上次` 时 `max(0, 到达计数 − 上次的到达计数)`；没有 `上次` 时 = `在跑数`。`到达数 ≥ 1` 时：

- `最近到达时刻 = now`。
- 没有本轮，或（`上次的在跑数 − 结束数 ≤ 0` 且 `now − 本轮最后结束时刻 > config.round_gap_s`）：新开一轮 `{起点时刻: now, 起点的 C: 上次的 C（没有上次就用 C）, 已完成: 0, 输出和: 0, 解码秒数和: 0, 解码时长: 0, 出现过并发: False, 最后结束时刻: now, 上一个提示: None}`。否则算进当前这一轮。

注意判断顺序：先 2.4 后 2.5。所以“上一个请求结束、下一个请求到达”落在同一次读数里时，新请求仍然算进同一轮（刚结束，间隔为 0）。

**2.6 忙碌段**：“忙碌段”指 `在跑数` 从 0 变成大于 0 起、到再次回到 0 为止。

- `在跑数 > 0` 且（没有 `上次`，或 `上次的在跑数 − 结束数 ≤ 0`）：新开忙碌段：`忙碌起点时刻 = now`、`忙碌起点的 C = 上次的 C（没有上次就用 C）`，但如果这次同时有请求结束（2.4 的 `幸存数 ≤ 0` 情形），`忙碌起点的 C = C − 现存输出`；`已归属的输出 = 0`、`首个 token 时刻 = None`、`段内最大在跑数 = 0`。
- `在跑数 > 0`：`段内最大在跑数 = max(段内最大在跑数, 在跑数)`；有本轮且 `在跑数 ≥ 2`：`本轮.出现过并发 = True`。
- `在跑数 == 0`：忙碌段结束，清空流表和解码段。

**2.7 流表**（只在 `hook == "ok"` 时维护，按外挂行的 `id`）：

- 新出现的 id：`开始时刻 = 最近到达时刻`（没有就用 `now`）；如果是 `prefill` 行，`进度点 = [(now, filled)]`。
- 已有的 `prefill` 行：`filled` 比最后一个进度点的大，就追加 `(now, filled)`，只保留最后 4 个。
- 这次没出现的 id 从流表里删掉。
- 一条流的预填充速度 = `(最后一个进度点的 filled − 第一个进度点的 filled) ÷ (两者时刻之差)`；进度点不足 2 个或时刻差 ≤ 0 时没有速度。

**2.8 状态**：`dec > 0` → `"decode"`；否则 `在跑数 > 0` → `"prefill"`；否则有 `全部结束时刻` 且 `now − 全部结束时刻 < config.done_hold_s` → `"done"`；否则 `"idle"`。

首个 token：`首个 token 时刻` 为空、且（`dec > 0` 或 `C − 忙碌起点的 C − 已归属的输出 > 0`）时，记 `首个 token 时刻 = now`。

**2.9 解码段**（`state == "decode"` 时）：

- 上一次的状态不是 `decode`（刚进入）：`解码起点时刻 = now`、`解码起点的 C = C`、`采样 = [(now, C)]`、`峰值 = 0`。否则把 `(now, C)` 追加到采样，丢掉 `now − 10` 之前的。
- `el = now − 解码起点时刻`。
- `参考点` = 采样里时刻 `≤ now − 2.5` 的最后一个；没有就用第一个采样。`tps = (C − 参考点的 C) ÷ max(0.5, now − 参考点的时刻)`。
- `el > 1.0` 时 `峰值 = max(峰值, tps)`。`tps_peak` = 峰值。
- `tps_avg` = `el ≥ 0.5` 时 `(C − 解码起点的 C) ÷ el`，否则 `null`。
- `output_tokens` = `hook == "ok"` 时外挂行里 `decode` 行的 `output` 之和；否则 `C − 忙碌起点的 C − 已归属的输出`。
- `ttft_s` = `段内最大在跑数 == 1` 且有 `首个 token 时刻` 时 `首个 token 时刻 − 忙碌起点时刻`，否则 `null`。
- 有本轮且有 `上次`：`本轮.解码时长 += min(now − 上次的时刻, 1.0)`。

`state != "decode"` 时快照的 `decode` 为 `null`。

**2.10 预填充段**（`pre > 0` 或 `state == "prefill"` 时快照有 `prefill`，否则为 `null`）：

`hook == "ok"`，取外挂行里的 `prefill` 行：

| 字段 | 值 |
| --- | --- |
| `prompt_tokens` `P` | 各行 `prompt` 之和 |
| `cached_tokens` `K` | 各行 `cached` 之和 |
| `filled_tokens` `F` | 各行 `filled` 之和 |
| `elapsed_s` | `now − 这些行里最早的开始时刻`；一行都没有时 `now − 忙碌起点时刻` |
| `tps` | 有速度的那些行的速度之和；都没有速度时 `null` |
| `est_s` | `(P − K) ÷ 平均预填充速度` |
| `remaining_s` | 有 `tps` 时 `(P − F) ÷ tps`；否则 `max(0, est_s − elapsed_s)` |
| `cache_miss` | 见下 |

`cache_miss` 为 `true` 的条件（全部满足）：有本轮、`本轮.出现过并发` 为假、`本轮.已完成 ≥ 1`、`本轮.上一个提示` 不为空且 `≥ 4000`、`P ≥ 上一个提示 × 0.5`、`K < 上一个提示 × 0.5`、`P − K ≥ 4000`。

`hook == "missing"`：`elapsed_s = now − 预填充起点`，其中预填充起点是“`pre > 0` 或 `state == "prefill"`”这个条件从假变真的那次的 `now`（条件为假时清掉）。`prompt_tokens` = 有 `metrics` 且 `kv_usage` 非空且最大值 > 0 时 `round(max(kv_usage) × context_max)`，否则 `null`。`cached_tokens`、`filled_tokens`、`tps`、`remaining_s`、`est_s` 都是 `null`，`cache_miss` 为 `false`。

**2.11 首字的精确值**：这次传了 `metrics` 且 `ttft_count`、`ttft_sum` 都不为空时：有上一组 `(ttft_sum, ttft_count)`、`ttft_count` 比它大、`等待首字精确值 ≥ 1`、有 `last`：`last.ttft_s = Δttft_sum ÷ Δttft_count`，`等待首字精确值 = 0`。然后把这组值记为上一组。（`ttft_count` 变小说明模型重启，只更新上一组。）

**2.12 其余字段**：

- `lanes` = `{"max": streams.max, "decoding": dec, "prefilling": pre, "waiting": 在跑数 > 0 时取 metrics.waiting（没有为 0），否则 0}`。
- `context_max` = `health.context_length`（没有时沿用，从没有过用 262144）。
- `context_used`：`在跑数 > 0` 时：`hook == "ok"` 且有外挂行 → 各行 `prompt + output`（`prefill` 行只算 `prompt`）的最大值；否则 `metrics.kv_usage` 最大值 > 0 → `round(最大值 × context_max)`；否则沿用上一次快照的值。`在跑数 == 0` 时：`last.context_used`，没有 `last` 为 0。
- `round`（没有本轮时为 `null`）：

| 字段 | 值 |
| --- | --- |
| `requests` | `已完成` |
| `running` | `在跑数` |
| `output_tokens` | `C − 起点的 C`（含正在生成的） |
| `decode_tps_avg` | 没出现过并发：`输出和 ÷ 解码秒数和`（分母 ≤ 0 为 `null`）；出现过并发：`解码时长 > 0.5` 时 `(C − 起点的 C) ÷ 解码时长`，否则 `null` |
| `exact` | `not 出现过并发` |
| `elapsed_s` | `在跑数 > 0` 时 `now − 起点时刻`，否则 `最后结束时刻 − 起点时刻` |
| `active` | `在跑数 > 0` 或 `now − 最后结束时刻 ≤ config.round_gap_s` |

- `today` = `usage.today()`（`usage` 为 `None` 时 `{"date": "", "prompt_tokens": 0, "cached_tokens": 0, "completion_tokens": 0, "requests": 0, "cost": 0.0}`；`usage` 抛异常时同样）。
- `memory` = 传进来的（沿用），从没有过时 `{"used_gb": 0.0, "total_gb": 0.0}`。
- `offline_s` = `null`；`version` = 2；`model`、`hook`、`state`。

快照的键和顺序与 `docs/design.md` 里的示例一致。数值不用特意四舍五入。返回的字典每次都是新的（调用方改它不影响采集器）。

## 测试要求（`panel/tests/test_collector.py`）

写一个辅助函数生成 `health` 字典（传累计值和流数，其余给默认值），再写一个假的 `usage`（记录收到的 `totals`，`today()` 返回固定字典）。全部用假时刻，不 sleep。浮点用 `assertAlmostEqual`。至少覆盖：

1. **单个请求全过程**（`hook` 为 `missing`，每 0.1 秒一次）。空闲基线：`R=97, C=185105, prompt=8260333, cached=5443627, prefill_s=1457.3376, decode_s=2848.0993, drafted=178331, accepted=124265`。然后：`t=10.0` 到达（`requests_running=1, pre=1`）；`t=10.1` 起 `dec=1`，`C` 每 0.1 秒加 6，直到 `t=13.4` 共加到 `C=185305`（最后几次自己凑够 200）；`t=13.5` 结束：`R=98, running=0, dec=0`，累计值变成 `prompt=8260391, cached=5443627, prefill_s=1457.42, decode_s=2851.45, drafted=178502, accepted=124381, C=185305`。断言：
   - 状态依次经过 `idle → prefill → decode → done`，`t=17.4` 仍是 `done`，`t=17.6` 是 `idle`。
   - 结束后 `last == {prompt_tokens: 58, cached_tokens: 0, completion_tokens: 200, decode_tps ≈ 59.69, prefill_tps ≈ 703.9, acceptance_rate ≈ 0.678, context_used: 258, ttft_s ≈ 0.1}`。
   - 解码中 `decode.output_tokens` 等于已增加的 `C`；`decode.ttft_s ≈ 0.1`；`round == {requests: 0, running: 1, …, exact: True, active: True}`。
   - 结束后 `round.requests == 1`、`round.running == 0`、`round.output_tokens == 200`、`round.decode_tps_avg ≈ 59.69`、`round.exact is True`。
   - 假 `usage` 每次成功读数都收到了对应的 `totals`。
2. **解码速度**：进入解码后 `C` 每 0.1 秒加 6（即 60 tok/s）。`el = 0.2` 时 `tps = 12 ÷ 0.5 = 24`；`el = 1.0` 时 `tps ≈ 60`；`el ≥ 2.5` 后 `tps ≈ 60`。`tps_avg` 在 `el < 0.5` 时为 `None`，之后 `≈ 60`。`tps_peak` 在 `el ≤ 1.0` 时为 0，之后等于出现过的最大 `tps`。之后 `C` 停止增长 3 秒，`tps` 降到 0，`tps_peak` 不变。
3. **首字的精确值**：场景 1 结束后传 `metrics`：先传过 `{ttft_sum: 100.0, ttft_count: 97}` 作基线，结束后传 `{ttft_sum: 100.0824, ttft_count: 98}`，`last.ttft_s ≈ 0.0824`。
4. **离线**：成功几次后连续传 `None`：第 1、2 次返回的快照和上一次内容相同；第 3 次 `state == "offline"`、`offline_s` 等于从第 1 次失败算起的秒数、`decode`/`prefill`/`round` 为 `None`、`last` 保留。恢复后 `state == "idle"`、`offline_s is None`。一上来就传 `None`：直接 `offline`。离线期间不调用 `usage.update`。
5. **模型重启**：`R`、`C` 变小后不产生“请求结束”，`last` 不变，不抛异常，`round` 为 `None`。
6. **一轮**：
   - 顺序两个请求，间隔 5 秒：第二个到达后 `round.requests == 1`、`running == 1`；都结束后 `requests == 2`、`exact is True`、`decode_tps_avg == 两次输出之和 ÷ 两次 Δdecode_seconds 之和`。
   - 结束 61 秒后（期间每秒 `feed` 一次空闲读数）`round.active is False`；这时再来请求，新开一轮（`requests == 0`、`output_tokens` 从 0 算）。
   - 结束后 59 秒来的请求仍在同一轮。
   - “上一个结束、下一个到达”在同一次读数里（`R` 加 1，`requests_running` 仍为 1）：仍是同一轮，`exact` 仍为 `True`，第一个请求的 `last.completion_tokens` 正确。
7. **并发**：两个请求先后到达同时在跑（`running=2, dec=2`）：`round.exact is False`；`decode_tps_avg` 在解码时长 ≤ 0.5 秒时为 `None`，之后 = `(C − 起点的 C) ÷ 解码时长`；`decode.ttft_s is None`；一个先结束时状态仍是 `decode`，不进入 `done`；都结束后才是 `done`，且两个请求的 `completion_tokens` 之和（两次 `last` 相加）等于本轮 `output_tokens`。
8. **外挂 · 预填充**（`hook` 为 `ok`）：一条流 `{"id": 1, "phase": "prefill", "prompt": 24615, "cached": 0, "filled": 0}`，`t=0` 到达，`filled` 在 `t=0.9` 变 2048、`t=1.8` 变 4096、`t=2.7` 变 6144（中间每 0.1 秒 `feed` 一次，值不变）。断言：`t=0.5` 时 `tps is None`、`remaining_s ≈ max(0, 24615/2300 − 0.5)`、`est_s ≈ 10.70`；`t=0.9` 时 `tps ≈ 2275.6`；`t=2.7` 时 `tps ≈ 2275.6`、`filled_tokens == 6144`、`remaining_s ≈ (24615 − 6144) ÷ 2275.6`、`elapsed_s ≈ 2.7`、`prompt_tokens == 24615`、`cached_tokens == 0`；`context_used == 24615`。两条预填充流时各字段是两条之和，`tps` 是两条速度之和。
9. **外挂 · 缓存未命中**：一轮里第一个请求（提示 40120，命中 39400）结束后，第二个请求预填充：外挂行 `prompt=41230, cached=0` → `cache_miss is True`；换成 `cached=39000` → `False`；换成 `prompt=5000, cached=0`（不到上一个的一半）→ `False`；并发的一轮里 → `False`；第一个请求提示只有 3000 → `False`。
10. **外挂 · 解码**：两行 `decode`（`output` 312 和 100）加一行 `prefill`（`prompt` 61000）：`decode.output_tokens == 412`、`context_used == 61000`、快照里 `prefill` 不为 `None`、`state == "decode"`、`lanes == {max: 5, decoding: 2, prefilling: 1, waiting: 取自 metrics}`。
11. **外挂失效 · 预填充**：`pre=1`、没有 `tfpanel`：`hook == "missing"`；`prefill.elapsed_s` 从 `pre` 变成 1 的那次算起；传 `metrics={"waiting": 0, "kv_usage": [0.093899, 0.0], …}`、`context_length=262144` 时 `prefill.prompt_tokens == 24615`、`context_used == 24615`；`cached_tokens`、`filled_tokens`、`tps`、`remaining_s`、`est_s` 都是 `None`。
12. **平均预填充速度的滚动更新**：一个请求结束（`Δprompt − Δcached = 20000`、`Δprefill_s = 8.0`，即 2500 tok/s）后，下一个预填充的 `est_s` 用 `0.7 × 2300 + 0.3 × 2500 = 2360`；新算不足 2048 的请求不更新它。
13. **健壮性**：`health` 是 `{"ok": True}`（什么都缺）不抛异常；`usage.update` 抛异常不影响 `feed`；返回的快照能 `json.dumps`；改动返回的字典后再 `feed`，结果不受影响；快照的顶层键和 `fixtures/idle.json` 的顶层键集合相同（`fixtures/idle.json` 存在时才比，不存在就跳过这一条）。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_collector -v
python3 -c "
import json
from panel.config import Config
from panel.collector import Collector
c = Collector(Config())
print(json.dumps(c.feed(1.0, {'ok': True, 'requests_total': 3, 'completion_tokens_total': 10, 'streams': {'decoding': 0, 'prefilling': 0, 'max': 5}, 'context_length': 262144}), ensure_ascii=False))
"
```
