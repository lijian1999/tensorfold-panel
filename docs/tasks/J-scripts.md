# 任务 J：同步、外挂安装、开机启动的脚本

先读 `AGENTS.md`，再读 `docs/design.md` 的“外挂的安装、自检与降级”“部署与运行”两节。

本任务只写 shell 脚本，并且**只用“演练”方式测试**：不真的往 `~/tfpanel/` 部署、不真的装开机启动项、不碰部署仓库。真正的安装由编排者来做。

## 交付文件

1. `scripts/sync.sh`：在 MacBook Pro 上运行，把程序同步到 Spark。
2. `scripts/hook.sh`：在 MacBook Pro 上运行，安装 / 移除 / 查看外挂补丁。
3. `scripts/install-autostart.sh`：在 Spark 上运行，安装 / 移除开机启动项。

三个都是 `#!/bin/sh` 脚本（POSIX sh，不用 bash 特有语法），`chmod +x`，开头 `set -eu`，文件头用中文注释写清用途和用法。提示信息用中文。不要创建或修改别的文件。

## `scripts/sync.sh`

```sh
scripts/sync.sh            # 同步到 spark:~/tfpanel/
```

- 从脚本自己的位置找到仓库根目录（`cd "$(dirname "$0")/.."`），不依赖当前目录。
- 主机取环境变量 `TFPANEL_HOST`，默认 `spark`；目标目录取 `TFPANEL_DEST`，默认 `tfpanel`（相对路径即主目录下；也可以给绝对路径）。
- 先 `ssh "$HOST" "mkdir -p '$DEST'"`，再用 `rsync -a --delete --exclude __pycache__ --exclude '*.pyc' --exclude .DS_Store` 同步这四个目录：`panel`、`fixtures`、`scripts`、`hook`。不同步 `docs`、`.git`。仓库里不存在的目录跳过（打印一行提示）。
- 结束时打印一行：`已同步到 <主机>:<目录>`。

## `scripts/hook.sh`

```sh
scripts/hook.sh status     # 查看：补丁在不在部署仓库里、/health 里有没有 tfpanel
scripts/hook.sh install    # 把 hook/0900-tfpanel-hook.patch 拷进部署仓库的 patches/
scripts/hook.sh remove     # 从部署仓库的 patches/ 删掉它
```

- 主机取 `TFPANEL_HOST`（默认 `spark`）；部署仓库目录取 `TFPANEL_DEPLOY`，默认 `Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold`（主目录下）。补丁在部署仓库里的位置是 `<部署仓库>/patches/0900-tfpanel-hook.patch`。
- `status`（只读）：打印三行——
  - `补丁文件：已放入` / `补丁文件：未放入`；已放入时再比较它和本地 `hook/0900-tfpanel-hook.patch` 的内容是否相同（用 `cksum` 或 `sha256sum`），不同就在后面加 `（和本地的不一样）`。
  - `运行中的模型：外挂已生效` / `运行中的模型：外挂未生效` / `运行中的模型：读不到 /health`。判断方式：`ssh` 到主机上 `curl -s -m 3 http://127.0.0.1:8888/health`，结果里有 `"tfpanel"` 就是已生效。
  - 补丁文件的状态和运行中模型的状态不一致时（放入了但没生效，或没放入但还在生效）：`需要重启模型才能生效：在 Spark 上进入部署仓库执行 ./start.sh restart（重启期间模型不可用）`。一致时打印 `状态一致，不需要重启`。
- `install`：本地 `hook/0900-tfpanel-hook.patch` 不存在就报错退出。部署仓库的 `patches/` 目录不存在就报错退出。`scp` 过去，然后打印和 `status` 第三行同样的重启提示。**脚本自己不重启模型。**
- `remove`：删掉那个文件（不存在也算成功），打印重启提示。
- 没有参数或参数不认识：打印用法，以 2 退出。
- 远程命令里的路径要加引号。

## `scripts/install-autostart.sh`

在 Spark 上、从 `~/tfpanel/` 里运行：

```sh
~/tfpanel/scripts/install-autostart.sh            # 安装
~/tfpanel/scripts/install-autostart.sh --remove   # 移除
```

- 启动项目录取环境变量 `TFPANEL_AUTOSTART_DIR`，默认 `$HOME/.config/autostart`；文件名 `tfpanel.desktop`。
- 程序目录 = 脚本所在目录的上一级的绝对路径（`cd "$(dirname "$0")/.." && pwd`）。
- 安装：目录不存在就创建，写入：

```ini
[Desktop Entry]
Type=Application
Name=TFPanel 副屏仪表盘
Comment=在拓展坞副屏上显示 TensorFold 的运行状态
Exec=<程序目录>/scripts/tfpanel.sh start
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
```

  然后打印：`已安装开机启动项：<文件路径>`。再检查自动登录：`/etc/gdm3/custom.conf` 里有没有未被注释的 `AutomaticLoginEnable` 为 `true`（大小写不敏感，等号两边可能有空格）。没开时打印下面这段提示（脚本自己**不执行** `sudo`）：

```text
还需要开启自动登录（要输入管理员密码，请你自己执行）：
  sudo sed -i 's/^#\? *AutomaticLoginEnable *=.*/AutomaticLoginEnable = true/; s/^#\? *AutomaticLogin *=.*/AutomaticLogin = <当前用户名>/' /etc/gdm3/custom.conf
```

  其中 `<当前用户名>` 用 `id -un` 的结果替换。已经开了就打印 `自动登录：已开启`。读不了那个文件时打印 `自动登录：无法检查（读不了 /etc/gdm3/custom.conf）`。
- `--remove`：删掉启动项文件（不存在也算成功），打印 `已移除开机启动项`。
- `scripts/tfpanel.sh` 由别的任务写，这里只引用它的路径，不检查它是否存在。

## 测试（全部是演练，原样执行下面的命令并检查输出）

```sh
cd /Users/kris/projects/tensorfold-panel
sh -n scripts/sync.sh && sh -n scripts/hook.sh && sh -n scripts/install-autostart.sh
test -x scripts/sync.sh && test -x scripts/hook.sh && test -x scripts/install-autostart.sh

# sync：同步到临时目录
TFPANEL_DEST=/tmp/tfpanel-j scripts/sync.sh
ssh spark 'ls /tmp/tfpanel-j && ls /tmp/tfpanel-j/panel | head -20 && test ! -e /tmp/tfpanel-j/docs && echo 没有同步 docs'
# 从别的目录调用也要能用
(cd / && TFPANEL_DEST=/tmp/tfpanel-j /Users/kris/projects/tensorfold-panel/scripts/sync.sh)

# hook：status 是只读的，可以对真实部署仓库运行
scripts/hook.sh status
# install / remove 用一个假的部署仓库演练
ssh spark 'mkdir -p /tmp/tfpanel-j/fake-deploy/patches'
TFPANEL_DEPLOY=/tmp/tfpanel-j/fake-deploy scripts/hook.sh install
ssh spark 'ls -l /tmp/tfpanel-j/fake-deploy/patches/'
TFPANEL_DEPLOY=/tmp/tfpanel-j/fake-deploy scripts/hook.sh status
TFPANEL_DEPLOY=/tmp/tfpanel-j/fake-deploy scripts/hook.sh remove
ssh spark 'ls -l /tmp/tfpanel-j/fake-deploy/patches/'
TFPANEL_DEPLOY=/tmp/tfpanel-j/no-such-dir scripts/hook.sh install; echo "退出码 $?"
scripts/hook.sh; echo "退出码 $?"

# autostart：装到临时目录
ssh spark 'TFPANEL_AUTOSTART_DIR=/tmp/tfpanel-j/autostart /tmp/tfpanel-j/scripts/install-autostart.sh && cat /tmp/tfpanel-j/autostart/tfpanel.desktop && TFPANEL_AUTOSTART_DIR=/tmp/tfpanel-j/autostart /tmp/tfpanel-j/scripts/install-autostart.sh --remove && ls /tmp/tfpanel-j/autostart'

ssh spark 'rm -rf /tmp/tfpanel-j'
```

要求：

- `hook/0900-tfpanel-hook.patch` 如果这时还不存在（别的任务还在写），`hook.sh install` 的演练那几条可以先在 `hook/` 下放一个临时的假补丁文件来测，测完删掉；最终不要留下假文件。
- `scripts/hook.sh status` 对真实环境的输出现在应该是：`补丁文件：未放入`、`运行中的模型：外挂未生效`、`状态一致，不需要重启`。
- 假部署仓库演练：`install` 后文件在、`status` 显示“已放入”并提示需要重启；`remove` 后目录为空；目录不存在时 `install` 退出码非 0；无参数时退出码 2。
- `tfpanel.desktop` 的 `Exec=` 是 `/tmp/tfpanel-j/scripts/tfpanel.sh start`；现在 Spark 没开自动登录，所以应打印那段 `sudo sed` 提示，用户名是 `kris`。
- **绝对不要**对真实部署仓库运行 `hook.sh install` 或 `remove`；不要运行那条 `sudo` 命令；不要往 `~/.config/autostart` 或 `~/tfpanel` 写东西。
