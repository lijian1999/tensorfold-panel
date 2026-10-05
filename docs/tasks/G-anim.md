# 任务 G：动画（anim）

先读 `AGENTS.md`，再读 `docs/tasks/00-contracts.md` 的第 1、3、7、8 节，和 `docs/design.md` 的“字号、格式与动画”一节。原型 `docs/dashboard-prototype.html` 里对应的部分：CSS 里的 `transition`、`@keyframes pulse`、`@keyframes swapin`，JS 里 `function apply(V)` 开头的“淡入键”和 `frame()` 里“缓动”那一段。

本任务只用标准库，全部在 MacBook Pro 上完成，不需要 `ssh spark`。`panel/view.py`、`panel/scale.py`、`panel/fmt.py` 已经有了，直接用，不要改它们。

## 交付文件

1. `panel/anim.py`
2. `panel/tests/test_anim.py`

不要创建或修改别的文件。

## 接口

`Frame` 的字段、默认值、顺序按接口约定第 8 节，一字不差。

```python
class Animator:
    def __init__(self)
    def step(self, view: View, now: float) -> Frame
    @staticmethod
    def settled(view: View) -> Frame
```

窗口每画一帧调一次 `step`（动画时每秒约 30 次；静止时只在数据变化时调）。`step` 不读时钟、不做 I/O。

## `settled(view)`：所有动画走完时的那一帧

| 字段 | 值 |
| --- | --- |
| `arc_frac` | `view.arc_target`，为 `None` 时 0 |
| `arc_mix` | `view.arc == "prefill"` 时 1，否则 0 |
| `value_alpha`、`ghost_alpha`、`ticks_alpha`、`track_alpha`、`notch_alpha` | 按下面“圆弧各部分的不透明度”表 |
| `big_int`、`big_dec` | `view.big_int`、`view.big_dec` |
| `bar_frac` | `view.bar.frac`，没有 `bar` 时 0 |
| `center_alpha`、`stats_alpha`、`strip_alpha`、`pulse_dec`、`pulse_pre` | 1 |
| `dim` | `view.dim` |
| `animating` | `False` |

圆弧各部分的不透明度（按 `view.arc`；`ghost` 一栏在 `view.ghost is None` 时为 0）：

| `arc` | `value_alpha` | `ghost_alpha` | `ticks_alpha` | `track_alpha` | `notch_alpha` |
| --- | --- | --- | --- | --- | --- |
| `value`、`prefill` | 1 | 0 | 1 | 1 | 1 |
| `rest` | 0 | 0.9 | 0.75 | 1 | 1 |
| `blank`、`off` | 0 | 0 | 0 | 0.5 | 0 |

## `step(view, now)`

**第一次调用**：返回 `settled(view)` 的值（脉冲按下面的公式算），并记下状态。之后每次：

`dt = min(0.1, max(0, now − 上次的 now))`，`k = 1 − exp(−dt / 0.4)`。

1. **圆弧位置** `arc_frac`：目标 = `view.arc_target`，为 `None` 时目标 = 当前值（停在原地）。`arc_frac += (目标 − arc_frac) × k`；和目标相差不到 0.0005 时直接等于目标。
2. **圆弧颜色** `arc_mix`：目标 1（`arc == "prefill"`）或 0，线性变化，0.4 秒走完全程（每秒变 2.5）。
3. **五个不透明度**：目标按上表，各自线性变化，0.6 秒走完全程 0→1（每秒变 1 ÷ 0.6）。
4. **刻度切换淡入**：`view.scale` 和上次不同时，开始一次 0.32 秒的淡入（见第 6 条的公式）；返回的 `ticks_alpha` = 第 3 条的值 × 这个淡入值。
5. **主数字**：
   - `view.big_value is None`：`big_int`、`big_dec` 直接取 `view` 的。
   - `view.big_value` 不为 `None`（实时解码速度）：内部保存一个缓动值 `display`。上一次不是实时数字时 `display = view.big_value`、立刻刷新显示；否则 `display += (view.big_value − display) × k`，相差不到 0.02 时直接等于目标。显示的文字每 0.25 秒最多刷新一次：距上次刷新 ≥ 0.25 秒时 `big_int = str(js_round(display))`；没到时间沿用上次显示的文字。`big_dec = ""`。
6. **三块淡入**：每块有一个“键”，键和上次不同时那一块开始淡入（第一次调用不淡入）：
   - 中间区域的键：`(view.cap, view.unit, view.big_whole, view.muted, view.state == "offline")`
   - 右侧三栏的键：三张卡片的 `label` 组成的元组
   - 状态条的键：`view.state_name`
   - 淡入公式：开始后经过 `e` 秒，时长 `T`，`p = min(1, e / T)`：
     - 普通淡入 `T = 0.32`：不透明度 = `0.15 + 0.85 × (1 − (1 − p)²)`
     - 慢淡入 `T = 0.8`（键变化的那次 `view.slow_fade` 为真）：不透明度 = `0.15 + 0.85 × (p² × (3 − 2p))`
   - 键变化的那一帧 `e = 0`，不透明度是 0.15。淡入进行中键又变了，就从头开始。
7. **条的长度** `bar_frac`：`view.bar` 为 `None` 时 0。`view.bar.kind` 和上次不同（或上次没有 `bar`）时直接等于 `view.bar.frac`；否则 `bar_frac += (view.bar.frac − bar_frac) × k`，相差不到 0.001 时直接等于目标。
8. **脉冲**：`pulse_dec = 0.675 + 0.325 × cos(2π × now ÷ 1.4)`（`view.lanes.decoding == 0` 时为 1）；`pulse_pre = 0.675 + 0.325 × cos(2π × now ÷ 1.0)`（`view.lanes.prefilling == 0` 时为 1）。`view.lanes.offline` 为真时两个都是 1。
9. **整屏亮度** `dim`：目标 `view.dim`。目标比当前大（变亮）：直接等于目标。目标比当前小（变暗）：线性变化，每秒变 0.3（从 1 到 0.4 用 2 秒）。
10. **`animating`**：下面任何一条成立就是 `True`：第 1、2、3、7、9 条里还有没到目标的；第 4、6 条里有淡入没走完；实时数字的 `display` 还没到目标，或显示的文字还不等于 `str(js_round(display))`；`pulse_dec` 或 `pulse_pre` 在用（对应的流数 > 0 且不是离线）。

所有输出的不透明度、位置都夹在 0–1 之间。

## 测试要求（`panel/tests/test_anim.py`）

自己构造 `View`（`from panel.view import View, Lanes, Card, Bar, Seg`），用假时刻，不 sleep。浮点用 `assertAlmostEqual`。至少覆盖：

1. `settled`：对 `arc` 为 `value`、`prefill`、`rest`（有 `ghost`）、`rest`（`ghost=None`）、`blank`、`off` 各一个 `View`，断言表里的全部字段。`arc_target=None` 时 `arc_frac == 0`；没有 `bar` 时 `bar_frac == 0`；`animating is False`。
2. 第一次 `step` 等于 `settled`（脉冲除外），三块不透明度都是 1。
3. 圆弧缓动：第一帧 `arc_target=0.2`，之后 `arc_target=0.8`、每 1/30 秒一帧：`arc_frac` 单调增加；0.4 秒后 ≈ `0.2 + 0.6 × (1 − e⁻¹)`（误差 0.01 内）；5 秒后等于 0.8 且该项不再让 `animating` 为真。`arc_target=None` 时 `arc_frac` 保持不变。
4. `dt` 上限：两次 `step` 相隔 10 秒，只按 0.1 秒推进（`arc_frac` 没有直接跳到目标）。
5. 颜色：`arc` 从 `value` 变 `prefill`，0.2 秒后 `arc_mix ≈ 0.5`，0.4 秒后为 1。
6. 不透明度：`arc` 从 `blank` 变 `value`，0.3 秒后 `value_alpha ≈ 0.5`、`track_alpha ≈ 1.0`（0.5 起步，0.3 秒走 0.5）、`notch_alpha ≈ 0.5`；0.6 秒后全部到位。
7. 刻度切换：`scale` 从 `decode` 变 `prefill` 的那一帧 `ticks_alpha ≈ 0.15`（`arc` 一直是 `value`），0.32 秒后 ≈ 1。
8. 三块淡入：`cap` 变了 → 那一帧 `center_alpha ≈ 0.15`、另两块仍是 1；0.16 秒后 `center_alpha ≈ 0.15 + 0.85 × 0.75`；0.32 秒后为 1。卡片标签变了 → 只有 `stats_alpha` 淡入。`state_name` 变了 → 只有 `strip_alpha` 淡入。只是卡片数值变（标签没变）、只是 `big_int` 变：都不淡入。
9. 慢淡入：`slow_fade=True` 且 `cap` 变了：0.4 秒后 `center_alpha ≈ 0.15 + 0.85 × 0.5`，0.8 秒后为 1。
10. 主数字：非实时 → 直接是 `view` 的文字。实时：第一帧 `big_value=60.4` 显示 `"60"`；0.1 秒后 `big_value=100`，显示仍是 `"60"`（没到 0.25 秒）；到 0.25 秒时显示刷新成一个介于 60 和 100 之间的整数；一直喂 `big_value=100`，5 秒后显示 `"100"`，`big_dec == ""`。从实时回到非实时再回到实时：`display` 直接取新的 `big_value`。
11. 条：`bar` 的 `kind` 不变、`frac` 从 0.2 变 0.6：缓动（0.4 秒后 ≈ `0.2 + 0.4 × (1 − e⁻¹)`）；`kind` 从 `ctx` 变 `prog`：直接等于新值；`bar` 变 `None`：0。
12. 脉冲：`lanes.decoding=1` 时 `now=0` → `pulse_dec ≈ 1.0`，`now=0.7` → `≈ 0.35`，`now=1.4` → `≈ 1.0`；`lanes.prefilling=1` 时 `now=0.5` → `pulse_pre ≈ 0.35`；流数为 0 时为 1；离线时为 1。
13. 亮度：`dim` 目标从 1.0 变 0.4：1 秒后 ≈ 0.7，2 秒后 0.4；目标变回 1.0：下一帧就是 1.0。
14. `animating`：静止的 `idle` 画面连续 `step` 两次后为 `False`；`lanes.decoding=1` 时一直为 `True`；圆弧在缓动时为 `True`、到位后（且没有脉冲）为 `False`；淡入进行中为 `True`。
15. 所有输出的不透明度都在 0–1 之间（随便喂一串变化的 `View`，每帧检查）。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_anim -v
python3 -c "
from panel.view import View
from panel.anim import Animator, Frame
print(Animator.settled(View(arc='value', arc_target=0.5)))
"
```
