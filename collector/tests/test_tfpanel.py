"""collector/tfpanel.py 的单元测试（只用标准库 unittest）。

全部使用假的 TensorFold（假 ChatApp、假 tokenizer、假时钟），
不依赖真实 TensorFold 和真实模型，不 sleep 等真实时间（HTTP 测试除外）。
"""
from __future__ import annotations

import http.client
import json
import shutil
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tfpanel  # noqa: E402  导入 tfpanel 本身不能有副作用


# ---------------------------------------------------------------- 假组件


class FakeClock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, dt):
        self.t += dt


class FakeTokenizer:
    """按空格切分：一个单词 = 一个 token。"""

    def encode(self, text, add_special_tokens=False):
        return text.split()


class LegacyTokenizer:
    """不支持 add_special_tokens 参数的旧版分词器。"""

    def encode(self, text):
        return text.split()


class BrokenTokenizer:
    def encode(self, *args, **kwargs):
        raise RuntimeError("tokenizer boom")


class FakeChatApp:
    """和真实 ChatApp 一样的构造属性与 chat 签名。"""

    def __init__(self, tokenizer=None, served_name="fake-model", context_window=4096):
        self.tokenizer = tokenizer
        self.served_name = served_name
        self.context_window = context_window
        self.tokenizer_lock = threading.Lock()
        self.seen = []


def make_app_cls(reply=None, exc=None, deltas=()):
    """构造一个 chat 行为可配置的假 ChatApp 类。"""

    def chat(self, messages, *, max_tokens=None, temperature=0.0,
             on_delta=None, tools=None, sampling=None):
        self.seen.append({"messages": messages, "max_tokens": max_tokens,
                          "temperature": temperature, "on_delta": on_delta,
                          "tools": tools, "sampling": sampling})
        if exc is not None:
            raise exc
        if on_delta is not None:
            for d in deltas:
                on_delta(d)
        return reply

    return type("FakeChatApp", (FakeChatApp,), {"chat": chat})


def fake_module(cls):
    module = types.ModuleType("faketensorfold.app")
    module.ChatApp = cls
    return module


def make_collector(clock, **kwargs):
    return tfpanel.Collector(clock=clock, start_worker=False, **kwargs)


FULL_REPLY = {
    "finish_reason": "stop",
    "prompt_tokens": 22,
    "cached_tokens": 0,
    "completion_tokens": 570,
    "runtime": {"tokens_per_second": 58.2, "time_to_first_token": 0.457},
    "speculative": {"acceptance_rate": 0.64},
}


# ---------------------------------------------------------------- 包装行为


class TestWrappedChat(unittest.TestCase):

    def _setup(self, cls):
        self.clock = FakeClock()
        self.collector = make_collector(self.clock)
        self.hooks = {"chat": "missing"}
        module = fake_module(cls)
        self.assertTrue(tfpanel.patch_chat_app(module, self.collector, self.hooks))
        self.assertEqual(self.hooks["chat"], "ok")
        return cls()

    def test_returns_same_object_and_forwards_args(self):
        """1. 返回值是同一个对象，参数原样传到原函数。"""
        reply = dict(FULL_REPLY)
        app = self._setup(make_app_cls(reply=reply))
        msgs = [{"role": "user", "content": "hi"}]
        tools = [{"name": "x"}]
        sampling = {"top_p": 0.9}
        out = app.chat(msgs, max_tokens=9, temperature=0.3,
                       on_delta=None, tools=tools, sampling=sampling)
        self.assertIs(out, reply)
        seen = app.seen[0]
        self.assertIs(seen["messages"], msgs)
        self.assertEqual(seen["max_tokens"], 9)
        self.assertEqual(seen["temperature"], 0.3)
        self.assertIsNone(seen["on_delta"])  # 3. on_delta=None 时原函数收到的仍是 None
        self.assertIs(seen["tools"], tools)
        self.assertIs(seen["sampling"], sampling)
        # 只传位置参数也不影响
        self.assertIs(app.chat(msgs), reply)

    def test_exception_propagates_unchanged(self):
        """2. 原 chat 抛出的异常原样抛出，且不进入 done、last 不变。"""
        boom = ValueError("boom")
        app = self._setup(make_app_cls(exc=boom))
        with self.assertRaises(ValueError) as ctx:
            app.chat([{"role": "user", "content": "hi"}])
        self.assertIs(ctx.exception, boom)
        self.assertIsNone(self.collector.last)
        self.assertIsNone(self.collector.current_request())
        self.assertEqual(self.collector.totals["requests"], 0)
        self.assertEqual(self.collector.state(), "idle")  # 不进入 done

    def test_on_delta_receives_all_in_order(self):
        """4. 原 on_delta 按顺序收到全部增量（str 和 dict 都有）。"""
        deltas = ["h1 h2", {"reasoning_content": "c"}, {"tool": "d e"}]
        received = []
        captured = {}

        def cb(d):
            received.append(d)
            if d == "h1 h2":
                captured["req"] = self.collector.current_request()

        app_cls = make_app_cls(reply={"ok": 1}, deltas=tuple(deltas))
        self._setup(app_cls)
        app = app_cls(tokenizer=FakeTokenizer())
        app.chat([{"role": "user", "content": "hi"}], on_delta=cb)
        self.assertEqual(len(received), 3)
        for got, want in zip(received, deltas):
            self.assertIs(got, want)
        req = captured["req"]
        # 增量文字都进了采集器（含 dict 里的嵌套文字）
        self.assertEqual([text for _, text in req.deltas], ["h1 h2", "c", "d e"])
        # 请求完成后已移出进行中，直接调用换算逻辑验证 token 数
        # 拼起来是 "h1 h2cd e" = 3 个单词 token
        self.collector._convert(req, self.clock())
        self.assertEqual(sum(c for _, c in req.events), 3)


    def test_on_delta_positional_only_start_end(self):
        """极端情况：on_delta 以位置参数传入时不改 args，只做开始/结束记录。"""

        class PositionalApp(FakeChatApp):
            def chat(self, messages, max_tokens=None, on_delta=None):
                self.seen.append((messages, max_tokens, on_delta))
                if on_delta is not None:
                    on_delta("x")
                return {"ok": 1}

        self._setup(PositionalApp)
        app = PositionalApp()
        msgs = [{"role": "user", "content": "hi"}]
        cb = lambda d: None
        out = app.chat(msgs, 9, cb)  # on_delta 是第三个位置参数
        self.assertEqual(out, {"ok": 1})
        self.assertEqual(app.seen[0], (msgs, 9, cb))  # args 原样，回调没被换
        self.assertIsNotNone(self.collector.last)  # 但开始/结束有记录


class TestCollectorErrors(unittest.TestCase):

    def test_internal_error_does_not_fail_request(self):
        """5. 采集器内部出错（tokenizer.encode 抛异常）时请求照常成功返回。"""
        clock = FakeClock()
        collector = make_collector(clock)
        hooks = {"chat": "missing"}
        app_cls = make_app_cls(reply={"ok": 1}, deltas=("w1 w2",))
        self.assertTrue(tfpanel.patch_chat_app(fake_module(app_cls), collector, hooks))
        app = app_cls(tokenizer=BrokenTokenizer())
        out = app.chat([{"role": "user", "content": "hi"}], on_delta=lambda d: None)
        self.assertEqual(out, {"ok": 1})
        self.assertIsNotNone(collector.last)
        clock.advance(1.0)
        collector.tick()  # 抛异常的 tokenizer 不能把 tick 弄崩

    def test_legacy_tokenizer_falls_back(self):
        """tokenizer 不支持 add_special_tokens 时退回 encode(text)。"""
        clock = FakeClock()
        collector = make_collector(clock)
        app = FakeChatApp(tokenizer=LegacyTokenizer())
        collector.register_instance(app)
        req = collector.begin()
        collector.delta(req, "a b c")
        clock.advance(1.0)
        collector.tick()
        self.assertEqual(sum(c for _, c in req.events), 3)

    def test_racing_delta_not_lost(self):
        """并发竞争：encode 执行期间 on_delta 线程追加的增量不能丢。"""
        clock = FakeClock(100.0)
        collector = make_collector(clock)
        req = collector.begin()
        clock.t = 100.1
        collector.delta(req, "a b")

        class RacingTokenizer:
            """encode 被调用时往 req.deltas 追加一条新增量，模拟竞争。"""

            def encode(self, text, add_special_tokens=False):
                req.deltas.append((100.1, "x y"))
                return text.split()

        collector._tokenizer = RacingTokenizer()
        collector.tick()
        clock.t = 100.2
        collector.tick()
        # 两次 tick 后："a b" 和竞争中追加的 "x y" 都要被计入
        self.assertEqual(req.total_tokens, 4)
        self.assertIn("x y", [seg for _, seg in req.deltas])

    def test_snapshot_and_add_event_no_race(self):
        """1. 线程竞争：一个线程不停追加事件，另一个不停 snapshot，0.5 秒内无异常。"""
        collector = tfpanel.Collector(start_worker=False)
        collector.register_instance(FakeChatApp())
        req = collector.begin()
        collector.delta(req, "a")
        errors = []
        deadline = time.monotonic() + 0.5

        def writer():
            try:
                while time.monotonic() < deadline:
                    now = time.perf_counter()
                    collector._add_event(req, now, 1.0, now)
            except Exception as exc:
                errors.append(exc)

        def reader():
            try:
                while time.monotonic() < deadline:
                    collector.snapshot()
            except Exception as exc:
                errors.append(exc)

        tw = threading.Thread(target=writer)
        tr = threading.Thread(target=reader)
        tw.start()
        tr.start()
        tw.join()
        tr.join()
        self.assertEqual(errors, [])


class TestStateAndSpeeds(unittest.TestCase):

    def test_state_transitions(self):
        """6. idle → prefill → decode → done →（done_hold_s 之后）idle。"""
        clock = FakeClock()
        collector = make_collector(clock, done_hold_s=4.0)
        self.assertEqual(collector.state(), "idle")
        req = collector.begin()
        self.assertEqual(collector.state(), "prefill")
        clock.advance(0.5)
        collector.delta(req, "x")
        self.assertEqual(collector.state(), "decode")
        collector.finish(req, dict(FULL_REPLY))
        self.assertEqual(collector.state(), "done")
        clock.advance(3.0)
        self.assertEqual(collector.state(), "done")
        clock.advance(1.2)
        self.assertEqual(collector.state(), "idle")

    def test_speeds_with_fake_clock(self):
        """7. decode_tps 窗口、peak 的 1 秒门槛、avg 的 0.5 秒门槛，精确断言。"""
        clock = FakeClock(1000.0)
        collector = make_collector(clock, window_s=2.5)
        app = FakeChatApp(tokenizer=FakeTokenizer())
        collector.register_instance(app)

        # 一次请求：两段文字 “a b”“c d”，首字在 1000.4，算到 1003.0
        req = collector.begin()
        clock.t = 1000.4
        collector.delta(req, "a b")
        clock.t = 1001.4
        collector.delta(req, "c d")
        clock.t = 1003.0
        collector.tick()
        # 拼接后 "a bc d" = 3 个 token，按长度各摊 1.5；
        # 窗口 (1000.5, 1003.0] 只含 1001.4 那段：1.5 / 2.5 = 0.6
        cur = collector.snapshot()["current"]
        self.assertEqual(cur["output_tokens"], 3)
        self.assertAlmostEqual(cur["decode_tps"], 1.5 / 2.5, places=3)
        self.assertAlmostEqual(cur["decode_tps_peak"], 1.5 / 2.5, places=3)
        self.assertAlmostEqual(cur["decode_tps_avg"], 3.0 / 2.6, places=3)
        self.assertAlmostEqual(cur["ttft_s"], 0.4, places=3)
        self.assertAlmostEqual(cur["elapsed_s"], 3.0, places=3)

        # 解码不足 1 秒：peak 为 0，但 tps 分母用实际经过时间
        req2 = collector.begin()  # t=1003.0
        clock.t = 1003.4
        collector.delta(req2, "x1 x2")
        clock.t = 1004.0
        collector.tick()
        cur = collector.snapshot()["current"]
        self.assertAlmostEqual(cur["decode_tps"], 2 / 0.6, places=3)
        self.assertEqual(cur["decode_tps_peak"], 0.0)
        self.assertAlmostEqual(cur["decode_tps_avg"], 2 / 0.6, places=3)

        # 解码不满 0.5 秒：avg 为 null；满 0.5 秒后有值
        req3 = collector.begin()  # t=1004.0
        clock.t = 1004.5
        collector.delta(req3, "y1 y2")
        collector.tick()
        cur = collector.snapshot()["current"]
        self.assertIsNone(cur["decode_tps_avg"])
        clock.t = 1005.0
        collector.tick()
        cur = collector.snapshot()["current"]
        self.assertAlmostEqual(cur["decode_tps_avg"], 2 / 0.5, places=3)


class TestLastMapping(unittest.TestCase):

    def test_last_fields_from_report(self):
        """8. last 各字段映射正确。"""
        clock = FakeClock()
        collector = make_collector(clock)
        req = collector.begin()
        collector.finish(req, json.loads(json.dumps(FULL_REPLY)))
        last = collector.last
        self.assertEqual(last["prompt_tokens"], 22)
        self.assertEqual(last["cached_tokens"], 0)
        self.assertEqual(last["completion_tokens"], 570)
        self.assertAlmostEqual(last["decode_tps"], 58.2, places=3)
        self.assertAlmostEqual(last["ttft_s"], 0.457, places=3)
        self.assertAlmostEqual(last["acceptance_rate"], 0.64, places=3)
        self.assertEqual(last["context_used"], 592)
        self.assertEqual(last["finish_reason"], "stop")
        self.assertEqual(collector.totals["requests"], 1)

    def test_last_missing_fields_become_null(self):
        """成绩单缺字段时对应为 null，其他字段正常。"""
        clock = FakeClock()
        collector = make_collector(clock)
        collector.finish(collector.begin(),
                         {"prompt_tokens": 5, "completion_tokens": 7,
                          "finish_reason": "length"})
        last = collector.last
        self.assertEqual(last["prompt_tokens"], 5)
        self.assertEqual(last["completion_tokens"], 7)
        self.assertEqual(last["context_used"], 12)
        self.assertEqual(last["finish_reason"], "length")
        for key in ("cached_tokens", "decode_tps", "ttft_s", "acceptance_rate"):
            self.assertIsNone(last[key])
        # runtime 不是 dict 也安全
        collector.finish(collector.begin(), {"prompt_tokens": 3, "runtime": "weird"})
        self.assertIsNone(collector.last["decode_tps"])
        self.assertEqual(collector.last["prompt_tokens"], 3)


class TestSelfCheck(unittest.TestCase):

    def test_missing_on_delta_no_patch(self):
        """9. chat 没有 on_delta 参数时不打补丁、hooks.chat == "missing"。"""
        collector = make_collector(FakeClock())

        class NoOnDeltaApp:
            def chat(self, messages):
                return {}

        module = fake_module(NoOnDeltaApp)
        original = NoOnDeltaApp.chat
        hooks = {"chat": "missing"}
        self.assertFalse(tfpanel.patch_chat_app(module, collector, hooks))
        self.assertEqual(hooks["chat"], "missing")
        self.assertIs(module.ChatApp.chat, original)  # 没被打补丁

    def test_module_without_chatapp(self):
        module = types.ModuleType("empty")
        hooks = {"chat": "missing"}
        self.assertFalse(tfpanel.patch_chat_app(module, make_collector(FakeClock()), hooks))
        self.assertEqual(hooks["chat"], "missing")

    def test_force_hook_fail(self):
        """TFPANEL_FORCE_HOOK_FAIL=1 强制走“不通过”分支。"""
        collector = make_collector(FakeClock())
        app_cls = make_app_cls(reply={"ok": 1})
        module = fake_module(app_cls)
        original = app_cls.chat
        hooks = {"chat": "ok"}
        self.assertFalse(tfpanel.run_self_check(module, collector, hooks,
                                                force_fail=True))
        self.assertEqual(hooks["chat"], "missing")
        self.assertIs(module.ChatApp.chat, original)  # 没被打补丁

    def test_pass_patches_chat(self):
        collector = make_collector(FakeClock())
        app_cls = make_app_cls(reply={"ok": 1})
        module = fake_module(app_cls)
        original = app_cls.chat
        hooks = {"chat": "missing"}
        self.assertTrue(tfpanel.run_self_check(module, collector, hooks))
        self.assertEqual(hooks["chat"], "ok")
        self.assertIsNot(module.ChatApp.chat, original)
        self.assertIsNotNone(getattr(module.ChatApp.chat, "__wrapped__", None))


class TestImportHook(unittest.TestCase):

    def test_hook_fires_after_module_executes(self):
        """10. import 之前补丁没有执行、import 之后 ChatApp.chat 已被包装。"""
        tmp = Path(tempfile.mkdtemp(prefix="tfpanel-test-"))
        finder = None
        try:
            pkg = tmp / "tensorfold"
            server = pkg / "server"
            server.mkdir(parents=True)
            (pkg / "__init__.py").write_text('__version__ = "9.9.9-test"\n')
            (server / "__init__.py").write_text("")
            (server / "app.py").write_text(
                "class ChatApp:\n"
                "    def __init__(self):\n"
                "        pass\n"
                "    def chat(self, messages, *, on_delta=None):\n"
                "        return {'ok': True}\n")
            for name in ("tensorfold", "tensorfold.server", "tensorfold.server.app"):
                sys.modules.pop(name, None)
            sys.path.insert(0, str(tmp))
            collector = make_collector(FakeClock())
            hooks = {"chat": "pending"}
            calls = []

            def on_module(module):
                calls.append(module)
                tfpanel.run_self_check(module, collector, hooks)

            finder = tfpanel.install_hook(on_module)
            self.assertIsNotNone(finder)
            self.assertEqual(calls, [])  # 导入之前补丁没有执行
            self.assertNotIn("tensorfold.server.app", sys.modules)

            import tensorfold.server.app as appmod  # noqa: PLC0415

            self.assertEqual(len(calls), 1)
            self.assertIs(calls[0], appmod)
            self.assertEqual(hooks["chat"], "ok")
            self.assertIsNotNone(getattr(appmod.ChatApp.chat, "__wrapped__", None))
            self.assertEqual(appmod.__package__, "tensorfold.server")
        finally:
            if finder is not None:
                sys.meta_path.remove(finder)
            for name in ("tensorfold", "tensorfold.server", "tensorfold.server.app"):
                sys.modules.pop(name, None)
            sys.path.remove(str(tmp))
            importlib_invalidate()
            shutil.rmtree(tmp, ignore_errors=True)


def importlib_invalidate():
    import importlib
    importlib.invalidate_caches()


class TestHookStates(unittest.TestCase):
    """3. 加载期间自检未运行 → pending；找不到模块 → missing。"""

    def test_pending_when_module_found_missing_when_not(self):
        tmp = Path(tempfile.mkdtemp(prefix="tfpanel-test-"))
        try:
            pkg = tmp / "tensorfold"
            server = pkg / "server"
            server.mkdir(parents=True)
            (pkg / "__init__.py").write_text("")
            (server / "__init__.py").write_text("")
            (server / "app.py").write_text("class ChatApp:\n    pass\n")
            sys.path.insert(0, str(tmp))
            for name in ("tensorfold", "tensorfold.server", "tensorfold.server.app"):
                sys.modules.pop(name, None)
            importlib_invalidate()
            self.assertEqual(tfpanel.decide_initial_hook_state(), "pending")
        finally:
            sys.path.remove(str(tmp))
            for name in ("tensorfold", "tensorfold.server", "tensorfold.server.app"):
                sys.modules.pop(name, None)
            importlib_invalidate()
            shutil.rmtree(tmp, ignore_errors=True)
        self.assertEqual(tfpanel.decide_initial_hook_state(
            "definitely_not_exist_xyz.module"), "missing")

    def test_pending_resolves_to_ok_after_self_check(self):
        hooks = {"chat": "pending"}
        app_cls = make_app_cls(reply={"ok": 1})
        module = fake_module(app_cls)
        self.assertTrue(tfpanel.run_self_check(module, make_collector(FakeClock()), hooks))
        self.assertEqual(hooks["chat"], "ok")

    def test_pending_resolves_to_missing_when_forced(self):
        hooks = {"chat": "pending"}
        app_cls = make_app_cls(reply={"ok": 1})
        module = fake_module(app_cls)
        tfpanel.run_self_check(module, make_collector(FakeClock()), hooks,
                               force_fail=True)
        self.assertEqual(hooks["chat"], "missing")


class TestMetricsHttp(unittest.TestCase):

    def test_metrics_endpoint(self):
        """11. /metrics 返回合法 JSON 且含全部顶层字段；其他路径 404。"""
        clock = FakeClock(1000.0)
        collector = make_collector(clock)
        collector.tensorfold_version = "0.3.4"
        collector.register_instance(
            FakeChatApp(served_name="Qwen3.8-27B-MLX-4bit", context_window=262144))
        server = tfpanel.make_metrics_server(0, collector)
        port = server.server_address[1]
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics",
                                        timeout=5) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers["Content-Type"],
                                 "application/json; charset=utf-8")
                self.assertEqual(resp.headers["Cache-Control"], "no-store")
                data = json.loads(resp.read().decode("utf-8"))
            for key in ("version", "state", "engine_ready", "model",
                        "tensorfold_version", "context_max", "hooks",
                        "current", "last", "totals", "round"):
                self.assertIn(key, data)
            self.assertEqual(data["version"], 1)
            self.assertEqual(data["state"], "idle")
            self.assertTrue(data["engine_ready"])
            self.assertEqual(data["model"], "Qwen3.8-27B-MLX-4bit")
            self.assertEqual(data["tensorfold_version"], "0.3.4")
            self.assertEqual(data["context_max"], 262144)
            self.assertIsNone(data["current"])
            self.assertIsNone(data["last"])
            self.assertEqual(data["totals"]["requests"], 0)
            self.assertEqual(data["totals"]["peak_tps"], 0.0)
            self.assertIn("uptime_s", data["totals"])

            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/other", timeout=5)
            self.assertEqual(ctx.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()

    def test_port_in_use_raises(self):
        """端口被占用时 make_metrics_server 抛错，由 main 打印并继续。"""
        collector = make_collector(FakeClock())
        s1 = tfpanel.make_metrics_server(0, collector)
        busy_port = s1.server_address[1]
        try:
            with self.assertRaises(Exception):
                tfpanel.make_metrics_server(busy_port, collector)
        finally:
            s1.shutdown()
            s1.server_close()

    def test_snapshot_error_returns_500(self):
        """2. snapshot 抛异常时返回 500 空 body，不能冒充“指标不可用”的数据。"""
        collector = make_collector(FakeClock())

        def boom():
            raise RuntimeError("boom")

        collector.snapshot = boom
        server = tfpanel.make_metrics_server(0, collector)
        port = server.server_address[1]
        try:
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=5)
            self.assertEqual(ctx.exception.code, 500)
            self.assertEqual(ctx.exception.read(), b"")
        finally:
            server.shutdown()
            server.server_close()

    def test_keep_alive_reuses_connection(self):
        """12. 同一条 HTTP 连接连续请求 3 次 /metrics 都成功（HTTP/1.1 keep-alive）。"""
        collector = make_collector(FakeClock())
        server = tfpanel.make_metrics_server(0, collector)
        port = server.server_address[1]
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                for _ in range(3):
                    conn.request("GET", "/metrics")
                    resp = conn.getresponse()
                    body = resp.read()  # 读完 body 连接才能复用
                    self.assertEqual(resp.status, 200)
                    json.loads(body.decode("utf-8"))
            finally:
                conn.close()
        finally:
            server.shutdown()
            server.server_close()


def _round_reply(completion=None, tps=None, include_tps=True):
    """构造一份成绩单：可去掉/置零 completion_tokens 和 tokens_per_second。"""
    reply = {"finish_reason": "stop"}
    if completion is not None:
        reply["completion_tokens"] = completion
    if include_tps:
        reply["runtime"] = ({"tokens_per_second": tps} if tps is not None else {})
    return reply


class TestRound(unittest.TestCase):
    """一轮统计：间隔内的连续请求合并为一轮，/metrics 的 round 字段。"""

    def _collector(self, clock=None, gap=60.0):
        if clock is None:
            clock = FakeClock(0.0)
        return tfpanel.Collector(clock=clock, start_worker=False,
                                 round_gap_s=gap)

    def test_round_none_before_begin(self):
        """1. 启动后未 begin 过：round 为 null。"""
        self.assertIsNone(self._collector().snapshot()["round"])

    def test_round_after_first_begin(self):
        """2. 第一个请求 begin 后：round 出现，计数为 0，active 为 true。"""
        c = self._collector(FakeClock(1000.0))
        c.begin()
        self.assertEqual(c.snapshot()["round"],
                         {"requests": 0, "output_tokens": 0, "decode_tps_avg": None,
                          "elapsed_s": 0.0, "active": True})

    def test_same_round_when_within_gap(self):
        """3. finish 在 t=10、下个 begin 在 t=70（间隔恰好 60）→ 同一轮。"""
        clock = FakeClock(0.0)
        c = self._collector(clock)
        r1 = c.begin()
        clock.advance(10)
        c.finish(r1, _round_reply(100))
        clock.advance(60)   # t=70，距上次活动 60 ≤ round_gap_s → 并入当前轮
        r2 = c.begin()
        clock.advance(5)
        c.finish(r2, _round_reply(200))
        rd = c.snapshot()["round"]
        self.assertEqual(rd["requests"], 2)
        self.assertEqual(rd["output_tokens"], 300)

    def test_new_round_when_gap_exceeded(self):
        """4. 间隔 60.001 > round_gap_s → 新的一轮，计数清零。"""
        clock = FakeClock(0.0)
        c = self._collector(clock)
        r1 = c.begin()
        clock.advance(10)
        c.finish(r1, _round_reply(100, tps=50))
        clock.advance(60.001)  # t=70.001 → 新轮
        r2 = c.begin()
        rd = c.snapshot()["round"]
        self.assertEqual(rd["requests"], 0)
        self.assertEqual(rd["output_tokens"], 0)
        self.assertIsNone(rd["decode_tps_avg"])
        self.assertTrue(rd["active"])
        c.finish(r2, _round_reply(200))
        rd = c.snapshot()["round"]
        self.assertEqual(rd["requests"], 1)
        self.assertEqual(rd["output_tokens"], 200)

    def test_avg_token_weighted(self):
        """5. 平均速度按 token 加权：400 ÷ 5 = 80.0，不是 (50+100)/2。"""
        clock = FakeClock(0.0)
        c = self._collector(clock)
        rA = c.begin()
        clock.advance(2)
        c.finish(rA, _round_reply(100, tps=50))
        rB = c.begin()
        clock.advance(3)
        c.finish(rB, _round_reply(300, tps=100))
        self.assertEqual(c.snapshot()["round"]["decode_tps_avg"], 80.0)

    def test_non_participating_requests(self):
        """6. 缺 tps / tps=0 / completion=0：计入 requests 和 output_tokens，不参与平均。"""
        clock = FakeClock(0.0)
        c = self._collector(clock)
        r1 = c.begin()
        clock.advance(1)
        c.finish(r1, _round_reply(50, include_tps=False))
        r2 = c.begin()
        clock.advance(1)
        c.finish(r2, _round_reply(70, tps=0))
        r3 = c.begin()
        clock.advance(1)
        c.finish(r3, _round_reply(0, tps=100))
        rd = c.snapshot()["round"]
        self.assertEqual(rd["requests"], 3)
        self.assertEqual(rd["output_tokens"], 120)
        self.assertIsNone(rd["decode_tps_avg"])

    def test_fail_only_refreshes_last_activity(self):
        """7. fail 不计入 requests，但刷新 last_activity，不影响轮边界。"""
        clock = FakeClock(0.0)
        c = self._collector(clock)
        r1 = c.begin()
        c.finish(r1, _round_reply(100))  # finish 在 t=0
        r2 = c.begin()
        clock.advance(50)
        c.fail(r2)                        # fail 在 t=50，刷新 last_activity
        clock.advance(50)
        r3 = c.begin()                    # t=100，100-50=50 ≤ 60 → 仍是同一轮
        rd = c.snapshot()["round"]
        self.assertEqual(rd["requests"], 1)
        self.assertEqual(rd["output_tokens"], 100)
        c.fail(r3)

    def test_begin_always_joins_when_in_progress(self):
        """8. 有请求进行中时，另一个 begin 一定并入当前轮（即使超过 gap）。"""
        clock = FakeClock(0.0)
        c = self._collector(clock)
        r1 = c.begin()
        clock.advance(1000)  # 远超 round_gap_s
        r2 = c.begin()       # r1 进行中 → 并入
        c.finish(r1, _round_reply(10))
        c.finish(r2, _round_reply(20))
        rd = c.snapshot()["round"]
        self.assertEqual(rd["requests"], 2)
        self.assertEqual(rd["output_tokens"], 30)
        self.assertEqual(rd["elapsed_s"], 1000.0)

    def test_elapsed_s_freezes_when_idle(self):
        """9. 进行中 = now − 开始；空闲后停在 last_activity − 开始，不再变化。"""
        clock = FakeClock(0.0)
        c = self._collector(clock)
        r1 = c.begin()
        clock.advance(3)
        self.assertEqual(c.snapshot()["round"]["elapsed_s"], 3.0)
        clock.advance(2)
        c.finish(r1, _round_reply(5))
        self.assertEqual(c.snapshot()["round"]["elapsed_s"], 5.0)
        clock.advance(100)
        self.assertEqual(c.snapshot()["round"]["elapsed_s"], 5.0)
        clock.advance(1000)
        self.assertEqual(c.snapshot()["round"]["elapsed_s"], 5.0)

    def test_active_window(self):
        """10. 最后一次结束后 60 秒内 active=true，60.001 秒后 false；进行中为 true。"""
        clock = FakeClock(0.0)
        c = self._collector(clock)
        r1 = c.begin()
        c.finish(r1, _round_reply(5))  # 最后一次活动结束于 t=0
        clock.advance(59.999)
        self.assertTrue(c.snapshot()["round"]["active"])
        clock.advance(0.002)  # 距结束 60.001 > 60
        self.assertFalse(c.snapshot()["round"]["active"])
        r2 = c.begin()
        self.assertTrue(c.snapshot()["round"]["active"])
        c.fail(r2)


class TestRoundGapFromEnv(unittest.TestCase):
    """12. main() 的环境变量解析：round_gap_from_env。"""

    def test_unset_defaults_to_60(self):
        self.assertEqual(tfpanel.round_gap_from_env({}), 60.0)

    def test_valid_value(self):
        self.assertEqual(tfpanel.round_gap_from_env({"TFPANEL_ROUND_GAP_S": "30"}),
                         30.0)

    def test_invalid_values_fall_back_to_60(self):
        for value in ("abc", "0", "-5"):
            with self.subTest(value=value):
                self.assertEqual(
                    tfpanel.round_gap_from_env({"TFPANEL_ROUND_GAP_S": value}), 60.0)


if __name__ == "__main__":
    unittest.main()
