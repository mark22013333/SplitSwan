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

// F2 非預期斷線通知
let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
/// 依序餵 (秒, 想連線, 已連線)，回傳每一步的結果
func feed(_ d: inout DropDetector, _ steps: [(TimeInterval, Bool, Bool)], enabled: Bool = true) -> [DropDetector.Action] {
    steps.map { d.update(now: at($0.0), wantConnected: $0.1, isConnected: $0.2, enabled: enabled) }
}
var d = DropDetector()
check("掉線 29 秒不發", feed(&d, [(0, true, true), (3, true, false), (32, true, false)]).allSatisfy { $0 == .none })
check("滿 30 秒發一次掉線通知", d.update(now: at(33), wantConnected: true, isConnected: false, enabled: true) == .notifyDrop)
check("之後持續斷線不重複", feed(&d, [(36, true, false), (120, true, false), (600, true, false)]).allSatisfy { $0 == .none })
check("恢復時發恢復通知", d.update(now: at(603), wantConnected: true, isConnected: true, enabled: true) == .notifyRestore)
check("恢復通知只發一次", feed(&d, [(606, true, true), (609, true, true)]).allSatisfy { $0 == .none })
check("再掉線超過 30 秒可以再發", feed(&d, [(700, true, false), (730, true, false)]) == [.none, .notifyDrop])
check("第二次恢復也會發", d.update(now: at(733), wantConnected: true, isConnected: true, enabled: true) == .notifyRestore)

d = DropDetector()
// App 自己重建通道（down → up）28 秒內完成：不發，且重置計時
check("30 秒內恢復不發任何通知", feed(&d, [(0, true, true), (3, true, false), (30, true, false), (31, true, true)]).allSatisfy { $0 == .none })
check("恢復後重置計時", d.downSince == nil)
check("重置後重新計時：再斷 29 秒不發", feed(&d, [(40, true, false), (69, true, false)]).allSatisfy { $0 == .none })

d = DropDetector()
check("按斷線：不發通知", feed(&d, [(0, true, false), (20, false, false), (60, false, false), (100, false, true)]).allSatisfy { $0 == .none })
check("按斷線：計時已重置", d.downSince == nil && !d.dropNotified)
d = DropDetector()
_ = feed(&d, [(0, true, false), (30, true, false)])
check("掉線通知後按斷線：不發恢復通知", feed(&d, [(40, false, false), (50, true, true)]).allSatisfy { $0 == .none })
d = DropDetector()
_ = feed(&d, [(0, true, false), (25, true, false)])
d.reset()   // VPNController.disconnect() 立即重置
check("reset 後從頭計時", feed(&d, [(26, true, false), (50, true, false)]).allSatisfy { $0 == .none })

d = DropDetector()
check("開關關閉：掉線不發", feed(&d, [(0, true, false), (30, true, false), (300, true, false), (303, true, true)], enabled: false).allSatisfy { $0 == .none })
d = DropDetector()
_ = feed(&d, [(0, true, false), (30, true, false)])
check("掉線通知後關閉開關：恢復也不發", feed(&d, [(40, true, false), (43, true, true)], enabled: false).allSatisfy { $0 == .none })

// 暫停計時：沒網路或讀不到輔助程式狀態時不算掉線（審查發現：避免誤發與錯誤的「正在自動重連」）
func step(_ d: inout DropDetector, _ s: TimeInterval, connected: Bool = false, paused: Bool = false) -> DropDetector.Action {
    d.update(now: at(s), wantConnected: true, isConnected: connected, enabled: true, paused: paused)
}
d = DropDetector()
check("暫停期間不發", [step(&d, 0), step(&d, 10, paused: true), step(&d, 100, paused: true)].allSatisfy { $0 == .none })
check("暫停結束後重新計時：29 秒不發", [step(&d, 110), step(&d, 139)].allSatisfy { $0 == .none })
check("暫停結束後滿 30 秒才發", step(&d, 140) == .notifyDrop)
check("已發掉線通知後暫停：不重複發", step(&d, 150, paused: true) == .none && d.dropNotified)
check("暫停後接回：仍發恢復通知", step(&d, 160, connected: true) == .notifyRestore)

// 睡眠喚醒：睡前開始的計時不算，喚醒後重新計時（規格 §4.2）
d = DropDetector()
_ = step(&d, 0)
d.restartGrace()
check("喚醒後第一次更新不因睡眠時間發通知", step(&d, 600) == .none)
check("喚醒後 30 秒內接回不發", step(&d, 620, connected: true) == .none)
d = DropDetector()
_ = [step(&d, 0), step(&d, 30)]
d.restartGrace()
check("已發掉線通知時喚醒：保留，接回仍發恢復通知", d.dropNotified && step(&d, 700, connected: true) == .notifyRestore)

check("掉線標題", DropDetector.dropTitle(app: "SplitSwan") == "SplitSwan 已斷線")
check("恢復標題", DropDetector.restoreTitle(app: "SplitSwan") == "SplitSwan 已恢復連線")
check("恢復內文帶台號", DropDetector.restoreBody(connection: "vpn2") == "VPN2 已重新連上")
check("取不到台號就省略", DropDetector.restoreBody(connection: nil) == "VPN 已重新連上")
check("掉線內文", DropDetector.dropBody == "VPN 中斷超過 30 秒，正在自動重連")
print("\n通過 \(pass)，失敗 \(fail)")
