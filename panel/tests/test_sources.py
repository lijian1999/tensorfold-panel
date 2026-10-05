"""任务 D 读取模块的测试：解析 /health、/metrics、/proc/meminfo，以及 Fetcher。

不访问真实的 8888 端口：需要 HTTP 时在 127.0.0.1 的随机端口上起一个假服务。
"""

import os
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from panel.sources import Fetcher, parse_health, parse_meminfo, parse_metrics, read_meminfo

METRICS_TEXT = """# HELP tensorfold:requests_waiting x
# TYPE tensorfold:requests_waiting gauge
tensorfold:requests_running 3
tensorfold:requests_waiting 2
tensorfold:kv_cache_usage_ratio{pool="2"} 0.5
tensorfold:kv_cache_usage_ratio{pool="0"} 0.093899
tensorfold:kv_cache_usage_ratio{pool="1"} 0
tensorfold:time_to_first_token_seconds_bucket{le="0.5"} 26
tensorfold:time_to_first_token_seconds_sum 1599.727361
tensorfold:time_to_first_token_seconds_count 156
坏行
tensorfold:requests_waiting abc
"""

EMPTY_METRICS = {"waiting": None, "kv_usage": [], "ttft_sum": None, "ttft_count": None}

HEALTH_OK = b'{"ok": true, "busy": false, "requests_running": 1}'

MODELS_OK = b'{"data": [{"id": "Qwen3.8-Flash-Next", "object": "model"}]}'


class Handler(BaseHTTPRequestHandler):
    """把 server.responses 里配好的内容发出去；每条请求记下路径和客户端端口。"""

    protocol_version = "HTTP/1.1"  # 不主动断开，才能看出客户端有没有复用连接

    def log_message(self, *args):
        pass  # 测试里不要访问日志

    def do_GET(self):
        server = self.server
        # 客户端端口只有一个，说明这些请求走的是同一条连接
        server.log.append((self.path, self.connection.getpeername()[1]))
        status, body = server.responses.get(self.path, (404, b""))
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class TestServer(ThreadingHTTPServer):
    """带测试数据的假服务（一个端口一个）。"""

    daemon_threads = True  # 处理线程不拖住进程退出

    def __init__(self, port: int, responses: dict, log: list):
        self.responses = responses
        self.log = log
        super().__init__(("127.0.0.1", port), Handler)

class FakeServer:
    """假服务：三个路径各返回什么由 responses 决定，能在同一个端口上重开。"""

    def __init__(self, port: int = 0):
        self.responses = {
            "/health": (200, HEALTH_OK),
            "/metrics": (200, METRICS_TEXT.encode("utf-8")),
            "/v1/models": (200, MODELS_OK),
        }
        self.log: list = []
        self.server: TestServer | None = None
        self.thread: threading.Thread | None = None
        self.port: int | None = None
        self.start(port)

    def start(self, port: int) -> None:
        """在指定端口（0 = 随机）上起服务；这个端口还占着会抛 OSError。"""
        self.stop()
        self.log = []  # 重开之后访问记录从空开始
        self.server = TestServer(port, self.responses, self.log)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop(self) -> None:
        """停掉服务并关掉监听套接字，之后这个端口上再没有人在监听。"""
        if self.server is None:
            return
        server, thread = self.server, self.thread
        self.server = None
        self.thread = None
        server.shutdown()
        server.server_close()
        thread.join(2.0)


class TestParseHealth(unittest.TestCase):
    def test_valid_object(self):
        """合法的 JSON 对象原样返回，bytes 按 UTF-8 解码。"""
        self.assertEqual(parse_health(HEALTH_OK), {"ok": True, "busy": False, "requests_running": 1})
        self.assertEqual(parse_health('{"ok": true}'), {"ok": True})

    def test_invalid(self):
        """不是对象、不是合法 JSON、ok 不为真、不是 UTF-8：都是 None。"""
        for data in (
            b'{"ok": false}',
            '{"busy": true}',
            b"[1]",
            "[]",
            b'{"ok": true',       # 坏 JSON
            "",
            b"",
            b"\xff\xfe\x00",     # 不是 UTF-8
            5,
            None,
        ):
            with self.subTest(data=data):
                self.assertIsNone(parse_health(data))


class TestParseMetrics(unittest.TestCase):
    def test_sample(self):
        """示例文本：只取要用的三项，kv_usage 按 pool 编号排。"""
        self.assertEqual(
            parse_metrics(METRICS_TEXT),
            {"waiting": 2, "kv_usage": [0.093899, 0.0, 0.5], "ttft_sum": 1599.727361, "ttft_count": 156},
        )

    def test_empty(self):
        """空文本和只有注释：四项都拿不到。"""
        self.assertEqual(parse_metrics(""), EMPTY_METRICS)
        self.assertEqual(parse_metrics("# 只有注释\n\n\n"), EMPTY_METRICS)

    def test_no_pool_label(self):
        """没有 pool 标签的那行不算数。"""
        text = 'tensorfold:kv_cache_usage_ratio 0.5\ntensorfold:kv_cache_usage_ratio{pool="3"} 0.2\n'
        self.assertEqual(parse_metrics(text)["kv_usage"], [0.2])


class TestParseMeminfo(unittest.TestCase):
    TEXT = "MemTotal:       127532380 kB\nMemFree: 1 kB\nMemAvailable:   30168172 kB\n"

    def test_values(self):
        """已用 = MemTotal − MemAvailable，GB = kB ÷ 1048576。"""
        result = parse_meminfo(self.TEXT)
        self.assertAlmostEqual(result["total_gb"], 121.62, places=2)
        self.assertAlmostEqual(result["used_gb"], 92.85, places=2)

    def test_missing_lines(self):
        """缺 MemAvailable（或缺 MemTotal）就没有结果。"""
        self.assertIsNone(parse_meminfo("MemTotal: 127532380 kB\nMemFree: 1 kB\n"))
        self.assertIsNone(parse_meminfo("MemAvailable: 30168172 kB\n"))
        self.assertIsNone(parse_meminfo(""))

    def test_read_meminfo(self):
        """读不了的文件返回 None，能读的正常解析。"""
        self.assertIsNone(read_meminfo("/tmp/tfpanel-不存在的文件"))
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "meminfo")
            with open(path, "w", encoding="utf-8") as f:
                f.write(self.TEXT)
            result = read_meminfo(path)
        self.assertIsNotNone(result)
        self.assertAlmostEqual(result["total_gb"], 121.62, places=2)


class TestFetcher(unittest.TestCase):
    def setUp(self):
        self.server = FakeServer()  # 端口交给系统随机分配
        self.addCleanup(self.server.stop)
        self.fetcher = self.fetcher_for(self.server.port)
        self.addCleanup(self.fetcher.close)

    def fetcher_for(self, port: int, timeout_s: float = 0.5) -> Fetcher:
        return Fetcher(f"http://127.0.0.1:{port}", timeout_s=timeout_s)

    def test_three_paths(self):
        """三个方法都能拿到内容。"""
        self.assertEqual(self.fetcher.health(), {"ok": True, "busy": False, "requests_running": 1})
        self.assertEqual(self.fetcher.metrics()["waiting"], 2)
        self.assertEqual(self.fetcher.metrics()["kv_usage"], [0.093899, 0.0, 0.5])
        self.assertEqual(self.fetcher.model_name(), "Qwen3.8-Flash-Next")

    def test_reuses_one_connection(self):
        """连续 20 次读都成功，而且始终复用同一条连接。"""
        self.assertTrue(all(self.fetcher.health() is not None for _ in range(20)))
        self.assertEqual(len(self.server.log), 20)
        self.assertEqual(len({port for _, port in self.server.log}), 1)

    def test_bad_status_and_content(self):
        """非 200、坏 JSON、空正文、data 为空：都是 None，而且不抛异常。"""
        self.assertIsNotNone(self.fetcher.health())  # 先在这条长连接上打通一次
        self.server.responses["/health"] = (500, HEALTH_OK)
        self.server.responses["/metrics"] = (404, b"")
        self.server.responses["/v1/models"] = (200, b'{"data": []}')
        self.assertIsNone(self.fetcher.health())
        self.assertIsNone(self.fetcher.metrics())
        self.assertIsNone(self.fetcher.model_name())
        self.server.responses["/health"] = (200, b"not json")
        self.server.responses["/metrics"] = (200, b"\xff\xfe")
        self.server.responses["/v1/models"] = (200, b"[1]")
        self.assertIsNone(self.fetcher.health())
        self.assertIsNone(self.fetcher.metrics())
        self.assertIsNone(self.fetcher.model_name())
        self.server.responses["/health"] = (200, b"")
        self.assertIsNone(self.fetcher.health())

    def test_server_down(self):
        """服务关掉后三个方法都返回 None，而且很快返回（连不上会被立刻拒绝）。"""
        self.assertIsNotNone(self.fetcher.health())  # 先在这条长连接上把请求发出去
        self.fetcher.close()  # 断掉这条连接
        self.server.stop()  # 再关掉服务，端口上再没有人在监听
        started = time.monotonic()
        for _ in range(15):
            self.assertIsNone(self.fetcher.health())
            self.assertIsNone(self.fetcher.metrics())
            self.assertIsNone(self.fetcher.model_name())
        self.assertLess(time.monotonic() - started, 10.0)

    def test_reconnect_after_restart(self):
        """服务在同一个端口上重开以后，同一个 Fetcher 能重新连上。"""
        self.assertIsNotNone(self.fetcher.health())  # 先在旧服务上把连接建起来
        port = self.server.port
        self.fetcher.close()  # 断掉这条连接
        self.server.stop()
        try:
            self.server.start(port)
        except OSError as exc:
            self.skipTest(f"端口 {port} 没能重新占用：{exc}")
        self.assertEqual(self.server.log, [])  # 重开以后还没人发过请求
        self.assertIsNotNone(self.fetcher.health())
        self.assertEqual(len(self.server.log), 1)
        self.assertIsNotNone(self.fetcher.health())
        self.assertEqual(len(self.server.log), 2)

    def test_unreachable_and_bad_urls(self):
        """没人监听的端口、不是 http 的地址、空地址：都不抛异常，返回 None。"""
        for base_url in ("http://127.0.0.1:1", "ftp://127.0.0.1:8888", "", "http://"):
            with self.subTest(base_url=base_url):
                fetcher = Fetcher(base_url)
                self.assertIsNone(fetcher.health())
                self.assertIsNone(fetcher.metrics())
                self.assertIsNone(fetcher.model_name())
                fetcher.close()
                fetcher.close()


if __name__ == "__main__":
    unittest.main()
