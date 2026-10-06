# 验证用：模块第一次被导入后再包一层 Health.snapshot，只读
import importlib.abc, importlib.util, sys
TARGET = "tensorfold.cuda.health"

def _streams(app):
    dec = getattr(getattr(getattr(app, "engine", None), "scheduler", None), "decoder", None)
    rows = []
    for s in list(getattr(dec, "streams", {}).values()):
        rows.append({"id": s.sid, "phase": "decode", "prompt": len(s.prompt), "cached": s.cached, "output": len(s.out)})
    fills = getattr(dec, "fills", {})
    for s in list(getattr(dec, "filling", ())):
        f = fills.get(s.sid)
        rows.append({"id": s.sid, "phase": "prefill", "prompt": len(s.prompt), "cached": s.cached,
                     "filled": int(f[2]) if f else None})
    return rows

def _patch(mod):
    orig = mod.Health.snapshot
    def snapshot(self, app):
        body = orig(self, app)
        try:
            body["tfpanel"] = {"v": 1, "streams": _streams(app)}
        except Exception:
            pass
        return body
    mod.Health.snapshot = snapshot

class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path, target=None):
        if name != TARGET:
            return None
        sys.meta_path.remove(self)
        spec = importlib.util.find_spec(name)
        if spec is None or spec.loader is None:
            return spec
        run = spec.loader.exec_module
        def exec_module(module):
            run(module)
            try:
                _patch(module)
            except Exception as exc:
                print("[tfpanel] 外挂未挂载:", exc, file=sys.stderr)
        spec.loader.exec_module = exec_module
        return spec

sys.meta_path.insert(0, _Finder())
