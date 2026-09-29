#!/bin/bash
# 編譯 App 到 build/<APP_NAME>.app（不需要 sudo）；名稱設定在 app.env
#   bash build.sh            只編譯
#   bash build.sh --install  編譯後安裝到 /Applications（會先結束正在執行的 App）
set -euo pipefail
cd "$(dirname "$0")"
source ./app.env

VERSION="1.5.1"
BUILD_NUM="11"
APP="build/${APP_NAME}.app"
C="$APP/Contents"

# 每次從乾淨的目錄開始，避免舊檔殘留（只清 build/ 底下自己的產物）
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$C/MacOS" "$C/Resources"

echo "▸ 編譯 Swift"
swiftc -O -o "$C/MacOS/${APP_NAME}" Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Combine \
  -target arm64-apple-macos14.0

echo "▸ 產生圖示"
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
swift tools/make-icon.swift build/icon-1024.png >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"

echo "▸ 內附系統元件（由「環境檢查」頁安裝）"
install -m 755 splitswan-helper "$C/Resources/splitswan-helper"
install -m 755 install-root.sh "$C/Resources/install-root.sh"

cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUM}</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>開啟終端機顯示 VPN 連線 log</string>
    <key>NSHumanReadableCopyright</key><string>strongSwan 狀態列前端</string>
</dict>
</plist>
PLIST

echo "▸ 簽章（ad-hoc）"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

if [ "${1:-}" = "--install" ]; then
  echo "▸ 安裝到 /Applications"
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" 2>/dev/null || true
  sleep 1
  ditto "$APP" "/Applications/${APP_NAME}.app"
  echo "已安裝：/Applications/${APP_NAME}.app"
fi
echo "完成：${APP}（版本 ${VERSION}）"
