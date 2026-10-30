# 任务 O3：画面改成 Mac 版

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（第 2、3 节和第 8 节，尤其 8.5～8.7）。本任务只改这两个文件：

- `mac/Sources/PanelCore/ViewModel.swift`
- `mac/Tests/PanelCoreTests/ViewModelTests.swift`

不要改别的文件。

## 背景

视图模型（`ViewModel`）把指标快照变成一个 `View`（画面上每块写什么）。它是从 Spark 版翻译过来的；Mac 版换了引擎（oMLX）、单价按模型填、多了“模型加载中”画面，有几处要改。画面以原型 `docs/dashboard-prototype.html` 为准：原型里画面内容在 `function view(` 附近，`case 'loading'`、`case 'done'`、`case 'offline'` 和 `const today = ` 这几段是本任务对应的部分。

快照里本任务用到的新内容（由别的模块给出）：

- `snap["engine"]` 可能是 `"omlx"`。
- `snap["model"]` 可能是 `mlx-community--Qwen3-ASR-0.6B-8bit` 这种带组织前缀的名字。
- `snap["today"]` 可能带 `priced_models`、`unpriced_models`（整数，见接口约定 8.5 节）；没有这两个键时都按 0。
- `snap["state"]` 可能是 `"loading"`，这时 `snap["loading"]` 是 `{model, elapsed_s, estimated_s, size_gb}`（后两项可能是 null）。
- `snap["engine_note"]` 可能是一句话（字符串）。

## 第一步：改 `ViewModel.swift`

1. **引擎名**：`engineName` 认出 `"omlx"` → `"oMLX"`。
2. **模型名**：`modelName` 现在取最后一个 `/` 后面的那段；再从这段里去掉最后一个 `--` 及它前面的部分（`mlx-community--Qwen3-ASR-0.6B-8bit` → `Qwen3-ASR-0.6B-8bit`）。去掉后为空就不去。把“原始名字 → 显示名”这部分抽成一个私有函数，第 7 条也用它。
3. **时区显示名**：在文件里加公开函数 `zoneDisplayName(_ identifier: String) -> String`（接口约定 8.7 节）：`Asia/Shanghai` → `北京时间`；`America/Los_Angeles` → `太平洋时间`；其他：`TimeZone(identifier:)?.localizedName(for: .generic, locale: Locale(identifier: "zh_CN"))`，拿不到就返回 `identifier` 原文。今日画面里原来按 `config.timezone` 算时区名的地方改用它。
4. **外挂未生效**：今日画面里“`hook` 是 `missing` 且引擎不是 vLLM 时写外挂未生效”的条件，改成引擎既不是 `"vllm"` 也不是 `"omlx"`（oMLX 不用外挂）。
5. **今日画面的单价**：设 `priced`、`unpriced` 为 `today` 里的 `priced_models`、`unpriced_models`（取不到按 0），`none = unpriced > 0 && priced == 0`。
   - `none` 时主数字 `bigInt = "—"`、`bigDec = ""`；否则照旧。
   - 圆圈下面那行（`view.bar`，`kind: "note"`）：`none` 时文字是 `[Seg("未填单价 · 在菜单栏里填", "warn")]`；否则 `unpriced > 0` 时是 `[Seg("<日期> · <时区名> · "), Seg("不含 <unpriced> 个模型", "warn")]`；否则照旧。
6. **离线画面**：
   - “今日费用”一格：`none` 时值写 `"—"`；脚注 `none` 时写 `"未填单价"`，否则 `unpriced > 0` 时写 `"不含 <unpriced> 个模型"`，否则空串。（`priced`、`unpriced`、`none` 的算法同第 5 条。）
   - `snap["engine_note"]` 是非空字符串时，状态条右边 `stripRight` 改成 `[Seg(engine_note, "warn")]`；否则照旧（“上次模型 …”）。
7. **新增“模型加载中”画面**（`state == "loading"`），在 `update` 里分派状态的地方加一支，写一个私有方法 `loading(_:_:_:)`。设 `ld` 是 `snap["loading"]`（不是对象时当空对象），`el = ld["elapsed_s"]` 的数（取不到按 0），`est` 是 `ld["estimated_s"]` 的数（不是数或不大于 0 时当没有）。
   - `stateName = "模型加载中"`，`stripLeft = ""`，`stripRight` = `[Seg("<显示名> · <引擎名>")]`；显示名是 `ld["model"]` 按第 2 条的规则得到的名字（`ld["model"]` 不是非空字符串时用 `modelName(snap)`），引擎名取不到时只写显示名。
   - 流指示点：照快照的 `lanes`；如果解码、预填充、排队三个数加起来是 0，把排队数设成 1。
   - `cap = "已用时"`，`unit = "秒"`，`bigWhole = true`；`el < 10` 时 `(bigInt, bigDec) = split1(el)`，否则 `bigInt = String(Int(floor(el)))`、`bigDec = ""`。
   - `arc = "blank"`，`arcTarget = nil`。
   - 有 `est` 时：`bar = Bar(kind: "prog", frac: min(0.99, el / est), level: "normal", text: segJoin([Seg("预计 "), Seg(<estText>, "strong"), Seg(" s · 剩余约 "), Seg(<rem>, "strong"), Seg(" s")]))`，其中 `estText` 在 `est < 10` 时是 `String(format: "%.1f", est)`，否则 `String(jsRound(est))`；`rem` 是 `max(1, ceil(est - el))` 写成整数（文件里已有 `_ceilAtLeast1`）。
   - 没有 `est` 时：`bar = Bar(kind: "prog", frac: 0.0, level: "normal", text: [Seg("首次加载 · 没有预计时间")])`。
   - 三格：`Card("模型大小", String(format: "%.1f", size), "GB", "")`（`ld["size_gb"]` 不是数时 `Card("模型大小", "—", "", "", true)`）；`Card("等待中", String(<排队数>), "个", "加载完开始")`，排队数就是上面流指示点里的排队数（至少 1）；内存那一格（`memCard`）。
   - 记忆（`update` 末尾那几段）不用为它单独处理：现有代码对“不是 idle/offline/done/decode/prefill”的状态的处理就是对的（不改休息画面的种类、清掉预填充接管标记、不调暗）。
8. **完成画面（单个请求，不是一轮模式）**：
   - 状态条右边 `stripRight` 一律写内存（`segJoin(memText)`），不再写首字。
   - 第三格从“接受率”改成“首字”：`ttft_s` 是数时 `Card("首字", String(format: "%.2f", ttft), "s", "")`，否则 `Card("首字", "—", "", "", true)`。
   - 一轮模式的完成画面不改。

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
```

最后一行是 `Build complete!`。

## 第二步：改已有的测试

`ViewModelTests.swift` 里有几处断言描述的是 Spark 版的行为，按第一步的规则改：

- `TestDone` 里完成画面的测试：`stripRight` 改成断言内存那句（按 `done` 样例里的内存数自己写出期望的文字和 `marks`），第三格改成 `CardRow("首字", "0.09", "s", "")`。
- `test_done_missing_acceptance`：改名为 `test_done_missing_ttft`，把合并进去的 `acceptance_rate: .null` 换成 `ttft_s: .null`，断言不变（第三格是 `"—"` 且 `pending`）。

其余已有断言不改。如果还有别的已有断言因为第一步的规则必须改，逐条写进结果报告（哪个测试、原来是什么、改成什么、为什么）。

## 第三步：新增测试

在 `ViewModelTests.swift` 末尾新增一个套件 `@Suite struct TestMacView`，11 个测试，名字照下面写。用文件里已有的辅助函数（`checkFixture`、`read`、`merged`、`plain`、`marks`、`cards` 等）在已有样例上改字段。

1. `test_引擎名写oMLX`：`idle` 样例，`engine` 改成 `"omlx"` → `stripLeft` 以 `" · oMLX"` 结尾。
2. `test_模型名去掉组织前缀`：`idle` 样例，`model` 改成 `"mlx-community--Qwen3-ASR-0.6B-8bit"`、`engine` 改成 `"omlx"` → `stripLeft == "Qwen3-ASR-0.6B-8bit · oMLX"`。
3. `test_时区显示名`：`zoneDisplayName("Asia/Shanghai") == "北京时间"`，`zoneDisplayName("America/Los_Angeles") == "太平洋时间"`，`zoneDisplayName("Asia/Tokyo") == "日本标准时间"`，`zoneDisplayName("Not/AZone") == "Not/AZone"`。
4. `test_今日有模型没填单价`：`idle` 样例，`today` 里加 `priced_models: 1`、`unpriced_models: 2` → 主数字照旧是费用；`bar` 的文字以 `" · 不含 2 个模型"` 结尾，最后一段的样式是 `warn`。
5. `test_今日一个模型都没填单价`：`today` 里 `priced_models: 0`、`unpriced_models: 1` → `bigInt == "—"`、`bigDec == ""`，`bar` 的文字是 `"未填单价 · 在菜单栏里填"`、样式 `warn`。
6. `test_离线的今日费用按单价显示`：`offline` 样例，分别用 `priced 0 / unpriced 1` 和 `priced 1 / unpriced 3` → 第一格分别是 `("今日费用", "—", 脚注 "未填单价")` 和 `(值照旧, 脚注 "不含 3 个模型")`。
7. `test_离线时显示引擎提示`：`offline` 样例加 `engine_note: "oMLX 需要 API key · 在设置里填写"` → `plain(stripRight)` 是这句、样式 `warn`；不加时照旧。
8. `test_模型加载中有预计时间`：`idle` 样例，`state` 改成 `"loading"`，`engine` 改成 `"omlx"`，加 `loading: {"model": "mlx-community--Big-8bit", "elapsed_s": 3.42, "estimated_s": 24.0, "size_gb": 84.9}` → `stateName == "模型加载中"`，`plain(stripRight) == "Big-8bit · oMLX"`，`bigInt`/`bigDec` 是 `"3"`/`".4"`，`bar.kind == "prog"`，`bar.frac` 约等于 `3.42 / 24`，`plain(bar.text) == "预计 24 s · 剩余约 21 s"`，三格是 `("模型大小", "84.9", "GB")`、`("等待中", "1", "个", "加载完开始")`、内存；`lanes.waiting == 1`。再把 `elapsed_s` 改成 `12.7` → `bigInt == "12"`、`bigDec == ""`。
9. `test_模型加载中没有预计时间`：同上但 `estimated_s` 和 `size_gb` 是 null → `bar.frac == 0`，`plain(bar.text) == "首次加载 · 没有预计时间"`；第一格是 `"—"` 且 `pending`。
10. `test_完成画面第三格是首字`：`done` 样例 → 第三格 `label == "首字"`、`value == "0.09"`、`unit == "s"`；`plain(stripRight)` 以 `"内存 "` 开头。
11. `test_oMLX不写外挂未生效`：`idle` 样例，`hook` 改成 `"missing"`、`engine` 改成 `"omlx"` → `plain(stripRight)` 不含 `"外挂未生效"`。

```sh
(cd mac && swift test --filter '\.Test(MacView|Done|RoundRest|Idle|OfflineView)/' 2>&1 | grep -E '✘|error:' | head -20; swift test 2>&1 | tail -1)
```

前面没有输出，最后一行以 `✔ Test run with 189 tests` 开头、以 `passed after` 加秒数结尾（178 个已有的测试 + 本任务新增的 11 个）。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/ViewModelTests.swift
git status --short
```

通过的标准：

- 第一条输出以 `✔ Test run with 189 tests` 开头、以 `passed after` 加秒数结尾。
- 第二条输出 `50`。
- `git status --short` 只列出本任务的两个文件（` M`）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做；oMLX 适配器、按模型记账由别的任务同时在别处做，这里没有它们，也不需要它们。
