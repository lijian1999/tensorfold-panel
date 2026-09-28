# 任务 E2：副屏上下文条 + 单位并入标题行（Swift）

先读 `AGENTS.md`，再读 `docs/design.md`「字号、配色与动画」里“标题行”和“上下文条”两条、「每个状态显示什么」里完成画面的状态条、「指标接口」里 `current.prompt_tokens`。原型 `docs/dashboard-prototype.html` 已按新设计改好（`.ctx` 相关 CSS、`view()` 末尾的上下文计算、`apply()` 里的“上下文条”和标题行），可以对照，但**以本文件为准**。

然后读：

- `display/Sources/PanelCore/Metrics.swift`
- `display/Sources/PanelCore/PanelModel.swift`
- `display/Sources/TFPanel/PanelScreenView.swift`
- `display/Sources/TFPanel/Snapshot.swift`
- `display/Tests/PanelCoreTests/AllTests.swift`

本任务只改上面这些文件和 `display/Fixtures/`，不碰 `collector/`、`docs/`、`scripts/`。

## 背景

- 原始速度小曲线整体去掉，原位置改为上下文占用条。
- 单位不再单独占一行，并入标题行：“解码速度 · tok/s”。
- 完成画面的状态条原来写“上下文 632 / 262K”，现在上下文已经在仪表下方，改成“首字 0.10 s”。
- 采集器已经在 `current` 里提供 `prompt_tokens`（本次提示 token 数，精确；拿不到时为 `null`）。

## 1. Metrics.swift

`Metrics.Current` 新增 `public var promptTokens: Int?`（JSON 键 `prompt_tokens`），`init` 在**最后**增加参数 `promptTokens: Int? = nil`（保证现有调用不用改）。

## 2. PanelModel.swift

### 2.1 去掉小曲线（全部删除）

- `SparkSample` 类型。
- `ConnectionTracker` 里的 `sparkSamples`、`lastSampleAt`、`tokenHistory`、`lastState`、`decodeSampleStart` 以及 `recordSuccess` 里所有采样、清空样本的代码。`recordSuccess` 只保留：在线、失败计数归零、`firstFailureAt`、`lastSuccess`、`fetchedAt`、`rememberedLast`、`rememberedModel`。
- `PanelViewModel` 的 `showSpark`、`spark` 两个属性。

### 2.2 上下文

新增：

```swift
/// 上下文占用等级：< 80% 普通，80%–95% 警告，≥ 95% 快满
public enum ContextLevel: String, Sendable { case normal, warn, full }

public struct ContextUsage: Equatable, Sendable {
    public var used: Int
    public var limit: Int
    public init(used: Int, limit: Int)
    /// used ÷ limit，钳制在 0…1
    public var fraction: Double
    /// fraction ≥ 0.95 → .full；≥ 0.8 → .warn；否则 .normal（用钳制前的比值判断也可以，结果相同）
    public var level: ContextLevel
    /// 文字行：[StripSegment("上下文 "), StripSegment(Format.tokFmt(used), bold: true), StripSegment(" / " + Format.tokFmt(limit))]
    public var segments: [StripSegment]
}
```

`PanelViewModel` 新增存储属性 `public var context: ContextUsage?`，`make()` 按下表赋值。`limit` = `m.contextMax`；`contextMax` 为空或 ≤ 0 时一律为 `nil`。

| state | used | 缺数据时 |
| --- | --- | --- |
| offline / unavailable / starting | — | 一律 `nil` |
| prefill（长短都一样，单请求和一轮模式都一样） | `current.promptTokens` | `promptTokens` 为空 → `nil` |
| decode（单请求和一轮模式都一样） | `current.promptTokens + (current.outputTokens ?? 0)` | `promptTokens` 为空 → `nil` |
| done（单请求和一轮模式都一样） | `m.last.contextUsed` | 为空 → `nil` |
| idle（单请求和一轮模式都一样） | `(m.last ?? tracker.rememberedLast).contextUsed` | 为空 → `nil` |

### 2.3 标题行

新增计算属性：

```swift
/// 标题行文字 = 标题 · 单位；两者任一为空时只用标题
public var capText: String   // cap 和 unit 都非空 → "\(cap) · \(unit)"，否则 cap
```

`cap`、`unit` 两个属性保留不变（淡入键 `centerFadeKey` 也不变）。

### 2.4 完成画面的状态条

单请求的 doneView 和一轮模式的 done 画面，`stripRight` 都改为：

```swift
[StripSegment("首字 "), StripSegment(ttft, bold: true), StripSegment(" s")]
```

`ttft` = `m.last?.ttftS` 用 `Format.fixed(_, 2)`；为空时为 `"—"`。删除 `contextStrip` 辅助函数。

## 3. PanelScreenView.swift

- **标题行**：`capRow` 里的文字改用 `model.capText`（字号、颜色、位置不变，“精确”药丸仍跟在后面）。
- **删除单位行** `unitRow` 和小曲线 `sparkView`、`sparkPath`。
- **新增上下文条**（`model.context` 非空时显示；坐标相对仪表区左上角，和原型 `.ctx` 一致）：
  - 长条：`x = 94`，`y = 205`，宽 120，高 6，圆角 3。底色 `Theme.track`；填充从左边开始，宽 = `120 × fraction`，圆角 3，颜色：`.normal` → `Theme.text2`，`.warn` → `Theme.amber`，`.full` → `Theme.danger`。
  - 文字：长条下方 5，即 `y = 216`，行高 14，宽 220 居中（`x = 44…264`），12 号；`segments` 里普通段 `Theme.muted`、`bold` 段 `Theme.text2` + semibold；数字用等宽数字。
  - 上下文条放在 CenterView 里，跟中间区域一起淡入（用 `frame.centerOpacity`）。`message` 非空（离线等）时不显示。
- 所有尺寸照旧乘以 `s`。

## 4. Snapshot.swift

删除注入小曲线样本的那段代码（`sparkSamples` 已不存在）。

## 5. Fixtures（display/Fixtures/）

在 `current` 里加 `prompt_tokens`（没有 `current` 的文件不动）：

| 文件 | `current.prompt_tokens` |
| --- | --- |
| `decode.json`、`round-decode.json` | 18420 |
| `prefill.json` | 35012 |
| `prefill-short.json` | 1240 |
| `round-prefill-short.json`、`round-prefill-long.json` | 18420 |

新增 2 个文件，都照抄修改后的 `decode.json`，只改 `current.prompt_tokens`：

- `decode-ctx-warn.json`：215000（215312 / 262144 ≈ 82%，琥珀色）
- `decode-ctx-full.json`：250000（250312 / 262144 ≈ 95.5%，红色）

## 6. 测试（display/Tests/PanelCoreTests/AllTests.swift）

**删除**这些测试（功能已去掉）：名字以“小曲线：”开头的 6 条、`decode → done 保留小曲线样本，新请求才清空`、`done 画面：有小曲线样本时 showSpark 且 spark 非空`。

**只允许**这样修改现有测试，其他一律不动：

- 删除所有对 `showSpark`、`spark`、`sparkSamples` 的断言和赋值。
- `done：引擎精确成绩`：状态条断言改为 `v.stripRight.map(\.text).joined() == "首字 0.10 s"`，`bold` 仍为 `[false, true, false]`。
- `done：contextMax 为空时省略「 / …」；样本数 > 5 显示小曲线` 改名为 `done：contextMax 为空时不显示上下文条`，断言 `v.context == nil`。
- 一轮模式那组里 `round-done` 的测试：名字里的“状态条仍是上下文”改为“状态条为首字”，断言改为 `v.stripRight.first == StripSegment("首字 ")`。
- 如果某条已有测试构造 `PanelViewModel` 或 `ConnectionTracker` 时用到了被删的属性而编译不过，只删掉那一处用法。

**新增**测试（每条一个 `@Test`）：

1. `Metrics` 解码 `current.prompt_tokens`；两个新 fixture 能解码。
2. `capText`：decode 为 `解码速度 · tok/s`，单请求 idle 为 `上次平均 · tok/s`，长预填充为 `已用时 · 秒`，一轮模式 done 为 `本轮平均 · tok/s`，offline 为 `""`。
3. decode（`decode.json`）：`context == ContextUsage(used: 18732, limit: 262144)`，`segments` 的文字依次为 `上下文 `、`18.7K`（bold）、` / 262K`，`level == .normal`。
4. 预填充只算提示：`prefill-short.json` → `used == 1240`；`prefill.json` → `used == 35012`；`round-prefill-long.json` → `used == 18420`。
5. idle（`idle.json`）→ `used == 592`；done（`done.json`）→ `used == 632`；`round-done.json` → 等于该文件 `last.context_used`。
6. `decode-ctx-warn.json` → `.warn`；`decode-ctx-full.json` → `.full`。边界：`ContextUsage(used: 80, limit: 100).level == .warn`，`(79, 100)` 为 `.normal`，`(95, 100)` 为 `.full`，`(120, 100).fraction == 1`。
7. 缺数据：decode 且 `promptTokens` 为 nil → `context == nil`；`contextMax` 为 nil → `nil`；offline、unavailable、starting → `nil`。
8. 完成画面 `last.ttftS` 为 nil → `stripRight` 文字为 `首字 — s`。

## 完成前必须运行并全部通过

```sh
cd display && swift build && swift test && rm -rf /tmp/tfpanel-shots && .build/debug/TFPanel --snapshot-all /tmp/tfpanel-shots && ls /tmp/tfpanel-shots
```

`ls` 应列出 17 张 PNG（原有 15 张 + 新增 2 张）。你看不到图片，截图由编排者逐张检查。

`grep -rn "spark\|Spark" display/Sources display/Tests` 应该没有任何结果。

如果 `swift test` 报 `plugin for module 'TestingMacros' not found`，这是本机工具链偶发的 bug，直接重跑一次，不要改 `Package.swift`。

不要运行不带 `--snapshot` 参数的 `.build/debug/TFPanel`（会启动窗口程序，副屏上已经有一个在运行）。
