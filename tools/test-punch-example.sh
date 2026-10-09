#!/bin/bash
# 打卡提醒範例外掛（config/plugins/punch-reminder.1m.sh.example）的測試：不需要 App、不連網路。
#   bash tools/test-punch-example.sh
# 每個情境用獨立的暫存 state 目錄，並以 NOW／TODAY／DOW 覆寫時間。
# 只在 mktemp 暫存目錄內操作，結束時清掉；設 KEEP_TMP=1 可保留暫存目錄方便檢查。
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/config/plugins/punch-reminder.1m.sh.example"
[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 1; }
RUN=$(mktemp -d "${TMPDIR:-/tmp}/splitswan-punch.XXXXXX") || exit 1
if [ "${KEEP_TMP:-0}" = 1 ]; then echo "暫存目錄保留在 $RUN"; else trap 'command rm -r "$RUN"' EXIT; fi

pass=0; fail=0
check() { if [ "$2" = 0 ]; then echo "✅ $1"; pass=$((pass+1)); else echo "❌ $1"; fail=$((fail+1)); fi; }
has() { grep -qF -- "$2" <<<"$1"; }          # 輸出 $1 含有 $2
st() { echo "$RUN/$1"; }                       # 情境名 → state 目錄
p() {  # state目錄 NOW [參數…]：平日 2026-10-09（週五）執行範例
  local s=$1 now=$2; shift 2
  SPLITSWAN_PLUGIN_STATE="$s" NOW="$now" TODAY="${TODAY:-2026-10-09}" DOW="${DOW:-5}" bash "$SRC" "$@"
}

# 正對照：has 真的抓得到「不包含」
has "abc" "xyz"; [ $? != 0 ]; check "正對照：has 對不存在的字串回失敗" $?

# 1. 上班前：沒有任何提醒
s=$(st early); out=$(p "$s" 08:20)
! has "$out" "notify=true"; check "08:20 沒有提醒" $?
has "$out" "上班：未打卡" && has "$out" "下班：預計 18:30 提醒" && [ "$(head -1 <<<"$out")" = "打卡" ]; check "08:20 狀態行與標題" $?
has "$out" "開啟打卡頁 | href=https://example.com/punch"; check "打卡頁連結" $?
has "$out" "標記上班已打卡 | bash=\"" && has "$out" "param1=mark param2=in refresh=true"; check "標記上班的選單項目" $?
bashpath=$(sed -n 's/^標記上班已打卡 | bash="\([^"]*\)".*/\1/p' <<<"$out")
[ "${bashpath:0:1}" = / ] && [ -f "$bashpath" ]; check "bash= 是存在的絕對路徑（${bashpath}）" $?

# 2. 上班①
out=$(p "$(st in1)" 08:40)
has "$out" "該上班打卡了 | notify=true notify_id=in-1 href=https://example.com/punch" && ! has "$out" "notify_id=in-2"; check "08:40 上班①" $?
# 3. 上班②（只顯示較晚的一則）
out=$(p "$(st in2)" 08:55)
has "$out" "快遲到了，還沒打上班卡 | notify=true notify_id=in-2 href=https://example.com/punch" && ! has "$out" "notify_id=in-1"; check "08:55 上班②，不重複顯示上班①" $?

# 4. mark in：寫入現在時間
s=$(st marked); p "$s" 08:45 mark in; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$s/2026-10-09.in")" = "08:45" ]; check "mark in 寫入 08:45" $?
[ "$(stat -f %Lp "$s")" = 700 ]; check "state 目錄權限 700" $?
out=$(p "$s" 09:30)
has "$out" "上班：已打卡 08:45" && ! has "$out" "notify_id=in-" && has "$out" "取消上班打卡標記 | bash=" && has "$out" "param1=unmark param2=in"; check "已標記上班：不再提醒、可取消" $?
has "$out" "下班：預計 18:45 提醒"; check "下班① = 上班 08:45 + 600 分 = 18:45" $?
# 5. 下班①（有上班標記，晚於 18:30）
out=$(p "$s" 18:44); ! has "$out" "notify_id=off-"; check "18:44 還沒到 18:45 不提醒" $?
out=$(p "$s" 18:45)
has "$out" "可以下班打卡了（預計 18:45） | notify=true notify_id=off-1 href=https://example.com/punch"; check "18:45 下班①" $?
# 6. 下班②：下班① + 30 分，紅字
out=$(p "$s" 19:15)
has "$out" "別忘了下班打卡 | notify=true notify_id=off-2 color=red href=https://example.com/punch" && ! has "$out" "notify_id=off-1"; check "19:15 下班②紅字，不重複顯示下班①" $?
out=$(p "$s" 19:14); has "$out" "notify_id=off-1" && ! has "$out" "notify_id=off-2"; check "19:14 仍是下班①" $?

# 7. 上班很早（08:00 + 10h = 18:00）→ 下班①取 18:30
s=$(st earlyin); p "$s" 08:00 mark in
out=$(p "$s" 18:29); ! has "$out" "notify_id=off-" && has "$out" "下班：預計 18:30 提醒"; check "早於 18:30 時取 18:30（18:29 不提醒）" $?
out=$(p "$s" 18:30); has "$out" "可以下班打卡了（預計 18:30）"; check "18:30 下班①" $?
# 8. 沒標記上班 → 下班①＝18:30
out=$(p "$(st noin)" 18:30)
has "$out" "可以下班打卡了（預計 18:30） | notify=true notify_id=off-1" && has "$out" "notify_id=in-2"; check "沒標記上班：下班①取 18:30（上班②仍提醒）" $?
out=$(p "$(st noin)" 19:00); has "$out" "notify_id=off-2 color=red"; check "沒標記上班：19:00 下班②" $?

# 9. mark off → 全部完成
s=$(st marked); p "$s" 19:20 mark off
out=$(p "$s" 19:30)
[ "$(head -1 <<<"$out")" = "打卡 ✓" ] && has "$out" "下班：已打卡 19:20" && ! has "$out" "notify=true"; check "mark off：標題 ✓、不再提醒" $?
# 10. unmark off → 回到未標記
p "$s" 19:31 unmark off; rc=$?
[ "$rc" = 0 ] && [ ! -e "$s/2026-10-09.off" ]; check "unmark off 移除標記" $?
out=$(p "$s" 19:32); has "$out" "標記下班已打卡 | bash=" && has "$out" "notify_id=off-2" && [ "$(head -1 <<<"$out")" = "打卡" ]; check "unmark 後恢復提醒" $?
p "$s" 19:33 unmark in; [ ! -e "$s/2026-10-09.in" ]; check "unmark in" $?
p "$s" 10:00 mark bogus 2>/dev/null; [ $? = 2 ]; check "錯誤參數回 2" $?

# 11. 週末
out=$(DOW=6 p "$(st weekend)" 09:00)
[ "$out" = $'打卡\n---\n今天不用打卡' ]; check "週六只顯示「今天不用打卡」" $?
out=$(DOW=7 p "$(st weekend)" 19:30); ! has "$out" "notify=true"; check "週日不提醒" $?

# 12. 只保留 14 天（今天 2026-10-09 → 保留 2026-09-26 以後）
s=$(st clean); mkdir -p "$s"
for f in 2026-09-01.in 2026-09-25.off 2026-09-26.in 2026-10-08.off notes.txt 2026-09-01.in.bak 2026-9-1.in; do echo 08:30 >"$s/$f"; done
mkdir "$s/2026-09-02.in"                                  # 符合格式的資料夾不可動
echo keep >"$RUN/outside.in"; ln -s "$RUN/outside.in" "$s/2026-09-03.in"   # 符合格式的 symlink 不可動
p "$s" 09:00 >/dev/null
[ ! -e "$s/2026-09-01.in" ] && [ ! -e "$s/2026-09-25.off" ]; check "超過 14 天的日期檔被清掉" $?
[ -f "$s/2026-09-26.in" ] && [ -f "$s/2026-10-08.off" ]; check "14 天內的保留" $?
[ -f "$s/notes.txt" ] && [ -f "$s/2026-09-01.in.bak" ] && [ -f "$s/2026-9-1.in" ]; check "不符合日期格式的檔案不動" $?
[ -d "$s/2026-09-02.in" ] && [ -L "$s/2026-09-03.in" ] && [ -f "$RUN/outside.in" ]; check "資料夾與 symlink 不動" $?

# 13. 時間格式錯誤
out=$(p "$(st bad)" 8:5 2>&1); [ $? = 1 ] && has "$out" "NOW 格式錯誤"; check "NOW 格式錯誤時結束碼 1" $?
# 14. 標記檔內容不合法當作沒標記
s=$(st junk); mkdir -p "$s"; echo 'x;rm' >"$s/2026-10-09.in"
out=$(p "$s" 09:00); has "$out" "上班：未打卡"; check "標記檔內容不合法當作沒標記" $?

echo "通過 ${pass}，失敗 $fail"
[ "$fail" = 0 ]
