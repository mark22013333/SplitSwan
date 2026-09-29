#!/bin/bash
# 連線狀態診斷：自動連上 VPN → 收集路由／DNS／SA 資訊 → 自動斷線。
# 連線期間 Claude Code 等外部服務可能無法使用，所以整段不需要人操作，跑完就恢復。
#   bash diag.sh [1|2|3]     預設 1
# 結果寫到 diag-<時間>.txt（已 gitignore），不含 PSK／密碼。
set -uo pipefail
cd "$(dirname "$0")"

H="sudo -n /usr/local/libexec/splitswan-helper"
T="${1:-1}"
OUT="diag-$(date +%Y%m%d-%H%M%S).txt"

# 要測的公司目標：從目前的通道網段（swanctl.conf 的 remote_ts）推出來。
#   /32 直接測該 IP；其他網段測第一個可用位址（.1）。也可以用 DIAG_TARGETS="ip1 ip2" 自己指定。
targets_from_conf() {
  local ts
  ts=$(grep -m1 -E '^[[:space:]]*remote_ts[[:space:]]*=' /opt/homebrew/etc/swanctl/swanctl.conf 2>/dev/null | sed 's/.*=//; s/#.*//; s/,/ /g')
  for cidr in $ts; do
    local ip=${cidr%/*} mask=${cidr#*/}
    [ "$mask" = "0" ] && continue
    if [ "$mask" = "32" ]; then echo "$ip"; else echo "${ip%.*}.$(( ${ip##*.} + 1 ))"; fi
  done
}
TARGETS="${DIAG_TARGETS:-$(targets_from_conf | tr '\n' ' ')}"

sec() { printf '\n===== %s =====\n' "$1"; }
probe() {  # 對外連線探測：DNS 與 HTTPS 各一次，各限時 5 秒
  sec "DNS 解析 api.anthropic.com"
  dscacheutil -q host -a name api.anthropic.com 2>&1 | head -5
  sec "直接問 168.95.1.1"
  dig +time=3 +tries=1 @168.95.1.1 api.anthropic.com +short 2>&1 | head -3
  sec "HTTPS api.anthropic.com"
  curl -sS -o /dev/null -w 'http=%{http_code} time=%{time_total}s\n' --max-time 5 https://api.anthropic.com 2>&1
  sec "不可切割的 ping（找出封包大小上限，-s 為資料長度，實際封包再加 28 bytes）"
  for size in 500 1000 1200 1252 1300 1372 1400 1472; do
    if ping -c 1 -D -s "$size" -t 3 168.95.1.1 >/dev/null 2>&1; then r=通; else r=不通; fi
    echo "  $size → $r"
  done
}

{
  echo "診斷時間：$(date '+%F %T')  目標：vpn$T"
  sec "連線前：預設路由"; netstat -rn -f inet | grep -E '^default|^0/1|^128.0/1'
  probe

  sec "執行 up $T"; $H up "$T"; echo "exit=$?"
  sleep 3

  sec "helper status"; $H status
  sec "swanctl --list-sas"; $H sas
  sec "連線後：IPv4 路由表"; netstat -rn -f inet
  sec "連線後：scutil --dns（前 40 行）"; scutil --dns | head -40
  sec "連線後：DNS 主設定"; scutil <<< "show State:/Network/Global/DNS"
  probe
  sec "公司目標：走哪個介面、連不連得到（utun = 走 VPN，en0 = 走一般網路）"
  for ip in $TARGETS; do
    ifc=$(route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2}')
    p22=$(nc -z -G 3 "$ip" 22 >/dev/null 2>&1 && echo 通 || echo 不通)
    p443=$(nc -z -G 3 "$ip" 443 >/dev/null 2>&1 && echo 通 || echo 不通)
    echo "  $ip  介面=${ifc:-?}  22=${p22}  443=${p443}"
  done

  sec "charon 最近 2 分鐘 log（Mode Config／traffic selector 相關）"
  log show --last 2m --predicate 'process == "charon"' --style compact 2>/dev/null \
    | grep -iE 'attribute|INTERNAL_|split|traffic selector|TS|installing|virtual IP|DNS|unity|narrow' | tail -60

  sec "執行 down"; $H down
  sleep 2
  sec "斷線後：預設路由"; netstat -rn -f inet | grep -E '^default|^0/1|^128.0/1'
  probe
} >"$OUT" 2>&1

echo "診斷完成，已斷線。結果：$(pwd)/$OUT"
