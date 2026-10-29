# 任务 M1：把采集模块 `panel/collector.py` 翻译成 Swift

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（尤其第 3、5、6、7 节）。本任务只新建这两个文件：

- `mac/Sources/PanelCore/Collector.swift`
- `mac/Tests/PanelCoreTests/CollectorTests.swift`

不要改别的文件。基础文件（`JSON.swift`、`Config.swift`、`Fmt.swift`、`Scale.swift`、`View.swift`、`TestSupport.swift`）里发现问题时不要改，写进结果报告。

## 背景

采集模块每秒收到一次读数（`/health` 的解析结果、可选的 `/metrics` 解析结果、内存、模型名），维护请求、轮次、速度这些状态，输出一份指标快照（JSON 对象）。Python 版 `panel/collector.py` 的行为就是规格：快照的每个键、每个值的类型、每个分支都要相同。今日用量通过 `UsageSink` 协议交给账本，本任务只定义这个协议，不实现账本。

## 第一步：翻译 `Collector.swift`

- 公开接口照接口约定第 5 节“采集（M1）”：`UsageSink` 协议、`Collector` 类（`init(config:usage:)`、`prefillTps`、`feed(now:health:metrics:memory:model:)`）。
- `collector.py` 里的模块级函数、常量（`_number`、`NO_TODAY`、`NO_MEMORY`、`_blank_snapshot` 等）翻成文件内的 `private` 函数、常量。
- 快照里的整数用 `.int`，小数用 `.double`，`None` 用 `.null`，和 Python 版输出的类型一致。
- 调账本的地方（`usage.update(...)`、`usage.today()`）Python 吞掉一切异常，Swift 用 `try?`，吞掉之后的回退值照 Python。

```sh
(cd mac && swift build 2>&1 | tail -3)
```

应输出 `Build complete!`（前面可能有一行编译进度）。

## 第二步：翻译测试 `CollectorTests.swift`

照接口约定第 7 节，把 `panel/tests/test_collector.py` 的 19 个测试类、48 个测试方法逐个翻过来：

- 辅助函数 `health`、`every_tenth`、`hook_rows`、`scene1_c`、`scene1_steps`、`vhealth`、`vmetrics`、`vrow`、`vllm_long_scene`，辅助类 `FakeUsage`、`Scene`，都翻成同一文件里的 `private` 函数和类型。`FakeUsage` 实现 `UsageSink`。Python 的关键字参数翻成带默认值的参数，参数名用原名。
- `TestRobustness` 里断言“能 `json.dumps`”的地方，换成 `#expect(JSON.parse(snap.serialized()) == snap)`；`json.dumps(snap, sort_keys=True, ensure_ascii=False)` 用 `snap.serialized()`。
- 读 `fixtures/idle.json` 用 `loadFixture("idle.json")`；这个文件一定存在，不用翻 Python 里“文件不存在就跳过”的分支。

```sh
(cd mac && swift test 2>&1 | grep -E '✘|error:' | head -20; swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/CollectorTests.swift
```

第一条：前面没有输出，最后一行以 `✔ Test run with 69 tests` 开头（21 个已有的基础测试 + 48 个本任务的测试）、以 `passed after` 加秒数结尾。第二条输出 `48`。

测试不通过时，以 Python 版为准判断是翻译错了还是测试翻错了：可以用 `python3 -m unittest panel.tests.test_collector -k <测试名>` 在仓库根目录跑 Python 版对照，要看中间值就在仓库根目录用 `python3 -c '...'` 导入 `panel.collector` 自己打印，不要改 `panel/` 里的文件。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/CollectorTests.swift
git status --short
```

通过的标准：

- 第一条输出以 `✔ Test run with 69 tests` 开头、以 `passed after` 加秒数结尾。
- 第二条输出 `48`。
- `git status --short` 只列出 `mac/Sources/PanelCore/Collector.swift` 和 `mac/Tests/PanelCoreTests/CollectorTests.swift` 两个新文件（`??`）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做，这里只有基础文件和本任务的文件；其他模块（今日用量、视图模型、动画）由别的任务同时在别处翻译，这里没有它们，也不需要它们。
