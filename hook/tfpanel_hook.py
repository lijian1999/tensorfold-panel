"""TensorFold 副屏外挂：给 /health 的 JSON 追加一段 tfpanel（只用标准库，只读）。

设计原则：外挂出任何问题都不能影响推理，也不能让 /health 出错。

- 导入这个模块时只做一件事：在 sys.meta_path 最前面登记一个导入钩子。
  不导入 torch、不导入 tensorfold 的任何模块、不打印任何东西。
- 钩子只关心 tensorfold.cuda.health 一个模块名。它第一次被导入并执行完之后，
  调用 patch_health 把 Health.snapshot 包一层；钩子用过一次就把自己摘掉。
- 包 snapshot 时读不到预期的结构，就整段不输出 tfpanel，/health 照常返回。
"""

import functools
import importlib.abc
import importlib.util
import sys

# 钩子关心的模块名
TARGET = "tensorfold.cuda.health"

# 包装函数上的标记属性：查重（不包两层）和自检脚本都靠它认出包装函数
MARKER = "__tfpanel_wrapped__"

# 复制两张流表最多试几次：表由引擎线程改，边读边改会抛 RuntimeError
_SNAPSHOT_TRIES = 3


def build_section(app):
    """读出当前的流表，拼出 tfpanel 那一段；任何一处读不到就返回 None。

    只读 design.md 里列出的那几个属性，不调用引擎的任何方法，不加锁。
    """
    try:
        engine = getattr(app, "engine", None)
        if engine is None:
            return None
        scheduler = getattr(engine, "scheduler", None)
        if scheduler is None:
            return None
        decoder = getattr(scheduler, "decoder", None)
        if decoder is None:
            return None
        streams = getattr(decoder, "streams", None)
        filling = getattr(decoder, "filling", None)
        fills = getattr(decoder, "fills", None)
        if not isinstance(streams, dict) or not isinstance(filling, list) or not isinstance(fills, dict):
            return None
        for _ in range(_SNAPSHOT_TRIES):
            try:
                decoding = list(streams.values())       # 正在解码的流
                prefilling = list(filling)              # 正在预填充的流
                break
            except RuntimeError:
                pass                                    # 表正在被改，重来
        else:
            return None
        rows = []
        for s in decoding:
            rows.append({"id": int(s.sid), "phase": "decode", "prompt": len(s.prompt),
                         "cached": int(s.cached), "output": len(s.out)})
        # 同一个 id 在两张表里都出现时，只保留 decode 那一行
        decoded = {row["id"] for row in rows}
        for s in prefilling:
            if s.sid in decoded:
                continue
            entry = fills.get(s.sid)
            if entry is None:
                # 这条流刚好算完、正在挪到解码表：按整个提示都算完了算
                filled = len(s.prompt)
            else:
                filled = int(entry[2])
            rows.append({"id": int(s.sid), "phase": "prefill", "prompt": len(s.prompt),
                         "cached": int(s.cached), "filled": filled})
        rows.sort(key=lambda row: row["id"])
        return {"v": 1, "streams": rows}
    except Exception:
        # 缺属性、类型不对、读到一半表被改了：整段不输出
        return None


def patch_health(module):
    """把 module.Health.snapshot 换成包装函数；自检不过就什么都不改。

    自检：Health 存在、Health.snapshot 可调用。不满足时向 stderr 打印一行原因，
    返回 False。已经包过就不再包第二层（重复调用仍返回 True）。
    """
    try:
        health = getattr(module, "Health", None)
        if health is None:
            print("[tfpanel] 外挂未挂载：模块里没有 Health 类", file=sys.stderr)
            return False
        original = getattr(health, "snapshot", None)
        if not callable(original):
            print("[tfpanel] 外挂未挂载：Health.snapshot 不可调用", file=sys.stderr)
            return False
        if getattr(original, MARKER, False):
            return True                       # 已经包过了

        @functools.wraps(original)
        def snapshot(self, app, *args, **kwargs):
            body = original(self, app, *args, **kwargs)   # 原函数抛的异常原样抛出
            try:
                section = build_section(app)
                if section is not None and isinstance(body, dict):
                    body["tfpanel"] = section
            except Exception:
                pass
            return body                                   # 同一个对象

        setattr(snapshot, MARKER, True)
        health.snapshot = snapshot
        return True
    except Exception as exc:
        print(f"[tfpanel] 外挂未挂载：{exc!r}", file=sys.stderr)
        return False


class _Finder(importlib.abc.MetaPathFinder):
    """导入钩子：等 tensorfold.cuda.health 执行完就挂上去，用过一次就摘掉。"""

    def find_spec(self, name, path, target=None):
        if name != TARGET:
            return None
        try:
            # 先把自己摘掉：一是"用过一次就摘掉"，二是下面查 spec 时不会绕回自己
            sys.meta_path.remove(self)
            spec = importlib.util.find_spec(name)      # 让其余的查找器找到真正的 spec
            if spec is None or spec.loader is None:
                return spec
            run = spec.loader.exec_module

            def exec_module(module):
                run(module)                     # 原样执行模块；它抛的异常原样抛出
                patch_health(module)

            # 只换这一个加载器实例上的 exec_module 方法
            spec.loader.exec_module = exec_module
            return spec
        except Exception as exc:
            # 钩子自己出任何问题：返回 None，那次导入照常进行，只是没有外挂
            print(f"[tfpanel] 外挂未挂载：{exc!r}", file=sys.stderr)
            return None


# 模块级只登记导入钩子：不导入别的模块，不打印任何东西
sys.meta_path.insert(0, _Finder())
