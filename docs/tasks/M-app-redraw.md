# 任务 M：窗口程序少画多余的帧（小修）

先读 `AGENTS.md`。只改一个文件：`panel/app.py`，只改 `PanelApp.deliver` 这一个方法。不要改别的方法、别的文件，不要在 Spark 上运行任何东西（副屏上正跑着正式程序；改完后由编排者部署和测量）。

## 背景

编排者在 Spark 上实测：模型忙的时候副屏程序占单核约 11.5%，而只跑 30 帧动画时是 6.7%。多出来的一部分来自多余的重画：忙的时候 33 毫秒的重画定时器已经在跑（每秒 30 帧），而 `deliver` 每收到一份新快照（每秒 10 次）又额外 `queue_draw()` 一次。定时器的下一帧本来就会用上最新的 `self.view`，这些额外的重画是白费的。

## 第一步：看现在的代码

```sh
cd /Users/kris/projects/tensorfold-panel
grep -n "def deliver" -A 10 panel/app.py
```

现在是：

```python
        view = self.viewmodel.update(snapshot, time.monotonic())
        if view != self.view:
            self.view = view
            if self.area is not None:
                self.area.queue_draw()
        return False
```

## 第二步：改成“定时器在跑就不额外重画”

把里面那个 `if` 改成：

```python
            if self.area is not None and self.timer is None:
                # 重画定时器在跑时，它的下一帧（33 毫秒内）会用上新的 view，不用额外重画
                self.area.queue_draw()
```

其余不动。同时把 `deliver` 的文档字符串改成一句话说清这个行为。

## 第三步：检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -c "import ast; ast.parse(open('panel/app.py').read()); print('语法正确')"
grep -n "self.timer is None" panel/app.py
git diff --stat -- panel/ 2>/dev/null | tail -1; python3 -m unittest discover -s panel/tests -t . 2>&1 | tail -3
```

通过的标准：第一条打印 `语法正确`；第二条至少有两行（`ensure_timer` 里原有的一处和你新加的一处）；测试是 `OK`（`skipped=1` 是正常的）。然后最后一行输出 `DONE`。
