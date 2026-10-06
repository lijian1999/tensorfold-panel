# 任务 V1：配置加接口地址列表；读取加 vLLM 的 `/metrics` 解析和两个读取方法

先读 `AGENTS.md`，再读接口约定 `docs/tasks/V-contracts.md` 的第 1、2 节。本任务改四个文件：`panel/config.py`、`panel/sources.py`、`panel/tests/test_base.py`、`panel/tests/test_sources.py`。不要改别的文件。不需要在 Spark 上运行任何东西。

## 背景

副屏程序要同时支持 TensorFold 和 vLLM 两种推理引擎。vLLM 没有 TensorFold 那样的 JSON `/health`，数据全在 `/metrics`（Prometheus 文本）里；两种引擎的端口也不一样，所以接口地址从一个变成一个列表。这个任务只做最底下的两块：配置项，和把 vLLM 的 `/metrics` 文本解析成字典。

同时有别的执行者在改 `panel/` 下的其他文件（`collector.py`、`usage.py`、`engine.py`、`viewmodel.py`、`render.py`、`view.py`）。所以检查命令只跑下面写的这两个测试模块，不要跑全部测试。

## 第一步：`panel/config.py`

1. `base_url` 的默认值改成空字符串：`base_url: str = ""`（后面的注释写“非空时只用这一个地址（兼容旧配置）”）。
2. 在它后面加一个字段：

   ```python
       base_urls: list[str] = field(default_factory=lambda: ["http://127.0.0.1:8888", "http://127.0.0.1:8000"])  # 按顺序试，用第一个认得出引擎的
   ```

3. 给 `Config` 加方法 `urls(self) -> list[str]`：`base_url` 非空返回 `[self.base_url]`，否则返回 `list(self.base_urls)`。
4. `_coerce` 加一种情况：默认值是 `list` 时，配置文件里的值必须是非空列表、每一项都是非空字符串才采用（采用时拷贝一份），否则用默认值。

`panel/tests/test_base.py`：

- `TestConfig.test_defaults` 的期望值里 `"base_url"` 改成 `""`，并在它后面加 `"base_urls": ["http://127.0.0.1:8888", "http://127.0.0.1:8000"]`。这个文件里现有的其他测试一行不改。
- 新加一个测试类 `TestConfigUrls`，覆盖：
  - 默认配置 `urls()` 是那两个地址；改返回的列表不影响下一次 `urls()` 的结果。
  - 配置文件只写了 `base_url`（`"http://127.0.0.1:1"`）→ `urls()` 是 `["http://127.0.0.1:1"]`。
  - 只写了 `base_urls`（一个地址的列表）→ `urls()` 就是它。
  - 两个都写了 → `urls()` 是 `[base_url]`。
  - `base_urls` 写成字符串、空列表、含数字的列表、含空字符串的列表 → 都用默认的两个地址。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -c "from panel.config import Config; c = Config(); print(repr(c.base_url), c.urls())"
python3 -m unittest panel.tests.test_base 2>&1 | tail -1
```

第一条应输出 `'' ['http://127.0.0.1:8888', 'http://127.0.0.1:8000']`，第二条应输出 `OK`。

## 第二步：`panel/sources.py` 加 `VLLM_FIELDS` 和 `parse_vllm_metrics`

照接口约定第 2 节写。现有的 `parse_health`、`parse_metrics`、`parse_meminfo`、`read_meminfo` 不动。

`panel/tests/test_sources.py` 新加测试类 `TestParseVllmMetrics`（现有测试一行不改），覆盖：

- 读 `fixtures/vllm/metrics-b.txt`，结果等于 `fixtures/vllm/metrics-b.expect.json`，键的顺序等于 `VLLM_FIELDS`；`success` 是 `int`，`ttft_sum` 是 `float`。
- 同名多行相加：`vllm:request_success_total{finished_reason="stop"} 9.0` 和 `…{finished_reason="length"} 11.0` 两行 → `success` 为 `20`。
- 指标名完全相等才算：只有 `vllm:prompt_tokens_cached_total 5` 和 `vllm:prompt_tokens_created 1.7e9` 时 `prompt` 是 `0`、`prompt_cached` 是 `5`。
- 没有标签的行也认：`vllm:num_requests_running 2` → `running` 为 `2`。
- 没有 `vllm:num_requests_running` → `None`；只有它一行 → 其余 int 键 `0`、float 键 `0.0`、`epoch` 为 `None`。
- 传 `None`、空字符串 → `None`；夹着读不懂的行（数值不是数字、只有一个词）不抛异常。
- TensorFold 的 `/metrics` 文本（只有 `tensorfold:` 开头的指标）→ `None`。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 - <<'EOF'
import json
from panel.sources import VLLM_FIELDS, parse_vllm_metrics
got = parse_vllm_metrics(open("fixtures/vllm/metrics-b.txt", encoding="utf-8").read())
want = json.load(open("fixtures/vllm/metrics-b.expect.json", encoding="utf-8"))
print(got == want, tuple(got) == VLLM_FIELDS, type(got["success"]).__name__, type(got["epoch"]).__name__)
print(parse_vllm_metrics("tensorfold:requests_waiting 0\n"))
EOF
```

应输出两行：`True True int float` 和 `None`。

## 第三步：`Fetcher` 加 `get_text` 和 `model_info`

- `get_text(path)`：对外公开的读取，行为就是现有的 `_get(path)`（200 返回正文，空正文返回 `""`；其余返回 `None`）。
- `model_info()`：读 `/v1/models`，取 `data[0]`：`id` 是非空字符串才算读到，返回 `{"id": id, "max_model_len": 值}`；`max_model_len` 是正整数（`bool` 不算）才采用，否则这一项是 `None`。读不到、不是合法 JSON、没有 `id` 返回 `None`。
- `model_name()` 的行为不变（可以改成调用 `model_info()` 再取 `id`）。
- 文件开头和 `Fetcher` 的文档字符串里写死“8888 端口”的说法改成“模型接口”。

`panel/tests/test_sources.py` 的 `TestFetcher` 里已经有一个本地 HTTP 服务的写法，照着它在新测试类 `TestFetcherExtra` 里覆盖：

- `get_text("/health")`：服务返回 200 空正文 → `""`；返回 200 带正文 → 正文；返回 404 → `None`；端口没人听 → `None`。
- `model_info()`：`{"data": [{"id": "Qwen/Qwen3.8-Flash-Next", "max_model_len": 262144}]}` → `{"id": "Qwen/Qwen3.8-Flash-Next", "max_model_len": 262144}`；没有 `max_model_len` 或它是字符串 → 那一项为 `None`；`data` 是空列表 → `None`。
- `model_name()` 对上面第一种返回 `"Qwen/Qwen3.8-Flash-Next"`。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_sources 2>&1 | tail -1
```

应输出 `OK`。

## 最后一步：收尾检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_base panel.tests.test_sources 2>&1 | tail -1
git status --short panel/config.py panel/sources.py panel/tests/test_base.py panel/tests/test_sources.py
```

通过的标准：第一条输出 `OK`；第二条恰好列出这四个文件，都是 ` M`。全部通过后最后一行输出 `DONE`。
