# 任务 M3：把视图模型 `panel/viewmodel.py` 翻译成 Swift

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（尤其第 2、3、5、6、7 节）。本任务只新建这三个文件：

- `mac/Sources/PanelCore/ViewModel.swift`
- `mac/Tests/PanelCoreTests/ViewModelTests.swift`
- `mac/Tests/PanelCoreTests/FixturesTests.swift`

不要改别的文件。基础文件（`JSON.swift`、`Config.swift`、`Fmt.swift`、`Scale.swift`、`View.swift`、`TestSupport.swift`）里发现问题时不要改，写进结果报告。

## 背景

视图模型把一份指标快照（JSON 对象，样例在 `fixtures/*.json`）变成画面上要写的东西（`View`：状态条、主数字、圆弧、右侧三栏等）。它不画图，只决定写什么字、用什么样式。Python 版 `panel/viewmodel.py` 的行为就是规格：每个文字、每个分支、每处取整都要相同。

## 第一步：翻译 `ViewModel.swift`

- 公开接口照接口约定第 5 节“视图模型（M3）”：`ViewModel` 类，`init(config:)`、`update(_:now:)`。
- 用到的格式化函数、刻度用基础文件里已有的（`tokFmt`、`split1`、`costFmt`、`durFmt`、`dateLabel`、`pct`、`jsRound`、`v2f`、`scales`），不要另写一份。
- `viewmodel.py` 里的模块级函数、常量翻成文件内的 `private` 函数、常量；`ViewModel` 在两次 `update` 之间记住的状态照 Python 放在实例里。
- 快照里取值照接口约定第 3 节的对照表：缺键、值为 null、类型不对时走的分支要和 Python 相同。

```sh
(cd mac && swift build 2>&1 | tail -3)
```

应输出 `Build complete!`（前面可能有一行编译进度）。

## 第二步：翻译测试 `ViewModelTests.swift`

照接口约定第 7 节，把 `panel/tests/test_viewmodel.py` 的 11 个测试类、39 个测试方法逐个翻过来：

- 辅助函数 `plain`、`marks`、`read`、`view_of`、`cards` 翻成文件里的 `private` 函数。`read(name, **overrides)` 翻成 `read(_ name: String, _ overrides: [String: JSON] = [:]) -> JSON`，用 `loadFixture("\(name).json")` 读，再把 `overrides` 的键逐个盖上去；`view_of` 同理。`cards` 返回的四元组可以用一个 `Equatable` 的小结构体代替元组，方便 `#expect` 比较。
- `FixtureCase.check(...)` 翻成一个 `private` 函数，里面照样断言“恰好三栏”“`View(json: view.toJSON()) == view`”。
- Python 的 `TestOffline` 在 Swift 里叫 `TestOfflineView`（另一个文件里已经有一个 `TestOffline` 套件）。其余类名照抄。

```sh
(cd mac && swift test 2>&1 | grep -E '✘|error:' | head -20; swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/ViewModelTests.swift
```

第一条：前面没有输出，最后一行以 `✔ Test run with 60 tests` 开头（21 个已有的基础测试 + 39 个本步的测试）、以 `passed after` 加秒数结尾。第二条输出 `39`。

测试不通过时，以 Python 版为准判断是翻译错了还是测试翻错了：可以用 `python3 -m unittest panel.tests.test_viewmodel -k <测试名>` 在仓库根目录跑 Python 版对照；要看中间值就在仓库根目录用 `python3 -c '...'` 导入 `panel.viewmodel` 自己打印，不要改 `panel/` 里的文件。

## 第三步：翻译测试 `FixturesTests.swift`

把 `panel/tests/test_fixtures.py` 的 2 个测试类、11 个测试方法逐个翻过来（它检查 `fixtures/` 下样例文件的格式，不依赖视图模型）：

- 常量集合（`TOP_KEYS`、`FIXTURE_NAMES` 等）翻成 `private let ...: Set<String>`。
- `fixture_paths()`：列出 `fixturesDir` 下扩展名为 `.json` 的文件（不进子目录），按文件名排序；`each_fixture` 的循环翻成普通循环，文件名写进 `#expect` 的说明里。
- 判断“是对象、是整数、是数字”照接口约定第 3 节的对照表。

```sh
(cd mac && swift test 2>&1 | grep -E '✘|error:' | head -20; swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/FixturesTests.swift
```

第一条：前面没有输出，最后一行以 `✔ Test run with 71 tests` 开头、以 `passed after` 加秒数结尾。第二条输出 `11`。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/ViewModelTests.swift mac/Tests/PanelCoreTests/FixturesTests.swift
git status --short
```

通过的标准：

- 第一条输出以 `✔ Test run with 71 tests` 开头、以 `passed after` 加秒数结尾。
- 第二条输出两行，分别以 `:39` 和 `:11` 结尾。
- `git status --short` 只列出 `mac/Sources/PanelCore/ViewModel.swift`、`mac/Tests/PanelCoreTests/ViewModelTests.swift`、`mac/Tests/PanelCoreTests/FixturesTests.swift` 三个新文件（`??`）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做，这里只有基础文件和本任务的文件；其他模块（采集、今日用量、动画）由别的任务同时在别处翻译，这里没有它们，也不需要它们。
