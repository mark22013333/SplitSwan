import Foundation
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }

// 狀態解析：新格式（5 欄）與舊格式（3 欄）
let n = HelperStatus.parse("connected vpn1 10.255.0.4 192.168.1.10 3")
check("新格式：狀態", n.state == .connected("vpn1", "10.255.0.4"))
check("新格式：本機 IP", n.localIP == "192.168.1.10")
check("新格式：已建立秒數", n.establishedSeconds == 3)
check("新格式：extended", n.extended)
let o = HelperStatus.parse("connected vpn2 10.0.0.9")
check("舊格式：狀態", o.state == .connected("vpn2", "10.0.0.9"))
check("舊格式：沒有本機 IP，extended = false", o.localIP == nil && !o.extended)
check("本機 IP 為 - 時視為沒有", HelperStatus.parse("connected vpn1 10.0.0.1 - -").localIP == nil)
check("connecting", HelperStatus.parse("connecting vpn3").state == .connecting("vpn3"))
check("disconnected", HelperStatus.parse("disconnected").state == .disconnected)
check("無法辨識 → helperMissing", HelperStatus.parse("sudo: a password is required").state == .helperMissing)

// 退避
check("退避 5→15→30→60→60", (0...5).map(ReconnectPolicy.backoff) == [5, 15, 30, 60, 60, 60])

// 閘道順序
let g = ["a", "b", "c"]
check("沒有紀錄：1→2→3", ReconnectPolicy.order(gateways: g, lastGood: nil) == [1, 2, 3])
check("上次成功 VPN3：3→1→2", ReconnectPolicy.order(gateways: g, lastGood: 2) == [3, 1, 2])
check("略過未設定的閘道", ReconnectPolicy.order(gateways: ["a", " ", "c"], lastGood: nil) == [1, 3])
check("上次成功的閘道被清空：照設定順序", ReconnectPolicy.order(gateways: ["a", "", "c"], lastGood: 1) == [1, 3])
check("全部未設定：空", ReconnectPolicy.order(gateways: ["", "", ""], lastGood: nil).isEmpty)

// VPN 介面判斷
check("utun/ipsec/ppp 是 VPN 介面", ["utun6", "ipsec0", "ppp0"].allSatisfy(ReconnectPolicy.isTunnelInterface))
check("en0/en7 不是", !["en0", "en7", "bridge100"].contains(where: ReconnectPolicy.isTunnelInterface))
let ips = VPNController.primaryIPv4s()
print("   本機實體介面 IPv4：\(ips)")
check("實體介面 IP 不含 loopback", !ips.contains("127.0.0.1"))

// 產生的設定檔帶到新參數
var s = VPNSettings(); s.username = "u"; s.gateways = ["203.0.113.1", "", ""]; s.remoteTS = "10.0.0.0/24"
let conf = ConfigStore.renderConf(s)
check("dpd_delay = 10s", conf.contains("dpd_delay = 10s") && !conf.contains("dpd_delay = 20s"))
check("dpd_action = clear", conf.contains("dpd_action = clear") && !conf.contains("dpd_action = restart"))
check("大括號成對", conf.filter { $0 == "{" }.count == conf.filter { $0 == "}" }.count)
print("\n通過 \(pass)，失敗 \(fail)")
