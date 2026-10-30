#!/bin/bash
# 一条命令打包：release 构建并生成 mac/dist/TFPanel.app（图标、Info.plist、ad-hoc 签名）。
set -euo pipefail

# 切到 mac/（脚本所在目录的上一级），可以在任何目录下运行
cd "$(dirname "$0")/.."

swift build -c release --product TFPanel

APP="dist/TFPanel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TFPanel "$APP/Contents/MacOS/TFPanel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "已生成 $PWD/dist/TFPanel.app"
