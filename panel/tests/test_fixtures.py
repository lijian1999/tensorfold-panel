"""任务 B：检查 fixtures/*.json 里各状态的指标快照样例格式。"""

import json
import unittest
from pathlib import Path

# 测试文件在 panel/tests/ 下，往上两级就是仓库根目录，fixtures/ 在它下面。
FIXTURES_DIR = Path(__file__).resolve().parents[2] / "fixtures"

# 基础快照的顶层 15 个键。
TOP_KEYS = {
    "version", "state", "hook", "engine", "model", "context_max",
    "lanes", "decode", "prefill", "context_used", "last", "round", "today",
    "memory", "offline_s",
}

DECODER_OBJ_KEYS = {"tps", "tps_peak", "tps_avg", "output_tokens", "ttft_s"}
PREFILL_OBJ_KEYS = {
    "elapsed_s", "prompt_tokens", "cached_tokens", "filled_tokens",
    "tps", "remaining_s", "est_s", "cache_miss", "estimated",
}
ROUND_OBJ_KEYS = {
    "requests", "running", "output_tokens", "decode_tps_avg", "exact",
    "elapsed_s", "active",
}
LAST_OBJ_KEYS = {
    "prompt_tokens", "cached_tokens", "completion_tokens", "decode_tps",
    "prefill_tps", "ttft_s", "acceptance_rate", "context_used",
}
TODAY_OBJ_KEYS = {
    "date", "prompt_tokens", "cached_tokens", "completion_tokens",
    "requests", "cost",
}
MEMORY_OBJ_KEYS = {"used_gb", "total_gb"}

STATES = {"offline", "idle", "prefill", "decode", "done"}
HOOKS = {"ok", "missing"}

# 外挂失效时这些字段必须为 null。
PREFILL_HOOK_NULL_KEYS = {"cached_tokens", "filled_tokens", "tps",
                          "remaining_s", "est_s"}

# 应有的 17 个样例文件名。
FIXTURE_NAMES = {
    "prefill-est.json",
    "idle-vllm.json",
    "offline-vllm.json",
    "offline.json",
    "idle.json",
    "idle-nohook.json",
    "prefill.json",
    "prefill-fresh.json",
    "prefill-miss.json",
    "prefill-nohook.json",
    "prefill-short.json",
    "decode.json",
    "decode-multi.json",
    "decode-ctx-warn.json",
    "queue.json",
    "done.json",
    "round-rest.json",
}


def fixture_paths():
    """fixtures/ 下全部 *.json，按文件名排序。"""
    return sorted(FIXTURES_DIR.glob("*.json"))


def load(path):
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def each_fixture(test_case):
    """逐个快照样例执行回调，失败时报出文件名。"""
    paths = fixture_paths()
    test_case.assertTrue(paths, f"fixtures/ 下没有找到任何 JSON 样例: {FIXTURES_DIR}")
    for path in paths:
        with test_case.subTest(fixture=path.name):
            yield path


class TestFixtureFiles(unittest.TestCase):
    def test_fixture_files_exist(self):
        """fixtures/ 里恰好有 17 个样例文件，不多不少。"""
        self.assertTrue(FIXTURES_DIR.is_dir(),
                        f"缺少目录 {FIXTURES_DIR}")
        found = {p.name for p in FIXTURES_DIR.glob("*.json")}
        self.assertEqual(found, FIXTURE_NAMES)


class TestFixtureFormat(unittest.TestCase):
    def test_loadable_and_object(self):
        """每个样例都能读出来，而且顶层是对象。"""
        for path in each_fixture(self):
            snap = load(path)
            self.assertIsInstance(snap, dict)

    def test_top_level_keys(self):
        """顶层键恰好是基础快照的 15 个键。"""
        for path in each_fixture(self):
            snap = load(path)
            self.assertEqual(set(snap.keys()), TOP_KEYS)

    def test_version_state_hook(self):
        """version 为 2；state、hook 的取值合法。"""
        for path in each_fixture(self):
            snap = load(path)
            self.assertEqual(snap["version"], 2)
            self.assertIn(snap["state"], STATES)
            self.assertIn(snap["hook"], HOOKS)

    def test_engine(self):
        """engine 只能是 tensorfold 或 vllm。"""
        for path in each_fixture(self):
            self.assertIn(load(path)["engine"], {"tensorfold", "vllm"})

    def test_estimated(self):
        """有预填充时 estimated 是布尔；TensorFold 的样例必须是 False。"""
        for path in each_fixture(self):
            snap = load(path)
            if snap["prefill"] is not None:
                self.assertIsInstance(snap["prefill"]["estimated"], bool)
                if snap["engine"] == "tensorfold":
                    self.assertFalse(snap["prefill"]["estimated"])

    def test_lanes(self):
        """lanes 恰好 4 个整数键。"""
        for path in each_fixture(self):
            lanes = load(path)["lanes"]
            self.assertEqual(set(lanes.keys()),
                             {"max", "decoding", "prefilling", "waiting"})
            for value in lanes.values():
                self.assertIsInstance(value, int)

    def test_optional_object_keys(self):
        """decode、prefill、round、last 要么是 null，要么键恰好齐全。"""
        checks = (
            ("decode", DECODER_OBJ_KEYS),
            ("prefill", PREFILL_OBJ_KEYS),
            ("round", ROUND_OBJ_KEYS),
            ("last", LAST_OBJ_KEYS),
        )
        for path in each_fixture(self):
            snap = load(path)
            for name, keys in checks:
                obj = snap[name]
                if obj is not None:
                    with self.subTest(fixture=path.name, field=name):
                        self.assertEqual(set(obj.keys()), keys)

    def test_state_consistency(self):
        """状态与并发数、offline_s 的互相约束。"""
        for path in each_fixture(self):
            snap = load(path)
            with self.subTest(fixture=path.name, check="decode"):
                if snap["state"] == "decode":
                    self.assertIsNotNone(snap["decode"])
                    self.assertGreaterEqual(snap["lanes"]["decoding"], 1)
            with self.subTest(fixture=path.name, check="prefill"):
                if snap["lanes"]["prefilling"] >= 1:
                    self.assertIsNotNone(snap["prefill"])
            with self.subTest(fixture=path.name, check="offline_s"):
                if snap["state"] == "offline":
                    self.assertIsInstance(snap["offline_s"], (int, float))
                else:
                    self.assertIsNone(snap["offline_s"])

    def test_missing_hook_nulls(self):
        """外挂失效且有预填充时，prefill 里依赖外挂的字段都是 null。"""
        for path in each_fixture(self):
            snap = load(path)
            if snap["hook"] == "missing" and snap["prefill"] is not None:
                for key in PREFILL_HOOK_NULL_KEYS:
                    with self.subTest(fixture=path.name, key=key):
                        self.assertIsNone(snap["prefill"][key])

    def test_today_and_memory_keys(self):
        """today、memory 的键齐全。"""
        for path in each_fixture(self):
            snap = load(path)
            with self.subTest(fixture=path.name, field="today"):
                self.assertEqual(set(snap["today"].keys()), TODAY_OBJ_KEYS)
            with self.subTest(fixture=path.name, field="memory"):
                self.assertEqual(set(snap["memory"].keys()), MEMORY_OBJ_KEYS)


if __name__ == "__main__":
    unittest.main()
