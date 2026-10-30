"""用参考适配器回放 fixtures/omlx/ 的录音。

python3 docs/tasks/mac/ref/replay.py <场景名>            逐拍打印适配器和采集器的要点（编排者自查用）
python3 docs/tasks/mac/ref/replay.py --write             把每个场景的期望输出写进 fixtures/omlx/<场景>.expected.jsonl

期望输出每行一个 JSON：{"t": 时刻, "health": ..., "metrics": ..., "model": 模型名}；读数无效的那一拍
health、metrics 都是 null。每个场景用一个新的适配器，先 set_models(第一行的 models)。
时刻 now 用录音里的 t，wall 用录音里的 wall。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
sys.path.insert(0, ROOT)

from omlx_adapter import OmlxAdapter  # noqa: E402

FIX = os.path.join(ROOT, "fixtures", "omlx")
SCENARIOS = ("load-short", "short", "long", "cached", "concurrent4", "queue10",
             "abort-decode", "abort-prefill", "mixed")


def run(name):
    lines = [json.loads(l) for l in open(os.path.join(FIX, name + ".jsonl"), encoding="utf-8")]
    ad = OmlxAdapter()
    ad.set_models(lines[0]["models"])
    out = []
    for d in lines[1:]:
        res = ad.feed(d["t"], d["wall"], d["status"], d["stats"])
        if res is None:
            out.append({"t": d["t"], "health": None, "metrics": None, "model": ad.model_name})
        else:
            out.append({"t": d["t"], "health": res[0], "metrics": res[1], "model": ad.model_name})
    return out


def write_all():
    for name in SCENARIOS:
        out = run(name)
        with open(os.path.join(FIX, name + ".expected.jsonl"), "w", encoding="utf-8") as f:
            for o in out:
                f.write(json.dumps(o, ensure_ascii=False, sort_keys=True) + "\n")
        print(name, len(out))


def show(name):
    from panel.collector import Collector
    from panel.config import Config
    col = Collector(Config())
    for o in run(name):
        h, m = o["health"], o["metrics"]
        snap = col.feed(o["t"], h, m, None, o["model"])
        if h is None:
            print(o["t"], "None")
            continue
        rows = h.get("tfpanel", {}).get("streams") if "tfpanel" in h else None
        rs = "-" if rows is None else " ".join(
            "%s%d:%d/%d+%d%s" % (r["phase"][0], r["id"], r["filled"], r["prompt"], r["output"],
                                 "" if r["ttft_s"] is None else "@%.2f" % r["ttft_s"]) for r in rows)
        ld = h.get("loading")
        print("%6.2f run%d d%d p%d w%d req%d c%d ab%d ttft%d/%.2f pf%.2f dc%.2f | %s %s| %s %s %s" % (
            o["t"], h["requests_running"], h["streams"]["decoding"], h["streams"]["prefilling"],
            m["waiting"], h["requests_total"], h["completion_tokens_total"], h["aborted_total"],
            m["ttft_count"], m["ttft_sum"], h["prefill_seconds_total"], h["decode_seconds_total"],
            rs, "LOAD%.1f " % ld["elapsed_s"] if ld else "",
            snap["state"], json.dumps(snap.get("last"), ensure_ascii=False)[:150] if snap["state"] == "done" else "",
            json.dumps(h["usage_by_model"])[-90:] if o is None else ""))


if __name__ == "__main__":
    if sys.argv[1:] == ["--write"]:
        write_all()
    else:
        show(sys.argv[1])
