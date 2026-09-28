# 任务 B2：副屏画面渲染（SwiftUI）+ 离屏截图

先读 `AGENTS.md`，再读 `docs/dashboard-prototype.html` 的 **CSS（`.screen` 之后的全部样式）和 `<template id="screenTpl">`、`buildDial`、`apply`、`sparkPoints`、`frame` 函数**。本任务把原型的“屏幕”部分用 SwiftUI 原样复刻。`PanelCore`（B1 已完成）里的 `PanelViewModel` 已经决定了每个状态显示什么文字，本任务只负责“画出来”和动画，**不要改 PanelCore 的逻辑**（如确需加一个小的辅助属性，保持现有测试全部通过）。

## 交付

- `display/Package.swift`：新增可执行目标 `TFPanel`（依赖 `PanelCore`），`swift build` 产出 `.build/debug/TFPanel`。
- `display/Sources/TFPanel/Theme.swift`：颜色常量。
- `display/Sources/TFPanel/PanelScreenView.swift`：整块屏幕的 SwiftUI 视图。
- `display/Sources/TFPanel/PanelAnimator.swift`：缓动、节流、淡入、脉冲等随时间变化的量。
- `display/Sources/TFPanel/Snapshot.swift`：离屏截图命令。
- `display/Sources/TFPanel/main.swift`：本任务只处理 `--snapshot` / `--snapshot-all` 两个命令，无参数时打印用法并以 0 退出（窗口程序在下一个任务做）。

## 1. 缩放规则（重要）

画面按 **480×320 设计单位** 设计（与原型 CSS px 一一对应）。`PanelScreenView` 接收 `scale: CGFloat`，**所有**尺寸（位置、宽高、字号、线宽、圆角、字距）都乘以 `scale`。**不要用 `.scaleEffect`**（会糊）。副屏窗口和截图都用 `scale = 2`，即 960×640。

## 2. 颜色（深色主题，照抄原型 `.screen` 的 CSS 变量）

`bg #0a0b0d`、`card #14161a`、`cardLine #1d2025`、`text #f3f4f6`、`text2 #a7adb6`、`muted #8c929b`、`faint #555b64`、`track #1d2025`、`accent #76e2b7`、`amber #f0b44c`、`danger #e27a72`、`ghost #59606a`、`pillBg = accent 透明度 0.15`、`pillText #8eeac5`。不做米色主题。

## 3. 布局（设计单位，原点在屏幕左上角）

- 屏幕 480×320，背景 `bg`，四周内边距 12。
- **状态条** `x=12, y=12, w=456, h=22`，左右各再缩进 2。水平排列、间距 8、垂直居中：
  圆点 8×8（颜色见 §5）→ `stateName`（14，semibold，`text`）→ `stripLeft`（13，`muted`）→ 弹性空白 → `stripRight`（13，`muted`；`bold: true` 的片段用 `text2` + semibold）。单行，超长时尾部截断。
- **仪表区** `x=12, y=40, w=316, h=268`；**卡片列** `x=336, y=40, w=132, h=268`。
- **仪表**（坐标相对仪表区左上角）：圆心 `(154,144)`，半径 `R=124`，线宽 14，圆头。圆弧从 225° 顺时针扫到 −45°（共 270°）。点坐标用 `Gauge.point(deg, r)`（y 向下）。建议用 `Gauge.point` 在 f=0…1 上取 ≥180 个点连成 Path，再用 `.trim` 画部分弧。绘制顺序（后画的在上面）：
  1. 轨道：整条弧，`track` 色。
  2. 刻痕：在 `tickFractions` 里介于 0 和 1 之间的每个位置，从半径 `R−8` 到 `R+8` 画一条线，线宽 2.5，颜色 `bg`（看起来是轨道上的缺口）。
  3. 残影点（`ghostFraction` 非空且 arc = rest 时）：在该位置画直径 14 的圆点，`ghost` 色，不透明度 0.9。
  4. 彗尾 + 彗星（arc = comet 时）：设 `ph = cometPhase`，`e = ph<0.5 ? 2ph² : 1 − (−2ph+2)²/2`，`head = e·1020 − 10`（单位：弧长的千分之一）。彗星段 = `[max(0, head−130), min(1000, head)]`，`amber`，不透明度 1；彗尾段 = `[max(0, head−240), min(1000, head)]`，`amber`，不透明度 0.28。先画彗尾。
  5. 数值弧（arc = value 时）：`trim(0, valueToFraction(动画值))`，`accent`。
  6. 刻度数字：`ticks` 每个值，字号 12、semibold、`muted`；位置 `deg = fractionToDegrees(f)`，`c = cos(deg)`：`c < −0.85` 时在半径 `R+12` 处右对齐，`c > 0.85` 时在 `R+12` 处左对齐，否则在 `R+20` 处居中；垂直方向居中。
  - 各模式下透明度：`off` 轨道 0.5、刻度 0.35；`rest` 刻度 0.75；其他为 1。
- **仪表中心文字**（相对仪表区，水平范围 `x=44…264`，宽 220，居中）：
  - cap 行：`y=78`，高 20，13 号 `muted`，后面跟“精确”药丸（`pill` 为 true 时显示）：12 号 semibold，左右内边距 7，高 18，圆角 9，底色 `pillBg`、字色 `pillText`；**idle 状态**药丸改为透明底、`muted` 字、1 单位 `faint` 描边。cap 与药丸间距 6。
  - 大数字：`y=97`，行高 96。`bigInt` 96 号 bold，字距 −0.035×96；`bigDec` 40 号，字距 −0.01×40，左边距 1；`whole` 为 true 时 `bigDec` 与 `bigInt` 同样式。两段基线对齐。idle 状态颜色 `text2`，其他 `text`。
  - 单位：`y=194`，15 号 semibold，`muted`。
  - 小曲线（`showSpark` 时）：`x=94, y=216`，120×26。样本 i（共 n 个，最多 80）：`x = 120 − (n−1−i)·(120/79)`，`y = 26 − 1.5 − valueToFraction(v)·23`。淡线 raw：`faint`，线宽 1；实线 smooth：`accent`，线宽 1.75，圆角连接。
  - 消息（`message` 非空时，取代 cap/大数字/单位）：`y=108`，标题 28 号 semibold `text2`（行高 36），副标题 13 号 `muted`，上间距 6。
- **卡片列**：3 张卡片等高（`(268 − 2·6)/3`），间距 6。每张：底色 `card`，1 单位 `cardLine` 描边，圆角 14，内边距上下 8、左右 12，内容垂直居中、左对齐：
  - `label`：13 号 `muted`。
  - 数值行：`value` 30 号 bold（字距 −0.6）+ 间距 4 + `unit` 13 号 semibold `muted`，基线对齐。`pending` 为 true 时 `value` 用 `faint`；idle / offline / unavailable / starting 状态 `value` 用 `text2`；其他 `text`。
  - `foot`：13 号 `muted`，为空字符串时不占位。
- 全部数字用 `.monospacedDigit()`（等宽数字，变化时不抖）。字体用系统字体（SF Pro + 苹方自动回退）。

## 4. 动画（PanelAnimator，`@MainActor final class`，由外部每帧调用 `tick(now:model:)`）

- **缓动值** `display`：目标 = decode 时 `model.arcTarget`，done 时 `model.arcTarget`，其他为 0；`display += (目标 − display)·(1 − e^(−dt/0.4))`，`dt` 上限 0.1 s；差值 < 0.02 时直接等于目标。数值弧用它。
- **大数字节流**：decode 状态下显示 `String(Int(display.rounded()))`，但最多每 0.25 s 更新一次（design.md：数字每秒最多刷新 4 次）；其他状态直接用 `model.bigInt`/`bigDec`。
- **状态切换淡入**：`model.state` 变化时，状态条、仪表中心文字、卡片列的不透明度从 0.15 过渡到 1：一般 0.32 s ease-out；从 done 变 idle 用 0.8 s ease-in-out。
- **圆点脉冲**：prefill 周期 1.0 s、decode 周期 1.4 s，不透明度在 1 和 0.35 之间正弦往复；starting 同 prefill；其他不脉冲。
- 圆点颜色：offline `danger`、unavailable `amber`、starting `amber`、idle `faint`、prefill `amber`、decode `accent`、done `accent`。
- 提供 `settled(model:)`：返回“所有动画已结束”的状态（display = 目标、大数字 = 目标四舍五入、淡入完成、脉冲不透明度 1），截图用。

## 5. 离屏截图（Snapshot.swift）

- `TFPanel --snapshot <fixture.json | offline> <out.png>`：
  - fixture：构造 `ConnectionTracker`，在 t=100 记录一次成功，`now = 100`；
  - `offline`：先用 `Fixtures/idle.json` 在 t=100 记录一次成功，再在 t=101、101.1、101.2 记录 3 次失败，`now = 143`（“已离线 42 秒”）。
  - 内存固定为 `(21.4, 64)`，保证截图可复现。
  - decode / done 时，给 tracker 注入 80 个确定性样本：`smooth_i = 58 + 8·sin(i/9)`，`raw_i = smooth_i + 30·sin(i·1.7)·(0.5 + 0.5·sin(i/5))`（若 PanelCore 没有注入接口，加一个 `internal`/`public` 的测试辅助方法即可）。
  - 用 `PanelAnimator.settled` 的状态、`scale = 2` 渲染，`ImageRenderer`（`renderer.scale = 1`）输出 **960×640** PNG。
- `TFPanel --snapshot-all <目录>`：对 `display/Fixtures/` 下每个 JSON 以及 `offline` 各出一张，文件名 `<名字>.png`（如 `decode.png`、`offline.png`）。Fixtures 目录用 `#filePath` 相对定位。

## 完成前必须运行并全部通过

```sh
cd display && swift build && swift test
cd display && rm -rf /tmp/tfpanel-shots && .build/debug/TFPanel --snapshot-all /tmp/tfpanel-shots && ls /tmp/tfpanel-shots
sips -g pixelWidth -g pixelHeight /tmp/tfpanel-shots/decode.png   # 必须是 960 × 640
```
你看不到图片，视觉效果由编排者对照原型验收；你只需保证上述尺寸、布局数值严格照本说明实现。
