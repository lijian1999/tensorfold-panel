# 临时预览：把原型以 Kiosk 模式全屏放到副屏上（按 Esc 退出）
import sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("WebKit", "6.0")
from gi.repository import Gdk, Gtk, WebKit

URL, SCREEN = sys.argv[1], "TYPE-C"

def on_activate(app):
    win = Gtk.ApplicationWindow(application=app, title="TFPanel 预览")
    win.set_decorated(False)
    view = WebKit.WebView()
    black = Gdk.RGBA(); black.parse("#000")
    view.set_background_color(black)
    win.set_child(view)
    view.load_uri(URL)
    keys = Gtk.EventControllerKey()
    keys.connect("key-pressed", lambda c, keyval, *a: (win.close(), True)[1] if keyval == Gdk.KEY_Escape else False)
    win.add_controller(keys)
    monitors = Gdk.Display.get_default().get_monitors()
    target = None
    for i in range(monitors.get_n_items()):
        m = monitors.get_item(i)
        print("monitor", i, m.get_connector(), m.get_manufacturer(), m.get_model(), m.get_geometry().width, m.get_geometry().height, flush=True)
        if m.get_model() == SCREEN:
            target = m
    if target is not None:
        win.fullscreen_on_monitor(target)
    else:
        win.fullscreen()
    win.present()

app = Gtk.Application(application_id="com.tensorfold.panel.preview")
app.connect("activate", on_activate)
app.run(None)
