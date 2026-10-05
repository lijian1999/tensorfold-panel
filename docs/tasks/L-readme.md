# 任务 L：重写 README

先读 `AGENTS.md`，再通读 `docs/design.md` 的“整体架构”“外挂的安装、自检与降级”“部署与运行”三节，然后看一遍这些脚本的文件头注释（用法都写在里面）：`scripts/sync.sh`、`scripts/hook.sh`、`scripts/install-autostart.sh`、`scripts/tfpanel.sh`、`scripts/offscreen.py`。

程序已经全部实现。本任务只改一个文件：仓库根目录的 `README.md`。不运行任何会改动 Spark 的命令（不同步、不安装、不重启）。

## 第一步：看现在的 README

```sh
cd /Users/kris/projects/tensorfold-panel && cat README.md
```

现在的内容还写着“程序还没有实现”，整篇重写。

## 第二步：写新的 `README.md`

读者是这台机器的主人：懂命令行，但不想读代码。全文中文，写给人看：先说做什么，再说怎么做；每条命令前用一句话说明它做什么、在哪台机器上执行。不要写实现细节（那些在 `docs/design.md` 里）。

按这个顺序分节（二级标题用下面的原文）：

1. `## 这是什么`：两三句话。副屏显示什么（解码速度、预填充速度和进度、并发的流数、今日用量和按 API 价格折算的费用）；模型跑在 DGX Spark 上，副屏接在 Spark 的 C 口；客户端不用改。
2. `## 组成`：一张三行的表——外挂（容器里，给 `/health` 加一段 `tfpanel`）、副屏程序（Spark 主机上，`~/tfpanel/`）、今日用量文件（`~/.local/state/tfpanel/`）。
3. `## 安装`：按顺序的步骤，每步一条命令加一句说明：
   1. 在 MacBook Pro 上同步程序：`scripts/sync.sh`
   2. 在 Spark 上启动：`~/tfpanel/scripts/tfpanel.sh start`
   3. 在 Spark 上安装开机启动项：`~/tfpanel/scripts/install-autostart.sh`；说明它会提示一条开启自动登录的 `sudo` 命令，需要自己执行一次。
   4. 安装外挂（可选，没有它副屏也能工作，只是预填充画面降级）：在 MacBook Pro 上 `scripts/hook.sh install`，然后在 Spark 上进入部署仓库执行 `PULL=0 ./start.sh restart`。写明：重启期间模型不可用，大约几分钟；`scripts/hook.sh status` 可以查看外挂是否生效。
4. `## 日常使用`：`tfpanel.sh` 的 `start`、`stop`、`restart`、`status` 各一句；日志在 `~/.local/state/tfpanel/tfpanel.log`；需要操作 Spark 桌面时先 `stop`（副屏是 Spark 唯一的屏幕时，仪表盘会盖住桌面）。
5. `## 配置`：配置文件 `~/.config/tfpanel/config.json`，没有就全用默认值。一张表列出全部配置项：键名、含义、默认值。键名和默认值从 `panel/config.py` 的 `Config` 里照抄（共 14 项），不要自己编。再给一个只改两三项的例子（例如把一轮间隔改成 30 秒、把输出单价改掉）。写明改完要 `tfpanel.sh restart`。
6. `## 画面说明`：一张表，五种状态（引擎离线、空闲、预填充中、解码中、完成）各一行，说明圆圈里和右侧三栏显示什么。内容以 `docs/design.md` 的“单个请求时每个状态显示什么”为准，写简短。再用两三句话说明：流指示点的颜色含义；连续请求算“一轮”；状态条出现“外挂未生效”是什么意思、怎么办。
7. `## 更新和卸载`：更新 = 重新 `scripts/sync.sh` 然后 `tfpanel.sh restart`（改了 `hook/` 才需要重新 `hook.sh install` 并重启模型）；卸载 = `tfpanel.sh stop`、`install-autostart.sh --remove`、`scripts/hook.sh remove` 后重启模型、删除 `~/tfpanel` 和 `~/.local/state/tfpanel`。
8. `## 开发`：测试怎么跑（MacBook Pro 上 `python3 -m unittest discover -s panel/tests -t .` 和 `python3 -m unittest discover -s hook/tests -t hook`；绘制的测试只能在 Spark 上跑）；离屏截图 `python3 scripts/offscreen.py`（在 Spark 上）；目录表（`docs/`、`panel/`、`hook/`、`fixtures/`、`scripts/` 各一句）；指向 `docs/design.md`、`docs/dashboard-prototype.html`、`AGENTS.md`。

格式要求：命令放在 ```sh 代码块里，一条命令一个代码块；不用表情符号；不出现“待实现”“还没有实现”这类过时的话。

## 第三步：核对

```sh
cd /Users/kris/projects/tensorfold-panel
grep -c "^## " README.md
grep -n "待实现\|还没有实现\|TODO" README.md; echo "（上一行之前应没有任何输出）"
python3 - <<'EOF'
import re, dataclasses
from panel.config import Config
text = open("README.md", encoding="utf-8").read()
missing = [f.name for f in dataclasses.fields(Config) if f"`{f.name}`" not in text]
print("配置项缺失:", missing)
for path in re.findall(r"`((?:scripts|docs|panel|hook|fixtures)/[A-Za-z0-9_./-]+)`", text):
    import os
    if not os.path.exists(path.rstrip("/")):
        print("README 里提到但不存在的路径:", path)
EOF
```

通过的标准：第一条输出 `8`；第二条没有输出；第三条打印 `配置项缺失: []`，并且没有“不存在的路径”这样的行。然后最后一行输出 `DONE`。
