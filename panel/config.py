"""配置：读取可选的 JSON 配置文件，缺失或非法时用默认值。"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field, fields
from typing import Any


@dataclass
class Config:
    base_url: str = ""                    # 非空时只用这一个地址（兼容旧配置）
    base_urls: list[str] = field(default_factory=lambda: ["http://127.0.0.1:8888", "http://127.0.0.1:8000"])  # 按顺序试，用第一个认得出引擎的
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

    def urls(self) -> list[str]:
        """要试的接口地址：base_url 非空只用它，否则用 base_urls 的一份拷贝。"""
        if self.base_url:
            return [self.base_url]
        return list(self.base_urls)


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
    if isinstance(default, list):
        # 列表：非空、每一项都是非空字符串才采用，采用时拷贝一份
        if isinstance(value, list) and value and all(isinstance(v, str) and v for v in value):
            return list(value)
        return default
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
