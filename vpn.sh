#!/usr/bin/env bash
# 公司 VPN 快捷指令（strongSwan）
#   vpn up        依序嘗試 vpn1 → vpn2 → vpn3，連上第一台就停
#   vpn up 2      只連指定的那台
#   vpn down      斷線
#   vpn status    查看目前連線
#   vpn log       即時看 charon log（排查用）
set -uo pipefail

CONNS=(vpn1 vpn2 vpn3)
PREFIX="$(brew --prefix strongswan)"
CHARON="$PREFIX/libexec/ipsec/charon"

# 確認 charon daemon 在跑，沒有就背景啟動並載入設定
ensure_charon() {
  sudo -v || exit 1   # 先在前景取得 sudo 授權，背景啟動時才不會卡在密碼提示
  if ! pgrep -x charon >/dev/null; then
    echo "啟動 charon…"
    sudo nohup "$CHARON" >/dev/null 2>&1 &   # nohup：關掉終端機後 charon 繼續跑
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sudo swanctl --stats >/dev/null 2>&1 && break
      sleep 0.5
    done
  fi
  sudo swanctl --load-all --noprompt >/dev/null
}

try_conn() {
  local c=$1
  echo "嘗試 ${c}…"
  if sudo swanctl --initiate --child corp --ike "$c" --timeout 20 >/dev/null 2>&1; then
    echo "✅ 已連上 $c"
    return 0
  fi
  echo "❌ $c 連線失敗"
  sudo swanctl --terminate --ike "$c" --force >/dev/null 2>&1
  return 1
}

case "${1:-status}" in
  up)
    ensure_charon
    if [ -n "${2:-}" ]; then
      try_conn "vpn$2"; exit $?
    fi
    for c in "${CONNS[@]}"; do
      try_conn "$c" && exit 0
    done
    echo "三台都連不上，用 'vpn log' 看原因"; exit 1
    ;;
  down)
    for c in "${CONNS[@]}"; do
      sudo swanctl --terminate --ike "$c" --force >/dev/null 2>&1
    done
    echo "已斷線"
    ;;
  status)
    sudo swanctl --list-sas
    ;;
  log)
    ensure_charon
    sudo swanctl --log
    ;;
  *)
    echo "用法：vpn {up [1|2|3]|down|status|log}"; exit 2
    ;;
esac
