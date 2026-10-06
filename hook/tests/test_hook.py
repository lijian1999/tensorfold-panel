"""外挂测试：用临时目录里的假 tensorfold 包代替真实 TensorFold。

在 MacBook Pro 上跑：python3 -m unittest discover -s hook/tests -t hook -v
"""

import io
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr

HOOK_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 假的 tensorfold/cuda/health.py：正常版和语法错误版
FAKE_HEALTH_OK = '''"""假的 tensorfold/cuda/health.py。"""


class Health:
    def snapshot(self, app, *args, **kwargs):
        return {"ok": True, "streams": {"decoding": 0, "prefilling": 0, "max": 4}}


def of(app):
    return Health()
'''

FAKE_HEALTH_BROKEN = "def broken(:\n    pass\n"

# check.py 第 3 项那组数据（测试 2 和 5 都用它）
EXPECTED_FULL = {"v": 1, "streams": [
    {"id": 3, "phase": "decode", "prompt": 18420, "cached": 16384, "output": 312},
    {"id": 4, "phase": "prefill", "prompt": 24615, "cached": 2048, "filled": 10240},
]}


def S(**kw):
    """代替一条 Stream。"""
    return types.SimpleNamespace(**kw)


def make_app(decoder=None, with_engine=True):
    """造一个供 build_section 读的假 app（with_engine=False 时连 engine 都没有）。"""
    N = types.SimpleNamespace
    if with_engine:
        return N(engine=N(scheduler=N(decoder=decoder, max_streams=5)),
                 effective_context_window=262144)
    return N(effective_context_window=262144)


def make_dec(streams=None, filling=None, fills=None):
    """造一个带三张表的假 decoder。"""
    return types.SimpleNamespace(
        streams={} if streams is None else streams,
        filling=[] if filling is None else filling,
        fills={} if fills is None else fills)


def full_app():
    """check.py 第 3 项那组数据：一条解码流 sid=3、一条预填充流 sid=4。"""
    dec = make_dec(streams={3: S(sid=3, prompt=[0] * 18420, cached=16384, out=[1] * 312)},
                   filling=[S(sid=4, prompt=[0] * 24615, cached=2048)],
                   fills={4: [None, None, 10240, None]})
    return make_app(dec)


class HookTestCase(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="tfpanel-hook-test-")
        self.saved_path = list(sys.path)
        self.saved_meta = list(sys.meta_path)
        pkg = os.path.join(self.tmp, "tensorfold")
        os.makedirs(os.path.join(pkg, "cuda"))
        for rel in (os.path.join("tensorfold", "__init__.py"),
                    os.path.join("tensorfold", "cuda", "__init__.py")):
            with open(os.path.join(self.tmp, rel), "w", encoding="utf-8") as f:
                f.write("")
        self.write_health(FAKE_HEALTH_OK)
        # 每个测试都从干净的 sys.modules 开始，并干净地导入一次外挂
        for name in list(sys.modules):
            if name == "tfpanel_hook" or name == "tensorfold" or name.startswith("tensorfold."):
                del sys.modules[name]
        sys.path.append(HOOK_DIR)
        sys.path.append(self.tmp)
        self.hookmod = __import__("tfpanel_hook")

    def tearDown(self):
        # 恢复 sys.path、sys.meta_path，清掉 sys.modules 里的 tensorfold* 和 tfpanel_hook
        sys.path[:] = self.saved_path
        sys.meta_path[:] = self.saved_meta
        for name in list(sys.modules):
            if name == "tfpanel_hook" or name == "tensorfold" or name.startswith("tensorfold."):
                del sys.modules[name]
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_health(self, text):
        with open(os.path.join(self.tmp, "tensorfold", "cuda", "health.py"),
                  "w", encoding="utf-8") as f:
            f.write(text)

    def wrap(self, snapshot_fn):
        """直接调用 patch_health 包好一个假 health 模块，返回该模块。"""
        mod = types.ModuleType("fake_health")
        mod.Health = type("Health", (), {"snapshot": snapshot_fn})
        self.assertTrue(self.hookmod.patch_health(mod))
        return mod

    def assertNoSection(self, body):
        """降级断言：没有 tfpanel 键、其他键的键值和原来一样。"""
        self.assertNotIn("tfpanel", body)
        self.assertEqual({k: v for k, v in body.items() if k != "tfpanel"},
                         {"ok": True, "streams": {"decoding": 1, "prefilling": 1, "max": 5}})


class TestImportHook(HookTestCase):

    def test_01_hook_registered_then_removed(self):
        # 导入外挂后、导入假 health 之前：tensorfold 不在 sys.modules 里，钩子已登记
        self.assertNotIn("tensorfold", sys.modules)
        self.assertEqual(1, sum(1 for f in sys.meta_path
                                if isinstance(f, self.hookmod._Finder)))
        import tensorfold.cuda.health as h
        # 导入之后：snapshot 已被包装，钩子已从 sys.meta_path 摘掉
        self.assertTrue(getattr(h.Health.snapshot, "__tfpanel_wrapped__", False))
        self.assertFalse(any(isinstance(f, self.hookmod._Finder) for f in sys.meta_path))

    def test_02_build_section_equals_expected(self):
        self.assertEqual(EXPECTED_FULL, self.hookmod.build_section(full_app()))

    def test_12_syntax_error_propagates(self):
        self.write_health(FAKE_HEALTH_BROKEN)
        with self.assertRaises(SyntaxError):
            __import__("tensorfold.cuda.health")


class TestSectionBuilding(HookTestCase):

    def test_03_wrapper_returns_same_object(self):
        sentinel = {"ok": True, "streams": {"decoding": 1, "prefilling": 1, "max": 5}}

        def snapshot(self, app):
            return sentinel

        mod = self.wrap(snapshot)
        body = mod.Health().snapshot(full_app())
        self.assertIs(body, sentinel)  # 返回的是原函数返回的同一个对象
        self.assertEqual(body["tfpanel"], EXPECTED_FULL)

    def test_04_original_exception_propagates(self):
        boom = ValueError("boom")

        def snapshot(self, app):
            raise boom

        mod = self.wrap(snapshot)
        with self.assertRaises(ValueError) as cm:
            mod.Health().snapshot(full_app())
        self.assertIs(cm.exception, boom)

    def test_05_degrade_cases(self):
        app_cases = [
            ("app 没有 engine", make_app(with_engine=False)),
            ("decoder 为 None", make_app(None)),
            ("decoder 缺 fills", make_app(types.SimpleNamespace(
                streams={7: S(sid=7, prompt=[0] * 10, cached=2, out=[1] * 3)}, filling=[]))),
            ("streams 是列表", make_app(make_dec(streams=[S(sid=1, prompt=[0] * 5, cached=0, out=[1] * 2)]))),
            ("流缺 cached", make_app(make_dec(streams={7: S(sid=7, prompt=[0] * 10, out=[1] * 3)}))),
            ("prompt 是 None", make_app(make_dec(streams={7: S(sid=7, prompt=None, cached=1, out=[1] * 3)}))),
            ("fills 只有 2 个元素", make_app(make_dec(filling=[S(sid=4, prompt=[0] * 100, cached=8)],
                                                      fills={4: [None, None]}))),
        ]

        def snapshot(self, app):
            return {"ok": True, "streams": {"decoding": 1, "prefilling": 1, "max": 5}}

        for name, app in app_cases:
            with self.subTest(name):
                mod = self.wrap(snapshot)
                body = mod.Health().snapshot(app)
                self.assertNoSection(body)
                # 直接调 build_section 也必须是 None
                self.assertIsNone(self.hookmod.build_section(app))

    def test_06_prefill_without_fills_row(self):
        # 预填充的流不在 fills 里：filled == len(prompt)
        app = make_app(make_dec(filling=[S(sid=4, prompt=[0] * 100, cached=8)], fills={}))
        self.assertEqual({"v": 1, "streams": [{"id": 4, "phase": "prefill", "prompt": 100,
                                               "cached": 8, "filled": 100}]},
                         self.hookmod.build_section(app))

    def test_07_dup_id_only_decode(self):
        # 同一个 id 两张表都有：只保留 decode 那一行
        s_dec = S(sid=9, prompt=[0] * 50, cached=5, out=[1] * 7)
        s_fill = S(sid=9, prompt=[0] * 50, cached=5)
        app = make_app(make_dec(streams={9: s_dec}, filling=[s_fill],
                                fills={9: [None, None, 20, None]}))
        section = self.hookmod.build_section(app)
        self.assertEqual(1, len(section["streams"]))
        self.assertEqual("decode", section["streams"][0]["phase"])

    def test_08_sorted_by_id(self):
        dec = make_dec(streams={7: S(sid=7, prompt=[0] * 10, cached=0, out=[1]),
                                2: S(sid=2, prompt=[0] * 10, cached=0, out=[1]),
                                5: S(sid=5, prompt=[0] * 10, cached=0, out=[1])})
        section = self.hookmod.build_section(make_app(dec))
        self.assertEqual([2, 5, 7], [r["id"] for r in section["streams"]])

    def test_09_runtimeerror_retry(self):
        class FlakyDict(dict):
            """假 streams 表：values() 前 fails 次抛 RuntimeError，之后正常。"""

            def __init__(self, items, fails):
                dict.__init__(self, items)
                self.fails = fails
                self.calls = 0

            def values(self):
                self.calls += 1
                if self.calls <= self.fails:
                    raise RuntimeError("表正在被改")
                return dict.values(self)

        def flaky_app(fails):
            streams = FlakyDict({2: S(sid=2, prompt=[0] * 10, cached=1, out=[1])}, fails)
            return make_app(make_dec(streams=streams))

        # 前两次抛、第三次正常（最多 3 次）：能拿到结果
        section = self.hookmod.build_section(flaky_app(2))
        self.assertIsNotNone(section)
        self.assertEqual(1, len(section["streams"]))
        # 一直抛：build_section 返回 None，包装后的结果里没有 tfpanel
        self.assertIsNone(self.hookmod.build_section(flaky_app(99)))

        def snapshot(self, app):
            return {"ok": True, "streams": {"decoding": 1, "prefilling": 1, "max": 5}}

        mod = self.wrap(snapshot)
        body = mod.Health().snapshot(flaky_app(99))
        self.assertNoSection(body)

    def test_10_non_dict_body_returned_as_is(self):
        mod = self.wrap(lambda self, app: None)
        self.assertIsNone(mod.Health().snapshot(full_app()))
        mod2 = self.wrap(lambda self, app: "42")
        self.assertEqual("42", mod2.Health().snapshot(full_app()))


class TestSelfCheck(HookTestCase):

    def test_11a_missing_health_or_snapshot(self):
        buf = io.StringIO()
        with redirect_stderr(buf):
            # 假模块没有 Health
            self.assertFalse(self.hookmod.patch_health(types.ModuleType("m_nohealth")))
            # Health 没有 snapshot
            mod = types.ModuleType("m_nosnap")
            mod.Health = type("Health", (), {})
            self.assertFalse(self.hookmod.patch_health(mod))
        lines = [ln for ln in buf.getvalue().splitlines()
                 if ln.startswith("[tfpanel] 外挂未挂载")]
        self.assertEqual(2, len(lines), buf.getvalue())

    def test_11b_repeat_patch_wraps_once(self):
        calls = []

        def orig(self, app):
            calls.append(1)
            return {"ok": True}

        mod = self.wrap(orig)
        # 重复 patch_health 不再包第二层，仍返回 True
        self.assertTrue(self.hookmod.patch_health(mod))
        self.assertIs(mod.Health.snapshot.__wrapped__, orig)  # 只包了一层
        body = mod.Health().snapshot(full_app())
        self.assertEqual([1], calls)  # 调一次 snapshot，原函数只被调一次
        self.assertEqual({"ok": True, "tfpanel": EXPECTED_FULL}, body)


class TestPatchFile(HookTestCase):

    def read(self, *parts):
        with open(os.path.join(HOOK_DIR, *parts), encoding="utf-8") as f:
            return f.read()

    def read_bytes(self, *parts):
        with open(os.path.join(HOOK_DIR, *parts), "rb") as f:
            return f.read()

    def test_13_build_patch_and_patch_command(self):
        import make_patch
        pth_text = self.read("tfpanel_hook.pth")
        py_text = self.read("tfpanel_hook.py")
        patch_text = make_patch.build_patch(pth_text, py_text)
        self.assertEqual(
            "tfpanel side-screen hook: adds two new files, changes no TensorFold file.",
            patch_text.splitlines()[0])
        with tempfile.TemporaryDirectory() as td:
            proc = subprocess.run(["patch", "-p0", "--forward"], cwd=td,
                                  input=patch_text.encode("utf-8"),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(0, proc.returncode,
                             f"patch 退出码 {proc.returncode}：{proc.stdout!r} {proc.stderr!r}")
            for name in ("tfpanel_hook.pth", "tfpanel_hook.py"):
                with open(os.path.join(td, name), "rb") as f:
                    produced = f.read()
                self.assertEqual(self.read_bytes(name), produced,
                                 f"{name} 用 patch 解开后应与源文件逐字节相同")

    def test_14_repo_patch_is_up_to_date(self):
        import make_patch
        generated = make_patch.build_patch(self.read("tfpanel_hook.pth"),
                                           self.read("tfpanel_hook.py"))
        self.assertEqual(generated, self.read("0900-tfpanel-hook.patch"),
                         "补丁与源文件不一致：请重新运行 python3 hook/make_patch.py")


if __name__ == "__main__":
    unittest.main(verbosity=2)
