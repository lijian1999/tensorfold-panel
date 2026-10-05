# 任务 D：读取（sources）和今日用量（usage）

先读 `AGENTS.md`，再读 `docs/tasks/00-contracts.md` 的第 1、2、4、5 节，和 `docs/design.md` 的“数据来源”“今日统计与费用”两节。本任务只用标准库，全部在 MacBook Pro 上完成，不需要 `ssh spark`。

`panel/config.py`（`Config`）已经有了，直接用，不要改它。

## 交付文件

1. `panel/sources.py`
2. `panel/usage.py`
3. `panel/tests/test_sources.py`
4. `panel/tests/test_usage.py`

不要创建或修改别的文件。

## `panel/sources.py`

三个解析函数按接口约定第 4 节。补充：

- `parse_health`：`bytes` 按 UTF-8 解码，解码失败返回 `None`。
- `parse_metrics`：逐行解析，忽略 `#` 开头的行和不认识的行；数值解析失败的行忽略。`kv_usage` 按 `pool="N"` 里的 N（整数）从小到大排；没有这类行时为 `[]`。`ttft_count` 转成 `int`。永不抛异常。
- `parse_meminfo`：从 `MemTotal:       127532380 kB` 这种行取数。结果保留原始精度，不四舍五入。

另外提供：

```python
def read_meminfo(path: str = "/proc/meminfo") -> dict | None      # 读文件并解析；文件不存在或读不了返回 None

class Fetcher:
    def __init__(self, base_url: str, timeout_s: float = 0.5)
    def health(self) -> dict | None        # GET /health → parse_health；任何失败返回 None
    def metrics(self) -> dict | None       # GET /metrics → parse_metrics；任何失败（含非 200）返回 None
    def model_name(self) -> str | None     # GET /v1/models → data[0]["id"]；任何失败返回 None
    def close(self) -> None
```

- `Fetcher` 用 `http.client.HTTPConnection` 复用同一条连接（每秒要读 10 次）。任何异常（连不上、超时、断开、非 200、内容不对）都吃掉并返回 `None`，同时关掉连接，下次调用重新连。三个方法永不抛异常。
- `base_url` 形如 `http://127.0.0.1:8888`，用 `urllib.parse.urlsplit` 取主机和端口；只支持 `http`。
- 不发任何 POST，不访问上面三个路径之外的地址。

## `panel/usage.py`

接口按接口约定第 5 节。规则：

- 文件：`<state_dir>/usage.json` 和 `<state_dir>/usage-history.jsonl`。`state_dir` 参数为 `None` 时用 `config.state_dir`；都要 `os.path.expanduser`。目录在第一次写文件时才创建。
- `usage.json` 的格式：

```json
{"version": 1, "date": "2026-10-03", "prompt_tokens": 8260391, "cached_tokens": 5443627,
 "completion_tokens": 185305, "requests": 98,
 "last_totals": {"prompt": 9116422, "cached": 6208194, "completion": 196157, "requests": 130}}
```

- 构造时读 `usage.json`。文件不存在、读不了、格式不对：当作没有，从空账开始（`last_totals` 为 `None`），不抛异常。
- `update(totals)`：
  1. `totals` 缺键或值不是整数（`bool` 不算）：整次忽略。
  2. 先处理换日（见下）。
  3. 没有 `last_totals`（第一次运行）：只记下 `last_totals = totals`，今日的账不变。
  4. 四项里任何一项比 `last_totals` 小：模型重启过，这次的 `totals` 整个算作增量。
  5. 否则增量 = `totals − last_totals`。
  6. 把增量加到今日的账（`prompt` → `prompt_tokens`，`cached` → `cached_tokens`，`completion` → `completion_tokens`，`requests` → `requests`），`last_totals = totals`。
  7. 账或 `last_totals` 有变化就标记“待写”。待写且（从没写过，或距上次写文件已满 `save_interval_s`）时写文件。
- 换日：用 `clock()` 和 `zoneinfo.ZoneInfo(config.timezone)` 算出当前日期（`YYYY-MM-DD`）。和账上的 `date` 不同时：如果账上有日期且四项不全为 0，往 `usage-history.jsonl` 追加一行 `{"date": 旧日期, "prompt_tokens": …, "cached_tokens": …, "completion_tokens": …, "requests": …, "cost": …}`；然后四项清零、`date` 改成当前日期、标记待写并立刻写文件。`last_totals` 不动。`today()` 也要先处理换日（这样离线时过了 0 点画面也会清零）。
- 时区名无效时退回 `America/Los_Angeles`。
- 费用：`((prompt_tokens − cached_tokens) × price_input + cached_tokens × price_cached + completion_tokens × price_output) ÷ 1_000_000`，每次调用 `today()` 时现算，不存文件。
- 写文件：先写同目录的临时文件再 `os.replace`。写失败（例如目录不可写）不抛异常，保留“待写”标记，下次再试。
- `flush()`：待写就立刻写。

## 测试要求

用标准库 `unittest`，不访问真实的 8888 端口，不 sleep（HTTP 测试除外）。

### `panel/tests/test_sources.py`

1. `parse_health`：正常对象原样返回（`bytes` 和 `str` 都行）；`ok` 为 `false`、缺 `ok`、数组、坏 JSON、空串、非 UTF-8 的 `bytes` 都返回 `None`。
2. `parse_metrics`：用下面这段文字，得到 `{"waiting": 2, "kv_usage": [0.093899, 0.0, 0.5], "ttft_sum": 1599.727361, "ttft_count": 156}`（浮点用 `assertAlmostEqual`）：

```text
# HELP tensorfold:requests_waiting x
# TYPE tensorfold:requests_waiting gauge
tensorfold:requests_running 3
tensorfold:requests_waiting 2
tensorfold:kv_cache_usage_ratio{pool="2"} 0.5
tensorfold:kv_cache_usage_ratio{pool="0"} 0.093899
tensorfold:kv_cache_usage_ratio{pool="1"} 0
tensorfold:time_to_first_token_seconds_bucket{le="0.5"} 26
tensorfold:time_to_first_token_seconds_sum 1599.727361
tensorfold:time_to_first_token_seconds_count 156
坏行
tensorfold:requests_waiting abc
```

   空串得到 `{"waiting": None, "kv_usage": [], "ttft_sum": None, "ttft_count": None}`。
3. `parse_meminfo`：`"MemTotal:       127532380 kB\nMemFree: 1 kB\nMemAvailable:   30168172 kB\n"` 得到 `total_gb ≈ 121.62`、`used_gb ≈ 92.85`；缺 `MemAvailable` 返回 `None`。`read_meminfo` 读不存在的路径返回 `None`，读临时文件正常。
4. `Fetcher`：在测试里用 `http.server.ThreadingHTTPServer` 在 `127.0.0.1` 的随机端口（端口传 0）起一个假服务（放在线程里，`log_message` 覆盖成不输出），它对 `/health`、`/metrics`、`/v1/models` 返回可配置的状态码和内容。覆盖：
   - 三个方法正常返回；连续调用 20 次 `health()` 都成功。
   - `/health` 返回 500、返回坏 JSON：`None`。`/metrics` 返回 404：`None`。`/v1/models` 返回 `{"data": []}`：`None`。
   - 服务关掉后三个方法都返回 `None`，不抛异常，且很快返回（没有监听的端口会立刻被拒绝）。
   - 服务关掉再在**同一个端口**重新起来后，同一个 `Fetcher` 对象的 `health()` 恢复正常（验证会重连）。
   - `Fetcher("http://127.0.0.1:1")`（没人监听）不抛异常。

### `panel/tests/test_usage.py`

用假时钟（一个返回可变数字的函数）和 `tempfile.TemporaryDirectory()` 作 `state_dir`。时间戳提示：太平洋时间 2026-10-03 12:00:00（夏令时，UTC−7）= UTC 2026-10-03 19:00:00；用 `datetime(…, tzinfo=timezone.utc).timestamp()` 算，不要手算。覆盖：

1. 第一次运行（没有文件）：第一次 `update` 后 `today()` 四项都是 0，`date == "2026-10-03"`；第二次 `update`（各项增加）后 `today()` 等于增量。
2. 费用：把账做成 `prompt_tokens=8260391, cached_tokens=5443627, completion_tokens=185305`（先 `update` 全 0，再 `update` 这组数），`cost ≈ 0.5967`（`places=4`）。改 `Config(price_output=1.0)` 后费用相应变化。
3. 模型重启：`update` 到 `{prompt: 1000, cached: 400, completion: 50, requests: 3}` 之后再 `update({prompt: 120, cached: 0, completion: 30, requests: 1})`，今日的账增加 120、0、30、1。
4. 副屏程序重启：一个账 `update` 几次后 `flush()`；用同一个目录新建一个账，`update` 更大的累计值，今日的账 = 之前的 + 这段时间的增量。
5. 换日：时钟设在太平洋时间 10 月 3 日 23:59:50，记几笔；时钟拨到 10 月 4 日 00:00:10，调 `today()`：四项为 0、`date == "2026-10-04"`；`usage-history.jsonl` 有一行，`date == "2026-10-03"`、各项和费用正确。再 `update` 增量记到 10 月 4 日。全为 0 的一天不写历史行。
6. 写文件的节流：`save_interval_s=10`。第一次有变化立刻写；之后 9 秒内的变化不写（读文件内容验证还是旧值）；满 10 秒后的下一次 `update` 写；`flush()` 立刻写；没有变化时 `update` 不重写文件（比较文件的 `st_mtime_ns` 或内容）。
7. 坏文件：`usage.json` 内容是 `"{坏"`、是 `[1]`、缺字段：构造不抛异常，按第一次运行处理。
8. `update` 传 `{"prompt": 1}`（缺键）、传 `{"prompt": "1", ...}`、传 `None`：忽略，不抛异常。
9. `state_dir` 是一个不存在的多级目录：第一次写时自动创建。`state_dir` 指向一个不可写的位置（例如一个普通文件的路径下面 `…/file.txt/sub`）：`update` 和 `flush` 不抛异常。
10. `Config(timezone="不存在/时区")`：不抛异常，按 `America/Los_Angeles` 算日期。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_sources panel.tests.test_usage -v
ssh spark 'rm -rf /tmp/tfpanel-d && mkdir -p /tmp/tfpanel-d'
scp -q -r panel spark:/tmp/tfpanel-d/
ssh spark 'cd /tmp/tfpanel-d && python3 -m unittest panel.tests.test_sources panel.tests.test_usage 2>&1 | tail -4; python3 -c "
from panel.sources import Fetcher, read_meminfo
f = Fetcher(\"http://127.0.0.1:8888\")
h = f.health(); m = f.metrics()
print(\"health keys:\", sorted(h)[:4], \"| metrics:\", m, \"| model:\", f.model_name(), \"| mem:\", read_meminfo())
"; rm -rf /tmp/tfpanel-d'
```

最后一条在 Spark 上跑同样的测试（Python 3.12），并对真实接口只读地读一次（只读 `/health`、`/metrics`、`/v1/models`，这是允许的）。输出里测试应为 `OK`，`model:` 后面应是 `Qwen3.8-Flash-Next`，`metrics` 里 `ttft_count` 是一个正整数。
