# 任务 A1：内存、轮询、设置

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（第 3 节、8.3、8.5 和 9.3、9.4）。本任务只新建这六个文件：

- `mac/Sources/PanelCore/Memory.swift`
- `mac/Sources/PanelCore/Poller.swift`
- `mac/Sources/PanelCore/AppSettings.swift`
- `mac/Tests/PanelCoreTests/MemoryTests.swift`
- `mac/Tests/PanelCoreTests/PollerTests.swift`
- `mac/Tests/PanelCoreTests/AppSettingsTests.swift`

不要改别的文件。已有文件里发现问题时不要改，写进结果报告。

开始之前先跑一次 `(cd mac && swift test 2>&1 | tail -1)`，记下现有的测试个数 N（最后检查要用）。

## 背景

副屏 app 在后台线程上一拍一拍地轮询：读 oMLX（`OmlxReader`，已有，在 `Sources.swift`）、读整机内存，把读数喂给采集器（`Collector`，已有），得到快照交给主线程。设置存在 `UserDefaults` 里，由菜单栏和设置窗口改，再换算成 PanelCore 用的 `Config`。本任务写这三块的逻辑和测试，窗口、菜单不在本任务里。

Spark 版的轮询是 `panel/poller.py` 的 `Poller.tick`，本任务的轮询按它的间隔规则写，但读取部分简单得多：读哪些接口、多久读一次模型列表都由 `OmlxReader` 自己管。

## 第一步：`Memory.swift`

接口照接口约定 9.3 节。

- `readSystemMemory()`：用 `host_statistics64(mach_host_self(), HOST_VM_INFO64, …)` 读 `vm_statistics64_data_t`，已用页数 = `internal_page_count - purgeable_count + wire_count + compressor_page_count`，乘 `getpagesize()`，除以 1024³ 得已用 GB；总量用 `sysctlbyname("hw.memsize", …)` 读出字节数除以 1024³。任何一步失败返回 nil。返回 `["used_gb": .double(已用), "total_gb": .double(总量)]`。下面这段读法验证过，照用：

```swift
var stats = vm_statistics64_data_t()
var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
let kr = withUnsafeMutablePointer(to: &stats) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
    }
}
guard kr == KERN_SUCCESS else { return nil }
```

- `monotonicNow()`：`ProcessInfo.processInfo.systemUptime`。

测试 `MemoryTests.swift`：`@Suite struct TestMemory`，一个测试 `test_读整机内存`：返回值不是 nil，`used_gb`、`total_gb` 都是数，`total_gb > 0`，`0 < used_gb`，`used_gb <= total_gb`。

```sh
(cd mac && swift test --filter '\.TestMemory/' 2>&1 | tail -1)
```

最后一行以 `✔ Test run with 1 test` 开头、以 `passed after` 加秒数结尾。

## 第二步：`Poller.swift`

接口照接口约定 9.3 节（`EngineSource`、`extension OmlxReader: EngineSource {}`、`Poller`）。

`tick()` 按顺序做：

1. 把 `perform` 交来、还没执行的动作取出来（加锁），按交来的顺序执行。
2. `now = clock()`，`wall = wallClock()`。
3. `let r = source.read(now: now, wall: wall)`；读到了就是 `health`、`metrics`，读不到两个都是 nil。
4. 内存：从没读过、或距上次读满 1 秒（`now - 上次 >= 1.0`）才调 `readMemory()`，并记下这次的时刻；否则这一拍传 nil。
5. `snapshot = collector.feed(now: now, health: health, metrics: metrics, memory: memory, model: source.modelName)`。
6. 快照不是 JSON 对象时：沿用上一次的快照，没有上一次就用 `["state": "offline"]`，这一拍的间隔固定 0.5（跳过第 8 条）。
7. `source.issue` 是 `.notOmlx` 或 `.needsKey` 时，在快照里放 `engine_note`：`.string(issue.message!)`；其他情况不放这个键。
8. 间隔：忙 → 0.1；否则状态是 `"offline"` → 0.5；否则 0.25。“忙”的定义照 `panel/poller.py` 的 `_is_busy`、`_lanes_sum`：状态是 `prefill` 或 `decode`，或者 `lanes` 里 `decoding`、`prefilling`、`waiting` 三个数（不是数的按 0，取整用 `Int(x)`）加起来大于 0。
9. 记下这次的快照（第 6 条要用），返回 `(snapshot, max(0.01, 间隔 - (clock() - now)))`。

`perform`、`start`、`stop` 的线程写法如下（验证过能在 Swift 6 下编译、运行），照这个结构写：

```swift
private let lock = NSLock()
private var pending: [() -> Void] = []
private var stopped = false
private var onSnapshot: ((JSON) -> Void)?
private let finished = DispatchSemaphore(value: 0)

public func perform(_ action: @escaping () -> Void) { lock.lock(); pending.append(action); lock.unlock() }

public func start(onSnapshot: @escaping (JSON) -> Void) {
    self.onSnapshot = onSnapshot
    let thread = Thread { [self] in
        while true {
            lock.lock(); let s = stopped; lock.unlock()
            if s { break }
            let (snapshot, wait) = tick()
            self.onSnapshot?(snapshot)
            // 分小段睡，stop 之后最多 0.05 秒就能退出
            var left = wait
            while left > 0 {
                lock.lock(); let s2 = stopped; lock.unlock()
                if s2 { break }
                Thread.sleep(forTimeInterval: min(left, 0.05))
                left -= 0.05
            }
        }
        finished.signal()
    }
    thread.start()
}

public func stop() { lock.lock(); stopped = true; lock.unlock(); _ = finished.wait(timeout: .now() + 1) }
```

`stop()` 在没调过 `start` 时也要能调（直接返回，不等 1 秒）：用一个 `started` 标记区分。

```sh
(cd mac && swift build 2>&1 | grep -E 'error' | head -20; swift build 2>&1 | tail -1)
```

最后一行是 `Build complete!`。

测试 `PollerTests.swift`：`@Suite struct TestPoller`，10 个测试，名字照下面写。文件里写两个私有辅助类型：

- `FakeClock`：`final class`，`var t: Double = 0`；`clock` 传 `{ fakeClock.t }`。
- `FakeSource: EngineSource`：`var issue: EngineIssue = .none`、`var modelIDs: [String] = []`、`var modelName: String?`、`var reads = 0`、`var advance = 0.0`（每次 `read` 让时钟前进多少）、`var queue: [(health: JSON, metrics: JSON)?]`（每次 `read` 取出第一个，取空了返回 nil）、`var log: [String]`（每次 `read` 追加 `"read"`）。它拿着 `FakeClock` 的引用来前进时钟。

读数用 oMLX 实录回放的期望输出 `fixtures/omlx/short.expected.jsonl`：每行一个 JSON 对象，`t` 是时刻，`health`、`metrics` 是统一读数（这个文件里都不是 null），`model` 是模型名。用 `loadFixture` 不行（它读整个文件），自己按行读：`String(contentsOf:)` 按 `"\n"` 拆开，跳过空行，每行 `JSON.parse(Data(line.utf8))`。

每个测试新建 `Collector(config: Config())`；`readMemory` 默认传一个返回 `["used_gb": 10.0, "total_gb": 48.0]` 并记录调用次数的闭包。

1. `test_空闲间隔是0点25`：`short` 的第 1 行（下标 0），时钟 `t = 行里的 t` → 快照的 `state` 不是 `"offline"`、不忙，`wait == 0.25`。
2. `test_忙时间隔是0点1`：`short` 的前 5 行依次 tick，每次 tick 前把时钟设成那一行的 `t` → 第 5 次（`t = 1.062`，这一拍 `prefilling` 是 1）的 `wait == 0.1`。
3. `test_离线间隔是0点5`：`queue` 为空（每次读不到），时钟每拍加 0.5，最多 tick 10 次，直到 `state == "offline"` → 断言确实到了离线，且那一拍 `wait == 0.5`。
4. `test_扣掉读取花的时间`：`short` 第 1 行，`advance = 0.04` → `abs(wait - 0.21) < 1e-9`；再来一次，用第 2 行、`advance = 1.0` → `wait == 0.01`。
5. `test_内存每秒读一次`：`queue` 放 `short` 的前 9 行，时钟依次设成 `0, 0.25, 0.5, …, 2.0`（9 拍）→ `readMemory` 被调 3 次；最后一拍快照的 `memory` 里 `used_gb == 10.0`。
6. `test_引擎提示`：`queue` 为空，`issue = .needsKey`，tick 到离线（同第 3 条）→ `engine_note == .string("oMLX 需要 API key · 在设置里填写")`；新建一组对象，`issue = .notOmlx` → `"这个地址上不是 oMLX"`；再新建一组，`issue = .unreachable` → 快照里没有 `engine_note` 键。
7. `test_模型名交给采集器`：`short` 第 1 行，`modelName = "mlx-community--X-4bit"` → 快照的 `model == .string("mlx-community--X-4bit")`。
8. `test_perform在下一拍开头执行`：`perform` 两个动作，分别往 `FakeSource.log` 追加 `"a"`、`"b"`；tick 之前 `log` 是空的；tick 之后 `log == ["a", "b", "read"]`；再 tick 一次，`log == ["a", "b", "read", "read"]`（动作只执行一次）。
9. `test_换读取`：两个 `FakeSource`，`perform { poller.source = second }` 后 tick → `second.reads == 1`，`first.reads == 0`。
10. `test_后台线程`：用真时钟（`clock`、`wallClock` 用默认值），`FakeSource` 的 `queue` 为空；`start` 时回调里加锁数次数；`Thread.sleep(forTimeInterval: 1.2)` 后 `stop()` → 次数 `>= 2`；记下次数，再睡 0.6 秒，次数没变。

```sh
(cd mac && swift test --filter '\.TestPoller/' 2>&1 | grep -E '✘|error:' | head -20; swift test --filter '\.TestPoller/' 2>&1 | tail -1)
```

前面没有输出，最后一行以 `✔ Test run with 10 tests` 开头、以 `passed after` 加秒数结尾。

## 第三步：`AppSettings.swift`

接口照接口约定 9.4 节，每个属性读写 `defaults` 里对应的键（键名见接口约定）。读的规则：

- `engine`、`address`、`screenName`：`defaults.string(forKey:)` 去掉首尾空白；没有、或去掉后是空串 → 默认值。`manualKey`：去掉首尾空白，没有就是 `""`。写：直接存字符串。
- `keyMode`、`zone`：存 `rawValue`；读出来认不出 → 默认值。
- `prices`：用 `JSONEncoder` 把 `[String: ModelPrice]` 编成 `Data` 存；读时 `JSONDecoder` 解，解不出 → `[:]`。
- `knownModels`：`defaults.stringArray(forKey:) ?? []`。
- `autoSwitchMode`、`launchAtLogin`：`defaults.object(forKey:)` 是 nil → 默认值，否则 `defaults.bool(forKey:)`。
- `zoneIdentifier(systemZone:)`：`.system` → `systemZone`；`.beijing` → `"Asia/Shanghai"`；`.pacific` → `"America/Los_Angeles"`。
- `config(systemZone:)`：从 `Config()` 开始，`timezone = zoneIdentifier(systemZone:)`，`prices = prices`，`modelName = "未加载模型"`；再读这五个只能用 `defaults write` 改的键：`round_gap_s` → `roundGapS`、`prefill_short_s` → `prefillShortS`、`done_hold_s` → `doneHoldS`、`dim_after_s` → `dimAfterS`、`anim_fps` → `animFps`。规则：`defaults.object(forKey:)` 是 `NSNumber`、不是布尔值（`CFGetTypeID(n) != CFBooleanGetTypeID()`）、`doubleValue` 是有限的正数，才采用；否则保留 `Config` 的默认值。
- `apiKey(settingsPath:)`：`.auto` → `omlxApiKey(settingsPath: settingsPath)`；`.manual` → `manualKey` 非空时返回它，否则 nil。
- `rememberModels(_:)`：把 `ids` 里不在 `knownModels` 里的非空名字按原顺序追加到末尾；没有新的就不写。
- `forgetModel(_:)`：从 `knownModels` 和 `prices` 里都删掉这个名字。

测试 `AppSettingsTests.swift`：`@Suite struct TestAppSettings`，9 个测试，名字照下面写。每个测试用一个新的 `UserDefaults(suiteName: "tfpanel-test-" + UUID().uuidString)!`，测试结束 `removePersistentDomain(forName:)` 清掉。

1. `test_默认值`：每个属性都是接口约定里的默认值；`config(systemZone: "Asia/Shanghai")` 的 `timezone == "Asia/Shanghai"`、`prices.isEmpty`、`roundGapS == 60`、`animFps == 10`、`modelName == "未加载模型"`。
2. `test_存了再读`：每个属性改成非默认值，用同一个 `UserDefaults` 新建一个 `AppSettings`，读出来都是改过的值。
3. `test_空白当默认`：`address = "  "` → 读出 `"127.0.0.1:8000"`；`screenName = ""` → `"TYPE-C"`；`address = " 10.0.0.2:8000 "` → `"10.0.0.2:8000"`。
4. `test_认不出的选项用默认`：直接 `defaults.set("xx", forKey: "api_key_mode")`、`defaults.set("xx", forKey: "timezone_choice")` → `keyMode == .auto`、`zone == .system`。
5. `test_单价`：存 `["A": ModelPrice(input: 0.15, cached: 0.016, output: 0.47)]` → 读出相等，`config().prices` 也相等；`defaults.set(Data("x".utf8), forKey: "prices")` → `prices.isEmpty`。
6. `test_时区`：`systemZone: "Asia/Tokyo"` 时三个选项的 `zoneIdentifier` 分别是 `"Asia/Tokyo"`、`"Asia/Shanghai"`、`"America/Los_Angeles"`，`config(systemZone:)` 的 `timezone` 跟着一样。
7. `test_只能用defaults改的键`：`round_gap_s` 存 `30.0` → `roundGapS == 30`；存 `-1.0` → 60；存字符串 `"abc"` → 60；存 `true` → 60；`anim_fps` 存 `20` → 20；`dim_after_s` 存 `Double.infinity` → 1800。
8. `test_apiKey`：临时目录（`FileManager.default.temporaryDirectory` 下新建唯一子目录，测试结束删掉）写 `settings.json`，内容 `{"auth": {"api_key": "k1"}}`；`.auto` → `"k1"`；`.manual` 且 `manualKey = "k2"` → `"k2"`；`.manual` 且 `manualKey = ""` → nil。
9. `test_记住和忘掉模型`：`rememberModels(["A", "B"])`、`rememberModels(["B", "", "C"])` → `knownModels == ["A", "B", "C"]`；`prices = ["B": …]` 后 `forgetModel("B")` → `knownModels == ["A", "C"]`、`prices.isEmpty`。

```sh
(cd mac && swift test --filter '\.TestAppSettings/' 2>&1 | grep -E '✘|error:' | head -20; swift test --filter '\.TestAppSettings/' 2>&1 | tail -1)
```

前面没有输出，最后一行以 `✔ Test run with 9 tests` 开头、以 `passed after` 加秒数结尾。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | grep -E '✘' | head; swift test 2>&1 | tail -1)
git status --short
```

通过的标准：

- 第一条前面没有输出，最后一行以 `✔ Test run with` 开头、以 `passed after` 加秒数结尾，测试个数是 N + 20（N 是开始前记下的个数）。
- `git status --short` 只列出本任务的六个文件（`??`）。

全部通过后最后一行输出 `DONE`。
