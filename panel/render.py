"""绘制：View + Frame → cairo。只画，不读文件、不打印。

坐标系：draw 开头把 cairo 上下文按 width/480、height/320 放大，
之后所有坐标、尺寸都按 480×320 写（副屏真实像素 960×640 就是 2 倍）。

文字用 PangoCairo：字号用绝对尺寸（随 cr.scale 一起放大），全部开等宽数字
（tnum=1），字距用 letter-spacing（em 数 × 字号）。每段文字的垂直位置按
“逻辑矩形在行框里垂直居中”算，和浏览器里 line-height 的效果一致；
一行里几段不同样式的文字基线对齐。布局与颜色照原型
docs/dashboard-prototype.html 的 CSS。
"""

from __future__ import annotations

import math

import cairo
import gi

gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Pango, PangoCairo

from panel.anim import Animator
from panel.scale import SCALES, TICK_FRACS

# ---------------------------------------------------------------- 颜色

BG = (0x0A / 255, 0x0B / 255, 0x0D / 255)
CARD = (0x14 / 255, 0x16 / 255, 0x1A / 255)
CARD_LINE = (0x1D / 255, 0x20 / 255, 0x25 / 255)
TEXT = (0xF3 / 255, 0xF4 / 255, 0xF6 / 255)
TEXT_2 = (0xA7 / 255, 0xAD / 255, 0xB6 / 255)
MUTED = (0x8C / 255, 0x92 / 255, 0x9B / 255)
FAINT = (0x55 / 255, 0x5B / 255, 0x64 / 255)
ACCENT = (0x76 / 255, 0xE2 / 255, 0xB7 / 255)
AMBER = (0xF0 / 255, 0xB4 / 255, 0x4C / 255)
DANGER = (0xE2 / 255, 0x7A / 255, 0x72 / 255)
GHOST = (0x59 / 255, 0x60 / 255, 0x6A / 255)
PILL_BG = (0x76 / 255, 0xE2 / 255, 0xB7 / 255)      # 底色不透明度 0.15
PILL_BG_ALPHA = 0.15
PILL_TEXT = (0x8E / 255, 0xEA / 255, 0xC5 / 255)
TRACK = CARD_LINE                    # 底环和卡片描边同色

FAMILY = "Noto Sans CJK SC"
DIAL = (166, 184, 124)             # 仪表圆心 x、y 和半径
STRIP_Y = 23                       # 状态条的垂直中心

_LAYOUTS: dict = {}                # (文字, 字号, 字重, 字距) → 布局
_MAX_LAYOUTS = 4096


# ---------------------------------------------------------------- 文字

def _desc(size, bold):
    """字体描述：族 + 绝对字号 + 字重。"""
    desc = Pango.FontDescription.new()
    desc.set_family(FAMILY)
    desc.set_weight(Pango.Weight.BOLD if bold else Pango.Weight.NORMAL)
    desc.set_absolute_size(size * Pango.SCALE)
    return desc


def _attrs(size, ls_em):
    """属性表：等宽数字 + 字距。"""
    attrs = Pango.AttrList()
    attrs.insert(Pango.attr_font_features_new("tnum=1"))
    if ls_em:
        attrs.insert(Pango.attr_letter_spacing_new(
            int(ls_em * size * Pango.SCALE)))
    return attrs


def _layout(cr, text, size, bold, ls_em=0.0):
    """取（或新建）布局。同样的文字 + 字号 + 字重 + 字距只建一次。"""
    key = (text, size, bold, ls_em)
    lay = _LAYOUTS.get(key)
    if lay is None:
        if len(_LAYOUTS) > _MAX_LAYOUTS:
            _LAYOUTS.clear()
        lay = PangoCairo.create_layout(cr)
        lay.set_text(text, -1)
        lay.set_font_description(_desc(size, bold))
        lay.set_attributes(_attrs(size, ls_em))
        _LAYOUTS[key] = lay
    return lay


def _box(cr, lay):
    """布局的逻辑矩形（坐标单位）和基线到逻辑矩形顶边的距离。"""
    PangoCairo.update_layout(cr, lay)
    rect = lay.get_extents().logical_rect
    scale = Pango.SCALE
    return rect.width / scale, rect.height / scale, lay.get_baseline() / scale


def _style(style, default_color):
    """Seg 的样式 → (是否粗, 颜色)。"""
    if style == "strong":
        return True, TEXT_2
    if style == "warn":
        return True, AMBER
    return False, default_color


def _width(cr, text, size, bold, ls_em=0.0):
    """一段文字占多宽（用来算后面文字的起点）。"""
    if not text:
        return 0.0
    return _box(cr, _layout(cr, text, size, bold, ls_em))[0]


def _draw_line(cr, segs, anchor_x, anchor_y, align="left", mode="center",
               gap=0.0):
    """画一行文字，返回这一行的总宽度。

    segs 是 (文字, 字号, 是否粗, 颜色, 字距) 的列表，段与段之间隔 gap。
    anchor_x 按 align 解释（left 从它起排、center 以它为中心、right 右对齐）。
    mode="center"：每段的逻辑矩形垂直居中在 anchor_y 这一行里；
    mode="baseline"：各段基线对齐；第一段（主段）的逻辑矩形垂直居中在
    anchor_y 的那块 34 高（或 41.4 高）的范围里，其余各段跟着它的基线走。
    """
    items = []
    for text, size, bold, color, ls in segs:
        if not text:
            continue
        lay = _layout(cr, text, size, bold, ls)
        w, h, base = _box(cr, lay)
        if w > 0 and h > 0:
            items.append((lay, w, h, base, color))
    if not items:
        return 0.0
    total = sum(it[1] for it in items) + gap * (len(items) - 1)
    if align == "center":
        x = anchor_x - total / 2
    elif align == "right":
        x = anchor_x - total
    else:
        x = anchor_x
    if mode == "baseline":
        main = items[0]
        base_y = anchor_y - main[2] / 2 + main[3]
        for lay, w, h, base, color in items:
            cr.set_source_rgb(*color)
            cr.move_to(x, base_y - base)
            PangoCairo.show_layout(cr, lay)
            x += w + gap
    else:
        for lay, w, h, base, color in items:
            cr.set_source_rgb(*color)
            cr.move_to(x, anchor_y - h / 2)
            PangoCairo.show_layout(cr, lay)
            x += w + gap
    return total


def _text(cr, text, size, x, y, color=MUTED, bold=False, align="left",
          ls=0.0):
    """一段文字，垂直居中在 y。"""
    if not text:
        return 0.0
    return _draw_line(cr, [(text, size, bold, color, ls)], x, y, align)


# ---------------------------------------------------------------- 小块

def _block(cr, alpha, draw_fn, *args):
    """整块乘一个不透明度（重叠处不会透出来）。不透明度 1 时不用 group。"""
    if alpha <= 0:
        return
    if alpha >= 1:
        draw_fn(cr, *args)
        return
    cr.push_group()
    draw_fn(cr, *args)
    cr.pop_group_to_source()
    cr.paint_with_alpha(alpha)
    cr.set_source_rgb(0, 0, 0)


def _rrect(cr, x, y, w, h, r):
    """圆角矩形的路径。"""
    r = min(r, w / 2, h / 2)
    cr.new_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
    cr.close_path()


def _circle(cr, cx, cy, r, color, alpha=1.0):
    """实心圆点。"""
    cr.new_path()
    cr.arc(cx, cy, r, 0, math.tau)
    cr.set_source_rgba(*color, _clamp01(alpha))
    cr.fill()
    cr.new_path()


def _clamp01(x):
    return 0.0 if x < 0 else (1.0 if x > 1 else x)


# ---------------------------------------------------------------- 状态条

def _dots(cr, lanes, n, frame):
    """流指示点：解码中（薄荷绿）→ 预填充中（琥珀）→ 空着（灰）。"""
    dec = max(0, int(lanes.decoding or 0))
    pre = max(0, int(lanes.prefilling or 0))
    for i in range(n):
        if i < dec:
            color, alpha = ACCENT, _clamp01(frame.pulse_dec)
        elif i < dec + pre:
            color, alpha = AMBER, _clamp01(frame.pulse_pre)
        else:
            color, alpha = FAINT, 0.5
        _circle(cr, 14 + 3.5 + 11 * i, STRIP_Y, 3.5, color, alpha)


def _strip(cr, view, frame):
    """状态条：流指示点、排队数、状态名、模型名、右侧文字。"""
    lanes = view.lanes
    x = 14.0
    if lanes.offline:
        # 离线：只有一个红点，直径 8
        _circle(cr, 18, STRIP_Y, 4, DANGER)
        x = 22 + 8
    else:
        n = max(0, min(12, int(lanes.max or 0)))
        right = (14 + 11 * n - 4) if n else 14      # 最后一个点的右边缘
        if n:
            _dots(cr, lanes, n, frame)
        if (lanes.waiting or 0) > 0:
            text = f"+{lanes.waiting}"
            w = _width(cr, text, 12, True)
            _text(cr, text, 12, right + 5, STRIP_Y, AMBER, True)
            x = right + 5 + w + 8
        else:
            x = right + 8
    if view.state_name:
        w = _width(cr, view.state_name, 14, True)
        _text(cr, view.state_name, 14, x, STRIP_Y, TEXT, True)
        x += w + 8
    if view.strip_left:
        _text(cr, view.strip_left, 13, x, STRIP_Y, MUTED)
    if view.strip_right:
        segs = [(seg.text, 13) + _style(seg.style, MUTED) + (0.0,)
                for seg in view.strip_right]
        _draw_line(cr, segs, 466, STRIP_Y, "right")


# ---------------------------------------------------------------- 仪表

def _dial(cr, view, frame):
    """仪表：底环、刻度缺口、灰色小点、数值弧、刻度数字。

    圆弧位置 f 对应的 cairo 角度 = 135° + 270°×f（y 轴向下，角度增大是顺时针）。
    """
    cx, cy, r = DIAL
    if frame.track_alpha > 0:
        cr.new_path()
        cr.set_line_width(14)
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.arc(cx, cy, r, math.radians(135), math.radians(405))
        cr.set_source_rgba(*TRACK, _clamp01(frame.track_alpha))
        cr.stroke()
        cr.new_path()
    if frame.notch_alpha > 0:
        # 刻度缺口：用底色在底环上画四道缺口（SOURCE 方式在半透明时会把画面擦出洞）
        cr.new_path()
        cr.set_line_width(2.5)
        cr.set_line_cap(cairo.LINE_CAP_BUTT)
        for f in TICK_FRACS:
            if not 0 < f < 1:
                continue
            a = math.radians(135 + 270 * f)
            ca, sa = math.cos(a), math.sin(a)
            cr.new_sub_path()
            cr.move_to(cx + (r - 8) * ca, cy + (r - 8) * sa)
            cr.line_to(cx + (r + 8) * ca, cy + (r + 8) * sa)
        cr.set_source_rgba(*BG, _clamp01(frame.notch_alpha))
        cr.stroke()
    if view.ghost is not None and frame.ghost_alpha > 0:
        a = math.radians(135 + 270 * _clamp01(view.ghost))
        _circle(cr, cx + r * math.cos(a), cy + r * math.sin(a), 7, GHOST,
                frame.ghost_alpha)
    if frame.value_alpha > 0:
        cr.set_line_width(14)
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        if frame.arc_frac <= 0:
            # 弧长为零：画成起点处的一个圆点
            a = math.radians(135)
            _circle(cr, cx + r * math.cos(a), cy + r * math.sin(a), 7,
                    _mix(ACCENT, AMBER, _clamp01(frame.arc_mix)),
                    _clamp01(frame.value_alpha))
        else:
            cr.new_path()
            a0 = math.radians(135)
            cr.arc(cx, cy, r, a0,
                   a0 + math.radians(270 * _clamp01(frame.arc_frac)))
            _arc_color(cr, frame.arc_mix, _clamp01(frame.value_alpha))
            cr.stroke()
    cr.set_line_cap(cairo.LINE_CAP_BUTT)
    cr.new_path()


def _mix(c1, c2, t):
    """两个颜色按 t 线性混合。"""
    return tuple(a + (b - a) * t for a, b in zip(c1, c2))


def _arc_color(cr, mix, alpha):
    """数值弧的颜色：薄荷绿 → 琥珀色按 mix 混合。"""
    cr.set_source_rgba(*_mix(ACCENT, AMBER, _clamp01(mix)), alpha)


def _ticks(cr, view, frame):
    """刻度数字：六个，位置见任务说明。"""
    if frame.ticks_alpha <= 0:
        return
    labels = (SCALES.get(view.scale) or SCALES["decode"])["labels"]
    cx, cy, r = DIAL
    for f, label in zip(TICK_FRACS, labels):
        a = math.radians(135 + 270 * f)
        c = math.cos(a)
        if c < -0.85:
            rad, align = r + 12, "right"
        elif c > 0.85:
            rad, align = r + 12, "left"
        else:
            rad, align = r + 20, "center"
        ca, sa = math.cos(a), math.sin(a)
        _text(cr, str(label), 12, cx + rad * ca, cy + rad * sa, MUTED, True,
              align)


def _cap_line(cr, view):
    """标题行：标题（· 单位），后面可能跟一个“精确”或“近期平均”标记，整体水平居中。"""
    text = f"{view.cap} · {view.unit}" if view.unit else view.cap
    pill_text = "近期平均" if view.pill_kind == "avg" else "精确"
    w_cap = _width(cr, text, 13, False) if text else 0
    w_pill = _width(cr, pill_text, 12, True, 0.04) + 14 if view.pill else 0
    gap = 6 if (text and view.pill) else 0
    x = 166 - (w_cap + gap + w_pill) / 2
    if text:
        _text(cr, text, 13, x, 128, MUTED)
    if not view.pill:
        return
    px = x + w_cap + gap
    if view.muted:
        # 灰色画面：没有底色，改画 1 宽的内侧描边，文字变灰
        _rrect(cr, px + 0.5, 119.5, w_pill - 1, 17, 8.5)
        cr.set_line_width(1)
        cr.set_source_rgb(*FAINT)
        cr.stroke()
        _text(cr, pill_text, 12, px + 7, 128, MUTED, True, ls=0.04)
    elif view.pill_kind == "avg":
        # “近期平均”：不填底色，琥珀色描边 + 琥珀色文字，和实心的“精确”区分开
        _rrect(cr, px + 0.5, 119.5, w_pill - 1, 17, 8.5)
        cr.set_line_width(1)
        cr.set_source_rgba(*AMBER, 0.5)
        cr.stroke()
        _text(cr, pill_text, 12, px + 7, 128, AMBER, True, ls=0.04)
    else:
        _rrect(cr, px, 119, w_pill, 18, 9)
        cr.set_source_rgba(*PILL_BG, PILL_BG_ALPHA)
        cr.fill()
        _text(cr, pill_text, 12, px + 7, 128, PILL_TEXT, True, ls=0.04)


def _big(cr, view, frame):
    """主数字：整数部分 + 小数部分，基线对齐，整体水平居中。"""
    size = {"normal": 96, "four": 76, "cost": 68}.get(view.big_size, 96)
    color = TEXT_2 if view.muted else TEXT
    if view.big_whole:
        # 小数部分和整数部分同字号、同字距，紧接着排
        segs = [(t, size, True, color, -0.035)
                for t in (frame.big_int, frame.big_dec) if t]
        _draw_line(cr, segs, 166, 185, "center", "baseline")
    else:
        segs = [(frame.big_int, size, True, color, -0.035)]
        if frame.big_dec:
            segs.append((frame.big_dec, 40, True, color, -0.01))
        _draw_line(cr, segs, 166, 185, "center", "baseline", gap=1)


def _bar(cr, view, frame):
    """主数字下面那块：上下文条 / 预填充进度条 / 一行说明。"""
    bar = view.bar
    if bar.kind in ("ctx", "prog"):
        _rrect(cr, 106, 245, 120, 6, 3)
        cr.set_source_rgb(*TRACK)
        cr.fill()
        if bar.kind == "prog":
            color = AMBER
        elif bar.level == "full":
            color = DANGER
        elif bar.level == "warn":
            color = AMBER
        else:
            color = TEXT_2
        _rrect(cr, 106, 245, min(max(6, 120 * _clamp01(frame.bar_frac)), 120),
               6, 3)
        cr.set_source_rgb(*color)
        cr.fill()
        y = 263
    elif bar.kind == "note":
        y = 247
    else:
        return
    if bar.text:
        segs = [(seg.text, 12) + _style(seg.style, MUTED) + (0.0,)
                for seg in bar.text]
        _draw_line(cr, segs, 166, y, "center")


def _center(cr, view, frame):
    """仪表盘中间那块。"""
    if view.state == "offline":
        _text(cr, "引擎离线", 28, 166, 166, TEXT_2, True, "center")
        _text(cr, "等待引擎响应…", 13, 166, 199, MUTED, False, "center")
        return
    if view.cap or view.unit:
        _cap_line(cr, view)
    if frame.big_int or frame.big_dec:
        _big(cr, view, frame)
    if view.bar is not None:
        _bar(cr, view, frame)


# ---------------------------------------------------------------- 右侧三栏

def _card(cr, view, card, y0):
    """一张卡片：圆角矩形 + 内侧描边，里面最多三行文字，整体垂直居中。"""
    _rrect(cr, 336, y0, 132, 85.33, 14)
    cr.set_source_rgb(*CARD)
    cr.fill()
    _rrect(cr, 336.5, y0 + 0.5, 131, 84.33, 13.5)
    cr.set_line_width(1)
    cr.set_source_rgb(*CARD_LINE)
    cr.stroke()
    if not (card.label or card.value or card.foot):
        return
    h_val = 34 if not card.unit else 41.4
    top = y0 + (85.33 - (16 + h_val + (16 if card.foot else 0))) / 2
    if card.label:
        _text(cr, card.label, 13, 349, top + 8, MUTED)
    if card.value:
        if card.pending:
            color = FAINT
        elif view.muted or view.state == "offline":
            color = TEXT_2
        else:
            color = TEXT
        segs = [(card.value, 30, True, color, -0.02)]
        if card.unit:
            segs.append((card.unit, 13, True, MUTED, 0.0))
        _draw_line(cr, segs, 349, top + 16 + 17, "left", "baseline", gap=4)
    if card.foot:
        _text(cr, card.foot, 13, 349, top + 16 + h_val + 8, MUTED)


def _cards(cr, view, frame):
    """右侧三栏。"""
    for i, card in enumerate(view.cards[:3]):
        _card(cr, view, card, 40 + 91.33 * i)


# ---------------------------------------------------------------- 入口

def draw(cr, view, frame, width=960, height=640):
    """画一帧。开头 cr.save() + cr.scale()，结尾 cr.restore()。"""
    cr.save()
    cr.scale(width / 480, height / 320)
    cr.rectangle(0, 0, 480, 320)
    cr.set_source_rgb(*BG)
    cr.fill()
    _block(cr, frame.strip_alpha, _strip, view, frame)
    _dial(cr, view, frame)
    _block(cr, frame.ticks_alpha, _ticks, view, frame)
    _block(cr, frame.center_alpha, _center, view, frame)
    _block(cr, frame.stats_alpha, _cards, view, frame)
    if frame.dim < 1:
        cr.rectangle(0, 0, 480, 320)
        cr.set_source_rgba(0, 0, 0, 1 - frame.dim)
        cr.fill()
    cr.restore()


def render_png(view, path, frame=None):
    """把一帧画到内存图片上，写成 PNG（960×640）。"""
    if frame is None:
        frame = Animator.settled(view)
    surface = cairo.ImageSurface(cairo.FORMAT_RGB24, 960, 640)
    cr = cairo.Context(surface)
    draw(cr, view, frame, 960, 640)
    surface.flush()
    surface.write_to_png(str(path))
