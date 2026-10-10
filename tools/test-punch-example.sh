#!/bin/bash
# 打卡提醒範例外掛（config/plugins/punch-reminder.1m.sh.example）的測試：不需要 App、不連網路。
# 政府日曆的部分用 CAL_API_FILE／CAL_CSV_FILE 指向本檔產生的精簡 fixture，HOME 指向暫存目錄（不讀真正的覆寫檔）。
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
mkdir -p "$RUN/home"
p() {  # state目錄 NOW [參數…]：平日 2026-10-09（週五）執行範例；預設不用政府日曆（HOLIDAY_SOURCE=none）
  local s=$1 now=$2; shift 2
  HOME="${PHOME:-$RUN/home}" HOLIDAY_SOURCE="${HOLIDAY_SOURCE:-none}" SPLITSWAN_PLUGIN_STATE="$s" NOW="$now" \
    TODAY="${TODAY:-2026-10-09}" DOW="${DOW:-5}" bash "$SRC" "$@"
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
[ "$(head -3 <<<"$out")" = $'打卡\n---\n今天放假：週末' ] && ! has "$out" "上班：" && has "$out" "日曆：週一至週五 | color=gray" \
  && ! has "$out" "重新抓取日曆"; check "週六（未用政府日曆）：今天放假：週末" $?
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

# 15. 下班時間跨過午夜：顯示隔日時間、不發下班提醒
s=$(st late); p "$s" 14:30 mark in
out=$(p "$s" 23:59)
has "$out" "下班：預計 隔日 00:30（跨日不提醒）" && ! has "$out" "notify_id=off-"; check "14:30 上班：下班顯示隔日 00:30 且不提醒" $?
! has "$out" "23:59 提醒"; check "不再顯示假的「預計 23:59 提醒」" $?
s=$(st edge); p "$s" 13:30 mark in
out=$(p "$s" 23:30); has "$out" "可以下班打卡了（預計 23:30）"; check "13:30 上班：下班① 23:30 當天照常提醒" $?
# 16. 24 小時制邊界
p "$(st t24)" 24:00 >/dev/null 2>&1; [ $? = 1 ]; check "NOW=24:00 視為格式錯誤" $?
p "$(st t29)" 29:59 >/dev/null 2>&1; [ $? = 1 ]; check "NOW=29:59 視為格式錯誤" $?
p "$(st t2359)" 23:59 >/dev/null 2>&1; [ $? = 0 ]; check "NOW=23:59 合法" $?
s=$(st junk24); mkdir -p "$s"; echo '25:00' >"$s/2026-10-09.in"
out=$(p "$s" 09:00); has "$out" "上班：未打卡"; check "標記檔 25:00 當作沒標記" $?

# ── 政府辦公日曆（離線 fixture）─────────────────────────
FX="$RUN/fx"; mkdir -p "$FX"
# 2026 全年：週末放假，其餘上班；另加國定假日與一天週六補班。第 2 欄是中文星期（判斷時不得使用）
gen_csv() {  # 輸出檔：用 awk 一次產生（bash 3.2 大量 process substitution 會耗盡 fd 並當掉）
  LC_ALL=C awk 'BEGIN {
    split("31 28 31 30 31 30 31 31 30 31 30 31", md, " ")
    split("一 二 三 四 五 六 日", wn, " ")
    hol["20260501"] = "勞動節"; hol["20260925"] = "中秋節"; hol["20261009"] = "補假"; hol["20261010"] = "國慶日"
    printf "\357\273\277西元日期,星期,是否放假,備註\r\n"
    w = 4                                   # 2026-01-01 是週四（1＝週一）
    for (m = 1; m <= 12; m++) for (d = 1; d <= md[m]; d++) {
      ds = sprintf("2026%02d%02d", m, d)
      if (ds in hol) printf "%s,%s,2,%s\r\n", ds, wn[w], hol[ds]
      else if (ds == "20260214") printf "%s,%s,0,補行上班\r\n", ds, wn[w]
      else if (w >= 6) printf "%s,%s,2,\r\n", ds, wn[w]
      else printf "%s,%s,0,\r\n", ds, wn[w]
      w = w % 7 + 1
    }
  }' >"$1"
}
gen_csv "$FX/good.csv"
LC_ALL=C grep -c '^2026' "$FX/good.csv" | grep -qx 365; check "fixture：365 天、含 BOM 與 CRLF" $?
api_entry() { printf '{"resourceDescription":"%s","resourceDownloadUrl":"%s","resourceFormat":"%s","resourceField":[{"name":"x"}]}' "$1" "$2" "${3:-CSV}"; }
{ printf '{"success":true,"result":{"distribution":['
  api_entry "114年中華民國政府行政機關辦公日曆表" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202407/a.csv"; printf ','
  api_entry "115年中華民國政府行政機關辦公日曆表" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202506/b.csv"; printf ','
  api_entry "115年中華民國政府行政機關辦公日曆表(1150901更新)" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202509/c.csv"; printf ','
  api_entry "115年中華民國政府行政機關辦公日曆表_Google行事曆專用" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202512/d.csv"; printf ','
  api_entry "115年中華民國政府行政機關辦公日曆表(假網站)" "https://evil.example/FileConversion?filename=dgpa/files/202612/e.csv"; printf ','
  api_entry "115年中華民國政府行政機關辦公日曆表(JSON)" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202611/f.json" JSON
  printf ']}}'; } >"$FX/api.json"
[ "$(plutil -extract result.distribution raw -o - "$FX/api.json")" = 6 ]; check "fixture：清單 JSON 可被 plutil 解析（6 筆）" $?
g() {  # 情境名 TODAY DOW NOW [參數…]：用政府日曆 fixture 執行
  local s; s=$(st "$1"); local today=$2 dow=$3 now=$4; shift 4
  CAL_API_FILE="${API:-$FX/api.json}" CAL_CSV_FILE="${CSV:-$FX/good.csv}" HOLIDAY_SOURCE=tw-gov TODAY="$today" DOW="$dow" p "$s" "$now" "$@"
}
meta() { grep "^$2=" "$(st "$1")/calendar-2026.meta" | cut -d= -f2-; }

# 17. 平日放假、週末補班、勞動節、一般週末、一般工作日
out=$(g gov 2026-09-25 5 09:00)
has "$out" "今天放假：中秋節" && ! has "$out" "notify=true" && has "$out" "日曆：政府 115 年（更新於 $(date +%m-%d)） | color=gray"; check "中秋節（週五）放假，資訊列顯示政府 115 年" $?
has "$out" "重新抓取日曆 | bash=\"" && has "$out" "param1=refresh-calendar refresh=true"; check "有「重新抓取日曆」項目" $?
[ "$(meta gov desc)" = "115年中華民國政府行政機關辦公日曆表(1150901更新)" ]; check "多版本取最新上傳的一般版，排除 Google 版、非 CSV 與非政府網址（選到：$(meta gov desc)）" $?
out=$(g gov 2026-02-14 6 09:00); has "$out" "上班：未打卡" && has "$out" "快遲到了"; check "週六補行上班：當工作日提醒" $?
out=$(g gov 2026-05-01 5 09:00); has "$out" "今天放假：勞動節"; check "勞動節放假" $?
out=$(g gov 2026-10-17 6 09:00); has "$out" "今天放假：週末"; check "一般週六：今天放假：週末" $?
out=$(g gov 2026-10-12 1 09:00); has "$out" "上班：未打卡" && has "$out" "日曆：政府 115 年"; check "一般週一上班" $?
out=$(g gov 2026-10-09 5 09:00); has "$out" "今天放假：補假"; check "10/9 補假（週五）" $?

# 18. 覆寫檔：off／work 優先、註解與格式錯的行忽略、權限不符整個忽略
H="$RUN/ohome"; mkdir -p "$H/.config/splitswan"; O="$H/.config/splitswan/punch-overrides.txt"
printf '# 註解\n2026-10-12 off 特休\n2026-10-10 work 加班\nbad line\n2026-13-01 off\n# 2026-10-13 off 被註解\n2026-10-14 maybe\n' >"$O"; chmod 600 "$O"
out=$(PHOME=$H g ovr 2026-10-12 1 09:00); has "$out" "今天放假：特休" && has "$out" "日曆：覆寫"; check "覆寫 off 優先於政府日曆" $?
out=$(PHOME=$H g ovr 2026-10-10 6 09:00); has "$out" "上班：未打卡" && has "$out" "日曆：覆寫"; check "覆寫 work 優先（國慶日加班）" $?
out=$(PHOME=$H g ovr 2026-10-13 2 09:00); has "$out" "上班：未打卡" && has "$out" "日曆：政府"; check "被註解的行不生效" $?
out=$(PHOME=$H g ovr 2026-10-14 3 09:00); has "$out" "日曆：政府"; check "格式錯的行（maybe）忽略" $?
chmod 666 "$O"
out=$(PHOME=$H g ovr 2026-10-12 1 09:00); has "$out" "上班：未打卡" && has "$out" "覆寫檔權限不安全" && has "$out" "日曆：政府"; check "覆寫檔他人可寫：忽略並提示" $?
chmod 600 "$O"

# 19. 壞資料不覆蓋舊快取（先有好的快取，再用 refresh-calendar 強制重抓壞資料）
s=$(st bad); g bad 2026-10-12 1 09:00 >/dev/null
sum0=$(shasum "$s/calendar-2026.csv" | cut -c1-40)
head -100 "$FX/good.csv" >"$FX/short.csv"
{ head -1 "$FX/good.csv"; LC_ALL=C sed -n '2,400p' "$FX/good.csv" | LC_ALL=C sed 's/,0,/,X,/'; } >"$FX/badfmt.csv"
LC_ALL=C sed 's/^2026/2025/' "$FX/good.csv" >"$FX/year.csv"
for bad in short badfmt year; do
  CSV="$FX/$bad.csv" g bad 2026-10-12 1 09:00 refresh-calendar
  [ "$(shasum "$s/calendar-2026.csv" | cut -c1-40)" = "$sum0" ] && [ -f "$s/calendar-2026.fail" ]; check "壞資料（${bad}）不覆蓋舊快取、記錄失敗" $?
done
out=$(g bad 2026-10-09 5 09:00); has "$out" "今天放假：補假"; check "失敗後仍用舊快取判斷" $?
ls -A "$s" | LC_ALL=C grep -q '^\.cal-'; [ $? != 0 ]; check "不留暫存檔" $?

# 20. 備註含 | 與超長備註：顯示時移除 |、截到 20 字
LC_ALL=C sed -e 's/^20261009,\(.*\),2,補假/20261009,\1,2,補假|notify=true href=https:\/\/evil.example/' \
  -e 's/^20261010,\(.*\),2,國慶日/20261010,\1,2,一二三四五六七八九十一二三四五六七八九十多出來的字/' "$FX/good.csv" >"$FX/remark.csv"
out=$(CSV="$FX/remark.csv" g remark 2026-10-09 5 09:00)
line=$(grep '^今天放假' <<<"$out")
[ "$line" = "今天放假：補假notify=true href=h" ] && ! grep -q '|' <<<"$line"; check "備註的 | 移除，不會變成參數（${line}）" $?
out=$(CSV="$FX/remark.csv" g remark 2026-10-10 6 09:00)
[ "$(grep '^今天放假' <<<"$out")" = "今天放假：一二三四五六七八九十一二三四五六七八九十" ]; check "超長備註截到 20 字" $?

# 21. 抓取失敗 6 小時內不重試；超過 6 小時重抓；快取 7 天內不重抓
s=$(st retry)
out=$(API="$FX/missing.json" g retry 2026-10-12 1 09:00); has "$out" "日曆：抓取失敗，暫用週一至週五" && has "$out" "上班：未打卡"; check "抓取失敗：退回週一至週五" $?
out=$(g retry 2026-10-09 5 09:00); has "$out" "抓取失敗" && has "$out" "上班：未打卡" && [ ! -f "$s/calendar-2026.csv" ]; check "失敗後 6 小時內不重試（資料正確也不抓）" $?
echo $(( $(date +%s) - 7 * 3600 )) >| "$s/calendar-2026.fail"
out=$(g retry 2026-10-09 5 09:00); has "$out" "今天放假：補假" && [ ! -f "$s/calendar-2026.fail" ]; check "失敗超過 6 小時後重抓成功" $?
sum1=$(shasum "$s/calendar-2026.csv" | cut -c1-40)
out=$(CSV="$FX/remark.csv" g retry 2026-10-09 5 09:00); [ "$(shasum "$s/calendar-2026.csv" | cut -c1-40)" = "$sum1" ]; check "快取 7 天內不重抓" $?
LC_ALL=C sed -i '' "s/^fetched=.*/fetched=$(( $(date +%s) - 8 * 86400 ))/" "$s/calendar-2026.meta"
out=$(CSV="$FX/remark.csv" g retry 2026-10-09 5 09:00); [ "$(shasum "$s/calendar-2026.csv" | cut -c1-40)" != "$sum1" ]; check "快取超過 7 天重抓" $?
echo $(date +%s) >| "$s/calendar-2026.fail"
CSV="$FX/good.csv" g retry 2026-10-09 5 09:00 refresh-calendar
[ "$(shasum "$s/calendar-2026.csv" | cut -c1-40)" = "$sum1" ] && [ ! -f "$s/calendar-2026.fail" ]; check "「重新抓取日曆」忽略 6 小時限制" $?

# 22. locale：不設 C 時 BSD awk 會把中文比較成相等（正對照）；腳本在任何 locale 下結果相同
n=$(LC_ALL=en_US.UTF-8 awk -F, '$2=="六"' "$FX/good.csv" | wc -l | tr -d ' ')
m=$(LC_ALL=C awk -F, '$2=="六"' "$FX/good.csv" | wc -l | tr -d ' ')
[ "$n" -gt 300 ] && [ "$m" -lt 60 ]; check "正對照：en_US.UTF-8 下 awk 誤判（命中 $n 行），C 下正確（$m 行）" $?
ref=$(g loc 2026-10-09 5 09:00; g loc 2026-10-12 1 09:00; g loc 2026-02-14 6 09:00)
for loc in en_US.UTF-8 zh_TW.UTF-8; do
  got=$(export LC_ALL=$loc; g loc 2026-10-09 5 09:00; g loc 2026-10-12 1 09:00; g loc 2026-02-14 6 09:00)
  [ "$got" = "$ref" ]; check "LC_ALL=$loc 下結果與 C 相同" $?
done
got=$(export LC_COLLATE=zh_TW.UTF-8 LANG=zh_TW.UTF-8; g loc 2026-10-09 5 09:00); has "$got" "今天放假：補假"; check "LC_COLLATE=zh_TW.UTF-8 下結果正確" $?

# 23. HOLIDAY_SOURCE=none：不用政府日曆、不連網、沒有重新抓取項目
out=$(CAL_API_FILE="$FX/api.json" CAL_CSV_FILE="$FX/good.csv" HOLIDAY_SOURCE=none TODAY=2026-09-25 DOW=5 p "$(st none)" 09:00)
has "$out" "上班：未打卡" && has "$out" "日曆：週一至週五" && ! has "$out" "重新抓取日曆" && [ ! -f "$(st none)/calendar-2026.csv" ]; check "HOLIDAY_SOURCE=none 只用週一至週五" $?

# 24. 異常大的清單：999 筆在時限內失敗、留下 .fail、不留暫存檔（逐筆 plutil 時要 30 秒以上）
{ printf '{"result":{"distribution":['
  for ((i = 1; i <= 999; i++)); do [ $i = 1 ] || printf ','
    api_entry "115年中華民國政府行政機關辦公日曆表($i)" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202506/$i.csv"; done
  printf ']}}'; } >"$FX/big.json"
s=$(st big); t0=$(date +%s)
out=$(API="$FX/big.json" g big 2026-10-12 1 09:00); el=$(( $(date +%s) - t0 ))
[ "$el" -le 3 ] && [ -f "$s/calendar-2026.fail" ] && [ ! -f "$s/calendar-2026.csv" ] && has "$out" "抓取失敗"; check "999 筆清單：${el} 秒內失敗並留下 .fail" $?
[ -z "$(ls -A "$s" | LC_ALL=C grep '^\.cal-')" ]; check "999 筆清單：不留暫存檔" $?

# 25. 清單項目含控制字元（TAB、換行）就排除；退回較舊但乾淨的項目
{ printf '{"result":{"distribution":['
  api_entry '115年中華民國政府行政機關辦公日曆表\thttps://evil.example/x.csv' "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202512/t.csv"; printf ','
  api_entry '115年中華民國政府行政機關辦公日曆表\nfetched=1' "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202511/n.csv"; printf ','
  api_entry "115年中華民國政府行政機關辦公日曆表" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202510/u.csv\tx"; printf ','
  api_entry "115年中華民國政府行政機關辦公日曆表" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202506/ok.csv"
  printf ']}}'; } >"$FX/ctl.json"
API="$FX/ctl.json" g ctl 2026-10-12 1 09:00 >/dev/null
[ "$(meta ctl desc)" = "115年中華民國政府行政機關辦公日曆表" ]; check "描述或網址含 TAB／換行的項目被排除（選到：$(meta ctl desc)）" $?

# 26. 嚴格驗證：日期重複、缺天、引號欄位
{ head -1 "$FX/good.csv"; LC_ALL=C grep '^2026' "$FX/good.csv" | LC_ALL=C sed 's/^20260102,/20260101,/'; } >"$FX/dupday.csv"
LC_ALL=C grep -c '^2026' "$FX/dupday.csv" | grep -qx 365; check "fixture：日期重複但仍是 365 行" $?
out=$(CSV="$FX/dupday.csv" g dupday 2026-10-12 1 09:00); has "$out" "抓取失敗"; check "日期重複（湊滿 365 行）視為失敗" $?
LC_ALL=C grep -v '^20260702,' "$FX/good.csv" >"$FX/missing.csv"
out=$(CSV="$FX/missing.csv" g missing 2026-10-12 1 09:00); has "$out" "抓取失敗"; check "缺一天視為失敗" $?
LC_ALL=C sed 's/^20261010,\([^,]*\),2,國慶日/"20261010","\1","2","國慶日"/' "$FX/good.csv" >"$FX/quoted.csv"
out=$(CSV="$FX/quoted.csv" g quoted 2026-10-10 6 09:00); has "$out" "今天放假：國慶日"; check "引號欄位的 \" 去除後正常判斷" $?
LC_ALL=C awk -F, 'BEGIN { OFS = "," } $1 == "20261010" { $4 = "國慶\033[31m日" } { print }' "$FX/good.csv" >"$FX/esc.csv"
LC_ALL=C grep '^20261010' "$FX/esc.csv" | LC_ALL=C grep -q $'\x1b'; check "fixture：備註含 ESC" $?
out=$(CSV="$FX/esc.csv" g esc 2026-10-10 6 09:00); line=$(grep '^今天放假' <<<"$out")
[ "$line" = "今天放假：國慶[31m日" ] && ! LC_ALL=C grep -q $'\x1b' <<<"$line"; check "備註的控制字元（ESC）移除" $?

# 27. 未來時間（時鐘倒退）不當成有效快取／失敗紀錄
s=$(st future); g future 2026-10-12 1 09:00 >/dev/null; sumf=$(shasum "$s/calendar-2026.csv" | cut -c1-40)
LC_ALL=C sed -i '' "s/^fetched=.*/fetched=$(( $(date +%s) + 30 * 86400 ))/" "$s/calendar-2026.meta"
CSV="$FX/remark.csv" g future 2026-10-12 1 09:00 >/dev/null
[ "$(shasum "$s/calendar-2026.csv" | cut -c1-40)" != "$sumf" ]; check "快取時間在未來：視為過期重抓" $?

# 28. 連網路徑（以假 curl 模擬，不真的連網）：參數、非 0 結束碼、候選退回、逾時中斷
FB="$RUN/fakebin"; mkdir -p "$FB"
cat >"$FB/curl" <<'FAKE'
#!/bin/bash
echo "$*" >>"$FAKE_LOG"
out=""; url=""
while [ $# -gt 0 ]; do
  case $1 in
    -o|-m|--proto|--proto-redir|--max-filesize) [ "$1" = -o ] && out=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case "$FAKE_MODE:$url" in
  sleep:*) sleep 30 ;;
  *:*dataset/14718) cat "$FAKE_API" >"$out" ;;
  *:*c.csv) printf 'garbage\n' >"$out" ;;
  partial:*b.csv) cat "$FAKE_CSV" >"$out"; exit 28 ;;
  *:*b.csv) cat "$FAKE_CSV" >"$out" ;;
  *) exit 22 ;;
esac
FAKE
chmod 700 "$FB/curl"
{ printf '{"result":{"distribution":['
  api_entry "115年中華民國政府行政機關辦公日曆表" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202506/b.csv"; printf ','
  api_entry "115年中華民國政府行政機關辦公日曆表(1150901更新)" "https://www.dgpa.gov.tw/FileConversion?filename=dgpa/files/202509/c.csv"
  printf ']}}'; } >"$FX/net.json"
net() {  # 模式 情境名 TODAY DOW [參數…]：走連網路徑，但 curl 是假的
  local mode=$1 name=$2 today=$3 dow=$4; shift 4
  PATH="$FB:$PATH" FAKE_MODE=$mode FAKE_LOG="$RUN/fake-$name.log" FAKE_API="$FX/net.json" FAKE_CSV="$FX/good.csv" \
    HOLIDAY_SOURCE=tw-gov TODAY="$today" DOW="$dow" p "$(st "$name")" 09:00 "$@"
}
out=$(net ok netok 2026-10-09 5)
has "$out" "今天放假：補假" && [ "$(meta netok desc)" = "115年中華民國政府行政機關辦公日曆表" ]; check "最新候選驗證失敗時改試下一個（選到：$(meta netok desc)）" $?
[ "$(LC_ALL=C grep -c -- '^-g ' "$RUN/fake-netok.log")" = 3 ] && LC_ALL=C grep -q -- "--proto =https --proto-redir =https" "$RUN/fake-netok.log"; check "curl 帶 -g 與 https 限制（呼叫 3 次：清單＋2 個候選）" $?
out=$(net partial netpart 2026-10-09 5); has "$out" "抓取失敗" && [ ! -f "$(st netpart)/calendar-2026.csv" ]; check "curl 非 0 結束碼（內容看似完整）一律視為失敗" $?
# 逾時中斷：App 送 SIGTERM → 立刻結束、清掉暫存檔、留下 .fail；下一分鐘不重抓
s=$(st netterm); mkdir -p "$s"
( net sleep netterm 2026-10-12 1 >/dev/null ) & bg=$!
sleep 1.5; t0=$(date +%s)
kill -TERM "$(pgrep -P $bg)" 2>/dev/null
wait $bg; el=$(( $(date +%s) - t0 ))
[ "$el" -le 2 ] && [ -f "$s/calendar-2026.fail" ] && [ -z "$(ls -A "$s" | LC_ALL=C grep '^\.cal-')" ]; check "SIGTERM 中斷：${el} 秒內結束、留下 .fail、無暫存檔" $?
calls=$(LC_ALL=C grep -c . "$RUN/fake-netterm.log")
out=$(net ok netterm 2026-10-12 1); has "$out" "抓取失敗" && [ "$(LC_ALL=C grep -c . "$RUN/fake-netterm.log")" = "$calls" ]; check "中斷後下一次執行不重抓（6 小時內）" $?
# SIGKILL（無法清理）：.fail 已在開始前寫入，所以同樣不會每分鐘重抓；殘留暫存檔在下一次執行時清掉
s=$(st netkill); mkdir -p "$s"
( net sleep netkill 2026-10-12 1 >/dev/null ) 2>/dev/null & bg=$!
sleep 1.5; kill -KILL "$(pgrep -P $bg)" 2>/dev/null; wait $bg
[ -f "$s/calendar-2026.fail" ]; check "SIGKILL 中斷：開始前已寫 .fail" $?
calls=$(LC_ALL=C grep -c . "$RUN/fake-netkill.log")
net ok netkill 2026-10-12 1 >/dev/null
[ "$(LC_ALL=C grep -c . "$RUN/fake-netkill.log")" = "$calls" ] && [ -z "$(ls -A "$s" | LC_ALL=C grep '^\.cal-')" ]; check "SIGKILL 後不重抓，殘留暫存檔被清掉" $?

echo "通過 ${pass}，失敗 $fail"
[ "$fail" = 0 ]
