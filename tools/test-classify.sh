#!/bin/bash
# 輔助程式「連線失敗原因分類」的離線測試：一般使用者權限即可，不需要 sudo、不連 VPN。
#   bash tools/test-classify.sh
# 1. 擷取 splitswan-helper 的 classify_fail，餵代表性的 swanctl --initiate 失敗輸出，驗證分類代碼
# 2. 把 helper 複製一份、swanctl／charon 換成假程式，實際跑 `up N`、`up auto`，驗證輸出格式
#    （舊版 App 認的「fail vpnN」整行仍在、原因在獨立的 reason 行、原始輸出中的帳號與位址不外流）
# 範例位址一律用 RFC 5737；帳號是假的。全部只在暫存目錄內操作，結束時清掉；設 KEEP_TMP=1 可保留。
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/splitswan-helper"
[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 1; }
RUN=$(mktemp -d "${TMPDIR:-/tmp}/splitswan-classify.XXXXXX") || exit 1
if [ "${KEEP_TMP:-0}" = 1 ]; then echo "暫存目錄保留在 $RUN"; else trap 'command rm -r "$RUN"' EXIT; fi

pass=0; fail=0
check() { if [ "$2" = 0 ]; then echo "✅ $1"; pass=$((pass+1)); else echo "❌ $1"; fail=$((fail+1)); fi; }

bash -n "$SRC"; check "bash -n splitswan-helper" $?

# ---- 1. classify_fail 單元測試 ----
awk '/^# >>> 連線與失敗分類/{p=1} p{print} /^# <<< 連線與失敗分類/{p=0}' "$SRC" >"$RUN/fn.sh"
grep -q '^classify_fail()' "$RUN/fn.sh"; check "擷取到 classify_fail（正對照：標記行還在）" $?
# shellcheck disable=SC1091
source "$RUN/fn.sh"

expect() {  # 說明 預期代碼 輸出內容
  local got; got=$(printf '%b' "$3" | classify_fail)
  [ "$got" = "$2" ]; check "$1 → $2（實際：${got}）" $?
}
INIT='[IKE] initiating IKE_SA vpn1[1] to 203.0.113.10\n[ENC] generating IKE_SA_INIT request 0 [ SA KE No N(NATD_S_IP) N(NATD_D_IP) ]\n[NET] sending packet: from 192.0.2.5[500] to 203.0.113.10[500] (464 bytes)\n'
FAILED_TAIL="initiate failed: establishing CHILD_SA 'corp' failed\n"
expect "閘道回 AUTHENTICATION_FAILED（PSK 或帳密錯）" auth "${INIT}[IKE] authentication of 'user01' (myself) with pre-shared key\n[ENC] parsed IKE_AUTH response 1 [ N(AUTH_FAILED) ]\n[IKE] received AUTHENTICATION_FAILED notify error\n${FAILED_TAIL}"
expect "EAP 失敗（帳號密碼錯）" auth "${INIT}[IKE] received EAP_FAILURE, EAP authentication failed\n${FAILED_TAIL}"
expect "PSK MAC 不符（本機 PSK 跟閘道不同）" auth "${INIT}[IKE] tried 1 shared key for '203.0.113.10' - 'user01', but MAC mismatched\n${FAILED_TAIL}"
expect "沒有可用的 PSK" auth "${INIT}[IKE] no shared key found for 'user01' - '203.0.113.10'\n${FAILED_TAIL}"
expect "XAuth 驗證失敗" auth "${INIT}[IKE] XAuth authentication of 'user01' (myself) failed\n${FAILED_TAIL}"
expect "IKE 加密參數不符" proposal "${INIT}[IKE] received NO_PROPOSAL_CHOSEN notify error\n${FAILED_TAIL}"
expect "CHILD 加密參數不符（本機選不到）" proposal "${INIT}[IKE] no acceptable proposal found\n[IKE] received proposals unacceptable\n${FAILED_TAIL}"
expect "網段不被接受" ts "${INIT}[IKE] received TS_UNACCEPTABLE notify, no CHILD_SA built\n${FAILED_TAIL}"
expect "本機找不到可接受的網段" ts "${INIT}[CFG] no acceptable traffic selectors found\n${FAILED_TAIL}"
expect "閘道沒回應（重送放棄）" unreachable "${INIT}[IKE] retransmit 1 of request with message ID 0\n[IKE] retransmit 2 of request with message ID 0\n[IKE] giving up after 3 retransmits\n[IKE] establishing IKE_SA failed, peer not responding\n${FAILED_TAIL}"
expect "閘道位址解析不到" unreachable "[IKE] unable to resolve vpn.example.invalid, initiate aborted\n${FAILED_TAIL}"
expect "送不出封包（沒有路由）" unreachable "${INIT}[NET] error writing to socket: No route to host\n${FAILED_TAIL}"
expect "swanctl --timeout 到了" timeout "${INIT}[IKE] retransmit 2 of request with message ID 1\ninitiate failed: CHILD_SA 'corp' not established after 20000ms\n"
expect "charon 沒在跑（無法辨識）" unknown "connecting to 'unix:///var/run/charon.vici' failed: No such file or directory\nError: connecting to 'default' URI failed: No such file or directory\n"
expect "只有一般失敗訊息" unknown "${INIT}${FAILED_TAIL}"
expect "空輸出" unknown ""
expect "驗證失敗優先於重送訊息" auth "${INIT}[IKE] retransmit 1 of request with message ID 1\n[IKE] received AUTHENTICATION_FAILED notify error\n${FAILED_TAIL}"
expect "成功的驗證訊息不算驗證失敗" unreachable "[IKE] authentication of '203.0.113.10' with pre-shared key successful\n[IKE] giving up after 3 retransmits\n"

# ---- 2. 整支 helper 跑 up（swanctl／charon 換成假程式） ----
mkdir -p "$RUN/bin"
cat >"$RUN/bin/charon" <<'EOF'
#!/bin/bash
exit 0
EOF
# 假 swanctl：--initiate 依 FAKE_MODE 決定結果，輸出刻意含帳號與位址，用來驗證不外流
cat >"$RUN/bin/swanctl" <<'EOF'
#!/bin/bash
case "$*" in
  *--initiate*)
    ike=$(printf '%s\n' "$@" | awk 'prev=="--ike"{print} {prev=$0}')
    case "${FAKE_MODE:-auth}:$ike" in
      ok:*|mixed:vpn3) echo "[IKE] IKE_SA $ike[1] established between 192.0.2.5[user01]...203.0.113.10[203.0.113.10]"; echo "initiate completed successfully"; exit 0 ;;
      auth:*|mixed:vpn1) echo "[IKE] authentication of 'user01' (myself) with EAP successful"; echo "[IKE] received AUTHENTICATION_FAILED notify error"; echo "initiate failed: establishing CHILD_SA 'corp' failed"; exit 1 ;;
      *) echo "[IKE] giving up after 3 retransmits"; echo "[IKE] establishing IKE_SA failed, peer not responding (203.0.113.20)"; exit 1 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
chmod 755 "$RUN/bin/charon" "$RUN/bin/swanctl"
sed -e "s#^SWANCTL=.*#SWANCTL=$RUN/bin/swanctl#" -e "s#^CHARON=.*#CHARON=$RUN/bin/charon#" "$SRC" >"$RUN/helper"
grep -q "^SWANCTL=$RUN/bin/swanctl\$" "$RUN/helper"; check "副本的 swanctl 已換成假程式（正對照）" $?

out=$(FAKE_MODE=auth bash "$RUN/helper" up 2); rc=$?
[ "$rc" = 1 ] && [ "$out" = "$(printf 'reason vpn2 auth\nfail vpn2')" ]; check "up 2 驗證失敗：reason vpn2 auth ＋ fail vpn2，結束代碼 1（實際：$(echo $out)）" $?
printf '%s\n' "$out" | grep -qx 'fail vpn2'; check "舊版 App 認的「fail vpn2」整行仍在" $?
! printf '%s\n' "$out" | grep -qE 'user01|203\.0\.113|192\.0\.2'; check "輸出不含帳號與位址" $?

out=$(FAKE_MODE=ok bash "$RUN/helper" up 1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "ok vpn1" ]; check "up 1 成功：只有 ok vpn1（實際：${out}）" $?

out=$(FAKE_MODE=mixed bash "$RUN/helper" up auto); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf 'reason vpn1 auth\nreason vpn2 unreachable\nok vpn3')" ]; check "up auto：前兩台各一行原因，第三台成功（實際：$(echo $out)）" $?

out=$(FAKE_MODE=down bash "$RUN/helper" up auto); rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "fail all" ] && [ "$(printf '%s\n' "$out" | grep -c '^reason vpn[123] unreachable$')" = 3 ]
check "up auto 全部失敗：三行原因＋fail all" $?

out=$(bash "$RUN/helper" up 4 2>&1); rc=$?
[ "$rc" = 2 ]; check "up 4 仍拒絕（結束代碼 2）" $?

echo "通過 ${pass}，失敗 ${fail}"
[ "$fail" = 0 ]
