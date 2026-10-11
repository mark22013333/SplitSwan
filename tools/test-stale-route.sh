#!/bin/bash
# 輔助程式「連上後路由沒走 utun → 重啟 charon 再連一次」的離線測試：一般使用者權限即可，不需要 sudo、不連 VPN。
#   bash tools/test-stale-route.sh
# 把 helper 複製一份，swanctl／charon／route 換成假程式（同 tools/test-classify.sh 的 sed 替換手法），驗證：
#   1. 一開始路由就走 utun：不重啟，只印 ok
#   2. 第一次走 en0、重啟後走 utun：只結束路徑相符的 charon（同名但路徑不同的程序不受影響），印 route … fixed ＋ ok
#   3. 兩次都走 en0：只重啟一次，印 route … bad ＋ ok
#   4. 重啟後重新連線失敗：reason 行 ＋ route … failed ＋ fail
#   5. charon 不理 TERM：5 秒後改送 KILL
#   6. 修復途中被 TERM（App 逾時）：卡住的子程序跟著結束、不留暫存檔
#   7. 相容性：舊版 App 只認「ok vpnN／fail vpnN」整行，新的 route 行不影響
# 範例網段用虛構的 10.0.0.x；全部只在暫存目錄內操作，結束時清掉；設 KEEP_TMP=1 可保留。
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/splitswan-helper"
[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 1; }
RUN=$(mktemp -d "${TMPDIR:-/tmp}/splitswan-route.XXXXXX") || exit 1
RUN=$(cd "$RUN" && pwd -P)

pass=0; fail=0
check() { if [ "$2" = 0 ]; then echo "✅ $1"; pass=$((pass+1)); else echo "❌ $1"; fail=$((fail+1)); fi; }

# 依執行檔路徑（ps comm）找程序；不用 pgrep -f，會比對到自己
pids_by_path() { ps -eo pid=,comm= | awk -v m="$1" '$2==m{print $1}'; }
kill_by_path() { local p; for p in $(pids_by_path "$1"); do kill -KILL "$p" 2>/dev/null; done; }
alive() { ps -eo pid=,args= | awk -v m="$1" '$2==m{f=1} END{exit !f}'; }
reap() { ps -eo pid=,args= | awk -v m="$1" '$2==m{print $1}' | while read -r p; do kill -KILL "$p" 2>/dev/null; done; }

finish() {
  kill_by_path "$RUN/bin/charon"
  kill_by_path "$RUN/other/charon"
  if [ "${KEEP_TMP:-0}" = 1 ]; then echo "暫存目錄保留在 $RUN"; else command rm -r "$RUN"; fi
}
trap finish EXIT

mkdir -p "$RUN/bin" "$RUN/other" "$RUN/tmp" "$RUN/state"

# 假 charon：名稱是 charon、argv[0]／comm 是自己的路徑；每次啟動記一行。
# FAKE_IGNORE_TERM=1 時不理 TERM（測 KILL 後備）
cat >"$RUN/bin/charon" <<EOF
#!/bin/bash
echo start >>"$RUN/state/charon-starts"
if [ "\${FAKE_IGNORE_TERM:-0}" = 1 ]; then
  exec -a "\$0" /bin/bash -c 'trap "" TERM; while :; do /bin/sleep 1; done'
fi
exec -a "\$0" /bin/sleep 300
EOF
# 同名但路徑不同的程序（誘餌）：helper 不可以碰它
cat >"$RUN/other/charon" <<'EOF'
#!/bin/bash
exec -a "$0" /bin/sleep 300
EOF

# 假 swanctl：--initiate 第 FAKE_INIT_FAIL_AT 次起失敗；--list-sas 輸出含 IKE 身分與 CHILD 網段
cat >"$RUN/bin/swanctl" <<EOF
#!/bin/bash
if [ -n "\${FAKE_HANG:-}" ]; then
  case "\$*" in *"\$FAKE_HANG"*) exec -a "\$FAKE_MARK" /bin/sleep 300 ;; esac
fi
case "\$*" in
  *--initiate*)
    ike=\$(printf "%s\\n" "\$@" | awk 'prev=="--ike"{print} {prev=\$0}')
    echo "\$ike" >>"$RUN/state/initiates"
    n=\$(wc -l <"$RUN/state/initiates" | tr -d ' ')
    if [ -n "\${FAKE_HANG_INIT_AT:-}" ] && [ "\$n" -ge "\$FAKE_HANG_INIT_AT" ]; then exec -a "\$FAKE_MARK" /bin/sleep 300; fi
    if [ -n "\${FAKE_INIT_FAIL_AT:-}" ] && [ "\$n" -ge "\$FAKE_INIT_FAIL_AT" ]; then
      echo "[IKE] giving up after 3 retransmits"; echo "[IKE] establishing IKE_SA failed, peer not responding (203.0.113.20)"; exit 1
    fi
    echo "initiate completed successfully"; exit 0 ;;
  *--list-sas*)
    cat <<'SAS'
vpn1: #3, ESTABLISHED, IKEv2, 0123456789abcdef_i* fedcba9876543210_r
  local  'user01' @ 192.0.2.5[4500] [10.0.0.77]
  remote '203.0.113.10' @ 203.0.113.10[4500]
  AES_CBC-256/HMAC_SHA2_256_128/PRF_HMAC_SHA2_256/MODP_2048
  established 12s ago, rekeying in 10000s
  corp: #4, reqid 1, INSTALLED, TUNNEL-in-UDP, ESP:AES_CBC-256/HMAC_SHA2_256_128
    installed 12s ago, rekeying in 3000s, expires in 3600s
    in  c1234567,      0 bytes,     0 packets
    out c7654321,      0 bytes,     0 packets
    local  10.0.0.77/32
    remote 10.0.0.0/24 10.0.1.0/24
SAS
    exit 0 ;;
  *) exit 0 ;;
esac
EOF

# 假 route：第 n 次查詢回 FAKE_ROUTES 的第 n 個介面（不夠就重複最後一個），並記下查了哪個位址
cat >"$RUN/bin/route" <<EOF
#!/bin/bash
if [ -n "\${FAKE_ROUTE_HANG:-}" ]; then exec -a "\$FAKE_MARK" /bin/sleep 300; fi
echo "\$3" >>"$RUN/state/route-queries"
n=\$(wc -l <"$RUN/state/route-queries" | tr -d ' ')
set -- \${FAKE_ROUTES:-utun4}
[ "\$n" -gt \$# ] && n=\$#
iface=\${!n}
echo "   route to: 10.0.0.0"
echo "destination: 10.0.0.0"
echo "       mask: 255.255.255.0"
echo "  interface: \$iface"
echo "      flags: <UP,DONE,STATIC>"
EOF
chmod 755 "$RUN/bin/charon" "$RUN/other/charon" "$RUN/bin/swanctl" "$RUN/bin/route"

sed -e "s#^SWANCTL=.*#SWANCTL=$RUN/bin/swanctl#" -e "s#^CHARON=.*#CHARON=$RUN/bin/charon#" \
    -e "s#^ROUTE=.*#ROUTE=$RUN/bin/route#" -e "s#^HELPER_TMPDIR=.*#HELPER_TMPDIR=$RUN/tmp#" "$SRC" >"$RUN/helper"
grep -q "^ROUTE=$RUN/bin/route\$" "$RUN/helper" && grep -q "^CHARON=$RUN/bin/charon\$" "$RUN/helper" \
  && grep -q "^HELPER_TMPDIR=$RUN/tmp\$" "$RUN/helper"
check "副本的 charon／route／暫存目錄已換掉（正對照）" $?

# 每個情境前：清掉計數、只留一支「長期執行」的假 charon 與一支誘餌
reset_state() {
  kill_by_path "$RUN/bin/charon"
  kill_by_path "$RUN/other/charon"
  : >|"$RUN/state/charon-starts"; : >|"$RUN/state/initiates"; : >|"$RUN/state/route-queries"
  FAKE_IGNORE_TERM=${1:-0} nohup "$RUN/bin/charon" </dev/null >/dev/null 2>&1 & disown
  nohup "$RUN/other/charon" </dev/null >/dev/null 2>&1 & disown
  local i
  for i in $(seq 1 30); do
    [ -n "$(pids_by_path "$RUN/bin/charon")" ] && [ -n "$(pids_by_path "$RUN/other/charon")" ] && break
    sleep 0.1
  done
  OLD=$(pids_by_path "$RUN/bin/charon"); DECOY=$(pids_by_path "$RUN/other/charon")
  : >|"$RUN/state/charon-starts"
}
starts() { wc -l <"$RUN/state/charon-starts" | tr -d ' '; }
lines() { printf '%s' "$1" | tr '\n' '|'; }

# 正對照：helper 的 own_charon_pids 只認路徑相符的那支
reset_state
[ -n "${OLD}" ] && [ -n "${DECOY}" ] && [ "${OLD}" != "${DECOY}" ]; check "假 charon 與誘餌都在跑（正對照，PID ${OLD}／${DECOY}）" $?
pgrep -x charon | grep -qx "${DECOY}"; check "誘餌的名稱也是 charon（pgrep -x charon 找得到它，正對照）" $?

# ---- 1. 一開始就走 utun ----
reset_state
out=$(FAKE_ROUTES="utun4" bash "$RUN/helper" up 1); rc=$?
[ "${rc}" = 0 ] && [ "$out" = "ok vpn1" ]; s=$?; check "路由正常：只印 ok vpn1（實際：$(lines "$out")）" $s
[ "$(starts)" = 0 ] && pid_still=$(pids_by_path "$RUN/bin/charon") && [ "$pid_still" = "${OLD}" ]
check "路由正常：沒有重啟 charon（原 PID ${OLD} 還在）" $?
[ "$(cat "$RUN/state/route-queries")" = "10.0.0.0" ]; check "查的是第一個遠端網段的網路位址 10.0.0.0（不是 IKE 對端位址）" $?

# ---- 2. en0 → 重啟 → utun ----
reset_state
t0=$SECONDS
out=$(FAKE_ROUTES="en0 utun4" bash "$RUN/helper" up 1); rc=$?; OUT2=$out
[ "${rc}" = 0 ] && [ "$out" = "$(printf 'route vpn1 fixed en0\nok vpn1')" ]
s=$?; check "先 en0 後 utun：route vpn1 fixed en0 ＋ ok vpn1（實際：$(lines "$out")，$((SECONDS - t0)) 秒）" $s
! kill -0 "${OLD}" 2>/dev/null; check "原本的 charon（PID ${OLD}）已結束" $?
new=$(pids_by_path "$RUN/bin/charon")
[ "$(starts)" = 1 ] && [ -n "${new}" ] && [ "${new}" != "${OLD}" ]; check "重新啟動了一支新的 charon（PID ${new:-無}）" $?
kill -0 "${DECOY}" 2>/dev/null; check "同名但路徑不同的 charon（PID ${DECOY}）不受影響" $?
[ "$(tr "\n" " " <"$RUN/state/initiates")" = "vpn1 vpn1 " ]; check "重新連的是同一台（initiate 依序為 vpn1、vpn1）" $?

# ---- 3. 兩次都是 en0 ----
reset_state
out=$(FAKE_ROUTES="en0 en0" bash "$RUN/helper" up 2); rc=$?; OUT3=$out
[ "${rc}" = 0 ] && [ "$out" = "$(printf 'route vpn2 bad en0\nok vpn2')" ]
s=$?; check "兩次都 en0：route vpn2 bad en0 ＋ ok vpn2，結束代碼 0（實際：$(lines "$out")）" $s
[ "$(starts)" = 1 ] && [ "$(wc -l <"$RUN/state/route-queries" | tr -d ' ')" = 2 ] && [ "$(wc -l <"$RUN/state/initiates" | tr -d ' ')" = 2 ]
check "只重啟一次（charon 啟動 1 次、查路由 2 次、initiate 2 次）" $?
kill -0 "${DECOY}" 2>/dev/null; check "誘餌仍在" $?

# ---- 4. 重啟後重新連線失敗 ----
reset_state
out=$(FAKE_ROUTES="en0" FAKE_INIT_FAIL_AT=2 bash "$RUN/helper" up 3); rc=$?; OUT4=$out
[ "${rc}" = 1 ] && [ "$out" = "$(printf 'reason vpn3 unreachable\nroute vpn3 failed en0\nfail vpn3')" ]
s=$?; check "重連失敗：reason ＋ route vpn3 failed en0 ＋ fail vpn3，結束代碼 1（實際：$(lines "$out")）" $s
! printf '%s\n' "$out" | grep -qE 'user01|203\.0\.113|192\.0\.2|10\.0\.0'; check "輸出不含帳號、閘道與網段" $?

# ---- 5. charon 不理 TERM ----
reset_state 1
t0=$SECONDS
out=$(FAKE_ROUTES="en0 utun4" bash "$RUN/helper" up 1); rc=$?
el=$((SECONDS - t0))
[ "${rc}" = 0 ] && [ "$out" = "$(printf 'route vpn1 fixed en0\nok vpn1')" ] && ! kill -0 "${OLD}" 2>/dev/null
check "charon 不理 TERM：改送 KILL 後照樣修復（耗時 ${el} 秒）" $?
[ "${el}" -ge 4 ] && [ "${el}" -le 10 ]; check "TERM 後等約 5 秒才 KILL（實際 ${el} 秒）" $?
kill -0 "${DECOY}" 2>/dev/null; check "誘餌仍在" $?

# ---- 6. 修復途中被 TERM ----
HT_STARTED=1; HT_ORPHAN=1; HT_RC=0
hang_test() {  # 環境變數設定… -- 子命令…
  local mark="splitswan-fake-$$-$RANDOM" hp i
  env FAKE_MARK="$mark" "$@" >/dev/null 2>&1 &
  hp=$!
  HT_STARTED=1
  for i in $(seq 1 50); do if alive "$mark"; then HT_STARTED=0; break; fi; sleep 0.1; done
  kill -TERM "$hp" 2>/dev/null
  wait "$hp" 2>/dev/null; HT_RC=$?
  sleep 0.5
  if alive "$mark"; then HT_ORPHAN=0; reap "$mark"; else HT_ORPHAN=1; fi
}
# 查路由卡住、查 SA 卡住、重啟 charon 之後的第二次 initiate 卡住（這時舊 charon 已結束、新的已啟動）
for spec in "FAKE_ROUTE_HANG=1|route -n get" "FAKE_HANG=--list-sas|swanctl --list-sas" "FAKE_HANG_INIT_AT=2|重啟後的第二次 initiate"; do
  reset_state
  hang_test ${spec%%|*} FAKE_ROUTES=en0 bash "$RUN/helper" up 1
  [ "$HT_STARTED" = 0 ]; check "卡在 ${spec#*|}（正對照：真的有卡住）" $?
  [ "$HT_ORPHAN" = 1 ] && [ "$HT_RC" = 143 ]; check "${spec#*|}：TERM 後子程序跟著結束、helper 回 143（實際 ${HT_RC}）" $?
  [ -z "$(ls -A "$RUN/tmp")" ]; check "${spec#*|}：中斷後不留暫存檔" $?
done
[ "$(starts)" = 1 ]; check "第二次 initiate 卡住的情境確實走過重啟（charon 啟動 1 次，正對照）" $?

# ---- 7. 相容性：舊版 App 的判斷規則套在新輸出上 ----
# 舊版 App：結束代碼 0 視為成功；GatewayHistory.shouldRecord 只認整行「fail vpnN」；ConnectFailReason 只認「reason vpnN 代碼」
for o in "$OUT2" "$OUT3"; do
  printf '%s\n' "$o" | grep -qx 'ok vpn[12]' && ! printf '%s\n' "$o" | grep -qE '^(fail|reason) '
  s=$?; check "情境 2／3 的實際輸出：「ok vpnN」整行仍在，沒有會被舊版當成失敗的行（$(lines "$o")）" $s
done
printf '%s\n' "$OUT4" | grep -qx 'fail vpn3' && [ "$(printf '%s\n' "$OUT4" | grep -c '^reason vpn3 ')" = 1 ]
check "情境 4 的實際輸出：「fail vpn3」整行仍在、reason 行只有一行" $?

echo "通過 ${pass}，失敗 ${fail}"
[ "$fail" = 0 ]
