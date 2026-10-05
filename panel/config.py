"""配置：读取可选的 JSON 配置文件，缺失或非法时用默认值。"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, fields
from typing import Any


@dataclass
class Config:
    base_url: str = "http://127.0.0.1:8888"
    monitor_match: str = "manufacturer"     # "manufacturer" 或 "connector"
    monitor_value: str = "DRS"
    round_gap_s: float = 60.0               # 一轮间隔
    prefill_short_s: float = 3.0            # 短预填充阈值
    done_hold_s: float = 4.0                # 完成画面停留
    dim_after_s: float = 1800.0             # 空闲多久后调暗
    anim_fps: float = 10.0                  # 持续动画（解码、预填充期间）的帧率；切换画面的淡入固定 30
    timezone: str = "America/Los_Angeles"
    price_input: float = 0.15               # 每百万 token
    price_cached: float = 0.016
    price_output: float = 0.47
    currency: str = "$"
    state_dir: str = "~/.local/state/tfpanel"
    model_name: str = "Qwen3.8-Flash-Next"  # 读不到模型名时用


def _coerce(default: Any, value: Any) -> Any:
    """类型对得上就采用，对不上就放弃这个键（bool 不算数字）。"""
    if isinstance(default, bool):
        return value if isinstance(value, bool) else default
    if isinstance(default, float):
        if isinstance(value, bool):
            return default
        return value if isinstance(value, (int, float)) else default
    if isinstance(default, str):
        return value if isinstance(value, str) else default
    return value


def load_config(path: str | None = None) -> Config:
    """读取配置。文件不存在、不是合法 JSON、不是对象：返回全默认值。"""
    if path is None:
        path = os.path.expanduser("~/.config/tfpanel/config.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return Config()
    if not isinstance(data, dict):
        return Config()
    defaults = Config()
    kwargs: dict[str, Any] = {}
    for f in fields(Config):
        if f.name in data:
            kwargs[f.name] = _coerce(getattr(defaults, f.name), data[f.name])
    return Config(**kwargs)
