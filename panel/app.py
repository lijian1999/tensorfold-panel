"""窗口程序（只在 Spark 上运行）：找副屏、开窗口、后台轮询、按需重画。

- 按厂商 / 接口名在副屏上开无边框全屏窗口；找不到副屏不开窗口，
  每 2 秒 + 显示器列表变化时重新检查，插回来自动重开。
- --fixture 只显示一个样例画面（不轮询，给和原型比对用）；
  --windowed 不全屏，开 960×640 的普通窗口。
- 轮询在后台线程（daemon）里跑 Poller.run；后台线程不碰任何 GTK 对象，
  用 GLib.idle_add 把快照交给主线程。
- 帧率：画面有动画时保证有一个重画定时器在跑（淡入时 33ms，持续动画按配置的 anim_fps），静止时停掉。

绘制和动画本身在 render.draw / Animator.step 里，这个文件只管窗口和调度。
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import threading
import time
import traceback

import gi

# GB10 显卡上 GTK4 的 GL 绘制器在 gsk_renderer_render 里偶发段错误（实测），
# 改用纯 CPU 的 cairo 绘制器；外部显式设了 GSK_RENDERER 时尊重外部值。
os.environ.setdefault("GSK_RENDERER", "cairo")

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk

from panel import render
from panel.anim import Animator
from panel.collector import Collector
from panel.config import load_config
from panel.poller import Poller
from panel.sources import Fetcher
from panel.usage import UsageLedger
from panel.viewmodel import ViewModel

APP_ID = "com.tensorfold.panel"

# 仓库根目录 = panel/ 的上一级（--fixture 给名字时在这里的 fixtures/ 里找）
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MODE_FIXTURE = "fixture"   # 只显示一个样例
MODE_LIVE = "live"        # 正式运行：轮询真实接口


def log(msg: str) -> None:
    """少量中文日志，走 stderr。"""
    print(msg, file=sys.stderr, flush=True)


def app_id_taken(app_id: str) -> bool:
    """在会话总线上查这个应用编号有没有人占用（有没有第二个实例）。

    总线用不上或出错时算没人占用。
    """
    try:
        conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        if conn is None:
            return False
        reply = conn.call_sync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            GLib.Variant("(s)", (app_id,)),
            GLib.VariantType("(b)"),
            Gio.DBusCallFlags.NONE,
            2000,
            None,
        )
        if reply is None:
            return False
        return bool(reply.unpack()[0])
    except Exception:
        return False


class PanelApp:
    """窗口程序的全部状态：找屏、窗口、轮询、重画定时器。"""

    def __init__(self, app, config, mode, windowed, state_dir, fixture):
        self.app = app
        self.config = config
        self.mode = mode
        self.windowed = windowed
        self.state_dir = state_dir
        self.fixture = fixture
        self.stop_event = threading.Event()
        self.poll_thread = None          # 轮询线程（daemon）
        self.usage = None                # 今日用量（正式运行才有）
        self.fetcher = None
        self.poller = None
        self.viewmodel = ViewModel(config)
        self.animator = Animator()
        self.view = None                 # 当前的 View（None = 画面还没内容）
        self.win = None                  # 唯一的那个窗口
        self.area = None                 # 窗口里的绘图区
        self.inhibit_cookie = None       # 防息屏的申请号
        self.timer = None                # 重画定时器（GSource）
        self.timer_ms = None             # 当前定时器的间隔，毫秒
        self.check_timer = None          # 2 秒的显示器复查定时器
        self._draw_errors = set()        # draw_func 里打过的错误（同样的只打一次）
        self._started = False            # activate 重入时不再重新组装
        self._logged_none = False        # “找不到副屏”这行日志打过没有

    # ---------- 组装 ----------

    def read_fixture(self) -> dict | None:
        """读样例快照：给名字读仓库的 fixtures/<名字>.json，给路径读那个文件。"""
        spec = self.fixture
        if os.path.sep in spec:
            path = spec
        else:
            path = os.path.join(REPO_ROOT, "fixtures", spec)
            if not path.endswith(".json"):
                path += ".json"
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def start_poller(self) -> None:
        """按正式运行的组装把轮询开在后台线程里。"""
        self.usage = UsageLedger(self.config, state_dir=self.state_dir)
        collector = Collector(self.config, self.usage)
        self.fetcher = Fetcher(self.config.base_url)
        self.poller = Poller(self.config, self.fetcher, collector)
        self.poll_thread = threading.Thread(
            target=self.poller.run,
            args=(self.on_snapshot, self.stop_event),
            daemon=True,
        )
        self.poll_thread.start()

    def start_monitor_watch(self) -> bool:
        """挂上显示器列表的监听和 2 秒一次的复查。没有显示器返回 False。"""
        display = Gdk.Display.get_default()
        if display is None:
            log("找不到任何显示器，没有地方放窗口，退出")
            return False
        monitors = display.get_monitors()
        monitors.connect("items-changed", lambda *a: self.check_monitors())
        self.check_timer = GLib.timeout_add(2000, self.every_2s)

        def on_signal():
            # GLib.unix_signal_add 的回调不带参数；返回 False 是为了释放这个源
            self.quit()
            return False

        for sig in (signal.SIGTERM, signal.SIGINT):
            GLib.unix_signal_add(GLib.PRIORITY_HIGH, int(sig), on_signal)
        return True

    def activate(self) -> None:
        """应用 activate（首次启动和别的实例转发过来的唤起）：组装 + 检查窗口。"""
        if not self._started:
            self._started = True
            if self.mode == MODE_FIXTURE:
                snapshot = self.read_fixture()
                if snapshot is None:
                    log(f"样例读取失败：{self.fixture}")
                    self.app.quit()          # 没东西可画，别挂着空转
                    return
                # 只做一个画面，之后一直显示它（脉冲动画照常走）
                self.view = self.viewmodel.update(snapshot, time.monotonic())
            else:
                self.start_poller()
            if not self.start_monitor_watch():
                self.app.quit()
                return
        self.check_monitors()

    # ---------- 找副屏和窗口 ----------

    def find_monitor(self):
        """找第一个匹配配置值的显示器；配置没给匹配上时返回 None。"""
        display = Gdk.Display.get_default()
        if display is None:
            return None
        monitors = display.get_monitors()
        for i in range(monitors.get_n_items()):
            m = monitors.get_item(i)
            if self.config.monitor_match == "connector":
                got = m.get_connector()
            else:
                got = m.get_manufacturer()
            if got == self.config.monitor_value:
                return m
        return None

    def check_monitors(self) -> None:
        """有副屏且窗口不在（或关了）就开窗口；副屏没了就关掉窗口等着。"""
        if self.windowed:
            if self.win is None:
                self.create_window(None)
            return
        target = self.find_monitor()
        if target is None:
            if not self._logged_none:
                self._logged_none = True
                log(f"找不到副屏（按 {self.config.monitor_match}"
                    f"={self.config.monitor_value} 没匹配上），等它插回来")
            if self.win is not None:
                log("副屏不见了，关掉窗口")
                self.destroy_window()
            return
        self._logged_none = False
        try:
            mapped = self.win is not None and self.win.get_mapped()
        except Exception:
            mapped = False
        if mapped:
            return
        if self.win is not None:
            # 副屏还在但窗口关了（例如被窗口管理器收掉）：旧的不要了，重开
            self.destroy_window()
        log("找到副屏，开全屏窗口")
        self.create_window(target)

    def create_window(self, monitor) -> None:
        """建窗口：全屏（非 --windowed）画在 monitor 上，普通窗口 960×640。"""
        win = Gtk.ApplicationWindow(application=self.app)
        win.set_decorated(False)
        win.set_title("TFPanel")
        # 不抢键盘焦点、不响应点击：不给焦点属性，也不接任何按键/点击的处理
        win.set_focusable(False)
        win.set_can_focus(False)
        try:
            # 鼠标移到窗口上时隐藏指针
            win.set_cursor(Gdk.Cursor.new_from_name("none", None))
        except Exception:
            pass
        area = Gtk.DrawingArea()
        area.set_focusable(False)
        area.set_can_focus(False)
        area.set_draw_func(self.draw)
        win.set_child(area)
        if monitor is not None and not self.windowed:
            win.fullscreen_on_monitor(monitor)
        if self.windowed:
            win.set_default_size(960, 640)
        win.present()
        self.win = win
        self.area = area
        # 防息屏：窗口显示出来后申请“不要因空闲息屏”
        self.inhibit_cookie = self.app.inhibit(
            win, Gtk.ApplicationInhibitFlags.IDLE, "副屏仪表盘常亮")

    def destroy_window(self) -> None:
        """关掉窗口：停重画定时器、撤销防息屏申请、销毁窗口。"""
        self.stop_timer()
        if self.inhibit_cookie is not None:
            try:
                self.app.uninhibit(self.inhibit_cookie)
            except Exception:
                pass
            self.inhibit_cookie = None
        win, self.win, self.area = self.win, None, None
        if win is not None:
            try:
                win.destroy()
            except Exception:
                pass

    # ---------- 数据和绘制 ----------

    def on_snapshot(self, snapshot) -> None:
        """轮询线程回调：不碰任何 GTK 对象，把快照交给主线程。"""
        if self.stop_event.is_set():
            return
        GLib.idle_add(self.deliver, snapshot)

    def deliver(self, snapshot) -> bool:
        """主线程：快照 → View；和上一个不一样就记下，重画定时器没在跑时才额外重画一次（定时器下一帧 33 毫秒内就会用上新 view）。"""
        if self.stop_event.is_set():
            return False
        view = self.viewmodel.update(snapshot, time.monotonic())
        if view != self.view:
            self.view = view
            if self.area is not None and self.timer is None:
                # 重画定时器在跑时，它的下一帧（33 毫秒内）会用上新的 view，不用额外重画
                self.area.queue_draw()
        return False

    def draw(self, area, cr, width, height) -> None:
        """DrawingArea 的绘制回调（画一帧）。"""
        try:
            if self.view is None:
                # 还没有任何画面：把整个区域涂黑
                cr.set_source_rgb(0, 0, 0)
                cr.paint()
                return
            frame = self.animator.step(self.view, time.monotonic())
            render.draw(cr, self.view, frame, width, height)
            if frame.animating:
                self.ensure_timer(self.frame_interval_ms(frame))
            else:
                self.stop_timer()
        except Exception as e:
            # 打印一次就够了，不能让程序退出
            key = f"{type(e).__name__}: {e}"
            if key not in self._draw_errors:
                self._draw_errors.add(key)
                log(f"绘制出错（同样的错误不再重复打印）：{key}")
                traceback.print_exc(limit=1, file=sys.stderr)

    def frame_interval_ms(self, frame) -> int:
        """这一帧之后隔多久画下一帧：正在淡入时 33 毫秒，其余按配置的帧率（限制在每秒 1 到 30 帧）。"""
        if min(frame.center_alpha, frame.stats_alpha, frame.strip_alpha) < 1.0:
            return 33
        fps = self.config.anim_fps
        if not isinstance(fps, (int, float)) or isinstance(fps, bool) or fps != fps:
            fps = 10.0
        fps = max(1.0, min(30.0, float(fps)))
        return max(33, int(round(1000.0 / fps)))

    def ensure_timer(self, interval_ms: int) -> None:
        """保证有一个间隔为 interval_ms 的重画定时器在跑（同一时刻不允许多个）。

        间隔和正在跑的不一样：先停掉旧的，再按新间隔起一个。
        """
        if self.timer is not None:
            if self.timer_ms == interval_ms:
                return
            self.stop_timer()
        area = self.area

        def tick():
            if self.area is not area:
                # 窗口已经关了：停掉定时器
                self.timer = None
                self.timer_ms = None
                return False
            self.area.queue_draw()
            return True

        self.timer = GLib.timeout_add(interval_ms, tick)
        self.timer_ms = interval_ms

    def stop_timer(self) -> None:
        """停掉重画定时器（这台机器上 timeout_add 返回整数 id）。"""
        timer, self.timer = self.timer, None
        self.timer_ms = None
        if timer is None:
            return
        try:
            if hasattr(timer, "destroy"):
                timer.destroy()
            else:
                GLib.Source.remove(timer)
        except Exception:
            pass

    def every_2s(self) -> bool:
        """每 2 秒再检查一次显示器（防止 items-changed 信号漏掉）。"""
        self.check_monitors()
        return True

    def quit(self) -> None:
        """收到 SIGTERM/SIGINT：停轮询线程、写账本、关窗口、退出。"""
        log("退出：停轮询、关窗口")
        self.stop_event.set()
        if self.poll_thread is not None:
            self.poll_thread.join(timeout=1.5)
        if self.usage is not None:
            self.usage.flush()
        if self.fetcher is not None:
            self.fetcher.close()
        self.destroy_window()
        self.app.quit()


def main(argv=None) -> int:
    """命令行入口：认参数、建应用、交给 PanelApp。"""
    parser = argparse.ArgumentParser(prog="python3 -m panel",
                                     description="TensorFold 副屏性能仪表盘")
    parser.add_argument("--config", default=None, help="配置文件路径")
    parser.add_argument("--fixture", default=None,
                        help="只显示一个样例的画面（名字或路径），不轮询")
    parser.add_argument("--windowed", action="store_true",
                        help="不全屏，开一个 960×640 的普通窗口")
    parser.add_argument("--state-dir", dest="state_dir", default=None,
                        help="今日用量文件的目录（默认用配置里的）")
    args = parser.parse_args(argv)

    config = load_config(args.config)
    if args.fixture:
        mode = MODE_FIXTURE
        log(f"启动：显示样例 {args.fixture}")
    else:
        mode = MODE_LIVE
        log(f"启动：正式运行，轮询 {config.base_url}")

    # 正式运行用默认标志（同一时间只有一个实例）；样例 / 窗口模式不做唯一限制
    unique = not (args.fixture or args.windowed)
    if unique and app_id_taken(APP_ID):
        log("已有实例在运行，这个进程不再开第二个窗口，退出")
        return 0
    if unique:
        app = Gtk.Application(application_id=APP_ID)
    else:
        app = Gtk.Application(application_id=APP_ID,
                              flags=Gio.ApplicationFlags.NON_UNIQUE)

    panel = PanelApp(app, config, mode,
                     args.windowed, args.state_dir, args.fixture)

    def on_activate(application):
        panel.activate()

    app.connect("activate", on_activate)
    # 没有窗口时（例如副屏被拔掉）进程也不退出
    app.hold()
    app.run(None)
    return 0
