# 任务 H2：绘制收尾（小修）

先读 `AGENTS.md`。`panel/render.py`、`scripts/offscreen.py`、`scripts/dev/compare.py`、`panel/tests/test_render.py` 上一位执行者已经写好。编排者在 Spark 上出了对照图并逐张看过：**布局、字号、颜色、卡片、主数字、进度条都已经和原型一致，不需要再调**。只剩下面三处问题，本任务只修这三处，**不要重写，不要动别的布局数值**。任务 H 的完整要求在 `docs/tasks/H-render.md`，需要时查阅。

绘制只能在 Spark 上运行。每次改完用下面这条命令同步并运行（下文称“同步并测试”）：

```sh
cd /Users/kris/projects/tensorfold-panel
ssh spark 'mkdir -p /tmp/tfpanel-h2/ref'
rsync -a --delete --exclude __pycache__ panel fixtures scripts spark:/tmp/tfpanel-h2/
ssh spark 'cd /tmp/tfpanel-h2 && python3 -m unittest panel.tests.test_render 2>&1 | tail -6'
```

## 第一步：看现状

运行“同步并测试”。现在应是 `FAILED (failures=32, errors=1)` 左右。

## 第二步：修 `panel/render.py` 的两处

1. **刻度数字没有画出来。** `_ticks` 函数写好了，但 `draw()` 里没有调用它。在 `draw()` 里 `_dial(cr, view, frame)` 之后加一行：`_block(cr, frame.ticks_alpha, _ticks, view, frame)`（`_block` 会把整块乘上不透明度；`_ticks` 开头那句 `if frame.ticks_alpha <= 0: return` 保留）。
2. **刻度缺口不要用 `OPERATOR_SOURCE`。** `_dial` 里画缺口的那段，删掉 `cr.set_operator(cairo.OPERATOR_SOURCE)` 和后面的 `cr.set_operator(cairo.OPERATOR_OVER)` 两行，其余不动（用默认的叠加方式画 `BG` 颜色的线即可；`SOURCE` 方式在半透明时会把画面擦出洞）。

## 第三步：修 `panel/tests/test_render.py`

1. 取像素的辅助函数把通道顺序弄反了：测试期望 `(10, 11, 13)`，实际取到 `(13, 11, 10)`。cairo 的 `FORMAT_RGB24` / `FORMAT_ARGB32` 在内存里每个像素 4 个字节，顺序是 **B、G、R、A**。把辅助函数改成返回 `(R, G, B)` = `(data[i + 2], data[i + 1], data[i])`。
2. 改完再运行“同步并测试”，把剩下的失败和报错逐个看：是测试取点的坐标不对（例如取到了有字的地方）就改测试里的坐标；是期望的颜色写错了就对照 `docs/tasks/H-render.md` 的颜色表改期望值。**不要改 `render.py` 的布局来迁就测试。**
3. 加一个测试：`decode` 样例里，刻度数字 “50” 所在的位置附近（`f = 0.4`，半径 `R + 20`，换算成 960×640 图里的像素坐标后，取它周围 24×16 像素的小块）至少有一个像素明显比背景亮（任一通道 > 80）；`idle` 样例里同一小块全是背景色（刻度不显示）。

直到 Spark 上 `python3 -m unittest panel.tests.test_render` 是 `OK`。

## 第四步：看三张对照图确认刻度数字的位置

```sh
cd /Users/kris/projects/tensorfold-panel
rsync -a docs/prototype-shots/ref/ spark:/tmp/tfpanel-h2/ref/
ssh spark 'cd /tmp/tfpanel-h2 && python3 scripts/offscreen.py --out /tmp/tfpanel-h2/out | wc -l && for n in decode-multi prefill-miss round-rest; do python3 scripts/dev/compare.py ref/$n.png out/$n.png out/cmp-$n.png; done'
mkdir -p /tmp/tfpanel-h2-out && rsync -a spark:/tmp/tfpanel-h2/out/ /tmp/tfpanel-h2-out/
```

第二条命令应先输出 `14`。然后用读文件的工具**只看这三张图**（左边原型、右边我们的）：`/tmp/tfpanel-h2-out/cmp-decode-multi.png`、`cmp-prefill-miss.png`、`cmp-round-rest.png`。核对：

- 右边现在有 6 个刻度数字，位置和左边一致（`0` 在左下、`25`/`600` 在左侧、`50`/`1.2K` 和 `100`/`1.8K` 在上方两侧、`200`/`2.4K` 在右侧、`300`/`3K` 在右下）。
- `round-rest` 里刻度数字比 `decode-multi` 里暗一些（不透明度 0.75）。
- 位置和原型相差 3 像素以内就算一致。差得多时只调 `_ticks` 里的半径（现在是 `r + 12` 和 `r + 20`），不要动别的。

原型截图里的数字是动态的（例如左边是 111、右边是 100），这不算差异。

## 第五步：收尾检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -c "import ast; [ast.parse(open(p).read()) for p in ('panel/render.py', 'panel/tests/test_render.py')]"
grep -n "OPERATOR_SOURCE" panel/render.py; echo "（上一行之前应没有任何输出）"
rsync -a --delete --exclude __pycache__ panel fixtures scripts spark:/tmp/tfpanel-h2/
ssh spark 'cd /tmp/tfpanel-h2 && python3 -m unittest panel.tests.test_render 2>&1 | tail -3; rm -rf /tmp/tfpanel-h2'
```

Spark 上的测试必须是 `OK`（不是跳过）。MacBook Pro 上的 `/tmp/tfpanel-h2-out/` 保留。最后一行输出 `DONE`。
