#!/usr/bin/env bash
# 打包 display/dist/TFPanel.app（release 构建 + Info.plist + ad-hoc 签名），可重复运行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/display"

swift build -c release

rm -rf dist/TFPanel.app
mkdir -p dist/TFPanel.app/Contents/MacOS dist/TFPanel.app/Contents/Resources
cp .build/release/TFPanel dist/TFPanel.app/Contents/MacOS/TFPanel
# 图标源码见 scripts/icon/，改图后运行 scripts/icon/make-icns.sh 重新生成
cp Resources/AppIcon.icns dist/TFPanel.app/Contents/Resources/AppIcon.icns

cat > dist/TFPanel.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.tensorfold.panel</string>
	<key>CFBundleName</key>
	<string>TFPanel</string>
	<key>CFBundleDisplayName</key>
	<string>TensorFold 副屏</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleExecutable</key>
	<string>TFPanel</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

codesign --force --sign - dist/TFPanel.app

echo "打包完成：$ROOT/display/dist/TFPanel.app"
