#!/bin/bash
# 安裝 root 輔助程式與 sudoers 免密碼規則。兩種執行方式：
#   sudo bash install-root.sh              在終端機手動執行
#   bash install-root.sh <使用者名稱>       由 SplitSwan.app 以管理員權限呼叫（沒有 SUDO_USER）
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" -eq 0 ] || { echo "請用 sudo 執行"; exit 1; }
USER_NAME="${1:-${SUDO_USER:-}}"
[ -n "$USER_NAME" ] && [ "$USER_NAME" != "root" ] || { echo "無法判斷要授權的使用者，請用 sudo 執行"; exit 1; }
[[ "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] && id -u "$USER_NAME" >/dev/null 2>&1 || { echo "使用者不存在：$USER_NAME"; exit 1; }

# 1. 輔助程式：root 擁有，一般使用者不可改
install -d -o root -g wheel -m 755 /usr/local/libexec
install -o root -g wheel -m 755 splitswan-helper /usr/local/libexec/splitswan-helper

# 2. charon log：root 擁有的目錄，App 以一般使用者直接讀取（規格 §5.3）
#    權限一律明確設定，不依賴 umask；已存在也重新修正。root 腳本不跟隨 symlink：遇到 symlink 先移除再重建
LOGDIR=/var/log/splitswan
LOGFILE="$LOGDIR/charon.log"
[ -L "$LOGDIR" ] && rm -f "$LOGDIR"
[ -e "$LOGDIR" ] && [ ! -d "$LOGDIR" ] && { echo "$LOGDIR 已存在但不是目錄，請手動處理"; exit 1; }
install -d -o root -g wheel -m 755 "$LOGDIR"
chown root:wheel "$LOGDIR"
chmod 755 "$LOGDIR"
# 目錄改成 root 擁有之前，其他人可能已放進 symlink 或 hard link（指向系統檔案）：一律移除重建
if [ -L "$LOGFILE" ] || { [ -e "$LOGFILE" ] && [ "$(stat -f %l "$LOGFILE")" != "1" ]; }; then rm -f "$LOGFILE"; fi
[ -e "$LOGFILE" ] && [ ! -f "$LOGFILE" ] && { echo "$LOGFILE 已存在但不是一般檔案，請手動處理"; exit 1; }
# 用附加方式建立：已存在時不清空（charon 可能正開著它）
( umask 022; : >> "$LOGFILE" )
chown root:wheel "$LOGFILE"
chmod 644 "$LOGFILE"

# 3. sudoers：只放行這一支程式免密碼。先用 visudo 檢查語法，通過才放進去
TMP=$(mktemp)
echo "$USER_NAME ALL=(root) NOPASSWD: /usr/local/libexec/splitswan-helper" > "$TMP"
if visudo -cf "$TMP"; then
  install -o root -g wheel -m 440 "$TMP" /etc/sudoers.d/splitswan
  rm -f "$TMP"
else
  rm -f "$TMP"; echo "sudoers 語法檢查失敗，未安裝"; exit 1
fi

echo "已安裝 /usr/local/libexec/splitswan-helper 與 /etc/sudoers.d/splitswan"
echo "驗證：sudo -n /usr/local/libexec/splitswan-helper status"
sudo -u "$USER_NAME" sudo -n /usr/local/libexec/splitswan-helper status || echo "（驗證未通過，請在 App 的環境檢查頁重新檢查）"
