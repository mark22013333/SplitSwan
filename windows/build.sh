#!/usr/bin/env bash
# SplitSwan Windows 版打包（可在 macOS 執行）：
#   1. 跑 Core 單元測試
#   2. dotnet publish 托盤 App（win-x64、自含、單一 exe）
#   3. 附上連線引擎 engine\splitswan-wsl.ps1／.sh（原樣複製，保留 BOM＋CRLF 與 LF）與 README
#   4. 打包成 <repo>/dist/SplitSwan-Windows-<版本>.zip，有發版私鑰時另產生 .zip.sig（一鍵更新用）
# 中間產物在 windows/out/（已 gitignore），每次重建。
set -euo pipefail

# 以本腳本所在的 windows/ 為工作目錄，下面的路徑都是固定的相對路徑
cd "$(dirname "$0")"

VERSION=0.1.1
NAME=SplitSwan

# 版本號要跟 csproj 一致（App 的「關於」與檔案內容都讀 csproj）
if ! grep -q "<Version>${VERSION}</Version>" src/SplitSwan.Tray/SplitSwan.Tray.csproj; then
    echo "錯誤：build.sh 的 VERSION=${VERSION} 與 src/SplitSwan.Tray/SplitSwan.Tray.csproj 的 <Version> 不一致" >&2
    exit 1
fi
for f in ../tools/windows/splitswan-wsl.ps1 ../tools/windows/splitswan-wsl.sh README.md; do
    [ -s "$f" ] || { echo "錯誤：找不到 $f" >&2; exit 1; }
done

# 托盤的背景 connect 一律帶 -NoInstall（契約 1）；引擎不支援時每次連線都會失敗，不可打包
if ! grep -q '\[switch\]\$NoInstall' ../tools/windows/splitswan-wsl.ps1; then
    echo "錯誤：tools/windows/splitswan-wsl.ps1 沒有 -NoInstall 參數，與托盤 App 不相容" >&2
    exit 1
fi

# 托盤的 connect 一律帶 -Order 並讀逐台的 @@ATTEMPT（契約 3）；引擎不支援時每次連線都會失敗，不可打包
if ! grep -q '\[string\]\$Order' ../tools/windows/splitswan-wsl.ps1 || ! grep -q '@@ATTEMPT=' ../tools/windows/splitswan-wsl.sh; then
    echo "錯誤：tools/windows 的引擎不支援 -Order／@@ATTEMPT，與托盤 App 不相容" >&2
    exit 1
fi

# 首次設定精靈跑 -Action setup，所有引擎呼叫都帶 -Distro（契約 5、6）；引擎不支援時精靈與連線都會失敗，不可打包
if ! grep -q "ValidateSet('connect', 'disconnect', 'status', 'brief', 'setup')" ../tools/windows/splitswan-wsl.ps1 \
   || ! grep -q '\[string\]\$Distro' ../tools/windows/splitswan-wsl.ps1; then
    echo "錯誤：tools/windows/splitswan-wsl.ps1 不支援 -Action setup 或 -Distro，與托盤 App 不相容" >&2
    exit 1
fi

# exe 圖示（與 Mac 版同圖）：csproj 要設 ApplicationIcon，app.ico 要存在且是 7 張的 ICO（由 tools/make-ico.sh 產生）
ICO=src/SplitSwan.Tray/app.ico
grep -q '<ApplicationIcon>app.ico</ApplicationIcon>' src/SplitSwan.Tray/SplitSwan.Tray.csproj \
    || { echo "錯誤：SplitSwan.Tray.csproj 沒有設定 <ApplicationIcon>app.ico</ApplicationIcon>" >&2; exit 1; }
[ -f "$ICO" ] || { echo "錯誤：找不到 $ICO，請先執行 bash windows/tools/make-ico.sh" >&2; exit 1; }
ico_size=$(wc -c < "$ICO" | tr -d ' ')
ico_head=$(head -c 6 "$ICO" | od -An -tx1 | tr -d ' \n')
# ICONDIR：reserved 0000、type 0100（圖示）、張數 0700（7 張，little-endian）
if [ "$ico_head" != "000001000700" ] || [ "$ico_size" -lt 4096 ] || [ "$ico_size" -gt 1048576 ]; then
    echo "錯誤：$ICO 格式或大小不對（開頭 $ico_head、$ico_size bytes；應為 7 張、4 KB～1 MB）" >&2
    exit 1
fi

echo "== 1/4 Core 單元測試"
dotnet test tests/SplitSwan.Core.Tests/SplitSwan.Core.Tests.csproj -c Release --nologo

echo "== 2/4 發佈托盤 App（win-x64 自含單一 exe）"
# 只清 windows/out（固定路徑）
rm -rf ./out
mkdir -p ./out/publish/SplitSwan/engine
dotnet publish src/SplitSwan.Tray/SplitSwan.Tray.csproj -c Release -r win-x64 --self-contained --nologo \
    -p:PublishSingleFile=true \
    -p:EnableCompressionInSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:DebugType=none \
    -o ./out/publish/SplitSwan

echo "== 3/4 附上連線引擎與說明"
cp ../tools/windows/splitswan-wsl.ps1 ../tools/windows/splitswan-wsl.sh ./out/publish/SplitSwan/engine/
cp README.md ./out/publish/SplitSwan/README.md

# 編碼檢查：ps1 必須是 UTF-8 BOM＋CRLF（Windows PowerShell 5.1 沒有 BOM 會把中文當 ANSI 讀）；sh 必須是 LF
ps1=./out/publish/SplitSwan/engine/splitswan-wsl.ps1
sh=./out/publish/SplitSwan/engine/splitswan-wsl.sh
if [ "$(head -c 3 "$ps1" | od -An -tx1 | tr -d ' \n')" != "efbbbf" ]; then
    echo "錯誤：$ps1 開頭沒有 UTF-8 BOM" >&2; exit 1
fi
if [ "$(tr -cd '\r' < "$ps1" | wc -c | tr -d ' ')" -eq 0 ]; then
    echo "錯誤：$ps1 不是 CRLF" >&2; exit 1
fi
if [ "$(tr -cd '\r' < "$sh" | wc -c | tr -d ' ')" -ne 0 ]; then
    echo "錯誤：$sh 含 CR（必須是 LF）" >&2; exit 1
fi
[ -f ./out/publish/SplitSwan/${NAME}.exe ] || { echo "錯誤：沒有產生 ${NAME}.exe" >&2; exit 1; }
# exe 的 PE 資源段要有 App 圖示，且逐張與 app.ico 相同
python3 tools/check-exe-icon.py ./out/publish/SplitSwan/${NAME}.exe "$ICO" \
    || { echo "錯誤：${NAME}.exe 沒有帶 App 圖示" >&2; exit 1; }
# 打包進去的引擎要是支援 -Order 的版本（避免複製到舊檔）
grep -q '\[string\]\$Order' "$ps1" || { echo "錯誤：$ps1 沒有 -Order 參數" >&2; exit 1; }
grep -q '@@ATTEMPT=' "$sh" || { echo "錯誤：$sh 沒有輸出 @@ATTEMPT" >&2; exit 1; }

echo "== 4/4 打包"
ZIP="${NAME}-Windows-${VERSION}.zip"
# 先在 out/ 裡壓縮（out/ 每次都是新的，不會混到舊內容），再複製到 dist/
(cd ./out/publish && zip -q -X -r "../${ZIP}" SplitSwan)
mkdir -p ../dist
cp "./out/${ZIP}" "../dist/${ZIP}"

# 一鍵更新的 Ed25519 簽章（與 Mac 版共用金鑰與工具）：有私鑰才簽，沒有只警告（開發機照樣能打包）。
# 私鑰內容只由 release-sign.swift 讀取，本腳本不讀也不印
SIGN_KEY="$HOME/.config/splitswan-release/update-ed25519.key"
if [ -f "$SIGN_KEY" ]; then
    echo "== 簽署 ${ZIP}"
    swift ../tools/release-sign.swift sign "../dist/${ZIP}"
    swift ../tools/release-sign.swift verify "../dist/${ZIP}"
else
    echo "警告：找不到 $SIGN_KEY，沒有產生 ${ZIP}.sig；沒有 .sig 的版本，App 的「下載並安裝」會拒絕安裝" >&2
fi

echo
echo "完成：dist/${ZIP}"
unzip -l "../dist/${ZIP}"
# 從 zip 本身再驗一次：裡面的引擎支援 -Order
# （先存變數再比對：pipefail 下 grep -q 提早結束會讓 unzip 收到 SIGPIPE 而誤判失敗）
zipped_ps1=$(unzip -p "../dist/${ZIP}" SplitSwan/engine/splitswan-wsl.ps1)
grep -q '\[string\]\$Order' <<<"$zipped_ps1" \
    || { echo "錯誤：zip 內的 splitswan-wsl.ps1 沒有 -Order 參數" >&2; exit 1; }
echo "zip 內引擎支援 -Order：通過"
