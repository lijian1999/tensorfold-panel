# 任务 K：窗口程序（app）

先读 `AGENTS.md`（特别是“在 Spark 上运行”一节），再读 `docs/tasks/00-contracts.md` 全文和 `docs/design.md` 的“显示程序行为”一节。`scripts/dev/preview.py` 是之前在副屏上全屏显示原型用的小工具，GTK 4 找屏、全屏的写法可以参考它。

别的模块都已经有了，直接用，**不要改它们**：`panel/config.py`、`sources.py`、`usage.py`、`collector.py`、`poller.py`（`Poller`）、`viewmodel.py`（`ViewModel`）、`anim.py`（`Animator`）、`render.py`（`draw`）。

窗口程序只能在 Spark 上运行。代码在 MacBook Pro 上写，同步到 Spark 的 `/tmp/tfpanel-k/` 运行。副屏是 Spark 唯一的屏幕，**同一时刻只能有一个程序占着它，你测试时开的窗口结束前必须关掉**。

## 交付文件

1. `panel/app.py`：窗口程序。
2. `panel/__main__.py`：`from panel.app import main`，`raise SystemExit(main())`。
3. `scripts/tfpanel.sh`：在 Spark 上启动 / 停止 / 查看副屏程序。

不要创建或修改别的文件。

## 命令行

```sh
python3 -m panel [--config 路径] [--fixture 名字或路径] [--windowed] [--state-dir 目录]
```

- 不带参数：正式运行。读 `load_config(--config)`，找到副屏，全屏显示，轮询真实接口。
- `--fixture`：不轮询，只显示一个样例的画面（给名字就读仓库里的 `fixtures/<名字>.json`，仓库根目录 = `panel/` 的上一级；给路径就读那个文件）。用 `ViewModel` 得到 `View` 后一直显示它，动画（流指示点的脉冲）照常。用来和原型比对。
- `--windowed`：不全屏，开一个 960×640 的普通窗口（没有匹配的副屏时也开）。
- `--state-dir`：今日用量文件的目录，默认用配置里的。**测试时必须给一个 `/tmp/tfpanel-k/state` 这样的临时目录**，不要写正式的 `~/.local/state/tfpanel`。

## 行为

### 进程和应用

- `Gtk.Application`，`application_id="com.tensorfold.panel"`。正式运行用默认标志（同一时间只有一个实例：再启动一次时，第二个进程发现已有实例就直接退出，不开第二个窗口）；带 `--fixture` 或 `--windowed` 时用 `Gio.ApplicationFlags.NON_UNIQUE`。
- `app.hold()`：没有窗口时进程也不退出（副屏被拔掉时要等它插回来）。
- 收到 `SIGTERM`、`SIGINT`（用 `GLib.unix_signal_add`）时干净退出：停轮询线程、`usage.flush()`、关窗口、`app.quit()`。
- 向 stderr 打印少量中文日志（启动、找到副屏、副屏消失、退出），不要每帧、每次轮询都打印。

### 找副屏

- `Gdk.Display.get_default().get_monitors()` 里找：`config.monitor_match == "manufacturer"` 时比 `monitor.get_manufacturer()`，`"connector"` 时比 `monitor.get_connector()`，等于 `config.monitor_value` 的第一个。
- 找到：建窗口，`fullscreen_on_monitor(那个显示器)`，`present()`。**只在这一个显示器上开窗口**，别的显示器上不开任何东西。
- 找不到：不开窗口（`--windowed` 除外），等着。
- 监听显示器列表的变化（`get_monitors()` 返回的列表的 `items-changed` 信号），并且每 2 秒主动再检查一次（防止信号漏掉）：副屏出现了就开窗口；窗口所在的显示器不见了就关掉窗口；副屏还在但窗口没了就重开。

### 窗口

- `Gtk.ApplicationWindow`，`set_decorated(False)`，标题 `TFPanel`，里面只有一个 `Gtk.DrawingArea`（`set_draw_func`）。背景黑色。
- 不抢键盘焦点、不响应点击：窗口和绘图区都 `set_focusable(False)`、`set_can_focus(False)`；不接任何点击、按键的处理。
- 鼠标移到窗口上时隐藏指针：`窗口.set_cursor(Gdk.Cursor.new_from_name("none", None))`。
- 防息屏：窗口显示出来后 `app.inhibit(窗口, Gtk.ApplicationInhibitFlags.IDLE, "副屏仪表盘常亮")`，窗口关掉时 `app.uninhibit(...)`。
- `--windowed` 时不全屏，`set_default_size(960, 640)`。

### 数据和绘制

- 轮询在一个后台线程（`daemon=True`）里跑 `Poller.run`。`on_snapshot` 里用 `GLib.idle_add` 把快照交给主线程，**后台线程不碰任何 GTK 对象**。
- 主线程收到快照：`view = viewmodel.update(snapshot, time.monotonic())`。新的 `view` 和上一个不相等（数据类可以直接用 `!=` 比）就记下并 `queue_draw()`。
- 画一帧（`draw_func(area, cr, width, height)`）：`frame = animator.step(view, time.monotonic())`，`render.draw(cr, view, frame, width, height)`。还没有任何 `view` 时只把整个区域涂黑。
- 帧率：`frame.animating` 为真时，保证有一个 `GLib.timeout_add(33, …)` 的定时器在跑，它每次 `queue_draw()`；画完一帧发现 `frame.animating` 为假时让定时器停掉（回调返回 `False`）。静止时没有定时器，只有 `view` 变了才重画。不要同时起多个定时器。
- 没有窗口时（副屏被拔掉）轮询照常进行（今日用量要继续记），只是不画。
- `draw_func` 里出异常：打印一次（同样的错误不要每帧都打），不能让程序退出。

### 正式运行的组装

`config = load_config(...)` → `usage = UsageLedger(config, state_dir=--state-dir 或 None)` → `collector = Collector(config, usage)` → `fetcher = Fetcher(config.base_url)` → `poller = Poller(config, fetcher, collector)` → `viewmodel = ViewModel(config)`、`animator = Animator()`。

## `scripts/tfpanel.sh`

`#!/bin/sh`，`set -eu`，`chmod +x`，在 Spark 上运行：

```sh
~/tfpanel/scripts/tfpanel.sh start      # 启动（已在运行就说一声，不重复启动）
~/tfpanel/scripts/tfpanel.sh stop       # 停止
~/tfpanel/scripts/tfpanel.sh restart
~/tfpanel/scripts/tfpanel.sh status     # 在运行就打印进程号、已运行时间、CPU 和内存占用
```

- 程序目录 = 脚本所在目录的上一级（绝对路径）。
- `start`：环境变量没设时补上 `DISPLAY=:1`、`XAUTHORITY=/run/user/$(id -u)/gdm/Xauthority`、`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus`（已经设了就用已有的——开机启动项启动时桌面会给）。日志写到 `${TFPANEL_LOG:-$HOME/.local/state/tfpanel/tfpanel.log}`（目录不存在就建；启动时文件超过 1 MB 就先清空）。`cd` 到程序目录，`setsid nohup python3 -m panel "$@" >>日志 2>&1 </dev/null &`（`start` 后面的其他参数原样传给程序）。等 1 秒后检查进程还在，打印 `已启动（进程号 N）`；不在就打印日志最后 20 行并以 1 退出。
- 找进程：`pgrep -u "$(id -u)" -f "python3 -m pane[l]( |\$)"`（方括号写法避免匹配到自己；后面的 `( |$)` 避免匹配到 `python3 -m panel.poller`）。
- `stop`：对找到的进程 `kill`（SIGTERM），最多等 3 秒，还在就 `kill -9`。没在运行时打印 `没有在运行`，退出码 0。
- `status`：没在运行时打印 `没有在运行`，退出码 1。
- 参数不认识：打印用法，退出码 2。

## 在 Spark 上测试

每次测试前同步：

```sh
cd /Users/kris/projects/tensorfold-panel
ssh spark 'mkdir -p /tmp/tfpanel-k'
rsync -a --delete --exclude __pycache__ panel fixtures scripts spark:/tmp/tfpanel-k/
```

通过 SSH 运行时先 `export DISPLAY=:1 XAUTHORITY=/run/user/1000/gdm/Xauthority DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`。截副屏用 `python3 /tmp/tfpanel-k/scripts/dev/shot.py /tmp/tfpanel-k/shot-<名>.png`（截整个 X 屏幕，960×640），把图拷回 MacBook Pro 的 `/tmp/tfpanel-k-out/` 用读文件的工具看（你有视觉能力）。

必须做的检查：

1. **样例画面**：对 `decode-multi`、`idle`、`prefill`、`offline` 四个样例，各自 `cd /tmp/tfpanel-k && setsid nohup python3 -m panel --fixture <名> >/tmp/tfpanel-k/log-<名>.txt 2>&1 </dev/null &`，等 3 秒，截图，然后关掉（见下面“关掉程序”）。看图：副屏被仪表盘铺满（没有 GNOME 顶栏、没有窗口边框、没有鼠标指针），画面和 `docs/prototype-shots/ref/<名>.png` 的布局一致。日志里没有 Python 报错。
2. **正式运行**：`setsid nohup python3 -m panel --state-dir /tmp/tfpanel-k/state >/tmp/tfpanel-k/log-live.txt 2>&1 </dev/null &`，等 5 秒截图，看图上的状态合理（别的执行者多半正在用模型，所以很可能是“解码中”；流指示点的数量应和 `curl -s http://127.0.0.1:8888/health` 里的 `streams` 对得上）。再等 20 秒，查 `ps -o pid,etimes,pcpu,rss,cmd -p <进程号>`：CPU 占用（`pcpu`）不超过 8，内存（`rss`）不超过 200000 KB。日志里没有 Python 报错。`/tmp/tfpanel-k/state/usage.json` 已经生成。
3. **只有一个实例**：正式运行着的时候再启动一次同样的命令，第二个进程应很快自己退出，`pgrep` 只剩一个。
4. **干净退出**：`kill <进程号>`（SIGTERM）后 2 秒内进程消失，日志里有退出的那行、没有 Python 报错（没有 Traceback）；截图确认副屏回到了桌面。
5. **`tfpanel.sh`**：`TFPANEL_LOG=/tmp/tfpanel-k/tfpanel.log /tmp/tfpanel-k/scripts/tfpanel.sh start --state-dir /tmp/tfpanel-k/state`；`status` 能看到；再 `start` 一次提示已在运行；`stop` 后 `status` 说没有在运行（退出码 1）。`sh -n scripts/tfpanel.sh` 通过。
6. **找不到副屏**：写一个临时配置 `/tmp/tfpanel-k/noscreen.json`：`{"monitor_value": "不存在"}`，用 `--config` 启动（加 `--state-dir`）：进程不退出、不开任何窗口（截图还是桌面）、日志里有一行说明没找到副屏。然后关掉。

**关掉程序**：`for p in $(pgrep -f "python3 -m pane[l]( |\$)"); do kill $p; done`（方括号写法，别用 `pkill -f`）。全部测试做完后确认 `pgrep -f "python3 -m pane[l]"` 没有输出，再 `ssh spark 'rm -rf /tmp/tfpanel-k'`。MacBook Pro 上的 `/tmp/tfpanel-k-out/` 保留。

## 完成前必须运行并全部通过

上面“在 Spark 上测试”的 6 项，加上：

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -c "import ast; [ast.parse(open(p).read()) for p in ('panel/app.py', 'panel/__main__.py')]"
sh -n scripts/tfpanel.sh && test -x scripts/tfpanel.sh
python3 -m unittest discover -s panel/tests -t . 2>&1 | tail -3      # 已有的测试不能被弄坏
ssh spark 'pgrep -f "python3 -m pane[l]" || echo 副屏上没有残留的程序'
```

最后在结果里写出第 2 项测到的 CPU 和内存占用，以及 6 项里有没有没通过的。
