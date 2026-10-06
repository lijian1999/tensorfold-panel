# 任务 I：轮询（poller）

先读 `AGENTS.md`，再读 `docs/tasks/00-contracts.md` 的第 1、2、4、5、6 节，和 `docs/design.md` 的“显示程序行为”一节最后一段（读取频率）。本任务只用标准库。

`panel/config.py`、`panel/sources.py`（`Fetcher`、`read_meminfo`）、`panel/usage.py`（`UsageLedger`）、`panel/collector.py`（`Collector`）都已经有了，直接用，不要改它们。

轮询把“按什么频率读哪个接口”这件事从窗口程序里拿出来，这样不需要显示器也能测，也能通过 SSH 在 Spark 上看实时快照。

## 交付文件

1. `panel/poller.py`
2. `panel/tests/test_poller.py`

不要创建或修改别的文件。

## 接口

```python
class Poller:
    def __init__(self, config, fetcher, collector, read_memory=None, clock=time.monotonic)
    def tick(self) -> tuple[dict, float]
    def run(self, on_snapshot, stop_event) -> None
```

- `fetcher`：有 `health()`、`metrics()`、`model_name()` 三个方法的对象（`sources.Fetcher` 或测试里的假对象）。
- `collector`：有 `feed(now, health, metrics=None, memory=None, model=None)` 的对象。
- `read_memory`：无参数、返回 `{"used_gb", "total_gb"}` 或 `None` 的函数；为 `None` 时用 `sources.read_meminfo`。
- `clock`：返回单调时钟秒数的函数。

### `tick()`：做一次读取，返回 `(快照, 距下一次读取的秒数)`

1. `now = clock()`。
2. `health = fetcher.health()`。
3. **`/metrics`**：满足“需要读”且距上次读 `/metrics` 已满 0.5 秒（或从没读过）时 `metrics = fetcher.metrics()`，否则 `None`。“需要读” = 上一次快照是忙的（见下），或距最近一次忙的时刻不到 2 秒，或这次 `health` 显示在忙（`health` 不为 `None` 且 `requests_running > 0`）。`health` 为 `None` 时不读。
4. **内存**：距上次读已满 1 秒（或从没读过）时 `memory = read_memory()`，否则 `None`。
5. **模型名**：还没拿到模型名、`health` 不为 `None`、且距上次尝试已满 5 秒（或从没试过）时 `model = fetcher.model_name()`（可能还是 `None`）。拿到之后不再读；但每次从离线恢复（上一次快照 `state == "offline"`、这次 `health` 不为 `None`）要重新读一次。其余时候 `model = None`。
6. `snapshot = collector.feed(now, health, metrics, memory, model)`。
7. 间隔：`snapshot["state"]` 是 `prefill` 或 `decode`，或 `lanes` 的 `decoding + prefilling + waiting > 0`（这就是“忙”）→ 0.1；`state == "offline"` → 0.5；其余 → 0.25。返回的秒数 = `max(0.01, 间隔 − (clock() − now))`（扣掉这次读取花的时间）。

`fetcher`、`read_memory`、`collector` 里任何一个抛异常：`tick` 不抛。读取的异常当作那一项没读到（`None`）；`collector.feed` 的异常则返回上一次的快照（从没有过就返回 `{"state": "offline"}`）和 0.5。

### `run(on_snapshot, stop_event)`

循环：`stop_event.is_set()` 为真就返回；否则 `snapshot, wait = self.tick()`；`on_snapshot(snapshot)`（它抛的异常吃掉）；`stop_event.wait(wait)`。`stop_event` 是 `threading.Event`。

### 命令行

```sh
python3 -m panel.poller [--seconds N] [--every S] [--config 路径] [--state-dir 目录] [--brief]
```

- 用 `load_config(--config)`、`Fetcher(config.base_url)`、`Collector(config, usage)` 跑轮询。`--state-dir` 给了就用 `UsageLedger(config, state_dir=那个目录)`，没给时 `usage=None`（**默认不读写正式的今日用量文件**，免得和正在运行的副屏程序抢着写）。
- 每隔 `--every` 秒（默认 1.0）把最新的快照打印一行到标准输出（`json.dumps(..., ensure_ascii=False)`，每行 `flush`）。`--brief` 时改为打印一行简短文字：`状态 解码/预填充/排队 合计速度 预填充进度 本轮 今日`，例如 `decode 2/1/0 tps=112.4 pf=10240/24615 round=3+3 today=98req $0.597`（没有的项写 `-`）。
- `--seconds`（默认 10）到时间后退出；`Ctrl-C` 也能干净退出。退出前如果有 `UsageLedger` 就 `flush()`。
- 只读 `/health`、`/metrics`、`/v1/models` 和 `/proc/meminfo`，不发任何别的请求。

## 测试要求（`panel/tests/test_poller.py`）

用假的 `fetcher`（按脚本返回，记录每个方法被调用的时刻和次数）、假的 `collector`（记录每次 `feed` 的参数，返回可配置的快照）、假的 `read_memory`、假时钟（每次 `tick` 之间手动拨）。不访问网络。至少覆盖：

1. 空闲：返回间隔 0.25；`health()` 每次都调；`metrics()` 不调；`read_memory` 第一次调、之后满 1 秒才再调；`model_name()` 第一次调，返回了名字之后不再调。
2. 忙（假 `collector` 返回 `state == "decode"`）：间隔 0.1；`metrics()` 第一次忙就调，之后每 0.5 秒调一次（连续 10 次间隔 0.1 的 `tick` 里调 2 次）。
3. 忙结束后 2 秒内 `metrics()` 还在按 0.5 秒调，2 秒后不再调。
4. 这次 `health` 的 `requests_running > 0`、而上一次快照还是 `idle`：这一次就读 `/metrics`。
5. 离线（`health()` 返回 `None`，假 `collector` 返回 `state == "offline"`）：间隔 0.5；不调 `metrics()`、`model_name()`。恢复后重新调一次 `model_name()`。
6. `model_name()` 返回 `None`：5 秒内不重试，满 5 秒再试。
7. `feed` 收到的参数：`now` 是时钟值；没读的项是 `None`。
8. 读取花了时间（假 `fetcher.health` 里把假时钟拨快 0.03 秒）：忙时返回的间隔 ≈ 0.07；花了 0.5 秒时返回 0.01。
9. 异常：`fetcher.health` 抛异常 → `feed` 收到 `health=None`，`tick` 不抛；`read_memory` 抛异常 → `memory=None`；`collector.feed` 抛异常 → 返回上一次的快照和 0.5。
10. `run`：`on_snapshot` 在收到第 3 个快照时 `stop_event.set()`，`run` 随即返回（用真实的 `threading.Event`，假 `collector` 返回忙的快照使间隔为 0.1，整个测试应在 1 秒内结束）；`on_snapshot` 抛异常不影响循环；`stop_event` 一开始就置位时一次 `tick` 都不做。
11. 命令行：用 `subprocess` 运行 `python3 -m panel.poller --seconds 0.6 --every 0.2 --config <临时配置文件>`，配置里 `base_url` 指向一个没人监听的端口（`http://127.0.0.1:1`）：退出码 0，标准输出每行都是合法 JSON 且 `state == "offline"`；加 `--brief` 时每行以 `offline` 开头。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_poller -v
ssh spark 'rm -rf /tmp/tfpanel-i && mkdir -p /tmp/tfpanel-i'
rsync -a --exclude __pycache__ panel spark:/tmp/tfpanel-i/
ssh spark 'cd /tmp/tfpanel-i && python3 -m unittest panel.tests.test_poller 2>&1 | tail -3 && python3 -m panel.poller --seconds 6 --every 1 --brief && python3 -m panel.poller --seconds 2 --every 1 > /tmp/tfpanel-i/out.jsonl && python3 -c "import json; d=json.loads(open(\"/tmp/tfpanel-i/out.jsonl\").readline()); print(len(d), sorted(d))"; rm -rf /tmp/tfpanel-i'
```

最后一条在 Spark 上对真实接口只读地跑 6 秒（这时别的执行者很可能正在用模型，所以你多半能看到 `decode` 或 `prefill` 的行，这是正常的）。通过的标准：测试是 `OK`；`--brief` 打印了 4 到 8 行简短状态（行数不要求精确）；没有 Python 的 Traceback；最后一行以 `14` 开头，后面是快照的 14 个顶层键。

实现上的两点要求：退出前的收尾（`usage.flush()`）必须能执行到，不要用 `os._exit`；标准输出被对方提前关闭（`BrokenPipeError`）时安静退出即可。
