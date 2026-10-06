import sys, gi
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk
w = Gdk.get_default_root_window()
pb = Gdk.pixbuf_get_from_window(w, 0, 0, w.get_width(), w.get_height())
pb.savev(sys.argv[1], "png", [], [])
print(pb.get_width(), pb.get_height())
