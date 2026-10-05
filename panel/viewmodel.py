"""视图模型：指标快照 → 视图（View）。

只用标准库；不读时钟、不做 I/O。快照里缺字段或字段为 null 时照常出画面，
缺的那部分写“—”或留空。
"""

from __future__ import annotations

import math

from panel import fmt, scale
from panel.config import Config
from panel.view import Bar, Card, Lanes, Seg, View


def _join(parts: list[Seg]) -> list[Seg]:
    """把若干段文字接起来，相邻的同样式文字合成一段。"""
    out: list[Seg] = []
    for part in parts:
        if out and out[-1].style == part.style:
            out[-1].text += part.text
        else:
            out.append(Seg(part.text, part.style))
    return out


def _num(value, default=0):
    """取不到的数字退回默认值（画面上写成 0 或“—”）。"""
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return value
    return default


class ViewModel:
    """把一份指标快照变成一个 View。

    两次 update 之间记住四件事：休息画面是哪一种、预填充有没有接管画面、
    上一次的状态（慢淡入）、今日统计开始显示的时刻（调暗）。
    """

    def __init__(self, config: Config):
        self.config = config
        self._rest_kind = "today"              # 上一次休息画面：today 或 round
        self._took_over = False                # 预填充是否接管了画面
        self._prev_state: str | None = None    # 上一次的状态
        self._today_since: float | None = None  # 今日统计开始显示的时刻

    def update(self, snapshot: dict, now: float) -> View:
        """按快照出画面。now 是单调时钟秒数，只用来算调暗。"""
        snap = snapshot if isinstance(snapshot, dict) else {}
        state = snap.get("state") or "idle"
        prev_state = self._prev_state
        self._prev_state = state

        view = View(state=state)
        # 记忆 3：完成 → 空闲用 0.8 秒慢淡入
        view.slow_fade = prev_state == "done" and state == "idle"
        view.lanes = self._lanes(snap)

        rm = self._round_mode(snap)
        mem_text = self._memory_text(snap)
        mem_card = self._memory_card(snap)

        if state == "offline":
            self._offline(view, snap, mem_card)
        elif state == "idle":
            # 一轮中间的空隙显示本轮统计，一轮结束后才是今日统计
            if rm:
                self._round_rest(view, snap)
                view.strip_right = _join(mem_text)
            else:
                self._today(view, snap)
        elif state == "prefill":
            self._prefill(view, snap, rm, mem_card)
        elif state == "decode":
            self._decode(view, snap, rm, mem_text)
        else:
            # 完成，以及认不出的状态：都按完成画
            self._done(view, snap, rm, mem_text)

        # 记忆 1：休息画面是哪一种（预填充不改）
        if state in ("idle", "offline"):
            self._rest_kind = "round" if (state == "idle" and rm) else "today"
        elif state in ("done", "decode"):
            self._rest_kind = "round"

        # 记忆 2：离开预填充就清掉接管标记
        if state != "prefill":
            self._took_over = False

        # 记忆 4：长时间停在今日统计上就调暗
        if state == "idle" and not rm:
            if self._today_since is None:
                self._today_since = now
            if now - self._today_since >= self.config.dim_after_s:
                view.dim = 0.4
        else:
            self._today_since = None

        return view

    # ---------- 公共片段 ----------

    def _lanes(self, snap: dict) -> Lanes:
        """流指示点：照抄快照里的流数；离线时只画一个红点。"""
        lanes = snap.get("lanes")
        if not isinstance(lanes, dict):
            lanes = {}
        if snap.get("state") == "offline":
            return Lanes(max=_num(lanes.get("max"), 5), offline=True)
        return Lanes(
            max=_num(lanes.get("max"), 5),
            decoding=_num(lanes.get("decoding"), 0),
            prefilling=_num(lanes.get("prefilling"), 0),
            waiting=_num(lanes.get("waiting"), 0),
        )

    def _memory_text(self, snap: dict) -> list[Seg]:
        """状态条右侧的“内存 x.x / 121 GB”。"""
        used, total = self._memory(snap)
        return [Seg("内存 "), Seg(used, "strong"), Seg(f" / {total} GB")]

    def _memory(self, snap: dict) -> tuple[str, str]:
        """内存已用和总量各写成字符串，读不到写“—”。"""
        memory = snap.get("memory")
        if not isinstance(memory, dict):
            memory = {}
        used = memory.get("used_gb")
        total = memory.get("total_gb")
        used_text = "—" if used is None else f"{used:.1f}"
        total_text = "—" if not total else str(int(total))
        return used_text, total_text

    def _memory_card(self, snap: dict) -> Card:
        used, total = self._memory(snap)
        return Card("内存", used, "GB", f"共 {total} GB")

    def _context_bar(self, snap: dict, used) -> Bar:
        """上下文条：长度按占用比例，颜色按档位分三档。"""
        used = _num(used, 0)
        context_max = _num(snap.get("context_max"), 0)
        frac = min(1, used / context_max) if context_max else 0
        if frac >= 0.95:
            level = "full"
        elif frac >= 0.8:
            level = "warn"
        else:
            level = "normal"
        shown = min(used, context_max) if context_max else used
        used_text = fmt.tok_fmt(shown) if shown else "—"
        max_text = fmt.tok_fmt(context_max) if context_max else "—"
        text = _join([Seg("上下文 "), Seg(used_text, "strong"), Seg(f" / {max_text}")])
        return Bar("ctx", frac, level, text)

    def _round_mode(self, snap: dict) -> bool:
        """一轮模式：这一轮请求数（含进行中的）≥ 2 且这一轮还没结束。"""
        rnd = snap.get("round")
        if not isinstance(rnd, dict) or not rnd.get("active"):
            return False
        return _num(rnd.get("requests"), 0) + _num(rnd.get("running"), 0) >= 2

    def _round_cards(self, snap: dict) -> list[Card]:
        """一轮模式右侧三栏，标签在这一轮里不变。"""
        rnd = snap.get("round")
        if not isinstance(rnd, dict):
            rnd = {}
        requests = _num(rnd.get("requests"), 0)
        running = _num(rnd.get("running"), 0)
        avg = rnd.get("decode_tps_avg")
        third = (
            Card("本轮平均", f"{avg:.1f}", "", "tok/s")
            if avg is not None
            else Card("本轮平均", "—", "", "", pending=True)
        )
        return [
            Card("本轮请求", str(requests + running), "次",
                 "用时 " + fmt.dur_fmt(_num(rnd.get("elapsed_s"), 0))),
            Card("累计输出", fmt.tok_fmt(_num(rnd.get("output_tokens"), 0)), "tok", ""),
            third,
        ]

    # ---------- 两种休息画面 ----------

    def _round_rest(self, view: View, snap: dict) -> None:
        """本轮统计（灰色）。"""
        rnd = snap.get("round")
        if not isinstance(rnd, dict):
            rnd = {}
        avg = rnd.get("decode_tps_avg")
        view.muted = True
        view.arc = "rest"
        view.cap = "本轮平均"
        view.unit = "tok/s"
        view.pill = avg is not None and bool(rnd.get("exact"))
        if avg is not None:
            view.big_int, view.big_dec = fmt.split1(avg)
        else:
            view.big_int, view.big_dec = "—", ""
        view.ghost = scale.v2f(avg, "decode") if avg is not None else None
        view.arc_target = view.ghost
        view.strip_left = ""
        view.bar = self._context_bar(snap, snap.get("context_used"))
        view.cards = self._round_cards(snap)

    def _today(self, view: View, snap: dict) -> None:
        """今日统计。"""
        today = snap.get("today")
        if not isinstance(today, dict):
            today = {}
        last = snap.get("last")
        if not isinstance(last, dict):
            last = {}

        view.strip_left = snap.get("model") or self.config.model_name
        if snap.get("hook") == "missing":
            view.strip_right = _join([Seg("外挂未生效", "warn"), Seg(" · ")]
                                     + self._memory_text(snap))
        else:
            view.strip_right = _join(self._memory_text(snap))

        currency = self.config.currency
        view.cap = "今日费用"
        view.unit = "美元" if currency == "$" else currency
        cost = fmt.cost_fmt(_num(today.get("cost"), 0), currency)
        dot = cost.index(".")
        view.big_int = cost[:dot]
        view.big_dec = cost[dot:]
        view.big_whole = True
        view.big_size = "cost"
        view.arc = "blank"
        view.arc_target = None
        zone = self.config.timezone
        zone_name = "太平洋时间" if zone == "America/Los_Angeles" else zone
        date_text = fmt.date_label(today.get("date") or "")
        view.bar = Bar("note", 0.0, "normal", [Seg(f"{date_text} · {zone_name}")])

        prompt = _num(today.get("prompt_tokens"), 0)
        cached = _num(today.get("cached_tokens"), 0)
        tps = last.get("decode_tps")
        view.cards = [
            Card("今日输入", fmt.tok_fmt(prompt), "tok",
                 f"缓存命中 {fmt.pct(cached, prompt)}%"),
            Card("今日输出", fmt.tok_fmt(_num(today.get("completion_tokens"), 0)), "tok", ""),
            Card("今日请求", str(_num(today.get("requests"), 0)), "次",
                 f"上次 {tps:.1f} tok/s" if tps else ""),
        ]

    # ---------- 各状态 ----------

    def _offline(self, view: View, snap: dict, mem_card: Card) -> None:
        """引擎离线。"""
        model = snap.get("model") or self.config.model_name
        view.state_name = "引擎离线"
        view.strip_right = [Seg(f"上次模型 {model}")]
        view.lanes.offline = True
        view.arc = "off"
        today = snap.get("today")
        if not isinstance(today, dict):
            today = {}
        secs = math.floor(_num(snap.get("offline_s"), 0))
        if secs < 60:
            off_card = Card("已离线", str(secs), "秒", "")
        else:
            off_card = Card("已离线", str(secs // 60), "分钟", "")
        view.bar = None
        view.cards = [
            Card("今日费用", fmt.cost_fmt(_num(today.get("cost"), 0),
                                       self.config.currency), "", ""),
            off_card,
            mem_card,
        ]

    def _prefill(self, view: View, snap: dict, rm: bool, mem_card: Card) -> None:
        """预填充：够长（或预计够长、缓存未命中）才换成预填充画面。"""
        view.state_name = "预填充中"
        view.strip_left = ""

        prefill = snap.get("prefill")
        if not isinstance(prefill, dict):
            prefill = {}
        el = _num(prefill.get("elapsed_s"), 0)
        short = self.config.prefill_short_s
        hook_missing = snap.get("hook") == "missing"
        if hook_missing:
            # 外挂失效：没有缓存命中和进度信息，只按 3 秒切
            take = el >= short
        else:
            est = _num(prefill.get("est_s"), 0)
            take = (el >= short or est >= short or bool(prefill.get("cache_miss")))
        if self._took_over:
            # 一旦接管，在离开预填充之前一直是接管状态
            take = True
        self._took_over = take

        if not take:
            # 短预填充：画面保持之前的样子，只有状态条和流指示点变化
            if self._rest_kind == "today" or not rm:
                self._today(view, snap)
            else:
                self._round_rest(view, snap)
            view.state_name = "预填充中"
            view.strip_left = ""
            view.strip_right = _join([Seg("已用时 "), Seg(f"{el:.1f}", "strong"), Seg(" s")])
            return

        if hook_missing:
            self._prefill_degraded(view, snap, prefill, el, rm)
            return

        prompt = _num(prefill.get("prompt_tokens"), 0)
        cached = _num(prefill.get("cached_tokens"), 0)
        filled = _num(prefill.get("filled_tokens"), 0)
        new_tokens = prompt - cached
        hit = fmt.pct(cached, prompt)
        tps = prefill.get("tps")
        view.cap = "预填充速度"
        view.unit = "tok/s"
        view.big_int = str(fmt.js_round(tps)) if tps else "—"
        view.big_dec = ""
        view.big_size = "four"
        view.arc = "prefill"
        view.scale = "prefill"
        view.arc_target = scale.v2f(tps or 0, "prefill")
        view.bar = Bar(
            "prog",
            (filled / prompt) if prompt else 0,
            "normal",
            _join([Seg("已算 "), Seg(fmt.tok_fmt(filled), "strong"),
                   Seg(f" / {fmt.tok_fmt(prompt)}")]),
        )

        el_txt = f"{el:.1f}" if el < 100 else str(math.floor(el))
        rem = self._remaining(prefill, prompt, filled, el, tps)
        if rm:
            view.cards = self._round_cards(snap)
            if prefill.get("cache_miss"):
                view.strip_right = _join([
                    Seg("已用时 "), Seg(el_txt, "strong"), Seg(" s · "),
                    Seg("缓存未命中", "warn"),
                    Seg(" · 剩余约 "), Seg(str(rem), "strong"), Seg(" s"),
                ])
            else:
                view.strip_right = _join([
                    Seg("已用时 "), Seg(el_txt, "strong"), Seg(" s · 缓存命中 "),
                    Seg(f"{hit}%", "strong"),
                    Seg(" · 剩余约 "), Seg(str(rem), "strong"), Seg(" s"),
                ])
        else:
            view.cards = [
                Card("缓存命中", str(hit), "%",
                     f"{fmt.tok_fmt(cached)} / {fmt.tok_fmt(prompt)}"),
                Card("已等待", el_txt, "s", f"剩余约 {rem} s"),
                mem_card,
            ]
            view.strip_right = _join([Seg("新算 "),
                                     Seg(fmt.tok_fmt(new_tokens), "strong"),
                                     Seg(" tok")])

    def _prefill_degraded(self, view: View, snap: dict, prefill: dict,
                          el: float, rm: bool) -> None:
        """外挂失效时的预填充画面：只剩“已用时”。"""
        view.cap = "已用时"
        view.unit = "秒"
        view.big_whole = True
        if el < 10:
            view.big_int, view.big_dec = fmt.split1(el)
        else:
            view.big_int, view.big_dec = str(math.floor(el)), ""
        view.arc = "rest"
        view.scale = "decode"
        view.arc_target = None
        last = snap.get("last")
        if not isinstance(last, dict):
            last = {}
        tps = last.get("decode_tps")
        view.ghost = scale.v2f(tps, "decode") if tps else None
        view.muted = False
        view.strip_right = [Seg("提示较长，可能需要几秒")]
        view.bar = self._context_bar(snap, snap.get("context_used"))
        if rm:
            view.cards = self._round_cards(snap)
        else:
            view.cards = [
                Card("输出", "—", "", "", pending=True),
                Card("首字", "—", "", "等待首个 token", pending=True),
                self._memory_card(snap),
            ]

    def _remaining(self, prefill: dict, prompt: float, filled: float,
                   el: float, tps) -> int:
        """剩余时间估算，至少 1 秒。"""
        if tps:
            return max(1, math.ceil((prompt - filled) / tps))
        est = _num(prefill.get("est_s"), 0)
        return max(1, math.ceil(est - el))

    def _decode(self, view: View, snap: dict, rm: bool, mem_text: list[Seg]) -> None:
        """解码：主数字是所有正在解码的流的合计速度。"""
        view.state_name = "解码中"
        decode = snap.get("decode")
        if not isinstance(decode, dict):
            decode = {}
        tps = decode.get("tps")
        view.cap = "解码速度"
        view.unit = "tok/s"
        view.big_value = tps
        view.big_int = str(fmt.js_round(tps)) if tps is not None else ""
        view.big_dec = ""
        view.arc = "value"
        view.arc_target = scale.v2f(tps or 0, "decode")
        view.bar = self._context_bar(snap, snap.get("context_used"))

        lanes = snap.get("lanes")
        if not isinstance(lanes, dict):
            lanes = {}
        decoding = _num(lanes.get("decoding"), 0)
        prefilling = _num(lanes.get("prefilling"), 0)
        waiting = _num(lanes.get("waiting"), 0)
        if decoding + prefilling >= 2 or waiting > 0:
            # 多条流（或有排队）：把各路数量列出来
            parts = [Seg("解码 "), Seg(str(decoding), "strong")]
            if prefilling:
                parts += [Seg(" · "), Seg("预填充 "), Seg(str(prefilling), "strong")]
            if waiting:
                parts += [Seg(" · "), Seg("排队 "), Seg(str(waiting), "strong")]
            parts += [Seg(" · ")] + mem_text
            view.strip_right = _join(parts)
        else:
            ttft = decode.get("ttft_s")
            if ttft is not None:
                view.strip_right = _join([Seg("首字 "), Seg(f"{ttft:.2f}", "strong"),
                                          Seg(" s · ")] + mem_text)
            else:
                view.strip_right = _join(mem_text)

        if rm:
            view.cards = self._round_cards(snap)
            return
        output = _num(decode.get("output_tokens"), 0)
        avg = decode.get("tps_avg")
        peak = decode.get("tps_peak")
        view.cards = [
            Card("输出", fmt.tok_fmt(output), "tok", ""),
            Card("平均", f"{avg:.1f}", "", "tok/s") if avg is not None
            else Card("平均", "—", "", "", pending=True),
            Card("峰值", str(fmt.js_round(peak)), "tok/s", "") if peak
            else Card("峰值", "—", "", "", pending=True),
        ]

    def _done(self, view: View, snap: dict, rm: bool, mem_text: list[Seg]) -> None:
        """完成：一轮里画本轮统计，单个请求画上一个请求的成绩。"""
        view.state_name = "完成"
        last = snap.get("last")

        if rm:
            self._round_rest(view, snap)
            view.state_name = "完成"
            rnd = snap.get("round")
            exact = isinstance(rnd, dict) and bool(rnd.get("exact"))
            ttft = last.get("ttft_s") if isinstance(last, dict) else None
            if exact and ttft is not None:
                view.strip_right = _join([Seg("首字 "), Seg(f"{ttft:.2f}", "strong"),
                                           Seg(" s")])
            else:
                view.strip_right = _join(mem_text)
            return

        if not isinstance(last, dict):
            # 没有上一个请求的成绩（不该发生）：按今日统计画
            self._today(view, snap)
            view.state_name = "完成"
            return

        tps = last.get("decode_tps")
        ttft = last.get("ttft_s")
        view.cap = "平均速度"
        view.unit = "tok/s"
        view.pill = True
        if tps is not None:
            view.big_int, view.big_dec = fmt.split1(tps)
        else:
            view.big_int, view.big_dec = "—", ""
        view.arc = "value"
        view.arc_target = scale.v2f(tps or 0, "decode")
        view.bar = self._context_bar(snap, last.get("context_used"))
        if ttft is not None:
            view.strip_right = _join([Seg("首字 "), Seg(f"{ttft:.2f}", "strong"),
                                      Seg(" s")])
        else:
            view.strip_right = _join(mem_text)

        prompt = _num(last.get("prompt_tokens"), 0)
        cached = _num(last.get("cached_tokens"), 0)
        accept = last.get("acceptance_rate")
        view.cards = [
            Card("输出", fmt.tok_fmt(_num(last.get("completion_tokens"), 0)), "tok",
                 f"提示 {fmt.tok_fmt(prompt)} tok"),
            Card("缓存命中", str(fmt.pct(cached, prompt)), "%",
                 f"{fmt.tok_fmt(cached)} tok"),
            Card("接受率", str(fmt.js_round(accept * 100)), "%", "") if accept
            else Card("接受率", "—", "", "", pending=True),
        ]
