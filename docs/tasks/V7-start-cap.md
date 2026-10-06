# 任务 V7：适配器的起点回推改成“不早于流表变空的时刻”

先读 `AGENTS.md`。本任务改两个文件：`panel/engine.py`、`panel/tests/test_engine.py`。不要改别的文件，不需要在 Spark 上运行任何东西。

## 背景

`VllmAdapter.feed` 的“到达”那一步（`_step_arrive`）给独自出现的新请求回推开始时刻。现在的条件是“流表是空的，并且已经空了至少 0.25 秒”才回推。实机上发现这个条件不对：一个请求结束后，轮询按空闲的节奏 0.25 秒读一次，紧跟着发出的下一个请求正好在 0.25 秒后的那次读数里出现，于是被回推了 0.7 秒，开始时刻比上一个请求结束还早，预填充进度一出现就是 99%。

正确的约束是：流表是空的时候出现的请求，它的开始时刻不可能早于流表变空的那一刻。所以改成“回推的秒数不超过流表已经空了多久”。`fixtures/vllm/seq-round.json` 里的 `checkpoints` 已经按新规则更新（只有两行的 `start` 变了），现有的 `TestSingle` 里 `round` 那个测试因此是失败的，改完 `engine.py` 它应该通过。

## 第一步：改 `_step_arrive`

“到达”一步里 `dq > 0` 时新建的每一行，`start` 和 `solo` 改成这样算（别的不变）：

- `was_empty` = 新建这些行之前流表是空的。
- `gap` = `empty_since` 是 `None` 时为 `None`，否则 `now - empty_since`。
- `start`：`was_empty` 为假 → `now`。为真 → `now - back`，其中 `back = min((prompt - cached) / tps, lag)`；`gap` 不是 `None` 时再取 `back = min(back, gap)`。
- `solo` = `was_empty` 且 `n == 1` 且（`gap` 是 `None` 或 `gap >= 1.0`）。

也就是：原来的“已经空了至少 0.25 秒”这个条件去掉了；回推多了一个上限 `gap`；`solo`（决定这一行出首字时要不要用来更新 `lag`）要求空了至少 1 秒。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_engine 2>&1 | tail -1
```

应输出 `OK`。

## 第二步：补测试

`panel/tests/test_engine.py` 的 `TestEdges` 里加一个测试方法 `test_start_not_before_empty`。先造四份读数：

```python
Z = dict(running=0, waiting=0, queries=0, hits=0, prompt=0, prompt_cached=0, ttft_sum=0.0, ttft_count=0,
         generation=0, success=0, req_prompt_sum=0, req_generation_sum=0, req_computed_sum=0,
         prefill_s=0.0, decode_s=0.0, drafted=0, accepted=0, epoch=1.0)
m1 = dict(Z, running=1, queries=100, prompt=100, ttft_count=1, ttft_sum=0.1, generation=1)       # 一个短请求出首字
m2 = dict(Z, queries=100, prompt=100, ttft_count=1, ttft_sum=0.1, generation=5, success=1,
          req_prompt_sum=100, req_generation_sum=5, req_computed_sum=100)                         # 它结束了
m3 = dict(m2, running=1, queries=23100)                                                           # 又来一个 23000 token 的
```

对 `t3` 取 `10.75`、`11.7`、`13.5` 三种情况，各用一个新建的适配器依次 `feed(1.0, Z)`、`feed(10.0, m1)`、`feed(10.5, m2)`、`feed(t3, m3)`，之后 `rows()` 恰好一行，`phase` 是 `"prefill"`，`prompt` 是 23000，`start` 分别约等于 `10.5`、`10.5`、`11.5`（误差 0.001）：前两种被“流表在 10.5 变空”卡住，第三种空了 3 秒，照常回推 2 秒（`lag` 的初始值）。

再加一种：新建适配器 `feed(1.0, Z)`、`feed(13.5, dict(Z, running=1, queries=23000))`，那一行的 `start` 约等于 `11.5`（从没有过请求，`empty_since` 是 `None`，照常回推）。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_engine 2>&1 | tail -1
git diff --numstat -- panel/tests/test_engine.py
```

通过的标准：第一条输出 `OK`；第二条的第二列（删除的行数）是 `0`。全部通过后最后一行输出 `DONE`。
