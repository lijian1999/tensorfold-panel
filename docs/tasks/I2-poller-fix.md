# 任务 I2：轮询收尾（小修）

先读 `AGENTS.md`。`panel/poller.py` 和 `panel/tests/test_poller.py` 上一位执行者已经写好，16 个测试全部通过。编排者通读代码后发现下面四处问题，本任务只修这四处并补对应的测试，**不要重写，不要改别的地方**。任务 I 的完整要求在 `docs/tasks/I-poller.md`，需要时查阅。

## 第一步：看现状

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_poller 2>&1 | tail -3
```

应是 16 个测试 `OK`。

## 第二步：修 `panel/poller.py` 的四处

1. **模型名拿到后没有记下来。** `tick()` 里 `model = self._call(self.fetcher.model_name)` 之后，`self._model` 从来没被赋值，所以每 5 秒就会再读一次 `/v1/models`，永远不停。改成：读到的 `model` 是非空字符串时 `self._model = model`。
2. **`run()` 跳过了内容相同的快照。** 现在只有 `snapshot != prev` 时才调用 `on_snapshot`。按说明应当每次 `tick` 之后都调用一次（窗口程序要靠它带着当前时刻刷新，例如空闲 30 分钟后调暗）。删掉 `prev` 和 `_MISSING` 相关的判断，每次都调。
3. **`main()` 里的 `_feed_usage` 是多余的。** 采集器（`Collector`）在 `feed` 里已经记账了，快照里也没有 `prompt`、`cached` 这些键。删掉 `_feed_usage` 函数和对它的调用。顺手删掉没用到的导入（`js_round`）。
4. **`brief_line` 里“本轮”那一项写错了。** 说明的格式是 `round=<已完成请求数>+<进行中请求数>`，即 `round.requests` 和 `round.running`；现在第二个数用的是 `output_tokens`。改成 `running`。

另外一处小改：`main()` 里捕获到 `BrokenPipeError` 时，在 `break` 之前加一行把标准输出指到空设备，免得解释器退出时再报一次：

```python
os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
```

（`import os, sys` 放到文件开头。）不要用 `os._exit`，`finally` 里的 `usage.flush()` 必须能执行到。

改完运行：

```sh
python3 -m unittest panel.tests.test_poller 2>&1 | tail -6
```

这时可能有个别旧测试因为第 2 条（现在每次都调 `on_snapshot`）而需要调整期望值：只调整和这四处直接相关的断言。

## 第三步：补 4 个测试（加在 `panel/tests/test_poller.py` 里，沿用文件里已有的假对象）

1. 模型名：假 `fetcher.model_name()` 第一次就返回 `"M"`；之后把假时钟一共拨过 12 秒、期间每 0.25 秒 `tick` 一次：`model_name()` 总共只被调用 1 次。
2. `run()`：假 `collector` 每次都返回**同一个内容**的空闲快照；`on_snapshot` 在第 3 次被调用时 `stop_event.set()`：`on_snapshot` 恰好被调用 3 次，`run` 返回。
3. `brief_line`：传 `{"state": "decode", "lanes": {"decoding": 2, "prefilling": 1, "waiting": 0}, "decode": {"tps": 112.4}, "prefill": {"filled_tokens": 10240, "prompt_tokens": 24615}, "round": {"requests": 3, "running": 3, "output_tokens": 999}, "today": {"requests": 98, "cost": 0.597}}`，结果以 `decode 2/1/0 tps=112.4 pf=10240/24615 round=3+3 today=98req` 开头。
4. `brief_line({})` 和 `brief_line(None)` 不抛异常，结果以 `idle 0/0/0 - - -` 开头。

```sh
python3 -m unittest panel.tests.test_poller -v 2>&1 | tail -30
grep -n "_feed_usage\|_MISSING\|js_round\|os\._exit" panel/poller.py; echo "（上一行之前应没有任何输出）"
```

测试应是 20 个左右、全部 `ok`。

## 第四步：在 Spark 上检查

```sh
cd /Users/kris/projects/tensorfold-panel
ssh spark 'rm -rf /tmp/tfpanel-i && mkdir -p /tmp/tfpanel-i'
rsync -a --exclude __pycache__ panel spark:/tmp/tfpanel-i/
ssh spark 'cd /tmp/tfpanel-i && python3 -m unittest panel.tests.test_poller 2>&1 | tail -3 && python3 -m panel.poller --seconds 6 --every 1 --brief && python3 -m panel.poller --seconds 2 --every 1 > /tmp/tfpanel-i/out.jsonl && python3 -c "import json; d=json.loads(open(\"/tmp/tfpanel-i/out.jsonl\").readline()); print(len(d), sorted(d))"; rm -rf /tmp/tfpanel-i'
```

通过的标准：测试是 `OK`；`--brief` 打印了 4 到 8 行（行数不要求精确，内容是 `idle …`、`decode …` 或 `prefill …` 都正常）；没有 Python 的 Traceback；最后一行以 `14` 开头。

四步都通过就结束，最后一行输出 `DONE`。
