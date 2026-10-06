# 任务 V6：`README.md` 和两个脚本的说明文字跟上“支持 vLLM”

先读 `AGENTS.md`，再读 `docs/design-vllm.md`（重点看“引擎识别”“界面的改动”“配置的改动”“用起来和 TensorFold 有什么不同”“已知限制与可选项”）。本任务改三个文件：`README.md`、`scripts/tfpanel.sh`、`scripts/install-autostart.sh`。不要改别的文件，不需要在 Spark 上运行任何东西。

## 背景

副屏程序现在自动识别 Spark 上跑的是 TensorFold 还是 vLLM，两种都能显示。`README.md` 还是只讲 TensorFold 的写法，要改成两种引擎都讲清楚。读者是这个仓库的使用者：想知道怎么装、怎么配、画面上每样东西是什么意思。文风和现有的 `README.md` 保持一致（短句、表格、命令各占一个代码块），不写实现细节，不写改动历史（不要出现“现在支持”“新增了”“第一阶段”这类话，直接按现状写）。

## 第一步：改 `README.md`

逐节改下面这些地方，没提到的章节和句子保持原样。

1. **“这是什么”**：第二段改成说明——模型（Qwen3.8 Flash Next）用 TensorFold 或 vLLM 跑在 Spark 上；副屏程序自己认出当前是哪种引擎、在哪个端口，换引擎不用改配置、不用重启副屏程序；客户端照常连模型的端口，什么都不用改。
2. **“组成”表**：
   - “外挂”一行写明只对 TensorFold 有效（vLLM 不需要外挂）。
   - “副屏程序”一行：读的东西按引擎分——TensorFold 读 `/health`、`/metrics`，vLLM 只读 `/metrics`；都读 `/proc/meminfo`。
3. 在“组成”后面加一节 **“两种引擎的差别”**：一张三列的表（方面 / TensorFold / vLLM），内容取自设计文档“用起来和 TensorFold 有什么不同”那张表，保留这几行：解码速度和完成画面、今日用量和费用、流指示点、预填充开始时的提示长度和缓存命中、预填充速度和进度、看到新请求的延迟、中途断开的请求。表下面用一两句话写：vLLM 的面板每次读取都会在容器日志里留一行访问记录，建议在 vLLM 的启动参数里加 `--disable-access-log-for-endpoints /health,/metrics,/v1/models`。
4. **“安装”第四步（装外挂）**：开头写明这一步只在用 TensorFold 时需要，用 vLLM 跳过。
5. **“配置”表**：
   - `base_url` 一行改成：含义“只用这一个接口地址（写了它就不再自动找）”，默认值“空”。
   - 在它后面加一行 `base_urls`：含义“接口地址列表，按顺序试，用第一个认得出引擎的”，默认值 `["http://127.0.0.1:8888", "http://127.0.0.1:8000"]`。
6. **“画面说明”**：
   - 表里“引擎离线”一行的 `等待 TensorFold 响应…` 改成 `等待引擎响应…`；右侧三栏不变；补一句状态条右边写“上次模型”和最后一次连上的引擎名。
   - “空闲（今日统计）”一行补充：状态条上模型名后面标出引擎，例如 `Qwen3.8-Flash-Next · vLLM`。
   - “预填充中”一行补充 vLLM 的写法：标题旁边有琥珀色描边的“近期平均”标记，主数字是最近几次请求的平均预填充速度（这次预填充期间不变），进度条按时间匀速前进，写“已算约 10.2K / 24.6K”。
   - 表下面那段：流指示点的个数——TensorFold 等于并发上限（现在 5 个）；vLLM 从 4 个起，同时在跑的流多了再加，最多画 12 个。“外挂未生效”只在引擎是 TensorFold 时出现，这时状态条左边只写模型名、不写引擎名。
7. **“更新和卸载”**：涉及外挂的句子都加上“用 TensorFold 时”的限定。
8. **“开发”**：目录表 `fixtures/` 一行补充 `fixtures/vllm/` 是在真实 vLLM 上录下来的 `/metrics` 序列，适配器的测试用它们；最后一段的链接里加上 vLLM 的设计文档 [`docs/design-vllm.md`](docs/design-vllm.md)。

## 第二步：两个脚本里的说明文字

- `scripts/tfpanel.sh` 第 2 行的注释 `# TensorFold 副屏仪表盘：…` 改成 `# 副屏仪表盘（TFPanel）：…`，冒号后面不变。
- `scripts/install-autostart.sh` 里 `Comment=在拓展坞副屏上显示 TensorFold 的运行状态` 改成 `Comment=在拓展坞副屏上显示推理引擎的运行状态`。

这两个文件只改这两行。

## 最后一步：收尾检查

```sh
cd /Users/kris/projects/tensorfold-panel
python3 - <<'EOF'
import re, subprocess
from panel.config import Config
readme = open("README.md", encoding="utf-8").read()
problems = []
for key in Config.__dataclass_fields__:
    if f"| `{key}` |" not in readme:
        problems.append(f"配置表里没有 {key}")
for word in ("等待 TensorFold 响应", "现在支持", "新增了", "第一阶段"):
    if word in readme:
        problems.append(f"不该出现：{word}")
for word in ("vLLM", "base_urls", "等待引擎响应…", "近期平均", "已算约", "两种引擎的差别",
             "--disable-access-log-for-endpoints /health,/metrics,/v1/models", "docs/design-vllm.md", "fixtures/vllm/"):
    if word not in readme:
        problems.append(f"应该出现：{word}")
for target in re.findall(r"\]\(([^)#]+)\)", readme):
    if not target.startswith("http"):
        import os
        if not os.path.exists(target):
            problems.append(f"链接指向不存在的文件：{target}")
stat = subprocess.run(["git", "diff", "--numstat", "--", "scripts/tfpanel.sh", "scripts/install-autostart.sh"],
                      capture_output=True, text=True).stdout.split()
if stat != ["1", "1", "scripts/install-autostart.sh", "1", "1", "scripts/tfpanel.sh"]:
    problems.append(f"两个脚本应各改一行：{stat}")
print("\n".join(problems) if problems else "OK")
EOF
sh -n scripts/tfpanel.sh && sh -n scripts/install-autostart.sh && echo SYNTAX-OK
```

通过的标准：第一条输出 `OK`，第二条输出 `SYNTAX-OK`。全部通过后最后一行输出 `DONE`。
