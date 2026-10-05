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
   第一次會出現「Apple 無法驗證是否為惡意軟體」：先按「完成」，到「系統設定 →
   隱私權與安全性」往下捲，找到 ${APP_NAME} 按「仍要打開」（只有第一次需要）
3. 第一次開啟會跳出視窗，照「環境檢查」頁的紅燈逐項按「安裝」
   （安裝系統元件時會跳出 macOS 管理員密碼視窗）
4. 到「設定」頁按「匯入設定檔…」，選取管理者提供的 .splitswan 檔並輸入匯入密碼
   （閘道、網段與預設共享金鑰會自動帶入；請核對閘道位址後再按「套用」）
5. 填入你自己的帳號、密碼，按「儲存」
6. 回「連線」頁按「連線（自動輪替）」

從舊版更新：1.7.0 以後在「關於」頁按「下載並安裝」即可；更舊的版本請把新版拖進
「應用程式」取代舊版。如果「環境檢查」頁的系統元件顯示「需要更新」，按「更新」並輸入管理員密碼。

連線前請先在 FortiClient 斷線，兩個同時連會衝突。
連不上時，到「環境檢查」頁按「產生診斷報告」，把桌面上的報告檔傳給管理者。
某台主機連不上時，請看 README「某台主機連不上怎麼辦」。
TXT

mkdir -p dist
hdiutil create -volname "${APP_NAME} ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null

if hdiutil verify "$DMG" >/dev/null; then
  echo "✅ 已產生並驗證：${DMG}（$(du -h "$DMG" | cut -f1)）"
else
  echo "❌ $DMG 驗證失敗" >&2; exit 1
fi
