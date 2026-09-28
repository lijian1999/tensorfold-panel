# 任务 E1：采集器在预填充开始时拿到提示 token 数（Python）

先读 `AGENTS.md`，再读 `docs/design.md`「每个指标怎么算」里“上下文用量”一行和紧跟表格后面的“提示 token 数怎么拿”一段，然后读 `collector/tfpanel.py` 的 `_Request`、`Collector.snapshot`、`patch_chat_app`、`run_self_check`、`main`，以及 `collector/tests/test_tfpanel.py`。本任务只改这两个文件。

## 背景

副屏要在解码时显示上下文占用 = 提示 token 数 + 已输出 token 数。引擎只在请求结束时才给 `prompt_tokens`，但 TensorFold 的 `ChatApp.chat()` 一开头就会在**同一个线程里**调用：

```python
def render(self, messages, tools=None, thinking=None) -> tuple[list[int], int]:
    """Prompt ids plus the length of the rendered history that prefixes them."""
```

返回值第 0 项就是完整的提示 token 列表。我们包住 `render`，只读返回值的长度，记到当前请求上。`render` 也可能在请求之外被调用（例如预热），这些调用必须忽略。

## 改动

1. 模块级新增 `_TLS = threading.local()`，用来在 `chat()` 执行期间记住“本线程正在处理的请求记录”。
2. `_Request` 新增字段 `prompt_tokens`（初始 `None`，加进 `__slots__`）。
3. `Collector` 新增方法 `set_prompt_tokens(self, req, n)`：在 `self._lock` 内，只有 `req.prompt_tokens is None` 时才设为 `n`（一个请求只记第一次）。
4. `patch_chat_app` 里的 chat 包装函数：在调用原 `chat` 之前把 `_TLS.req` 设为本次请求记录（`begin` 失败时为 `None`），调用结束后（无论正常返回还是抛异常）恢复成调用前的值（用 `try/finally`）。原有的开始 / 结束 / 失败记录、返回值和异常传递都不能变。
5. `patch_chat_app` 在 chat 打补丁成功之后，**尽力**包装 `ChatApp.render`：
   - `render` 不存在或不可调用 → 不包，`hooks["render"] = "missing"`，chat 的补丁照常生效，函数仍返回 `True`。
   - 否则用 `functools.wraps` 包装：
     ```
     def wrapped_render(self, *args, **kwargs):
         result = original_render(self, *args, **kwargs)   # 异常原样抛出
         尽力（任何异常都吞掉）：
             req = getattr(_TLS, "req", None)
             若 req 不是 None，且 result 是 tuple、长度 ≥ 1、result[0] 支持 len()：
                 collector.set_prompt_tokens(req, len(result[0]))
         return result   # 必须是同一个对象，不复制、不修改
     ```
     然后 `hooks["render"] = "ok"`。
6. `run_self_check` 走“不通过”分支时，同时设 `hooks["render"] = "missing"`。
7. `main()` 里初始的 `hooks` 改为 `{"chat": state, "render": state}`（`state` 就是现在算出的 `pending` / `missing`）。
8. `snapshot()` 的 `current` 新增键 `"prompt_tokens"`：请求记录上的值（整数或 `null`），在 `self._lock` 内读取。预填充和解码时都输出。`current` 里其他键不变。

输出里仍然绝不能包含任何对话文字。

## 测试要求（加到 collector/tests/test_tfpanel.py，现有测试一条都不能删改；只有断言 `hooks` 整体等于某个字典的地方，如果因为多了 `render` 键而失败，可以把期望字典补上 `"render"`）

用现有测试里的假 `ChatApp` 写法，另外给它加一个 `render` 方法（返回 `([1, 2, 3, ...], 0)` 这样的元组），并让假的 `chat` 在内部先调用 `self.render(...)`。至少覆盖：

1. 打补丁后，一次 chat 调用期间 `render` 返回 1234 个 token → 在 chat 返回前（例如在假 chat 里调用 `collector.snapshot()`）`current["prompt_tokens"] == 1234`。
2. `render` 的返回值是同一个对象（`is`），参数原样传到原 `render`。
3. 原 `render` 抛出的异常原样抛出（同一对象），chat 的包装照常走“失败”分支。
4. 在 chat 之外直接调用 `render`（没有进行中的请求）→ 不影响任何请求，不报错。
5. chat 里调用两次 `render`（先 100 个、再 50 个）→ `prompt_tokens == 100`。
6. `render` 返回的不是元组（例如返回一个整数或 `None`）→ `prompt_tokens` 保持 `None`，chat 照常返回。
7. chat 结束后 `_TLS.req` 恢复成调用前的值（正常返回和抛异常两种情况都测）。
8. 两个线程同时各做一次 chat，各自的 `render` 长度记到各自的请求上（用 `threading.Event` 控制两次调用交错，不 sleep）。
9. `ChatApp` 没有 `render` 方法 → chat 补丁照常生效，`hooks == {"chat": "ok", "render": "missing"}`（在测试里自己构造初始 hooks 字典）。
10. 自检不通过（`chat` 没有 `on_delta`，或 `force_fail=True`）→ `hooks["render"] == "missing"`。
11. 预填充时 `snapshot()["current"]` 含 `prompt_tokens` 键，没调用过 render 时为 `None`。
12. HTTP 测试：`current` 不为空时包含 `prompt_tokens` 键（如果现有 HTTP 测试没有进行中的请求，就新增一条用假 ChatApp 在 chat 中途请求 `/metrics` 的测试，或直接对 `snapshot()` 断言也可以）。

## 完成前必须运行并全部通过

```sh
cd collector && ~/.local/share/uv/tools/tensorfold/bin/python -m unittest discover -s tests -v
~/.local/share/uv/tools/tensorfold/bin/python -c "import ast,sys; ast.parse(open('collector/tfpanel.py').read())"
```

不要运行 `collector/tfpanel serve ...`，不要启动、停止或重启 TensorFold，不要修改 `~/.local/share/uv/tools/tensorfold/` 下的任何文件。真实联调由编排者来做。
