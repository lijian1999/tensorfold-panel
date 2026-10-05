"""动画：视图模型 → 每一帧的数值。只算数，不读时钟、不做 I/O。

对应原型 dashboard-prototype.html 里的三处：
- CSS 的 transition（圆弧位置 0.4 秒缓动、不透明度 0.6 秒线性、整屏亮度 0.3/秒）
- @keyframes pulse（流指示点 1.4 秒 / 1 秒的余弦脉冲）
- @keyframes swapin 和 frame() 里的"缓动"那一段（主数字 0.25 秒刷一次、三块 0.32 秒淡入）
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from panel.fmt import js_round

# 时间常数与速度，和原型一致
TAU = 0.4                  # 圆弧位置 / 主数字的缓动时间常数（秒）
MIX_RATE = 1 / 0.4         # 圆弧颜色：0.4 秒走完全程（每秒 2.5）
ALPHA_RATE = 1 / 0.6       # 五个不透明度：0.6 秒走完全程
FADE_FAST = 0.32           # 普通淡入时长（秒）
FADE_SLOW = 0.8            # 慢淡入时长：完成 → 空闲
MAX_DT = 0.1               # 一帧最多推进多久，隔太久没画也不许一步跳到目标
DIM_RATE = 0.3             # 整屏变暗的速度：每秒 0.3
PULSE_DEC = 1.4            # 解码脉冲周期（秒）
PULSE_PRE = 1.0            # 预填充脉冲周期（秒）
ALPHA_FLOOR = 0.15         # 淡入起始不透明度
EPS = 1e-9                 # 视为"已经到目标"的误差
_MISSING = object()        # 键的"没有上一次"哨兵


@dataclass
class Frame:
    """画一帧需要的全部数值。"""

    arc_frac: float = 0.0        # 数值弧当前位置 0–1
    arc_mix: float = 0.0         # 数值弧颜色：0 薄荷绿，1 琥珀色
    value_alpha: float = 0.0     # 数值弧
    ghost_alpha: float = 0.0     # 灰色小点
    ticks_alpha: float = 0.0     # 刻度数字（已乘上切换刻度时的淡入）
    track_alpha: float = 0.5     # 底环
    notch_alpha: float = 0.0     # 底环上的刻度缺口
    big_int: str = ""            # 这一帧实际显示的主数字
    big_dec: str = ""
    bar_frac: float = 0.0        # 条的当前长度
    center_alpha: float = 1.0    # 中间区域淡入
    stats_alpha: float = 1.0     # 右侧三栏淡入
    strip_alpha: float = 1.0     # 状态条淡入
    pulse_dec: float = 1.0       # 解码中的流指示点的不透明度
    pulse_pre: float = 1.0       # 预填充中的流指示点的不透明度
    dim: float = 1.0             # 整屏亮度
    animating: bool = False      # 还有动画没走完（窗口据此决定要不要继续重画）


def _clamp(x: float) -> float:
    """夹到 0–1，和原型的 clamp01 一样。"""
    return 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)


def _linear(cur: float, target: float, stride: float) -> tuple[float, bool]:
    """线性走向目标。一步就能走完时直接等于目标。

    返回 (新值, 是否还没到目标)。
    """
    gap = target - cur
    if abs(gap) <= max(stride, EPS):
        return target, False
    return _clamp(cur + math.copysign(stride, gap)), True


def _alpha_targets(view) -> dict:
    """圆弧各部分不透明度的目标值，按 view.arc。"""
    if view.arc in ("value", "prefill"):
        return {"value": 1.0, "ghost": 0.0, "ticks": 1.0, "track": 1.0, "notch": 1.0}
    if view.arc == "rest":
        # 灰色小点：有位置才画，0.9 是原型里 --ghost 的不透明度
        return {"value": 0.0, "ghost": 0.9 if view.ghost is not None else 0.0,
                "ticks": 0.75, "track": 1.0, "notch": 1.0}
    # blank / off：只剩暗底环
    return {"value": 0.0, "ghost": 0.0, "ticks": 0.0, "track": 0.5, "notch": 0.0}


def _pulse(now: float, period: float) -> float:
    """流指示点的脉冲，等价于 @keyframes pulse：1 → 0.35 → 1。"""
    return _clamp(0.675 + 0.325 * math.cos(2 * math.pi * now / period))


class _Fade:
    """一次淡入：什么时候开始、走多久、是不是慢淡入。"""

    __slots__ = ("start", "duration", "slow")

    def __init__(self, start: float, duration: float, slow: bool) -> None:
        self.start = start
        self.duration = duration
        self.slow = slow

    def running(self, now: float) -> bool:
        """这一刻还在淡入途中吗。"""
        return (now - self.start) < self.duration

    def alpha(self, now: float) -> float:
        """淡入进行到 e 秒时的不透明度；键变化的那一帧是 0.15。"""
        e = now - self.start
        if e >= self.duration:
            return 1.0
        p = min(1.0, max(0.0, e / self.duration))
        if self.slow:
            return ALPHA_FLOOR + 0.85 * (p * p * (3 - 2 * p))   # ease-in-out
        return ALPHA_FLOOR + 0.85 * (1 - (1 - p) ** 2)          # ease-out


class Animator:
    """把一串 View 变成一串 Frame。每个画面用一个 Animator；step 不读时钟。"""

    def __init__(self) -> None:
        self._now: float | None = None            # 上一次调用的时刻，None = 第一次
        self._arc_frac: float = 0.0
        self._arc_mix: float = 0.0
        self._alphas: dict[str, float] = {}       # 五个不透明度的当前值（value/ghost/ticks/track/notch）
        self._ticks_fade: _Fade | None = None
        self._scale: str | None = None
        self._display: float | None = None        # 缓动中的解码速度，None = 上一帧不是实时数字
        self._big_at: float = 0.0                 # 上次刷新主数字文字的时刻
        self._big: str = ""                       # 上一帧显示的主数字文字
        self._bar_frac: float = 0.0
        self._bar_kind: str | None = None
        self._dim: float = 1.0
        self._fades: dict[str, _Fade | None] = {}
        self._keys: dict[str, object] = {}

    @staticmethod
    def settled(view) -> Frame:
        """所有动画都走完时的那一帧（静止画面、离屏截图用）。"""
        targets = _alpha_targets(view)
        bar = view.bar
        return Frame(
            arc_frac=_clamp(view.arc_target) if view.arc_target is not None else 0.0,
            arc_mix=1.0 if view.arc == "prefill" else 0.0,
            value_alpha=targets["value"],
            ghost_alpha=targets["ghost"],
            ticks_alpha=targets["ticks"],
            track_alpha=targets["track"],
            notch_alpha=targets["notch"],
            big_int=view.big_int,
            big_dec=view.big_dec,
            bar_frac=_clamp(bar.frac) if bar is not None else 0.0,
            center_alpha=1.0,
            stats_alpha=1.0,
            strip_alpha=1.0,
            pulse_dec=1.0,
            pulse_pre=1.0,
            dim=_clamp(view.dim),
            animating=False,
        )

    def step(self, view, now: float) -> Frame:
        """算 now 这一帧。第一次调用给出动画已经走完的那一帧。"""
        first = self._now is None
        dt = 0.0 if first else min(MAX_DT, max(0.0, now - self._now))
        self._now = now
        k = 1.0 - math.exp(-dt / TAU) if dt > 0 else 0.0

        # 1) 圆弧位置：指数缓动；没有目标就停在原地
        if first:
            arc_frac = 0.0 if view.arc_target is None else _clamp(view.arc_target)
            arc_done = True
        elif view.arc_target is None:
            arc_frac = self._arc_frac
            arc_done = True
        elif abs(view.arc_target - self._arc_frac) < 0.0005:
            arc_frac = _clamp(view.arc_target)
            arc_done = True
        else:
            arc_frac = self._arc_frac + (view.arc_target - self._arc_frac) * k
            arc_done = False
        self._arc_frac = _clamp(arc_frac)

        # 2) 圆弧颜色：prefill 是琥珀色，其余回到薄荷绿
        mix_target = 1.0 if view.arc == "prefill" else 0.0
        if first:
            arc_mix = mix_target
            mix_done = True
        else:
            arc_mix, mix_moving = _linear(self._arc_mix, mix_target, dt * MIX_RATE)
            arc_mix = _clamp(arc_mix)
            mix_done = not mix_moving
        self._arc_mix = arc_mix

        # 3) 五个不透明度：0.6 秒走完全程
        targets = _alpha_targets(view)
        alpha = {}
        alpha_done = True
        for key, tgt in targets.items():
            value, moving = _linear(self._alphas.get(key, tgt), tgt, dt * ALPHA_RATE)
            alpha[key] = _clamp(value)
            alpha_done = alpha_done and not moving

        # 4) 切换刻度时淡入一次，结果再乘上第 3 条算出的不透明度
        if first:
            ticks_fade = None
        elif view.scale != self._scale:
            ticks_fade = _Fade(now, FADE_FAST, False)
        else:
            ticks_fade = self._ticks_fade
        ticks_moving = ticks_fade is not None and ticks_fade.running(now)
        ticks_factor = 1.0 if ticks_fade is None else ticks_fade.alpha(now)
        ticks_alpha = _clamp(alpha["ticks"] * ticks_factor)

        # 5) 主数字
        if view.big_value is None:
            big_int, big_dec = view.big_int, view.big_dec
            self._display = None
            big_moving = False
        else:
            jump = first or self._display is None      # 上一帧不是实时数字
            if jump:
                self._display = float(view.big_value)   # 直接取新值，立刻刷新显示
            else:
                gap = view.big_value - self._display
                if abs(gap) < 0.02:
                    self._display = float(view.big_value)
                else:
                    self._display += gap * k
            shown = str(js_round(self._display))
            if jump or now - self._big_at >= 0.25:
                big_int = shown
                self._big_at = now                      # 每 0.25 秒最多刷新一次
            else:
                big_int = self._big or shown
            big_dec = ""
            big_moving = abs(view.big_value - self._display) >= 0.02 or big_int != shown
        self._big = big_int

        # 6) 三块淡入：内容标签（键）变了才淡入，第一次调用不淡入
        keys = {
            "center": (view.cap, view.unit, view.big_whole, view.muted,
                       view.state == "offline"),
            "stats": tuple(card.label for card in view.cards),
            "strip": view.state_name,
        }
        fades = {}
        for part, key in keys.items():
            if first:
                fades[part] = None
            elif self._keys.get(part, _MISSING) != key:
                # 键变了就从头淡入；slow_fade 为真时用 0.8 秒慢淡入
                fades[part] = _Fade(now, FADE_SLOW if view.slow_fade else FADE_FAST,
                                    bool(view.slow_fade))
            else:
                fades[part] = self._fades.get(part)
        fade_moving = any(f is not None and f.running(now) for f in fades.values())
        center_fade = fades.get("center")
        stats_fade = fades.get("stats")
        strip_fade = fades.get("strip")
        center_alpha = 1.0 if center_fade is None else center_fade.alpha(now)
        stats_alpha = 1.0 if stats_fade is None else stats_fade.alpha(now)
        strip_alpha = 1.0 if strip_fade is None else strip_fade.alpha(now)

        # 7) 条的长度
        if view.bar is None:
            bar_frac = 0.0
            self._bar_kind = None
            bar_done = True
        elif first or view.bar.kind != self._bar_kind:
            # 上一帧没有条，或者换了一种条：直接等于新的长度
            bar_frac = _clamp(view.bar.frac)
            self._bar_kind = view.bar.kind
            bar_done = True
        else:
            tgt = _clamp(view.bar.frac)
            gap = tgt - self._bar_frac
            if abs(gap) < 0.001:
                bar_frac = tgt
            else:
                bar_frac = self._bar_frac + gap * k
            bar_done = bar_frac == tgt
        self._bar_frac = bar_frac

        # 8) 流指示点的脉冲；离线时只画一个红点，不参与脉冲
        lanes = view.lanes
        if lanes.offline:
            pulse_dec = pulse_pre = 1.0
            pulse_moving = False
        else:
            pulse_dec = _pulse(now, PULSE_DEC) if lanes.decoding else 1.0
            pulse_pre = _pulse(now, PULSE_PRE) if lanes.prefilling else 1.0
            pulse_moving = bool(lanes.decoding) or bool(lanes.prefilling)

        # 9) 整屏亮度：变暗慢慢来（每秒 0.3），变亮立刻回
        dim_target = _clamp(view.dim)
        if first or self._dim <= dim_target + EPS:
            dim = dim_target
            dim_done = True
        else:
            dim = max(dim_target, self._dim - DIM_RATE * dt)
            dim_done = dim == dim_target
        self._dim = dim

        # 10) 还有没走完的动画就一直重画
        animating = (
            not (arc_done and mix_done and alpha_done and bar_done and dim_done)
            or ticks_moving or fade_moving or big_moving or pulse_moving
        )

        frame = Frame(
            arc_frac=arc_frac,
            arc_mix=arc_mix,
            value_alpha=alpha["value"],
            ghost_alpha=alpha["ghost"],
            ticks_alpha=ticks_alpha,
            track_alpha=alpha["track"],
            notch_alpha=alpha["notch"],
            big_int=big_int,
            big_dec=big_dec,
            bar_frac=bar_frac,
            center_alpha=center_alpha,
            stats_alpha=stats_alpha,
            strip_alpha=strip_alpha,
            pulse_dec=pulse_dec,
            pulse_pre=pulse_pre,
            dim=dim,
            animating=animating,
        )

        # 记下这一帧的状态，供下一帧接着算
        self._alphas = alpha
        self._ticks_fade = ticks_fade
        self._scale = view.scale
        self._fades = fades
        self._keys = keys
        return frame
