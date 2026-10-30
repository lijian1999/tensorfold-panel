# 任务 O2：按模型记账、模型加载中状态

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（第 3、5 节和第 8 节，尤其 8.4～8.6），以及设计文档 `docs/design-mac.md` 的“费用单价”“时区”两节。本任务只改这五个文件：

- `mac/Sources/PanelCore/Config.swift`
- `mac/Sources/PanelCore/Usage.swift`
- `mac/Sources/PanelCore/Collector.swift`
- `mac/Tests/PanelCoreTests/UsageTests.swift`
- `mac/Tests/PanelCoreTests/CollectorTests.swift`

不要改别的文件。

## 背景

今日用量账本（`UsageLedger`）现在只记一个总数，按 `Config` 里的一组单价算费用。不同模型的 API 价格不同，要改成每个模型分开记，按每个模型自己的单价算，没填单价的模型不算费用、单独数出来。引擎适配器在统一读数里给出按模型分开的累计值 `usage_by_model`（各模型加起来等于 `usage_totals`），采集器把它交给账本。

另外，引擎在加载模型时统一读数带 `loading` 字段，采集器要据此给出新状态 `"loading"`。

## 第一步：`Config.swift`

- 删掉 `priceInput`、`priceCached`、`priceOutput` 三个字段。
- 在同一个文件里加 `ModelPrice`（照接口约定 8.5 节），给 `Config` 加 `public var prices: [String: ModelPrice] = [:]`，注释写“按模型的单价（美元 / 百万 token），键是引擎给的模型名原文；没有的模型不算费用”。

## 第二步：`Usage.swift` 按模型记账

### 状态

- `counters`（四项合计）换成 `byModel: [String: [String: Int]]`：模型名 → 四项（键同 `COUNTERS`）。今天的合计是各模型相加。
- 保留 `lastTotals`（四项合计的基线），新增 `lastByModel: [String: [String: Int]]?`：上一次读数里的 `by_model`（键同 `SOURCE_KEYS`），没有就是 nil。
- `config` 改成 `var`，`zone` 改成 `var`。

### `update(_ totals:)`

1. 前面照旧：换日、检查四项合计有效（`valid`）、取 `epoch`。
2. **引擎启动标记变没变**改成：一边有一边没有算变了；两边都有时，两者的数相差超过 30 秒才算变了；两边都没有算没变。（oMLX 的启动时刻是算出来的，程序重启后会差一两秒。）
3. 合计的增量 `delta` 照旧算（第一次只记基线、重启或标记变了算整个、否则相减）。
4. 取这次的 `by_model`：`totals["by_model"]` 是对象，且每个值都是对象、四个 `SOURCE_KEYS` 都是整数时才算有；否则当没有。取 `fallback`：`totals["model"]` 是字符串时用它，否则用 `""`。
5. `delta` 不为 nil 时，把它分到各模型名下，**每一项（四个 `SOURCE_KEYS`）分别处理**：
   - 有 `by_model` 时，算每个模型的增量 `d[m][k]`：这次是“整个算增量”（第一次以外的重启、标记变了）或者 `lastByModel` 为 nil 或者 `lastByModel` 里没有 `m` → `by_model[m][k]`；否则 `max(0, by_model[m][k] - lastByModel[m][k])`。所有模型的 `d[m][k]` 加起来正好等于 `delta[k]` 时，就按 `d[m][k]` 记；不等于时，整个 `delta[k]` 记在 `fallback` 名下。
   - 没有 `by_model` 时，整个 `delta[k]` 记在 `fallback` 名下。
   - 记账：加到 `byModel[模型][对应的 COUNTERS 键]`；增量为 0 的不要新建模型条目（今天的 `byModel` 里只出现真有用量的模型）。
6. `lastTotals` 照旧更新；`lastByModel` 设为这次的 `by_model`（没有就是 nil）；`lastEpoch` 照旧更新。
7. 什么时候置“待写”、什么时候写文件，照旧。

### `today()`

返回照接口约定 8.5 节：

- `prompt_tokens`、`cached_tokens`、`completion_tokens`、`requests`：各模型相加。
- `by_model`：每个模型一项，`{prompt_tokens, cached_tokens, completion_tokens, requests, cost}`；这个模型在 `config.prices` 里有单价时 `cost` 是 `.double(费用)`，没有时是 `.null`。
- `priced_models`、`unpriced_models`：`byModel` 里有单价、没单价的模型个数（`.int`）。
- `cost`：有单价的模型的费用相加（`.double`，没有就是 0.0）。
- 一个模型的费用：`((prompt_tokens - cached_tokens) × input + cached_tokens × cached + completion_tokens × output) / 1_000_000`。

### `apply(config:)`

换掉 `config`，按新的时区名重新算 `zone`（同样的三级回退）。不写文件、不动账；下一次 `update` 或 `today` 时的换日检查会按新时区处理日期变化（日期变了就照常换日）。

### 换日和历史文件

- 换日时“有没有用量”改成“`byModel` 里有没有不为 0 的数”；清零改成 `byModel = [:]`。
- 历史行：`{date, prompt_tokens, cached_tokens, completion_tokens, requests, cost, by_model}`，前五项是合计、`cost` 是有单价的模型的费用之和，`by_model` 和 `today()` 里的 `by_model` 同格式（含各自的 `cost` 或 null）。

### 文件格式（`usage.json`）

- 写：`version` 改成 `2`；保留 `date`、四项合计（各模型相加，只供人看）、`last_totals`、`last_epoch`（规则照旧）；新增 `by_model`（`{模型名: 四项 COUNTERS}`）和 `last_by_model`（`lastByModel` 的内容，nil 时写 `null`）。
- 读：原来的检查（`date`、四项合计、`last_totals`）照旧。然后：
  - 有 `by_model` 且是对象：每个值是对象、四个 `COUNTERS` 都是整数时才采用，采用后 `byModel` 用它；有任何一项不合格就按读不懂处理（整个文件当作第一次运行）。
  - 没有 `by_model`（第 1 版的文件）：四项合计里有不为 0 的数时记成 `byModel[""] = 四项合计`，否则 `byModel` 为空。
  - `last_by_model` 是对象且每个值都有四个整数 `SOURCE_KEYS` 时采用，否则 `lastByModel = nil`。

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
```

最后一行是 `Build complete!`。这一步测试还会编译不过（测试里用了删掉的单价字段），下一步改。

## 第三步：改已有的账本测试 `UsageTests.swift`

已有的 25 个测试原来都用 `Config()` 的默认单价，现在默认没有单价、记账时模型名是 `""`。所以：测试里造 `Config` 的地方（包括辅助函数）统一给 `prices[""]` 设上原来的默认单价 `ModelPrice(input: 0.15, cached: 0.016, output: 0.47)`；`test_cost_with_other_price` 里原来改 `priceInput` 等字段的地方改成改 `prices[""]`。这样原有断言的数值都不用改。除此之外原有断言不改；如果还有原有断言因为本任务的规则必须改，逐条写进结果报告（改了哪个测试、原来是什么、改成什么、为什么）。

然后新增一个套件 `@Suite struct TestByModel`，9 个测试，名字照下面写。`TOTALS` 这类合计用文件里已有的常量或者自己写；时钟、临时目录照已有测试的辅助函数。下面“喂”都是调 `update`，`by_model` 里的每个模型都写全四项。

1. `test_按模型分开记`：先喂一次只记基线，`by_model` 为 `{"A": 四项都是 0, "B": 四项都是 0}`；再喂一次，`A` 的 `prompt` 增加 100、`B` 的 `prompt` 增加 50（合计 `prompt` 增加 150，其他三项合计按各模型的变化同样相加）→ `today()["by_model"]["A"]["prompt_tokens"] == 100`，`B` 的是 50，`today()["prompt_tokens"] == 150`。
2. `test_只算填了单价的模型`：同上的用量，`prices` 只有 `"A"` → `today()["priced_models"] == 1`，`unpriced_models == 1`，`by_model["B"]["cost"]` 是 null，`today()["cost"]` 等于 `A` 的费用（自己按公式算出期望值，`almostEqual`）。
3. `test_按模型的和对不上时记在当前模型名下`：基线之后喂一次，合计 `prompt` 增加 100，但 `by_model` 各模型 `prompt` 的变化加起来只有 60，`model` 为 `"C"` → `prompt_tokens` 的 100 全记在 `"C"` 名下（`by_model["C"]["prompt_tokens"] == 100`）。
4. `test_没有按模型的累计值时记在当前模型名下`：不带 `by_model`、带 `model: "D"`，基线之后喂一次增量 → 全记在 `"D"`；再新建一个账本（换一个临时目录）、两次都既不带 `by_model` 也不带 `model` → 记在 `""` 名下。
5. `test_读第1版的文件`：在临时目录里写一个第 1 版的 `usage.json`（`version` 1，`date` 是今天，四项合计 `prompt_tokens` 等于 1000 其余为 0，`last_totals` 四项都是 0）→ 新建账本后 `today()["by_model"][""]["prompt_tokens"] == 1000`。
6. `test_程序重启后按模型接着算`：喂两次让 `A`、`B` 都有用量，`flush()`；用同一个目录新建账本，再喂一次 `A` 增加 10 → `A` 的 `prompt_tokens` 比重启前多 10，`B` 不变；`usage.json` 的 `version` 是 2，有 `by_model` 和 `last_by_model`。
7. `test_换日时历史行带各模型明细`：今天让 `A`（有单价）、`B`（没单价）都有用量，时钟拨到第二天再 `today()` → 历史文件一行，`by_model["A"]["cost"]` 是数、`by_model["B"]["cost"]` 是 null，这行的 `cost` 等于 `A` 的费用。
8. `test_改单价和时区立刻生效`：`A` 有用量、没单价时 `today()["cost"] == 0`；`apply(config:)` 给 `A` 填上单价后 `today()["cost"]` 等于按新单价算出的值；再 `apply` 一个时区，使这个时刻在新时区里是另一个日期 → `today()["date"]` 变成新时区的日期，`prompt_tokens` 为 0，历史文件多了一行。
9. `test_启动标记差30秒以内算同一次启动`：两次喂的 `epoch` 分别是 `1000.0` 和 `1001.0`，合计增加 → 按差值记账（不是整个算）；第三次 `epoch` 是 `1100.0` → 整个算。

```sh
(cd mac && swift test --filter '\.Test(FirstRun|Cost|ModelRestart|ProgramRestart|DayRollover|SaveFile|BadFile|Timezone|Epoch|ByModel)/' 2>&1 | grep -E '✘|error:' | head -20; swift test --filter '\.Test(FirstRun|Cost|ModelRestart|ProgramRestart|DayRollover|SaveFile|BadFile|Timezone|Epoch|ByModel)/' 2>&1 | tail -1)
```

前面没有输出，最后一行以 `✔ Test run with 34 tests` 开头、以 `passed after` 加秒数结尾。

## 第四步：采集器 `Collector.swift`

1. **交给账本**：`feed` 里把累计值交给账本的地方（注释 `2.1 记账` 那段），在 `forUsage` 里再放两项：`health["usage_by_model"]` 是对象时放 `forUsage["by_model"]`；采集器记着的模型名（`feed` 的 `model` 参数最近一次不为空的值，即已有的 `_model`）不为 nil 也不是空串时放 `forUsage["model"]`。
2. **模型加载中**：这次读数 `health["loading"]` 是对象、并且算出来的状态是 `"idle"` 或 `"prefill"` 时，快照的 `state` 改成 `"loading"`，并加一个键 `loading`，值照抄 `health["loading"]`。其他情况快照里没有 `loading` 这个键。只改给出去的快照，采集器内部记的状态（忙碌段、一轮、完成时刻等）照旧按原来的状态算。读不到（`health` 为 nil）时不涉及。

然后在 `CollectorTests.swift` 末尾新增一个套件 `@Suite struct TestOmlxSnapshot`，3 个测试（文件里已有造读数的辅助函数就用它们；需要假账本时写一个记下每次 `update` 参数的 `private final class`，实现 `UsageSink`）：

1. `test_按模型的累计值交给账本`：`health` 带 `usage_totals` 和 `usage_by_model`（`{"A": {...}}`），`feed(..., model: "A")` → 假账本收到的 JSON 里 `by_model` 等于那份 `usage_by_model`，`model == "A"`。
2. `test_加载模型时状态是loading`：空闲的 `health`（`requests_running` 为 0）加上 `loading: {"model": "A", "elapsed_s": 0.5, "estimated_s": 2.0, "size_gb": 2.2}` → 快照 `state == "loading"`，`snap["loading"]` 等于那份 `loading`；下一次不带 `loading` → `state == "idle"`，快照里没有 `loading` 这个键。
3. `test_解码时不显示加载`：有一条流在解码的 `health` 加上 `loading` → `state == "decode"`，快照里没有 `loading` 这个键。

```sh
(cd mac && swift test --filter TestOmlxSnapshot 2>&1 | grep -E '✘|error:' | head -20; swift test --filter TestOmlxSnapshot 2>&1 | tail -1)
```

前面没有输出，最后一行以 `✔ Test run with 3 tests` 开头、以 `passed after` 加秒数结尾。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/UsageTests.swift mac/Tests/PanelCoreTests/CollectorTests.swift
grep -n 'priceInput\|priceCached\|priceOutput' -r mac/Sources mac/Tests
git status --short
```

通过的标准：

- 第一条输出以 `✔ Test run with 190 tests` 开头、以 `passed after` 加秒数结尾（178 个已有的测试 + 本任务新增的 12 个）。
- 第二条输出 `mac/Tests/PanelCoreTests/UsageTests.swift:34` 和 `mac/Tests/PanelCoreTests/CollectorTests.swift:51`。
- 第三条没有输出。
- `git status --short` 只列出本任务的五个文件（` M`）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做；oMLX 适配器、画面改动由别的任务同时在别处做，这里没有它们，也不需要它们。
