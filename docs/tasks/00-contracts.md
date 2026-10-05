# 接口约定（所有任务共用）

本文规定各模块之间交接的数据结构和函数签名。每份任务说明都以本文为准：名字、字段、参数**一字不差**。
本文没写到的内部实现由执行者自己定。和 `docs/design.md` 冲突时以本文为准。

## 1. 模块和依赖

| 文件 | 内容 | 能用什么 | 依赖 |
| --- | --- | --- | --- |
| `panel/__init__.py` | 只有 `__version__ = "2.0.0"` | 标准库 | — |
| `panel/config.py` | 配置 | 标准库 | — |
| `panel/fmt.py` | 数字、时间的显示格式 | 标准库 | — |
| `panel/scale.py` | 仪表盘两套刻度、数值 → 圆弧位置 | 标准库 | — |
| `panel/view.py` | 视图数据结构 `View`（视图模型 → 绘制） | 标准库 | — |
| `panel/sources.py` | 读取：`/health`、`/metrics`、`/proc/meminfo` | 标准库 | — |
| `panel/usage.py` | 今日用量 | 标准库 | config |
| `panel/collector.py` | 采集：原始读数 → 指标快照 | 标准库 | config、usage |
| `panel/viewmodel.py` | 视图模型：指标快照 → `View` | 标准库 | config、fmt、scale、view |
| `panel/anim.py` | 动画：`View` → 每一帧的 `Frame` | 标准库 | view、scale |
| `panel/render.py` | 绘制：`View` + `Frame` → cairo | cairo、Pango（`gi`） | view、anim、scale |
| `panel/app.py`、`panel/__main__.py` | 窗口、找屏、轮询 | GTK 4（`gi`） | 全部 |

- 包内互相引用用 `from panel import fmt` 这种绝对写法。
- 测试在 `panel/tests/test_<模块>.py`，从仓库根目录运行：`python3 -m unittest panel.tests.test_<模块> -v`。
- 所有“时刻”参数 `now` 都是单调时钟的秒数（`time.monotonic()`），测试里直接传假数字，不 sleep。
- JS 的 `Math.round(x)` 在 Python 里写 `math.floor(x + 0.5)`（不要用内置 `round`，它是四舍六入五成双）。

## 2. 配置（`panel/config.py`）

```python
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

def load_config(path: str | None = None) -> Config
```

- `path` 为 `None` 时读 `~/.config/tfpanel/config.json`。文件不存在、不是合法 JSON、不是对象：返回全默认值。
- JSON 的键就是字段名。不认识的键忽略；类型不对的值（例如该是数字却给了字符串）忽略、用默认值；整数可以赋给 float 字段；`bool` 不算数字。

## 3. 格式（`panel/fmt.py`）与刻度（`panel/scale.py`）

`panel/fmt.py`（行为和原型 `docs/dashboard-prototype.html` 里同名的 JS 函数一致）：

| 函数 | 行为 |
| --- | --- |
| `js_round(x: float) -> int` | `math.floor(x + 0.5)` |
| `tok_fmt(n) -> str` | 先 `js_round`。`< 1000` 原值；`< 99950` 一位小数加 `K`（`6.2K`、`6.0K`）；`< 999500` 整数加 `K`（`262K`）；`< 9995000` 两位小数加 `M`（`8.26M`）；其余一位小数加 `M` |
| `split1(x) -> tuple[str, str]` | 一位小数拆成整数部分和小数部分：`62.3 → ("62", ".3")` |
| `cost_fmt(c, currency="$") -> str` | `c >= 100` 时 `"$123"`（`js_round`），否则 `"$0.60"`（两位小数） |
| `dur_fmt(sec) -> str` | 向下取整：`"46 秒"`、`"2 分钟"`、`"3 小时"`（数字和单位之间一个空格；`< 60` 秒、`< 3600` 分钟） |
| `date_label(date: str) -> str` | `"2026-10-03" → "10月3日"`；解析失败返回 `"今日"` |
| `pct(part, whole) -> int` | `whole` 为 0 或 `None` 时 0，否则 `js_round(part / whole * 100)` |

`panel/scale.py`：

```python
TICK_FRACS = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)
SCALES = {
    "decode":  {"ticks": (0, 25, 50, 100, 200, 300),       "labels": ("0", "25", "50", "100", "200", "300")},
    "prefill": {"ticks": (0, 600, 1200, 1800, 2400, 3000), "labels": ("0", "600", "1.2K", "1.8K", "2.4K", "3K")},
}
def v2f(v: float | None, scale: str) -> float   # 数值 → 圆弧位置 0–1，分段线性；None、≤ 0 返回 0，≥ 最大刻度返回 1
```

## 4. 读取（`panel/sources.py`）的输出

| 函数 | 返回 |
| --- | --- |
| `parse_health(data: bytes \| str) -> dict \| None` | `/health` 的 JSON 对象原样返回；不是合法 JSON、不是对象、或 `ok` 不为真：`None` |
| `parse_metrics(text: str) -> dict` | `{"waiting": int \| None, "kv_usage": list[float], "ttft_sum": float \| None, "ttft_count": int \| None}` |
| `parse_meminfo(text: str) -> dict \| None` | `{"used_gb": float, "total_gb": float}`，`GB = kB ÷ 1048576`，已用 = `MemTotal − MemAvailable`；缺行返回 `None` |

`/metrics` 里用到的行（Prometheus 文本格式）：

```text
tensorfold:requests_waiting 0
tensorfold:kv_cache_usage_ratio{pool="0"} 0.093899
tensorfold:kv_cache_usage_ratio{pool="1"} 0
tensorfold:time_to_first_token_seconds_sum 1599.727361
tensorfold:time_to_first_token_seconds_count 156
```

`kv_usage` 是各个 pool 的比值，按 pool 编号从小到大排。

## 5. 今日用量（`panel/usage.py`）

```python
class UsageLedger:
    def __init__(self, config: Config, clock=time.time, state_dir: str | None = None, save_interval_s: float = 10.0)
    def update(self, totals: dict) -> None      # 每次读到 /health 调一次
    def today(self) -> dict                     # 快照里的 today
    def flush(self) -> None                     # 有没写的变化就立刻写文件
```

- `totals` = `{"prompt": int, "cached": int, "completion": int, "requests": int}`，分别来自 `/health` 的 `prompt_tokens_total`、`cached_tokens_total`、`completion_tokens_total`、`requests_total`。
- `today()` = `{"date": "2026-10-03", "prompt_tokens": int, "cached_tokens": int, "completion_tokens": int, "requests": int, "cost": float}`。
- `clock` 返回 Unix 时间戳（秒），“今日”按 `config.timezone` 划分。

## 6. 采集（`panel/collector.py`）

```python
class Collector:
    def __init__(self, config: Config, usage=None)
    def feed(self, now: float, health: dict | None, metrics: dict | None = None,
             memory: dict | None = None, model: str | None = None) -> dict
```

- 每读一次 `/health` 调一次 `feed`。`health` 是 `parse_health` 的结果（读不到传 `None`）；`metrics`、`memory` 是这一次顺带读到的 `parse_metrics`、`parse_meminfo` 结果，这一次没读就传 `None`（采集器沿用上一次的）；`model` 是读到的模型名，没读传 `None`。
- `usage` 是 `UsageLedger` 或任何有 `update(totals)`、`today()` 的对象；为 `None` 时快照的 `today` 全为 0、`date` 为空串。
- 返回值是 `docs/design.md`“指标快照”一节的字典（`version` 为 2），字段齐全，可以直接 `json.dumps`。

## 7. 视图（`panel/view.py`）

视图模型把快照变成“画面上每个位置写什么字、圆弧是什么样”，绘制只管照着画。

```python
@dataclass
class Seg:                       # 一段文字
    text: str
    style: str = "normal"        # "normal" 普通 | "strong" 加粗提亮（原型里的 <b>）| "warn" 琥珀色加粗

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
    kind: str = "ctx"            # "ctx" 上下文条 | "prog" 预填充进度条 | "note" 只有一行字、没有条
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
    unit: str = ""               # 标题后的单位，如“tok/s”；显示为“标题 · 单位”
    pill: bool = False           # “精确”标记
    big_int: str = ""            # 主数字的整数部分（含货币符号）
    big_dec: str = ""            # 主数字的小数部分（含小数点），可为空
    big_whole: bool = False      # True：小数部分和整数部分同字号；False：小数部分用小字号
    big_size: str = "normal"     # "normal" 96 | "four" 76 | "cost" 68
    big_value: float | None = None   # 主数字是实时解码速度时填数值（动画用它缓动），其余为 None
    arc: str = "blank"           # "value" 薄荷绿数值弧 | "prefill" 琥珀色数值弧 | "rest" 灰色小点 | "blank" 只有暗底环 | "off" 离线
    scale: str = "decode"        # "decode" | "prefill"
    arc_target: float | None = None  # 圆弧目标位置 0–1；blank、off 时为 None
    ghost: float | None = None   # arc 为 rest 时灰色小点的位置 0–1；没有则 None
    muted: bool = False          # 灰色画面（主数字和右侧数值变灰）
    bar: Bar | None = None
    cards: list[Card] = field(default_factory=list)   # 恰好 3 个
    dim: float = 1.0             # 整屏亮度，长时间空闲时 0.4
    slow_fade: bool = False      # 这次切换用 0.8 秒慢淡入（完成 → 空闲）

    def to_dict(self) -> dict            # dataclasses.asdict
    @classmethod
    def from_dict(cls, d: dict) -> "View"    # to_dict 的逆运算；缺的键用默认值
```

## 8. 动画帧（`panel/anim.py`）

```python
@dataclass
class Frame:
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
    animating: bool = False      # 还有动画没走完（窗口据此决定要不要继续每秒 30 帧）

class Animator:
    def step(self, view: View, now: float) -> Frame
    @staticmethod
    def settled(view: View) -> Frame     # 所有动画都走完时的那一帧（离屏截图用）
```

## 9. 绘制（`panel/render.py`）

```python
def draw(cr, view: View, frame: Frame, width: int = 960, height: int = 640) -> None
def render_png(view: View, path: str, frame: Frame | None = None) -> None   # frame 为 None 时用 Animator.settled(view)
```

`draw` 自己把坐标放大（`width / 480`），里面全部按 480×320 画。
