"""读取：/health、/metrics、/proc/meminfo。

只用标准库。解析函数和 Fetcher 都不抛异常：读不到、内容不对就返回 None，
连接出错就关掉连接，下次调用重新连（模型接口每秒要读 10 次，所以连接要复用）。
"""

from __future__ import annotations

import http.client
import json
import re
from urllib.parse import urlsplit

_GB_IN_KB = 1048576  # 1 GiB = 1048576 kB

# tensorfold:kv_cache_usage_ratio{pool="2"} 里的 pool 编号
_POOL_LABEL = re.compile(r'\{pool="(-?\d+)"\}')

# vLLM /metrics 要收的指标：键名、指标名、类型（"i" 整数、"f" 浮点数）；顺序就是结果字典的键顺序
_VLLM_METRICS = (
    ("running", "vllm:num_requests_running", "i"),
    ("waiting", "vllm:num_requests_waiting", "i"),
    ("queries", "vllm:prefix_cache_queries_total", "i"),
    ("hits", "vllm:prefix_cache_hits_total", "i"),
    ("prompt", "vllm:prompt_tokens_total", "i"),
    ("prompt_cached", "vllm:prompt_tokens_cached_total", "i"),
    ("ttft_sum", "vllm:time_to_first_token_seconds_sum", "f"),
    ("ttft_count", "vllm:time_to_first_token_seconds_count", "i"),
    ("generation", "vllm:generation_tokens_total", "i"),
    ("success", "vllm:request_success_total", "i"),
    ("req_prompt_sum", "vllm:request_prompt_tokens_sum", "i"),
    ("req_generation_sum", "vllm:request_generation_tokens_sum", "i"),
    ("req_computed_sum", "vllm:request_prefill_kv_computed_tokens_sum", "i"),
    ("prefill_s", "vllm:request_prefill_time_seconds_sum", "f"),
    ("decode_s", "vllm:request_decode_time_seconds_sum", "f"),
    ("drafted", "vllm:spec_decode_num_draft_tokens_total", "i"),
    ("accepted", "vllm:spec_decode_num_accepted_tokens_total", "i"),
    ("epoch", "process_start_time_seconds", "f"),
)

VLLM_FIELDS = tuple(key for key, _, _ in _VLLM_METRICS)

# 指标名 → (键, 类型)
_VLLM_BY_NAME = {name: (key, kind) for key, name, kind in _VLLM_METRICS}


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


def parse_vllm_metrics(text: str) -> dict | None:
    """vLLM 的 /metrics 文本 → vLLM 读数：键恰好是 VLLM_FIELDS、顺序也照它。

    指标名取第一个 { 或第一个空白之前的那段，必须和表里的完全相等；文本里
    没有 vllm:num_requests_running 这个指标就返回 None；其余指标缺了：整数的
    按 0、浮点的按 0.0、epoch 按 None。同名多行（标签不同）把数值加起来。
    注释行、空行、读不懂的行忽略，永不抛异常；text 不是字符串返回 None。
    """
    if not isinstance(text, str):
        return None
    sums: dict[str, float] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name = line.split(None, 1)[0].split("{", 1)[0]  # 指标名：{ 和空白之前
        spec = _VLLM_BY_NAME.get(name)
        if spec is None:
            continue
        value = _to_float(line.rsplit(None, 1)[-1])
        if value is None:
            continue
        key = spec[0]
        sums[key] = sums.get(key, 0.0) + value
    if "running" not in sums:  # 不是 vLLM 的 /metrics
        return None
    result: dict = {}
    for key, _, kind in _VLLM_METRICS:
        if key == "epoch":
            result[key] = sums.get(key)  # 没有这行就是 None
        elif kind == "i":
            result[key] = int(sums.get(key, 0.0))
        else:
            result[key] = sums.get(key, 0.0)
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
    """用一条复用的 HTTP 连接读模型接口的三个只读接口。

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
        text = self.get_text("/health")
        if text is None:
            return None
        return parse_health(text)

    def metrics(self) -> dict | None:
        """读 /metrics 并交给 parse_metrics。"""
        text = self.get_text("/metrics")
        if text is None:
            return None
        return parse_metrics(text)

    def get_text(self, path: str) -> str | None:
        """GET 一个路径：200 返回正文（空正文返回 ""），其余情况返回 None。"""
        return self._get(path)

    def model_info(self) -> dict | None:
        """读 /v1/models，取 data[0] → {"id": 名字, "max_model_len": 数字或 None}。

        id 要是非空字符串才算读到；max_model_len 要正整数（bool 不算）才采用，
        否则这一项是 None。读不到、不是合法 JSON、没有 id 都返回 None。
        """
        text = self.get_text("/v1/models")
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
        model_id = first.get("id")
        if not isinstance(model_id, str) or not model_id:
            return None
        max_len = first.get("max_model_len")
        if isinstance(max_len, bool) or not isinstance(max_len, int) or max_len <= 0:
            max_len = None
        return {"id": model_id, "max_model_len": max_len}

    def model_name(self) -> str | None:
        """读 /v1/models 的模型名；读不到或没有就返回 None。"""
        info = self.model_info()
        return None if info is None else info["id"]

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
