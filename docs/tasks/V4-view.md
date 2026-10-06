# 任务 V4：界面——估算版预填充画面、标出当前引擎、离线文字

先读 `AGENTS.md`，再读接口约定 `docs/tasks/V-contracts.md` 的第 5、7 节。本任务改五个文件：`panel/view.py`、`panel/viewmodel.py`、`panel/render.py`、`panel/tests/test_viewmodel.py`、`panel/tests/test_render.py`。不要改别的文件（`fixtures/` 也不要改）。

## 背景

副屏程序要同时支持 TensorFold 和 vLLM 两种推理引擎。指标快照为此多了两个字段，样例已经改好：顶层 `engine`（`"tensorfold"`、`"vllm"` 或 `None`），`prefill` 里的 `estimated`（`True` 表示进度、速度、剩余时间是按时间估算的，只有 vLLM 会这样）。新增了三个样例：`fixtures/prefill-est.json`、`fixtures/idle-vllm.json`、`fixtures/offline-vllm.json`。

界面跟着改四处，效果以原型 `docs/dashboard-prototype.html` 为准（对应画面：`?kiosk=1&demo=prefill-est`，以及 `demo=idle`、`demo=offline` 各加不加 `&engine=vllm`）。

同时有别的执行者在改 `panel/` 下的其他文件（`config.py`、`sources.py`、`collector.py`、`usage.py`、`engine.py`）。所以检查命令只跑下面写的测试模块，不要跑全部测试；在 Spark 上的检查如果因为这几个文件报错（例如语法错误），等一分钟重新同步再跑。

## 第一步：`panel/view.py`

`View` 在 `pill` 后面加一个字段：

```python
    pill_kind: str = "exact"     # pill 为 True 时画哪一种标记："exact" 实心的“精确” | "avg" 琥珀色描边的“近期平均”
```

## 第二步：`panel/viewmodel.py`

1. **模型名只显示最后一段。** 加一个方法：快照的 `model` 是非空字符串就用它，否则用 `config.model_name`；取最后一个 `/` 后面的部分，那部分是空的就用整个名字。今日统计和离线画面里显示模型名的地方都用它（`Qwen/Qwen3.8-Flash-Next` 显示成 `Qwen3.8-Flash-Next`）。
2. **引擎名。** 快照的 `engine` 是 `"tensorfold"` 时引擎名是 `TensorFold`，`"vllm"` 时是 `vLLM`，其余（`None`、没有这个键、别的值）没有引擎名。
3. **今日统计（`_today`）的状态条。** “外挂未生效”的条件改成：`hook == "missing"` 并且 `engine != "vllm"`。
   - 要写“外挂未生效”时：`strip_left` 只写模型名（不写引擎名），`strip_right` 照旧是 `外挂未生效 · 内存 …`。
   - 不写“外挂未生效”时：有引擎名则 `strip_left` 是 `模型名 · 引擎名`（例如 `Qwen3.8-Flash-Next · vLLM`，中间是空格、间隔号 `·`、空格），没有引擎名就只写模型名；`strip_right` 只有内存。
4. **离线（`_offline`）的状态条右边。** 有引擎名时是 `上次模型 模型名 · 引擎名`，没有时是 `上次模型 模型名`。
5. **估算版预填充（`_prefill` 里接管画面之后、外挂好用的那个分支）。** `prefill.get("estimated")` 为真时，和现在相比只有三处不同，其余（标题、主数字取 `tps`、圆弧、右侧三栏、状态条、缓存未命中）都照旧：
   - `view.pill = True`，`view.pill_kind = "avg"`。
   - 进度条下的文字开头是 `已算约 `（现在是 `已算 `）。
   - 剩余秒数不按速度算，固定用 `max(1, ceil(est_s - elapsed_s))`。

   `estimated` 不为真时 `pill`、`pill_kind` 保持默认值，文字照旧。

`panel/tests/test_viewmodel.py`：

- 现有测试里有三处断言因为状态条多了引擎名而必须改，只改这三处，其余一行不动：
  - `TestOffline.test_offline`：`"上次模型 Qwen3.8-Flash-Next"` → `"上次模型 Qwen3.8-Flash-Next · TensorFold"`
  - `TestIdle.test_idle`：`view.strip_left` 的期望 `"Qwen3.8-Flash-Next"` → `"Qwen3.8-Flash-Next · TensorFold"`
  - `test_back_to_today_after_round`：同上
- 文件末尾（`if __name__` 之前）加测试类 `TestEngineLabel(FixtureCase)`：
  - `idle-vllm`：`strip_left == "Qwen3.8-Flash-Next · vLLM"`，`strip_right` 的纯文字是 `"内存 94.2 / 121 GB"`，`lanes.max == 4`。
  - `offline-vllm`：`strip_left == ""`，`strip_right` 的纯文字是 `"上次模型 Qwen3.8-Flash-Next · vLLM"`。
  - `idle-nohook`：`strip_left == "Qwen3.8-Flash-Next"`（写了“外挂未生效”就不写引擎名）。
  - `idle` 把 `engine` 改成 `None`：`strip_left == "Qwen3.8-Flash-Next"`；`offline` 把 `engine` 改成 `None`：右边是 `"上次模型 Qwen3.8-Flash-Next"`。
  - `idle-vllm` 把 `hook` 改成 `"missing"`：`strip_left == "Qwen3.8-Flash-Next · vLLM"`，`strip_right` 的纯文字是 `"内存 94.2 / 121 GB"`（vLLM 不写“外挂未生效”）。
  - `idle` 把 `model` 改成 `None`：`strip_left == "Qwen3.8-Flash-Next · TensorFold"`（用配置里的模型名）。
- 再加测试类 `TestPrefillEstimated(FixtureCase)`：
  - `prefill-est`：`state_name == "预填充中"`；`cap == "预填充速度"`，`unit == "tok/s"`；`pill is True`，`pill_kind == "avg"`；`big_int == "2200"`，`big_size == "four"`；`arc == "prefill"`，`scale == "prefill"`，`arc_target` 约 0.7333；`bar.kind == "prog"`，`bar.frac` 约 0.3696，`bar.text` 的纯文字是 `"已算约 14.7K / 39.9K"`，加粗的只有 `"14.7K"`；`strip_right` 的纯文字是 `"新算 39.9K tok"`；三栏是 `("缓存命中", "0", "%", "0 / 39.9K")`、`("已等待", "6.7", "s", "剩余约 12 s")`、`("内存", "94.4", "GB", "共 121 GB")`；`lanes.max == 4`，`lanes.prefilling == 1`。
  - `prefill-est` 把 `round` 换成 `fixtures/prefill-miss.json` 里的 `round`（一轮模式）：`strip_right` 的纯文字是 `"已用时 6.7 s · 缓存命中 0% · 剩余约 12 s"`，三栏的标签是 `本轮请求`、`累计输出`、`本轮平均`。
  - `prefill-est` 把 `prefill` 换成 `dict(原来的, elapsed_s=30.0, filled_tokens=39485, remaining_s=0.0)`：第二栏是 `("已等待", "30.0", "s", "剩余约 1 s")`，`bar.frac` 约 0.99。
  - TensorFold 的画面不变：`prefill` 样例 `pill is False`、`pill_kind == "exact"`、`bar.text` 的纯文字是 `"已算 53.2K / 61.2K"`；`done` 样例 `pill is True`、`pill_kind == "exact"`。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_viewmodel panel.tests.test_anim panel.tests.test_fixtures 2>&1 | tail -1
git diff --numstat -- panel/tests/test_viewmodel.py
```

第一条应输出 `OK`；第二条的第二列（删除的行数）应是 `3`。

## 第三步：`panel/render.py`

1. `_center` 里离线画面的第二行 `"等待 TensorFold 响应…"` 改成 `"等待引擎响应…"`。
2. `_cap_line` 的标记：文字由 `view.pill_kind` 决定，`"avg"` 是 `近期平均`，其余是 `精确`；标记的宽度按实际文字算（现在写死按“精确”算）。三种画法：
   - `view.muted` 为真：照现在的灰色描边画法，文字用上面决定的那个。
   - 否则 `pill_kind == "avg"`：不填底色；画 1 宽的内侧描边，位置和尺寸与灰色描边那种相同（`_rrect(cr, px + 0.5, 119.5, w_pill - 1, 17, 8.5)`），颜色是 `AMBER`、不透明度 0.5；文字颜色 `AMBER`。
   - 否则：照现在的实心画法。

`panel/tests/test_render.py`（这个文件只能在 Spark 上跑）在 `DrawPixels` 里加一个测试 `test_avg_pill`：在 960×640 的图上取 `y = 256` 这一行、`x` 从 380 到 529 的像素，`prefill-est` 至少有一个像素和 `AMBER` 的每个分量相差不超过 12（“近期平均”四个字是琥珀色的）；`prefill` 一个都没有（TensorFold 的预填充画面没有这个标记）。现有测试一行不动。

把代码同步到 Spark 的临时目录跑：

```sh
cd /Users/kris/projects/tensorfold-panel
TFPANEL_DEST=/tmp/tfpanel-v4 scripts/sync.sh
ssh spark 'cd /tmp/tfpanel-v4 && python3 -m unittest panel.tests.test_render 2>&1 | tail -1'
ssh spark 'cd /tmp/tfpanel-v4 && python3 scripts/offscreen.py --out /tmp/tfpanel-v4/shots prefill-est idle idle-vllm offline offline-vllm prefill done'
```

第二条应输出 `OK`；第三条应打印 7 个 PNG 的路径。

## 最后一步：收尾检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_viewmodel panel.tests.test_anim panel.tests.test_fixtures 2>&1 | tail -1
TFPANEL_DEST=/tmp/tfpanel-v4 scripts/sync.sh
ssh spark 'cd /tmp/tfpanel-v4 && python3 -m unittest panel.tests.test_render panel.tests.test_viewmodel 2>&1 | tail -1'
ssh spark 'cd /tmp/tfpanel-v4 && python3 scripts/offscreen.py --out /tmp/tfpanel-v4/shots prefill-est idle idle-vllm offline offline-vllm prefill done | wc -l'
grep -c "TensorFold" panel/render.py
```

通过的标准：第一条和第三条输出 `OK`；第四条输出 `7`；第五条输出 `0`。`/tmp/tfpanel-v4` 留着不要删，编排者要看里面的图。全部通过后最后一行输出 `DONE`。
