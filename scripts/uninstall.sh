#!/usr/bin/env bash
# 卸载：删除 ~/Applications/TFPanel.app 和 ~/.local/bin/tfpanel（只删指向本仓库的符号链接）。
# 可重复运行（幂等）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "提示：如果勾选过“登录时启动”，请先打开 TFPanel 的菜单栏图标（gauge 图标）取消勾选，再运行本脚本。"

echo "删除 ~/Applications/TFPanel.app …"
rm -rf "$HOME/Applications/TFPanel.app"

LINK="$HOME/.local/bin/tfpanel"
if [ -L "$LINK" ]; then
  TARGET="$(readlink -f "$LINK" 2>/dev/null || true)"
  if [ "$TARGET" = "$ROOT/collector/tfpanel" ]; then
    rm -f "$LINK"
    echo "已删除 $LINK"
  else
    echo "跳过 $LINK：它指向 $TARGET，不是本仓库，不动它。"
  fi
elif [ -e "$LINK" ]; then
  echo "跳过 $LINK：它不是符号链接，不敢删，请手动检查。"
else
  echo "$LINK 不存在，跳过。"
fi

echo "卸载完成。"
