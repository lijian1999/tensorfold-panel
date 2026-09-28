# 任务 F1：采集器直接数引擎生成的 token（Python）

先读 `AGENTS.md`，再读 `collector/tfpanel.py` 全文和 `collector/tests/test_tfpanel.py`。本任务只改这两个文件。

## 背景（已由编排者核实）

现在采集器靠 `on_delta` 推送的文字换算 token 数。但 TensorFold 推送工具调用时，**数组 / 对象类型的参数会缓存到整个值写完才一次性推出**（例如编程代理 `edit` 工具的 `edits` 数组）。模型写这段参数的几秒里其实一直在生成，采集器却收不到任何文字：实时速度掉到 0，“平均”往下掉，最后文字一次性涌入又造成虚高的峰值。

TensorFold 的真实结构（v0.3.4 源码，照此实现）：

- `tensorfold.server.app` 模块里有 `Scheduler`（从 `tensorfold.server.scheduler` 导入到 app 模块的名字空间，`module.Scheduler` 就是那个类）。
- `ChatApp.chat()` 在**请求线程里同步**调用 `self.scheduler.submit(job)`，签名 `def submit(self, job: ChatJob) -> None`。同一个请求被抢占重跑时，会在同一线程里用新的 `job` 再调用一次 `submit`，新 job 从头生成，前面已经数过的 token 会重新生成一遍。`submit` 也会在其他线程被调用（预热），这些要忽略。
- `job.stream` 在 job 被调度器接纳之前是 `None`，之后是一个 `LaneStream`；引擎每生成一个 token 就 `job.stream.emitted.append(token)`（Python 列表，只增不减，**包括**工具调用、思考内容、结束符，和引擎成绩单里的 `completion_tokens` 计数方式一致）。

## 改动

### 1. 包装 `Scheduler.submit`

在 `patch_chat_app` 里，chat 补丁成功之后、和包装 `render` 同样的方式**尽力**包装 `module.Scheduler.submit`：

- `module` 上没有 `Scheduler`，或 `Scheduler.submit` 不可调用 → 不包，`hooks["tokens"] = "missing"`，chat 补丁照常生效，函数仍返回 `True`。
- 否则用 `functools.wraps` 包装：
  ```
  def wrapped_submit(self, *args, **kwargs):
      尽力（任何异常都吞掉）：
          req = getattr(_TLS, "req", None)
          job = args[0] if args else kwargs.get("job")
          若 req 和 job 都不是 None：collector.attach_job(req, job)
      return original_submit(self, *args, **kwargs)   # 参数原样、返回值原样、异常原样抛出
  ```
  然后 `hooks["tokens"] = "ok"`。
- `run_self_check` 走“不通过”分支时同时设 `hooks["tokens"] = "missing"`；`main()` 初始 `hooks` 改为 `{"chat": state, "render": state, "tokens": state}`。

### 2. 请求记录

`_Request` 新增字段（加进 `__slots__`）：

- `job`：最近一次 attach 的 job，初始 `None`；
- `job_seen`：已经计入的引擎 token 数，初始 `0`；
- `first_token_time`：换算线程第一次看到引擎 token 数 > 0 的时刻，初始 `None`。

`Collector.attach_job(req, job)`：在 `self._lock` 内设 `req.job = job`。**不要**重置 `job_seen`（抢占重跑时新 job 会把已数过的 token 重新生成一遍，只有超过 `job_seen` 的部分才是新的）。

### 3. 换算线程 `_convert(req, now)`

- **引擎计数模式**（`req.job is not None`）：
  - 尽力读 `n = len(req.job.stream.emitted)`；`stream` 为 `None` 时 `n = 0`；读取出任何异常就当作本次没有新 token（不退回文字换算，下次 tick 再读）。
  - `new = n − req.job_seen`；`new > 0` 时：用现有 `_add_event(req, now, new, now)` 记一个事件（时间 = 本次 tick 的 `now`），`req.job_seen = n`；`req.first_token_time` 为 `None` 时设为 `now`。
  - 丢弃 `req.deltas` 里积压的文字（在锁内清空，`consumed` 归零），**不调用分词器**。
- **文字换算模式**（`req.job is None`）：完全保持现在的逻辑。
- 峰值更新保持现在的规则，只是“解码开始时刻”改用下面的 `_decode_start(req)`。

### 4. 解码开始时刻

新增 `_decode_start(req)`：`first_delta_time` 和 `first_token_time` 里非 `None` 的最小值；都为 `None` 时返回 `None`。以下各处把原来用 `req.first_delta_time` 判断 / 计算的地方全部改用 `_decode_start(req)`：

- `state()`：当前请求 `_decode_start(req)` 非 `None` → `decode`，否则 `prefill`；
- `snapshot()` 里 `ttft_s` = `_decode_start(req) − req.start_time`，以及 prefill / decode 分支的判断；
- `_decode_tps`、`_decode_avg`、峰值的 1 秒门槛。

`delta()` 里记录 `first_delta_time` 的逻辑不变。

### 5. 不变的部分

`/metrics` 的字段和含义不变（`output_tokens` 在引擎计数模式下就是精确值）；`finish` / `fail` / 一轮统计 / `render` 包装都不变。输出里仍然绝不包含对话文字。

## 测试要求（加到 collector/tests/test_tfpanel.py，现有测试一条都不能删改；只有断言 `hooks` 整体等于某个字典的地方，如果因为多了 `tokens` 键而失败，可以把期望字典补上 `"tokens"`）

假 TensorFold 模块里加一个 `Scheduler` 类（有 `submit(self, job)` 方法），假 `ChatApp` 持有一个 `Scheduler` 实例，假 `chat` 里调用 `self.scheduler.submit(job)`；假 `job` 有 `stream` 属性（先为 `None`，之后换成带 `emitted` 列表的对象）。用注入的假时钟、`start_worker=False`、直接调用 `tick(now)`。为了在 chat 执行“中途”检查，可以让假 chat 在内部回调测试提供的函数，或用 `threading.Event` 在另一个线程里跑 chat。至少覆盖：

1. 打补丁后 `hooks["tokens"] == "ok"`；`submit` 的参数原样传入、返回值是同一个对象、原 `submit` 抛出的异常原样抛出。
2. 没有任何 `on_delta` 文字、只有 `emitted` 增长到 10 → `tick` 后 `current["output_tokens"] == 10`，`state() == "decode"`。
3. 模拟工具调用缓存：`emitted` 每 0.5 秒增长 50，持续 3 秒且没有任何文字增量 → 每次 `tick` 后 `decode_tps > 0`，3 秒时 `decode_tps == 100.0`（2.5 秒窗口 250 个 ÷ 2.5）。
4. 引擎计数模式下，之后涌入大段 `on_delta` 文字 → 分词器 `encode` 一次都没被调用（假 tokenizer 记调用次数），`output_tokens` 不变，峰值不出现尖峰。
5. `job.stream` 为 `None` → `tick` 不报错，`output_tokens == 0`，仍为 `prefill`。
6. 抢占重跑：第一个 job 的 `emitted` 到 30 后 attach 第二个 job，第二个 job 的 `emitted` 从 0 涨到 45 → `output_tokens == 45`（不是 75）；涨到 20 时 `output_tokens` 仍是 30。
7. 在另一个线程（没有进行中的 chat）调用 `submit` → 不 attach 到任何请求。
8. 模块里没有 `Scheduler` → `hooks["tokens"] == "missing"`，按文字换算的现有行为不变（现有测试已覆盖的话，加一条断言即可）。
9. 自检不通过 → `hooks["tokens"] == "missing"`。
10. `ttft_s`：先到文字增量再有引擎 token → 用文字增量的时刻；没有文字、只有引擎 token → 用第一次看到 token 的 tick 时刻。
11. 读 `emitted` 抛异常（例如 `stream` 是一个访问 `emitted` 会抛错的对象）→ `tick` 不报错，请求照常完成。

## 完成前必须运行并全部通过

```sh
cd collector && ~/.local/share/uv/tools/tensorfold/bin/python -m unittest discover -s tests -v
~/.local/share/uv/tools/tensorfold/bin/python -c "import ast,sys; ast.parse(open('collector/tfpanel.py').read())"
```

不要运行 `collector/tfpanel serve ...`，不要启动、停止或重启 TensorFold，不要修改 `~/.local/share/uv/tools/tensorfold/` 下的任何文件。真实联调由编排者来做。
