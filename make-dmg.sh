#!/bin/bash
# 打包安裝檔 dist/<APP_NAME>-<版本>.dmg：打開後把 App 拖進「應用程式」即可
set -euo pipefail
cd "$(dirname "$0")"
source ./app.env

bash build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/${APP_NAME}.app/Contents/Info.plist)
DMG="dist/${APP_NAME}-${VERSION}.dmg"

STAGE=$(mktemp -d)
trap 'command rm -r "$STAGE"' EXIT   # 不論成功失敗都清掉暫存目錄（裡面的 應用程式 是 symlink，不會跟進去）
ditto "build/${APP_NAME}.app" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/應用程式"
cat > "$STAGE/請先讀我.txt" <<TXT
${APP_NAME} 安裝方式

1. 把 ${APP_NAME} 拖到右邊的「應用程式」資料夾
2. 到「應用程式」點兩下 ${APP_NAME}
3. 第一次開啟會跳出視窗，照「環境檢查」頁的紅燈逐項按「安裝」
   （安裝系統元件時會跳出 macOS 管理員密碼視窗）
4. 到「設定」頁按「匯入公司設定檔…」，選取管理者提供的 company.env
5. 填帳號、密碼、預設共享金鑰（PSK 請向管理者索取），按「儲存」
6. 回「連線」頁按「連線」

連線前請先在 FortiClient 斷線，兩個同時連會衝突。
某台主機連不上時，請看 README「某台主機連不上怎麼辦」。
TXT

mkdir -p dist
hdiutil create -volname "${APP_NAME} ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null

if hdiutil verify "$DMG" >/dev/null; then
  echo "✅ 已產生並驗證：${DMG}（$(du -h "$DMG" | cut -f1)）"
else
  echo "❌ $DMG 驗證失敗" >&2; exit 1
fi
