#!/bin/bash
# 發版前檢查：build.sh 的 VERSION 與 README.md「版本：」那一行必須一致。
#   bash tools/check-version.sh          檢查本 repo
#   bash tools/check-version.sh <目錄>   檢查其他目錄（裡面要有 build.sh 與 README.md，測試用）
# 一致時印出版本號、退出碼 0；不一致或找不到時退出碼 1。
set -uo pipefail
DIR=${1:-"$(cd "$(dirname "$0")/.." && pwd)"}

BUILD_VER=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$DIR/build.sh")
# README 的版本行長這樣：「> 版本：1.7.0」。用內容找行，不寫死行號
README_LINES=$(grep -E '^(>[[:space:]]*)?版本：' "$DIR/README.md")
COUNT=$(printf '%s' "$README_LINES" | grep -c '版本：')

if [ -z "$BUILD_VER" ] || [ "$(printf '%s\n' "$BUILD_VER" | wc -l | tr -d ' ')" != 1 ]; then
  echo "❌ 在 $DIR/build.sh 找不到唯一一行 VERSION=\"…\"" >&2; exit 1
fi
if [ "$COUNT" != 1 ]; then
  echo "❌ $DIR/README.md 應該剛好有一行「版本：」，實際找到 ${COUNT} 行" >&2; exit 1
fi
README_VER=$(printf '%s\n' "$README_LINES" | sed 's/.*版本：[[:space:]]*//; s/[[:space:]]*$//')

if [ "$BUILD_VER" != "$README_VER" ]; then
  echo "❌ 版本不一致：build.sh 是 ${BUILD_VER}，README.md 是 ${README_VER}" >&2; exit 1
fi
echo "✅ 版本一致：${BUILD_VER}"
