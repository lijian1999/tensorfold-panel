# 任务 F：视图模型（viewmodel）

先读 `AGENTS.md`，再读 `docs/tasks/00-contracts.md` 的第 1、2、3、7 节，和 `docs/design.md` 的“副屏界面设计”“外挂的安装、自检与降级”两节。然后读原型 `docs/dashboard-prototype.html` 里的 `function view(t, st)`（从 `// ---------- 视图模型 ----------` 到 `// ---------- 写入 DOM` 之间）：本任务就是把这个函数搬成 Python，输入从原型的模拟状态换成指标快照。

本任务只用标准库，全部在 MacBook Pro 上完成，不需要 `ssh spark`。`panel/config.py`、`panel/fmt.py`、`panel/scale.py`、`panel/view.py` 和 `fixtures/*.json` 已经有了，直接用，不要改它们。

## 交付文件

1. `panel/viewmodel.py`
2. `panel/tests/test_viewmodel.py`

不要创建或修改别的文件。

## 接口

```python
class ViewModel:
    def __init__(self, config: Config)
    def update(self, snapshot: dict, now: float) -> View
```

`snapshot` 是指标快照（`fixtures/*.json` 那种格式）。`ViewModel` 有少量记忆（见“记忆”一节），所以是类。`update` 不读时钟、不做 I/O。快照里任何字段缺失或为 `None` 都不能抛异常（缺什么就显示 `—` 或空）。

## 写法约定

下面用 `**粗体**` 表示 `style="strong"` 的 `Seg`，用 `!!文字!!` 表示 `style="warn"` 的 `Seg`，其余是 `normal`。例如“内存 **94.2** / 121 GB”就是 `[Seg("内存 "), Seg("94.2", "strong"), Seg(" / 121 GB")]`。相邻的同样式文字合成一个 `Seg`。

常用片段：

- `内存文字` = “内存 **{used_gb:.1f}** / {int(total_gb)} GB”（`int` 向下取整：121.6 → 121）。
- `内存卡` = `Card("内存", f"{used_gb:.1f}", "GB", f"共 {int(total_gb)} GB")`。
- `一轮模式` = 快照有 `round`、`round.active` 为真、`round.requests + round.running >= 2`。
- `本轮平均` = `round.decode_tps_avg`（可能为 `None`）。
- `一轮三栏`：
  1. `Card("本轮请求", str(requests + running), "次", "用时 " + dur_fmt(round.elapsed_s))`
  2. `Card("累计输出", tok_fmt(round.output_tokens), "tok", "")`
  3. 有本轮平均：`Card("本轮平均", f"{avg:.1f}", "", "tok/s")`；没有：`Card("本轮平均", "—", "", "", pending=True)`
- `上下文条(used)` = `Bar("ctx", frac, level, 文字)`：`frac = min(1, used / context_max)`（`context_max` 为 0 或缺失时 `frac = 0`）；`level`：`frac >= 0.95` 为 `"full"`，`>= 0.8` 为 `"warn"`，否则 `"normal"`；文字 “上下文 **{tok_fmt(min(used, context_max))}** / {tok_fmt(context_max)}”。
- `lanes` 每个画面都按快照的 `lanes` 填（`max`、`decoding`、`prefilling`、`waiting`），只有离线时 `offline=True` 且三个数为 0。

## 两种“休息画面”

**今日统计**（`今日()`）：

- `strip_left` = 模型名；`strip_right` = `内存文字`，`hook == "missing"` 时前面加 “!!外挂未生效!! · ”。
- `cap` = “今日费用”，`unit` = “美元”（`config.currency` 不是 `$` 时 `unit` 用 `config.currency`）。
- 主数字 = `cost_fmt(today.cost, config.currency)` 在小数点处拆开：`big_int = "$0"`、`big_dec = ".60"`（没有小数点时 `big_dec = ""`）；`big_whole = True`；`big_size = "cost"`。
- `arc = "blank"`、`arc_target = None`、`ghost = None`、`muted = False`、`pill = False`。
- `bar` = `Bar("note", 0.0, "normal", [Seg(date_label(today.date) + " · 太平洋时间")])`（`config.timezone` 不是 `America/Los_Angeles` 时把“太平洋时间”换成时区名）。
- 三栏：
  1. `Card("今日输入", tok_fmt(prompt_tokens), "tok", f"缓存命中 {pct(cached_tokens, prompt_tokens)}%")`
  2. `Card("今日输出", tok_fmt(completion_tokens), "tok", "")`
  3. `Card("今日请求", str(requests), "次", f"上次 {last.decode_tps:.1f} tok/s")`；没有 `last` 或 `last.decode_tps` 为空时 `foot = ""`

**本轮统计**（`本轮()`，灰色）：

- `muted = True`；`arc = "rest"`；`cap` = “本轮平均”，`unit` = “tok/s”；`pill` = 有本轮平均且 `round.exact`。
- 主数字：有本轮平均时 `split1(avg)`，否则 `big_int = "—"`、`big_dec = ""`。`big_whole = False`、`big_size = "normal"`。
- `ghost` = 有本轮平均时 `v2f(avg, "decode")`，否则 `None`；`arc_target` 同 `ghost`。
- 三栏 = `一轮三栏`；`bar` = `上下文条(snapshot.context_used)`；`strip_left = ""`。

## 各状态

| `state` | 画面 |
| --- | --- |
| `offline` | 见下 |
| `idle` | `state_name` = “空闲”。`一轮模式` → `本轮()`，`strip_right` = `内存文字`；否则 `今日()` |
| `prefill` | 见下 |
| `decode` | 见下 |
| `done` | 见下 |

**离线**：`state_name` = “引擎离线”；`strip_right` = “上次模型 {模型名}”（整段 normal）；`lanes.offline = True`；`arc = "off"`；`cap`、`unit`、`big_int`、`big_dec` 为空；`bar = None`；三栏：

1. `Card("今日费用", cost_fmt(today.cost, config.currency), "", "")`
2. 已离线：`secs = floor(offline_s)`；`< 60` 时 `Card("已离线", str(secs), "秒", "")`，否则 `Card("已离线", str(secs // 60), "分钟", "")`
3. `内存卡`

**预填充**（`state_name` = “预填充中”，`strip_left = ""`）。记 `pf = snapshot.prefill`，`el = pf.elapsed_s`，`短 = config.prefill_short_s`：

- 是否接管画面 `take`：`hook == "ok"` 时 `el >= 短` 或 `pf.est_s >= 短` 或 `pf.cache_miss`；`hook == "missing"` 时 `el >= 短`。一旦接管，在离开 `prefill` 状态之前一直算接管（见“记忆”）。
- **不接管（短预填充）**：画面保持预填充之前的样子：记忆里的休息画面是 `today`，或者现在不是 `一轮模式` → `今日()`；否则 → `本轮()`。然后覆盖三项：`state_name` = “预填充中”、`strip_left = ""`、`strip_right` = “已用时 **{el:.1f}** s”。
- **接管，`hook == "ok"`**：
  - `P`、`K`、`F` = `pf.prompt_tokens`、`pf.cached_tokens`、`pf.filled_tokens`，`N = P − K`，`hit = pct(K, P)`。
  - `cap` = “预填充速度”，`unit` = “tok/s”；`big_int` = 有 `pf.tps` 时 `str(js_round(pf.tps))`，否则 “—”；`big_dec = ""`；`big_size = "four"`。
  - `arc = "prefill"`、`scale = "prefill"`、`arc_target = v2f(pf.tps or 0, "prefill")`。
  - `bar` = `Bar("prog", F / P（P 为 0 时 0）, "normal", “已算 **{tok_fmt(F)}** / {tok_fmt(P)}”)`。
  - `elTxt` = `el < 100` 时 `f"{el:.1f}"`，否则 `str(floor(el))`；`rem = max(1, ceil(pf.remaining_s))`。
  - `一轮模式`：三栏 = `一轮三栏`；`strip_right` = “已用时 **{elTxt}** s · 缓存命中 **{hit}%** · 剩余约 **{rem}** s”，`pf.cache_miss` 时中间一段换成 “!!缓存未命中!!”，即 “已用时 **{elTxt}** s · !!缓存未命中!! · 剩余约 **{rem}** s”。
  - 否则：三栏 = `Card("缓存命中", str(hit), "%", f"{tok_fmt(K)} / {tok_fmt(P)}")`、`Card("已等待", elTxt, "s", f"剩余约 {rem} s")`、`内存卡`；`strip_right` = “新算 **{tok_fmt(N)}** tok”。
- **接管，`hook == "missing"`（降级）**：
  - `cap` = “已用时”，`unit` = “秒”，`big_whole = True`；`el < 10` 时主数字 `split1(el)`，否则 `big_int = str(floor(el))`、`big_dec = ""`。
  - `arc = "rest"`、`scale = "decode"`、`arc_target = None`；`ghost` = 有 `last.decode_tps` 时 `v2f(last.decode_tps, "decode")`，否则 `None`；`muted = False`。
  - `strip_right` = “提示较长，可能需要几秒”；`bar` = `上下文条(snapshot.context_used)`。
  - 三栏：`一轮模式` → `一轮三栏`；否则 `Card("输出", "—", "", "", pending=True)`、`Card("首字", "—", "", "等待首个 token", pending=True)`、`内存卡`。

**解码**：`state_name` = “解码中”；`cap` = “解码速度”，`unit` = “tok/s”；`big_value = decode.tps`、`big_int = str(js_round(decode.tps))`、`big_dec = ""`；`arc = "value"`、`arc_target = v2f(decode.tps, "decode")`；`bar` = `上下文条(snapshot.context_used)`。

- `strip_right`：`lanes.decoding + lanes.prefilling >= 2` 或 `lanes.waiting > 0` 时，依次用 “ · ” 连接：“解码 **{decoding}**”、“预填充 **{prefilling}**”（为 0 不写）、“排队 **{waiting}**”（为 0 不写）、`内存文字`。否则：有 `decode.ttft_s` 时 “首字 **{ttft:.2f}** s · ” 加 `内存文字`，没有时只有 `内存文字`。
- 三栏：`一轮模式` → `一轮三栏`；否则：
  1. `Card("输出", tok_fmt(decode.output_tokens), "tok", "")`
  2. 有 `decode.tps_avg`：`Card("平均", f"{tps_avg:.1f}", "", "tok/s")`；没有：`Card("平均", "—", "", "", pending=True)`
  3. `decode.tps_peak > 0`：`Card("峰值", str(js_round(tps_peak)), "tok/s", "")`；否则 `Card("峰值", "—", "", "", pending=True)`

**完成**：`state_name` = “完成”。

- `一轮模式`：`本轮()`，然后 `strip_right` = `round.exact` 且有 `last.ttft_s` 时 “首字 **{ttft:.2f}** s”，否则 `内存文字`。
- 否则（单个请求，用 `last`）：`cap` = “平均速度”，`unit` = “tok/s”，`pill = True`；主数字 `split1(last.decode_tps)`（为空时 “—”）；`arc = "value"`、`arc_target = v2f(last.decode_tps, "decode")`；`bar` = `上下文条(last.context_used)`；`strip_right` = 有 `last.ttft_s` 时 “首字 **{ttft:.2f}** s”，否则 `内存文字`；三栏：
  1. `Card("输出", tok_fmt(completion_tokens), "tok", f"提示 {tok_fmt(prompt_tokens)} tok")`
  2. `Card("缓存命中", str(pct(cached_tokens, prompt_tokens)), "%", f"{tok_fmt(cached_tokens)} tok")`
  3. 有 `acceptance_rate`：`Card("接受率", str(js_round(acceptance_rate * 100)), "%", "")`；没有：`Card("接受率", "—", "", "", pending=True)`
- 没有 `last`（不该发生）：按 `今日()` 画，`state_name` 仍是“完成”。

没写到的字段保持 `View` 的默认值（例如 `scale` 默认 `"decode"`、`pill` 默认 `False`）。

## 记忆

`ViewModel` 在两次 `update` 之间只记这些：

1. **休息画面是哪种**（初始 `today`）：每次 `update` 结束时，`state` 是 `idle` 或 `offline` → `idle` 且 `一轮模式` 时记 `round`，否则记 `today`；`state` 是 `done` 或 `decode` → 记 `round`；`prefill` 不改。
2. **接管标记**：`state == "prefill"` 且 `take` 为真时置位；`state != "prefill"` 时清除。
3. **慢淡入**：上一次的 `state` 是 `done`、这一次是 `idle` 时，这一次返回的 `View.slow_fade = True`，其余时候 `False`。
4. **调暗**：记下“今日统计开始显示的时刻”：`state == "idle"` 且画的是 `今日()` 时，如果还没记就记 `now`；其他情况清掉。记了且 `now − 那个时刻 >= config.dim_after_s` 时 `View.dim = 0.4`，否则 `1.0`。离线画面不调暗。

## 测试要求（`panel/tests/test_viewmodel.py`）

写两个辅助函数：`plain(segs)` 把 `Seg` 列表拼成纯文字；`marks(segs)` 返回 `[(text, style)]` 里 `style != "normal"` 的那些。用 `json.load` 读 `fixtures/` 里的样例（用 `pathlib` 从测试文件位置找仓库根目录）。每个样例用**新建的** `ViewModel(Config())`，`now=100.0`。

### 14 个样例的期望画面

下面每个样例都要断言列出的全部内容（`plain` 比文字，`marks` 比样式；浮点用 `assertAlmostEqual(places=3)`）。表里没写的字段不用断言。卡片写成 `标签 | 数值 | 单位 | 脚注`。

| 样例 | 期望 |
| --- | --- |
| `offline` | `state_name` 引擎离线；`strip_left` 空；`strip_right` “上次模型 Qwen3.8-Flash-Next”，没有非 normal 的段；`lanes.offline` 真；`arc` off；`bar` 为 `None`；`big_int` 空；卡片 `今日费用 \| $0.60 \| \| `、`已离线 \| 44 \| 秒 \| `、`内存 \| 9.3 \| GB \| 共 121 GB` |
| `idle` | `state_name` 空闲；`strip_left` Qwen3.8-Flash-Next；`strip_right` “内存 94.2 / 121 GB”，`marks == [("94.2", "strong")]`；`cap` 今日费用；`unit` 美元；`big_int` `$0`；`big_dec` `.60`；`big_whole` 真；`big_size` cost；`arc` blank；`arc_target` 为 `None`；`bar.kind` note，`plain(bar.text)` “10月3日 · 太平洋时间”；`muted` 假；`dim` 1.0；卡片 `今日输入 \| 8.26M \| tok \| 缓存命中 66%`、`今日输出 \| 185K \| tok \| `、`今日请求 \| 98 \| 次 \| 上次 63.6 tok/s` |
| `idle-nohook` | 同 `idle`，只有 `strip_right` 是 “外挂未生效 · 内存 94.2 / 121 GB”，`marks == [("外挂未生效", "warn"), ("94.2", "strong")]` |
| `prefill` | `state_name` 预填充中；`strip_left` 空；`strip_right` “新算 20.2K tok”，`marks == [("20.2K", "strong")]`；`lanes.prefilling` 1；`cap` 预填充速度；`unit` tok/s；`big_int` 2412；`big_dec` 空；`big_size` four；`arc` prefill；`scale` prefill；`arc_target` ≈ 0.804；`bar.kind` prog，`bar.frac` ≈ 0.8701，`plain(bar.text)` “已算 53.2K / 61.2K”，`marks(bar.text) == [("53.2K", "strong")]`；卡片 `缓存命中 \| 67 \| % \| 41.0K / 61.2K`、`已等待 \| 5.7 \| s \| 剩余约 4 s`、`内存 \| 95.1 \| GB \| 共 121 GB` |
| `prefill-fresh` | `strip_right` “新算 24.6K tok”；`big_int` 2354；`bar.frac` ≈ 0.5824，文字 “已算 14.3K / 24.6K”；卡片 `缓存命中 \| 0 \| % \| 0 / 24.6K`、`已等待 \| 6.7 \| s \| 剩余约 5 s`、`内存 \| 94.4 \| GB \| 共 121 GB` |
| `prefill-miss` | `strip_right` “已用时 5.7 s · 缓存未命中 · 剩余约 13 s”，`marks == [("5.7", "strong"), ("缓存未命中", "warn"), ("13", "strong")]`；`big_int` 2368；`arc` prefill；`bar` 文字 “已算 12.3K / 41.2K”；卡片 `本轮请求 \| 6 \| 次 \| 用时 1 分钟`、`累计输出 \| 1.8K \| tok \| `、`本轮平均 \| 61.8 \| \| tok/s` |
| `prefill-nohook` | `strip_right` “提示较长，可能需要几秒”；`cap` 已用时；`unit` 秒；`big_int` 5；`big_dec` `.6`；`big_whole` 真；`big_size` normal；`arc` rest；`scale` decode；`ghost` ≈ 0.4544；`muted` 假；`bar.kind` ctx，文字 “上下文 24.6K / 262K”，`bar.frac` ≈ 0.0939，`bar.level` normal；卡片 `输出 \| — \| \| `（pending）、`首字 \| — \| \| 等待首个 token`（pending）、`内存 \| 94.4 \| GB \| 共 121 GB` |
| `prefill-short` | `state_name` 预填充中；`strip_left` 空；`strip_right` “已用时 1.2 s”，`marks == [("1.2", "strong")]`；`lanes.prefilling` 1；其余同 `idle`（`cap` 今日费用、`big_int` `$0`、`arc` blank、三张今日卡片） |
| `decode` | `state_name` 解码中；`strip_right` “首字 0.10 s · 内存 94.2 / 121 GB”，`marks == [("0.10", "strong"), ("94.2", "strong")]`；`lanes.decoding` 1；`cap` 解码速度；`unit` tok/s；`big_int` 74；`big_dec` 空；`big_value` ≈ 74.3；`arc` value；`arc_target` ≈ 0.4972；`bar.kind` ctx，文字 “上下文 441 / 262K”，`bar.level` normal；卡片 `输出 \| 383 \| tok \| `、`平均 \| 69.7 \| \| tok/s`、`峰值 \| 79 \| tok/s \| ` |
| `decode-multi` | `strip_right` “解码 3 · 预填充 1 · 内存 94.9 / 121 GB”，`marks == [("3", "strong"), ("1", "strong"), ("94.9", "strong")]`；`lanes` 解码 3、预填充 1、排队 0；`big_int` 100；`arc` value；`bar` 文字 “上下文 61.0K / 262K”；卡片 `本轮请求 \| 7 \| 次 \| 用时 46 秒`、`累计输出 \| 1.7K \| tok \| `、`本轮平均 \| 107.6 \| \| tok/s` |
| `decode-ctx-warn` | `strip_right` “首字 0.35 s · 内存 97.9 / 121 GB”；`big_int` 88；`bar.level` warn，`bar.frac` ≈ 0.8392，文字 “上下文 220K / 262K”；卡片 `输出 \| 12.4K \| tok \| `、`平均 \| 87.9 \| \| tok/s`、`峰值 \| 96 \| tok/s \| ` |
| `queue` | `strip_right` “解码 5 · 排队 2 · 内存 94.9 / 121 GB”；`lanes` 解码 5、预填充 0、排队 2；`big_int` 136；`bar` 文字 “上下文 9.5K / 262K”；卡片 `本轮请求 \| 9 \| 次 \| 用时 17 秒`、`累计输出 \| 1.4K \| tok \| `、`本轮平均 \| 128.2 \| \| tok/s` |
| `done` | `state_name` 完成；`strip_right` “首字 0.09 s”，`marks == [("0.09", "strong")]`；`cap` 平均速度；`unit` tok/s；`pill` 真；`big_int` 97；`big_dec` `.2`；`big_whole` 假；`big_value` 为 `None`；`arc` value；`arc_target` ≈ 0.5888；`muted` 假；`bar` 文字 “上下文 696 / 262K”；卡片 `输出 \| 600 \| tok \| 提示 96 tok`、`缓存命中 \| 0 \| % \| 0 tok`、`接受率 \| 81 \| % \| ` |
| `round-rest` | `state_name` 空闲；`strip_left` 空；`strip_right` “内存 94.2 / 121 GB”；`cap` 本轮平均；`unit` tok/s；`pill` 真；`big_int` 62；`big_dec` `.3`；`muted` 真；`arc` rest；`ghost` ≈ 0.4492；`bar` 文字 “上下文 14.5K / 262K”；卡片 `本轮请求 \| 7 \| 次 \| 用时 2 分钟`、`累计输出 \| 2.3K \| tok \| `、`本轮平均 \| 62.3 \| \| tok/s` |

每个样例再断言：`len(view.cards) == 3`、`View.from_dict(view.to_dict()) == view`。

### 其他要测的

1. **记忆 · 短预填充保持画面**：同一个 `ViewModel` 先 `update(round-rest)`，再 `update(prefill-short 改成 round = {requests: 7, running: 1, output_tokens: 2345, decode_tps_avg: 62.3, exact: true, elapsed_s: 140, active: true})`：画面是本轮统计（`cap` 本轮平均、`muted` 真、`本轮请求` 卡片数值 8），`state_name` 预填充中，`strip_right` “已用时 1.2 s”。先 `update(idle)` 再 `update(同一份改过的 prefill-short)`：画面是今日统计。
2. **记忆 · 接管后不退回**：`update(prefill)`（接管）之后，再 `update` 一份 `est_s = 0.5`、`elapsed_s = 1.0` 的 `prefill`：仍是预填充画面（`cap` 预填充速度）。中间插一次 `update(idle)` 再来同样的短预填充：不接管。
3. **慢淡入**：`update(done)` 后 `update(idle)`：`slow_fade` 真；再 `update(idle)`：假；`update(decode)` 后 `update(idle)`：假。
4. **调暗**：`Config(dim_after_s=1800)`。`update(idle, now=0)`：`dim == 1.0`；`update(idle, now=1799)`：1.0；`update(idle, now=1800)`：0.4；`update(decode, now=1801)`：1.0；`update(idle, now=1802)`：1.0（重新计时）。`round-rest` 画面和离线画面不调暗。
5. **缺数据**：`idle` 样例把 `last` 设为 `None`：第三张卡片 `foot == ""`。`decode` 样例把 `decode.tps_avg` 设为 `None`、`tps_peak` 设为 0、`ttft_s` 设为 `None`：平均和峰值卡片是 `—` 且 `pending`，`strip_right` 是 “内存 94.2 / 121 GB”。`done` 样例把 `last.acceptance_rate` 设为 `None`：接受率卡片 `—` 且 `pending`。`prefill` 样例把 `prefill.tps` 设为 `None`：`big_int == "—"`、`arc_target == 0`。`round-rest` 样例把 `round.decode_tps_avg` 设为 `None`：`big_int == "—"`、`pill` 假、`ghost` 为 `None`。
6. **上下文条变色**：`decode` 样例 `context_used` 设为 250000：`bar.level == "full"`；设为 300000：`bar.frac == 1.0`、文字 “上下文 262K / 262K”。
7. **离线超过一分钟**：`offline` 样例 `offline_s = 185`：卡片 `已离线 | 3 | 分钟 | `。
8. **一轮里完成**：`done` 样例把 `round` 改成 `{requests: 3, running: 0, output_tokens: 900, decode_tps_avg: 70.0, exact: true, elapsed_s: 30, active: true}`：画面是本轮统计（`muted` 真、`cap` 本轮平均、`pill` 真），`state_name` 完成，`strip_right` “首字 0.09 s”；再把 `exact` 改成 `false`：`pill` 假，`strip_right` “内存 94.2 / 121 GB”。
9. **一轮结束后回到今日统计**：`round-rest` 样例把 `round.active` 改成 `false`：画面是今日统计（`cap` 今日费用、`strip_left` 是模型名）。
10. **健壮性**：`update({}, 0.0)` 不抛异常并返回 `View`（3 张卡片）；`update({"state": "prefill"}, 0.0)`、`update({"state": "decode"}, 0.0)`、`update({"state": "done"}, 0.0)`、`update({"state": "offline"}, 0.0)` 都不抛异常。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_viewmodel -v
python3 -c "
import json, glob
from panel.config import Config
from panel.viewmodel import ViewModel
for f in sorted(glob.glob('fixtures/*.json')):
    v = ViewModel(Config()).update(json.load(open(f)), 100.0)
    print(f.split('/')[-1].ljust(24), v.state_name, '|', v.cap, '|', v.big_int + v.big_dec, '|', ''.join(s.text for s in v.strip_right), '|', ' / '.join(c.label + ' ' + c.value + c.unit for c in v.cards))
"
```
