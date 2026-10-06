# 任务 B：指标快照样例（fixtures）

先读 `AGENTS.md`，再读 `docs/design.md` 的“指标快照（采集 → 绘制）”一节。本任务只写 JSON 和一个测试，全部在 MacBook Pro 上完成，不需要 `ssh spark`。

## 交付文件

1. `fixtures/<名字>.json`：下面列的 14 个样例，每个是一份完整的指标快照（设计文档里那种格式，字段齐全）。
2. `panel/tests/test_fixtures.py`：检查样例格式的测试。

不要创建别的文件（`panel/tests/__init__.py` 由别的任务创建；如果它不存在，你可以建一个空的）。

## 写法

每个样例 = “基础快照”+ 下表里写的改动。没提到的字段保持基础快照的值。JSON 用 2 空格缩进、`ensure_ascii=False`，键的顺序和基础快照一致。可以临时写个脚本生成，但脚本不要留在仓库里。

基础快照：

```json
{
  "version": 2,
  "state": "idle",
  "hook": "ok",
  "model": "Qwen3.8-Flash-Next",
  "context_max": 262144,
  "lanes": { "max": 5, "decoding": 0, "prefilling": 0, "waiting": 0 },
  "decode": null,
  "prefill": null,
  "context_used": 628,
  "last": {
    "prompt_tokens": 58, "cached_tokens": 0, "completion_tokens": 570, "decode_tps": 63.6,
    "prefill_tps": 704.0, "ttft_s": 0.07, "acceptance_rate": 0.7, "context_used": 628
  },
  "round": null,
  "today": {
    "date": "2026-10-03", "prompt_tokens": 8260391, "cached_tokens": 5443627,
    "completion_tokens": 185305, "requests": 98, "cost": 0.597
  },
  "memory": { "used_gb": 94.2, "total_gb": 121.6 },
  "offline_s": null
}
```

下面 `decode`、`prefill`、`round`、`last` 给出时都是**整个对象**，键的顺序如下：

- `decode`：`tps`、`tps_peak`、`tps_avg`、`output_tokens`、`ttft_s`
- `prefill`：`elapsed_s`、`prompt_tokens`、`cached_tokens`、`filled_tokens`、`tps`、`remaining_s`、`est_s`、`cache_miss`
- `round`：`requests`、`running`、`output_tokens`、`decode_tps_avg`、`exact`、`elapsed_s`、`active`
- `last`：和基础快照里的顺序相同

### 14 个样例

| 文件名 | 改动 |
| --- | --- |
| `offline.json` | `state` = `"offline"`；`memory.used_gb` = 9.3；`offline_s` = 44.0 |
| `idle.json` | 无改动 |
| `idle-nohook.json` | `hook` = `"missing"` |
| `prefill.json` | 见下 |
| `prefill-fresh.json` | 见下 |
| `prefill-miss.json` | 见下 |
| `prefill-nohook.json` | 见下 |
| `prefill-short.json` | 见下 |
| `decode.json` | 见下 |
| `decode-multi.json` | 见下 |
| `decode-ctx-warn.json` | 见下 |
| `queue.json` | 见下 |
| `done.json` | 见下 |
| `round-rest.json` | 见下 |

**prefill.json**（单个请求，长提示命中 67%）

- `state` = `"prefill"`；`lanes.prefilling` = 1；`context_used` = 61200；`memory.used_gb` = 95.1
- `prefill` = `{elapsed_s: 5.7, prompt_tokens: 61200, cached_tokens: 40960, filled_tokens: 53248, tps: 2412.0, remaining_s: 3.3, est_s: 8.8, cache_miss: false}`
- `round` = `{requests: 0, running: 1, output_tokens: 0, decode_tps_avg: null, exact: true, elapsed_s: 5.7, active: true}`

**prefill-fresh.json**（单个请求，从头算 2.5 万 token）

- `state` = `"prefill"`；`lanes.prefilling` = 1；`context_used` = 24615；`memory.used_gb` = 94.4
- `prefill` = `{elapsed_s: 6.7, prompt_tokens: 24615, cached_tokens: 0, filled_tokens: 14336, tps: 2354.0, remaining_s: 4.37, est_s: 10.7, cache_miss: false}`
- `round` = `{requests: 0, running: 1, output_tokens: 0, decode_tps_avg: null, exact: true, elapsed_s: 6.7, active: true}`

**prefill-miss.json**（编程代理一轮里缓存未命中）

- `state` = `"prefill"`；`lanes.prefilling` = 1；`context_used` = 41230；`memory.used_gb` = 94.6
- `prefill` = `{elapsed_s: 5.7, prompt_tokens: 41230, cached_tokens: 0, filled_tokens: 12288, tps: 2368.0, remaining_s: 12.22, est_s: 17.93, cache_miss: true}`
- `round` = `{requests: 5, running: 1, output_tokens: 1830, decode_tps_avg: 61.8, exact: true, elapsed_s: 95.0, active: true}`
- `last` = `{prompt_tokens: 40120, cached_tokens: 39400, completion_tokens: 212, decode_tps: 61.5, prefill_tps: 2100.0, ttft_s: 0.41, acceptance_rate: 0.72, context_used: 40332}`

**prefill-nohook.json**（外挂失效时的预填充）

- `state` = `"prefill"`；`hook` = `"missing"`；`lanes.prefilling` = 1；`context_used` = 24615；`memory.used_gb` = 94.4
- `prefill` = `{elapsed_s: 5.6, prompt_tokens: 24615, cached_tokens: null, filled_tokens: null, tps: null, remaining_s: null, est_s: null, cache_miss: false}`
- `round` = `{requests: 0, running: 1, output_tokens: 0, decode_tps_avg: null, exact: true, elapsed_s: 5.6, active: true}`

**prefill-short.json**（短预填充，画面不切）

- `state` = `"prefill"`；`lanes.prefilling` = 1；`context_used` = 9200
- `prefill` = `{elapsed_s: 1.2, prompt_tokens: 9200, cached_tokens: 8192, filled_tokens: 8192, tps: null, remaining_s: 0.0, est_s: 0.44, cache_miss: false}`
- `round` = `{requests: 0, running: 1, output_tokens: 0, decode_tps_avg: null, exact: true, elapsed_s: 1.2, active: true}`

**decode.json**（单个请求解码）

- `state` = `"decode"`；`lanes.decoding` = 1；`context_used` = 441
- `decode` = `{tps: 74.3, tps_peak: 79.2, tps_avg: 69.7, output_tokens: 383, ttft_s: 0.1}`
- `round` = `{requests: 0, running: 1, output_tokens: 383, decode_tps_avg: null, exact: true, elapsed_s: 5.6, active: true}`

**decode-multi.json**（3 条在解码，1 条在预填充）

- `state` = `"decode"`；`lanes.decoding` = 3；`lanes.prefilling` = 1；`context_used` = 61000；`memory.used_gb` = 94.9
- `decode` = `{tps: 100.2, tps_peak: 118.4, tps_avg: 104.9, output_tokens: 742, ttft_s: null}`
- `prefill` = `{elapsed_s: 2.8, prompt_tokens: 61000, cached_tokens: 2048, filled_tokens: 8192, tps: 1650.0, remaining_s: 32.0, est_s: 25.6, cache_miss: false}`
- `round` = `{requests: 3, running: 4, output_tokens: 1702, decode_tps_avg: 107.6, exact: false, elapsed_s: 46.3, active: true}`

**decode-ctx-warn.json**（长会话，上下文占用 84%）

- `state` = `"decode"`；`lanes.decoding` = 1；`context_used` = 220000；`memory.used_gb` = 97.9
- `decode` = `{tps: 88.4, tps_peak: 96.0, tps_avg: 87.9, output_tokens: 12400, ttft_s: 0.35}`
- `round` = `{requests: 0, running: 1, output_tokens: 12400, decode_tps_avg: null, exact: true, elapsed_s: 141.0, active: true}`

**queue.json**（5 路在跑，2 个排队）

- `state` = `"decode"`；`lanes.decoding` = 5；`lanes.waiting` = 2；`context_used` = 9480；`memory.used_gb` = 94.9
- `decode` = `{tps: 136.4, tps_peak: 141.0, tps_avg: 128.9, output_tokens: 790, ttft_s: null}`
- `round` = `{requests: 2, running: 7, output_tokens: 1400, decode_tps_avg: 128.2, exact: false, elapsed_s: 17.4, active: true}`

**done.json**（单个请求完成）

- `state` = `"done"`；`context_used` = 696
- `last` = `{prompt_tokens: 96, cached_tokens: 0, completion_tokens: 600, decode_tps: 97.2, prefill_tps: 1100.0, ttft_s: 0.09, acceptance_rate: 0.81, context_used: 696}`
- `round` = `{requests: 1, running: 0, output_tokens: 600, decode_tps_avg: 97.2, exact: true, elapsed_s: 6.3, active: true}`

**round-rest.json**（一轮中间的空隙）

- `state` = `"idle"`；`context_used` = 14512
- `last` = `{prompt_tokens: 14300, cached_tokens: 13600, completion_tokens: 212, decode_tps: 71.4, prefill_tps: 2050.0, ttft_s: 0.41, acceptance_rate: 0.72, context_used: 14512}`
- `round` = `{requests: 7, running: 0, output_tokens: 2345, decode_tps_avg: 62.3, exact: true, elapsed_s: 132.0, active: true}`

## 测试要求（`panel/tests/test_fixtures.py`）

用 `pathlib` 从测试文件位置找到仓库根目录下的 `fixtures/`，对每个 `*.json`：

1. 能用 `json.load` 读出，是对象。
2. 顶层键恰好是基础快照的 14 个键（不多不少）。
3. `version == 2`；`state` 是 `offline`、`idle`、`prefill`、`decode`、`done` 之一；`hook` 是 `ok` 或 `missing`。
4. `lanes` 恰好有 `max`、`decoding`、`prefilling`、`waiting` 四个整数键。
5. `decode`、`prefill`、`round`、`last` 要么是 `null`，要么恰好有上面列的那些键。
6. `state == "decode"` 时 `decode` 不为 `null` 且 `lanes.decoding >= 1`；`lanes.prefilling >= 1` 时 `prefill` 不为 `null`；`state == "offline"` 时 `offline_s` 是数字，否则是 `null`。
7. `hook == "missing"` 且 `prefill` 不为 `null` 时，`prefill` 的 `cached_tokens`、`filled_tokens`、`tps`、`remaining_s`、`est_s` 都是 `null`。
8. `today`、`memory` 的键齐全。

再加一条：`fixtures/` 里恰好有上面 14 个文件名。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_fixtures -v
python3 -c "import json,glob; [json.load(open(f)) for f in glob.glob('fixtures/*.json')]; print(len(glob.glob('fixtures/*.json')))"
```

第二条命令应输出 `14`。
