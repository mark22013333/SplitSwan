import Foundation
// 「某台公司主機連不上？」一鍵檢查的純邏輯：輸入解析、IP 抽取、網段涵蓋、結果文字
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
typealias T = HostCheck.Target

// MARK: 輸入解析
check("純網域", HostCheck.parseTarget("intranet.example.com") == T(host: "intranet.example.com", port: nil))
check("前後空白、大寫轉小寫", HostCheck.parseTarget("  Intranet.Example.COM \n") == T(host: "intranet.example.com", port: nil))
check("host:port", HostCheck.parseTarget("db.example.com:3306") == T(host: "db.example.com", port: 3306))
check("URL 去掉 scheme、帳號、路徑、查詢字串", HostCheck.parseTarget("https://user:pw@git.example.com:8443/a/b?x=1#y") == T(host: "git.example.com", port: 8443))
check("URL 無連接埠", HostCheck.parseTarget("http://wiki.example.com/page") == T(host: "wiki.example.com", port: nil))
check("直接輸入 IP", HostCheck.parseTarget("198.51.100.7") == T(host: "198.51.100.7", port: nil))
check("IP:port", HostCheck.parseTarget("198.51.100.7:22") == T(host: "198.51.100.7", port: 22))
check("拒絕：空字串", HostCheck.parseTarget("   ") == nil)
check("拒絕：中間有空白", HostCheck.parseTarget("a b.example.com") == nil)
check("拒絕：換行注入", HostCheck.parseTarget("a.example.com\n}") == nil)
check("拒絕：大括號", HostCheck.parseTarget("a{.example.com") == nil)
check("拒絕：分號、反引號", HostCheck.parseTarget("a.com;ls") == nil && HostCheck.parseTarget("a`x`.com") == nil)
check("拒絕：全形數字 IP", HostCheck.parseTarget("１98.51.100.7") == nil)
check("拒絕：不完整的 IP", HostCheck.parseTarget("198.51.100") == nil)
check("拒絕：IP 超過 255", HostCheck.parseTarget("198.51.100.256") == nil)
check("拒絕：連接埠 0、70000、非數字、全形", HostCheck.parseTarget("a.com:0") == nil && HostCheck.parseTarget("a.com:70000") == nil
      && HostCheck.parseTarget("a.com:http") == nil && HostCheck.parseTarget("a.com:４43") == nil)
check("拒絕：IPv6 字面值", HostCheck.parseTarget("[2001:db8::1]:443") == nil)
check("拒絕：開頭是連字號（不能被當成指令選項）", HostCheck.parseTarget("-oProxy.example.com") == nil)

// MARK: dscacheutil 輸出
let ds = "name: intranet.example.com\nip_address: 198.51.100.7\n\nname: intranet.example.com\nip_address: 198.51.100.8\nip_address: 198.51.100.7\n\nname: intranet.example.com\nipv6_address: 2001:db8::1\n"
check("抽出 IPv4、去重、保留順序、略過 IPv6", HostCheck.ipv4s(fromDscacheutil: ds) == ["198.51.100.7", "198.51.100.8"])
check("沒有結果 → 空", HostCheck.ipv4s(fromDscacheutil: "") == [])

// MARK: 網段涵蓋
check("/24 涵蓋", HostCheck.contains(cidr: "203.0.113.0/24", ip: "203.0.113.254"))
check("/24 不涵蓋鄰近網段", !HostCheck.contains(cidr: "203.0.113.0/24", ip: "203.0.114.1"))
check("/32 只涵蓋自己", HostCheck.contains(cidr: "198.51.100.7/32", ip: "198.51.100.7") && !HostCheck.contains(cidr: "198.51.100.7/32", ip: "198.51.100.8"))
check("/26 邊界", HostCheck.contains(cidr: "203.0.113.64/26", ip: "203.0.113.127") && !HostCheck.contains(cidr: "203.0.113.64/26", ip: "203.0.113.128"))
check("/0 與格式錯誤一律不算涵蓋", !HostCheck.contains(cidr: "0.0.0.0/0", ip: "198.51.100.7") && !HostCheck.contains(cidr: "abc", ip: "198.51.100.7"))
check("找出涵蓋的網段（逗號分隔）", HostCheck.coveringSubnet(ip: "203.0.113.70", in: "198.51.100.7/32, 203.0.113.64/26") == "203.0.113.64/26")
check("找出涵蓋的網段（換行分隔）", HostCheck.coveringSubnet(ip: "198.51.100.7", in: "203.0.113.64/26\n198.51.100.7/32") == "198.51.100.7/32")
check("沒有涵蓋 → nil", HostCheck.coveringSubnet(ip: "198.51.100.9", in: "198.51.100.7/32") == nil)

// MARK: 公網判斷
check("RFC 1918 是私有", HostCheck.isPrivate("10.1.2.3") && HostCheck.isPrivate("172.31.255.1") && HostCheck.isPrivate("192.168.0.1"))
check("172.32、RFC 5737 不是私有", !HostCheck.isPrivate("172.32.0.1") && !HostCheck.isPrivate("198.51.100.7"))

// MARK: 提議
check("已涵蓋的不重複提議", HostCheck.proposal(ips: ["203.0.113.70", "198.51.100.7"], existing: "203.0.113.64/26") == ["198.51.100.7/32"])
check("全部涵蓋 → 空", HostCheck.proposal(ips: ["203.0.113.70"], existing: "203.0.113.64/26") == [])

// MARK: 結果文字
let rep = HostCheck.report(target: T(host: "git.example.com", port: 443),
                           results: [HostCheck.IPResult(ip: "198.51.100.7", interface: "utun6", viaTunnel: true, portOK: false)],
                           added: ["198.51.100.7/32"], vpnIP: "203.0.113.200")
check("結果含主機與連接埠", rep.contains("git.example.com") && rep.contains("連接埠 443"))
check("結果含介面與 TCP 結果", rep.contains("utun6") && rep.contains("有走 VPN") && rep.contains("TCP 443 連不上"))
check("結果含新增網段與 VPN 位址", rep.contains("198.51.100.7/32") && rep.contains("203.0.113.200"))

// MARK: 目前通道的網段（swanctl --list-sas）與路由建議
let sas = """
vpn1: #3, ESTABLISHED, IKEv2, 0123456789abcdef_i* fedcba9876543210_r
  local  'user01' @ 192.0.2.5[4500] [10.0.0.77]
  remote '203.0.113.10' @ 203.0.113.10[4500]
  established 12s ago, rekeying in 10000s
  corp: #4, reqid 1, INSTALLED, TUNNEL-in-UDP, ESP:AES_CBC-256/HMAC_SHA2_256_128
    in  c1234567,      0 bytes,     0 packets
    out c7654321,      0 bytes,     0 packets
    local  10.0.0.77/32
    remote 10.0.0.0/24 198.51.100.7/32[tcp/22]
"""
check("抽出 CHILD_SA 遠端網段（去掉協定與埠），不含 IKE 對端位址",
      HostCheck.activeRemoteTS(fromListSas: sas) == "10.0.0.0/24,198.51.100.7/32")
check("沒有 SA（charon 未執行）→ nil", HostCheck.activeRemoteTS(fromListSas: "charon 未執行") == nil)
check("只有 IKE、沒有 CHILD_SA → nil", HostCheck.activeRemoteTS(fromListSas: "vpn1: #1, CONNECTING, IKEv2\n  remote '203.0.113.10' @ 203.0.113.10[500]") == nil)

typealias R = HostCheck.IPResult
let viaUtun = R(ip: "10.0.0.5", interface: "utun4", viaTunnel: true, portOK: nil)
let viaEn0 = R(ip: "10.0.0.5", interface: "en0", viaTunnel: false, portOK: nil)
let otherEn0 = R(ip: "10.0.9.5", interface: "en0", viaTunnel: false, portOK: nil)
let ts = HostCheck.activeRemoteTS(fromListSas: sas)
check("全部走 utun → viaTunnel", HostCheck.routeAdvice(results: [viaUtun], activeTS: ts) == .viaTunnel)
check("IP 在通道網段內卻走 en0 → staleRoute（提示 VPN 服務異常並提供重新連線）",
      HostCheck.routeAdvice(results: [viaEn0], activeTS: ts) == .staleRoute)
check("IP 不在通道網段內 → notApplied（舊提示：確認已儲存並重新連線）",
      HostCheck.routeAdvice(results: [otherEn0], activeTS: ts) == .notApplied)
check("一個在網段內、一個不在 → notApplied（要先讓網段生效）",
      HostCheck.routeAdvice(results: [viaEn0, otherEn0], activeTS: ts) == .notApplied)
check("讀不到通道網段（舊版輔助程式、sudo 失敗）→ notApplied", HostCheck.routeAdvice(results: [viaEn0], activeTS: nil) == .notApplied)
check("通道網段是 /0 不算涵蓋 → notApplied", HostCheck.routeAdvice(results: [viaEn0], activeTS: "0.0.0.0/0") == .notApplied)

// MARK: staleRoute 的下一步（依系統元件版本與是否已重連過）
check("系統元件需要更新 → 先更新（不論是否重連過）",
      HostCheck.staleRouteHint(helperOutdated: true, retried: false) == .updateHelper
      && HostCheck.staleRouteHint(helperOutdated: true, retried: true) == .updateHelper)
check("新版、第一次 → 重新連線", HostCheck.staleRouteHint(helperOutdated: false, retried: false) == .reconnect)
check("新版、按過重新連線仍沒走 VPN → 診斷報告（不再給同一個按鈕）",
      HostCheck.staleRouteHint(helperOutdated: false, retried: true) == .report)
let tUpd = HostCheck.staleRouteText(.updateHelper)
check("舊版元件的文案：指向「環境檢查」更新，不承諾自動重啟", tUpd.contains("環境檢查") && tUpd.contains("更新") && !tUpd.contains("自動重啟"))
check("新版元件的文案：說明重新連線會檢查並自動重啟", HostCheck.staleRouteText(.reconnect).contains("重新連線")
      && HostCheck.staleRouteText(.reconnect).contains("自動重啟"))
let tRep = HostCheck.staleRouteText(.report)
check("重連後仍失敗的文案：自動修復沒有成功、產生診斷報告", tRep.contains("自動修復沒有成功") && tRep.contains("診斷報告"))

print("通過 \(pass)，失敗 \(fail)")
