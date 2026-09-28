# 任务 C：安装脚本 + README

先读 `AGENTS.md`、`docs/design.md`「更新与维护」「显示程序行为」，以及 `collector/tfpanel`、`scripts/build-app.sh` 的现状。不要改 `collector/`、`display/` 下的任何代码。

## 1. scripts/install.sh

`set -euo pipefail`，可重复运行（幂等），每一步打印一行中文说明：

1. 运行 `scripts/build-app.sh` 打包。
2. 把 `display/dist/TFPanel.app` 复制到 `~/Applications/TFPanel.app`（先删旧的；`~/Applications` 不存在就创建）。
3. 在 `~/.local/bin/tfpanel` 建指向仓库里 `collector/tfpanel` 的符号链接（已存在则替换；`~/.local/bin` 不存在就创建）。
4. 检查 `command -v tensorfold` 存在，不存在只警告不失败。
5. 最后打印“下一步”：
   - 以后用 `tfpanel serve <模型>` 代替 `tensorfold serve <模型>`（参数完全相同）；
   - 打开 `~/Applications/TFPanel.app`，在菜单栏图标里可勾选“登录时启动”。

不要在脚本里启动或停止 TensorFold，也不要自动打开 TFPanel.app。

## 2. scripts/uninstall.sh

删除 `~/Applications/TFPanel.app` 和 `~/.local/bin/tfpanel`（只删指向本仓库的符号链接），提示如果勾选过“登录时启动”，请先在菜单里取消。幂等。

## 3. README.md（仓库根目录，中文）

简洁，面向本机使用者。章节：
1. **这是什么**：一两句话 + 指向 `docs/design.md`、`docs/dashboard-prototype.html`。
2. **安装**：`sh scripts/install.sh`。
3. **日常使用**：`tfpanel serve Vontra/Qwen3.8-27B-MLX-4bit`；副屏程序自动找名为 `TYPE-C` 的屏幕；菜单栏选项说明（自动切换 960×640、登录时启动、退出）。
4. **/metrics 接口**：`curl http://127.0.0.1:8081/metrics`，端口可用 `TFPANEL_METRICS_PORT` 修改；字段说明指向 design.md。
5. **副屏上各状态的含义**：一张表（引擎离线 / 启动中 / 指标不可用 / 空闲 / 预填充中 / 解码中 / 完成）。
6. **TensorFold 更新后**：照抄 design.md「实际维护是什么样」的要点；说明 `TFPANEL_FORCE_HOOK_FAIL=1` 可以模拟自检失败。
7. **开发**：`cd collector && ~/.local/share/uv/tools/tensorfold/bin/python -m unittest discover -s tests`；`cd display && swift test`；`.build/debug/TFPanel --snapshot-all <目录>` 离屏截图；`--metrics-url`、`--screen` 调试参数。
8. **卸载**：`sh scripts/uninstall.sh`。

所有命令、路径、参数必须和仓库里的实际实现一致（逐一去代码里核对，不要凭印象写）。

## 完成前必须运行

```sh
sh -n scripts/install.sh && sh -n scripts/uninstall.sh
bash -n scripts/install.sh && bash -n scripts/uninstall.sh
```
**不要**真的运行 install.sh / uninstall.sh（编排者会运行）。最后一行输出 DONE。
