#!/usr/bin/env python3
"""把 fixtures/ 里的快照样例画成 PNG（离屏画到内存图片，不需要显示器）。

用法：python3 scripts/offscreen.py [--out 目录] [样例名 …]
不给样例名就画 fixtures/ 里全部。
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]        # 仓库根目录（scripts/ 的上一级）
sys.path.insert(0, str(ROOT))

import json  # noqa: E402

from panel.config import Config  # noqa: E402
from panel.render import render_png  # noqa: E402
from panel.viewmodel import ViewModel  # noqa: E402


def main(argv):
    argv = list(argv)
    out = Path("/tmp/tfpanel-shots")
    if "--out" in argv:
        i = argv.index("--out")
        if i + 1 >= len(argv):
            print("缺少样例名，应为：--out 目录", file=sys.stderr)
            return 1
        out = Path(argv[i + 1])
        del argv[i:i + 2]

    fixtures = ROOT / "fixtures"
    names = argv
    if not names:
        names = sorted(p.stem for p in fixtures.glob("*.json"))

    out.mkdir(parents=True, exist_ok=True)
    for name in names:
        src = fixtures / f"{name}.json"
        if not src.is_file():
            print(f"没有这个样例：{name}", file=sys.stderr)
            return 1
        with open(src, encoding="utf-8") as f:
            snapshot = json.load(f)
        view = ViewModel(Config()).update(snapshot, 0.0)
        target = out / f"{name}.png"
        render_png(view, str(target))
        print(target)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
