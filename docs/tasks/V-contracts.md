# 接口约定 · 支持 vLLM（V 系列任务共用）

本文是 `docs/tasks/00-contracts.md` 的增补，规定 V 系列任务之间交接的数据结构和函数签名：名字、字段、参数**一字不差**。
本文没提到的接口照 `00-contracts.md`，现有行为不变。设计背景见 `docs/design-vllm.md`；两者不一致时以本文为准。

## 1. 配置（`panel/config.py`）

```python
@dataclass
class Config:
    base_url: str = ""                      # 非空时只用这一个地址（兼容旧配置）
    base_urls: list[str] = field(default_factory=lambda: ["http://127.0.0.1:8888", "http://127.0.0.1:8000"])
    …其余字段不变…

    def urls(self) -> list[str]             # base_url 非空返回 [base_url]，否则返回 base_urls 的一份拷贝
```

`base_urls` 在配置文件里必须是“非空列表，每一项都是非空字符串”，否则忽略、用默认值。

## 2. 读取（`panel/sources.py`）

```python
VLLM_FIELDS = ("running", "waiting", "queries", "hits", "prompt", "prompt_cached", "ttft_sum", "ttft_count",
               "generation", "success", "req_prompt_sum", "req_generation_sum", "req_computed_sum",
               "prefill_s", "decode_s", "drafted", "accepted", "epoch")

def parse_vllm_metrics(text: str) -> dict | None
```

把 vLLM 的 `/metrics` 文本变成一个字典，键恰好是 `VLLM_FIELDS`，顺序也照它。下面简称“vLLM 读数”。

| 键 | 指标名 | 类型 |
| --- | --- | --- |
| `running` | `vllm:num_requests_running` | int |
| `waiting` | `vllm:num_requests_waiting` | int |
| `queries` | `vllm:prefix_cache_queries_total` | int |
| `hits` | `vllm:prefix_cache_hits_total` | int |
| `prompt` | `vllm:prompt_tokens_total` | int |
| `prompt_cached` | `vllm:prompt_tokens_cached_total` | int |
| `ttft_sum` | `vllm:time_to_first_token_seconds_sum` | float |
| `ttft_count` | `vllm:time_to_first_token_seconds_count` | int |
| `generation` | `vllm:generation_tokens_total` | int |
| `success` | `vllm:request_success_total` | int |
| `req_prompt_sum` | `vllm:request_prompt_tokens_sum` | int |
| `req_generation_sum` | `vllm:request_generation_tokens_sum` | int |
| `req_computed_sum` | `vllm:request_prefill_kv_computed_tokens_sum` | int |
| `prefill_s` | `vllm:request_prefill_time_seconds_sum` | float |
| `decode_s` | `vllm:request_decode_time_seconds_sum` | float |
| `drafted` | `vllm:spec_decode_num_draft_tokens_total` | int |
| `accepted` | `vllm:spec_decode_num_accepted_tokens_total` | int |
| `epoch` | `process_start_time_seconds` | float 或 `None` |

- 一行的指标名是“第一个 `{` 或第一个空白之前的部分”，数值是“最后一段空白之后的部分”。指标名必须和表里的**完全相等**（`vllm:prompt_tokens_total` 不匹配 `vllm:prompt_tokens_cached_total`，也不匹配 `…_created`、`…_bucket`）。
- 同一个指标名有多行（标签不同）时把数值加起来。
- 文本里没有 `vllm:num_requests_running` 这个指标 → 返回 `None`。别的指标缺了：int 的按 `0`，float 的按 `0.0`，`epoch` 按 `None`。
- int 的键用 `int(float(数值))`。注释行、空行、读不懂的行忽略，永不抛异常；`text` 不是字符串返回 `None`。

`Fetcher` 加两个方法，现有方法的行为不变：

```python
def get_text(self, path: str) -> str | None      # GET 一个路径；200 返回正文（空正文返回 ""），其余情况返回 None
def model_info(self) -> dict | None              # 读 /v1/models → {"id": str, "max_model_len": int | None}；读不到或没有 id 返回 None
```

## 3. 统一读数

引擎适配层交给采集器的两样东西，格式就是 TensorFold 的 `/health`、`/metrics` 解析结果（`parse_health`、`parse_metrics` 的返回值），vLLM 多几个可选键。

vLLM 的 `health`（`m` 是 vLLM 读数）：

```python
{
    "ok": True,
    "backend": "vllm",
    "requests_running": m["running"],
    "streams": {"decoding": 解码行数, "prefilling": 预填充行数, "max": max(4, 引擎启动以来 running 的最大值)},
    "requests_total": m["success"],
    "completion_tokens_total": m["generation"],
    "prompt_tokens_total": m["req_prompt_sum"],
    "cached_tokens_total": m["req_prompt_sum"] - m["req_computed_sum"],
    "prefill_seconds_total": m["prefill_s"],
    "decode_seconds_total": m["decode_s"],
    "drafted_total": 锁存的 drafted,       # 只在“有请求结束”或“running 为 0”的那次读数更新
    "accepted_total": 锁存的 accepted,     # 同上
    "context_length": context_length,      # 调用方给了才有这个键
    "epoch": m["epoch"],
    "aborted_total": 中途断开的累计次数,
    "completion_finished_total": m["req_generation_sum"],
    "usage_totals": {"prompt": m["prompt"], "cached": m["prompt_cached"],
                     "completion": m["generation"], "requests": m["success"]},
    "tfpanel": {"v": 1, "streams": [行, …]},   # 只有流表里每一行的 prompt 都已知时才有这个键（空表也有）
}
```

vLLM 的 `metrics`：

```python
{"waiting": m["waiting"], "kv_usage": [], "ttft_sum": 已结束请求的首字时间之和, "ttft_count": 已结束且有首字时间的请求数}
```

流表的一行（`tfpanel.streams` 里的元素，恰好这 7 个键）：

```python
{"id": 7, "phase": "prefill" 或 "decode", "prompt": 39884, "cached": 0, "output": 0, "start": 1234.5, "ttft_s": None}
```

`id` 是适配器从 1 开始编的序号；`start` 是这条流的开始时刻（和 `feed` 的 `now` 同一个时钟）；`ttft_s` 出首字后才有数。和 TensorFold 外挂行相比没有 `filled`。提示未知的行 `prompt` 是 `None`（这种行不会出现在 `tfpanel` 里，因为这时整个 `tfpanel` 键都不给）。

## 4. 引擎适配（`panel/engine.py`，新文件，只用标准库）

```python
class VllmAdapter:
    def __init__(self) -> None
    def reset(self) -> None                          # 清空流表和所有记忆，回到刚建好的样子
    def feed(self, now: float, m: dict, prefill_tps: float | None = None,
             context_length: int | None = None) -> tuple[dict, dict]     # 返回第 3 节的 (health, metrics)
    def rows(self) -> list[dict]                     # 当前流表各行的拷贝（每行恰好第 3 节那 7 个键），按到达先后

class EngineReader:
    def __init__(self, base_urls: list[str], make_fetcher=Fetcher, timeout_s: float = 0.5) -> None
    engine: str | None            # 属性："tensorfold"、"vllm"，没认出时 None
    base_url: str | None          # 属性：认出的那个地址，没认出时 None
    metrics_every_tick: bool      # 属性：engine == "vllm"
    def prepare(self, now: float, prefill_tps: float | None) -> None    # 每次轮询开头调一次，记下这次的时刻和平均预填充速度
    def health(self) -> dict | None
    def metrics(self) -> dict | None
    def model_name(self) -> str | None
    def close(self) -> None
```

- `VllmAdapter` 不读时钟、不做 I/O，同样的输入序列得到同样的输出。
- `EngineReader` 对轮询来说就是一个 `Fetcher`（`health`、`metrics`、`model_name`、`close` 四个方法的含义相同），多了引擎识别。`make_fetcher(base_url)` 返回一个有 `get_text`、`health`、`metrics`、`model_name`、`model_info`、`close` 的对象。

## 5. 采集（`panel/collector.py`）

- `Collector.feed` 的签名不变。`health` 里第 3 节那几个可选键“存在才生效”。
- 新属性 `Collector.prefill_tps -> float`：当前的平均预填充速度（只读）。
- 快照多两个字段：顶层 `engine`（`"hook"` 后面；取最近一次读数的 `backend`，离线时沿用，从没读到过为 `None`）；`prefill` 对象里的 `estimated`（`bool`，最后一个键）。

## 6. 今日用量（`panel/usage.py`）

`UsageLedger.update(totals)` 的 `totals` 可以多带一个键 `"epoch"`（数字，引擎启动标记）。没有这个键和值为 `None` 等价。

## 7. 视图（`panel/view.py`）

`View` 在 `pill` 后面加一个字段：

```python
    pill_kind: str = "exact"     # pill 为 True 时画哪一种标记："exact" 实心的“精确” | "avg" 琥珀色描边的“近期平均”
```

## 8. 录下来的 vLLM 序列（`fixtures/vllm/seq-*.json`）

```json
{
  "about": "场景说明",
  "interval_s": 0.05,
  "fields": ["t", "running", "waiting", …],
  "samples": [[0.005, 0, 0, …], …],
  "requests": [{"name": "long", "t_send": 1.0051, "t_first": 10.361, "t_end": 13.502, "aborted": false,
                "prompt_tokens": 24085, "completion_tokens": 160}],
  "checkpoints": [{"t": 3.5058, "detail": true, "rows": [{"id": 1, "phase": "prefill", "prompt": 24085, "cached": 0,
                   "start": 1.506, "ttft_s": null}], "decoding": 0, "prefilling": 1, "max": 4,
                   "aborted_total": 0, "ttft_count": 0, "ttft_sum": 0.0}]
}
```

- `samples`：每 0.05 秒读一次真实 vLLM 的 `/metrics` 得到的 vLLM 读数。每个元素是一个数组，第一项是时刻 `t`（秒），后面各项按 `fields` 的顺序；`dict(zip(fields[1:], sample[1:]))` 就是那一刻的 vLLM 读数。
- `requests`：录制时实际发出的请求。`t_send`、`t_first`、`t_end` 是客户端发出、收到首字、结束（或断开）的时刻；`aborted` 为真表示客户端中途断开，这时两个 token 数是 `null`。token 数是接口返回的 `usage`。
- `checkpoints`：用一个新建的 `VllmAdapter`，把 `samples[::2]`（每隔一个取一个，也就是 0.1 秒一次）依次 `feed(t, 读数)`（不传 `prefill_tps`、`context_length`），**流表每次变化后**应有的状态。也就是说：每喂一次之后，适配器的状态都应等于“`t` 不晚于这次的最后一个 checkpoint”。
  - `detail`：返回的 `health` 里有没有 `tfpanel` 键。
  - `rows`：`VllmAdapter.rows()` 的结果去掉 `output`；`start` 四舍五入到 3 位小数、`ttft_s` 到 4 位。
  - `decoding`、`prefilling`、`max`：`health["streams"]` 的三项。`aborted_total`：`health["aborted_total"]`。`ttft_count`、`ttft_sum`：返回的 `metrics` 里的两项（`ttft_sum` 四舍五入到 4 位）。

`fixtures/vllm/metrics-b.txt` 是一份真实的 `/metrics` 原文，`fixtures/vllm/metrics-b.expect.json` 是它应有的 `parse_vllm_metrics` 结果。
