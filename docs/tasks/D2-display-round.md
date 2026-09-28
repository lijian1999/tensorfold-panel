# 任务 D2：副屏显示“一轮”与短预填充（Swift）

先读 `AGENTS.md`，再读 `docs/design.md` 的「连续请求（一轮）与短预填充」「指标接口」里的 `round` 字段、「每个状态显示什么」（包括新增的一轮模式表格）、「字号、配色与动画」里的“缓动起点”和“淡入”两条。然后读下面这些文件：

- `display/Sources/PanelCore/Metrics.swift`
- `display/Sources/PanelCore/PanelModel.swift`
- `display/Sources/TFPanel/PanelAnimator.swift`
- `display/Sources/TFPanel/PanelScreenView.swift`
- `display/Tests/PanelCoreTests/AllTests.swift`（`PanelViewModel.make` 那一组和 `Metrics` 解码那一组）

原型 `docs/dashboard-prototype.html` 已按新设计改好（`view()`、`apply()`、`frame()`），可以对照，但**以本文件为准**。本任务只改本文件列出的文件，不碰 `collector/`、`docs/`、`scripts/`。

采集器已经在 `/metrics` 顶层提供：

```json
"round": { "requests": 9, "output_tokens": 1834, "decode_tps_avg": 78.4, "elapsed_s": 96.5, "active": true }
```

`requests` 是本轮**已完成**的请求数（不含进行中的）。老版本采集器没有 `round` 字段，这时一律按单请求画面显示。

## 1. Metrics.swift

新增：

```swift
public struct Round: Decodable, Sendable {
    public var requests: Int?
    public var outputTokens: Int?
    public var decodeTpsAvg: Double?
    public var elapsedS: Double?
    public var active: Bool?
    // init：所有参数带默认值 nil；CodingKeys：output_tokens / decode_tps_avg / elapsed_s
}
```

`Metrics` 增加属性 `public var round: Round?`（JSON 键 `round`），`init` 在**最后**增加参数 `round: Round? = nil`（放在 `totals` 之后，保证现有调用不用改）。

## 2. PanelModel.swift

### 2.1 删除和新增

- 删除 `ArcMode.comet` 和 `PanelViewModel.cometPhase`（预填充不再有扫动弧）。
- `PanelViewModel` 新增存储属性 `public var muted: Bool`：画面是“不在解码时的灰色画面”时为 `true`，大数字、卡片数值用灰色（`text2`），“精确”药丸用描边样式。
- 新增常量 `public static let shortPrefillS: Double = 3.0`。
- 新增两个计算属性（淡入用，见第 3 节）：
  - `public var centerFadeKey: String` = `"\(cap)|\(unit)|\(whole)|\(muted)|\(message?.title ?? "")"`
  - `public var cardsFadeKey: String` = 三张卡片的 `label` 用 `"|"` 连起来

### 2.2 一轮模式的判定

`make()` 确定 state 之后（只对 idle / prefill / decode / done 生效），计算：

```
let round = m?.round
let inFlight = (state == .prefill || state == .decode)
let roundCount = (round?.requests ?? 0) + (inFlight ? 1 : 0)
let roundMode = round != nil && roundCount >= 2
let roundActive = inFlight || (round?.active ?? false)
```

### 2.3 一轮模式的三张卡片（roundCards）

标签随 `roundActive` 变化：`true` 用左边，`false` 用右边。

| # | 标签 | value | unit | foot |
| --- | --- | --- | --- | --- |
| 1 | 本轮请求 / 上轮请求 | `"\(roundCount)"` | `次` | `round.elapsedS` 非空时为 `"用时 \(v) \(u)"`，`(v, u)` 用已有的 `durationParts`（例如 96.5 → `用时 1 分钟`，42 → `用时 42 秒`）；为空时 `""` |
| 2 | 累计输出 / 上轮输出 | `Format.tokFmt(Double(已完成输出 + 进行中输出))`：已完成 = `round.outputTokens ?? 0`；进行中 = state 为 decode 时 `m.current?.outputTokens ?? 0`，否则 0 | `tok` | `""` |
| 3 | 本轮平均 / 上轮平均 | `round.decodeTpsAvg` 非空：`Format.fixed(v, 1)`，unit `""`，foot `tok/s`；为空：`Card.pending(标签)` | | |

### 2.4 “灰色画面”（restView）

不在解码时画面的公共部分。返回一个 `PanelViewModel`，`state` / `stateName` 由调用方传入，`stripLeft` = 模型短名，`stripRight = []`，`muted = true`，`arc = .rest`，`showSpark = false`，`spark = []`，`message = nil`，`whole = false`，`unit = "tok/s"`。

- **单请求**（`roundMode == false`）：cap、pill、bigInt/bigDec、arcTarget、ghostFraction、cards **与现在的 idleView 完全相同**（包括 last 为空时 `—` 和 pill 为 false 的情况）。
- **一轮模式**：设 `avg = round.decodeTpsAvg`：
  - `cap` = `roundActive ? "本轮平均" : "上轮平均"`
  - `pill` = `avg != nil`
  - `avg` 非空：`(bigInt, bigDec) = Format.split1(avg)`；为空：`bigInt = "—"`，`bigDec = ""`
  - `arcTarget = avg ?? 0`，`ghostFraction = avg.map(Gauge.valueToFraction)`
  - `cards` = 2.3 的三张卡片

### 2.5 各状态画面

| state | 单请求 | 一轮模式 |
| --- | --- | --- |
| idle | restView，stateName `空闲` | restView，stateName `空闲` |
| done | **现在的 doneView，不变**（`muted = false`） | restView，stateName `完成`，`stripRight` = 现在 doneView 的“上下文 X / Y”那几段（抽成一个辅助函数两边共用） |
| decode | **现在的 decodeView，不变**（`muted = false`） | 现在的 decodeView，只把 `cards` 换成 2.3 的三张卡片 |
| prefill | 见下 | 见下 |

**prefill**：已用时 `elapsed` 的算法不变（`current.elapsed_s + (now − fetchedAt)`）。

- `elapsed < shortPrefillS`（短预填充）：先取 restView（state `.prefill`，stateName `预填充中`），再把 `stripRight` 设为
  `[StripSegment("已用时 "), StripSegment(Format.fixed(elapsed, 1), bold: true), StripSegment(" s")]`。其他字段保持 restView 的值（所以画面和预填充之前一样，只有状态条变化）。
- `elapsed >= shortPrefillS`（长预填充）：先取同样的 restView，再覆盖这些字段：
  - `muted = false`，`pill = false`，`cap = "已用时"`，`whole = true`，`unit = "秒"`
  - `bigInt/bigDec`：`elapsed < 10` 时 `Format.split1(elapsed)`，否则 `("\(Int(elapsed))", "")`（和现在一样）
  - `stripRight = [StripSegment("提示较长，可能需要几秒")]`
  - `arc`、`arcTarget`、`ghostFraction` 保持 restView 的值（圆弧不动，小点留在原位）
  - `cards`：单请求时用现在 prefillView 的三张（输出 — / 首字 — 等待首个 token / 内存）；一轮模式保持 restView 的一轮卡片

offline / unavailable / starting 三个画面不变，`muted = false`。

## 3. PanelAnimator.swift

- **缓动目标**：`arc == .value` 或 `arc == .rest` 时目标 = `model.arcTarget`，其他为 0。这样不在解码时缓动值停在灰色主数字处，解码开始时大数字从这个值缓动到实时速度，不再每次从 0 涨上来。`settled(model:)` 的 `display` 用同一规则。
- **淡入**：把 `Frame.fadeOpacity` 换成三个：`stripOpacity`、`centerOpacity`、`cardsOpacity`，各自独立计时：
  - 状态条：`model.stateName` 变化时淡入；
  - 中间：`model.centerFadeKey` 变化时淡入；
  - 右侧：`model.cardsFadeKey` 变化时淡入。
  - 曲线、时长和现在相同：0.15 → 1，一般 0.32 s ease-out；本次 tick 中 state 从 `.done` 变为 `.idle` 时，这一帧触发的淡入用 0.8 s ease-in-out。第一次 tick 视为变化（和现在一样启动时淡入）。
  - `settled(model:)` 三个都为 1。`isSettled` 要求三个淡入都已结束，其他条件不变。
  - 不要删除或改动脉冲、大数字 0.25 s 节流的逻辑。
- 删除注释里“彗星”的说法。

## 4. PanelScreenView.swift

- 删除 DialView 里“4. 预填充扫动弧段”整段，以及注释里“彗尾 + 彗星”的说法。
- StripView 用 `frame.stripOpacity`，GaugeView 里 CenterView 用 `frame.centerOpacity`，CardsView 用 `frame.cardsOpacity`。
- 药丸描边样式的条件 `model.state == .idle` 改为 `model.muted`；大数字灰色的条件 `model.state == .idle` 改为 `model.muted`。
- CardView 不再接收 `state` 判断灰色，改为接收 `muted: Bool`（由 CardsView 传 `model.muted || model.state == .offline || model.state == .unavailable || model.state == .starting`）；pending 仍用 `faint`。

## 5. Fixtures（display/Fixtures/）

`--snapshot-all` 会对这个目录下每个 JSON 出一张图。

- 修改 `prefill.json`：`current.elapsed_s` 从 2.3 改为 4.6（长预填充）。
- 新增下面 7 个文件。除特别说明外，顶层其他字段（`version`、`model`、`tensorfold_version`、`context_max`、`hooks`、`last`、`totals`）照抄 `idle.json`：
  - `prefill-short.json`：照抄新的 `prefill.json`，`current.elapsed_s` 为 1.2，没有 `round`。
  - `round-prefill-short.json`：`state` `prefill`，`current` 照抄 `prefill.json` 但 `elapsed_s` 为 0.8，`round` = `{"requests": 9, "output_tokens": 1834, "decode_tps_avg": 78.4, "elapsed_s": 96.5, "active": true}`。
  - `round-prefill-long.json`：同上，`elapsed_s` 为 4.4。
  - `round-decode.json`：照抄 `decode.json`，加上同一个 `round`。
  - `round-done.json`：照抄 `done.json`，`round` 为 `{"requests": 10, "output_tokens": 2146, "decode_tps_avg": 79.1, "elapsed_s": 101.2, "active": true}`。
  - `round-idle.json`：照抄 `idle.json`，`round` 同 `round-done.json`。
  - `round-idle-ended.json`：照抄 `round-idle.json`，`round.active` 为 `false`。

## 6. 测试（display/Tests/PanelCoreTests/AllTests.swift）

现有测试里只允许改这几条（行为按设计已经变了），其他一律不动：

- `各 fixture 都能解码` 里 `prefill.current?.elapsedS == 2.3` 改为 `4.6`。
- `prefill：已用时本地插值 + 扫动弧段` 改名为 `prefill：3 秒以后显示已用时，圆弧不动`：已用时 = 4.6 + (11 − 10) = 5.6，断言 `bigInt == "5"`、`bigDec == ".6"`、`arc == .rest`、`ghostFraction == Gauge.valueToFraction(58.2)`、`arcTarget == 58.2`、`muted == false`，删掉 `.comet` / `cometPhase` 两条断言，其余断言保留。
- `prefill：刚进入时状态条右侧为空` 改名为 `prefill：前 3 秒保持空闲画面，状态条显示已用时`：已用时 = 0.3 + 0.7 = 1.0，断言 `stripRight == [StripSegment("已用时 "), StripSegment("1.0", bold: true), StripSegment(" s")]`，删掉 `cometPhase` 断言。

新增测试（每条一个 `@Test`，用 fixture 或在测试里改 fixture 的字段构造）：

1. `Metrics` 解码 `round` 全部 5 个字段；没有 `round` 键时为 `nil`；7 个新 fixture 都能解码。
2. 短预填充（单请求，`prefill-short.json`，now = fetchedAt）：`state == .prefill`、`stateName == "预填充中"`、`muted`、`arc == .rest`，`cap`、`pill`、`bigInt`、`bigDec`、`ghostFraction`、`arcTarget`、`cards` 与用同一份 `last` 生成的 idle 画面完全相同。
3. 阈值边界：已用时 2.99 为短预填充（`cap == "上次平均"`），3.0 为长预填充（`cap == "已用时"`）。
4. 一轮判定：`round.requests == 1` 且 state 为 prefill → 一轮模式（`cards[0].label == "本轮请求"`、`cards[0].value == "2"`）；`round.requests == 1` 且 state 为 idle → 单请求（`cards[0].label == "输出"`）；没有 `round` 且 state 为 decode → 单请求。
5. `round-decode.json`：`cards` 依次为 `本轮请求 10 次 / 用时 1 分钟`、`累计输出 2.1K tok`（1834 + 312）、`本轮平均 78.4 / tok/s`；`cap == "解码速度"`，`arcTarget`、`bigInt`、`stripRight` 与单请求 decode 相同；`muted == false`。
6. `round-done.json`：`state == .done`、`stateName == "完成"`、`cap == "本轮平均"`、`pill`、`bigInt == "79"`、`bigDec == ".1"`、`muted`、`arc == .rest`、`ghostFraction == Gauge.valueToFraction(79.1)`、`cards[0].value == "10"`、`stripRight` 以 `StripSegment("上下文 ")` 开头。
7. `round-idle.json`：`stateName == "空闲"`、`stripRight.isEmpty`、卡片标签为 本轮请求 / 累计输出 / 本轮平均、`cards[1].value == "2.1K"`。
8. `round-idle-ended.json`：`cap == "上轮平均"`，卡片标签为 上轮请求 / 上轮输出 / 上轮平均。
9. `round-prefill-short.json`：`cards[0].value == "10"`、`cap == "本轮平均"`、`bigInt == "78"`、`stripRight` 为已用时 0.8。
10. `round-prefill-long.json`：`cap == "已用时"`、`bigInt == "4"`、`bigDec == ".4"`、`muted == false`、卡片仍为一轮卡片、`ghostFraction == Gauge.valueToFraction(78.4)`。
11. 一轮模式下 `decode_tps_avg` 为 null：`bigInt == "—"`、`pill == false`、`ghostFraction == nil`、`cards[2].label == "本轮平均"` 且 `pending`。
12. 淡入键：一轮模式下 done / idle / 短预填充三者 `centerFadeKey` 相同，decode 与它们不同；decode / done / idle / 短预填充 / 长预填充五者 `cardsFadeKey` 全部相同。单请求下 decode 与 done 的 `cardsFadeKey` 不同。
13. `muted`：单请求 idle 为 `true`，单请求 done、decode、offline 为 `false`。

## 完成前必须运行并全部通过

```sh
cd display && swift build && swift test && rm -rf /tmp/tfpanel-shots && .build/debug/TFPanel --snapshot-all /tmp/tfpanel-shots && ls /tmp/tfpanel-shots
```

`ls` 应列出 15 张 PNG（原有 8 张 + 新增 7 张）。你看不到图片，截图由编排者逐张检查。

如果 `swift test` 报 `plugin for module 'TestingMacros' not found`，这是本机工具链偶发的 bug，直接重跑一次，不要改 `Package.swift`。

不要运行 `.build/debug/TFPanel`（不带 `--snapshot` 参数会启动窗口程序，副屏上已经有一个在运行）。
