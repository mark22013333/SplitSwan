#!/usr/bin/env bash
# 產生 Windows 版 App 圖示 windows/src/SplitSwan.Tray/app.ico（只能在 macOS 執行）：
#   1. 用 Mac 版同一支 tools/make-icon.swift 畫 1024×1024 PNG（藍色漸層圓角底＋白色 lock.shield.fill），
#      跟 Mac 版根目錄 build.sh 的「產生圖示」步驟一樣
#   2. sips 縮成 16/24/32/48/64/128/256
#   3. python3 標準函式庫（struct）把 7 張 PNG 包成 ICO（Windows Vista 起支援 ICO 內嵌 PNG）
# 產物要提交進 repo（Windows 版在 macOS 上 dotnet publish，不需要每次重畫）。
# 中間檔放 windows/out/icon/（已 gitignore，windows/build.sh 每次重建 out/）。
#   bash windows/tools/make-ico.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WIN="$(dirname "$HERE")"
REPO="$(dirname "$WIN")"
WORK="$WIN/out/icon"
OUT="$WIN/src/SplitSwan.Tray/app.ico"
SIZES=(16 24 32 48 64 128 256)

command -v sips >/dev/null || { echo "錯誤：需要 macOS 的 sips" >&2; exit 1; }
command -v python3 >/dev/null || { echo "錯誤：需要 python3" >&2; exit 1; }

mkdir -p "$WORK"
swift "$REPO/tools/make-icon.swift" "$WORK/icon-1024.png" >/dev/null
for s in "${SIZES[@]}"; do
    sips -z "$s" "$s" "$WORK/icon-1024.png" --out "$WORK/icon-$s.png" >/dev/null
done

python3 - "$OUT" "$WORK" "${SIZES[@]}" <<'PY'
import struct, sys
out, work, sizes = sys.argv[1], sys.argv[2], [int(s) for s in sys.argv[3:]]
pngs = []
for s in sizes:
    data = open(f"{work}/icon-{s}.png", "rb").read()
    # PNG 簽章＋IHDR 寬高必須等於宣告的尺寸，避免 sips 輸出不如預期
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"icon-{s}.png 不是 PNG"
    w, h = struct.unpack(">II", data[16:24])
    assert (w, h) == (s, s), f"icon-{s}.png 尺寸是 {w}x{h}"
    pngs.append((s, data))
# ICONDIR：reserved=0、type=1（圖示）、張數
header = struct.pack("<HHH", 0, 1, len(pngs))
offset = 6 + 16 * len(pngs)
entries, blobs = b"", b""
for s, data in pngs:
    dim = 0 if s >= 256 else s   # 256 在 ICONDIRENTRY 以 0 表示
    entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
    blobs += data
    offset += len(data)
with open(out, "wb") as f:
    f.write(header + entries + blobs)
print(f"已寫入 {out}：{len(pngs)} 張（{', '.join(str(s) for s, _ in pngs)}），{6 + len(entries) + len(blobs)} bytes")
PY
