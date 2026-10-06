# 任务 V2：vLLM 适配器 `VllmAdapter`（计数器 → 统一读数 + 每条流明细）

先读 `AGENTS.md`，再读接口约定 `docs/tasks/V-contracts.md` 的第 2、3、4、8 节。本任务新建两个文件：`panel/engine.py`、`panel/tests/test_engine.py`。不要改别的文件。只写 `VllmAdapter` 这一个类，约定第 4 节里的 `EngineReader` 不在本任务里。不需要在 Spark 上运行任何东西。

## 背景

vLLM 的 `/metrics` 只有全局计数器，没有“每条流现在怎么样”。适配器是一个小状态机：记住上一次的读数，按这一次和上一次的差推出“来了几个请求、几个出了首字、几个结束了、几个中途断开了”，维护一张**流表**（每个在跑的请求一行），再把读数换算成和 TensorFold `/health` 同样格式的字典。

输入是 `parse_vllm_metrics` 的结果（下面叫 `m`，上一次的叫 `p`），输出是约定第 3 节的 `(health, metrics)`。`fixtures/vllm/seq-*.json` 是在真实 vLLM 上录下来的 10 段读数序列，每段都带流表应有的状态（`checkpoints`），实现对不对用它们来核对。

同时有别的执行者在改 `panel/` 下的其他文件。所以检查命令只跑 `panel.tests.test_engine`，不要跑全部测试。`panel/engine.py` 只用标准库，不 import `panel` 里别的模块。

## 状态

适配器记住这些东西（`reset()` 把它们全部恢复成初始值）：

| 名字 | 初始值 | 含义 |
| --- | --- | --- |
| `prev` | `None` | 上一次的读数 `p` |
| 流表 | 空列表 | 按到达先后排的行；新行总是加在末尾 |
| 下一个 `id` | 1 | 每新建一行用掉一个，行被删掉也不回收 |
| `peak` | 0 | 见过的 `running` 的最大值 |
| `aborted` | 0 | 中途断开的累计次数 |
| `done_ttft_sum`、`done_ttft_count` | 0.0、0 | 已结束请求的首字时间之和、个数 |
| `lag` | 2.0 | 典型延迟（秒）：新请求从到达引擎到第一次出现在读数里要多久 |
| `orphan` | 0 | 不属于任何在跑的行的输出 token 数 |
| `drafted`、`accepted` | 0、0 | 锁存的两个推测解码计数 |
| `empty_since` | `None` | 流表最近一次变空的时刻；`None` 表示“很久以前” |

每一行除了约定里的 7 个键，内部再记两样：`seen`（这一行建出来那次的 `now`）、`solo`（`bool`，建出来时算不算“独自出现”，见第 3 步）。`rows()` 和 `tfpanel` 里只给那 7 个键。

“新建一行提示未知的行”指：`phase` 为 `"prefill"`、`prompt` 为 `None`、`cached` 为 0、`output` 为 0、`start` 为 `now`、`ttft_s` 为 `None`、`seen` 为 `now`、`solo` 为 `False`。

“平均分”指整数除法：把 `total` 分给 `n` 行，每行 `total // n`，余数 `total % n` 全部加给这 `n` 行里**最靠前**的那一行。

## `feed(now, m, prefill_tps=None, context_length=None)` 的处理顺序

`tps` = `prefill_tps`（是大于 0 的数字时），否则 `2300.0`。`m` 里缺的键按 0 算（`epoch` 按 `None`）。

**1. 重启。** `p` 不是 `None`，并且（`p["epoch"]`、`m["epoch"]` 都不是 `None` 且不相等，或者下面任何一个键 `m` 的值比 `p` 的小）→ 调 `reset()`，然后按第 2 步处理（这时 `p` 是 `None`）。
要比的键：`queries`、`hits`、`prompt`、`prompt_cached`、`ttft_count`、`generation`、`success`、`req_prompt_sum`、`req_generation_sum`、`req_computed_sum`、`drafted`、`accepted`。

**2. 第一次读数**（`p` 是 `None`）。新建 `m["running"]` 行提示未知的行；`orphan = m["generation"] - m["req_generation_sum"]`；`drafted`、`accepted` 取 `m` 的值；`peak = max(peak, m["running"])`；记下 `prev = m`；直接去“输出”。下面各步都不做。

以下各步里 `fin = m["success"] - p["success"]`（这次结束的条数）。

**3. 到达。** 先算 `n = m["running"] - 流表行数 + fin`，`dq = m["queries"] - p["queries"]`，`dh = m["hits"] - p["hits"]`。
“独自出现的条件” = 此刻流表是空的。（起点回推的上限和 `solo` 的条件后来在任务 V7 里改过，以 `docs/tasks/V7-start-cap.md` 为准。）

- `dq > 0`：`n = max(1, n)`，新建 `n` 行。`dq` 平均分成各行的 `prompt`，`dh` 平均分成各行的 `cached`。每行的 `start`：满足独自出现的条件时是 `now - min((prompt - cached) / tps, lag)`，否则是 `now`。`solo` = 满足独自出现的条件并且 `n == 1`。`phase` 为 `"prefill"`，`seen` 为 `now`。
- `dq <= 0` 且 `n > 0`：新建 `n` 行提示未知的行。

**4. 出首字。** `k = m["ttft_count"] - p["ttft_count"]`，`dp = m["prompt"] - p["prompt"]`，`dc = m["prompt_cached"] - p["prompt_cached"]`，`dt = m["ttft_sum"] - p["ttft_sum"]`。

- `k == 1`：在 `phase` 为 `"prefill"` 的行里按这个顺序找一行：`prompt == dp` 的第一行 → `prompt` 是 `None` 的第一行 → 第一行 → 都没有就新建一行提示未知的行。
  如果这一行 `solo` 为真、`prompt` 不是 `None`、`prompt - cached >= 4096`：`lag = 0.7 * lag + 0.3 * max(0.0, dt - (now - seen))`。
  然后把这一行改成：`phase = "decode"`，`prompt = dp`，`cached = dc`，`ttft_s = dt`，`start = now - dt`。
- `k > 1`：取 `phase` 为 `"prefill"` 的前 `k` 行；不够 `k` 行就新建提示未知的行补足。这 `k` 行里 `prompt` 是 `None` 的那些：把 `max(0, dp - 这 k 行里已知的 prompt 之和)` 平均分成它们的 `prompt`，把 `max(0, dc - 这 k 行里已知行的 cached 之和)` 平均分成它们的 `cached`。然后这 `k` 行都改成 `phase = "decode"`，`ttft_s = dt / k`，`start = now - dt / k`。

**5. 分输出。** `dg = m["generation"] - p["generation"]`。`dg > 0` 且有 `phase` 为 `"decode"` 的行时，把 `dg` 平均分，加到这些行的 `output` 上。

**6. 结束**（`fin >= 1`）。把流表排成“解码行在前（按原顺序）、其余行在后（按原顺序）”的候选顺序。

- `fin == 1`：解码行里 `prompt == m["req_prompt_sum"] - p["req_prompt_sum"]` 的第一行；没有就取候选顺序的第一行；流表是空的就什么都不删。
- `fin > 1`：取候选顺序的前 `fin` 行（不够就有几行取几行）。

把取到的行从流表删掉。其中 `ttft_s` 不是 `None` 的：`done_ttft_sum += ttft_s`，`done_ttft_count += 1`。

**7. 对数。** `extra = 流表行数 - m["running"]`。

- `extra > 0`：删掉流表**末尾**的 `extra` 行；删之前把它们的 `output` 加到 `orphan` 上；`aborted += extra`。
- `extra < 0`：新建 `-extra` 行提示未知的行。

**8. 校准输出。** `target = max(0, m["generation"] - m["req_generation_sum"] - orphan)`。

- `target > 0`、流表不空、但没有 `phase` 为 `"decode"` 的行 → 把流表第一行的 `phase` 改成 `"decode"`。
- 有解码行、且它们的 `output` 之和 `total != target` 时：`total > 0` → 每行 `output = output * target // total`，再把 `target - 新的和` 加给第一条解码行；`total == 0` → 把 `target` 平均分给解码行。

**9. 收尾。**

- `m["running"] == 0` → `orphan = m["generation"] - m["req_generation_sum"]`。
- `m["running"] == 0`，并且（`p["running"] > 0`，或 `fin >= 1`，或这次 `aborted` 增加了）→ `empty_since = now`。
- `fin >= 1` 或 `m["running"] == 0` → `drafted`、`accepted` 取 `m` 的值。
- `peak = max(peak, m["running"])`；`prev = m`。

**输出。** 照约定第 3 节拼 `(health, metrics)`：`streams.decoding`、`.prefilling` 是流表里两种 `phase` 的行数；`streams.max` 是 `max(4, peak)`；`context_length` 是正数才放这个键；流表里每一行的 `prompt` 都不是 `None`（包括空表）才放 `tfpanel`。`metrics` 的 `ttft_sum`、`ttft_count` 是 `done_ttft_sum`、`done_ttft_count`。返回的字典和里面的行都是新的，调用方改它们不影响适配器。

## 第一步：单条流

写出 `VllmAdapter`（`reset`、`feed`、`rows`）。`panel/tests/test_engine.py` 开头放下面这段辅助代码（原样用）：

```python
import json
import unittest
from pathlib import Path

from panel.engine import VllmAdapter

SEQ_DIR = Path(__file__).resolve().parents[2] / "fixtures" / "vllm"


def load(name):
    """读一段录下来的序列，返回 (整个文件, [(t, 读数), …])。"""
    with open(SEQ_DIR / f"seq-{name}.json", encoding="utf-8") as f:
        data = json.load(f)
    fields = data["fields"]
    return data, [(s[0], dict(zip(fields[1:], s[1:]))) for s in data["samples"]]


def state_of(adapter, health, metrics):
    """适配器此刻的状态，写成和 checkpoints 同样的格式（不含 t）。"""
    rows = []
    for row in adapter.rows():
        rows.append({"id": row["id"], "phase": row["phase"], "prompt": row["prompt"], "cached": row["cached"],
                     "start": round(row["start"], 3),
                     "ttft_s": None if row["ttft_s"] is None else round(row["ttft_s"], 4)})
    return {"detail": "tfpanel" in health, "rows": rows,
            "decoding": health["streams"]["decoding"], "prefilling": health["streams"]["prefilling"],
            "max": health["streams"]["max"], "aborted_total": health["aborted_total"],
            "ttft_count": metrics["ttft_count"], "ttft_sum": round(metrics["ttft_sum"], 4)}


class SeqCase(unittest.TestCase):
    def check_checkpoints(self, name):
        """把 samples[::2] 喂进去，每一步的状态都要等于时刻不晚于它的最后一个 checkpoint。"""
        data, samples = load(name)
        checkpoints = data["checkpoints"]
        adapter = VllmAdapter()
        for t, m in samples[::2]:
            health, metrics = adapter.feed(t, m)
            want = [c for c in checkpoints if c["t"] <= t + 1e-9][-1]
            want = {k: v for k, v in want.items() if k != "t"}
            got = state_of(adapter, health, metrics)
            self.assertEqual(len(got["rows"]), len(want["rows"]), f"{name} t={t}")
            for g, w in zip(got["rows"], want["rows"]):
                self.assertAlmostEqual(g.pop("start"), w["start"], delta=0.002, msg=f"{name} t={t}")
                if w["ttft_s"] is None:
                    self.assertIsNone(g.pop("ttft_s"), f"{name} t={t}")
                else:
                    self.assertAlmostEqual(g.pop("ttft_s"), w["ttft_s"], delta=0.0002, msg=f"{name} t={t}")
                self.assertEqual(g, {k: v for k, v in w.items() if k not in ("start", "ttft_s")}, f"{name} t={t}")
            self.assertAlmostEqual(got.pop("ttft_sum"), want["ttft_sum"], delta=0.0002, msg=f"{name} t={t}")
            got.pop("rows")
            self.assertEqual(got, {k: v for k, v in want.items() if k not in ("rows", "ttft_sum")}, f"{name} t={t}")
        return adapter
```

加测试类 `TestSingle(SeqCase)`：对 `short`、`long`、`followup`、`round` 四段各调一次 `check_checkpoints`（每段一个测试方法）。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_engine.TestSingle 2>&1 | tail -1
```

应输出 `OK`。

## 第二步：并发和中途断开

加测试类 `TestMulti(SeqCase)`：对 `conc3`、`conc5`、`long-then-short`、`abort-decode`、`abort-prefill`、`abort-conc` 六段各调一次 `check_checkpoints`。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_engine.TestSingle panel.tests.test_engine.TestMulti 2>&1 | tail -1
```

应输出 `OK`。有对不上的，报错信息里的 `t=` 就是第一次对不上的那次读数，回到上面的处理顺序里找原因。

## 第三步：统一读数和不变量

加测试类 `TestUnified(SeqCase)`，覆盖下面每一条（序列里的累计值不是从 0 开始的，所以都比“最后一次读数 − 第一次读数”的差）：

1. `followup`（喂 `samples[::2]`，下同）：`requests_total` 的差是 1，`prompt_tokens_total` 的差是 24126，`cached_tokens_total` 的差是 19584，`completion_tokens_total` 和 `completion_finished_total` 的差都是 120；最后一次的 `usage_totals` 四项分别等于最后一次读数的 `prompt`、`prompt_cached`、`generation`、`success`；`health["ok"] is True`，`health["backend"] == "vllm"`，`health["epoch"]` 等于读数的 `epoch`；`metrics["waiting"] == 0`，`metrics["kv_usage"] == []`。
2. `short`：`drafted_total`、`accepted_total` 在 `requests_running == 1` 的那些读数里保持第一次读数的值不变；最后一次比第一次分别多 84 和 29。
3. 10 段序列、步长 1、2、3、5（`samples[off::step]`，`off` 取 `0` 到 `step - 1`）的每一种喂法：每喂一次都有 `len(adapter.rows()) == m["running"]`，`health["requests_running"] == m["running"]`，`streams.decoding + streams.prefilling == m["running"]`；喂完之后流表是空的，`aborted_total` 等于这段 `requests` 里 `aborted` 为真的个数，`metrics["ttft_count"]` 等于 `aborted` 为假的个数。
4. `long`、`conc3`、`conc5`（没有断开的序列）、步长 2：每喂一次，解码行的 `output` 之和等于 `(m["generation"] - m["req_generation_sum"]) - (第一次读数的 generation - 第一次读数的 req_generation_sum)`。
5. `conc5` 喂完后 `streams.max == 5`；`short` 喂完后是 4。
6. `context_length`：`feed(t, m, None, 262144)` 的 `health["context_length"] == 262144`；不传时没有这个键。
7. `prefill_tps`：`long` 用 `feed(t, m, 24085.0)` 喂，`t` 为 3.5058 的那次之后流表唯一一行的 `start` 约等于 `2.5058`（误差 0.002；回推 `24085 / 24085.0 = 1.0` 秒）。
8. 返回值是新的：改 `health["tfpanel"]["streams"]` 里某一行的 `prompt`、改 `rows()` 返回的行，再喂下一次，流表不受影响。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_engine 2>&1 | tail -1
```

应输出 `OK`。

## 第四步：中途启动和引擎重启

加测试类 `TestEdges(SeqCase)`：

1. 中途启动（预填充中）：`long` 从 `samples[100::2]` 开始喂（第一次读数时已经有一个请求在跑）。第一次：`rows()` 有一行，`prompt` 是 `None`，`phase` 是 `"prefill"`，`health` 里没有 `tfpanel`。喂到 `t >= 10.5` 之后：有 `tfpanel`，那一行 `phase` 是 `"decode"`、`prompt` 是 24085、`ttft_s` 约 9.3375。喂完流表为空，`aborted_total` 是 0，`ttft_count` 是 1。
2. 中途启动（解码中）：`long` 从 `samples[230::2]` 开始喂（那个请求已经在解码，首字已经出过）。第一次是一行提示未知的预填充行；第二次起那一行 `phase` 是 `"decode"`，`health` 里一直没有 `tfpanel`，`output` 等于“这次读数的 generation − 第一次读数的 generation”。喂完流表为空、`aborted_total` 是 0、`ttft_count` 是 0（这个请求的首字时间不知道，不计数）、有 `tfpanel`。
3. 从每个位置中途启动都不出错：10 段序列，`start` 取 `range(0, len(samples) - 5, 7)`，喂 `samples[start::2]`，不抛异常，喂完流表为空。
4. 引擎重启（`epoch` 变了）：`conc5` 喂完后，再喂一次“所有键都是 0、`epoch` 换成另一个数”的读数：流表为空，`aborted_total`、`ttft_count` 是 0，`streams.max` 回到 4，`drafted_total` 是 0。
5. 引擎重启（累计值变小、`epoch` 相同）：`abort-decode` 喂完（这时 `aborted_total` 是 1）后，再喂一次把最后一次读数的 `generation` 减 1 的读数：`aborted_total` 回到 0。
6. `reset()`：`short` 喂到一半调 `reset()`，`rows()` 为空；接着喂剩下的不抛异常。
7. 读数缺键：`feed(0.0, {"running": 0})` 不抛异常，返回的 `health["requests_total"] == 0`、`health["epoch"] is None`。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_engine 2>&1 | tail -1
```

应输出 `OK`。

## 最后一步：收尾检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_engine 2>&1 | tail -1
python3 -c "import ast, sys; t = ast.parse(open('panel/engine.py', encoding='utf-8').read()); print(sorted({a.name.split('.')[0] for n in ast.walk(t) if isinstance(n, ast.Import) for a in n.names} | {n.module.split('.')[0] for n in ast.walk(t) if isinstance(n, ast.ImportFrom) and n.module}))"
git status --short panel
```

通过的标准：第一条输出 `OK`；第二条打印的列表里没有 `panel`、`time`、`gi`（适配器不读时钟、不依赖别的模块）；第三条里属于你的改动只有 `?? panel/engine.py` 和 `?? panel/tests/test_engine.py`（别的执行者改的文件也可能列在里面，不用管）。全部通过后最后一行输出 `DONE`。
