# 任务 V3：采集器和今日用量认 vLLM 的几个可选字段

先读 `AGENTS.md`，再读接口约定 `docs/tasks/V-contracts.md` 的第 3、5、6 节。本任务改四个文件：`panel/collector.py`、`panel/usage.py`、`panel/tests/test_collector.py`、`panel/tests/test_usage.py`。不要改别的文件。不需要在 Spark 上运行任何东西。

## 背景

副屏程序要同时支持 TensorFold 和 vLLM。vLLM 的读数会由一个适配器（别的任务在写）换算成和 TensorFold `/health` 同样格式的字典，再喂给采集器，所以采集器的主路径两种引擎共用。vLLM 的读数比 TensorFold 多几个可选键（约定第 3 节），每条流的行里没有 `filled`、多了 `start` 和 `ttft_s`。这个任务让采集器和账本认这些键。

所有改动都是“键存在才生效”：TensorFold 的读数里没有这些键，行为必须和现在完全一样。**两个测试文件里现有的测试一行都不能改**，只能在文件末尾（`if __name__` 之前）加新的测试类。

同时有别的执行者在改 `panel/` 下的其他文件。所以检查命令只跑下面写的这两个测试模块，不要跑全部测试。

## 第一步：快照加 `engine` 和 `prefill.estimated`，采集器加 `prefill_tps` 属性

`panel/collector.py`：

1. `__init__` 里加 `self._engine = None`。`_on_read` 里：`health.get("backend")` 是非空字符串时 `self._engine` 取它。
2. `_blank_snapshot` 的字典在 `"hook"` 后面加 `"engine": self._engine`。离线快照也是从 `_blank_snapshot` 来的，所以离线时自然沿用最近一次的值。
3. 两处拼 `prefill` 字典的地方（`_prefill_section` 的降级分支、`_prefill_from_hook`）都在最后加 `"estimated": False`。
4. 加只读属性 `prefill_tps`，返回 `self._prefill_tps`。

`panel/tests/test_collector.py` 文件末尾加测试类 `TestEngineField`：

- 新建的采集器 `prefill_tps == 2300.0`。
- 喂 `health(**BASE)`（没有 `backend`）→ 快照 `engine` 是 `None`；再喂 `dict(health(**BASE), backend="tensorfold")` → `"tensorfold"`；接着连喂 3 次 `None` → 三份快照的 `engine` 都还是 `"tensorfold"`，第 3 份的 `state` 是 `"offline"`。
- 外挂好用的预填充（照 `TestHookPrefill.test_一条预填充流` 的喂法喂到 10.5）和外挂失效的预填充（照 `TestNoHookPrefill` 的喂法）：`prefill["estimated"] is False`。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_collector 2>&1 | tail -1
```

应输出 `OK`（现有的 `test_顶层键和原型一致` 现在也应该通过：`fixtures/idle.json` 里已经有 `engine` 键）。

## 第二步：采集器认 vLLM 的可选键

在 `_on_read` 开头和其他累计值一起取出三样（取不到都当作没有）：

- `epoch`：`health.get("epoch")` 是数字（`bool` 不算）才用，否则 `None`。
- `aborted`：`int(_number(health, "aborted_total"))`。
- `finished_c`：`health.get("completion_finished_total")` 是数字（`bool` 不算）才用，否则 `None`。

这三样也记进 `_Prev`（“上次”的值）。然后改这几处：

| 位置 | 现在 | 改成 |
| --- | --- | --- |
| 2.1 记账 | 把 `{"prompt", "cached", "completion", "requests"}` 四个累计值交给账本 | `health.get("usage_totals")` 是字典时，这四项改从它里面取；否则照旧。`epoch` 不是 `None` 时再加一个键 `"epoch": epoch`（是 `None` 时不加这个键） |
| 2.2 重启判断 | `requests` 或 `c` 变小 | 原条件，或者“这次和上次的 `epoch` 都不是 `None` 且不相等” |
| 2.4 请求结束时的输出 | `_on_finish` 里按 `survivors` 分两种估算 | 这次和上次的 `finished_c` 都不是 `None` 时：`completion = max(0, int(这次 - 上次))`，两种估算都跳过；`survivors > 0` 且 `busy` 不是 `None` 时照旧做 `busy["used"] += completion`。有一边是 `None` 时照旧 |
| 2.5 到达计数 | `arrive = requests + requests_running` | `arrive = requests + requests_running + aborted` |
| 2.5 中途断开 | 没有 | 不是重启那次、有上次、`aborted` 比上次的大、并且 `self._round` 不是 `None` → `self._round["end"] = now` |
| 2.7 流表 | 新出现的 id 的 `start` 取到达时刻 | 行里的 `start` 是数字（`bool` 不算）时，这条流的 `start` 就用它（新出现的 id 和已有的 id 都这样，每次读数都更新）；不是数字照旧 |
| 2.9 解码段的 `ttft_s` | 按忙碌段估算 | 先照旧估算；然后如果 `self._rows` 恰好一行、`self._running == 1`、这一行的 `ttft_s` 是数字（`bool` 不算），就改用这一行的 `ttft_s` |
| 2.10 预填充（外挂行） | `_prefill_from_hook` 用各行的 `filled` | 正在预填充的行里有任何一行没有 `"filled"` 这个键时走“估算”，见下 |

`_prefill_from_hook` 的估算分支（`rows` 非空且有行没有 `filled` 键）：`prompt`、`cached`、`elapsed`、`est`、`cache_miss` 的算法不变，另外四项改成：

- `filled_tokens = cached + js_round((prompt - cached) * frac)`，其中 `frac = min(0.99, elapsed / est)`（`est <= 0` 时 `frac = 0.99`）
- `tps = self._prefill_tps`
- `remaining_s = max(0.0, est - elapsed)`
- `estimated = True`

`panel/tests/test_collector.py` 文件末尾先放下面这段辅助代码（原样用）：

```python
def vhealth(running=0, dec=0, pre=0, total=20, c=2000, prompt=160000, cached=30000, prefill_s=60.0,
            decode_s=61.0, drafted=5000, accepted=1300, maximum=4, epoch=1000.0, aborted=0,
            finished_c=1900, usage=None, rows=()):
    """造一份 vLLM 适配器给出的统一读数（空闲基线：结束过 20 个请求）。"""
    return {
        "ok": True, "backend": "vllm", "requests_running": running,
        "streams": {"decoding": dec, "prefilling": pre, "max": maximum},
        "requests_total": total, "completion_tokens_total": c, "prompt_tokens_total": prompt,
        "cached_tokens_total": cached, "prefill_seconds_total": prefill_s, "decode_seconds_total": decode_s,
        "drafted_total": drafted, "accepted_total": accepted, "context_length": 262144,
        "epoch": epoch, "aborted_total": aborted, "completion_finished_total": finished_c,
        "usage_totals": usage or {"prompt": 160100, "cached": 30000, "completion": c, "requests": total},
        "tfpanel": {"v": 1, "streams": list(rows)},
    }


def vmetrics(ttft_sum=60.0, ttft_count=20):
    return {"waiting": 0, "kv_usage": [], "ttft_sum": ttft_sum, "ttft_count": ttft_count}


def vrow(sid, phase, prompt, cached=0, output=0, start=0.0, ttft=None):
    """vLLM 适配器合成的一行：没有 filled，有 start 和 ttft_s。"""
    return {"id": sid, "phase": phase, "prompt": prompt, "cached": cached, "output": output,
            "start": start, "ttft_s": ttft}


def vllm_long_scene(usage=None):
    """一个 24085 token 的请求：1.5 开始，3.5 才第一次被读到，10.4 出首字，13.5 结束，输出 160。"""
    collector = Collector(Config(), usage)
    scene = Scene(collector)
    scene.at(1.0, vhealth(), vmetrics())
    for t in every_tenth(3.5, 10.3):
        scene.at(t, vhealth(running=1, pre=1, rows=[vrow(1, "prefill", 24085, start=1.5)]), vmetrics())
    n = 0
    for t in every_tenth(10.4, 13.4):
        n += 5
        scene.at(t, vhealth(running=1, dec=1, c=2000 + n,
                            rows=[vrow(1, "decode", 24085, output=n, start=1.06, ttft=9.34)],
                            usage={"prompt": 184185, "cached": 30000, "completion": 2000 + n, "requests": 20}),
                 vmetrics())
    scene.at(13.5, vhealth(total=21, c=2160, prompt=184085, prefill_s=69.284, decode_s=64.155,
                           drafted=5420, accepted=1401, finished_c=2060,
                           usage={"prompt": 184185, "cached": 30000, "completion": 2160, "requests": 21}),
             vmetrics(69.34, 21))
    return collector, scene
```

再加下面四个测试类。

`TestVllmSingle`（都用 `vllm_long_scene`）：

- 3.5 的快照：`state` 是 `"prefill"`，`hook` 是 `"ok"`，`engine` 是 `"vllm"`，`lanes["max"]` 是 4；`prefill` 里 `estimated is True`、`elapsed_s` 约 2.0（从行里的 `start` 算，不是从第一次读到算）、`prompt_tokens` 24085、`cached_tokens` 0、`est_s` 约 `24085 / 2300`、`filled_tokens` 4600、`tps` 2300.0、`remaining_s` 约 `24085 / 2300 - 2.0`、`cache_miss is False`。
- 10.3 的快照：`prefill["filled_tokens"]` 是 20240，`elapsed_s` 约 8.8。
- 进度封顶：另建一个采集器，1.0 喂 `vhealth()`，然后 3.5 到 40.0 每 0.5 秒喂一次同样的预填充读数（`start=1.5`）：40.0 的 `filled_tokens` 是 `js_round(24085 * 0.99)`（23844），`remaining_s` 是 0.0。
- 11.0 的快照：`state` 是 `"decode"`，`decode["ttft_s"]` 是 9.34（行里给的，不是估算的 6.9），`decode["output_tokens"]` 是 35，`context_used` 是 24120。
- 13.5 的快照：`state` 是 `"done"`；`last` 里 `prompt_tokens` 24085、`cached_tokens` 0、`completion_tokens` 160、`decode_tps` 约 `160 / 3.155`、`prefill_tps` 约 `24085 / 9.284`、`ttft_s` 约 9.34、`acceptance_rate` 约 `101 / 420`、`context_used` 24245。之后 `collector.prefill_tps` 约 `0.7 * 2300 + 0.3 * 24085 / 9.284`。
- 记账：给 `vllm_long_scene` 传一个 `FakeUsage()`，它收到的第一份是 `{"prompt": 160100, "cached": 30000, "completion": 2000, "requests": 20, "epoch": 1000.0}`，最后一份是 `{"prompt": 184185, "cached": 30000, "completion": 2160, "requests": 21, "epoch": 1000.0}`。

`TestVllmFinishExact`：并发时结束的那个请求的输出用准数。1.0 喂 `vhealth()`；2.0 喂 `vhealth(running=2, dec=2, c=2287, rows=[vrow(1, "decode", 71, output=170, ttft=0.13), vrow(2, "decode", 3066, output=117, ttft=1.25)])`；2.1 喂 `vhealth(running=1, dec=1, total=21, c=2300, prompt=163066, prefill_s=61.21, decode_s=63.83, finished_c=2050, rows=[vrow(1, "decode", 71, output=250, ttft=0.13)])`，三次的 `metrics` 分别是 `vmetrics()`、`vmetrics()`、`vmetrics(61.25, 21)`。2.1 的快照 `last["completion_tokens"]` 是 150（不是行里估的 117），`last["prompt_tokens"]` 是 3066，`last["ttft_s"]` 约 1.25，`state` 是 `"decode"`。

`TestVllmAbort`：1.0 喂 `vhealth()`；10.0 到 19.9 每 0.1 秒喂 `vhealth(running=1, dec=1, c=2000 + k, rows=[vrow(1, "decode", 67, output=k, start=9.9, ttft=0.13)])`，`k` 是 `int(round((t - 10) * 10))`；20.0 喂 `vhealth(c=2100, aborted=1)`（在跑数归零，结束数没变）。`metrics` 都是 `vmetrics()`。

- 20.0 的快照：`state` 是 `"idle"`（没有完成画面），`last` 是 `None`，`lanes` 的 `decoding`、`prefilling` 都是 0，`round["requests"]` 是 0、`round["running"]` 是 0、`round["output_tokens"]` 是 100。
- 接着 75.0、81.0 各喂一次 `vhealth(c=2100, aborted=1)`：75.0 的 `round["active"]` 是 `True`（一轮的最后活动时刻是断开的 20.0，不是这一轮开始的 10.0），81.0 的是 `False`。
- 再来一个正常的请求：90.0 喂 `vhealth(running=1, dec=1, c=2110, aborted=1, rows=[vrow(2, "decode", 65, output=10, start=89.9, ttft=0.12)])`，90.5 喂 `vhealth(total=21, c=2140, aborted=1, prompt=160065, prefill_s=60.1, decode_s=61.6, finished_c=1940)` 配 `vmetrics(60.12, 21)`。90.5 的快照：`state` 是 `"done"`，`last["completion_tokens"]` 是 40、`last["prompt_tokens"]` 是 65、`last["ttft_s"]` 约 0.12，`round["requests"]` 是 1、`round["output_tokens"]` 是 40。

`TestVllmRestart`：1.0 喂 `vhealth()`；2.0 喂 `vhealth(running=1, dec=1, c=2010, rows=[vrow(1, "decode", 67, output=10, ttft=0.1)])`；2.1 喂 `vhealth(total=30, c=5000, prompt=200000, finished_c=4900, epoch=2000.0)`（累计值都变大了，只有 `epoch` 变了）。2.1 的快照：`state` 是 `"idle"`（不是 `"done"`），`round` 是 `None`，`last` 是 `None`，`engine` 是 `"vllm"`。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_collector 2>&1 | tail -1
```

应输出 `OK`。

## 第三步：账本认引擎启动标记

`panel/usage.py`：

1. 多记一项 `self._last_epoch`（初始 `None`）：上次读数的引擎启动标记。
2. `update(totals)`：`epoch = totals.get("epoch")`，是数字（`bool` 不算）才用，否则 `None`。算增量的规则改成：
   - 还没有基线（`_last_totals` 是 `None`）→ 照旧，只记基线。
   - `epoch != self._last_epoch`（包括一边是 `None` 一边不是）→ 当作引擎重启或换了引擎：这次的四个累计值整个算作增量。
   - 否则照旧（有累计值变小 → 整个算增量；不然算差）。
3. `_last_totals` 只存 `prompt`、`cached`、`completion`、`requests` 四个键（不把 `epoch` 存进去）；`_last_epoch` 记成这次的 `epoch`。`epoch` 和上次不同时也要把“待写”标记置上。
4. 写文件：`_last_epoch` 不是 `None` 时在 `last_totals` 后面多写一个键 `"last_epoch"`；是 `None` 时不写这个键（这样只用 TensorFold 时文件内容和现在一模一样）。
5. 读文件：`last_epoch` 是数字就采用，没有这个键或不是数字按 `None`。

`panel/tests/test_usage.py` 文件末尾加测试类 `TestEpoch(LedgerTest)`（用文件里现成的 `TOTALS`、`BIGGER`；下面每一条是一个测试方法，各自新建账本）：

- 第一次 `update(dict(TOTALS, epoch=1000.0))`：今日四项都是 0；文件里 `last_epoch` 是 1000.0，`last_totals` 等于 `TOTALS`（恰好四个键）。
- 同一个标记：再 `update(dict(BIGGER, epoch=1000.0))` → 今日 `prompt_tokens` 500、`cached_tokens` 200、`completion_tokens` 30、`requests` 2。
- 标记变了：`TOTALS`（1000.0）之后 `update(dict(BIGGER, epoch=2000.0))` → 今日四项等于 `BIGGER` 的四项（1500、600、80、5），不是差。
- 有标记 → 没标记：`dict(TOTALS, epoch=1000.0)` 之后 `update(dict(BIGGER))` → 今日四项等于 `BIGGER` 的四项；`flush()` 后文件里没有 `last_epoch` 键。
- 没标记 → 有标记：`TOTALS` 之后 `update(dict(BIGGER, epoch=1000.0))` → 今日四项等于 `BIGGER` 的四项。
- 两边都没标记：`TOTALS` 之后 `BIGGER` → 今日是差（500、200、30、2）；文件里没有 `last_epoch` 键。
- 重新加载：`update(dict(TOTALS, epoch=1000.0))`、`flush()` 之后新建一个账本（同一个目录），`update(dict(BIGGER, epoch=1000.0))` → 今日是差（500、200、30、2）。
- `epoch` 不是数字（`"x"`、`True`）按没有标记处理：`TOTALS` 之后 `update(dict(BIGGER, epoch="x"))` → 今日是差。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_usage 2>&1 | tail -1
```

应输出 `OK`。

## 最后一步：收尾检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_collector panel.tests.test_usage 2>&1 | tail -1
git diff --numstat -- panel/tests/test_collector.py panel/tests/test_usage.py
```

通过的标准：第一条输出 `OK`；第二条两行的第二列（删除的行数）都是 `0`（现有测试一行没改）。全部通过后最后一行输出 `DONE`。
