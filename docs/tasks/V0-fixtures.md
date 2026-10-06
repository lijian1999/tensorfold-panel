# 任务 V0：快照样例加上 `engine` 和 `prefill.estimated`，新增三个 vLLM 样例

先读 `AGENTS.md`。本任务改这些文件：`fixtures/` 下现有的 14 个 `*.json`、新建 `fixtures/prefill-est.json`、`fixtures/idle-vllm.json`、`fixtures/offline-vllm.json`，改 `panel/tests/test_fixtures.py`。不要改别的文件，不要动 `fixtures/vllm/` 目录。不需要在 Spark 上运行任何东西。

## 背景

副屏程序要同时支持 TensorFold 和 vLLM 两种推理引擎（设计见 `docs/design-vllm.md` 的“指标快照的改动”）。指标快照的格式因此多两个字段：

- 顶层 `engine`：`"tensorfold"`、`"vllm"`，从没连上过引擎时为 `null`。
- `prefill` 对象里的 `estimated`：`true` 表示预填充的进度、速度、剩余时间是按时间估算的；只有 vLLM 会是 `true`。

`fixtures/*.json` 是各个画面的快照样例，要跟着格式一起改。

## 第一步：现有 14 个样例加字段

对 `fixtures/` 下现有的每个 `*.json`（不含子目录）：

1. 顶层在 `"hook"` 后面加一个键 `"engine": "tensorfold"`。
2. 如果 `prefill` 不是 `null`，在 `prefill` 对象的最后加一个键 `"estimated": false`。

其余内容、键的顺序、缩进（2 个空格）都保持原样。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 - <<'EOF'
import json, pathlib
for p in sorted(pathlib.Path("fixtures").glob("*.json")):
    if p.name in ("prefill-est.json", "idle-vllm.json", "offline-vllm.json"):
        continue
    d = json.loads(p.read_text(encoding="utf-8"))
    keys = list(d)
    assert keys[keys.index("hook") + 1] == "engine" and d["engine"] == "tensorfold", p.name
    if d["prefill"] is not None:
        assert list(d["prefill"])[-1] == "estimated" and d["prefill"]["estimated"] is False, p.name
print("OK")
EOF
```

应输出 `OK`。

## 第二步：新建三个 vLLM 样例

`fixtures/prefill-est.json`，内容一字不差：

```json
{
  "version": 2,
  "state": "prefill",
  "hook": "ok",
  "engine": "vllm",
  "model": "Qwen/Qwen3.8-Flash-Next",
  "context_max": 262144,
  "lanes": {
    "max": 4,
    "decoding": 0,
    "prefilling": 1,
    "waiting": 0
  },
  "decode": null,
  "prefill": {
    "elapsed_s": 6.7,
    "prompt_tokens": 39884,
    "cached_tokens": 0,
    "filled_tokens": 14740,
    "tps": 2200.0,
    "remaining_s": 11.43,
    "est_s": 18.13,
    "cache_miss": false,
    "estimated": true
  },
  "context_used": 39884,
  "last": {
    "prompt_tokens": 58,
    "cached_tokens": 0,
    "completion_tokens": 570,
    "decode_tps": 63.6,
    "prefill_tps": 704.0,
    "ttft_s": 0.07,
    "acceptance_rate": 0.26,
    "context_used": 628
  },
  "round": {
    "requests": 0,
    "running": 1,
    "output_tokens": 0,
    "decode_tps_avg": null,
    "exact": true,
    "elapsed_s": 6.7,
    "active": true
  },
  "today": {
    "date": "2026-10-03",
    "prompt_tokens": 8260391,
    "cached_tokens": 5443627,
    "completion_tokens": 185305,
    "requests": 98,
    "cost": 0.597
  },
  "memory": {
    "used_gb": 94.4,
    "total_gb": 121.6
  },
  "offline_s": null
}
```

`fixtures/idle-vllm.json`：把第一步改好的 `fixtures/idle.json` 复制一份，只改三处：`"engine"` 改成 `"vllm"`，`"model"` 改成 `"Qwen/Qwen3.8-Flash-Next"`，`lanes` 里的 `"max"` 改成 `4`。

`fixtures/offline-vllm.json`：把第一步改好的 `fixtures/offline.json` 复制一份，同样只改这三处。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 - <<'EOF'
import json
def load(n): return json.load(open(f"fixtures/{n}.json", encoding="utf-8"))
for new, old in (("idle-vllm", "idle"), ("offline-vllm", "offline")):
    a, b = load(new), load(old)
    assert (a["engine"], a["model"], a["lanes"]["max"]) == ("vllm", "Qwen/Qwen3.8-Flash-Next", 4), new
    a["engine"], a["model"], a["lanes"]["max"] = b["engine"], b["model"], b["lanes"]["max"]
    assert a == b and list(a) == list(b), new
p = load("prefill-est")
assert p["engine"] == "vllm" and p["prefill"]["estimated"] is True and p["prefill"]["filled_tokens"] == 14740
assert list(p) == list(load("prefill"))
print("OK")
EOF
```

应输出 `OK`。

## 第三步：改 `panel/tests/test_fixtures.py`

1. `TOP_KEYS` 加 `"engine"`；`PREFILL_OBJ_KEYS` 加 `"estimated"`；`FIXTURE_NAMES` 加 `"prefill-est.json"`、`"idle-vllm.json"`、`"offline-vllm.json"`。注释和文档字符串里写的个数（“14 个键”“14 个样例”）改成新的个数（15 个键、17 个样例）。
2. 在 `TestFixtureFormat` 里加一个测试 `test_engine`：每个样例的 `engine` 是 `"tensorfold"` 或 `"vllm"`。
3. 在 `TestFixtureFormat` 里加一个测试 `test_estimated`：每个 `prefill` 不为 `null` 的样例，`prefill["estimated"]` 是 `bool`；`engine` 是 `"tensorfold"` 的样例它必须是 `False`。
4. 其余测试不动。

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_fixtures 2>&1 | tail -3
```

最后一行应是 `OK`，上面隔一行是 `Ran 11 tests in …`。

## 最后一步：收尾检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_fixtures panel.tests.test_viewmodel panel.tests.test_anim 2>&1 | tail -1
git status --short fixtures panel
```

通过的标准：第一条命令输出 `OK`；第二条命令列出的改动只有 `fixtures/` 下的 17 个 `*.json`（14 个 ` M`、3 个 `??`）和 `panel/tests/test_fixtures.py`。全部通过后最后一行输出 `DONE`。
