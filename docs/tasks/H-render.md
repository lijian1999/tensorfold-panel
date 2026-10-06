# 任务 H：绘制（render）和离屏截图

先读 `AGENTS.md`，再读 `docs/tasks/00-contracts.md` 的第 1、3、7、8、9 节。然后读原型 `docs/dashboard-prototype.html` 的 CSS 里 `/* ============ 屏幕（480×320）============ */` 之后的全部样式，和 JS 里的 `buildDial`、`apply`。原型各画面在副屏上的实拍截图在 `docs/prototype-shots/ref/<名字>.png`（960×640，共 11 张）——**你有视觉能力，用读文件的工具直接看这些图**，本任务的目标就是用 cairo 画出和它们一样的画面。

`panel/view.py`、`panel/scale.py`、`panel/fmt.py`、`panel/anim.py`（`Frame`、`Animator.settled`）、`panel/viewmodel.py`（`ViewModel`）、`panel/config.py`、`fixtures/*.json` 都已经有了，直接用，不要改它们。

绘制只能在 Spark 上运行（MacBook Pro 上没有 `gi`）。代码在 MacBook Pro 上写，同步到 Spark 的 `/tmp/tfpanel-h/` 运行，图拷回 MacBook Pro 的 `/tmp/tfpanel-h-out/` 来看。离屏截图画到内存图片上，**不需要显示器，不要在副屏上开窗口**。

## 交付文件

1. `panel/render.py`：绘制。
2. `scripts/offscreen.py`：把样例画成 PNG。
3. `scripts/dev/compare.py`：把原型截图和我们的图左右拼在一起。
4. `panel/tests/test_render.py`：测试（没有 `gi` 的机器上整个跳过）。

不要创建或修改别的文件。

## 接口

```python
def draw(cr, view: View, frame: Frame, width: int = 960, height: int = 640) -> None
def render_png(view: View, path: str, frame: Frame | None = None) -> None   # frame 为 None 时用 Animator.settled(view)
```

- `draw` 开头 `cr.save()`、`cr.scale(width / 480, height / 320)`，之后全部按 480×320 的坐标画，结尾 `cr.restore()`。下面所有坐标、尺寸都是这个 480×320 坐标系里的。
- `draw` 每秒要调 30 次，不能有明显的开销：字体描述、颜色等能缓存的缓存；不读文件；不打印。
- `draw` 对任何 `View` 都不能抛异常（文字为空就不画；`cards` 不足 3 张就只画有的）。
- 导入：`import gi; gi.require_version("Pango", "1.0"); gi.require_version("PangoCairo", "1.0"); from gi.repository import Pango, PangoCairo; import cairo`。不要导入 Gtk、Gdk（离屏截图不需要显示器）。

## 文字

- 字体族 `Noto Sans CJK SC`。字重只有两种：普通（原型里 400）和粗（原型里 600、650、700 都用 `Pango.Weight.BOLD`）。
- 字号用绝对尺寸：`desc.set_absolute_size(字号 × Pango.SCALE)`，这样字号的单位就是坐标系的单位，随 `cr.scale` 放大。
- 全部文字开等宽数字：Pango 属性 `Pango.attr_font_features_new("tnum=1")`。
- 字距（原型的 `letter-spacing`）用 `Pango.attr_letter_spacing_new(int(字距 × Pango.SCALE))`，字距 = em 数 × 字号。
- 用 `PangoCairo.create_layout(cr)` 建布局，量尺寸用 `layout.get_extents()` 的逻辑矩形（除以 `Pango.SCALE` 得到坐标单位，保留小数，不要用取整的 `get_pixel_size`），基线用 `layout.get_baseline() / Pango.SCALE`。
- 画之前 `PangoCairo.update_layout(cr, layout)`，用 `PangoCairo.show_layout(cr, layout)` 画。
- **垂直位置的规则**：原型里每段文字都有一个“行框”（CSS 的 `line-height`）。把布局的逻辑矩形在行框里垂直居中，就和浏览器的位置一致。下面说“中心 y = …”都是指逻辑矩形的垂直中心。
- 一行里有几段不同样式的文字（`Seg` 列表、数值加单位、整数加小数）时，各段**基线对齐**，从左到右依次排。
- 建议写一个辅助函数，输入若干段（文字、字号、是否粗、颜色、字距）和对齐方式（左、中、右）、锚点 x、中心 y（或基线 y），量出总宽后一次画完。

## 颜色

| 名字 | 值 | 名字 | 值 |
| --- | --- | --- | --- |
| `bg` | `#0a0b0d` | `accent`（薄荷绿） | `#76e2b7` |
| `card` | `#14161a` | `amber`（琥珀） | `#f0b44c` |
| `card_line` | `#1d2025` | `danger`（红） | `#e27a72` |
| `text` | `#f3f4f6` | `ghost` | `#59606a` |
| `text_2` | `#a7adb6` | `pill_bg` | `rgba(118, 226, 183, 0.15)` |
| `muted` | `#8c929b` | `pill_text` | `#8eeac5` |
| `faint` | `#555b64` | `track` | `#1d2025` |

`Seg` 的样式：`normal` 用所在位置的默认颜色、普通字重；`strong` 用 `text_2`、粗；`warn` 用 `amber`、粗。

## 布局（480×320）

整屏先填 `bg`。

### 状态条（y 12–34，垂直中心 23；整条的不透明度乘 `frame.strip_alpha`）

从左到右，左边从 x = 14 开始：

1. **流指示点**。`view.lanes.offline` 为真：只画一个直径 8 的 `danger` 圆点（x 14–22）。否则画 `lanes.max` 个直径 7 的圆点，间隔 4（第 i 个圆心 x = 14 + 3.5 + 11 × i）：前 `decoding` 个是 `accent`、不透明度 `frame.pulse_dec`；接着 `prefilling` 个是 `amber`、不透明度 `frame.pulse_pre`；其余是 `faint`、不透明度 0.5。`lanes.waiting > 0` 时在最后一个点右边 5 处写 `+{waiting}`（12 号、粗、`amber`）。
2. 隔 8，**状态名** `view.state_name`（14 号、粗、`text`）。
3. `view.strip_left` 非空时再隔 8 写它（13 号、普通、`muted`）。
4. **右侧文字** `view.strip_right`（13 号，默认颜色 `muted`），右对齐到 x = 466。

### 仪表盘（区域左上角 (12, 40)，316×268）

圆心 (166, 184)，半径 124，线宽 14，线帽为圆头。圆弧共 270°：位置 `f`（0–1）对应的 cairo 角度 = `135° + 270° × f`（cairo 的 y 轴向下，角度增大是顺时针；`f = 0` 在左下，`f = 0.5` 在正上方，`f = 1` 在右下）。按这个顺序画：

1. **底环**：从 `f = 0` 到 `f = 1`，颜色 `track`，不透明度 `frame.track_alpha`。
2. **刻度缺口**：`f = 0.2、0.4、0.6、0.8` 四处，沿半径方向从 `R − 8` 到 `R + 8` 画线，线宽 2.5，颜色 `bg`，不透明度 `frame.notch_alpha`，线帽平头。
3. **灰色小点**：`view.ghost` 不为 `None` 时，在圆弧上 `f = view.ghost` 的位置画一个半径 7 的实心圆，颜色 `ghost`，不透明度 `frame.ghost_alpha`。
4. **数值弧**：从 `f = 0` 到 `f = frame.arc_frac`，颜色是 `accent` 和 `amber` 按 `frame.arc_mix` 线性混合（0 全是 `accent`，1 全是 `amber`），不透明度 `frame.value_alpha`。`arc_frac` 为 0 时画成起点处的一个圆点（长度为 0 的圆头线）。不透明度为 0 时不画。
5. **刻度数字**：`SCALES[view.scale]["labels"]` 的 6 个，对应 `TICK_FRACS`。12 号、粗、`muted`，不透明度 `frame.ticks_alpha`。位置：设角度 `a = 135° + 270° × f`，`c = cos(a)`。`c < −0.85`：放在半径 `R + 12` 处，文字右对齐到该点；`c > 0.85`：半径 `R + 12`，左对齐；否则半径 `R + 20`，水平居中。垂直方向都以该点为中心。

### 仪表盘中间（水平中心 x = 166；这一块的不透明度乘 `frame.center_alpha`）

`view.state == "offline"` 时只画两行字：

- “引擎离线”：28 号、粗、`text_2`，中心 y = 166。
- “等待 TensorFold 响应…”：13 号、普通、`muted`，中心 y = 199。

否则画下面三样：

1. **标题行**（中心 y = 128）：文字是 `view.cap`；`view.unit` 非空时是 `"{cap} · {unit}"`（13 号、普通、`muted`）。`view.pill` 为真时后面隔 6 画“精确”标记：文字 12 号、粗、字距 0.04 em；底是高 18、圆角 9 的圆角矩形，文字左右各留 7。平常底色 `pill_bg`、文字 `pill_text`；`view.muted` 为真时没有底色，改画 1 宽的 `faint` 描边（画在矩形内侧），文字 `muted`。标题文字加标记作为一个整体水平居中。
2. **主数字**：字号 `view.big_size` → `normal` 96、`four` 76、`cost` 68；粗；字距 −0.035 em；颜色 `text`（`view.muted` 时 `text_2`）。文字用 `frame.big_int` 和 `frame.big_dec`。整数部分的中心 y = 185。小数部分：`view.big_whole` 为真时和整数部分同字号、同字距，紧接着排；为假时 40 号、字距 −0.01 em，和整数部分隔 1，**基线对齐**。整数加小数作为一个整体水平居中。
3. **主数字下方**（`view.bar` 不为 `None` 时）：
   - `kind` 为 `ctx` 或 `prog`：一根宽 120、高 6、圆角 3 的条，x 106–226，y 245–251。底色 `track`；填充部分从左端起，宽 `max(6, 120 × frame.bar_frac)`，圆角 3。填充颜色：`prog` 用 `amber`；`ctx` 按 `view.bar.level`：`normal` → `text_2`，`warn` → `amber`，`full` → `danger`。条下面一行字 `view.bar.text`：12 号、默认颜色 `muted`，水平居中，中心 y = 263。
   - `kind` 为 `note`：没有条，只有一行字，12 号、`muted`，水平居中，中心 y = 247。

### 右侧三栏（x 336–468；这一块的不透明度乘 `frame.stats_alpha`）

三张卡片，每张高 85.33，间隔 6：第 i 张（i = 0、1、2）的 y 从 `40 + 91.33 × i` 到 `40 + 91.33 × i + 85.33`。卡片是圆角 14 的圆角矩形，底色 `card`，1 宽的 `card_line` 描边（画在矩形内侧）。

卡片里的文字都从 x = 349 开始左对齐，由上到下最多三行，三行作为一个整体在卡片里垂直居中：

| 行 | 行高 | 内容 |
| --- | --- | --- |
| 标签 | 16 | `card.label`，13 号、普通、`muted`，在行里垂直居中 |
| 数值 | `card.unit` 为空时 34，否则 41.4 | `card.value`：30 号、粗、字距 −0.02 em；它的逻辑矩形在这一行**顶部 34 高**的范围里垂直居中。`card.unit` 非空时在数值右边隔 4 写单位：13 号、粗、`muted`，和数值基线对齐 |
| 脚注 | 16（`card.foot` 为空时没有这一行） | `card.foot`，13 号、普通、`muted`，在行里垂直居中 |

数值的颜色：`card.pending` 为真 → `faint`；否则 `view.muted` 为真或 `view.state == "offline"` → `text_2`；否则 `text`。

### 整屏亮度

最后，`frame.dim < 1` 时在整屏上盖一层黑色，不透明度 `1 − frame.dim`。

### 关于不透明度

一块里有重叠的东西（卡片底色和文字、状态条里的各项）时，“整块乘一个不透明度”要用 `cr.push_group()` … `cr.pop_group_to_source()`、`cr.paint_with_alpha(不透明度)` 来做，这样重叠处不会透出来。不透明度为 1 时不要用 group（省开销）。

## `scripts/offscreen.py`

```sh
python3 scripts/offscreen.py [--out 目录] [样例名 …]
```

- 把仓库根目录加进 `sys.path`（脚本在 `scripts/` 下，根目录是它的上一级）。
- 对每个样例：读 `fixtures/<名>.json` → `ViewModel(Config()).update(snapshot, 0.0)` → `render_png(view, <目录>/<名>.png)`。不给样例名就画 `fixtures/` 里全部。
- `--out` 默认 `/tmp/tfpanel-shots`，目录不存在就创建。每画一张打印一行文件路径。
- 样例名不存在：打印中文错误到 stderr，以 1 退出。

## `scripts/dev/compare.py`

```sh
python3 scripts/dev/compare.py <原型截图.png> <我们的图.png> <输出.png>
```

用 cairo 把两张 960×640 的图左右拼成一张 1930×640 的图（左边原型、右边我们的，中间留 10 宽的 `#ff00ff` 竖条）。只用 `cairo`（`cairo.ImageSurface.create_from_png`）。两张图尺寸不是 960×640 时照样拼（按各自尺寸，高度取较大的）。

## 测试（`panel/tests/test_render.py`）

文件开头尝试导入 `cairo` 和 `gi` 的 Pango；导入失败时用 `raise unittest.SkipTest("没有 gi / cairo")` 让整个文件跳过（这样在 MacBook Pro 上跑 `unittest discover` 不会报错）。在 Spark 上至少覆盖：

1. 对 `fixtures/` 里每个样例：`ViewModel` → `render_png` 到临时目录，文件存在；用 `cairo.ImageSurface.create_from_png` 读回来是 960×640。
2. 取像素检查（写一个辅助函数从 `ImageSurface.get_data()` 取某个像素的 RGB，注意 cairo 的字节顺序是 B、G、R、A）。坐标是 960×640 图里的像素：
   - 任何样例的 (4, 4) 是 `bg`（10, 11, 13）。
   - 任何样例的 (700, 100)（第一张卡片内部靠左上、没有字的地方；取不准就自己换一个确定在卡片内、没有字的点）是 `card`（20, 22, 26）。
   - `decode` 样例：圆弧左侧中点附近（`f = 0.25` 处，自己按公式算像素坐标）是 `accent`（118, 226, 183）；`f = 0.9` 处是 `track`（29, 32, 37）。
   - `prefill` 样例：`f = 0.25` 处是 `amber`（240, 180, 76）。
   - `idle` 样例：`f = 0.25` 处是半透明的底环（不是 `accent`，也不是纯 `bg`）。
   - `offline` 样例：(36, 46) 附近（红点中心）是 `danger`（226, 122, 114）。
   - 颜色比较允许每个通道差 3 以内。
3. `draw` 的健壮性：`View()`（全默认）、`View(cards=[])`、`View(state="offline")`、主数字为空、`bar` 三种 `kind`、`frame.dim = 0.4`、各不透明度为 0.5：都不抛异常。
4. `draw` 之后 cairo 上下文的变换矩阵和调用前相同（`cr.get_matrix()` 比较），没有残留的 group。
5. 画 100 次 `decode-multi` 样例（画到同一个 `ImageSurface` 上），总用时小于 2 秒。

## 对照原型（必须做，这是本任务的重点）

样例和原型截图的对应关系（文件名相同）：`offline`、`idle`、`prefill`、`prefill-fresh`、`prefill-miss`、`prefill-nohook`、`decode`、`decode-multi`、`queue`、`done`、`round-rest`。原型截图里的数字是动态的，和样例里的数字不完全一样（例如原型是 2387，样例是 2368），**这不算差异**；要比的是布局和样式。

做法：

```sh
cd /Users/kris/projects/tensorfold-panel
ssh spark 'rm -rf /tmp/tfpanel-h && mkdir -p /tmp/tfpanel-h/ref'
rsync -a --delete --exclude __pycache__ panel fixtures scripts spark:/tmp/tfpanel-h/
rsync -a docs/prototype-shots/ref/ spark:/tmp/tfpanel-h/ref/
ssh spark 'cd /tmp/tfpanel-h && python3 scripts/offscreen.py --out /tmp/tfpanel-h/out && for n in offline idle prefill prefill-fresh prefill-miss prefill-nohook decode decode-multi queue done round-rest; do python3 scripts/dev/compare.py ref/$n.png out/$n.png out/cmp-$n.png; done'
mkdir -p /tmp/tfpanel-h-out && rsync -a spark:/tmp/tfpanel-h/out/ /tmp/tfpanel-h-out/
```

然后用读文件的工具**逐张看** `/tmp/tfpanel-h-out/cmp-<名>.png`（左原型、右我们的），11 张都要看。逐项核对并修到一致：

- 状态条：圆点的位置、大小、颜色；状态名的字号和粗细；右侧文字的右边缘、粗体段、琥珀色段。
- 圆弧：粗细、起止位置、圆头；底环的明暗；刻度缺口；刻度数字的位置（6 个都要看）；灰色小点。
- 中间：标题行的位置、“精确”标记的样子（实底和描边两种）；主数字的大小、粗细、垂直位置、小数部分的大小和基线；进度条和它下面那行字；今日统计的那行日期；离线的两行字。
- 右侧：卡片的位置、圆角、底色、描边；标签、数值、单位、脚注的位置和大小（有无单位、有无脚注共四种组合都要看）；`—` 的颜色。
- 灰色画面（`round-rest`）：主数字和卡片数值是灰的。

同一处文字的位置和原型相差 2 像素（960×640 图里）以内算一致。位置对不上时先检查是不是没按“逻辑矩形在行框里垂直居中”和“基线对齐”来做，不要靠乱调数字凑。每改一轮重新同步、重新出图、重新看。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_render -v          # MacBook Pro 上应显示跳过，不报错
python3 -c "import ast; [ast.parse(open(p).read()) for p in ('panel/render.py', 'scripts/offscreen.py', 'scripts/dev/compare.py')]"
ssh spark 'rm -rf /tmp/tfpanel-h && mkdir -p /tmp/tfpanel-h/ref'
rsync -a --delete --exclude __pycache__ panel fixtures scripts spark:/tmp/tfpanel-h/
ssh spark 'cd /tmp/tfpanel-h && python3 -m unittest panel.tests.test_render -v 2>&1 | tail -15 && python3 scripts/offscreen.py --out /tmp/tfpanel-h/out | wc -l'
```

Spark 上的测试必须是 `OK`（不能是跳过），最后一行应是 `14`。结束前清理：`ssh spark 'rm -rf /tmp/tfpanel-h'`；MacBook Pro 上的 `/tmp/tfpanel-h-out/` 保留（编排者验收要看）。

最后在结果里简要写出：11 张对照图各自还剩哪些你发现但没能消除的差异（没有就写“无”）。
