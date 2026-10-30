# 任务 O1：oMLX 适配器和读取

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（第 3、6、7 节和第 8 节）。本任务只新建这五个文件：

- `mac/Sources/PanelCore/Engine.swift`
- `mac/Sources/PanelCore/Sources.swift`
- `mac/Tests/PanelCoreTests/OmlxAdapterTests.swift`
- `mac/Tests/PanelCoreTests/OmlxFixturesTests.swift`
- `mac/Tests/PanelCoreTests/OmlxReaderTests.swift`

不要改别的文件。已有文件里发现问题时不要改，写进结果报告。

## 背景

副屏程序从本机的推理引擎 oMLX 读状态。oMLX 有两个状态接口：`/api/status` 给累计值和当前请求数，`/admin/api/stats` 给每个模型的三张表（排队、预填充、解码）。适配器把这两份 JSON 换算成采集器认得的“统一读数”（`health`、`metrics` 两个 JSON 对象）。换算规则已经写成 Python 参考实现 `docs/tasks/mac/ref/omlx_adapter.py`，它的行为就是规格；`docs/tasks/mac/ref/test_omlx_adapter.py` 是它的单元测试，`fixtures/omlx/` 里是在真机上录下的九段读数序列和参考实现对每一拍的输出。

读取部分（`OmlxReader`）负责发 HTTP 请求、认出 oMLX、带上 API key、把读到的东西喂给适配器。它没有参考实现，规则在下面第三步里。

## 第一步：翻译适配器 `Engine.swift`

把 `docs/tasks/mac/ref/omlx_adapter.py` 逐个方法翻成 Swift 的 `OmlxAdapter`，公开接口照接口约定 8.2 节。

- 常量 `LIMBO_S`、`DEFAULT_CONTEXT`、`DEFAULT_MAX_STREAMS`、`EPOCH_TOLERANCE_S`、`GIB` 照搬，做成文件内的 `private let`。
- 流表的行在 Python 里是可变字典，几处代码拿着同一个字典改。Swift 里写成一个 `private final class Row`，字段照 `_new_row` 里的键。
- **顺序**：Python 的字典保持插入顺序，这里有三处结果依赖顺序，Swift 里都要保持：
  - `_parse_stats` 返回的 `tables`：按模型在列表里的顺序、每个模型内 waiting、prefilling、generating 的顺序、每张表内行的顺序。用一个数组存 `(rid, table, row, model)`，另加一个 `rid → 下标` 的字典查找。
  - `self._rows`：按第一次见到的顺序。用数组存 `Row`（另加查找字典也可以），删除时保持其余行的顺序。
  - `self._placeholders`、`self._credits`：本来就是列表。
  - `self._by_model` 的顺序无所谓（输出时按名字排序）。
- `gone.sort(key=...)` 的键里有唯一的 `id`，Swift 里按 `(phase != "decode", start, id)` 比较排序即可。
- `int(round(raw_epoch))`：Python 的 `round` 是逢五取偶，写成 `Int(rawEpoch.rounded(.toNearestOrEven))`。
- `d * w // wsum`：这里 `d`、`w` 都不是负数，Swift 的整数 `/` 结果相同。
- `_int`、`_num`、`_int_or` 照接口约定第 3 节的对应关系写：`_int(v)` 是 `v?.int`；`_num(v, d)` 是 `v?.number ?? d`；`_int_or(v, d)` 是“`v?.number` 不为 nil 时 `Int(它)`（向零截断），否则 `d`”。
- 输出的 JSON 类型照 Python：Python 是 `int` 的用 `.int`，`float` 的用 `.double`（`start`、`ttft_s`、`prefill_seconds_total`、`decode_seconds_total`、`ttft_sum`、`elapsed_s`、`estimated_s`、`size_gb` 是 `float`），`None` 用 `.null`。`epoch` 还没有时是 `.null`。
- `feed` 返回 Python 的 `(health, metrics)` 元组时，Swift 返回 `(health: JSON, metrics: JSON)`；返回 `None` 时返回 `nil`。

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
```

前面没有输出，最后一行是 `Build complete!`。

## 第二步：翻译适配器的测试

### `OmlxAdapterTests.swift`

照接口约定第 7 节，把 `docs/tasks/mac/ref/test_omlx_adapter.py` 的 `TestOmlxAdapter` 类翻成 `@Suite struct TestOmlxAdapter`，21 个测试方法逐个翻，名字照抄。造读数的函数 `status`、`stats`、`model`、`w`、`p`、`g` 和常量 `WALL0` 翻成文件里的 `private` 函数和常量，参数名、默认值照抄（Python 的 `*models` 翻成 `[JSON]` 参数或可变参数都可以）。

Python 版的测试可以在仓库根目录这样跑，用来对照：

```sh
python3 -m unittest docs/tasks/mac/ref/test_omlx_adapter.py -v 2>&1 | tail -3
```

### `OmlxFixturesTests.swift`

一个套件 `@Suite struct TestOmlxFixtures`，一个测试 `@Test func test_回放九段实录()`，把 `fixtures/omlx/` 里九个场景逐个回放，和期望输出逐拍比较。场景名：`load-short`、`short`、`long`、`cached`、`concurrent4`、`queue10`、`abort-decode`、`abort-prefill`、`mixed`。

文件格式（都是一行一个 JSON）：

- `fixtures/omlx/<场景>.jsonl`：第一行是头 `{"models": [...], "health": {...}}`；之后每行一拍 `{"t": 秒, "wall": Unix 时间戳, "status": 对象或 null, "stats": 对象或 null}`。
- `fixtures/omlx/<场景>.expected.jsonl`：每行对应上面的一拍（不含头），`{"t": 秒, "health": 对象或 null, "metrics": 对象或 null, "model": 字符串或 null}`。

回放的做法（和 `docs/tasks/mac/ref/replay.py` 的 `run` 相同）：每个场景新建一个 `OmlxAdapter()`，先 `setModels(头["models"])`；然后每一拍调用 `feed(now: t, wall: wall, status: status, stats: stats)`。结果为 `nil` 时期望的 `health`、`metrics` 都是 null；否则逐项比较 `health`、`metrics`。每一拍都比较 `adapter.modelName` 和期望的 `model`（`nil` 对 null）。

比较用一个文件内的 `private func jsonDiff(_ a: JSON, _ b: JSON, _ path: String) -> String?`：一样就返回 `nil`，不一样就返回第一个不一样的位置（如 `health.tfpanel.streams[0].start`）和两边的值。规则：两个数（`int`、`double` 混着也算）差的绝对值不超过 `1e-9` 算一样；对象的键集合必须相同、逐键比较；数组长度必须相同、逐个比较；其余类型直接 `==`。每一拍的断言写成 `#expect(diff == nil, "\(场景) t=\(t): \(diff ?? "")")`，一个场景出现第一处不同就停止这个场景（免得刷屏），接着比下一个场景。

读文件：`fixturesDir.appendingPathComponent("omlx/\(name).jsonl")`，按 `\n` 切行、跳过空行，每行 `JSON.parse`。

```sh
(cd mac && swift test --filter 'TestOmlxAdapter|TestOmlxFixtures' 2>&1 | grep -E '✘|error:' | head -20; swift test --filter 'TestOmlxAdapter|TestOmlxFixtures' 2>&1 | tail -1)
```

前面没有输出，最后一行以 `✔ Test run with 22 tests` 开头、以 `passed after` 加秒数结尾。

回放对不上时，在仓库根目录运行 `python3 docs/tasks/mac/ref/replay.py <场景名>` 可以看参考实现逐拍的要点；要看某一拍的完整输出，直接读 `.expected.jsonl` 里对应的行。以参考实现为准改 Swift 代码。

## 第三步：读取 `Sources.swift`

公开接口照接口约定 8.3 节。

### `URLSessionTransport`

照下面写（这段写法已经验证过，能在 Swift 6 下编译、能连本机的 oMLX）：

```swift
/// 结果盒子：完成回调在别的线程里写，调用方等信号量之后读
private final class ResultBox: @unchecked Sendable {
    var value: HTTPResult?
}

public final class URLSessionTransport: HTTPTransport {
    private let base: String
    private let session: URLSession

    public init(baseURL: String, timeout: Double = 0.5) {
        var b = baseURL.trimmingCharacters(in: .whitespaces)
        if !b.contains("://") { b = "http://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        base = b
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.connectionProxyDictionary = [:]   // 本机地址不走系统代理
        session = URLSession(configuration: cfg)
    }

    public func get(_ path: String, headers: [String: String]) -> HTTPResult? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse {
                box.value = HTTPResult(status: http.statusCode, body: data ?? Data())
            }
            sem.signal()
        }.resume()
        sem.wait()
        return box.value
    }
}
```

测试里不测 `URLSessionTransport`（不连真的 oMLX）。

### `EngineIssue.message`

照接口约定 8.3 节注释里的四句话。

### `OmlxReader`

状态：适配器 `OmlxAdapter(maxStreams:)`、`verified`（认没认出 oMLX，初始 false）、`misses`（连续读不到的次数，初始 0）、`modelsAt`（上次读 `/v1/models` 的时刻，初始 nil）、`issue`（初始 `.none`）、`modelIDs`（初始空）。

请求头：`apiKey` 不为 nil 也不是空串时，带 `["Authorization": "Bearer \(apiKey)"]`；否则不带任何头。`/health` 永远不带头。

`read(now:wall:)` 按顺序做：

1. 还没认出 oMLX（`verified` 为 false）：GET `/health`。
   - 返回 nil → 记一次读不到，原因 `.unreachable`，返回 nil。
   - 状态码不是 200，或者内容不是 JSON 对象，或者对象里没有 `engine_pool` 这个键 → 记一次读不到，原因 `.notOmlx`，返回 nil。
   - 否则 `verified = true`，接着往下。
2. `modelsAt` 为 nil 或 `now - modelsAt >= 5`：`modelsAt = now`，GET `/v1/models`（带头）。状态码 200 且内容是 JSON 对象、`data` 是数组时：`adapter.setModels(data)`，`modelIDs` 设为数组里每项 `id`（字符串）按原顺序组成的列表。其他情况什么都不做，接着往下。
3. GET `/api/status`（带头）。
   - 返回 nil → 记一次读不到，原因 `.unreachable`，返回 nil。
   - 状态码 401 → 记一次读不到，原因 `.needsKey`，返回 nil。
   - 状态码不是 200 或内容不是 JSON 对象 → 记一次读不到，原因 `.notOmlx`，返回 nil。
4. GET `/admin/api/stats`（带头）。状态码 200 且内容是 JSON 对象时作为 `stats`，否则 `stats` 是 nil（适配器会走降级）。
5. `adapter.feed(now: now, wall: wall, status: status, stats: stats)`：返回 nil → 记一次读不到，原因 `.notOmlx`，返回 nil。否则 `misses = 0`、`issue = .none`，返回结果。

“记一次读不到，原因 X”：`misses += 1`，`issue = X`；`misses >= 3` 时适配器 `reset()`、`verified = false`、`modelsAt = nil`、`misses = 0`。

`reset()`：适配器 `reset()`、`verified = false`、`modelsAt = nil`、`misses = 0`、`issue = .none`。

`modelName`：返回 `adapter.modelName`。

### 读 oMLX 的设置文件

- `omlxApiKey(settingsPath:)`：路径开头的 `~` 用 `(path as NSString).expandingTildeInPath` 展开；读文件、`JSON.parse`；返回 `auth.api_key`（不是字符串或是空串时返回 nil）。读不了、不是 JSON 时返回 nil。
- `omlxMaxStreams(settingsPath:)`：同样读文件，返回 `scheduler.max_concurrent_requests`（整数且大于 0 时），否则返回 8。

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
```

前面没有输出，最后一行是 `Build complete!`。

## 第四步：读取的测试 `OmlxReaderTests.swift`

一个套件 `@Suite struct TestOmlxReader`，8 个测试，名字照下面写。用文件内的 `private final class FakeTransport: HTTPTransport`：按路径存要返回的 `HTTPResult?`（可以随时改），并把每次调用的 `(path, headers)` 记进一个数组。造内容用 `HTTPResult(status: 200, body: Data(json.serialized().utf8))`。一份能用的 `/api/status` 内容：`{"total_requests": 0, "total_prompt_tokens": 0, "total_cached_tokens": 0, "total_completion_tokens": 0, "active_requests": 0, "waiting_requests": 0, "uptime_seconds": 100.0, "default_model": "M"}`；`/admin/api/stats`：`{"active_models": {"models": []}}`；`/health`：`{"status": "healthy", "engine_pool": {}}`；`/v1/models`：`{"data": [{"id": "M", "max_model_len": 4096}]}`。

1. `test_health不是oMLX时读不到`：`/health` 返回 200 但内容是 `{"status": "ok"}` → `read` 返回 nil，`issue == .notOmlx`。
2. `test_连不上时是unreachable`：所有路径都返回 nil → `read` 返回 nil，`issue == .unreachable`。
3. `test_401时是needsKey`：`/api/status` 返回状态码 401 → `read` 返回 nil，`issue == .needsKey`，`issue.message == "oMLX 需要 API key · 在设置里填写"`。
4. `test_正常读数带key且health只认一次`：`apiKey` 为 `"k1"`，四个路径都正常。连读两次（`now` 为 0 和 0.1）：两次都不为 nil，`health["backend"] == "omlx"`，`issue == .none`；`/health` 只被请求过一次且不带任何头；`/api/status` 每次都带 `Authorization: Bearer k1`；`modelIDs == ["M"]`；`health["context_length"]` 是 4096（模型名来自 `default_model` 的 `"M"`）。
5. `test_详情读不到时降级`：`/admin/api/stats` 返回 500 → `read` 不为 nil，`health` 里没有 `tfpanel` 这个键。
6. `test_连续3次读不到后重新认引擎`：先正常读一次；然后把 `/api/status` 改成 nil 连读三次（都返回 nil）；再改回正常读一次 → 这一次之前 `/health` 一共被请求 2 次（第一次认、清空后再认一次），这次结果不为 nil。
7. `test_模型列表每5秒读一次`：正常情况下在 `now` 为 0、1、4.9、5.0 各读一次 → `/v1/models` 被请求 2 次。
8. `test_读设置文件里的key和并发上限`：在临时目录（`FileManager.default.temporaryDirectory` 下新建的唯一子目录，测试结束删掉）写一个 `settings.json`，内容 `{"auth": {"api_key": "abc"}, "scheduler": {"max_concurrent_requests": 6}}` → `omlxApiKey` 返回 `"abc"`，`omlxMaxStreams` 返回 6；对一个不存在的路径 → `omlxApiKey` 返回 nil，`omlxMaxStreams` 返回 8。

```sh
(cd mac && swift test --filter TestOmlxReader 2>&1 | grep -E '✘|error:' | head -20; swift test --filter TestOmlxReader 2>&1 | tail -1)
```

前面没有输出，最后一行以 `✔ Test run with 8 tests` 开头、以 `passed after` 加秒数结尾。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/OmlxAdapterTests.swift mac/Tests/PanelCoreTests/OmlxFixturesTests.swift mac/Tests/PanelCoreTests/OmlxReaderTests.swift
git status --short
```

通过的标准：

- 第一条输出以 `✔ Test run with 208 tests` 开头、以 `passed after` 加秒数结尾（178 个已有的测试 + 本任务的 30 个）。
- 第二条输出三个文件依次是 `21`、`1`、`8`。
- `git status --short` 只列出本任务的五个新文件（`??`）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做；按模型记账、画面改动由别的任务同时在别处做，这里没有它们，也不需要它们。
