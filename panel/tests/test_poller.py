"""任务 I 轮询模块的测试：只用假对象和假时钟，不访问网络。"""

import json
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

from panel.collector import Collector
from panel.config import Config
from panel.poller import Poller, brief_line

REPO = str(Path(__file__).resolve().parents[2])


class FakeClock:
    """假时钟：返回当前时刻，测试里手动拨快（读取耗时也用它模拟）。"""

    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def advance(self, dt):
        self.t = round(self.t + dt, 6)


class ScriptedFetcher:
    """假读取：health 固定给一个值；metrics、model_name 记下被调用的次数。

    给了 clock 和 cost 时，health() 会把时钟拨快 cost 秒，模拟读 /health 花的时间。
    """

    def __init__(self, health=None, raise_health=False, model="Qwen3.8-Flash-Next",
                 clock=None, cost=0.0):
        self.health_value = health
        self.raise_health = raise_health
        self.model_value = model
        self.clock = clock
        self.cost = cost
        self.health_calls = 0
        self.metrics_calls = 0
        self.model_calls = 0

    def health(self):
        self.health_calls += 1
        if self.clock is not None and self.cost:
            self.clock.advance(self.cost)  # 读 /health 花掉的时间
        if self.raise_health:
            raise RuntimeError("读不到 /health")
        return self.health_value

    def metrics(self):
        self.metrics_calls += 1
        return {"waiting": 0, "kv_usage": [], "ttft_sum": None, "ttft_count": None}

    def model_name(self):
        self.model_calls += 1
        return self.model_value


class FakeCollector:
    """假采集器：记下每次 feed 的参数，返回固定内容的快照（每拍内容都一样）。"""

    def __init__(self, snapshot=None, raise_feed=False):
        self.snapshot = {"state": "idle"} if snapshot is None else snapshot
        self.raise_feed = raise_feed
        self.calls = []

    def feed(self, now, health, metrics=None, memory=None, model=None):
        self.calls.append((now, health, metrics, memory, model))
        if self.raise_feed:
            raise RuntimeError("采集器坏了")
        return dict(self.snapshot)


class ChangingCollector:
    """每拍内容都不同的采集器：让 run 里 on_snapshot 收得到好几份不同的快照。"""

    def __init__(self, state="decode"):
        self.state = state
        self.n = 0
        self.calls = []

    def feed(self, now, health, metrics=None, memory=None, model=None):
        self.n += 1
        self.calls.append((now, health, metrics, memory, model))
        return {"state": self.state, "lanes": {"decoding": (self.n % 3) + 1}, "n": self.n}


class FakeMemory:
    """假内存读数：返回一个字典（或抛异常）。"""

    def __init__(self, value=None, raise_read=False):
        self.value = {"used_gb": 1.0, "total_gb": 2.0} if value is None else value
        self.raise_read = raise_read
        self.calls = 0

    def __call__(self):
        self.calls += 1
        if self.raise_read:
            raise RuntimeError("读不到内存")
        return dict(self.value)


def make(fetcher, collector, memory=None, clock=None):
    """装配一个 Poller，两个时钟（第一次读取和算间隔）用同一个假时钟。"""
    clock = FakeClock() if clock is None else clock
    memory = FakeMemory() if memory is None else memory
    poller = Poller(Config(), fetcher, collector, read_memory=memory, clock=clock)
    return poller, clock, memory


IDLE = {"ok": True, "requests_running": 0}
BUSY = {"ok": True, "requests_running": 2}


class TestIdle(unittest.TestCase):
    def test_interval_and_calls(self):
        fetcher = ScriptedFetcher(health=IDLE)
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, FakeClock())

        # 0.0 秒：第一拍
        snap, wait = poller.tick()
        self.assertAlmostEqual(wait, 0.25)
        self.assertEqual(fetcher.health_calls, 1)
        self.assertEqual(fetcher.metrics_calls, 0)  # 空闲不读 /metrics
        self.assertEqual(memory.calls, 1)  # 第一次读内存
        self.assertEqual(fetcher.model_calls, 1)  # 第一次读模型名

        # 0.25 / 0.5 / 0.75 秒：还差 0.25 秒
        for _ in range(3):
            clock.advance(0.25)
            _snap, wait = poller.tick()
            self.assertAlmostEqual(wait, 0.25)

        # 1.0 秒：满 1 秒，内存要再读一次
        clock.advance(0.25)
        poller.tick()

        self.assertEqual(fetcher.health_calls, 5)
        self.assertEqual(fetcher.metrics_calls, 0)
        self.assertEqual(memory.calls, 2)  # 0.0 和 1.0 各一次
        self.assertEqual(fetcher.model_calls, 1)  # 拿到名字之后不再读


class TestBusy(unittest.TestCase):
    def test_busy_interval_and_metrics(self):
        fetcher = ScriptedFetcher(health=BUSY)
        collector = FakeCollector({"state": "decode", "lanes": {"decoding": 2, "prefilling": 0, "waiting": 0}})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, FakeClock())

        for _ in range(10):
            _snap, wait = poller.tick()
            self.assertAlmostEqual(wait, 0.1)
            clock.advance(0.1)

        # 0.0 和 0.5 各读一次 /metrics
        self.assertEqual(fetcher.metrics_calls, 2)


class TestMetricsTail(unittest.TestCase):
    def test_tail_after_busy(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=BUSY)
        collector = FakeCollector({"state": "decode", "lanes": {"decoding": 1, "prefilling": 0, "waiting": 0}})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        def tick():
            snap, wait = poller.tick()
            clock.advance(0.1)
            return snap, wait

        # 忙 1 秒：0.0 到 0.9，10 拍；只在 0.0 和 0.5 各读一次 /metrics
        for _ in range(10):
            tick()
        self.assertEqual(fetcher.metrics_calls, 2)  # 忙碌期间 2 次

        # 忙碌刚结束 2 秒内（离上次忙碌 0.9 秒）：1.5 / 2.1 / 2.7 还在按 0.5 秒读
        fetcher.health_value = IDLE
        collector.snapshot = {"state": "idle"}

        clock.advance(0.5)  # 1.5
        tick()
        clock.advance(0.5)  # 2.1
        tick()
        clock.advance(0.5)  # 2.7
        tick()

        # 超过 2 秒（3.9 和 4.5，health 不再忙、快照也是空闲）：不再读
        clock.advance(1.2)  # 3.9
        tick()
        clock.advance(0.6)  # 4.5
        tick()

        # 忙 2 次 + 忙碌后 2 秒内的 3 次 = 5
        self.assertEqual(fetcher.metrics_calls, 5)


class TestRunningRead(unittest.TestCase):
    def test_running_but_idle(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health={"ok": True, "requests_running": 1})
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        poller.tick()
        # 上一次快照还是 idle，但这次 health 在忙 → 这一拍读 /metrics
        self.assertIsNotNone(collector.calls[0][2])
        self.assertEqual(fetcher.metrics_calls, 1)


class TestOffline(unittest.TestCase):
    def test_offline_and_recover(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=IDLE, model="Qwen3.8-Flash-Next")
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        # 0.0 秒：空闲，间隔 0.25；第一次读模型名
        _snap, wait = poller.tick()
        self.assertAlmostEqual(wait, 0.25)
        self.assertEqual(fetcher.model_calls, 1)

        # 转离线：health 给 None，采集器返回离线
        fetcher.health_value = None
        fetcher.model_calls = 0
        fetcher.metrics_calls = 0
        collector.snapshot = {"state": "offline"}

        clock.advance(0.25)  # 0.25
        _snap, wait = poller.tick()
        self.assertAlmostEqual(wait, 0.5)  # 离线 → 0.5
        self.assertEqual(fetcher.metrics_calls, 0)  # 离线不读 /metrics
        self.assertEqual(fetcher.model_calls, 0)  # 离线不读模型名

        clock.advance(0.5)  # 0.75：还是离线
        _snap, wait = poller.tick()
        self.assertAlmostEqual(wait, 0.5)

        # 恢复成空闲（health 不再忙）：间隔回到 0.25，重新读一次模型名
        fetcher.health_value = IDLE
        collector.snapshot = {"state": "idle"}
        clock.advance(0.5)  # 1.25
        _snap, wait = poller.tick()
        self.assertAlmostEqual(wait, 0.25)
        self.assertEqual(fetcher.model_calls, 1)  # 恢复后重新读一次

        clock.advance(0.5)  # 1.75：模型名已拿到，不再读
        _snap, wait = poller.tick()
        self.assertAlmostEqual(wait, 0.25)
        self.assertEqual(fetcher.model_calls, 1)


class TestModelRetry(unittest.TestCase):
    def test_retry_after_5s(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=IDLE, model=None)
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        poller.tick()  # 0.0：第一次试
        self.assertEqual(fetcher.model_calls, 1)

        for _ in range(4):  # 1.0 2.0 3.0 4.0：5 秒内不重试
            clock.advance(1.0)
            poller.tick()
        self.assertEqual(fetcher.model_calls, 1)

        clock.advance(1.0)  # 5.0：满 5 秒，再试
        poller.tick()
        self.assertEqual(fetcher.model_calls, 2)


class TestFeedArgs(unittest.TestCase):
    def test_args(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=IDLE)
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        poller.tick()  # 0.0
        clock.advance(2.0)
        poller.tick()  # 2.0：满 1 秒读了内存

        first = collector.calls[0]
        self.assertEqual(first[0], 0.0)
        second = collector.calls[1]
        self.assertEqual(second[0], 2.0)  # now 是时钟值
        self.assertEqual(second[2], None)  # 2.0 秒这拍没读 /metrics
        self.assertEqual(second[4], None)  # 模型名已拿到，不再读


class TestReadTime(unittest.TestCase):
    def test_subtract_read_time(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=BUSY, clock=clock, cost=0.03)
        collector = FakeCollector({"state": "decode", "lanes": {"decoding": 1, "prefilling": 0, "waiting": 0}})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        _snap, wait = poller.tick()
        self.assertAlmostEqual(wait, 0.07, places=6)

        # 这次读取花了 0.5 秒：间隔不够，兜底给 0.01
        fetcher.cost = 0.5
        _snap, wait = poller.tick()
        self.assertAlmostEqual(wait, 0.01, places=6)


class TestExceptions(unittest.TestCase):
    def test_health_raise(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(raise_health=True)
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        snap, wait = poller.tick()
        self.assertIsNone(collector.calls[0][1])  # feed 收到 health=None
        self.assertEqual(snap["state"], "idle")  # 采集器照常算出 idle
        self.assertAlmostEqual(wait, 0.25)

    def test_memory_raise(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=IDLE)
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory(raise_read=True)
        poller, clock, memory = make(fetcher, collector, memory, clock)

        poller.tick()
        self.assertIsNone(collector.calls[0][3])  # memory=None

    def test_feed_raise(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=IDLE)
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        # 先正常喂一份 idle 快照
        snap1, wait1 = poller.tick()
        self.assertEqual(snap1["state"], "idle")
        self.assertAlmostEqual(wait1, 0.25)

        # 采集器坏掉：返回上一次的快照和 0.5
        collector.raise_feed = True
        clock.advance(0.25)
        snap2, wait2 = poller.tick()
        self.assertIs(snap2, snap1)
        self.assertAlmostEqual(wait2, 0.5)


class TestModelRemembered(unittest.TestCase):
    def test_model_stops_being_read_after_obtained(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=IDLE, model="M")
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        poller.tick()  # 0.0 秒：第一拍读到模型名，应当记下来
        self.assertEqual(fetcher.model_calls, 1)

        for _ in range(48):  # 一共拨过 12 秒，每 0.25 秒一拍
            clock.advance(0.25)
            poller.tick()
        self.assertEqual(fetcher.model_calls, 1)  # 拿到之后不再读


class TestRunEveryTick(unittest.TestCase):
    def test_identical_snapshot_still_notified(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=IDLE)
        collector = FakeCollector({"state": "idle"})  # 每拍都返回同一份内容
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        stop = threading.Event()
        seen = []

        def on_snapshot(snap):
            seen.append(snap)
            if len(seen) >= 3:
                stop.set()

        poller.run(on_snapshot, stop)
        self.assertEqual(len(seen), 3)  # 内容相同也每拍回调一次


class TestBriefLine(unittest.TestCase):
    def test_full_snapshot(self):
        snap = {
            "state": "decode",
            "lanes": {"decoding": 2, "prefilling": 1, "waiting": 0},
            "decode": {"tps": 112.4},
            "prefill": {"filled_tokens": 10240, "prompt_tokens": 24615},
            "round": {"requests": 3, "running": 3, "output_tokens": 999},
            "today": {"requests": 98, "cost": 0.597},
        }
        line = brief_line(snap)
        self.assertTrue(
            line.startswith("decode 2/1/0 tps=112.4 pf=10240/24615 round=3+3 today=98req"), line)

    def test_empty_and_none(self):
        self.assertTrue(brief_line({}).startswith("idle 0/0/0 - - -"))
        self.assertTrue(brief_line(None).startswith("idle 0/0/0 - - -"))


class TestRun(unittest.TestCase):
    def test_stops_on_third(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=BUSY)
        collector = ChangingCollector("decode")
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        stop = threading.Event()
        seen = []

        def on_snapshot(snap):
            seen.append(snap)
            if len(seen) >= 3:
                stop.set()

        poller.run(on_snapshot, stop)
        self.assertGreaterEqual(len(seen), 3)  # 第 3 份时置位，随即返回

    def test_on_snapshot_raise(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=BUSY)
        collector = ChangingCollector("decode")
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        stop = threading.Event()
        seen = []

        def on_snapshot(snap):
            seen.append(snap)
            if len(seen) >= 3:
                stop.set()
            raise ValueError("画不动")

        poller.run(on_snapshot, stop)
        self.assertGreaterEqual(len(seen), 3)  # 抛异常也不影响循环

    def test_stop_set_at_first(self):
        clock = FakeClock()
        fetcher = ScriptedFetcher(health=IDLE)
        collector = FakeCollector({"state": "idle"})
        memory = FakeMemory()
        poller, clock, memory = make(fetcher, collector, memory, clock)

        stop = threading.Event()
        stop.set()
        seen = []
        poller.run(seen.append, stop)
        self.assertEqual(seen, [])
        self.assertEqual(fetcher.health_calls, 0)  # 一次 tick 都不做


class TestCli(unittest.TestCase):
    def _run_cli(self, extra):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "config.json"
            cfg.write_text(json.dumps({"base_url": "http://127.0.0.1:1"}), encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, "-m", "panel.poller",
                 "--seconds", "0.6", "--every", "0.2", "--config", str(cfg), *extra],
                cwd=REPO, capture_output=True, text=True, timeout=30,
            )
            return proc

    def test_full(self):
        proc = self._run_cli([])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = [line for line in proc.stdout.splitlines() if line.strip()]
        self.assertTrue(lines)
        for line in lines:
            data = json.loads(line)
            self.assertEqual(data["state"], "offline")

    def test_brief(self):
        proc = self._run_cli(["--brief"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = [line for line in proc.stdout.splitlines() if line.strip()]
        self.assertTrue(lines)
        for line in lines:
            self.assertTrue(line.startswith("offline"), line)


if __name__ == "__main__":
    unittest.main()
