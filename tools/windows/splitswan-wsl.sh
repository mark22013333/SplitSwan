#!/usr/bin/env bash
# SplitSwan Windows 實驗版：WSL2 內的 Linux 端（以 root 執行）
# 由 splitswan-wsl.ps1 呼叫，不要直接在 Windows 以外的地方使用。
#
# 用法：
#   splitswan-wsl.sh setup                 確認 systemd、安裝 strongSwan（回傳 10 代表要重啟 WSL）
#   splitswan-wsl.sh connect <設定目錄>     安裝設定、依序嘗試 vpn1..N、開啟轉發與 SNAT
#   splitswan-wsl.sh disconnect            中斷所有 SA、清掉 SNAT／MSS 規則
#   splitswan-wsl.sh status                顯示 SA 與規則
#   splitswan-wsl.sh brief                 只讀 SA 狀態，輸出 @@STATE／@@GATEWAY／@@VIP（不改任何狀態）
#
# 給 PowerShell 解析的結果一律以「@@KEY=值」單獨一行輸出。

set -u
# stderr 併入 stdout：PowerShell 只收一條管線，錯誤訊息和一般輸出的先後順序不會亂，
# PowerShell 5.1 也不會把 stderr 每一行包成 NativeCommandError
exec 2>&1

SWANCTL_DIR=/etc/swanctl
CHAIN=SPLITSWAN
# eap-mschapv2 在 extauth、openssl（ecp384、MD4）在 standard，兩者平常只靠 Recommends 帶進來，明列以免漏裝
PACKAGES=(strongswan-swanctl charon-systemd libcharon-extauth-plugins libstrongswan-standard-plugins
          libcharon-extra-plugins iptables)
# swanctl 沒設定 swanctl.load 時，會載入編譯期的預設清單（strongSwan configure.ac 標 s 的外掛，順序照原檔）。
# Ubuntu 把外掛拆成多個套件，沒裝的 libstrongswan-extra-plugins 那幾個每次都會印「failed to load」。
# setup 只保留實際裝了 .so 的，寫進 swanctl.load；charon 走 load_modular，不受這個設定影響。
SWANCTL_PLUGINS=(test-vectors unbound ldap pkcs11 aesni aes des blowfish rc2 sha2 sha3 sha1 md4 md5 mgf1
                 rdrand random nonce x509 revocation constraints acert pubkey pkcs1 pkcs7 pkcs12 pgp dnskey
                 sshkey pem padlock openssl wolfssl gcrypt botan pkcs8 af-alg fips-prf gmp curve25519 agent
                 keychain chapoly xcbc cmac hmac kdf ctr ccm gcm ntru drbg newhope bliss curl files winhttp
                 soup mysql sqlite openxpki)
PLUGIN_DIR=/usr/lib/ipsec/plugins
SWANCTL_LOAD_CONF=/etc/strongswan.d/zz-splitswan-swanctl.conf

log()  { printf '[WSL] %s\n' "$*"; }
fail() { printf '[WSL] 錯誤：%s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "需要以 root 執行"

# charon 的 systemd unit 名稱因版本而異
unit_name() {
    local u
    for u in strongswan.service strongswan-swanctl.service; do
        if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
            echo "$u"; return 0
        fi
    done
    return 1
}

# 從 swanctl.conf 取出 remote_ts（逗號分隔，去空白）
remote_ts() {
    grep -E '^[[:space:]]*remote_ts[[:space:]]*=' "$SWANCTL_DIR/swanctl.conf" | head -n 1 \
        | sed -E 's/^[^=]*=//; s/#.*$//; s/[[:space:]]//g'
}

# 列出設定檔裡的連線名稱（vpn1、vpn2…）
gateways() {
    grep -oE '^[[:space:]]*vpn[0-9]+[[:space:]]*\{' "$SWANCTL_DIR/swanctl.conf" | grep -oE 'vpn[0-9]+'
}

ip2int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# 兩個 CIDR 是否重疊：用較短的前綴遮罩比對網路位址
cidr_overlap() {
    local n1=${1%/*} p1=${1#*/} n2=${2%/*} p2=${2#*/}
    [ "$p1" = "$1" ] && p1=32
    [ "$p2" = "$2" ] && p2=32
    local p=$(( p1 < p2 ? p1 : p2 ))
    local mask=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
    [ $(( $(ip2int "$n1") & mask )) -eq $(( $(ip2int "$n2") & mask )) ]
}

# 從 swanctl --list-sas 的 local 行取出虛擬 IP（行尾中括號內的 IPv4；[4500] 這種埠號不會符合）
parse_vip() {
    sed -nE 's/^[[:space:]]*local[[:space:]].*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\][[:space:]]*$/\1/p' | head -n 1
}

# 把 swanctl.load 設成「預設清單中實際裝了的外掛」；找不到任何外掛就不寫，維持 swanctl 預設行為
write_swanctl_load() {
    local p load=()
    for p in "${SWANCTL_PLUGINS[@]}"; do
        [ -f "$PLUGIN_DIR/libstrongswan-$p.so" ] && load+=("$p")
    done
    if [ "${#load[@]}" -eq 0 ]; then
        log "警告：$PLUGIN_DIR 裡找不到外掛，不設定 swanctl.load"
        return 0
    fi
    local content
    content=$(printf '# 由 SplitSwan 產生：只載入已安裝的外掛，避免 swanctl 每次印 failed to load\nswanctl {\n    load = %s\n}\n' "${load[*]}")
    if [ "$(cat "$SWANCTL_LOAD_CONF" 2>/dev/null)" != "$content" ]; then
        printf '%s\n' "$content" > "$SWANCTL_LOAD_CONF"
        log "已設定 swanctl 只載入已安裝的外掛（${SWANCTL_LOAD_CONF}）"
    fi
}

# 從 swanctl --list-sas 的輸出判斷狀態：第一個 ESTABLISHED 且 child corp 為 INSTALLED 的 IKE_SA 算連上
#   vpn1: #1, ESTABLISHED, IKEv2, ...           ← IKE_SA（行首不縮排）
#     local  'x' @ 192.0.2.5[4500] [198.51.100.7]  ← 行尾中括號內的 IPv4 是虛擬 IP（[4500] 是埠號，不含點）
#     corp: #1, reqid 1, INSTALLED, ...          ← CHILD_SA
parse_brief() {
    awk '
        function flush() {
            if (!found && name != "" && est && child) {
                found = 1
                print "@@STATE=up"
                print "@@GATEWAY=" name
                if (vip != "") print "@@VIP=" vip
            }
        }
        /^[A-Za-z0-9_.-]+: #[0-9]+, / {
            flush()
            name = $1; sub(/:$/, "", name)
            est = ($3 == "ESTABLISHED,")
            child = 0; vip = ""
            next
        }
        /^  local[[:space:]]/ && vip == "" {
            if (match($0, /\[[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\]/)) vip = substr($0, RSTART + 1, RLENGTH - 2)
            next
        }
        /^  corp: #[0-9]+, / {
            if ($0 ~ /, INSTALLED,/) child = 1
            next
        }
        END {
            flush()
            if (!found) print "@@STATE=down"
        }
    '
}

cmd_setup() {
    local need_restart=0

    if ! grep -qE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf 2>/dev/null; then
        log "寫入 /etc/wsl.conf 開啟 systemd"
        if [ -f /etc/wsl.conf ] && grep -q '^\[boot\]' /etc/wsl.conf; then
            sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
        else
            printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
        fi
        need_restart=1
    fi
    if [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]; then
        need_restart=1
    fi
    if [ "$need_restart" -eq 1 ]; then
        echo "@@RESTART=1"
        exit 10
    fi

    local missing=()
    local p
    for p in "${PACKAGES[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        log "安裝套件：${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q || fail "apt-get update 失敗"
        apt-get install -y -q "${missing[@]}" || fail "套件安裝失敗"
    else
        log "套件都已安裝"
    fi

    # WSL 6.6 核心的 XFRM_USER／ESP／xt_nat 是模組，要 WSL 2.3.11 以上的 modules.vhd 才載得到
    echo "@@KERNEL=$(uname -r)"
    if modprobe -a xfrm_user esp4 xt_nat nft_compat 2>&1 | sed 's/^/[WSL]   /'; [ "${PIPESTATUS[0]}" -eq 0 ]; then
        log "核心模組 xfrm_user esp4 xt_nat nft_compat 已載入"
    else
        log "警告：核心模組載入失敗，請在 Windows 執行 wsl --update --web-download 後重試；仍失敗就要改用 kernel-libipsec"
        echo "@@MODULES=fail"
    fi

    unit_name >/dev/null || fail "找不到 strongSwan 的 systemd 服務"
    write_swanctl_load
    echo "@@SETUP=ok"
}

cmd_connect() {
    local src=${1:-}
    [ -n "$src" ] || fail "缺少設定目錄參數"
    [ -f "$src/swanctl.conf" ] || fail "找不到 $src/swanctl.conf"
    [ -f "$src/secrets.conf" ] || fail "找不到 $src/secrets.conf"

    install -m 644 "$src/swanctl.conf" "$SWANCTL_DIR/swanctl.conf"
    install -d -m 755 "$SWANCTL_DIR/conf.d"
    install -m 600 "$src/secrets.conf" "$SWANCTL_DIR/conf.d/secrets.conf"
    # Windows 上複製或用記事本改過的檔案可能有 BOM 與 CRLF
    sed -i '1s/^\xEF\xBB\xBF//; s/\r$//' "$SWANCTL_DIR/swanctl.conf" "$SWANCTL_DIR/conf.d/secrets.conf"

    local ts
    ts=$(remote_ts)
    [ -n "$ts" ] || fail "swanctl.conf 裡找不到 remote_ts"

    # WSL 與 Windows 之間的網段、Windows 端位址（WSL 的預設閘道）；連線前取，避免拿到虛擬 IP
    local wsl_ip subnet host_ip
    wsl_ip=$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 | head -n 1)
    subnet=$(ip -4 route show dev eth0 proto kernel scope link | awk '{print $1}' | head -n 1)
    host_ip=$(ip -4 route show default | awk '{print $3}' | head -n 1)
    [ -n "$wsl_ip" ] && [ -n "$subnet" ] && [ -n "$host_ip" ] || fail "讀不到 eth0 位址或預設閘道（需要 WSL 的 NAT 網路模式）"

    # 內網網段若和 WSL 網段重疊，通道路由會搶走 WSL↔Windows 的流量
    local net nets=()
    IFS=',' read -r -a nets <<< "$ts"
    for net in "${nets[@]}"; do
        case "$net" in ''|*:*) continue ;; esac
        if cidr_overlap "$net" "$subnet"; then
            fail "內網網段 $net 與 WSL 網段 $subnet 重疊，請在 %UserProfile%\\.wslconfig 的 [wsl2] 設定其他 NAT 網段後重開 WSL"
        fi
    done

    local unit
    unit=$(unit_name) || fail "找不到 strongSwan 的 systemd 服務，請先跑 setup"
    local since
    since=$(date '+%Y-%m-%d %H:%M:%S')
    log "重啟 $unit"
    systemctl restart "$unit" || fail "無法啟動 $unit"
    # 等 vici socket 起來
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        swanctl --stats >/dev/null 2>&1 && break
        sleep 1
    done
    local plugins plugin
    plugins=$(swanctl --stats 2>/dev/null)
    for plugin in eap-mschapv2 openssl; do
        grep -qw -- "$plugin" <<< "$plugins" || log "警告：loaded plugins 裡沒有 $plugin，IKE 協商可能會失敗"
    done
    swanctl --load-all || fail "swanctl --load-all 失敗，請檢查設定檔"

    local gw vip="" used=""
    for gw in $(gateways); do
        log "嘗試 $gw …"
        if swanctl --initiate --ike "$gw" --child corp --timeout 30; then
            vip=$(swanctl --list-sas --ike "$gw" | parse_vip)
            used=$gw
            break
        fi
        log "$gw 失敗，換下一台"
        swanctl --terminate --ike "$gw" --force --timeout 5 >/dev/null 2>&1 || true
    done
    [ -n "$used" ] || fail "所有閘道都連線失敗（詳細記錄：journalctl -u $unit -n 80）"
    [ -n "$vip" ] || fail "$used 已連線但拿不到虛擬 IP"
    log "已連上 $used，虛擬 IP $vip"

    # 轉發＋SNAT：FortiGate 只收來源為虛擬 IP 的封包（local_ts = dynamic）
    sysctl -q -w net.ipv4.ip_forward=1
    # 封包從 eth0 進、又從 eth0 出，不關掉的話 Linux 會送 ICMP redirect 叫 Windows 改走自己，繞過通道
    sysctl -q -w net.ipv4.conf.all.send_redirects=0
    sysctl -q -w net.ipv4.conf.eth0.send_redirects=0
    iptables -t nat -N "$CHAIN" 2>/dev/null || true
    iptables -t nat -F "$CHAIN"
    iptables -t nat -C POSTROUTING -j "$CHAIN" 2>/dev/null || iptables -t nat -A POSTROUTING -j "$CHAIN"
    # 經過 Windows NAT＋ESP 封裝後 MTU 變小，壓低 TCP MSS 避免大封包卡住
    iptables -t mangle -N "$CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$CHAIN"
    iptables -t mangle -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -t mangle -A FORWARD -j "$CHAIN"
    # 明確放行轉發（同一個 VM 若裝了 Docker，FORWARD 預設政策會是 DROP）
    iptables -N "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN"
    iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD 1 -j "$CHAIN"

    for net in "${nets[@]}"; do
        case "$net" in ''|*:*) continue ;; esac   # 略過 IPv6
        iptables -t nat -A "$CHAIN" -s "$subnet" -d "$net" -j SNAT --to-source "$vip"
        # 去程 SYN 與回程 SYN-ACK 都夾，上傳與下載兩個方向的 segment 都不會超過通道 MTU
        iptables -t mangle -A "$CHAIN" -s "$subnet" -d "$net" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
        iptables -t mangle -A "$CHAIN" -s "$net" -d "$subnet" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
        iptables -A "$CHAIN" -s "$subnet" -d "$net" -j ACCEPT
        iptables -A "$CHAIN" -s "$net" -d "$subnet" -j ACCEPT
    done

    # 內部 DNS（strongSwan 的 resolve 外掛會在日誌留下 installing DNS server x.x.x.x），只看這次重啟後的日誌
    local dns
    dns=$(journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null \
        | grep -oE 'installing DNS server [0-9.]+' | awk '{print $4}' | sort -u | paste -sd, -)

    echo "@@GATEWAY=$used"
    echo "@@VIP=$vip"
    echo "@@WSLIP=$wsl_ip"
    echo "@@HOSTIP=$host_ip"
    echo "@@SUBNET=$subnet"
    echo "@@TS=$ts"
    echo "@@DNS=$dns"
}

cmd_disconnect() {
    local gw
    if [ -f "$SWANCTL_DIR/swanctl.conf" ]; then
        for gw in $(gateways); do
            swanctl --terminate --ike "$gw" --timeout 10 >/dev/null 2>&1 || true
        done
    fi
    iptables -t nat -F "$CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" 2>/dev/null || true
    log "已中斷並清除 SNAT／MSS／FORWARD 規則"
}

# 每 15 秒輪詢用：只讀不寫。swanctl 查得到結果才判斷 up／down；
# 查不到時，charon 服務確定沒在跑才算 down，其他情況回 unknown（不代表斷線）
cmd_brief() {
    local sas unit
    if sas=$(swanctl --list-sas 2>/dev/null); then
        parse_brief <<< "$sas"
        return 0
    fi
    if unit=$(unit_name) && ! systemctl is-active --quiet "$unit"; then
        echo "@@STATE=down"
    else
        echo "@@STATE=unknown"
        echo "@@ERROR=swanctl --list-sas 失敗"
    fi
}

cmd_status() {
    swanctl --list-sas 2>&1 || true
    echo "--- SNAT ---"
    iptables -t nat -S "$CHAIN" 2>&1 || true
    echo "--- FORWARD ---"
    iptables -S FORWARD 2>&1 || true
    iptables -S "$CHAIN" 2>&1 || true
    echo "--- ip_forward ---"
    sysctl net.ipv4.ip_forward
}

case "${1:-}" in
    setup)      cmd_setup ;;
    connect)    shift; cmd_connect "${1:-}" ;;
    disconnect) cmd_disconnect ;;
    status)     cmd_status ;;
    brief)      cmd_brief ;;
    *)          fail "未知指令：${1:-（空）}" ;;
esac
