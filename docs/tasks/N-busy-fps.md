# 任务 N：把“持续动画时的帧率”做成配置项

先读 `AGENTS.md`。本任务改四个文件：`panel/config.py`、`panel/app.py`、`panel/tests/test_base.py`、`README.md`。不要改别的文件，不要在 Spark 上运行任何东西（副屏上正跑着正式程序；改完由编排者部署和测量）。

## 背景

编排者实测：副屏每秒重画 30 帧时，模型的解码速度会慢约 5%（显示和推理共用同一块显卡）；10 帧时慢约 2%。所以要让帧率可以配置。默认值保持 30，行为不变。

画面上的动画分两种：

- **切换动画**：画面内容换了之后的淡入（0.3–0.8 秒）。`Frame` 里 `center_alpha`、`stats_alpha`、`strip_alpha` 三个值里有任何一个小于 1 时，就是正在淡入。这种时候固定每秒 30 帧（33 毫秒一帧）。
- **持续动画**：解码、预填充期间流指示点一直在闪，圆弧在缓动。这种时候按配置的帧率画。

## 第一步：`panel/config.py` 加一个配置项

在 `Config` 里 `dim_after_s` 那一行后面加：

```python
    anim_fps: float = 30.0                  # 持续动画（解码、预填充期间）的帧率；切换画面的淡入固定 30
```

运行：

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -c "from panel.config import Config; print(Config().anim_fps)"
```

应输出 `30.0`。

## 第二步：`panel/app.py` 按帧率定重画间隔

现在 `ensure_timer()` 固定用 `GLib.timeout_add(33, tick)`。改成：

1. 给 `PanelApp.__init__` 加一个属性 `self.timer_ms = None`（当前定时器的间隔，毫秒）。
2. 加一个方法：

```python
    def frame_interval_ms(self, frame) -> int:
        """这一帧之后隔多久画下一帧：正在淡入时 33 毫秒，其余按配置的帧率（限制在每秒 1 到 30 帧）。"""
        if min(frame.center_alpha, frame.stats_alpha, frame.strip_alpha) < 1.0:
            return 33
        fps = self.config.anim_fps
        if not isinstance(fps, (int, float)) or isinstance(fps, bool) or fps != fps:
            fps = 30.0
        fps = max(1.0, min(30.0, float(fps)))
        return max(33, int(round(1000.0 / fps)))
```

3. `ensure_timer` 改成接收间隔：`def ensure_timer(self, interval_ms: int) -> None`。定时器已经在跑且 `self.timer_ms == interval_ms` 时直接返回；在跑但间隔不同就先 `self.stop_timer()` 再按新间隔起一个；起的时候 `GLib.timeout_add(interval_ms, tick)` 并记下 `self.timer_ms = interval_ms`。
4. `stop_timer` 里把 `self.timer_ms` 也置回 `None`。`tick` 里因为窗口关了而停掉时同样置 `None`。
5. `draw` 里 `if frame.animating: self.ensure_timer()` 改成 `self.ensure_timer(self.frame_interval_ms(frame))`。

其余不动。运行：

```sh
python3 -c "import ast; ast.parse(open('panel/app.py').read()); print('语法正确')"
grep -n "timer_ms\|frame_interval_ms\|timeout_add(" panel/app.py
```

`timeout_add(` 那几行里不应再有写死的 `33`（2 秒的显示器复查定时器 `timeout_add(2000, …)` 保留）。

## 第三步：`panel/tests/test_base.py` 补测试

在已有的配置测试旁边加：

1. `Config().anim_fps == 30.0`。
2. 用临时文件写 `{"anim_fps": 10}`，`load_config` 得到 `anim_fps == 10.0`；写 `{"anim_fps": "快"}` 得到 `30.0`。

`panel/app.py` 在 MacBook Pro 上导入不了（没有 GTK），所以 `frame_interval_ms` 不在这里测，由编排者在 Spark 上验证。

```sh
python3 -m unittest panel.tests.test_base 2>&1 | tail -3
```

应是 `OK`。

## 第四步：`README.md` 的配置表加一行

在“配置”一节的表里，`dim_after_s` 那一行后面加一行：

```text
| `anim_fps` | 解码、预填充期间画面每秒重画几次（1–30）。画面和推理共用显卡，30 时解码会慢约 5%，10 时慢约 2% | `30.0` |
```

## 第五步：收尾检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest discover -s panel/tests -t . 2>&1 | tail -3
python3 - <<'EOF'
import dataclasses
from panel.config import Config
text = open("README.md", encoding="utf-8").read()
print("配置项缺失:", [f.name for f in dataclasses.fields(Config) if f"`{f.name}`" not in text])
EOF
```

通过的标准：测试 `OK`（`skipped=1` 正常）；第二条打印 `配置项缺失: []`。然后最后一行输出 `DONE`。
