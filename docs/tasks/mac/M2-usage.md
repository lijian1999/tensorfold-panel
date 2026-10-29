# 任务 M2：把今日用量模块 `panel/usage.py` 翻译成 Swift

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（尤其第 3、5、6、7 节）。本任务只新建这两个文件：

- `mac/Sources/PanelCore/Usage.swift`
- `mac/Tests/PanelCoreTests/UsageTests.swift`

不要改别的文件。基础文件（`JSON.swift`、`Config.swift`、`Fmt.swift`、`Scale.swift`、`View.swift`、`TestSupport.swift`）里发现问题时不要改，写进结果报告。

## 背景

今日用量账本从采集模块收到引擎的累计计数（输入、命中缓存、输出、请求数），算出“今天”的用量和费用，跨过当地午夜时清零并把昨天的一行追加到历史文件。状态存在 `usage.json`，程序重启后接着算。Python 版 `panel/usage.py` 的行为就是规格：文件名、文件里的键、写文件的时机、日期的划分都要相同。

## 第一步：翻译 `Usage.swift`

- 公开接口照接口约定第 5 节“今日用量（M2）”。`UsageLedger` 实现 `UsageSink` 协议，但这个协议由另一个任务在 `Collector.swift` 里定义，这里还没有。为了能编译，在 `Usage.swift` 末尾临时放一份协议定义，原样照抄接口约定第 5 节，前面加一行注释 `// 临时：合并时删掉，以 Collector.swift 里的为准`。
- `update`、`today`、`flush` 在 Swift 里不抛异常（不写 `throws`）；Python 里吞掉的文件读写错误，Swift 里同样吞掉。
- 时区：`_zone` 的三级回退照做：`TimeZone(identifier: config.timezone)` → `TimeZone(identifier: "America/Los_Angeles")` → `TimeZone(secondsFromGMT: -8 * 3600)!`。
- 日期：时间戳换成当地的 `YYYY-MM-DD` 用公历日历，不要用依赖系统区域设置的格式化：

  ```swift
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = zone
  let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
  let date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  ```

- 路径：`stateDir` 开头的 `~` 用 `(path as NSString).expandingTildeInPath` 展开。建目录用 `FileManager.default.createDirectory(atPath:withIntermediateDirectories: true)`。
- 文件内容：`json.dumps(payload, ensure_ascii=False) + "\n"` 用 `payload.serialized() + "\n"`，UTF-8 写入。
- 原子替换 `usage.json`（Python 的 `mkstemp` + `os.replace`）：用 `try Data(text.utf8).write(to: url, options: .atomic)`，它先写临时文件再改名，效果相同。
- 追加历史行（`usage-history.jsonl`）：文件不存在就新建，存在就用 `FileHandle(forWritingTo:)`、`seekToEnd()`、`write(contentsOf:)` 追加。

```sh
(cd mac && swift build 2>&1 | tail -3)
```

应输出 `Build complete!`（前面可能有一行编译进度）。

## 第二步：翻译测试 `UsageTests.swift`

照接口约定第 7 节，把 `panel/tests/test_usage.py` 的 9 个测试类、25 个测试方法逐个翻过来：

- `utc_ts`、常量 `NOON`、`LATE_NIGHT`、`MIDNIGHT`、`EVENING`、`TOTALS`、`BIGGER`、`SMALLER` 翻成文件里的 `private` 函数和常量；`utc_ts` 用 UTC 时区的公历日历拼时间戳。
- 假时钟 `Clock` 翻成 `private final class Clock`，有一个可改的 `ts`；传给账本的是 `{ clock.ts }`。
- `LedgerTest` 的 `setUp`、`ledger(...)` 等公共部分翻成每个套件都用的辅助类型或函数。临时目录用 `FileManager.default.temporaryDirectory` 下新建的唯一子目录，测试结束删掉（swift-testing 的测试会并行跑，每个测试用自己的目录）。
- 读文件修改时间（Python 的 `os.stat(path).st_mtime_ns`）：`(try FileManager.default.attributesOfItem(atPath: path))[.modificationDate] as! Date`，比较两个 `Date` 是否相等。

```sh
(cd mac && swift test 2>&1 | grep -E '✘|error:' | head -20; swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/UsageTests.swift
```

第一条：前面没有输出，最后一行以 `✔ Test run with 46 tests` 开头（21 个已有的基础测试 + 25 个本任务的测试）、以 `passed after` 加秒数结尾。第二条输出 `25`。

测试不通过时，以 Python 版为准判断是翻译错了还是测试翻错了：可以用 `python3 -m unittest panel.tests.test_usage -k <测试名>` 在仓库根目录跑 Python 版对照；要看中间值就在仓库根目录用 `python3 -c '...'` 导入 `panel.usage` 自己打印，不要改 `panel/` 里的文件。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/UsageTests.swift
git status --short
```

通过的标准：

- 第一条输出以 `✔ Test run with 46 tests` 开头、以 `passed after` 加秒数结尾。
- 第二条输出 `25`。
- `git status --short` 只列出 `mac/Sources/PanelCore/Usage.swift` 和 `mac/Tests/PanelCoreTests/UsageTests.swift` 两个新文件（`??`）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做，这里只有基础文件和本任务的文件；其他模块（采集、视图模型、动画）由别的任务同时在别处翻译，这里没有它们，也不需要它们。
