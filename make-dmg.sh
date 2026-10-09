#!/bin/bash
# 打包安裝檔 dist/<APP_NAME>-<版本>.dmg：打開後把 App 拖進「應用程式」即可
# 同時完成發版流程的本機步驟：檢查版號、跑測試、產生 .sha256 與 .sig（push、tag、gh release 仍需手動）
#   bash make-dmg.sh                完整流程
#   bash make-dmg.sh --skip-tests   略過單元測試（剛跑過全綠時用）
#   bash make-dmg.sh --no-sign      不產生 .sig（自己測試用的 dmg，不要拿去發版）
set -euo pipefail
cd "$(dirname "$0")"
source ./app.env

SKIP_TESTS=0; NO_SIGN=0
for a in "$@"; do
  case $a in
    --skip-tests) SKIP_TESTS=1 ;;
    --no-sign)    NO_SIGN=1 ;;
    *) echo "未知的參數：${a}（可用：--skip-tests、--no-sign）" >&2; exit 2 ;;
  esac
done

echo "▸ 檢查版號"
bash tools/check-version.sh

if [ "$SKIP_TESTS" = 1 ]; then
  echo "⚠️ 依 --skip-tests 略過單元測試"
else
  echo "▸ 單元測試"
  bash Tests/run-tests.sh
fi

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

# .sha256 只寫檔名、不含路徑，使用者下載後在同一目錄執行 shasum -c 才對得上
DMG_NAME=$(basename "$DMG")
(cd dist && shasum -a 256 "$DMG_NAME" > "${DMG_NAME}.sha256" && shasum -a 256 -c "${DMG_NAME}.sha256" >/dev/null)
echo "✅ 已產生並核對：dist/${DMG_NAME}.sha256"

# 私鑰內容只由 release-sign.swift 讀取，本腳本只檢查檔案在不在，不讀也不印
SIGN_KEY="$HOME/.config/splitswan-release/update-ed25519.key"
if [ "$NO_SIGN" = 1 ]; then
  echo "⚠️ 依 --no-sign 沒有產生 .sig：這個 dmg 不能拿去發版（App 的「下載並安裝」會拒絕）" >&2
elif [ -f "$SIGN_KEY" ]; then
  swift tools/release-sign.swift sign "$DMG"
  swift tools/release-sign.swift verify "$DMG"
  echo "✅ 已產生並驗證：${DMG}.sig"
else
  echo "⚠️ 警告：找不到 ${SIGN_KEY}，沒有產生 ${DMG_NAME}.sig；沒有 .sig 的版本，App 的「下載並安裝」會拒絕安裝" >&2
fi

echo "下一步（手動）：commit、push → annotated tag v${VERSION} 並 push → gh release create 附 dmg、.sha256、.sig → 下載回來驗證"
