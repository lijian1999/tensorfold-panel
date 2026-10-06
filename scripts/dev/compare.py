#!/usr/bin/env python3
"""把原型截图和我们的图左右拼成一张，便于逐处比对。

用法：python3 scripts/dev/compare.py <原型截图.png> <我们的图.png> <输出.png>
两张图尺寸不一样时也照样拼（各按自己的尺寸，高度取较大的），
中间留 10 宽的品红竖条。
"""

import sys

import cairo


def join(ref_path, mine_path, out_path):
    """左原型、右我们，中间 10 宽的品红竖条。"""
    a = cairo.ImageSurface.create_from_png(ref_path)
    b = cairo.ImageSurface.create_from_png(mine_path)
    w1, h1 = a.get_width(), a.get_height()
    w2, h2 = b.get_width(), b.get_height()
    width = w1 + 10 + w2
    height = max(h1, h2)
    surface = cairo.ImageSurface(cairo.FORMAT_RGB24, width, height)
    cr = cairo.Context(surface)
    cr.set_source_rgb(1.0, 0.0, 1.0)
    cr.paint()                                  # 整张先铺品红，中间留出竖条
    cr.set_source_surface(a, 0, 0)
    cr.paint()
    cr.set_source_surface(b, w1 + 10, 0)
    cr.paint()
    surface.flush()
    surface.write_to_png(out_path)
    return width, height


def main(argv):
    if len(argv) != 3:
        print("用法：compare.py <原型截图.png> <我们的图.png> <输出.png>",
              file=sys.stderr)
        return 1
    size = join(argv[0], argv[1], argv[2])
    print(f"{argv[2]} {size[0]}×{size[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
