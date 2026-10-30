# 接口约定 · Mac 版（M 系列任务共用）

本文规定 Mac 版各模块之间交接的类型和函数签名：名字、参数、字段**一字不差**。
设计背景见 `docs/design-mac.md`。这一批是把 `panel/` 里的 Python 模块原样翻译成 Swift；Python 代码的行为就是规格，本文只规定 Swift 这边的写法。

## 1. 包和文件

Swift 包在 `mac/`，在 `mac/` 目录下运行 `swift build`、`swift test`。

| 文件 | 内容 | 谁写 |
| --- | --- | --- |
| `mac/Package.swift` | 库 `PanelCore`、测试 `PanelCoreTests` | 已有，不改 |
| `mac/Sources/PanelCore/JSON.swift` | JSON 值类型 `JSON`（见第 3 节） | 已有，不改 |
| `mac/Sources/PanelCore/Config.swift` | 配置 `Config` | 已有，不改 |
| `mac/Sources/PanelCore/Fmt.swift` | `panel/fmt.py` 的翻译 | 已有，不改 |
| `mac/Sources/PanelCore/Scale.swift` | `panel/scale.py` 的翻译 | 已有，不改 |
| `mac/Sources/PanelCore/View.swift` | `panel/view.py` 的翻译 | 已有，不改 |
| `mac/Sources/PanelCore/Collector.swift` | `panel/collector.py` 的翻译 | 任务 M1 |
| `mac/Sources/PanelCore/Usage.swift` | `panel/usage.py` 的翻译 | 任务 M2 |
| `mac/Sources/PanelCore/ViewModel.swift` | `panel/viewmodel.py` 的翻译 | 任务 M3 |
| `mac/Sources/PanelCore/Animator.swift` | `panel/anim.py` 的翻译（含 `Frame`） | 任务 M4 |
| `mac/Tests/PanelCoreTests/TestSupport.swift` | 测试共用：`repoRoot`、`fixturesDir`、`loadFixture(_:)`、`almostEqual(_:_:places:)` | 已有，不改 |
| `mac/Tests/PanelCoreTests/<模块>Tests.swift` | `panel/tests/test_<模块>.py` 的翻译 | 各任务 |

`PanelCore` 只能 `import Foundation`。测试只用 swift-testing（`import Testing`），不能用 XCTest。

## 2. 已有的基础（读源码即可，这里只列名字）

- `Config`：`roundGapS`、`prefillShortS`、`doneHoldS`、`dimAfterS`、`animFps`、`timezone`、`priceInput`、`priceCached`、`priceOutput`、`currency`、`stateDir`、`modelName`，含义和默认值同 Python 的 `Config` 里同名字段（`round_gap_s` → `roundGapS`）。Python 的 `base_url`、`base_urls`、`monitor_*` 在 Mac 版没有。
- `Fmt.swift`：`jsRound(_:) -> Int`、`tokFmt(_:)`、`split1(_:) -> (String, String)`、`costFmt(_:currency:)`、`durFmt(_:)`、`dateLabel(_:)`、`pct(_:_:)`，参数都是 `Double`（`pct` 的第二个是 `Double?`）。Python 各模块里自己定义的 `js_round` 一律用这里的 `jsRound`。
- `Scale.swift`：`tickFracs`、`scales`（`[String: GaugeScale]`，`GaugeScale` 有 `ticks`、`labels`）、`v2f(_ v: Double?, _ scale: String) -> Double`。
- `View.swift`：`Seg`、`Lanes`、`Card`、`Bar`、`View`，字段同 Python 的 `view.py`，名字换成驼峰（`state_name` → `stateName`，`big_int` → `bigInt`，`pill_kind` → `pillKind`）。Python 里 `None` 的字段在 Swift 里是可选值。构造：`Seg("文字")`、`Seg("6.2K", "strong")`、`Card("输出", "24.6K", "tok", "", false)`（参数顺序同 Python 的位置参数，后面的可省略）、`Lanes(max:decoding:prefilling:waiting:offline:)`、`Bar(kind:frac:level:text:)`、`View()` 再逐个赋值。`toJSON()`、`View(json:)` 对应 `to_dict`、`from_dict`。

## 3. JSON 值

读数（`/health`、`/metrics` 的解析结果、统一读数）、指标快照、账本文件在 Python 里都是字典，Swift 里一律用 `JSON` 表示，**键名照 Python 的原样**（`"requests_total"`、`"prompt_tokens"`）。

```swift
public enum JSON { case null, bool(Bool), int(Int), double(Double), string(String), array([JSON]), object([String: JSON]) }
```

| Python | Swift |
| --- | --- |
| `d.get("k")` | `d["k"]`（类型 `JSON?`：没有这个键是 `nil`，值为 null 是 `.null`） |
| `d.get("k") is None` | `d["k"].isNone`（两种情况都算） |
| `isinstance(v, (int, float)) and not isinstance(v, bool)` | `v.number != nil`（`number` 是 `Double?`） |
| `isinstance(v, int) and not isinstance(v, bool)` | `v.int != nil` |
| `isinstance(v, dict)`、`list`、`str`、`bool` | `v.object`、`v.array`、`v.string`、`v.bool` 不为 `nil` |
| `if v:`（真值） | `v.truthy` |
| `None` | `.null`（**不支持** `nil` 字面量当 JSON 值：`["epoch": .null]`，不能写 `["epoch": nil]`） |
| 字面量 `{"ok": True, "n": 5, "x": 1.5, "s": "a", "l": [1, 2]}` | `let h: JSON = ["ok": true, "n": 5, "x": 1.5, "s": "a", "l": [1, 2]]` |
| `a == b`（字典比较） | `a == b`：和 Python 一样，`1 == 1.0` 为真；`true` 不等于 `1` |
| `json.loads(text)` | `JSON.parse(text)`（`String` 或 `Data`；不合法返回 `nil`；`1` 解析成 `.int`，`1.0` 解析成 `.double`） |
| `json.dumps(d, sort_keys=True, ensure_ascii=False)` | `d.serialized()` |
| `copy.deepcopy(d)`、`dict(d)` | 直接赋值（值类型，本来就是拷贝） |

要往快照里放 Python 的 `int` 就用 `.int(...)`，放 `float` 就用 `.double(...)`，`None` 就用 `.null`：输出的类型要和 Python 版一致（快照写进文件、和 fixtures 比较时要用到）。`JSON(x)` 把 `Int?`、`Double?`、`String?`、`Bool?` 转成 JSON，`nil` 变成 `.null`。

## 4. 时刻

和 Python 版一样：所有 `now` 参数都是单调时钟的秒数（`Double`），模块自己不读时钟；测试里直接传假数字，不 sleep。今日用量的 `clock` 返回 Unix 时间戳（秒）。

## 5. 各模块的公开接口

### 采集（M1，`Collector.swift`）

```swift
/// 今日用量账本的接口（UsageLedger 实现它；测试里可以写一个假的）
public protocol UsageSink: AnyObject {
    func update(_ totals: JSON) throws
    func today() throws -> JSON
}

public final class Collector {
    public init(config: Config, usage: UsageSink? = nil)
    public var prefillTps: Double { get }       // Python 的 prefill_tps 属性
    public func feed(now: Double, health: JSON?, metrics: JSON? = nil, memory: JSON? = nil, model: String? = nil) -> JSON
}
```

- `feed` 对应 Python 的 `Collector.feed`：`health` 为 `nil` 表示这次读不到（Python 的 `None`）；返回值是快照（JSON 对象），键和值的类型与 Python 版逐个相同。
- Python 里 `try: self.usage.update(...) except Exception: pass` 这类“账本抛异常一律吃掉”的地方，Swift 里用 `try?`。

### 今日用量（M2，`Usage.swift`）

```swift
public final class UsageLedger: UsageSink {
    public init(config: Config, clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                stateDir: String? = nil, saveIntervalS: Double = 10.0)
    public func update(_ totals: JSON)
    public func today() -> JSON
    public func flush()
}
```

- 对应 Python 的 `UsageLedger`。`stateDir` 为 `nil` 时用 `config.stateDir`；开头的 `~` 展开成用户目录。文件名、文件格式、写文件的时机和 Python 版相同（`usage.json`、`usage-history.jsonl`）。
- 时区用 `TimeZone(identifier: config.timezone)`；Python 版在时区名无效时怎么做，这里照做。

### 视图模型（M3，`ViewModel.swift`）

```swift
public final class ViewModel {
    public init(config: Config)
    public func update(_ snapshot: JSON, now: Double) -> View
}
```

### 动画（M4，`Animator.swift`）

```swift
public struct Frame: Equatable, Sendable {
    public var arcFrac: Double = 0.0
    public var arcMix: Double = 0.0
    public var valueAlpha: Double = 0.0
    public var ghostAlpha: Double = 0.0
    public var ticksAlpha: Double = 0.0
    public var trackAlpha: Double = 0.5
    public var notchAlpha: Double = 0.0
    public var bigInt: String = ""
    public var bigDec: String = ""
    public var barFrac: Double = 0.0
    public var centerAlpha: Double = 1.0
    public var statsAlpha: Double = 1.0
    public var stripAlpha: Double = 1.0
    public var pulseDec: Double = 1.0
    public var pulsePre: Double = 1.0
    public var dim: Double = 1.0
    public var animating: Bool = false
    public init()
}

public final class Animator {
    public init()
    public func step(_ view: View, now: Double) -> Frame
    public static func settled(_ view: View) -> Frame
}
```

字段的含义和默认值同 Python 的 `Frame`（`arc_frac` → `arcFrac`），顺序也照它。

## 6. 翻译的规矩

- **行为一字不变**：每个分支、每个阈值、每处取整都照 Python。Python 的私有方法、私有状态可以按 Swift 的习惯组织，但算出来的东西必须一样。Python 代码里的中文注释（尤其是 `2.7`、`2.12` 这类指向设计文档章节的编号）随代码一起搬过来。
- 取整：Python 的 `math.floor(x)` → `x.rounded(.down)`；`int(x)`（向零截断）→ `Int(x)`；`round(x, n)` 是“四舍六入五成双”，照它的语义写，不要换成 `jsRound`。`//` 是向下取整的整除，负数时和 Swift 的 `/` 不同，按 Python 的语义写。
- 格式：`f"{x:.1f}"` → `String(format: "%.1f", x)`；`str(int)` → `String(n)`。
- Python 里 `float` 和 `int` 混算的地方，Swift 里先转成 `Double` 再算。
- 大的 JSON 字面量写明类型（`let h: JSON = [...]`），嵌套很深的拆成几个变量。否则编译器推断类型很慢，甚至报 “the compiler is unable to type-check this expression in reasonable time”。

## 7. 测试的翻译规矩

- 一个 Python 测试文件翻成一个 Swift 文件：`panel/tests/test_collector.py` → `mac/Tests/PanelCoreTests/CollectorTests.swift`，以此类推。
- `class TestX(unittest.TestCase)` → `@Suite struct TestX`；每个 `def test_y(self)` → 一个 `@Test func test_y()`，**名字照抄**（中文名照样用，Swift 允许）。Python 有几个测试方法，Swift 就有几个 `@Test`，一一对应。
- 测试里的辅助类、辅助函数（场景回放、造读数的函数）照样翻成 Swift 的辅助类型、函数，放在同一个文件里，名字前面加 `private`。`setUp` 翻成 `init()` 或每个测试开头调用的辅助函数。
- `@Test` 不带参数（不用 `arguments:`），这样 `swift test` 报的测试个数和 Python 的测试方法个数相同。
- 测试套件的名字在整个测试目标里不能重复。Python 里两个文件有同名的类时（`test_collector.py` 和 `test_viewmodel.py` 都有 `TestOffline`），`CollectorTests.swift` 里照抄，`ViewModelTests.swift` 里的改叫 `TestOfflineView`。
- 断言：`assertEqual(a, b)` → `#expect(a == b)`；`assertAlmostEqual(a, b, places=n)` → `#expect(almostEqual(a, b, places: n))`（不写 `places` 时 `places: 7`）；`assertAlmostEqual(a, b, delta=d)` → `#expect(abs(a - b) <= d)`；`assertIsNone(x)` → `#expect(x == nil)` 或 `#expect(x.isNone)`；`assertIs(x, True)` → `#expect(x == .bool(true))`；`assertTrue`/`assertFalse` → `#expect(...)`/`#expect(!...)`；`subTest` 的循环 → 普通循环，把循环变量写进 `#expect` 的说明里。断言里给的说明文字也搬过来。
- **断言不改，数值不改**。Python 断言的是“能转成 JSON”这类 Python 特有的东西时，换成 Swift 里意思最接近的断言（例如 `JSON.parse(snap.serialized()) == snap`），并在结果报告里逐条列出。
- 读 `fixtures/` 用 `loadFixture("decode.json")`。要临时目录时用 `FileManager.default.temporaryDirectory` 下新建一个唯一的子目录，测试结束删掉。

## 8. 第二批（O 系列）：oMLX、按模型记账、Mac 版画面

第二批在第一批的基础上接 oMLX、把今日用量改成按模型记账、把画面改成 Mac 版。设计见 `docs/design-mac.md` 的“引擎：oMLX”“引擎的选择”“费用单价”“时区”几节，画面以原型 `docs/dashboard-prototype.html` 为准。本节和前面几节冲突时以本节为准。

### 8.1 文件

| 文件 | 内容 | 谁写 |
| --- | --- | --- |
| `mac/Sources/PanelCore/Engine.swift` | oMLX 适配器 `OmlxAdapter`（`docs/tasks/mac/ref/omlx_adapter.py` 的翻译） | 任务 O1，新建 |
| `mac/Sources/PanelCore/Sources.swift` | HTTP 读取、`OmlxReader`、读 oMLX 设置文件 | 任务 O1，新建 |
| `mac/Sources/PanelCore/Config.swift` | 去掉三个单价字段，加按模型的单价 | 任务 O2 |
| `mac/Sources/PanelCore/Usage.swift` | 按模型记账 | 任务 O2 |
| `mac/Sources/PanelCore/Collector.swift` | 把按模型的累计值交给账本；“模型加载中”状态 | 任务 O2 |
| `mac/Sources/PanelCore/ViewModel.swift` | Mac 版画面的改动 | 任务 O3 |
| `docs/tasks/mac/ref/` | 参考实现和它的测试、回放脚本（只读） | 已有 |
| `fixtures/omlx/<场景>.jsonl`、`<场景>.expected.jsonl` | oMLX 实录的读数序列和参考实现的输出（只读） | 已有 |

### 8.2 适配器（O1，`Engine.swift`）

```swift
public final class OmlxAdapter {
    public init(maxStreams: Int = 8)
    public var maxStreams: Int
    public private(set) var contexts: [String: Int]          // 模型名 → 上下文上限
    public func reset()
    public func setModels(_ models: JSON?)                    // /v1/models 的 data 数组
    public var modelName: String? { get }                     // Python 的 model_name 属性
    public func rows() -> [JSON]
    public func feed(now: Double, wall: Double, status: JSON?, stats: JSON?) -> (health: JSON, metrics: JSON)?
}
```

行为照参考实现：`status`、`stats` 不是 JSON 对象时，分别按 Python 的“不是 dict”处理。

### 8.3 读取（O1，`Sources.swift`）

```swift
public struct HTTPResult: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data)
}

/// 发 GET 请求的东西；测试里换成假的
public protocol HTTPTransport: AnyObject {
    /// 连不上、超时返回 nil；连上了就返回状态码和内容（不管状态码是多少）
    func get(_ path: String, headers: [String: String]) -> HTTPResult?
}

public final class URLSessionTransport: HTTPTransport {
    public init(baseURL: String, timeout: Double = 0.5)   // baseURL 如 "127.0.0.1:8000"，没写协议时补 "http://"
}

public enum EngineIssue: String, Sendable {
    case none, unreachable, notOmlx, needsKey
    public var message: String? { get }   // none → nil；unreachable → "未连接"；notOmlx → "这个地址上不是 oMLX"；needsKey → "oMLX 需要 API key · 在设置里填写"
}

public final class OmlxReader {
    public init(transport: HTTPTransport, apiKey: String? = nil, maxStreams: Int = 8)
    public var apiKey: String?
    public private(set) var issue: EngineIssue          // 最近一次读的结果
    public private(set) var modelIDs: [String]          // /v1/models 里的模型名，按原顺序
    public var modelName: String? { get }               // 适配器的 modelName
    public func read(now: Double, wall: Double) -> (health: JSON, metrics: JSON)?   // nil = 这次读不到
    public func reset()                                  // 换地址、换 key 后调用：适配器清空、重新认引擎
}

public func omlxApiKey(settingsPath: String = "~/.omlx/settings.json") -> String?
public func omlxMaxStreams(settingsPath: String = "~/.omlx/settings.json") -> Int
```

### 8.4 统一读数的新字段（适配器给出，采集器使用）

| 字段 | 内容 |
| --- | --- |
| `usage_totals` | `{prompt, cached, completion, requests}`：交给账本的四项累计值（已有，Spark 版 vLLM 也用） |
| `usage_by_model` | `{模型名: {prompt, cached, completion, requests}}`：按模型分开的同样四项 |
| `loading` | 有模型在加载时才有：`{model, elapsed_s, estimated_s, size_gb}`，后两项可以是 null |

### 8.5 单价和账本（O2）

```swift
public struct ModelPrice: Equatable, Sendable, Codable {
    public var input: Double     // 美元 / 百万 token
    public var cached: Double
    public var output: Double
    public init(input: Double, cached: Double, output: Double)
}
```

- `Config` 去掉 `priceInput`、`priceCached`、`priceOutput`，加 `public var prices: [String: ModelPrice] = [:]`（键是 oMLX 的模型名原文，如 `Qwen3-4B-Instruct-2507-4bit`）。
- `UsageLedger` 加 `public func apply(config: Config)`：换单价、换时区，立刻生效。
- 交给 `UsageLedger.update` 的 JSON 除了原来的 `prompt`、`cached`、`completion`、`requests`、`epoch`，可以再带 `by_model`（即 `usage_by_model`）和 `model`（字符串，当前模型名）。
- `today()` 返回的 JSON 在原来的键（`date`、`prompt_tokens`、`cached_tokens`、`completion_tokens`、`requests`、`cost`）之外加：
  - `by_model`：`{模型名: {prompt_tokens, cached_tokens, completion_tokens, requests, cost}}`，没填单价的模型 `cost` 是 null；
  - `priced_models`：今天用过、填了单价的模型个数（整数）；
  - `unpriced_models`：今天用过、没填单价的模型个数（整数）。
  - `cost` 只算填了单价的模型。

### 8.6 快照的新内容

- `state` 多一个值 `"loading"`（模型加载中，O2 在采集器里定）。这时快照多一个键 `loading`，内容照抄统一读数的 `loading`；其他状态没有这个键。
- `engine_note`：app 在引擎有问题时放进快照的一句话（`EngineIssue.message`），采集器不管它；画面在离线时显示它（O3）。

### 8.7 画面（O3，`ViewModel.swift`）

```swift
/// 时区的中文显示名：Asia/Shanghai → 北京时间，America/Los_Angeles → 太平洋时间，其他用系统给的中文名
public func zoneDisplayName(_ identifier: String) -> String
```
