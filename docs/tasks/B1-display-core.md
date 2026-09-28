# 任务 B1：副屏程序的核心逻辑（Swift，纯逻辑 + 测试）

先读 `AGENTS.md`，再读 `docs/design.md`「指标接口」「副屏界面设计」「显示程序行为」三节，并仔细读 `docs/dashboard-prototype.html` 里 `<script>` 的 `view(t)`、`tokFmt`、`split1`、`v2f` 等函数——**画面上每个状态显示什么，以原型的 `view()` 为准**。本任务只写逻辑和测试，不写任何 SwiftUI 界面，不碰 `collector/`。

## 交付

在 `display/` 建一个 SwiftPM 包：

```
display/Package.swift              // swift-tools-version:6.0，platforms: .macOS(.v14)，包名 TFPanel
display/Sources/PanelCore/...      // library 目标 PanelCore（本任务全部代码）
display/Tests/PanelCoreTests/...   // 测试目标，swift-testing
display/Fixtures/*.json            // /metrics 示例数据
```
Package.swift 本任务只声明 `PanelCore` 库和 `PanelCoreTests` 测试目标（后续任务会再加可执行目标）。

## 1. Metrics.swift：/metrics 的数据模型

`Decodable` 结构，字段与接口一致（接口定义见下），**所有字段都可选**（缺字段、多字段、`null` 都不能导致解码失败）：

```
Metrics { version: Int?, state: String?, engine_ready: Bool?, model: String?, tensorfold_version: String?,
          context_max: Int?, hooks: Hooks?, current: Current?, last: Last?, totals: Totals? }
Hooks   { chat: String? }
Current { elapsed_s: Double?, ttft_s: Double?, output_tokens: Int?, decode_tps: Double?, decode_tps_peak: Double?, decode_tps_avg: Double? }
Last    { prompt_tokens: Int?, cached_tokens: Int?, completion_tokens: Int?, decode_tps: Double?, ttft_s: Double?,
          acceptance_rate: Double?, context_used: Int?, finish_reason: String? }
Totals  { requests: Int?, peak_tps: Double?, uptime_s: Int? }
```
Swift 属性用驼峰命名，用 `CodingKeys` 或 `.convertFromSnakeCase` 映射。

## 2. Format.swift：格式化（和原型 JS 结果逐字一致）

- `tokFmt(_ n: Double) -> String`：先四舍五入；`< 1000` 原样整数；`< 99950` 一位小数加 K（`1000→"1.0K"`、`6200→"6.2K"`、`12400→"12.4K"`、`99949→"99.9K"`）；否则整数 K（`99950→"100K"`、`262144→"262K"`）。
- `split1(_ x: Double) -> (String, String)`：一位小数后在小数点处切开，`58.2→("58", ".2")`、`109.64→("109", ".6")`、`7→("7", ".0")`。
- `fixed(_ x: Double, _ digits: Int) -> String`：等同 JS `toFixed`。
- `shortModelName(_ s: String) -> String`：去掉量化/格式后缀，从第一个匹配处截断，匹配（不区分大小写）以 `-` 开头的 `MLX`、`GGUF`、`AWQ`、`GPTQ`、`EXL` 加任意数字、`数字bit`、`MTP`、`DFlash`。例：`"Qwen3.8-27B-MLX-4bit"→"Qwen3.8-27B"`、`"Qwen3.8-27B-oQ4e-mtp"→"Qwen3.8-27B-oQ4e"`、`"Llama-3-8B"→"Llama-3-8B"`。

## 3. Gauge.swift：仪表几何（照抄原型常量）

- `ticks = [0, 25, 50, 100, 150, 200]`，`tickFractions = [0, 0.17, 0.34, 0.60, 0.81, 1]`。
- `valueToFraction(_ v: Double) -> Double`：原型 `v2f`（分段线性，≤0 为 0，≥200 为 1）。
- `fractionToDegrees(_ f: Double) -> Double = 225 − 270·f`。
- 几何常量 `cx=154, cy=144, R=124, strokeWidth=14`（设计单位，480×320 画布内），`point(deg, r) -> CGPoint`（y 向下：`cy − r·sin`）。

## 4. Memory.swift：整机内存

- `SystemMemory.read() -> (usedGB: Double, totalGB: Double)?`：用 `host_statistics64(HOST_VM_INFO64)`，已用 = (`internal_page_count − purgeable_count` + `wire_count` + `compressor_page_count`) × 页大小；总量 = `sysctl hw.memsize`。GB 按 1024³ 换算（和活动监视器一致）。

## 5. PanelModel.swift：状态 → 画面（核心）

### 5.1 连接状态机 `ConnectionTracker`（值类型，纯逻辑，时间由参数传入）

- `mutating func recordSuccess(_ m: Metrics, at t: Double)`、`mutating func recordFailure(at t: Double)`。
- 连续 3 次失败才算离线；启动后还没有成功过也算离线。`offlineSince` = 第一次失败的时间（启动后从未成功则为程序启动时间，由 init 传入）。
- 记住：最近一次成功的 `Metrics` 及其时间 `fetchedAt`、最近一次非空的 `last`（`rememberedLast`）、最近一次非空的 `model`（`rememberedModel`）。离线时仍保留这些，用于画面。
- 解码小曲线采样：每次成功且 `state == "decode"` 时，若距上次采样 ≥ 0.1 s，追加一个样本 `(raw, smooth)`，最多保留 80 个。`smooth` = `current.decodeTps`；`raw` = 最近 1 秒内 `output_tokens` 的增量 ÷ `max(0.25, min(1, 本次解码已进行秒数))`（用自己记的成功历史算）。进入 `prefill` 时清空样本。

### 5.2 画面模型 `PanelViewModel`（对应原型 `view()` 返回的 V）

```
enum PanelState { offline, unavailable, starting, idle, prefill, decode, done }
enum ArcMode { value, rest, comet, off }
struct Card { label, value, unit, foot: String; pending: Bool }
struct StripSegment { text: String; bold: Bool }
PanelViewModel {
  state; stateName; stripLeft: String; stripRight: [StripSegment]
  cap: String; pill: Bool; bigInt: String; bigDec: String; whole: Bool; unit: String
  arc: ArcMode; arcTarget: Double (tok/s, 由界面缓动); ghostFraction: Double? ; cometPhase: Double?
  showSpark: Bool; message: (title: String, subtitle: String)?   // 离线/不可用/启动中时显示在仪表中央
  cards: [Card]  // 恰好 3 张
}
static func make(tracker: ConnectionTracker, now: Double, memory: (usedGB, totalGB)?) -> PanelViewModel
```

状态判定顺序：离线 → `hooks.chat == "missing"` 为 `unavailable` → `engine_ready == false` 为 `starting` → 否则按 `metrics.state`（未知值按 `idle`）。

注意：`hooks.chat` 有三个取值 `ok` / `missing` / `pending`（模型加载中、自检还没运行），只有 `missing` 算 unavailable。`/metrics` 返回非 200（例如 500）或 JSON 解析失败，都由调用方记为一次 `recordFailure`（这部分网络代码在后续任务写，本任务只需保证 tracker 语义）。

每个状态的内容**逐字照抄原型**（`view()` 的 case），并做以下替换（原型用的是模拟数据）：

| 状态 | 与原型的对应与替换 |
| --- | --- |
| offline | 同原型 offline。`stripLeft` = `上次模型 <短模型名>`，没有记住的模型时为 `TensorFold`。卡片：上次平均（`rememberedLast.decodeTps` 一位小数，foot `tok/s`；没有则 `—` pending）、已离线（<60 秒 `N 秒`，<60 分钟 `N 分钟`，否则 `N 小时`；秒数向下取整）、内存。`message = ("引擎离线", "等待 TensorFold 响应…")`，`arc = .off`。 |
| unavailable | 新状态（原型没有）。`stateName = "指标不可用"`，`stripLeft` = 短模型名，`arc = .off`，`message = ("指标不可用", "TensorFold 已更新，需要适配")`。卡片：上次平均（同 offline）、运行（`totals.uptimeS`，同“已离线”的秒/分钟/小时规则）、内存。 |
| starting | 新状态。`stateName = "启动中"`，`stripLeft = "TensorFold"`，`arc = .off`，`message = ("模型加载中", "TensorFold 正在启动…")`。卡片：上次平均（同 offline）、运行（`totals.uptimeS`）、内存。 |
| idle | 同原型 idle。数据用 `metrics.last`（为空时用 `rememberedLast`）。都没有时：`bigInt = "—"`、`bigDec = ""`、`pill = false`、`ghostFraction = nil`，三张卡片为 输出/首字/内存，前两张 `—` pending。 |
| prefill | 同原型 prefill。已用时 = `current.elapsedS + (now − fetchedAt)`（本地插值，画面才能连续走秒）。`cometPhase = (已用时 mod 1.5) / 1.5`。`stripRight` 超过 1.5 秒时为 `提示较长，可能需要几秒`。内存卡用当前内存。 |
| decode | 同原型 decode。`bigInt` = `arcTarget` 四舍五入（界面层会用缓动值覆盖，这里给目标值即可），`arcTarget = current.decodeTps`。`stripRight` = `首字 ` + **`0.46`** + ` s · 内存 ` + **`21.4`** + ` / 64 GB`（粗体段用 `bold: true`；总内存取整数）。卡片：输出（`tokFmt(outputTokens)` / `tok`）、平均（`decodeTpsAvg` 为空 → `—` pending，否则一位小数，foot `tok/s`）、峰值（>0 时四舍五入、unit `tok/s`，否则 `—` pending）。`showSpark = true`。 |
| done | 同原型 done。数据用 `metrics.last`。`stripRight` = `上下文 ` + **tokFmt(contextUsed)** + ` / ` + tokFmt(contextMax)（`contextMax` 为空时省略 ` / …`）。卡片：输出（foot `提示 X tok`）、缓存命中（`round(cached / prompt × 100)`，prompt 为 0 时 0；foot `X tok`）、接受率（`round(acceptanceRate × 100)`）。缺字段的卡片显示 `—` pending。`arcTarget = last.decodeTps`，`showSpark = 样本数 > 5`。 |

所有 `stateName`：offline `引擎离线`、unavailable `指标不可用`、starting `启动中`、idle `空闲`、prefill `预填充中`、decode `解码中`、done `完成`。idle/prefill/decode/done 的 `stripLeft` = 短模型名。内存卡：`内存` / `21.4` / `GB` / foot `共 64 GB`；读不到内存时 `—` pending。

## 6. Fixtures

在 `display/Fixtures/` 放 JSON（字段全部符合接口）：`idle.json`、`idle-empty.json`（`last` 为 null）、`prefill.json`（elapsed_s 2.3）、`decode.json`（用 design.md 里的示例值）、`done.json`（prompt 32、cached 0、completion 600、decode_tps 109.6、ttft 0.102、acceptance 0.78、context_used 632）、`unavailable.json`（hooks.chat missing）、`starting.json`（engine_ready false、model null）。测试要能读到它们（测试里按 `#filePath` 相对定位即可）。

## 测试（swift-testing）至少覆盖

1. `tokFmt`、`split1`、`shortModelName` 上面列出的全部例子。
2. `valueToFraction`：0、25、58、100、200、250 以及负数。
3. 每个 fixture 都能解码；缺字段、多余字段、`null` 的 JSON 也能解码。
4. `ConnectionTracker`：2 次失败仍在线、3 次失败离线、成功后恢复；从未成功 = 离线；离线后仍保留 `rememberedLast` / `rememberedModel`。
5. 每个 `PanelState` 至少一个 `PanelViewModel.make` 用例，断言 stateName、cap、bigInt/bigDec、三张卡片的 label/value/unit/foot/pending、stripRight 文本。
6. 小曲线采样：0.1 秒节流、最多 80 个、进入 prefill 清空。

## 完成前必须运行并全部通过

```sh
cd display && swift build && swift test
```
