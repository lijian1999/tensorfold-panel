#!/usr/bin/env python3
"""生成补丁文件 0900-tfpanel-hook.patch（在部署仓库构建镜像时用 patch -p0 打上）。

用法：python3 hook/make_patch.py
读同目录的 tfpanel_hook.pth 和 tfpanel_hook.py，写出同目录的 0900-tfpanel-hook.patch。
补丁只新增两个文件，不修改 TensorFold 任何已有文件。
"""

import os
import sys

# 补丁第一行的说明文字
HEADER = "tfpanel side-screen hook: adds two new files, changes no TensorFold file."


def _file_diff(name, text):
    """拼一个"新增文件"的 unified diff 段；两个源文件都必须以换行结尾。"""
    if not text.endswith("\n"):
        raise ValueError(f"{name} 不以换行结尾")
    lines = text.split("\n")[:-1]
    if len(lines) == 1:
        header = "@@ -0,0 +1 @@"
    else:
        header = f"@@ -0,0 +1,{len(lines)} @@"
    parts = ["--- /dev/null", f"+++ {name}", header]
    parts += ["+" + line for line in lines]
    return "\n".join(parts) + "\n"


def build_patch(pth_text: str, py_text: str) -> str:
    """由两个源文件的文本生成补丁全文；源文件不以换行结尾时抛 ValueError。"""
    return (HEADER + "\n"
            + _file_diff("tfpanel_hook.pth", pth_text)
            + _file_diff("tfpanel_hook.py", py_text))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    src_pth = os.path.join(here, "tfpanel_hook.pth")
    src_py = os.path.join(here, "tfpanel_hook.py")
    with open(src_pth, encoding="utf-8") as f:
        pth_text = f.read()
    with open(src_py, encoding="utf-8") as f:
        py_text = f.read()
    try:
        patch_text = build_patch(pth_text, py_text)
    except ValueError as exc:
        print(f"错误：{exc}，无法生成补丁", file=sys.stderr)
        sys.exit(1)
    out_path = os.path.join(here, "0900-tfpanel-hook.patch")
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(patch_text)
    print(out_path)
    print(f"共 {patch_text.count(chr(10))} 行")


if __name__ == "__main__":
    main()
