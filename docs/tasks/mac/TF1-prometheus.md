# 任务 TF1：Prometheus 文本解析

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（第 3、6、7 节和第 10 节，特别是 10.2）。本任务只新建这两个文件：

- `mac/Sources/PanelCore/Prometheus.swift`
- `mac/Tests/PanelCoreTests/PrometheusTests.swift`

不要改别的文件（包括 `mac/Package.swift`，新文件在已有 target 里自动参与编译）。已有文件里发现问题时不要改，写进结果报告。

## 背景

TensorFold 引擎（设计见 `docs/design-mac.md` 的“引擎：TensorFold”）用 Prometheus 文本格式报告指标，TF2 的适配器要把它换算成统一读数。本任务只做**文本格式解析**，不判语义：家族名原样保留，`_sum`/`_count`/`_bucket` 都只是普通家族名。

真实输入样例看 `fixtures/tensorfold/scenarios.jsonl` 里 `ep` 为 `/metrics` 的行的 `body` 字段（一行一个 JSON；`body` 就是刮到的原始文本）。

## 接口（照 10.2 节，一字不差）

```swift
public struct PrometheusText: Sendable, Equatable {
    public init(_ text: String)
    public func number(_ family: String) -> Double?
    public func numbers(_ family: String) -> [String: Double]
}
```

`PanelCore` 只能 `import Foundation`。

## 解析规则

按 Prometheus 文本格式（ exposition formats 的 text version 0.0.4）：

1. **行**：以 `\n` 分行（容忍 `\r\n`）。
2. **注释行**：`#` 开头的行（`# HELP`、`# TYPE`、其他注释）一律忽略。
3. **空行**：忽略。
4. **样本行**：`家族名 [ "{" 标签列表 "}" ] 值 [ 时间戳 ]`，记号之间允许空格/制表符。
   - 家族名：`[a-zA-Z_:][a-zA-Z0-9_:]*`。
   - 标签列表：`名字="值"` 用逗号分隔；`{}`（空标签）视为无标签。标签值里的转义只处理三种：`\\` → `\`、`\"` → `"`、`\n` → 换行；其他转义按字面保留。
   - 值：整数（`17`）、小数（`0.5`）、负数（`-3`）、指数记法（`1.5e3`、`1.5E-3`）都要能读；`+Inf`、`-Inf`、`NaN` 和读不成数的值 → 该样本忽略（`number` 不收录、`numbers` 不收录）。用 `Double(_ string:)` 判断即可，注意 Swift 的 `Double("inf")` 等的大小写行为自己验证一下，写进代码前用测试钉住。
   - 时间戳：值后面如果还有一个整数记号，忽略它。
5. **收录**：
   - 无标签样本 → `number(家族名)` 的候选；同一文本里同一家族的无标签样本出现多行时，**最后一行生效**。
   - 带标签样本 → `numbers(家族名)` 里加一项 `标签值 → 数`；同一标签值出现多行时，**最后一行生效**。同一行的多个标签只取**第一个**标签的值做键（TF 的家族每个最多一个有意义的标签，`pool`、`stream`、`mode`、`route`、`le` 都如此）。
   - 家族不存在 → `number` 返回 nil、`numbers` 返回空字典。
6. 内部存储自己组织，`Equatable` 让编译器合成即可。解析性能不用特别优化，但不要对每行做正则——手工扫描就行。

## 第一步：写 `Prometheus.swift`

照上面规则实现。风格照 `Sources/PanelCore/` 里其他文件的写法（中文注释、简洁）。

检查：

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
```

前面没有输出，最后一行是 `Build complete!`。

## 第二步：写 `PrometheusTests.swift`

一个套件 `@Suite struct TestPrometheus`，用 swift-testing（`import Testing`、`#expect`），不用 XCTest。测试名用中文也可以。至少覆盖：

- `# HELP`/`# TYPE` 和其他 `#` 注释行被忽略。
- 整数、小数、负数、指数记法各一个；带时间戳的样本读出值。
- `+Inf`/`NaN` 的样本被忽略（家族因此不存在时 `number` 是 nil）。
- 带标签样本：`tensorfold:kv_cache_usage_ratio{pool="3"} 0.5` → `numbers` 里有 `"3": 0.5`；多行同家族收齐多键；同一键重复出现取最后一行。
- `{}` 视为无标签。
- 同家族无标签样本多行取最后一行。
- 标签值转义：`pool="a\"b"` 的键是 `a"b`。
- 不存在的家族：`number` nil、`numbers` 空。
- 值后面有多余空白、`\r\n` 行尾都能读。

再加一个 fixtures 抽样测试 `@Test func test_fixtures_全部可解析()`：把 `fixtures/tensorfold/idle.jsonl` 和 `fixtures/tensorfold/scenarios.jsonl` 里所有 `status` 为 200、`ep` 为 `/metrics` 的行的 `body` 逐个解析，断言：

- `number("tensorfold:process_start_time_seconds")` 不为 nil（两个文件都查）；
- `numbers("tensorfold:server_info").count == 1`（scenarios 里查，idle 里若也出现同样断言）；
- `numbers("tensorfold:kv_cache_usage_ratio").count <= 8`。

读 fixtures 用 `TestSupport.swift` 的 `loadFixture("tensorfold/idle.jsonl")`（它接受带子目录的名字）。注意 fixtures 是 JSON 行文件，`JSON.parse` 每行取 `body`（字符串）。

检查：

```sh
(cd mac && swift test --filter Prometheus 2>&1 | tail -3)
(cd mac && swift test 2>&1 | tail -3)
```

第一条全部通过；第二条不能有既有测试因此失败。

## 结果报告

按 `AGENTS.md` 的格式：改动的文件、每条检查命令通过与否、歧义处理，最后一行 `DONE` 或 `FAILED: <原因>`。