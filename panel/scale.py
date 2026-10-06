"""仪表盘两套刻度：数值 → 圆弧位置 0–1。"""

from __future__ import annotations

# 刻度位置（0–1）：5 段等分，左右对称
TICK_FRACS = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)

SCALES = {
    "decode": {"ticks": (0, 25, 50, 100, 200, 300), "labels": ("0", "25", "50", "100", "200", "300")},
    "prefill": {"ticks": (0, 600, 1200, 1800, 2400, 3000), "labels": ("0", "600", "1.2K", "1.8K", "2.4K", "3K")},
}


def v2f(v: float | None, scale: str) -> float:
    """数值 → 圆弧位置。None、≤ 0 返回 0，≥ 最大刻度返回 1。"""
    if v is None or not (v > 0):
        return 0.0
    ticks = SCALES[scale]["ticks"]
    if v >= ticks[-1]:
        return 1.0
    for i in range(1, len(ticks)):
        if v <= ticks[i]:
            f0 = TICK_FRACS[i - 1]
            f1 = TICK_FRACS[i]
            return f0 + (v - ticks[i - 1]) / (ticks[i] - ticks[i - 1]) * (f1 - f0)
    return 1.0
