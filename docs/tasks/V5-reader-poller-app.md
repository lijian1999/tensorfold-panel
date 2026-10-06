# 任务 V5：引擎识别 `EngineReader`，接进轮询和窗口程序

先读 `AGENTS.md`，再读接口约定 `docs/tasks/V-contracts.md`（全部）。本任务改这些文件：`panel/engine.py`、`panel/poller.py`、`panel/app.py`、`panel/sources.py`、`panel/tests/test_engine.py`、`panel/tests/test_poller.py`、`panel/tests/test_sources.py`。不要改别的文件。副屏上正跑着正式的副屏程序，不要启动、停止它，也不要往 `~/tfpanel/` 同步；在 Spark 上只用 `/tmp/tfpanel-v5`。

## 背景

Spark 上的推理引擎可能是 TensorFold，也可能是 vLLM，端口也不固定。副屏程序要自己认出来，换了引擎不用改配置、不用重启。现在已经有的零件：

- `panel/sources.py`：`Fetcher`（`health`、`metrics`、`model_name`、`get_text`、`model_info`）、`parse_health`、`parse_vllm_metrics`。
- `panel/engine.py`：`VllmAdapter`，把 vLLM 读数变成和 TensorFold `/health` 同样格式的统一读数。
- `panel/collector.py`：`Collector` 已经认统一读数里 vLLM 的可选键，有 `prefill_tps` 属性。
- `panel/config.py`：`Config.urls()` 给出要试的接口地址列表。

这个任务把它们接起来：写 `EngineReader`（对轮询来说它就是一个带引擎识别的 `Fetcher`），`Poller` 认它多出来的两样东西，窗口程序和命令行改用它。**`test_poller.py`、`test_sources.py`、`test_engine.py` 里现有的测试一行都不能改**，只能加新的测试类。

## 第一步：`parse_vllm_metrics` 忽略不是有限数的数值

`panel/sources.py` 的 `parse_vllm_metrics`：一行的数值是 `NaN`、`+Inf`、`-Inf` 时（`math.isfinite` 为假），和读不懂的行一样忽略。现在这种行会让 `int()` 抛异常。

`panel/tests/test_sources.py` 的 `TestParseVllmMetrics` 里加一个测试：`"vllm:num_requests_running 1\nvllm:generation_tokens_total NaN\nvllm:prompt_tokens_total +Inf\n"` → 不抛异常，`running` 是 1，`generation`、`prompt` 是 0；只有一行 `"vllm:num_requests_running NaN\n"` → `None`。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_sources 2>&1 | tail -1
```

应输出 `OK`。

## 第二步：`EngineReader`（`panel/engine.py`）

`panel/engine.py`：文件开头那两行 `#` 注释改成模块文档字符串（和 `panel/` 下别的文件一样），内容改成“引擎适配：引擎识别（`EngineReader`）和 vLLM 适配器（`VllmAdapter`）……”这样两样都提到；`_DEFAULT_TPS` 那行注释里的英文词 `assumed` 改成中文。然后加 `from panel.sources import Fetcher, parse_health, parse_vllm_metrics`，在 `VllmAdapter` 后面加 `EngineReader`：

```python
class EngineReader:
    def __init__(self, base_urls, make_fetcher=None, timeout_s=0.5)
```

`make_fetcher` 是 `None` 时用 `Fetcher(url, timeout_s=timeout_s)` 建读取器，否则用 `make_fetcher(url)`。每个地址的读取器第一次用到时才建，建好留着复用。

内部状态：`engine`（`None`）、`base_url`（`None`）、一个 `VllmAdapter`、这次的时刻 `now`（`0.0`）和平均预填充速度（`None`）、连续读不到的次数（0）、最近一次 vLLM 的统一 `metrics`（`None`）、vLLM 的上下文上限（`None`）。

- `prepare(now, prefill_tps)`：记下这两个数，后面喂适配器时用。
- `metrics_every_tick`（属性）：`engine == "vllm"`。
- `health()`：
  1. **还没认出引擎**（`engine is None`）：按 `base_urls` 的顺序逐个地址试，认出一个就停：
     - `text = 读取器.get_text("/health")`；是 `None` → 试下一个地址。
     - `parse_health(text)` 不是 `None` → 认出 **TensorFold**：`engine = "tensorfold"`，`base_url` 记这个地址，返回这个字典。
     - 否则 `get_text("/metrics")`，`parse_vllm_metrics` 的结果不是 `None` → 认出 **vLLM**：`engine = "vllm"`，`base_url` 记这个地址，适配器 `reset()`，把这份读数喂给适配器（见下），返回适配器给的 `health`。
     - 否则试下一个地址。全部地址都不行 → 返回 `None`。
  2. **已经认出 TensorFold**：返回 `读取器.health()`（只读认出的那个地址）。
  3. **已经认出 vLLM**：`get_text("/metrics")` → `parse_vllm_metrics`；有一步是 `None` 就返回 `None`；否则喂给适配器，返回适配器给的 `health`。
  4. 已经认出引擎而这次返回 `None`：连续读不到的次数加 1，到 3 就**忘掉**：`engine`、`base_url`、最近一次的 `metrics`、上下文上限都回到 `None`，次数清零，适配器 `reset()`，所有读取器 `close()`。这次读到了：次数清零。（没认出引擎时读不到不计数。）
- “喂给适配器”：`health, metrics = adapter.feed(now, m, prefill_tps, 上下文上限)`，把 `metrics` 记成“最近一次 vLLM 的统一 metrics”。
- `metrics()`：TensorFold → `读取器.metrics()`；vLLM → 最近一次的统一 `metrics`（拷贝一份，不访问网络）；没认出 → `None`。
- `model_name()`：TensorFold → `读取器.model_name()`；vLLM → `读取器.model_info()`，是 `None` 就返回 `None`，否则把它的 `max_model_len` 记成上下文上限、返回它的 `id`；没认出 → `None`。
- `close()`：所有建过的读取器都 `close()`。

`panel/tests/test_engine.py` 文件末尾（`if __name__` 之前）先加辅助代码（原样用）：

```python
from panel.engine import EngineReader

METRIC_NAMES = {
    "running": "vllm:num_requests_running", "waiting": "vllm:num_requests_waiting",
    "queries": "vllm:prefix_cache_queries_total", "hits": "vllm:prefix_cache_hits_total",
    "prompt": "vllm:prompt_tokens_total", "prompt_cached": "vllm:prompt_tokens_cached_total",
    "ttft_sum": "vllm:time_to_first_token_seconds_sum", "ttft_count": "vllm:time_to_first_token_seconds_count",
    "generation": "vllm:generation_tokens_total", "success": "vllm:request_success_total",
    "req_prompt_sum": "vllm:request_prompt_tokens_sum", "req_generation_sum": "vllm:request_generation_tokens_sum",
    "req_computed_sum": "vllm:request_prefill_kv_computed_tokens_sum",
    "prefill_s": "vllm:request_prefill_time_seconds_sum", "decode_s": "vllm:request_decode_time_seconds_sum",
    "drafted": "vllm:spec_decode_num_draft_tokens_total", "accepted": "vllm:spec_decode_num_accepted_tokens_total",
    "epoch": "process_start_time_seconds",
}


def metrics_text(m):
    """把一份 vLLM 读数写回 /metrics 文本（repr 保证浮点数原样读回来）。"""
    return "".join(f"{METRIC_NAMES[k]} {m[k]!r}\n" for k in METRIC_NAMES if m.get(k) is not None)


class FakeFetcher:
    """假读取器：texts 是 {路径: 正文或 None}；记下每次调用。"""

    def __init__(self, url, texts=None, health=None, metrics=None, model=None, info=None):
        self.url = url
        self.texts = dict(texts or {})
        self.health_value, self.metrics_value, self.model_value, self.info_value = health, metrics, model, info
        self.calls = []
        self.closed = 0

    def get_text(self, path):
        self.calls.append(("get_text", path))
        return self.texts.get(path)

    def health(self):
        self.calls.append(("health",))
        return self.health_value

    def metrics(self):
        self.calls.append(("metrics",))
        return self.metrics_value

    def model_name(self):
        self.calls.append(("model_name",))
        return self.model_value

    def model_info(self):
        self.calls.append(("model_info",))
        return self.info_value

    def close(self):
        self.closed += 1


def reader_with(fakes):
    """fakes 是 {地址: FakeFetcher}；返回按这些地址的顺序去试的 EngineReader。"""
    return EngineReader(list(fakes), make_fetcher=lambda url: fakes[url])
```

再加测试类 `TestEngineReader`，下面用 `A = "http://127.0.0.1:8888"`、`B = "http://127.0.0.1:8000"`，`TF = '{"ok": true, "backend": "tensorfold", "requests_running": 0}'`，`VTEXT` 是 `fixtures/vllm/metrics-b.txt` 的内容：

1. 两个地址都读不到（`texts` 为空）：`health()` 是 `None`，`engine`、`base_url` 是 `None`，`metrics_every_tick` 是 `False`，`metrics()`、`model_name()` 是 `None`；连调 5 次 `health()` 后两个假读取器各被 `get_text("/health")` 了 5 次，`closed` 都是 0。
2. 认出 TensorFold：`A` 的 `texts={"/health": TF}`、`health={"ok": True, "requests_running": 1}`、`metrics={"waiting": 3}`、`model="m"`。第一次 `health()` 返回 `{"ok": True, "backend": "tensorfold", "requests_running": 0}`，`engine == "tensorfold"`，`base_url == A`，`metrics_every_tick is False`，`B` 没有被调用过。第二次 `health()` 返回 `{"ok": True, "requests_running": 1}`（走的是 `A.health()`）；`metrics()` 是 `{"waiting": 3}`，`model_name()` 是 `"m"`。
3. 认出 vLLM（在第二个地址）：`A` 的 `texts` 为空，`B` 的 `texts={"/health": "", "/metrics": VTEXT}`。`prepare(5.0, None)` 后 `health()`：返回的字典 `backend == "vllm"`、`requests_total == 20`、`completion_tokens_total == 2036`、有 `tfpanel`；`engine == "vllm"`，`base_url == B`，`metrics_every_tick is True`；`metrics()` 等于 `{"waiting": 0, "kv_usage": [], "ttft_sum": 0.0, "ttft_count": 0}`，改它返回的字典不影响下一次 `metrics()`。再调一次 `health()`：这一次 `B` 只多了一次 `("get_text", "/metrics")`，`A` 没有新的调用。
4. `/health` 返回 200 但认不出：`A` 的 `texts={"/health": "", "/metrics": "tensorfold:requests_waiting 0\n"}`，`B` 为空 → `health()` 是 `None`，`engine` 是 `None`。`A` 的 `texts={"/health": '{"ok": false}', "/metrics": VTEXT}` → 认出 vLLM（`/health` 不是合法的 TensorFold 正文时照样去看 `/metrics`）。
5. 连续 3 次读不到才忘掉：照第 3 条认出 vLLM 后，把 `B.texts["/metrics"]` 改成 `None`：第 1、2 次 `health()` 是 `None`、`engine` 还是 `"vllm"`；第 3 次之后 `engine`、`base_url` 是 `None`，`B.closed >= 1`。第 4 次 `health()` 又从 `A` 开始试（`A` 多了一次 `("get_text", "/health")`）。
6. 中间读到一次就重新计数：认出 vLLM 后 读不到、读不到、读到（把正文改回 `VTEXT`）、读不到、读不到 → `engine` 还是 `"vllm"`。
7. TensorFold 也一样：照第 2 条认出后把 `A.health_value` 改成 `None`，连调 3 次 `health()` → `engine` 是 `None`。
8. 忘掉之后适配器是干净的：`B` 的 `/metrics` 先给 `seq-abort-decode` 的各个读数（用 `metrics_text`，`samples[::2]`，每次先 `prepare(t, None)` 再 `health()`），最后一次的 `aborted_total` 是 1；然后连续 3 次读不到；再给最后那份读数 → `aborted_total` 是 0。
9. 时刻和速度传给了适配器：`B` 的 `/metrics` 依次给 `seq-long` 的 `samples[::2]`（`metrics_text`），每次 `prepare(t, 24085.0)` 再 `health()`；`t` 为 3.5058 的那次返回的 `tfpanel["streams"][0]["start"]` 约 2.5058（误差 0.002）；全部喂完后 `metrics()["ttft_count"] == 1`、`metrics()["ttft_sum"]` 约 9.3375。
10. vLLM 的模型名和上下文上限：认出 vLLM 后 `B.info_value = {"id": "Qwen/Qwen3.8-Flash-Next", "max_model_len": 131072}`：这之前 `health()` 返回的字典没有 `context_length` 键；`model_name()` 返回 `"Qwen/Qwen3.8-Flash-Next"`；之后 `health()` 返回的字典 `context_length == 131072`。`B.info_value = None` 时 `model_name()` 是 `None`。
11. `close()`：照第 3 条认出后 `close()`，`A.closed`、`B.closed` 都至少是 1。
12. 默认的读取器：`EngineReader(["http://127.0.0.1:1"])`（不传 `make_fetcher`）的 `health()` 是 `None`，不抛异常。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_engine 2>&1 | tail -1
```

应输出 `OK`。

## 第三步：`Poller` 认 `prepare` 和 `metrics_every_tick`（`panel/poller.py`）

`tick()` 里改两处，别的不动：

1. 取到 `now` 之后、读 `health` 之前：`self.fetcher` 有可调用的 `prepare` 时调 `prepare(now, getattr(self.collector, "prefill_tps", None))`，用 `self._call` 包着（抛异常不影响这次读取）。
2. 读 `/metrics` 的条件：`every = getattr(self.fetcher, "metrics_every_tick", False) is True`。`health` 不是 `None` 且 `every` 为真时，这一拍一定调 `self.fetcher.metrics()`（不看忙不忙，也不受 0.5 秒间隔限制）；`every` 不为真时照旧。

`brief_line` 在行尾多加一段：快照的 `engine` 是非空字符串时加 ` engine=<值>`，否则不加。

`main()`：`Fetcher(config.base_url)` 换成 `EngineReader(config.urls())`；`--help` 的说明里“读取 8888 端口的只读接口”改成“读取模型接口的只读接口”；文件里用不到的 import 去掉。

`panel/tests/test_poller.py` 文件末尾加测试类 `TestEngineHooks`（用文件里现成的 `FakeClock`、`ScriptedFetcher`、`FakeCollector`、`make`、`IDLE`）：

- `prepare`：给 `ScriptedFetcher` 写一个子类，`prepare(now, tps)` 把参数记进列表、并记下当时 `health_calls` 的值。采集器用带 `prefill_tps = 2345.0` 属性的 `FakeCollector` 子类。拨两拍（0.0、0.3）：记下的是 `[(0.0, 2345.0), (0.3, 2345.0)]`，而且每次 `prepare` 都发生在那一拍的 `health()` 之前。采集器没有 `prefill_tps` 属性时传的是 `None`。
- `prepare` 抛异常：`tick()` 照常返回快照，`health_calls` 照常加 1。
- `metrics_every_tick`：子类加类属性 `metrics_every_tick = True`，`health=IDLE`，采集器返回 `{"state": "idle"}`。拨 4 拍（0.0、0.25、0.5、0.75）：`metrics_calls == 4`，采集器每次 `feed` 收到的 `metrics` 都不是 `None`。
- 没有这个属性的 `ScriptedFetcher` 同样拨 4 拍：`metrics_calls == 0`（空闲时不读，和现在一样）。
- `health` 是 `None` 时即使 `metrics_every_tick` 为真也不调 `metrics()`。
- `brief_line({"state": "idle", "engine": "vllm"})` 以 ` engine=vllm` 结尾；`brief_line({"state": "idle"})` 里没有 `engine=`。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_poller 2>&1 | tail -1
```

应输出 `OK`。

## 第四步：适配器 + 采集器连起来，对照实际发出的请求

`panel/tests/test_engine.py` 再加测试类 `TestPipeline`。辅助函数：新建 `VllmAdapter()` 和 `Collector(Config())`，对一段序列的 `samples[::2]` 逐个做 `health, metrics = adapter.feed(t, m, collector.prefill_tps, 262144)`、`snap = collector.feed(t, health, metrics)`，返回 `[(t, m, snap), …]`。

1. `short`：最后一份快照 `state == "done"`，`engine == "vllm"`，`hook == "ok"`；`last` 的 `prompt_tokens`、`completion_tokens` 等于 `requests[0]` 的两个 token 数（65、40），`cached_tokens == 0`，`ttft_s` 约 0.1255（误差 0.001），`decode_tps` 约 `40 / 0.61455`（误差 0.01）。
2. `long`：第一份 `state == "prefill"` 的快照：`prefill["estimated"] is True`，`prefill["prompt_tokens"] == 24085`，`prefill["cached_tokens"] == 0`，`elapsed_s` 约 2.0（误差 0.01）。最后一份 `state == "prefill"` 的快照：`filled_tokens / prompt_tokens >= 0.6`。所有 `state == "decode"` 的快照 `decode["ttft_s"]` 约 9.3375。最后一份快照：`state == "done"`；`last` 的 `prompt_tokens == 24085`、`cached_tokens == 0`、`completion_tokens == 160`、`ttft_s` 约 9.3375、`context_used == 24245`。
3. `followup`：没有任何一份快照的 `prefill` 里 `cache_miss` 为真；最后 `last` 的 `prompt_tokens == 24126`、`cached_tokens == 19584`、`completion_tokens == 120`。
4. `abort-decode`、`abort-prefill`：没有任何一份快照 `state == "done"`；最后一份 `state == "idle"`，`last is None`，`lanes` 的 `decoding`、`prefilling` 都是 0。
5. `conc5`：每一份快照 `lanes["decoding"] + lanes["prefilling"] == m["running"]`；最后一份 `lanes["max"] == 5`，`round["requests"] == 5`，`round["output_tokens"] == 568`，`round["exact"] is False`。
6. `round`：最后一份 `round["requests"] == 4`，`round["output_tokens"] == 122`，`round["exact"] is True`；`last["prompt_tokens"] == 1646`，`last["completion_tokens"] == 30`。
7. 记账：给 `Collector` 一个只记录 `update` 参数的假账本（`today()` 返回 `{}`），跑 `conc3`：最后一次和第一次收到的 `totals` 之差是 `prompt` 3199、`cached` 0、`completion` 490、`requests` 3；每次都带 `epoch`，而且都相等。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_engine 2>&1 | tail -1
```

应输出 `OK`。

## 第五步：窗口程序改用 `EngineReader`（`panel/app.py`）

1. `start_poller` 里 `self.fetcher = Fetcher(self.config.base_url)` 换成 `self.fetcher = EngineReader(self.config.urls())`；import 跟着改（去掉用不到的 `Fetcher`）。
2. `main()` 里启动日志 `轮询 {config.base_url}` 改成把 `config.urls()` 用 `、` 连起来。
3. 别的不动。

```sh
cd /Users/kris/projects/tensorfold-panel
grep -n "config.base_url\|Fetcher(" panel/app.py panel/poller.py | wc -l
```

应输出 `0`（前面可能有空格）。

## 第六步：在 Spark 上对着真实的引擎跑一遍

```sh
cd /Users/kris/projects/tensorfold-panel
TFPANEL_DEST=/tmp/tfpanel-v5 scripts/sync.sh
ssh spark 'cd /tmp/tfpanel-v5 && python3 -m unittest panel.tests.test_engine panel.tests.test_poller panel.tests.test_sources panel.tests.test_collector panel.tests.test_usage panel.tests.test_base 2>&1 | tail -1'
ssh spark 'cd /tmp/tfpanel-v5 && python3 -c "import panel.app; print(1)"'
ssh spark 'cd /tmp/tfpanel-v5 && python3 -m panel.poller --seconds 4 --every 1 --brief' > /tmp/tfpanel-v5-brief.txt; cat /tmp/tfpanel-v5-brief.txt
grep -c "^offline" /tmp/tfpanel-v5-brief.txt; grep -c "engine=" /tmp/tfpanel-v5-brief.txt
```

第二条应输出 `OK`；第三条应输出 `1`；第四条打印 3 到 4 行状态，每行以 `idle`、`prefill`、`decode`、`done` 之一开头、以 ` engine=` 加引擎名结尾（引擎名以 `docker ps` 看到的正在跑的那个为准）；第五条的两个数：第一个是 `0`，第二个等于第四条打印的行数。

这一步没有给 `--state-dir`，不会碰正式的今日用量文件。

## 最后一步：收尾检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest discover -s panel/tests -t . 2>&1 | tail -1
git diff --numstat -- panel/tests/test_poller.py panel/tests/test_sources.py panel/tests/test_engine.py
ssh spark 'rm -rf /tmp/tfpanel-v5'; rm -f /tmp/tfpanel-v5-brief.txt
```

通过的标准：第一条输出以 `OK` 开头（后面可能有 `(skipped=1)`）；第二条三行的第二列（删除的行数）都是 `0`。全部通过后最后一行输出 `DONE`。
