# 任务 TF2：TensorFold 适配器、读取、设置与 app

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（第 3、6、7 节和第 10 节）和设计文档 `docs/design-mac.md` 增补的“引擎：TensorFold”“引擎的选择”两节。前置：任务 TF1 已完成（`Prometheus.swift` 的 `PrometheusText` 可用）。本任务动这些文件：

新建：

- `mac/Sources/PanelCore/Tensorfold.swift`
- `mac/Tests/PanelCoreTests/TensorfoldTests.swift`

修改：

- `mac/Sources/PanelCore/Sources.swift`（`EngineIssue` 加两个分支）
- `mac/Sources/PanelCore/AppSettings.swift`（engine 取值、默认地址切换、key 策略）
- `mac/Tests/PanelCoreTests/AppSettingsTests.swift`（只**追加**新测试，不改已有测试）
- `mac/Sources/TFPanel/AppController.swift`（按设置建对应引擎的 reader）
- `mac/Sources/TFPanel/SettingsWindow.swift`（引擎下拉框加 TensorFold 一项）

除此之外不改任何文件，`OmlxReader`、`OmlxAdapter`、采集器、账本、视图模型、轮询一行不动；已有测试全部保持原样且必须继续通过。

## 第一步：适配器 `Tensorfold.swift`

`TensorfoldAdapter` 照接口约定 10.3，**无状态**（不记上一次，同样的输入永远同样的输出）：

```swift
public final class TensorfoldAdapter {
    public init()
    public func feed(now: Double, health: JSON?, models: JSON?, metrics: PrometheusText?) -> (health: JSON, metrics: JSON)?
}
```

字段规则（设计文档“统一读数各字段”表 + 契约 10.3 的写死项，这里汇总成实现清单）：

| 输出（放 `health` 字典） | 规则 |
| --- | --- |
| `ok` | `.bool(true)` |
| `backend` | `.string("tensorfold")` |
| `requests_running` | metrics 的 `tensorfold:requests_running`，取整；缺按 0 |
| `waiting` | `tensorfold:requests_waiting`，取整；缺按 0 |
| `streams` | `{"decoding": D, "prefilling": P, "max": M}`（都是 `.int`）。P = `tensorfold:filling_prompt_tokens_left > 0` ? 1 : 0；D = `max(0, requests_running − P)`；M = `/health` 的 `max_batch_size`（是数且 > 0），否则 8 |
| `kv_usage` | `tensorfold:kv_cache_usage_ratio` 的值数组（`.double`），按 pool 键的**数值**升序（键读不成数的忽略）；家族缺 → 不带这个键 |

| 输出（放 `metrics` 字典） | 规则 |
| --- | --- |
| `requests_total` | `tensorfold:request_latency_seconds_count`，取整；缺按 0 |
| `prompt_tokens_total` | `tensorfold:prompt_tokens_total`，取整；缺按 0 |
| `cached_tokens_total` | `tensorfold:prompt_tokens_cached_total`，取整；缺按 0 |
| `completion_tokens_total` | `tensorfold:generation_tokens_total`，取整；缺按 0 |
| `prefill_seconds_total`、`decode_seconds_total` | `tensorfold:request_prefill_seconds_sum`、`tensorfold:request_decode_seconds_sum`，`.double`；缺按 0.0 |
| `drafted_total`、`accepted_total` | `tensorfold:mtp_drafted_total`、`tensorfold:mtp_accepted_total`，取整；**家族缺 → 不带这个键** |
| `ttft_sum`、`ttft_count` | `tensorfold:time_to_first_token_seconds_sum`（`.double`）、`_count`（取整）；`_sum` 缺 → 不带这对键 |
| `epoch` | `tensorfold:process_start_time_seconds` 取整到 10 秒：`Int((x / 10).rounded(.down) * 10)`，`.int`；缺 → `.null` |
| `aborted_total` | `tensorfold:client_disconnections_total`，取整；缺 → 不带 |
| `completion_finished_total` | `generation_tokens_total − generation_tokens_running`（向零截断；后者缺取前者），取整 |

统一读数的 `usage_totals` 放在 `metrics` 字典里（oMLX 适配器同位置）：`{"prompt": prompt_tokens_total, "cached": cached_tokens_total, "completion": completion_finished_total, "requests": requests_total}`（四个都是 `.int`）。**不带** `usage_by_model`、`loading`、`tfpanel`。

`feed` 的输入守卫：`health` 为 nil 或不是 JSON 对象 → 返回 nil。`metrics` 为 nil 时仍要产出读数（那次的家族全按缺处理）；`models` 为 nil 时 `context_length` 走默认。

`context_length`：从 `models`（`/v1/models` 的 `data` 数组）里找 `id` 等于 `/health` 的 `model` 的项，取它的 `context_length`（没有再取 `max_model_len`）；找不到项就用数组第一项的；数组空或缺 → 262,144。放 `metrics["context_length"]`，`.int`。

JSON 类型纪律照接口约定第 3 节：该 `.int` 的 `.int`、该 `.double` 的 `.double`，快照比较时类型要对。

检查：

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
```

## 第二步：`EngineIssue` 增补（`Sources.swift`）

照契约 10.4：加 `case notTensorfold, needsKeyTensorfold`，`message` 加两行：

- `notTensorfold` → `"这个地址上不是 TensorFold"`
- `needsKeyTensorfold` → `"TensorFold 需要 API key · 在设置里填写"`

已有的四个分支一字不动。

## 第三步：读取 `TensorfoldReader`

```swift
public final class TensorfoldReader: EngineSource {
    public init(transport: HTTPTransport, apiKey: String? = nil)
    public var apiKey: String?
    public private(set) var issue: EngineIssue
    public private(set) var modelIDs: [String]
    public var modelName: String? { get }
    public func read(now: Double, wall: Double) -> (health: JSON, metrics: JSON)?
    public func reset()
}
```

写法照 `OmlxReader` 的现状（同一个 `HTTPTransport`、同样的三拍重试口径：读不到就返回 nil，连续 3 次离线的判断在采集器/轮询层，reader 只管这次）。每次 `read` 按顺序发三个 GET：`/health`、`/metrics`、`/v1/models`，全部拿到后喂适配器。

认引擎（`issue` 的判定顺序照契约 10.3，关键在配了 key 时 `/health` 只回 `{"status":"ok"}`）：

1. `/health` 连不上或非 200 → `.unreachable`，返回 nil。
2. 200 且 JSON 对象带 `version` 和 `backend` → 认出。
3. 200 且 JSON 对象但只有 `status`（配了 key 的样子）→ 拿 `/metrics` 的状态码试探：200 → 认出；401 → `.needsKeyTensorfold`；其他 → `.notTensorfold`。这两种情况都返回 nil。
4. 200 的 JSON 不带 `version`/`backend` → `.notTensorfold`，返回 nil。

认出后：带 key 时请求 `/metrics`、`/v1/models` 放 `Authorization: Bearer`；`modelIDs` 取 `/health` 的 `model_ids`（没有就用 `/v1/models` 的 `data` 数组的 `id` 列表）；`modelName` 取 `/health` 的 `model`，缺取 `modelIDs` 第一个；`issue` 回 `.none`。`/v1/models` 或 `/metrics` 这两个 GET 失败 → 这次返回 nil、`.unreachable`。

## 第四步：设置（`AppSettings.swift`）

照契约 10.5：

- `engine` 的合法取值多一个 `"tensorfold"`（键、默认 `"omlx"` 不变）。
- 默认地址按引擎：`omlx → 127.0.0.1:8000`，`tensorfold → 127.0.0.1:8080`。`engine` 的 setter 里：改引擎时若旧地址等于旧引擎的默认值，地址跟着改成新引擎默认；用户手改过的地址不动。
- `apiKey()`：自动模式只在 engine 为 `"omlx"` 时读 `~/.omlx/settings.json`；engine 为 `"tensorfold"` 返回 nil。

`AppSettingsTests.swift` 末尾**追加**几个 `@Test`（引擎切换换默认地址、手改地址不换、tensorfold 自动模式 apiKey 为 nil、omlx 自动模式照旧），套件名沿用文件里已有的。

## 第五步：app 接线（`AppController.swift`、`SettingsWindow.swift`）

- `AppController`：按 `settings.engine` 建 `OmlxReader` 或 `TensorfoldReader`（传输层都用 `makeTransport(baseURL:)`）；`poller.source` 的类型本来就是 `EngineSource`，换引擎重建时照现有 `settingsChanged()` 的路子。第 132 行附近 `poller.source as? OmlxReader` 的 key 更新要分引擎处理（TensorFoldReader 的 key 来自设置，手动模式才有）。
- `SettingsWindow`：引擎下拉框加"TensorFold"一项（值 `"tensorfold"`，显示名 `TensorFold`）。
- 菜单栏引擎一项的文案来自 `issue.message`，两个新分支的文案在 10.4 里已定，不用再改菜单代码——如果现状是把文案写死在菜单里，把取文案的地方对齐 `EngineIssue.message` 即可，别的不动。

## 第六步：测试 `TensorfoldTests.swift`

没有 Python 对照，测试是新写的（swift-testing，套件 `@Suite struct TestTensorfold`），断言以本任务和契约 10.3 的规则为准。至少覆盖：

**适配器单元测试**（手工构造 `health` JSON、`models` JSON、`PrometheusText` 文本）：

- 全字段都在的输入 → 统一读数逐字段断言（含 `streams` 推导、`epoch` 取整、`usage_totals` 四项、`completion_finished_total` = `generation_tokens_total − generation_tokens_running`）。
- 缺失就缺失：metrics 文本里删掉 `mtp_*`、`client_disconnections_total`、`prompt_tokens_cached_total`、`time_to_first_token_seconds_*`、`kv_cache_usage_ratio` → 输出对应键不存在（`#expect(snap.metrics["drafted_total"] == nil)` 这类）。
- `max_batch_size` 缺失/非法 → `streams.max == 8`；`filling_prompt_tokens_left` 为 0 和为正两种 `streams`。
- `kv_usage` 的 pool 数值排序（`"10"` 排在 `"2"` 后面）。
- `health` 传 nil 或非对象 → `feed` 返回 nil。
- `context_length`：models 里有/没有当前模型两种。

**读取测试**（照 `OmlxReaderTests.swift` 里假 `HTTPTransport` 的写法）：

- 无 key：`/health` 带 `version`+`backend` → 认出、`issue == .none`、模型名和 modelIDs 正确。
- 有 key：`/health` 只回 `{"status":"ok"}` → `/metrics` 200 认出 / 401 → `.needsKeyTensorfold` / 404 → `.notTensorfold`。
- `/health` 返回 HTML（JSON 解析失败）→ `.notTensorfold`。
- `/health` 500 → `.unreachable`。
- 假传输返回的 metrics 文本喂适配器 → 读数正确。

**fixtures 回放** `@Test func test_回放实录()`：逐行读 `fixtures/tensorfold/scenarios.jsonl`（`loadFixture("tensorfold/scenarios.jsonl")` 是整个文件一个字符串，自己按行拆；或照 `loadFixture` 的写法直接 `Data(contentsOf:)` 拆行），按时间顺序把每拍喂给适配器：

- `ok == true`、`backend == "tensorfold"` 恒成立；
- 任一拍 `streams.decoding + streams.prefilling == requests_running`；
- `requests_total` 单调不减；
- 最后一拍的 `aborted_total >= 1`（实录里有一次客户端中断）；
- `epoch` 全程唯一（没有重启）。

检查：

```sh
(cd mac && swift test --filter Tensorfold 2>&1 | tail -3)
(cd mac && swift test 2>&1 | tail -3)
(cd mac && swift test --filter AppSettings 2>&1 | tail -3)
```

三条全部通过，且全量测试的个数比 TF1 完成时只多不少。

## 结果报告

按 `AGENTS.md` 的格式：改动的文件、每条检查命令通过与否、歧义处理（尤其 `AppController` 里 key 更新和 reader 替换的实际写法）、最后一行 `DONE` 或 `FAILED: <原因>`。