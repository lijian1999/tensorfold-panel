"""数字、时间的显示格式，行为与原型里的 JS 函数一致。"""

from __future__ import annotations

import math


def js_round(x: float) -> int:
    """JS 的 Math.round：0.5 向上取整。"""
    return math.floor(x + 0.5)


def tok_fmt(n) -> str:
    """token 数：先取整，再按量级换成 K / M。"""
    n = js_round(n)
    if n < 1000:
        return str(n)
    if n < 99950:
        return f"{n / 1000:.1f}K"
    if n < 999500:
        return f"{js_round(n / 1000)}K"
    if n < 9995000:
        return f"{n / 1e6:.2f}M"
    return f"{n / 1e6:.1f}M"


def split1(x) -> tuple[str, str]:
    """一位小数拆成整数部分和小数部分，小数部分带小数点。"""
    s = f"{x:.1f}"
    i = s.index(".")
    return s[:i], s[i:]


def cost_fmt(c, currency: str = "$") -> str:
    """费用：100 以上不带小数，其余两位小数。"""
    if c >= 100:
        return f"{currency}{js_round(c)}"
    return f"{currency}{c:.2f}"


def dur_fmt(sec) -> str:
    """时长：秒 / 分钟 / 小时，向下取整。"""
    x = max(0, math.floor(sec))
    if x < 60:
        return f"{x} 秒"
    if x < 3600:
        return f"{x // 60} 分钟"
    return f"{x // 3600} 小时"


def date_label(date: str) -> str:
    """"2026-10-03" → "10月3日"；解析不了就写“今日”。"""
    try:
        year, month, day = date.split("-")
        return f"{int(month)}月{int(day)}日"
    except ValueError:
        return "今日"


def pct(part, whole) -> int:
    """百分比取整；总数为 0 或缺失时为 0。"""
    if not whole:
        return 0
    return js_round(part / whole * 100)
