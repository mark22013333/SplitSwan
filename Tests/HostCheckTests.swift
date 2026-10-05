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

print("通過 \(pass)，失敗 \(fail)")
