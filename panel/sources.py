"""读取：/health、/metrics、/proc/meminfo。

只用标准库。三个解析函数和 Fetcher 都不抛异常：读不到、内容不对就返回 None，
连接出错就关掉连接，下次调用重新连（8888 端口每秒要读 10 次，所以连接要复用）。
"""

from __future__ import annotations

import http.client
import json
import re
from urllib.parse import urlsplit

_GB_IN_KB = 1048576  # 1 GiB = 1048576 kB

# tensorfold:kv_cache_usage_ratio{pool="2"} 里的 pool 编号
_POOL_LABEL = re.compile(r'\{pool="(-?\d+)"\}')


def parse_health(data: bytes | str) -> dict | None:
    """/health 的 JSON 对象 → 字典。不是对象、不是合法 JSON、ok 不为真 → None。"""
    if isinstance(data, (bytes, bytearray)):
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            return None
    elif isinstance(data, str):
        text = data
    else:
        return None
    if not text:
        return None
    try:
        obj = json.loads(text)
    except ValueError:
        return None
    if not isinstance(obj, dict):
        return None
    if not obj.get("ok"):
        return None
    return obj


def parse_metrics(text: str) -> dict:
    """逐行解析 /metrics 文本；不认识的行和数值读不懂的行都忽略，永不抛异常。

    kv_usage 按 pool 编号从小到大排；ttft_count 是整数。
    """
    result: dict = {"waiting": None, "kv_usage": [], "ttft_sum": None, "ttft_count": None}
    if not isinstance(text, str):
        return result
    pools: dict[int, float] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2:
            continue
        name, raw_value = parts
        value = _to_float(raw_value)
        if value is None:
            continue
        if name == "tensorfold:requests_waiting":
            result["waiting"] = int(value)
        elif name == "tensorfold:time_to_first_token_seconds_sum":
            result["ttft_sum"] = value
        elif name == "tensorfold:time_to_first_token_seconds_count":
            result["ttft_count"] = int(value)
        elif name.startswith("tensorfold:kv_cache_usage_ratio"):
            pool = _POOL_LABEL.search(name)
            if pool is not None:
                pools[int(pool.group(1))] = value
    result["kv_usage"] = [pools[i] for i in sorted(pools)]
    return result


def parse_meminfo(text: str) -> dict | None:
    """/proc/meminfo → {"used_gb", "total_gb"}；GB = kB ÷ 1048576，已用 = MemTotal − MemAvailable。

    缺任何一行都返回 None；数值保留原始精度，不四舍五入。
    """
    if not isinstance(text, str):
        return None
    values: dict[str, int] = {}
    for raw in text.splitlines():
        parts = raw.split()
        if len(parts) < 2 or not parts[0].endswith(":"):
            continue
        try:
            values[parts[0][:-1]] = int(parts[1])
        except ValueError:
            continue
    total = values.get("MemTotal")
    available = values.get("MemAvailable")
    if total is None or available is None:
        return None
    return {"used_gb": (total - available) / _GB_IN_KB, "total_gb": total / _GB_IN_KB}


def read_meminfo(path: str = "/proc/meminfo") -> dict | None:
    """读内存信息文件并解析；文件不存在或读不了返回 None。"""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except (OSError, ValueError):
        return None
    return parse_meminfo(text)


def _to_float(text: str) -> float | None:
    """数值字符串 → 浮点数；读不懂返回 None。"""
    try:
        return float(text)
    except ValueError:
        return None


class Fetcher:
    """用一条复用的 HTTP 连接读 8888 端口的三个只读接口。

    只发 GET，只读 /health、/metrics、/v1/models。任何失败（连不上、超时、
    被对端断开、非 200、内容不对）都吃掉并返回 None，同时关掉连接，
    下一次调用重新连。一个 Fetcher 不供多个线程同时用。
    """

    def __init__(self, base_url: str, timeout_s: float = 0.5) -> None:
        self._host, self._port = _split_host_port(base_url)
        self._timeout = timeout_s
        self._conn: http.client.HTTPConnection | None = None

    def health(self) -> dict | None:
        """读 /health 并交给 parse_health。"""
        text = self._get("/health")
        if text is None:
            return None
        return parse_health(text)

    def metrics(self) -> dict | None:
        """读 /metrics 并交给 parse_metrics。"""
        text = self._get("/metrics")
        if text is None:
            return None
        return parse_metrics(text)

    def model_name(self) -> str | None:
        """读 /v1/models，取 data[0]["id"]；读不到或没有就返回 None。"""
        text = self._get("/v1/models")
        if text is None:
            return None
        try:
            data = json.loads(text)
        except ValueError:
            return None
        if not isinstance(data, dict):
            return None
        items = data.get("data")
        if not isinstance(items, list) or not items:
            return None
        first = items[0]
        if not isinstance(first, dict):
            return None
        name = first.get("id")
        return name if isinstance(name, str) and name else None

    def close(self) -> None:
        """关掉当前连接；下一次调用重新连。"""
        conn, self._conn = self._conn, None
        if conn is None:
            return
        try:
            conn.close()
        except OSError:
            pass

    def _get(self, path: str) -> str | None:
        """GET 一个路径。第一次失败就重连再试一次，还是不行就返回 None。"""
        if self._host is None:
            return None
        for _ in range(2):
            text = self._attempt(path)
            if text is not None:
                return text
        return None

    def _attempt(self, path: str) -> str | None:
        """试一次；出错就关掉连接并返回 None，下一次调用会重新连。"""
        try:
            conn = self._conn
            if conn is None:
                conn = http.client.HTTPConnection(self._host, self._port, timeout=self._timeout)
                self._conn = conn
            conn.request("GET", path)
            response = conn.getresponse()
            if response.status != 200:
                self.close()
                return None
            body = response.read()
        except (OSError, http.client.HTTPException):
            # 连不上、超时、被对端断开：关掉连接，下一次重新连
            self.close()
            return None
        # 响应读完了：这条连接留着给下一次复用（每秒要读 10 次）
        try:
            return body.decode("utf-8")
        except UnicodeDecodeError:
            self.close()
            return None


def _split_host_port(base_url: str) -> tuple[str | None, int | None]:
    """从 http://127.0.0.1:8888 取主机和端口；不是合法 http 地址就返回 (None, None)。"""
    try:
        parts = urlsplit(base_url)
        port = parts.port
    except ValueError:
        return (None, None)
    if parts.scheme != "http" or not parts.hostname or port is None:
        return (None, None)
    return (parts.hostname, port)
