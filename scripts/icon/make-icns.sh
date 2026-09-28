#!/usr/bin/env bash
# 把 icon.html 导出的 out/icon_*.png 组装成 display/Resources/AppIcon.icns（系统自带 iconutil）。
set -euo pipefail
cd "$(dirname "$0")/out"
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  cp "icon_$s.png" "AppIcon.iconset/icon_${s}x${s}.png"
  cp "icon_$((s * 2)).png" "AppIcon.iconset/icon_${s}x${s}@2x.png"
done
DEST="../../../display/Resources"
mkdir -p "$DEST"
iconutil -c icns AppIcon.iconset -o "$DEST/AppIcon.icns"
echo "已生成：$(cd "$DEST" && pwd)/AppIcon.icns"
