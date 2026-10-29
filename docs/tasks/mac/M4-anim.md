# 任务 M4：把动画模块 `panel/anim.py` 翻译成 Swift

先读 `AGENTS.md`，再读接口约定 `docs/tasks/mac/00-contracts.md`（尤其第 2、5、6、7 节）。本任务只新建这两个文件：

- `mac/Sources/PanelCore/Animator.swift`
- `mac/Tests/PanelCoreTests/AnimTests.swift`

不要改别的文件。基础文件（`JSON.swift`、`Config.swift`、`Fmt.swift`、`Scale.swift`、`View.swift`、`TestSupport.swift`）里发现问题时不要改，写进结果报告。

## 背景

动画模块在两次视图更新之间做过渡：每画一帧调用一次 `step(view, now)`，得到这一帧的 `Frame`（圆弧位置、各部分的透明度、主数字滚动到哪、整屏亮度等）。`settled(view)` 给出不带过渡、直接到位的那一帧。Python 版 `panel/anim.py` 的行为就是规格：缓动公式、时长、`dt` 的上限、数字滚动的取整都要相同。

## 第一步：翻译 `Animator.swift`

- 公开接口照接口约定第 5 节“动画（M4）”：`Frame` 结构体（字段名、类型、默认值、顺序照抄）、`Animator` 类（`init()`、`step(_:now:)`、`static settled(_:)`）。
- `anim.py` 里的模块级函数、常量翻成文件内的 `private` 函数、常量；`js_round` 用基础文件里的 `jsRound`。
- `math.exp` → `exp`，其余取整照接口约定第 6 节。

```sh
(cd mac && swift build 2>&1 | tail -3)
```

应输出 `Build complete!`（前面可能有一行编译进度）。

## 第二步：翻译测试 `AnimTests.swift`

照接口约定第 7 节，把 `panel/tests/test_anim.py` 的 15 个测试类、34 个测试方法逐个翻过来：

- 常量 `STEP`、辅助函数 `times`、`feed`、`cards` 翻成文件里的 `private` 常量和函数。构造 `View` 用 `View()` 再逐个赋值。
- Python 用字段名取值的地方（`getattr(frame, name)`、类里的 `ALPHA_FIELDS` 这类名字列表）翻成“名字 + 键路径”的列表，例如 `[("center_alpha", \Frame.centerAlpha), ...]`，名字写进 `#expect` 的说明里。
- `for name in Frame.__dataclass_fields__` 逐个比较两帧的全部字段：`Double` 字段按 `delta` 比较（用一个列出 `Frame` 全部 `Double` 字段的键路径列表），`bigInt`、`bigDec`、`animating` 用 `==` 比较。

```sh
(cd mac && swift test 2>&1 | grep -E '✘|error:' | head -20; swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/AnimTests.swift
```

第一条：前面没有输出，最后一行以 `✔ Test run with 55 tests` 开头（21 个已有的基础测试 + 34 个本任务的测试）、以 `passed after` 加秒数结尾。第二条输出 `34`。

测试不通过时，以 Python 版为准判断是翻译错了还是测试翻错了：可以用 `python3 -m unittest panel.tests.test_anim -k <测试名>` 在仓库根目录跑 Python 版对照；要看中间值就在仓库根目录用 `python3 -c '...'` 导入 `panel.anim` 自己打印，不要改 `panel/` 里的文件。

## 最后一步：收尾检查

```sh
(cd mac && swift test 2>&1 | tail -1)
grep -cE '^\s*@Test' mac/Tests/PanelCoreTests/AnimTests.swift
git status --short
```

通过的标准：

- 第一条输出以 `✔ Test run with 55 tests` 开头、以 `passed after` 加秒数结尾。
- 第二条输出 `34`。
- `git status --short` 只列出 `mac/Sources/PanelCore/Animator.swift` 和 `mac/Tests/PanelCoreTests/AnimTests.swift` 两个新文件（`??`）。

全部通过后最后一行输出 `DONE`。

本任务在单独的工作目录里做，这里只有基础文件和本任务的文件；其他模块（采集、今日用量、视图模型）由别的任务同时在别处翻译，这里没有它们，也不需要它们。
