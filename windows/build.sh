#!/usr/bin/env bash
# SplitSwan Windows 版打包（可在 macOS 執行）：
#   1. 跑 Core 單元測試
#   2. dotnet publish 托盤 App（win-x64、自含、單一 exe）
#   3. 附上連線引擎 engine\splitswan-wsl.ps1／.sh（原樣複製，保留 BOM＋CRLF 與 LF）與 README
#   4. 打包成 <repo>/dist/SplitSwan-Windows-<版本>.zip
# 中間產物在 windows/out/（已 gitignore），每次重建。
set -euo pipefail

# 以本腳本所在的 windows/ 為工作目錄，下面的路徑都是固定的相對路徑
cd "$(dirname "$0")"

VERSION=0.1.0
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
# 打包進去的引擎要是支援 -Order 的版本（避免複製到舊檔）
grep -q '\[string\]\$Order' "$ps1" || { echo "錯誤：$ps1 沒有 -Order 參數" >&2; exit 1; }
grep -q '@@ATTEMPT=' "$sh" || { echo "錯誤：$sh 沒有輸出 @@ATTEMPT" >&2; exit 1; }

echo "== 4/4 打包"
ZIP="${NAME}-Windows-${VERSION}.zip"
# 先在 out/ 裡壓縮（out/ 每次都是新的，不會混到舊內容），再複製到 dist/
(cd ./out/publish && zip -q -X -r "../${ZIP}" SplitSwan)
mkdir -p ../dist
cp "./out/${ZIP}" "../dist/${ZIP}"

echo
echo "完成：dist/${ZIP}"
unzip -l "../dist/${ZIP}"
# 從 zip 本身再驗一次：裡面的引擎支援 -Order
# （先存變數再比對：pipefail 下 grep -q 提早結束會讓 unzip 收到 SIGPIPE 而誤判失敗）
zipped_ps1=$(unzip -p "../dist/${ZIP}" SplitSwan/engine/splitswan-wsl.ps1)
grep -q '\[string\]\$Order' <<<"$zipped_ps1" \
    || { echo "錯誤：zip 內的 splitswan-wsl.ps1 沒有 -Order 參數" >&2; exit 1; }
echo "zip 內引擎支援 -Order：通過"
