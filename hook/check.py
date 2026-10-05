#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""外挂自检脚本：在已打上补丁的容器里运行，不需要显卡。

用法（在 dist-packages 那一层执行，补丁把两个文件放在这一层）：

    cd /usr/local/lib/python3.12/dist-packages && python3 /hook/check.py

逐项打印结果；全部通过时最后一行打印 CHECK OK 并以 0 退出，
任何一项不通过打印一行原因并以 1 退出。只用标准库。
"""

import sys
from types import SimpleNamespace

# 与 tfpanel_hook.py 里的 MARKER 一致：包装函数上带的标记属性靠它认出来
MARKER = "__tfpanel_wrapped__"

# 第 3 项期望的 tfpanel 段（假 app 的数据照任务说明里的样子）
EXPECTED_TF = {"v": 1, "streams": [
    {"id": 3, "phase": "decode", "prompt": 18420, "cached": 16384, "output": 312},
    {"id": 4, "phase": "prefill", "prompt": 24615, "cached": 2048, "filled": 10240},
]}

failures = []


def say(name, ok, detail=""):
    """打印一项结果，顺带记下它过没过。"""
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f"：{detail}" if detail else ""))
    if not ok:
        failures.append(name)
    return ok


def main():
    # 1. 启动时外挂已在 sys.modules 里（.pth 生效），而且没把 torch/tensorfold 带进来
    loaded = "tfpanel_hook" in sys.modules
    quiet = "torch" not in sys.modules and "tensorfold" not in sys.modules
    if not say("1. 启动时已加载 tfpanel_hook，且没连带导入 torch/tensorfold",
               loaded and quiet,
               f"已加载: {loaded}，torch/tensorfold 都不在 sys.modules 里: {quiet}"):
        return 1

    # 2. 导入 tensorfold.cuda.health，看 Health.snapshot 有没有被包住
    try:
        import tensorfold.cuda.health as h
    except Exception as exc:
        say("2. 导入 tensorfold.cuda.health", False, f"导入失败 {exc!r}")
        return 1
    snapshot = getattr(getattr(h, "Health", None), "snapshot", None)
    if not say("2. Health.snapshot 已被包装", bool(getattr(snapshot, MARKER, False)),
               f"标记属性 {MARKER} 在不在: {bool(getattr(snapshot, MARKER, False))}"):
        return 1

    # 3. 假 app：一条正在解码的流 + 一条正在预填充的流
    decoder = SimpleNamespace(
        streams={3: SimpleNamespace(sid=3, prompt=[0] * 18420, cached=16384, out=[1] * 312)},
        filling=[SimpleNamespace(sid=4, prompt=[0] * 24615, cached=2048)],
        fills={4: [None, None, 10240, None]},
    )
    scheduler = SimpleNamespace(decoder=decoder, max_streams=5)
    app = SimpleNamespace(engine=SimpleNamespace(scheduler=scheduler),
                          effective_context_window=262144)
    expected_streams = {"decoding": 1, "prefilling": 1, "max": 5}

    def snapshot_of(app_):
        """照 /health 的取用入口取一份快照（没有 of 就直接实例化 Health）。"""
        health = h.of(app_) if hasattr(h, "of") else h.Health()
        return health.snapshot(app_)

    try:
        body = snapshot_of(app)
    except Exception as exc:
        body = None
        say("3. 假 app 的快照结果", False, f"调用抛了异常 {exc!r}")
    if body is not None:
        say("3. 假 app 的快照结果",
            body.get("tfpanel") == EXPECTED_TF
            and body.get("streams") == expected_streams
            and body.get("ok") is True
            and body.get("context_length") == 262144,
            f"tfpanel 段与预期一致: {body.get('tfpanel') == EXPECTED_TF}，"
            f"streams: {body.get('streams')}，ok: {body.get('ok')}，"
            f"context_length: {body.get('context_length')}")

    # 4. 把假 decoder 的 fills 属性删掉：没有 tfpanel 这一段，其他字段照常
    del decoder.fills
    try:
        body4 = snapshot_of(app)
    except Exception as exc:
        body4 = None
        say("4. 缺 fills 时整段不输出", False, f"调用抛了异常 {exc!r}")
    if body4 is not None:
        before = {k: v for k, v in body.items() if k != "tfpanel"}
        say("4. 缺 fills 时整段不输出",
            "tfpanel" not in body4 and body4 == before,
            f"没有 tfpanel: {'tfpanel' not in body4}，其余字段跟第 3 项一样: {body4 == before}")

    # 5. 假 app 没有 engine 属性：没有 tfpanel 这一段，ok 还是 True
    try:
        body5 = snapshot_of(SimpleNamespace(effective_context_window=262144))
    except Exception as exc:
        body5 = None
        say("5. 没有 engine 时整段不输出", False, f"调用抛了异常 {exc!r}")
    if body5 is not None:
        say("5. 没有 engine 时整段不输出",
            "tfpanel" not in body5 and body5.get("ok") is True,
            f"没有 tfpanel: {'tfpanel' not in body5}，ok 是 True: {body5.get('ok') is True}")

    return 1 if failures else 0


if __name__ == "__main__":
    code = main()
    if code == 0:
        print("CHECK OK")
    sys.exit(code)
