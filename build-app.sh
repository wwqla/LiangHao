#!/bin/bash
# 打包成 靓号助手.app（需要 Xcode 或 Command Line Tools，macOS 14+）
set -e
cd "$(dirname "$0")"
# 同时编译 Apple 芯片和 Intel（通用二进制）；失败就只编本机架构
if swift build -c release --arch arm64 --arch x86_64; then
  BIN=.build/apple/Products/Release/LiangHao
else
  swift build -c release
  BIN=.build/release/LiangHao
fi
APP="靓号助手.app"
VERSION="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo dev)}"
VERSION="${VERSION:0:7}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiangHao"

# 应用图标：Resources/AppIcon.png → AppIcon.icns
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>靓号助手</string>
  <key>CFBundleDisplayName</key><string>靓号助手</string>
  <key>CFBundleIdentifier</key><string>com.keovi.lianghao</string>
  <key>CFBundleExecutable</key><string>LiangHao</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "完成：$(pwd)/$APP"
echo "首次打开如果提示无法验证开发者：右键 → 打开。"
