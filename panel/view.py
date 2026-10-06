"""视图数据结构：视图模型 → 绘制。只描述画面上写什么，不做计算。"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field


@dataclass
class Seg:                       # 一段文字
    text: str
    style: str = "normal"        # "normal" 普通 | "strong" 加粗提亮 | "warn" 琥珀色加粗


@dataclass
class Lanes:                     # 流指示点
    max: int = 5
    decoding: int = 0
    prefilling: int = 0
    waiting: int = 0
    offline: bool = False        # True 时只画一个红点


@dataclass
class Card:                      # 右侧一栏
    label: str = ""
    value: str = ""
    unit: str = ""
    foot: str = ""
    pending: bool = False        # True 时数值用暗色（“—”）


@dataclass
class Bar:                       # 主数字下方那一块
    kind: str = "ctx"          # "ctx" 上下文条 | "prog" 预填充进度条 | "note" 只有一行字、没有条
    frac: float = 0.0            # 条的长度 0–1
    level: str = "normal"        # 只对 ctx 有意义："normal" 灰 | "warn" 琥珀（≥ 80%）| "full" 红（≥ 95%）
    text: list[Seg] = field(default_factory=list)


@dataclass
class View:
    state: str = "idle"          # offline | idle | prefill | decode | done
    state_name: str = "空闲"      # 状态条上的状态名
    strip_left: str = ""         # 状态名后面的模型名，可为空
    strip_right: list[Seg] = field(default_factory=list)
    lanes: Lanes = field(default_factory=Lanes)
    cap: str = ""                # 仪表盘标题，如“解码速度”
    unit: str = ""               # 标题后的单位，如“tok/s”
    pill: bool = False           # “精确”标记
    pill_kind: str = "exact"     # pill 为 True 时画哪一种标记："exact" 实心的“精确” | "avg" 琥珀色描边的“近期平均”
    big_int: str = ""            # 主数字的整数部分（含货币符号）
    big_dec: str = ""            # 主数字的小数部分（含小数点），可为空
    big_whole: bool = False      # True：小数部分和整数部分同字号
    big_size: str = "normal"     # "normal" 96 | "four" 76 | "cost" 68
    big_value: float | None = None   # 主数字是实时解码速度时填数值，其余为 None
    arc: str = "blank"           # "value" | "prefill" | "rest" | "blank" | "off"
    scale: str = "decode"        # "decode" | "prefill"
    arc_target: float | None = None  # 圆弧目标位置 0–1；blank、off 时为 None
    ghost: float | None = None   # arc 为 rest 时灰色小点的位置 0–1；没有则 None
    muted: bool = False          # 灰色画面
    bar: Bar | None = None
    cards: list[Card] = field(default_factory=list)   # 恰好 3 个
    dim: float = 1.0             # 整屏亮度，长时间空闲时 0.4
    slow_fade: bool = False      # 这次切换用 0.8 秒慢淡入（完成 → 空闲）

    def to_dict(self) -> dict:
        """转成普通字典，嵌套的数据类也一并转。"""
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "View":
        """to_dict 的逆运算：缺的键用默认值，多出来的键忽略。"""
        d = d or {}
        return cls(
            state=d.get("state", "idle"),
            state_name=d.get("state_name", "空闲"),
            strip_left=d.get("strip_left", ""),
            strip_right=[_seg(s) for s in d.get("strip_right", []) if isinstance(s, (dict, Seg))],
            lanes=_lane(d.get("lanes")),
            cap=d.get("cap", ""),
            unit=d.get("unit", ""),
            pill=d.get("pill", False),
            pill_kind=d.get("pill_kind", "exact"),
            big_int=d.get("big_int", ""),
            big_dec=d.get("big_dec", ""),
            big_whole=d.get("big_whole", False),
            big_size=d.get("big_size", "normal"),
            big_value=d.get("big_value"),
            arc=d.get("arc", "blank"),
            scale=d.get("scale", "decode"),
            arc_target=d.get("arc_target"),
            ghost=d.get("ghost"),
            muted=d.get("muted", False),
            bar=_bar(d.get("bar")),
            cards=[_card(c) for c in d.get("cards", []) if isinstance(c, (dict, Card))],
            dim=d.get("dim", 1.0),
            slow_fade=d.get("slow_fade", False),
        )


def _seg(d) -> Seg:
    """字典 → Seg；已经是 Seg 就原样返回。"""
    if isinstance(d, Seg):
        return d
    return Seg(text=d.get("text", ""), style=d.get("style", "normal"))


def _lane(d) -> Lanes:
    if isinstance(d, Lanes):
        return d
    if not isinstance(d, dict):
        return Lanes()
    return Lanes(
        max=d.get("max", 5),
        decoding=d.get("decoding", 0),
        prefilling=d.get("prefilling", 0),
        waiting=d.get("waiting", 0),
        offline=d.get("offline", False),
    )


def _bar(d) -> Bar | None:
    if d is None:
        return None
    if isinstance(d, Bar):
        return d
    if not isinstance(d, dict):
        return None
    return Bar(
        kind=d.get("kind", "ctx"),
        frac=d.get("frac", 0.0),
        level=d.get("level", "normal"),
        text=[_seg(s) for s in d.get("text", [])],
    )


def _card(d) -> Card:
    if isinstance(d, Card):
        return d
    if not isinstance(d, dict):
        return Card()
    return Card(
        label=d.get("label", ""),
        value=d.get("value", ""),
        unit=d.get("unit", ""),
        foot=d.get("foot", ""),
        pending=d.get("pending", False),
    )
