# 任务 C：容器内外挂和补丁

先读 `AGENTS.md`，再读 `docs/design.md` 的“容器内外挂（只负责外面读不到的）”和“外挂的安装、自检与降级”两节。`docs/spike-hook/` 里是验证机制时的草稿，可以参考写法，但正式实现按本说明另写。

外挂跑在 TensorFold 进程里。最重要的要求：**外挂出任何问题都不能影响推理，也不能让 `/health` 出错**。

## 交付文件

1. `hook/tfpanel_hook.pth`：只有一行 `import tfpanel_hook`（结尾有换行）。
2. `hook/tfpanel_hook.py`：外挂本体，只用标准库。
3. `hook/make_patch.py`：生成补丁文件的脚本。
4. `hook/0900-tfpanel-hook.patch`：由 `make_patch.py` 生成的补丁（生成后留在仓库里）。
5. `hook/check.py`：在容器里运行的检查脚本。
6. `hook/tests/__init__.py`（空）和 `hook/tests/test_hook.py`：`unittest` 测试，在 MacBook Pro 上跑，不需要真实的 TensorFold。

不要创建别的文件，不要改 `docs/spike-hook/`。

## 引擎里的真实结构（TensorFold 0.6.1，已核对源码，照此实现）

`tensorfold/cuda/health.py`：

```python
class Health:
    def snapshot(self, app) -> dict[str, Any]:     # 返回 /health 的 JSON 对象
        ...
        scheduler = getattr(getattr(app, "engine", None), "scheduler", None)
        decoder = getattr(scheduler, "decoder", None)
        if decoder is not None:
            body["streams"] = {"decoding": len(getattr(decoder, "streams", ())),
                               "prefilling": len(getattr(decoder, "filling", ())), "max": scheduler.max_streams}
        return body
```

`decoder`（`tensorfold/families/qwen4_exp/cuda/multi.py` 的 `MultiDecoder`）上的三张表：

| 属性 | 类型 | 含义 |
| --- | --- | --- |
| `decoder.streams` | `dict[int, Stream]` | 正在解码的流，键是流的 id |
| `decoder.filling` | `list[Stream]` | 正在预填充的流 |
| `decoder.fills` | `dict[int, list]` | 流 id → `[引擎, 是否带草稿, 已算到第几个 token, 其他]`，只有预填充中的流才有 |

每条流（`Stream`）上用到的属性：`s.sid`（int，流的 id）、`s.prompt`（提示的 token 列表）、`s.cached`（int，从缓存复用的 token 数）、`s.out`（已输出的 token 列表）。

这些表由引擎线程修改，`/health` 在另一个线程里读，**读的时候不加锁**。所以读到一半表变了是正常情况，要能应付。

## `hook/tfpanel_hook.py` 的行为

### 导入钩子的写法（已在真实镜像里验证过，照这个写，不要自己研究 importlib 的内部实现）

`docs/spike-hook/tfpanel_hook.py` 里的 `_Finder` 就是验证过的写法，要点：

```python
class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path, target=None):
        if name != TARGET:
            return None
        sys.meta_path.remove(self)                 # 先把自己摘掉，下面再查就不会绕回来
        spec = importlib.util.find_spec(name)      # 让其余的查找器找到真正的 spec
        if spec is None or spec.loader is None:
            return spec
        run = spec.loader.exec_module
        def exec_module(module):
            run(module)                            # 原样执行模块；它抛的异常原样抛出
            try:
                patch_health(module)
            except Exception as exc:
                print("[tfpanel] 外挂未挂载：", exc, file=sys.stderr)
        spec.loader.exec_module = exec_module      # 只换这一个加载器实例上的方法
        return spec

sys.meta_path.insert(0, _Finder())
```

在它的基础上补全本说明要求的行为即可（`find_spec` 里除了 `run(module)` 之外的部分出异常时返回 `None`，让导入照常进行）。Python 3.12（容器、Spark）和 MacBook Pro 上的 `python3` 都要能跑，写完直接用测试验证，不用读标准库源码。

### 导入时

- 只做一件事：在 `sys.meta_path` 最前面登记一个导入钩子。不导入 `torch`、不导入 `tensorfold` 的任何模块、不打印任何东西。
- 钩子只关心模块名 `tensorfold.cuda.health`。这个模块第一次被导入并执行完之后，调用 `patch_health(module)`。钩子用过一次就把自己从 `sys.meta_path` 里摘掉。
- 钩子内部出任何异常都不能让那次导入失败：模块照常导入，只是没有外挂。

### `patch_health(module) -> bool`

- 自检：`module.Health` 存在、`module.Health.snapshot` 可调用。不满足：向 stderr 打印一行 `[tfpanel] 外挂未挂载：<原因>`，返回 `False`，不改任何东西。
- 满足：把 `Health.snapshot` 换成包装函数（用 `functools.wraps`），返回 `True`。已经包过就不再包（重复调用仍返回 `True`）。
- 包装函数：

```
def snapshot(self, app, *args, **kwargs):
    body = 原 snapshot(self, app, *args, **kwargs)     # 原函数抛的异常原样抛出
    try:
        段 = build_section(app)
        if 段 is not None and isinstance(body, dict):
            body["tfpanel"] = 段
    except Exception:
        pass
    return body          # 同一个对象
```

### `build_section(app) -> dict | None`

返回 `{"v": 1, "streams": [...]}`，或者在读不到预期结构时返回 `None`（整段不输出）。

- `decoder = app.engine.scheduler.decoder`，任何一层不存在或为 `None`：返回 `None`。
- `decoder.streams` 不是 `dict`、`decoder.filling` 不是 `list`、`decoder.fills` 不是 `dict`：返回 `None`。
- 先取快照：`list(decoder.streams.values())`、`list(decoder.filling)`。取的时候碰上 `RuntimeError`（表正在被改）就重试，最多试 3 次，还不行返回 `None`。
- 解码中的每条流一行：`{"id": int(s.sid), "phase": "decode", "prompt": len(s.prompt), "cached": int(s.cached), "output": len(s.out)}`
- 预填充中的每条流一行：`{"id": int(s.sid), "phase": "prefill", "prompt": len(s.prompt), "cached": int(s.cached), "filled": 已算到第几个}`
  - `已算到第几个` = `int(decoder.fills[s.sid][2])`。
  - `decoder.fills` 里没有这条流（它刚好算完、正在挪到解码表）：`filled` = `len(s.prompt)`。
- 同一个 id 在两张表里都出现：只保留 `decode` 那一行。
- 结果按 `id` 从小到大排。
- 任何一条流缺属性或类型不对（`AttributeError`、`TypeError`、`ValueError`、`IndexError` 等）：返回 `None`，不是只跳过那一条。
- 只读：只读上面列的属性，不调用引擎的任何方法，不加锁，不修改任何东西。

`patch_health`、`build_section` 要能在测试里直接调用。

## `hook/make_patch.py`

部署仓库在构建镜像时，进到 Python 的包目录（里面有 `tensorfold/` 目录的那一层，即 `/usr/local/lib/python3.12/dist-packages`），对每个补丁执行 `patch -p0 --forward < 补丁`。补丁文件开头可以有说明文字。已有补丁的样子：

```text
Flash Next recipe on TensorFold v0.6.1 (17c73e1): video input and ...
--- tensorfold/cuda/geometry.py
+++ tensorfold/cuda/geometry.py
@@ -14,6 +14,19 @@
```

`python3 hook/make_patch.py` 读同目录的 `tfpanel_hook.pth` 和 `tfpanel_hook.py`，写出同目录的 `0900-tfpanel-hook.patch`：

- 第一行是说明：`tfpanel side-screen hook: adds two new files, changes no TensorFold file.`
- 然后是两个“新增文件”的 unified diff，先 `.pth` 后 `.py`，文件路径不带目录：

```text
--- /dev/null
+++ tfpanel_hook.pth
@@ -0,0 +1 @@
+import tfpanel_hook
--- /dev/null
+++ tfpanel_hook.py
@@ -0,0 +1,<行数> @@
+<每一行前面加一个 +>
```

- 两个源文件都必须以换行结尾（不是就报错退出），这样补丁里不需要 `\ No newline at end of file`。
- 提供函数 `build_patch(pth_text: str, py_text: str) -> str`，`main()` 调用它并写文件。`import make_patch` 不能有副作用。
- 脚本运行结束打印补丁路径和行数。

## `hook/check.py`

在已经打上补丁的容器里用 `python3 /hook/check.py` 运行，不需要显卡。逐项打印结果，全部通过时最后一行打印 `CHECK OK` 并以 0 退出，任何一项不通过以 1 退出：

1. 启动后 `tfpanel_hook` 已经在 `sys.modules` 里（`.pth` 生效），此时 `torch` 和 `tensorfold` 都不在 `sys.modules` 里。
2. `import tensorfold.cuda.health as h` 之后，`h.Health.snapshot` 已被包装（例如带有你设的标记属性）。
3. 用 `types.SimpleNamespace` 造一个假的 `app`：一条解码中的流（`sid=3`，提示 18420，缓存 16384，输出 312）、一条预填充中的流（`sid=4`，提示 24615，缓存 2048，`fills[4] = [None, None, 10240, None]`），`scheduler.max_streams = 5`，`app.effective_context_window = 262144`。`h.of(app).snapshot(app)` 的结果里：
   - `tfpanel == {"v": 1, "streams": [{"id": 3, "phase": "decode", "prompt": 18420, "cached": 16384, "output": 312}, {"id": 4, "phase": "prefill", "prompt": 24615, "cached": 2048, "filled": 10240}]}`
   - `streams == {"decoding": 1, "prefilling": 1, "max": 5}`、`ok is True`、`context_length == 262144`（原有字段不受影响）
4. 把假 `decoder` 的 `fills` 属性删掉再调一次：结果里没有 `tfpanel`，其他字段照常。
5. `app` 没有 `engine` 属性时：结果里没有 `tfpanel`，`ok is True`。

## 测试要求（`hook/tests/test_hook.py`）

在测试里把 `hook/` 目录加进 `sys.path` 来导入 `tfpanel_hook` 和 `make_patch`。用假包代替 TensorFold：在临时目录里写 `tensorfold/__init__.py`、`tensorfold/cuda/__init__.py`、`tensorfold/cuda/health.py`（里面一个 `Health` 类，`snapshot(self, app)` 返回一个字典），把临时目录加进 `sys.path`。每个测试结束后清理 `sys.modules` 里的 `tensorfold*`、`tfpanel_hook`，清理 `sys.meta_path` 里外挂登记的钩子，恢复 `sys.path`。至少覆盖：

1. 导入 `tfpanel_hook` 后、导入假 `tensorfold.cuda.health` 之前：`tensorfold` 不在 `sys.modules` 里；导入之后：`Health.snapshot` 已被包装，钩子已从 `sys.meta_path` 摘掉。
2. `build_section`：上面 check.py 第 3 项那组数据，结果完全相等。
3. 包装后的 `snapshot` 返回的是原函数返回的同一个对象（`is`），原有键值不变，多了 `tfpanel`。
4. 原 `snapshot` 抛异常时，包装函数原样抛出（同一个异常对象）。
5. 降级，每种情况都是“没有 `tfpanel` 键、其他照常”：`app` 没有 `engine`；`decoder` 为 `None`；`decoder` 缺 `fills`；`decoder.streams` 是列表而不是字典；某条流没有 `cached` 属性；某条流的 `prompt` 是 `None`；`fills[sid]` 只有 2 个元素。
6. 预填充的流不在 `fills` 里：`filled == len(prompt)`。
7. 同一个 id 两张表都有：只有一行，`phase == "decode"`。
8. 结果按 id 排序（造 id 为 7、2、5 的三条流）。
9. `decoder.streams` 是一个 `values()` 前两次抛 `RuntimeError`、第三次正常的假字典（继承 `dict` 重写 `values`）：能得到结果；一直抛：没有 `tfpanel`。
10. 原 `snapshot` 返回的不是字典（例如 `None`）：包装函数原样返回，不抛异常。
11. 自检：假模块没有 `Health`、`Health` 没有 `snapshot`：`patch_health` 返回 `False`，stderr 有一行以 `[tfpanel] 外挂未挂载` 开头的字；重复 `patch_health` 不会包两层（调一次 `snapshot` 原函数只被调一次）。
12. 假的 `tensorfold/cuda/health.py` 本身有语法错误时：`import tensorfold.cuda.health` 抛的是 `SyntaxError`（原样），而不是外挂自己的异常。
13. `build_patch`：结果第一行是说明；用 `subprocess` 在一个空的临时目录里执行 `patch -p0 --forward`（把补丁文字从标准输入送进去），退出码为 0，生成的 `tfpanel_hook.pth`、`tfpanel_hook.py` 和 `hook/` 里的源文件逐字节相同。
14. 仓库里的 `hook/0900-tfpanel-hook.patch` 和 `build_patch` 现在生成的内容相同（防止改了外挂忘了重新生成补丁）。

## 在 Spark 上的检查（本任务明确允许下面这一种 `docker run`）

用一次性容器检查补丁打得上、外挂能生效。它不带显卡、不占端口、用完即删，**不会碰正在运行的模型容器**。除了下面这几条命令原样执行之外，不要对 docker 做任何别的事：

```sh
cd /Users/kris/projects/tensorfold-panel
ssh spark 'rm -rf /tmp/tfpanel-hook && mkdir -p /tmp/tfpanel-hook'
scp hook/0900-tfpanel-hook.patch hook/check.py spark:/tmp/tfpanel-hook/
ssh spark 'docker run --rm --entrypoint sh -v /tmp/tfpanel-hook:/hook:ro tensorfold-qwen38:v0.6.1-languages -c "cd /usr/local/lib/python3.12/dist-packages && patch -p0 --forward < /hook/0900-tfpanel-hook.patch && ls -l tfpanel_hook.pth tfpanel_hook.py && python3 /hook/check.py && tensorfold --version"'
ssh spark 'rm -rf /tmp/tfpanel-hook'
```

第三条命令的输出里必须有 `CHECK OK`，最后一行是 TensorFold 的版本号（含 `0.6.1`）。

## 完成前必须运行并全部通过

```sh
cd /Users/kris/projects/tensorfold-panel
python3 hook/make_patch.py
python3 -m unittest discover -s hook/tests -t hook -v
python3 -c "import ast; ast.parse(open('hook/tfpanel_hook.py').read()); ast.parse(open('hook/check.py').read())"
```

再加上上一节“在 Spark 上的检查”的四条命令。
