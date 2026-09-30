#!/bin/bash
# 輔助程式 logtrim 的副本測試（規格 §5.3）：一般使用者權限即可，不需要 sudo。
#   bash tools/test-logtrim.sh
# 把 splitswan-helper 複製一份，log 路徑換成 mktemp 暫存目錄、拿掉 chown root:wheel，
# 驗證：就地截斷成約 1 MB、inode 不變、沒有空洞、小檔不動、拒絕 symlink／hard link／參數、不留暫存檔。
# 全部只在暫存目錄內操作，結束時清掉；設 KEEP_TMP=1 可保留暫存目錄方便檢查。
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/splitswan-helper"
[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 1; }
RUN=$(mktemp -d "${TMPDIR:-/tmp}/splitswan-logtrim.XXXXXX") || exit 1
if [ "${KEEP_TMP:-0}" = 1 ]; then echo "暫存目錄保留在 $RUN"; else trap 'command rm -r "$RUN"' EXIT; fi

pass=0; fail=0
check() { if [ "$2" = 0 ]; then echo "✅ $1"; pass=$((pass+1)); else echo "❌ $1"; fail=$((fail+1)); fi; }
mk() {  # 情境名 → 產生指向 $RUN/<名>/logdir 的 helper 副本，印出情境目錄
  local d="$RUN/$1"; mkdir -p "$d"
  sed -e "s#^LOGDIR=/var/log/splitswan#LOGDIR=$d/logdir#" \
      -e 's/chown root:wheel "\$LOGDIR" && //' -e 's/chown root:wheel "\$LOGFILE" && //' \
      -e 's/install -d -o root -g wheel -m 755/install -d -m 755/' "$SRC" >"$d/helper"
  # 正對照：確認路徑真的換掉了，否則會動到系統的 /var/log
  grep -q "^LOGDIR=$d/logdir\$" "$d/helper" || { echo "副本路徑替換失敗"; exit 1; }
  echo "$d"
}
fill() {  # 檔案 bytes：用編號行灌到指定大小
  LC_ALL=C awk -v n="$2" 'BEGIN{i=0; t=0; while (t < n) { s=sprintf("line %08d charon test data abcdefghijklmnopqrstuvwxyz\n", i++); printf "%s", s; t += length(s) } }' >>"$1"
}

# 1. 目錄與檔案都不存在 → 建立
d=$(mk create); out=$(bash "$d/helper" logtrim); rc=$?
[ "$rc" = 0 ] && [ -d "$d/logdir" ] && [ -f "$d/logdir/charon.log" ]; check "不存在時建立目錄與檔案（${out}）" $?
[ "$(stat -f %Lp "$d/logdir/charon.log")" = 644 ] && [ "$(stat -f %Lp "$d/logdir")" = 755 ]; check "權限 644／755" $?

# 2. 灌到 2.5 MB，模擬 charon 以 O_APPEND 開著檔案，截斷後再寫一行
d=$(mk big); mkdir -p "$d/logdir"; F="$d/logdir/charon.log"
fill "$F" $((2500 * 1024))
before=$(stat -f %z "$F"); ino1=$(stat -f %i "$F")
( exec 3>>"$F"; sleep 2; echo "AFTER-TRIM" >&3 ) &
apid=$!
sleep 0.5
bash "$d/helper" logtrim >/dev/null; rc=$?
wait "$apid"
after=$(stat -f %z "$F"); ino2=$(stat -f %i "$F")
real=$(wc -c <"$F" | tr -d ' ')
nul=$(LC_ALL=C tr -cd '\000' <"$F" | wc -c | tr -d ' ')
echo "  截斷前 ${before} bytes → 截斷後 ${after} bytes；inode ${ino1} → ${ino2}；wc -c=${real}；NUL=${nul}"
[ "$rc" = 0 ]; check "logtrim 回傳 0" $?
[ "$after" -gt $((1000 * 1024)) ] && [ "$after" -le $((1024 * 1024 + 100)) ]; check "截成約 1 MB" $?
[ "$ino1" = "$ino2" ]; check "inode 不變" $?
[ "$real" = "$after" ] && [ "$nul" = 0 ]; check "沒有空洞（大小與內容一致、無 NUL）" $?
[ "$(tail -1 "$F")" = "AFTER-TRIM" ]; check "截斷後 O_APPEND 的寫入接在檔尾" $?
head -1 "$F" | grep -qE '^line [0-9]{8} '; check "第一行是完整的一行" $?
[ -z "$(find "$d/logdir" -name '.trim.*')" ]; check "沒有留下 .trim.* 暫存檔" $?

# 3. 未達 2 MB 門檻不動
for kb in 500 1500; do
  d=$(mk "small$kb"); mkdir -p "$d/logdir"; F="$d/logdir/charon.log"
  fill "$F" $((kb * 1024)); m1=$(md5 -q "$F")
  bash "$d/helper" logtrim >/dev/null
  [ "$m1" = "$(md5 -q "$F")" ]; check "${kb} KB 內容不變" $?
done

# 4. log 檔是 symlink → 拒絕，目標不受影響
d=$(mk symfile); mkdir -p "$d/logdir"; T="$d/target.txt"
fill "$T" $((2500 * 1024)); m1=$(md5 -q "$T"); chmod 600 "$T"
ln -s "$T" "$d/logdir/charon.log"
bash "$d/helper" logtrim >/dev/null; rc=$?
[ "$rc" != 0 ] && [ "$(md5 -q "$T")" = "$m1" ] && [ "$(stat -f %Lp "$T")" = 600 ]; check "log 檔為 symlink → 拒絕，目標內容與權限不變" $?

# 5. log 目錄是 symlink → 拒絕
d=$(mk symdir); mkdir -p "$d/realdir"; ln -s "$d/realdir" "$d/logdir"
bash "$d/helper" logtrim >/dev/null; rc=$?
[ "$rc" != 0 ] && [ ! -e "$d/realdir/charon.log" ]; check "log 目錄為 symlink → 拒絕、沒有建檔" $?

# 6. hard link → 拒絕
d=$(mk hard); mkdir -p "$d/logdir"; T="$d/other.txt"
fill "$T" $((2500 * 1024)); m1=$(md5 -q "$T")
ln "$T" "$d/logdir/charon.log"
bash "$d/helper" logtrim >/dev/null; rc=$?
[ "$rc" != 0 ] && [ "$(md5 -q "$T")" = "$m1" ]; check "log 檔有多個 hard link → 拒絕，內容不變" $?

# 7. 參數與白名單
d=$(mk args); bash "$d/helper" logtrim /etc/passwd >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -e "$d/logdir" ]; check "logtrim 帶參數 → exit 2、不動作" $?
bash "$d/helper" bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ]; check "未知子命令仍拒絕" $?

echo "通過 ${pass}，失敗 ${fail}"
[ "$fail" = 0 ]
