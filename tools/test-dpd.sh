#!/bin/bash
# F1 實測：暫時擋住所有閘道，量「偵測失聯」「退避重試」與「解除後恢復」（規格 Q1、Q6）。
#   sudo bash tools/test-dpd.sh [封鎖秒數，預設 120]
# 前提：SplitSwan 已連線、「連線意圖」為開啟（按過連線）。
# 擋的是 swanctl.conf 裡所有閘道的 IKE（UDP 500／4500）與 ESP，其他網路不受影響；
# 腳本結束（含 Ctrl-C）一定會移除規則。
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "請用 sudo 執行"; exit 1; }

HOLD="${1:-120}"
H=/usr/local/libexec/splitswan-helper
CONF=/opt/homebrew/etc/swanctl/swanctl.conf
ANCHOR="com.apple/splitswan-test"   # macOS 預設的 pf.conf 會評估 com.apple/* 底下的 anchor

st() { "$H" status 2>/dev/null; }
key() { echo "$1" | awk '{print $1, $2, $3}'; }   # 狀態比對只看前三欄（已建立秒數每秒都在變）
now() { date +%s; }

line=$(st)
case "$line" in connected*) ;; *) echo "目前沒有連線（$line），請先用 SplitSwan 連線"; exit 1 ;; esac
# 封鎖所有閘道，否則 App 會輪替到別台而量不到退避
GWS=$(grep -E '^[[:space:]]*remote_addrs[[:space:]]*=' "$CONF" | sed 's/.*=//; s/#.*//' | tr -d ' ' | sort -u | tr '\n' ' ')
[ -n "$GWS" ] || { echo "讀不到閘道位址"; exit 1; }
echo "目前：$line"
echo "封鎖 $(echo $GWS | wc -w | tr -d ' ') 台閘道 ${HOLD} 秒"

TOKEN=""
cleanup() {
  pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
  [ -n "$TOKEN" ] && pfctl -X "$TOKEN" >/dev/null 2>&1
  echo "（已移除封鎖規則）"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

TOKEN=$(pfctl -E 2>&1 | awk '/Token/{print $NF}')
RULES=""
for g in $GWS; do
  RULES+="block drop out quick proto udp to $g port { 500, 4500 }"$'\n'"block drop out quick proto esp to $g"$'\n'
done
printf '%s' "$RULES" | pfctl -a "$ANCHOR" -f - 2>/dev/null || { echo "載入封鎖規則失敗"; exit 1; }
# pf 會放行已存在連線狀態的封包，先清掉往閘道的既有狀態，封鎖才會立即生效
for g in $GWS; do pfctl -k 0.0.0.0/0 -k "$g" >/dev/null 2>&1; done

T0=$(now); lost=""; last=$(key "$line"); attempts=0
echo "$(date +%T) 開始封鎖"
while [ $(( $(now) - T0 )) -lt "$HOLD" ]; do
  s=$(st); k=$(key "$s")
  if [ "$k" != "$last" ]; then
    echo "$(date +%T) +$(( $(now) - T0 ))s  $k"
    case "$k" in connecting*) attempts=$((attempts + 1)) ;; esac
    last="$k"
  fi
  case "$s" in connected*) ;; *) [ -z "$lost" ] && lost=$(( $(now) - T0 )) ;; esac
  sleep 1
done

pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
T1=$(now); back=""
echo "$(date +%T) 解除封鎖，等待自動恢復（最多 120 秒）"
while [ $(( $(now) - T1 )) -lt 120 ]; do
  s=$(st); k=$(key "$s")
  if [ "$k" != "$last" ]; then echo "$(date +%T) +$(( $(now) - T1 ))s  $k"; last="$k"; fi
  case "$s" in connected*) back=$(( $(now) - T1 )); break ;; esac
  sleep 1
done

echo
echo "===== 結果 ====="
echo "偵測到失聯：${lost:-封鎖期間都沒偵測到} 秒（規格預估約 26 秒）"
echo "封鎖期間看到的連線嘗試：${attempts} 次（輪詢每秒一次，較短的嘗試可能漏看；退避間隔預期 5、15、30、60 秒）"
echo "解除後恢復連線：${back:-120 秒內沒恢復} 秒"
