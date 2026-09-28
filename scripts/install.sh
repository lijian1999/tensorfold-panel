#!/usr/bin/env bash
# 一次性安装：打包显示程序、装到 ~/Applications、在 ~/.local/bin 建 tfpanel 命令。
# 可重复运行（幂等）。不会启动或停止 TensorFold，也不会自动打开 TFPanel.app。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "1/5 打包显示程序（TFPanel.app）…"
"$ROOT/scripts/build-app.sh"

echo "2/5 安装 TFPanel.app 到 ~/Applications …"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/TFPanel.app"
cp -R "$ROOT/display/dist/TFPanel.app" "$HOME/Applications/TFPanel.app"

echo "3/5 创建 tfpanel 命令（~/.local/bin，指向仓库里的 collector/tfpanel）…"
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/collector/tfpanel" "$HOME/.local/bin/tfpanel"

echo "4/5 检查 tensorfold 命令…"
if command -v tensorfold >/dev/null 2>&1; then
  echo "  已找到：$(command -v tensorfold)"
else
  echo "  警告：找不到 tensorfold 命令，请先安装 TensorFold 或把它加入 PATH（不影响安装，tfpanel 启动时才会再检查）。"
fi

echo "5/5 安装完成。下一步："
echo "  - 以后用 tfpanel serve <模型> 代替 tensorfold serve <模型>，参数完全相同，"
echo "    例如：tfpanel serve Vontra/Qwen3.8-27B-MLX-4bit"
echo "  - 打开 ~/Applications/TFPanel.app（启动台或访达），在菜单栏图标里可勾选“登录时启动”。"
echo "  - 注意：~/.local/bin 需要在你的 PATH 里，如果 tfpanel 命令找不到，检查 shell 配置。"
