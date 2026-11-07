"""fixtures 录制器：按固定间隔轮询 TensorFold 的监控端点，追加写入 jsonl。

用法: python3 record.py OUT.jsonl [间隔秒]
每行: {"t": 单调秒, "ep": 端点名, "status": http状态码, "body": 原始文本}
Ctrl-C 或 kill 结束。
"""

import json
import sys
import time
import urllib.request

BASE = "http://127.0.0.1:8081"
ENDPOINTS = ["/health", "/v1/models", "/v1/load", "/metrics", "/stats"]
INTERVAL = float(sys.argv[2]) if len(sys.argv) > 2 else 0.25

start = time.monotonic()
while True:
    t = time.monotonic() - start
    for ep in ENDPOINTS:
        try:
            with urllib.request.urlopen(BASE + ep, timeout=1) as r:
                body = r.read().decode("utf-8", "replace")
                status = r.status
        except Exception as e:  # 连不上也要记（离线场景）
            code = getattr(e, "code", None)
            body = "" if code else f"{type(e).__name__}: {e}"
            status = code or 0
        line = json.dumps({"t": round(t, 3), "ep": ep, "status": status, "body": body},
                          ensure_ascii=False)
        with open(sys.argv[1], "a") as f:
            f.write(line + "\n")
            f.flush()
    time.sleep(INTERVAL)