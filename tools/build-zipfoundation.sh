#!/bin/bash
set -euo pipefail
# 固定且內附的來源；建置不連網。呼叫端指定自己的輸出目錄，避免測試互相覆寫。
ZIP_OUT=$1
mkdir -p "$ZIP_OUT"
swiftc -module-cache-path "$ZIP_OUT/cache" -O -parse-as-library -emit-library -static -emit-module -module-name ZIPFoundation \
  Vendor/ZIPFoundation/Sources/*.swift -o "$ZIP_OUT/libZIPFoundation.a" \
  -emit-module-path "$ZIP_OUT/ZIPFoundation.swiftmodule" -target arm64-apple-macos14.0
