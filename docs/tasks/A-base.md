# 任务 A：基础模块（配置、格式、刻度、视图数据结构）

先读 `AGENTS.md`，再读 `docs/tasks/00-contracts.md` 的第 1、2、3、7 节。本任务只用标准库，全部在 MacBook Pro 上完成，不需要 `ssh spark`。

## 交付文件

1. `panel/__init__.py`：只有一行 `__version__ = "2.0.0"`。
2. `panel/config.py`：`Config`、`load_config`，按接口约定第 2 节。
3. `panel/fmt.py`：按接口约定第 3 节的表，7 个函数。
4. `panel/scale.py`：`TICK_FRACS`、`SCALES`、`v2f`，按接口约定第 3 节。
5. `panel/view.py`：`Seg`、`Lanes`、`Card`、`Bar`、`View`，按接口约定第 7 节，字段名、默认值、顺序一字不差。
6. `panel/tests/__init__.py`：空文件。
7. `panel/tests/test_base.py`：测试。

不要创建别的文件。

## 细节

- `fmt.py`、`scale.py` 的行为以原型 `docs/dashboard-prototype.html` 里的 `tokFmt`、`split1`、`costFmt`、`durFmt`、`v2f` 为准（搜这些名字就能找到）。`toFixed(n)` 用 `f"{x:.{n}f}"`。
- `tok_fmt`、`cost_fmt`、`split1`、`dur_fmt` 的参数可能是 `int` 也可能是 `float`。
- `View.from_dict`：嵌套的 `strip_right`（`Seg` 列表）、`lanes`、`bar`（可为 `None`，里面还有 `Seg` 列表）、`cards` 都要还原成对应的数据类；字典里缺的键用默认值，多出来的键忽略。`View.from_dict(v.to_dict()) == v` 必须成立。
- `load_config` 里 `~` 的展开只在读默认路径时做；`Config.state_dir` 保持原样的字符串（由使用它的模块自己展开）。

## 测试要求（`panel/tests/test_base.py`）

至少覆盖：

1. `tok_fmt`：`0 → "0"`、`999 → "999"`、`999.6 → "1.0K"`、`1000 → "1.0K"`、`6000 → "6.0K"`、`6249 → "6.2K"`、`24615 → "24.6K"`、`99949 → "99.9K"`、`99950 → "100K"`、`262144 → "262K"`、`999499 → "999K"`、`999500 → "1.00M"`、`8260391 → "8.26M"`、`9995000 → "10.0M"`、`12345678 → "12.3M"`。
2. `split1(62.3) == ("62", ".3")`、`split1(97.2) == ("97", ".2")`、`split1(5) == ("5", ".0")`、`split1(107.64) == ("107", ".6")`。
3. `cost_fmt(0.597) == "$0.60"`、`cost_fmt(0) == "$0.00"`、`cost_fmt(99.994) == "$99.99"`、`cost_fmt(100) == "$100"`、`cost_fmt(1234.5) == "$1235"`、`cost_fmt(1.5, "¥") == "¥1.50"`。
4. `dur_fmt`：`0 → "0 秒"`、`46.9 → "46 秒"`、`60 → "1 分钟"`、`132 → "2 分钟"`、`3599 → "59 分钟"`、`3600 → "1 小时"`、`-5 → "0 秒"`。
5. `date_label("2026-10-03") == "10月3日"`、`date_label("2026-12-25") == "12月25日"`、`date_label("") == "今日"`、`date_label("x") == "今日"`。
6. `pct(5443627, 8260391) == 66`、`pct(0, 0) == 0`、`pct(1, None) == 0`、`pct(40960, 61200) == 67`。
7. `js_round(0.5) == 1`、`js_round(1.5) == 2`、`js_round(2.5) == 3`、`js_round(2.4) == 2`。
8. `v2f`：解码刻度 `0 → 0`、`-3 → 0`、`None → 0`、`25 → 0.2`、`50 → 0.4`、`74 → 0.496`、`100 → 0.6`、`150 → 0.7`、`200 → 0.8`、`300 → 1`、`500 → 1`；预填充刻度 `600 → 0.2`、`2412 → 0.804`、`3000 → 1`（用 `assertAlmostEqual`）。
9. `Config()` 的每个默认值；`load_config` 读不存在的文件、读内容是 `[1,2]` 的文件、读坏 JSON 都得到默认值；读 `{"round_gap_s": 30, "price_output": "贵", "currency": "¥", "monitor_match": "connector", "monitor_value": "USB-C-0", "不认识": 1, "done_hold_s": true}` 得到 `round_gap_s == 30.0`、`price_output == 0.47`、`currency == "¥"`、`monitor_match == "connector"`、`monitor_value == "USB-C-0"`、`done_hold_s == 4.0`。用 `tempfile` 建临时文件。
10. `View()` 的默认值（`state == "idle"`、`arc == "blank"`、`cards == []`、`bar is None`、`dim == 1.0`）；构造一个各字段都非默认值的 `View`（含 2 个 `Seg`、3 个 `Card`、一个带文字的 `Bar`），`View.from_dict(v.to_dict()) == v`，并且 `json.dumps(v.to_dict(), ensure_ascii=False)` 不报错；`View.from_dict({})` 等于 `View()`；`View.from_dict({"bar": None, "多余": 1, "cards": [{"label": "输出"}]})` 得到一张 `label == "输出"`、其余默认的卡片。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 -m unittest panel.tests.test_base -v
python3 -c "import panel, panel.config, panel.fmt, panel.scale, panel.view; print(panel.__version__)"
```
