# 任务 C2：外挂收尾（小修）

先读 `AGENTS.md`。`hook/` 里的文件上一位执行者已经写好了大部分，本任务只做下面列的几处修改和最后的检查。任务 C 的完整要求在 `docs/tasks/C-hook.md`，需要时查阅，但**不要重做，也不要研究 Python 标准库 importlib 的内部实现**。

## 背景

`hook/tfpanel_hook.py` 里上一位执行者自己写了一个 `_find_spec` 函数，用 `FileFinder` 去扫目录找模块。这是多余的，而且写错了（`FileFinder` 的参数顺序不对），导致测试 `test_01_hook_registered_then_removed` 失败。正确的做法就是 `docs/tasks/C-hook.md` 里“导入钩子的写法”那段：摘掉自己之后调用 `importlib.util.find_spec(name)`。编排者已经验证过：改成这样之后 14 条要求的测试全部通过。

## 要做的修改

1. `hook/tfpanel_hook.py`：
   - 删掉整个 `_find_spec` 函数（连同它的文档字符串）。
   - `_Finder.find_spec` 里，把从 `# 没有父包 __path__ 时` 这行注释开始、到 `spec = _find_spec(...)` 这一行为止的那一段，换成一行：`spec = importlib.util.find_spec(name)      # 让其余的查找器找到真正的 spec`。
   - 删掉不再使用的 `import importlib.machinery` 和 `import os`。
   - 其余（`build_section`、`patch_health`、`_Finder` 的其他部分）不动。
2. `hook/tests/test_hook.py`：删掉 `test_15_stale_path_cache_still_wraps` 和 `test_16_degrade_when_health_unimportable` 这两个测试（它们测的是被删掉的那套逻辑，任务没有要求），以及只有它们用到的 `import`。其余测试不动。
3. `python3 hook/make_patch.py` 重新生成 `hook/0900-tfpanel-hook.patch`。
4. `hook/check.py`：对照 `docs/tasks/C-hook.md` 的“`hook/check.py`”一节核对 5 项检查都有、最后打印 `CHECK OK`；缺什么补什么，没问题就不动。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 hook/make_patch.py
python3 -m unittest discover -s hook/tests -t hook -v 2>&1 | tail -25
python3 -c "import ast; ast.parse(open('hook/tfpanel_hook.py').read()); ast.parse(open('hook/check.py').read())"
grep -n "_find_spec\|FileFinder\|importlib.machinery" hook/tfpanel_hook.py; echo "上一行之前应没有任何输出"
```

测试应是 14 个全部 `ok`。然后做 Spark 上的检查（一次性容器，不带显卡，不碰正在运行的模型；只许原样执行这四条）：

```sh
ssh spark 'rm -rf /tmp/tfpanel-hook && mkdir -p /tmp/tfpanel-hook'
scp hook/0900-tfpanel-hook.patch hook/check.py spark:/tmp/tfpanel-hook/
ssh spark 'docker run --rm --entrypoint sh -v /tmp/tfpanel-hook:/hook:ro tensorfold-qwen38:v0.6.1-languages -c "cd /usr/local/lib/python3.12/dist-packages && patch -p0 --forward < /hook/0900-tfpanel-hook.patch && ls -l tfpanel_hook.pth tfpanel_hook.py && python3 /hook/check.py && tensorfold --version"'
ssh spark 'rm -rf /tmp/tfpanel-hook'
```

第三条的输出里必须有 `CHECK OK`，最后一行是 TensorFold 的版本号（含 `0.6.1`）。

如果容器里的检查不通过：把完整输出贴在结果里，最后一行写 `FAILED: <原因>`，**不要自己换别的导入钩子写法**，由编排者来判断。
