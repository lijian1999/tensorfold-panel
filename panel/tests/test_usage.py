"""任务 D 今日用量模块的测试：UsageLedger。

用假时钟和临时目录，不 sleep，也不碰真实的 ~/.local/state/tfpanel。
"""

import json
import os
import tempfile
import unittest
from datetime import datetime, timezone

from panel.config import Config
from panel.usage import UsageLedger


def utc_ts(day: int, clock: str) -> float:
    """2026 年 10 月 day 日 hh:mm:ss（UTC）→ 时间戳。

    副屏按太平洋时间（夏令时，UTC−7）划分日期：
    太平洋时间 12:00:00 = UTC 19:00:00，太平洋时间 23:59:50 = UTC 次日 06:59:50。
    """
    hour, minute, second = (int(part) for part in clock.split(":"))
    return datetime(2026, 10, day, hour, minute, second, tzinfo=timezone.utc).timestamp()


# 太平洋时间 2026-10-03 12:00:00
NOON = utc_ts(3, "19:00:00")
# 太平洋时间 2026-10-03 23:59:50
LATE_NIGHT = utc_ts(4, "06:59:50")
# 太平洋时间 2026-10-04 00:00:10
MIDNIGHT = utc_ts(4, "07:00:10")
# 太平洋时间 2026-10-03 23:00:00（和 UTC 的日期差一天，用来验时区）
EVENING = utc_ts(4, "06:00:00")

TOTALS = {"prompt": 1000, "cached": 400, "completion": 50, "requests": 3}
BIGGER = {"prompt": 1500, "cached": 600, "completion": 80, "requests": 5}
SMALLER = {"prompt": 120, "cached": 0, "completion": 30, "requests": 1}


class Clock:
    """假时钟：时间戳由测试拨。"""

    def __init__(self, ts: float) -> None:
        self.ts = ts

    def __call__(self) -> float:
        return self.ts


class LedgerTest(unittest.TestCase):
    """公共部分：临时目录当 state_dir，假时钟当时钟。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = self._tmp.name

    def ledger(self, ts: float = NOON, config: Config | None = None, interval: float = 10.0,
               state_dir: str | None = None):
        self.clock = Clock(ts)
        return UsageLedger(config or Config(), clock=self.clock,
                           state_dir=state_dir or self.dir, save_interval_s=interval)

    def read_usage(self) -> dict:
        """读磁盘上的账。"""
        with open(os.path.join(self.dir, "usage.json"), "r", encoding="utf-8") as f:
            return json.load(f)

    def write_usage(self, text: str) -> None:
        with open(os.path.join(self.dir, "usage.json"), "w", encoding="utf-8") as f:
            f.write(text)

    def four(self, today: dict) -> tuple:
        """今日账上的四项，方便比较。"""
        return (today["prompt_tokens"], today["cached_tokens"],
                today["completion_tokens"], today["requests"])


class TestFirstRun(LedgerTest):
    def test_first_update_records_nothing(self):
        """第一次读只记下累计值，不动账。"""
        ledger = self.ledger()
        ledger.update(TOTALS)
        self.assertEqual(self.four(ledger.today()), (0, 0, 0, 0))
        self.assertEqual(ledger.today()["date"], "2026-10-03")

    def test_second_update_adds_increment(self):
        """第二次读：把比上次多的部分记到今天的账上。"""
        ledger = self.ledger()
        ledger.update(TOTALS)
        ledger.update(BIGGER)
        self.assertEqual(self.four(ledger.today()), (500, 200, 30, 2))


class TestCost(LedgerTest):
    def test_cost(self):
        """费用 =（提示 − 缓存命中）× 输入价 + 缓存命中 × 缓存价 + 输出 × 输出价。"""
        totals = {"prompt": 8260391, "cached": 5443627, "completion": 185305, "requests": 98}
        ledger = self.ledger()
        ledger.update({"prompt": 0, "cached": 0, "completion": 0, "requests": 0})
        ledger.update(totals)
        self.assertAlmostEqual(ledger.today()["cost"], 0.5967, places=4)

    def test_cost_with_other_price(self):
        """改输出单价，费用跟着变。"""
        totals = {"prompt": 8260391, "cached": 5443627, "completion": 185305, "requests": 98}
        ledger = self.ledger(config=Config(price_output=1.0))
        ledger.update({"prompt": 0, "cached": 0, "completion": 0, "requests": 0})
        ledger.update(totals)
        self.assertAlmostEqual(ledger.today()["cost"], 0.6949, places=4)


class TestModelRestart(LedgerTest):
    def test_smaller_totals_counts_as_restart(self):
        """累计值比上次小：模型重启过，这次的值整个算增量。"""
        ledger = self.ledger()
        ledger.update(TOTALS)
        ledger.update(SMALLER)
        self.assertEqual(self.four(ledger.today()), (120, 0, 30, 1))
        # 重启之后接着按差值记
        ledger.update({"prompt": 200, "cached": 10, "completion": 40, "requests": 2})
        self.assertEqual(self.four(ledger.today()), (200, 10, 40, 2))


class TestProgramRestart(LedgerTest):
    def test_new_ledger_continues_the_day(self):
        """副屏程序重启：新账本接着上次的累计值补上这段空隙的用量。"""
        clock = Clock(NOON)
        first = UsageLedger(Config(), clock=clock, state_dir=self.dir)
        first.update(TOTALS)
        first.update(BIGGER)
        first.flush()
        self.assertEqual(self.four(first.today()), (500, 200, 30, 2))

        second = UsageLedger(Config(), clock=clock, state_dir=self.dir)
        second.update({"prompt": 2000, "cached": 900, "completion": 120, "requests": 8})
        # 之前的 500/200/30/2 加上这段空隙里的 500/300/40/3
        self.assertEqual(self.four(second.today()), (1000, 500, 70, 5))


class TestDayRollover(LedgerTest):
    def test_rollover(self):
        """过 0 点：今天的账清零，前一天追加到历史文件。"""
        ledger = self.ledger(ts=LATE_NIGHT)
        ledger.update(TOTALS)
        ledger.update(BIGGER)
        self.assertEqual(ledger.today()["date"], "2026-10-03")

        self.clock.ts = MIDNIGHT
        today = ledger.today()  # today() 自己就会换日
        self.assertEqual(today["date"], "2026-10-04")
        self.assertEqual(self.four(today), (0, 0, 0, 0))

        with open(os.path.join(self.dir, "usage-history.jsonl"), "r", encoding="utf-8") as f:
            lines = [json.loads(line) for line in f if line.strip()]
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["date"], "2026-10-03")
        self.assertEqual((lines[0]["prompt_tokens"], lines[0]["cached_tokens"],
                          lines[0]["completion_tokens"], lines[0]["requests"]),
                         (500, 200, 30, 2))
        # 一天的账（增量）的费用：(500-200)×0.15 + 200×0.016 + 30×0.47 = 62.3（每百万 token 价 ÷ 1000000）
        self.assertAlmostEqual(lines[0]["cost"], 6.23e-05, places=7)

        # 10 月 4 日新记的账记在 10 月 4 日
        ledger.update({"prompt": 2200, "cached": 1000, "completion": 140, "requests": 10})
        today = ledger.today()
        self.assertEqual(today["date"], "2026-10-04")
        self.assertEqual(self.four(today), (700, 400, 60, 5))

    def test_empty_day_writes_no_history(self):
        """全为 0 的一天不写历史行。"""
        ledger = self.ledger(ts=LATE_NIGHT)
        ledger.update(TOTALS)  # 只记基线，账还是 0
        self.clock.ts = MIDNIGHT
        self.assertEqual(self.four(ledger.today()), (0, 0, 0, 0))
        self.assertFalse(os.path.exists(os.path.join(self.dir, "usage-history.jsonl")))


class TestSaveFile(LedgerTest):
    def test_write_at_once_when_file_exists(self):
        """已经有账了：满 10 秒后的第一次读会写文件。"""
        ledger = self.ledger(interval=10.0)
        ledger.update(TOTALS)
        ledger.update(BIGGER)  # 满 10 秒后的第一次读
        self.clock.ts += 10.0
        ledger.update(BIGGER)
        self.assertEqual(ledger.today()["date"], "2026-10-03")

    def test_write_throttling(self):
        """写文件最多每 save_interval_s 秒一次；flush 立刻写。"""
        ledger = self.ledger(interval=10.0)
        ledger.update(TOTALS)
        self.assertEqual(self.read_usage()["last_totals"], TOTALS)  # 第一次立刻写

        self.clock.ts += 5.0
        ledger.update(BIGGER)  # 5 秒：还到不了写文件的点
        self.assertEqual(self.read_usage()["last_totals"], TOTALS)

        self.clock.ts += 5.0  # 满 10 秒
        ledger.update(SMALLER)
        self.assertEqual(self.read_usage()["last_totals"], SMALLER)

        self.clock.ts += 1.0
        ledger.update(BIGGER)  # 距上次写才 1 秒：不写
        self.assertEqual(self.read_usage()["last_totals"], SMALLER)

        ledger.flush()  # flush 不受间隔限制
        self.assertEqual(self.read_usage()["last_totals"], BIGGER)

    def test_no_change_does_not_rewrite(self):
        """累计值没有变化时不重写文件。"""
        ledger = self.ledger(interval=10.0)
        ledger.update(TOTALS)
        path = os.path.join(self.dir, "usage.json")
        stamp = os.stat(path).st_mtime_ns

        self.clock.ts += 20.0
        ledger.update(TOTALS)  # 和上次一样：没有变化
        self.assertEqual(os.stat(path).st_mtime_ns, stamp)

        self.clock.ts += 20.0
        ledger.update(BIGGER)  # 有变化：到点了就写
        self.assertNotEqual(os.stat(path).st_mtime_ns, stamp)

    def test_creates_missing_state_dir(self):
        """state_dir 是不存在的多级目录：第一次写时建出来。"""
        state_dir = os.path.join(self.dir, "a", "b", "c")
        ledger = self.ledger(state_dir=state_dir)
        ledger.update(TOTALS)
        self.assertTrue(os.path.exists(os.path.join(state_dir, "usage.json")))

    def test_unwritable_state_dir(self):
        """state_dir 不可写：读和写都不抛异常。"""
        blocked = os.path.join(self.dir, "file.txt")
        with open(blocked, "w", encoding="utf-8") as f:
            f.write("不是目录\n")
        ledger = self.ledger(state_dir=os.path.join(blocked, "sub"))
        ledger.update(TOTALS)
        ledger.update(BIGGER)
        self.assertEqual(self.four(ledger.today()), (500, 200, 30, 2))
        ledger.flush()


class TestBadFile(LedgerTest):
    def test_unusable_file(self):
        """坏 JSON、不是对象、缺字段：都当没有这个文件，从空账开始。"""
        for text in ('{坏', '[1]',
                     '{"date": "2026-10-03", "prompt_tokens": 10, "requests": 2}',
                     '{}'):
            with self.subTest(text=text):
                self._tmp.cleanup()
                self._tmp = tempfile.TemporaryDirectory()
                self.dir = self._tmp.name
                self.addCleanup(self._tmp.cleanup)
                self.write_usage(text)
                ledger = self.ledger()
                ledger.update(TOTALS)  # 按第一次运行处理：只记基线
                self.assertEqual(self.four(ledger.today()), (0, 0, 0, 0))
                ledger.update(BIGGER)
                self.assertEqual(self.four(ledger.today()), (500, 200, 30, 2))

    def test_update_ignores_bad_totals(self):
        """缺键、值不是整数、传 None：整次忽略。"""
        ledger = self.ledger()
        ledger.update(TOTALS)
        for bad in (None, {}, {"prompt": 1}, {"prompt": "1", "cached": 0, "completion": 0, "requests": 0},
                    {"prompt": True, "cached": 0, "completion": 0, "requests": 0}):
            ledger.update(bad)
        self.assertEqual(self.four(ledger.today()), (0, 0, 0, 0))


class TestTimezone(LedgerTest):
    def test_unknown_timezone_falls_back(self):
        """时区名无效时按太平洋时间算日期（和 UTC 差一天，能看出来）。"""
        ledger = self.ledger(ts=EVENING, config=Config(timezone="不存在/时区"))
        self.assertEqual(ledger.today()["date"], "2026-10-03")

    def test_config_timezone_is_used(self):
        """同一个时刻，按 UTC 算是 10 月 4 日。"""
        ledger = self.ledger(ts=EVENING, config=Config(timezone="UTC"))
        self.assertEqual(ledger.today()["date"], "2026-10-04")


class TestEpoch(LedgerTest):
    """引擎启动标记：vLLM 的 epoch 变了就把整个累计值算作增量。"""

    def test_第一次读只记基线并写下标记(self):
        ledger = self.ledger()
        ledger.update(dict(TOTALS, epoch=1000.0))
        self.assertEqual(self.four(ledger.today()), (0, 0, 0, 0))
        saved = self.read_usage()
        self.assertEqual(saved["last_epoch"], 1000.0)
        self.assertEqual(saved["last_totals"], TOTALS, "存的就是四个累计值")
        self.assertEqual(set(saved["last_totals"]), {"prompt", "cached", "completion", "requests"})

    def test_同一个标记算差值(self):
        ledger = self.ledger()
        ledger.update(dict(TOTALS, epoch=1000.0))
        ledger.update(dict(BIGGER, epoch=1000.0))
        self.assertEqual(self.four(ledger.today()), (500, 200, 30, 2))

    def test_标记变了算整个(self):
        ledger = self.ledger()
        ledger.update(dict(TOTALS, epoch=1000.0))
        ledger.update(dict(BIGGER, epoch=2000.0))
        self.assertEqual(self.four(ledger.today()), (1500, 600, 80, 5),
                         "换了引擎或重启了：这次的累计值整个算增量")

    def test_有标记变没标记算整个(self):
        ledger = self.ledger()
        ledger.update(dict(TOTALS, epoch=1000.0))
        ledger.update(dict(BIGGER))
        self.assertEqual(self.four(ledger.today()), (1500, 600, 80, 5))
        ledger.flush()
        self.assertNotIn("last_epoch", self.read_usage(), "没有标记就不写这个键")

    def test_没标记变有标记算整个(self):
        ledger = self.ledger()
        ledger.update(TOTALS)
        ledger.update(dict(BIGGER, epoch=1000.0))
        self.assertEqual(self.four(ledger.today()), (1500, 600, 80, 5))

    def test_两边都没标记算差值(self):
        ledger = self.ledger()
        ledger.update(TOTALS)
        ledger.update(BIGGER)
        self.assertEqual(self.four(ledger.today()), (500, 200, 30, 2))
        self.assertNotIn("last_epoch", self.read_usage(), "只用 TensorFold 时文件内容和以前一样")

    def test_重新加载后接着算差值(self):
        ledger = self.ledger()
        ledger.update(dict(TOTALS, epoch=1000.0))
        ledger.flush()
        second = self.ledger()
        second.update(dict(BIGGER, epoch=1000.0))
        self.assertEqual(self.four(second.today()), (500, 200, 30, 2))

    def test_标记不是数字按没有标记(self):
        for bad in ("x", True):
            with self.subTest(bad=bad):
                self._tmp.cleanup()
                self._tmp = tempfile.TemporaryDirectory()
                self.dir = self._tmp.name
                self.addCleanup(self._tmp.cleanup)
                ledger = self.ledger()
                ledger.update(TOTALS)
                ledger.update(dict(BIGGER, epoch=bad))
                self.assertEqual(self.four(ledger.today()), (500, 200, 30, 2))


if __name__ == "__main__":
    unittest.main()
