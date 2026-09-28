# 任务 G1：采集器在预填充开始时拿到缓存命中、预计时间、缓存未命中判定（Python）

先读 `AGENTS.md`，再读 `docs/design.md` 里“每个指标怎么算”表格后面的三段：“预填充时的缓存命中怎么拿”“预填充预计时间”“缓存未命中”，以及“指标接口”里 `hooks`、`current` 两行。然后读 `collector/tfpanel.py` 全文和 `collector/tests/test_tfpanel.py`。本任务只改这两个文件。

## 背景（已由编排者对照 TensorFold v0.3.4.1 源码核实，照此实现）

- `tensorfold.server.app` 模块的名字空间里有 `LaneEngine` 类（`module.LaneEngine`）。调度线程在预填充前调用：
  ```python
  def add_stream(self, stream, *, cache=None, cached_tokens=0, checkpoints_at=()) -> None
  ```
  `stream.prompt_ids` 是完整提示 token 列表；`cache` 为 `None` 时表示没有可复用的缓存（此时引擎按 0 命中处理），否则前 `cached_tokens` 个 token 直接复用。
- `add_stream` 在**调度线程**里调用，不在请求线程里，所以不能用 `_TLS`。但调度器调用 `add_stream` 之前刚执行过 `job.stream = stream`，而 `Scheduler.submit` 包装（F1 已实现）已经把这个 `job` 记到了请求的 `req.job` 上。所以用 `req.job.stream is stream` 找到对应请求。
- job 上有两个 `float` 属性 `started_at`、`prefilled_at`（`time.perf_counter()` 时刻，没发生时为 `0.0`）：`prefilled_at − started_at` 就是不含排队的纯预填充秒数。

## 改动

### 1. 预填充时间模型 `PrefillModel`

模块级新增常量和类：

```python
PREFILL_DEFAULT_COEFS = (0.213, 1.048, 0.0162)   # 本机日志 148 个请求拟合
PREFILL_MAX_SAMPLES = 500
PREFILL_MIN_SAMPLES = 30
PREFILL_MIN_SPAN = 4000        # 样本里至少有一个新算 ≥ 这么多才重新拟合
```

`class PrefillModel`：

- `__init__(self)`：`self.coefs = PREFILL_DEFAULT_COEFS`（元组 `(a, b1, b2)`），`self._samples = deque(maxlen=PREFILL_MAX_SAMPLES)`，`self._lock = threading.Lock()`。
- 静态方法 `features(cached, new)` 返回 `(1.0, new / 1000.0, new * (cached + new / 2.0) / 1e6)`。
- `estimate(self, cached, new)`：`a*f0 + b1*f1 + b2*f2`（`f` 为 `features(cached, new)`），`round(…, 3)` 后返回 `float`。读 `self.coefs` 在锁内。
- `add_sample(self, cached, new, seconds)`：只有 `cached ≥ 0`、`new ≥ 1`、`seconds > 0` 且三者都是有限数（不是 bool）时才记；在锁内追加 `(cached, new, seconds)`，然后调用 `self._refit()`（仍在锁内）。
- `_refit(self)`（调用方持锁）：
  - 样本数 < `PREFILL_MIN_SAMPLES`，或所有样本的 `new` 都 < `PREFILL_MIN_SPAN` → 直接返回，系数不变。
  - 否则按普通最小二乘求 `(a, b1, b2)`：建 3×3 正规方程 `XᵀX · β = Xᵀy`（X 的每行是 `features(cached, new)`，y 是 `seconds`），用带部分主元的高斯消元解；主元绝对值 < 1e-12 视为奇异，直接返回、系数不变。
  - 解出的三个数都有限，且 `a ≥ 0`、`b1 > 0`、`b2 ≥ 0` 才赋给 `self.coefs`（元组）；否则系数不变。
  - 只用标准库，不要引入 numpy。

### 2. 请求记录

`_Request` 新增字段（加进 `__slots__`，初始值写在 `__init__`）：

- `prefill_cached = None`：预填充开始时的缓存命中 token 数；
- `prefill_est_s = None`：预计纯预填充秒数；
- `cache_miss = False`：是否判定缓存未命中。

### 3. `Collector`

- `__init__` 新增 `self.prefill_model = PrefillModel()`。
- 新增方法 `prefill_begin(self, stream, cached)`：
  1. 在 `self._lock` 内遍历 `self._requests.values()`，找出 `r.job is not None and getattr(r.job, "stream", None) is stream` 的那个请求；找不到就直接返回（例如预热、后台请求）。同时在锁内读出 `last = self.last`、`rnd = self._round`（`rnd` 取 `dict(self._round)` 的副本或 `None`）。
  2. 提示总长 `total`：尽力取 `len(stream.prompt_ids)`，出任何异常或结果不是正整数时用 `req.prompt_tokens`（仍在锁里读）；两者都拿不到 → `total = None`。`total` 不是 `None` 时调用 `self.set_prompt_tokens(req, total)`（它只在 `prompt_tokens` 还是 `None` 时生效）。
  3. `cached` 不是 int（或是 bool）时当 0；负数当 0；`total` 不是 `None` 时再夹到 `≤ total`。
  4. `total` 不是 `None` 时：`new = total − cached`，`est = self.prefill_model.estimate(cached, new)`；否则 `est = None`。
  5. 缓存未命中 `miss`：下面全部成立时为 `True`，否则 `False`（`M = PREFILL_MIN_SPAN`，也就是 4000）：
     - `total is not None`
     - `rnd is not None and rnd["requests"] >= 1`
     - `last is not None`，且 `prev = last.get("prompt_tokens")` 是 int 且 `prev >= M`
     - `total >= prev * 0.5`
     - `cached < prev * 0.5`
     - `total − cached >= M`
  6. 在 `self._lock` 内写 `req.prefill_cached = cached`、`req.prefill_est_s = est`、`req.cache_miss = miss`。同一请求再次进入（抢占重跑）时直接覆盖。
- `finish(self, req, reply=None)`：在现有逻辑之后**尽力**（任何异常都吞掉）记一个样本：
  - `job = req.job`；为 `None` 就不记。
  - `started = getattr(job, "started_at", 0.0)`，`prefilled = getattr(job, "prefilled_at", 0.0)`；两者都是数（不是 bool）、都 > 0、且 `prefilled > started` 才记。
  - `prompt = reply.get("prompt_tokens")`，`cached = reply.get("cached_tokens")`（reply 不是 dict 就不记）；两者都是 int（不是 bool）、`0 ≤ cached < prompt` 才记。
  - `self.prefill_model.add_sample(cached, prompt − cached, prefilled − started)`。
  - `fail()` 不记样本。

### 4. 包装 `LaneEngine.add_stream`

在 `patch_chat_app` 里，`Scheduler.submit` 包装之后，用同样的方式**尽力**包装 `module.LaneEngine.add_stream`：

- `module` 上没有 `LaneEngine`，或 `LaneEngine.add_stream` 不可调用 → 不包，`hooks["prefill"] = "missing"`，chat 补丁照常生效，函数仍返回 `True`。
- 否则用 `functools.wraps` 包装：
  ```
  def wrapped_add_stream(self, *args, **kwargs):
      尽力（任何异常都吞掉）：
          stream = args[0] if args else kwargs.get("stream")
          cached = kwargs.get("cached_tokens", 0) if kwargs.get("cache") is not None else 0
          若 stream 不是 None：collector.prefill_begin(stream, cached)
      return original_add_stream(self, *args, **kwargs)   # 参数原样、返回值原样、异常原样抛出
  ```
  然后 `hooks["prefill"] = "ok"`。包装过程本身出异常 → `hooks["prefill"] = "missing"`。
- `run_self_check` 走“不通过”分支时同时设 `hooks["prefill"] = "missing"`；`main()` 初始 `hooks` 改为 `{"chat": state, "render": state, "tokens": state, "prefill": state}`。

### 5. `/metrics`

`snapshot()` 的 `current` 新增三个键（在 `self._lock` 内读），预填充和解码时都输出：

- `"prefill_cached"`：整数或 `null`；
- `"prefill_est_s"`：浮点数（已 round 到 3 位）或 `null`；
- `"cache_miss"`：`true` / `false`。

`current` 里其他键、以及 `last`、`round`、`totals` 都不变。输出里仍然绝不能包含任何对话文字。

## 测试要求（加到 collector/tests/test_tfpanel.py，现有测试一条都不能删改；只有断言 `hooks` 整体等于某个字典的地方，如果因为多了 `prefill` 键而失败，可以把期望字典补上 `"prefill"`）

新增一个测试类 `TestPrefillCache`。假模块里加 `LaneEngine` 类（`add_stream(self, stream, *, cache=None, cached_tokens=0, checkpoints_at=())`，记下调用参数），假 `stream` 有 `prompt_ids` 列表，假 `job` 有 `stream`、`started_at`、`prefilled_at`。可以沿用 `make_scheduler_app_cls()` 的 `mid(self, job)` 回调写法：在 `mid` 里设 `job.stream = stream`，再**在另一个线程里**调用 `LaneEngine().add_stream(...)` 并 `join`，然后检查 `collector.snapshot()["current"]`。用注入的假时钟、`start_worker=False`。至少覆盖：

1. 打补丁后 `hooks["prefill"] == "ok"`；`add_stream` 的位置参数和关键字参数原样传入原方法，返回值是同一个对象，原方法抛出的异常原样抛出（同一对象）。
2. 提示 35012 个 token、`cache` 非 None、`cached_tokens=32768` → `current["prefill_cached"] == 32768`，`current["prefill_est_s"] == 3.797`，`current["cache_miss"] is False`。
3. `cache=None`、`cached_tokens=5000` → `prefill_cached == 0`，`prefill_est_s == PrefillModel().estimate(0, 35012)`。
4. 提示 41230、命中 0 → `prefill_est_s == 57.191`。
5. `stream` 不属于任何进行中的请求（例如不在 chat 里、或 `job.stream` 是另一个对象）→ 不报错，不影响任何请求，`current` 里三个键为 `None` / `None` / `False`。
6. `render` 没有记到提示长度时（`prompt_tokens is None`），`add_stream` 之后 `current["prompt_tokens"] == len(stream.prompt_ids)`；`render` 已经记了 100 时保持 100。
7. `stream.prompt_ids` 访问抛异常 → 用 `req.prompt_tokens` 算；两者都没有 → `prefill_cached` 照记，`prefill_est_s is None`，`cache_miss is False`，不报错。
8. `cached_tokens` 大于提示长度 → 夹到提示长度（`prefill_est_s == PrefillModel().estimate(total, 0)`）；`cached_tokens` 为负数或 `True` → 当 0。
9. 缓存未命中判定，全部通过 `collector.begin` / `finish(req, reply)` 真实走一遍“上一个请求”再测这一个（`finish` 的 reply 里给 `prompt_tokens`）：
   - 上一个 40120、这次 41230 命中 0 → `True`；
   - 上一个 40120、这次 41230 命中 32768 → `False`；
   - 上一个 3000（< 4000）、这次 41230 命中 0 → `False`；
   - 上一个 58804、这次 2090 命中 2048（后台短请求）→ `False`；
   - 上一个 40120、这次 18000 命中 0（这次提示不到上一个的一半）→ `False`；
   - 上一个 40120、这次 42000 命中 38500（新算 3500 < 4000）→ `False`；
   - 上一个请求完成后超过 `round_gap_s` 才开始这一个（新的一轮，`round.requests == 0`）→ `False`。
10. `snapshot()` 预填充时 `current` 含 `prefill_cached`、`prefill_est_s`、`cache_miss` 三个键，没有进入 `add_stream` 时为 `None` / `None` / `False`；解码时也有这三个键。
11. `PrefillModel`：
    - 默认系数下 `estimate(32768, 2244) == 3.797`、`estimate(0, 41230) == 57.191`、`estimate(16384, 2036) == 2.921`；
    - 用系数 `(0.5, 2.0, 0.03)` 按 `features` 生成 40 个精确样本（`cached` 取 0、8000、30000、60000 轮换，`new` 从 500 到 20000 分布，包括 ≥ 4000 的）后 `coefs` 三个值与 `(0.5, 2.0, 0.03)` 相差都 < 1e-6；
    - 29 个样本时系数不变；30 个样本但 `new` 全部 < 4000 时系数不变；
    - 让拟合出 `b1 ≤ 0` 的样本（例如 y 随 new 增大而减小）→ 系数不变；
    - 非法样本（`new == 0`、`seconds <= 0`、`seconds` 为 `nan`、参数是 bool）不记（`len(_samples)` 不变）；
    - 样本超过 500 个时只保留最近 500 个。
12. `finish` 记样本：job 的 `started_at=10.0`、`prefilled_at=13.5`，reply `prompt_tokens=20000`、`cached_tokens=16000` → `prefill_model._samples[-1] == (16000, 4000, 3.5)`；`prefilled_at == 0.0`、没有 job、reply 缺字段、`cached >= prompt` 时都不记；`fail()` 不记。
13. 模块里没有 `LaneEngine` → `hooks["prefill"] == "missing"`，chat / render / tokens 照常 `"ok"`；自检不通过 → `hooks["prefill"] == "missing"`。

## 完成前必须运行并全部通过

```sh
cd collector && ~/.local/share/uv/tools/tensorfold/bin/python -m unittest discover -s tests -v
~/.local/share/uv/tools/tensorfold/bin/python -c "import ast,sys; ast.parse(open('collector/tfpanel.py').read())"
```

不要运行 `collector/tfpanel serve ...`，不要启动、停止或重启 TensorFold，不要修改 `~/.local/share/uv/tools/tensorfold/` 下的任何文件。真实联调由编排者来做。
