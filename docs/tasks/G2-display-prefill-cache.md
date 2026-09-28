# 任务 G2：副屏在预填充时显示缓存命中、新算 token 数、预计时间（Swift）

先读 `AGENTS.md`，再读 `docs/design.md` 的「连续请求（一轮）与短预填充」里“提前切换”一条、“每个指标怎么算”表格后面的“缓存未命中”一段、「指标接口」里 `current` 一行、「每个状态显示什么」两张表的预填充行和表后那段说明。然后读下面这些文件：

- `display/Sources/PanelCore/Metrics.swift`
- `display/Sources/PanelCore/PanelModel.swift`
- `display/Sources/TFPanel/PanelScreenView.swift`（只看 `stripRightText` 和 `ctxBar`）
- `display/Tests/PanelCoreTests/AllTests.swift`（`Metrics` 解码那一组，和 prefill 相关的测试）

原型 `docs/dashboard-prototype.html` 已按新设计改好（`view()` 的 `case 'prefill'`），可以对照，但**以本文件为准**。本任务只改上面列出的 4 个文件和 `display/Fixtures/` 下新增的 3 个文件，不碰 `collector/`、`docs/`、`scripts/`。

采集器已经在 `current` 里提供（老版本采集器没有这三个键，这时一律按现在的画面显示）：

```json
"prompt_tokens": 35012,
"prefill_cached": 32768,
"prefill_est_s": 3.797,
"cache_miss": false
```

## 1. Metrics.swift

`Metrics.Current` 新增三个属性（JSON 键分别是 `prefill_cached`、`prefill_est_s`、`cache_miss`）：

```swift
/// 预填充开始时的缓存命中 token 数（拿不到时为 nil）
public var prefillCached: Int?
/// 预计纯预填充秒数（拿不到时为 nil）
public var prefillEstS: Double?
/// 是否判定为缓存未命中
public var cacheMiss: Bool?
```

`init` 在**最后**依次增加参数 `prefillCached: Int? = nil, prefillEstS: Double? = nil, cacheMiss: Bool? = nil`（放在 `promptTokens` 之后，保证现有调用不用改）。

## 2. PanelModel.swift

### 2.1 StripSegment

新增存储属性 `public var warn: Bool`：为 `true` 时这一段用琥珀色显示。`init` 改为 `public init(_ text: String, bold: Bool = false, warn: Bool = false)`，现有调用不用改。

### 2.2 预填充画面（prefillView）

在现有 `prefillView` 里，已用时 `elapsed` 的算法不变。先从 `m?.current` 取出：

```
let prompt = cur?.promptTokens
let cached = cur?.prefillCached
let est = cur?.prefillEstS
let miss = cur?.cacheMiss ?? false
```

**长短判定**改为：`elapsed >= shortPrefillS || (est ?? 0) >= shortPrefillS || miss` 时为长预填充，否则为短预填充。短预填充画面**完全不变**。

**长预填充**：仍然先取 restView 并覆盖 `muted`、`pill`、`cap`、`whole`、`unit`、`bigInt/bigDec`（和现在一样）。然后：

- **拿得到缓存信息**（`prompt` 非空且 > 0，`cached` 非空）：
  - `hit = Int((Double(cached) / Double(prompt) * 100).rounded())`，夹到 0...100；`newTok = max(0, prompt - cached)`。
  - 预计时间段 `eta`：`est` 非空时为
    `[StripSegment(" · 预计约 "), StripSegment("\(Int(est.rounded(.up)))", bold: true), StripSegment(" s")]`，为空时为 `[]`。
  - `stripRight`：
    - 单请求（`roundMode == false`）：`[StripSegment("新算 "), StripSegment(Format.tokFmt(Double(newTok)), bold: true), StripSegment(" tok")] + eta`
    - 一轮模式：`hitSegs + [StripSegment(" · 新算 "), StripSegment(Format.tokFmt(Double(newTok)), bold: true)] + eta`，其中
      - `miss` 为 `true`：`hitSegs = [StripSegment("缓存未命中", warn: true)]`
      - 否则：`hitSegs = [StripSegment("缓存命中 "), StripSegment("\(hit)%", bold: true)]`
  - `cards`：单请求时为
    `[Card(label: "缓存命中", value: "\(hit)", unit: "%", foot: "\(Format.tokFmt(Double(cached))) / \(Format.tokFmt(Double(prompt)))"), .pending("首字", foot: "等待首个 token"), memoryCard(memory)]`；
    一轮模式保持 restView 的一轮卡片（不变）。
- **拿不到缓存信息**：和现在完全一样（`stripRight = [StripSegment("提示较长，可能需要几秒")]`，单请求卡片为 输出 — / 首字 — 等待首个 token / 内存）。

其他状态的画面都不变。

## 3. PanelScreenView.swift

`stripRightText` 和 `ctxBar` 里拼 AttributedString 的地方：`seg.warn` 为 `true` 时颜色用 `Theme.amber`、字重 `.semibold`；否则保持现在的规则（bold → `text2` + semibold，其他 → `muted` + regular）。其他代码不动。

## 4. Fixtures（display/Fixtures/，新增 3 个）

`--snapshot-all` 会对这个目录下每个 JSON 出一张图。

- `prefill-cache.json`：照抄 `prefill.json`，`current` 改为 `elapsed_s` 1.0、`prompt_tokens` 35012，并加上 `"prefill_cached": 32768, "prefill_est_s": 3.797, "cache_miss": false`。没有 `round`。
- `round-prefill-cache.json`：照抄 `round-prefill-long.json`（`elapsed_s` 4.4、`prompt_tokens` 18420 不变），`current` 加上 `"prefill_cached": 16384, "prefill_est_s": 2.921, "cache_miss": false`。
- `round-prefill-miss.json`：照抄 `round-prefill-long.json`，`current` 改为 `elapsed_s` 1.0、`prompt_tokens` 41230，并加上 `"prefill_cached": 0, "prefill_est_s": 57.191, "cache_miss": true`。

## 5. 测试（display/Tests/PanelCoreTests/AllTests.swift）

现有测试一条都不能删改（现有 fixture 没有新字段，行为必须和现在一样）。新增测试（每条一个 `@Test`，用 fixture 或在测试里改 fixture 字段构造，`now` = `fetchedAt`，除非另外说明）：

1. `Metrics` 解码：`prefill-cache.json` 的三个新字段为 32768 / 3.797 / false；`prefill.json` 里三者都是 `nil`；3 个新 fixture 都能解码。
2. `StripSegment("a") == StripSegment("a", bold: false, warn: false)`；`StripSegment("a", warn: true) != StripSegment("a")`。
3. `prefill-cache.json`（单请求，已用时 1.0 但预计 3.797 ≥ 3 → 长预填充）：
   - `cap == "已用时"`、`bigInt == "1"`、`bigDec == ".0"`、`!muted`、`arc == .rest`；
   - `stripRight == [StripSegment("新算 "), StripSegment("2.2K", bold: true), StripSegment(" tok"), StripSegment(" · 预计约 "), StripSegment("4", bold: true), StripSegment(" s")]`；
   - `cards[0] == Card(label: "缓存命中", value: "94", unit: "%", foot: "32.8K / 35.0K")`，`cards[1]` 为首字 pending（foot `等待首个 token`），`cards[2].label == "内存"`。
4. `round-prefill-cache.json`（一轮，已用时 4.4）：`stripRight == [StripSegment("缓存命中 "), StripSegment("89%", bold: true), StripSegment(" · 新算 "), StripSegment("2.0K", bold: true), StripSegment(" · 预计约 "), StripSegment("3", bold: true), StripSegment(" s")]`；`cards` 和用 `round-prefill-long.json` 生成的画面的 `cards` 完全相同。
5. `round-prefill-miss.json`（一轮，已用时 1.0，缓存未命中 → 长预填充）：`cap == "已用时"`；`stripRight == [StripSegment("缓存未命中", warn: true), StripSegment(" · 新算 "), StripSegment("41.2K", bold: true), StripSegment(" · 预计约 "), StripSegment("58", bold: true), StripSegment(" s")]`；`cards[0].label == "本轮请求"`。
6. 提前切换边界（改 `prefill-cache.json` 的字段）：`prefill_est_s` 2.99、已用时 1.0、`cache_miss` false → 短预填充（`cap == "上次平均"`，`stripRight` 为已用时三段）；`prefill_est_s` 3.0 → 长预填充；`prefill_est_s` 为 nil、`cache_miss` true → 长预填充。
7. `prefill_est_s` 为 nil、已用时 4.0（改 `prefill-cache.json`）：`stripRight == [StripSegment("新算 "), StripSegment("2.2K", bold: true), StripSegment(" tok")]`，卡片仍是缓存命中卡。
8. 拿不到缓存信息时退回：`prefill_cached` 为 nil（`prompt_tokens` 35012、已用时 4.0）→ `stripRight == [StripSegment("提示较长，可能需要几秒")]`，`cards[0].label == "输出"`；`prompt_tokens` 为 nil 或 0（`prefill_cached` 32768）→ 同样退回。
9. 命中率取整和夹紧：`prompt_tokens` 3、`prefill_cached` 2、预计 5.0 → `cards[0].value == "67"`；`prefill_cached` 大于 `prompt_tokens` → `value == "100"`，新算显示 `"0"`。

## 完成前必须运行并全部通过

在 `display/` 目录下依次运行：

```sh
swift build && swift test
swift run TFPanel --snapshot-all /tmp/tfpanel-g2-snap
```

第二条命令要能生成 `prefill-cache.png`、`round-prefill-cache.png`、`round-prefill-miss.png` 三张图（画面由编排者检查，你只需确认文件生成）。不要启动、停止或重启 TensorFold，不要安装或运行 `TFPanel.app`。
