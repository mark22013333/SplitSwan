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

// F4 閘道順序（docs/SPEC-1.3.md §6）
let g = ["a", "b", "c"]
let now = Date(timeIntervalSince1970: 2_000_000)
/// 依序加入 (閘道, 成功, 耗時, 幾秒前)
func hist(_ items: [(Int, Bool, Double, TimeInterval)], gateways: [String] = g) -> GatewayHistory {
    var h = GatewayHistory()
    for (n, ok, secs, ago) in items {
        h.record(GatewayAttempt(gateway: n, address: gateways[n - 1], success: ok, seconds: secs, time: now.addingTimeInterval(-ago)))
    }
    return h
}
extension GatewayHistory {
    func adding(_ a: GatewayAttempt) -> GatewayHistory { var h = self; h.record(a); return h }
}
func order(_ h: GatewayHistory, _ gws: [String] = g) -> [Int] { GatewayHistory.order(gateways: gws, history: h, now: now) }
let empty = GatewayHistory()
check("沒有紀錄：1→2→3", order(empty) == [1, 2, 3])
check("上次連上 VPN3 → 先試 VPN3", order(hist([(1, true, 2, 3000), (3, true, 5, 2000)])).first == 3)
check("上次成功 VPN3（其他台無紀錄）：3→1→2", order(hist([(3, true, 5, 2000)])) == [3, 1, 2])
check("上次成功的閘道優先於成功率更高的閘道",
      order(hist([(1, true, 1, 5000), (1, true, 1, 4000), (3, false, 16, 3000), (3, true, 9, 2000)])) == [3, 1, 2])
check("VPN3 剛失敗（冷卻中）→ 排最後", order(hist([(3, true, 3, 3000), (3, false, 16, 60)])) == [1, 2, 3])
check("冷卻中仍會嘗試，不跳過", order(hist([(1, false, 16, 10), (2, false, 16, 10), (3, false, 16, 10)])).count == 3)
check("失敗超過 10 分鐘就不算冷卻", !hist([(2, false, 16, 601)]).isCooling(2, now: now)
      && hist([(2, false, 16, 599)]).isCooling(2, now: now))
check("某台連續失敗（已過冷卻）→ 排在其他有紀錄的後面",
      order(hist([(1, false, 16, 5000), (1, false, 16, 4000), (1, false, 16, 3000), (2, true, 4, 2500), (3, true, 6, 2400), (2, true, 4, 2300)])) == [2, 3, 1])
check("某台連續失敗（冷卻中）→ 排最後",
      order(hist([(2, true, 4, 5000), (1, false, 16, 300), (1, false, 16, 200), (1, false, 16, 100)])) == [2, 3, 1])
check("成功率高的在前（VPN3 是上次成功，排第一）",
      order(hist([(1, true, 3, 5000), (1, false, 16, 4900), (2, true, 3, 4800), (2, true, 3, 4700),
                  (3, false, 16, 4600), (3, false, 16, 4500), (3, true, 3, 4400)])) == [3, 2, 1])
check("成功率同分比平均耗時（只算成功的）",
      order(hist([(1, true, 8, 5000), (1, false, 1, 4900), (2, true, 3, 4800), (2, false, 16, 4700),
                  (3, false, 16, 4600), (3, false, 16, 4500), (3, false, 16, 4400), (3, true, 9, 4300)])) == [3, 2, 1])
check("無紀錄的排在有成功紀錄的後面", order(hist([(3, true, 4, 5000), (3, false, 16, 4000), (2, true, 4, 3000)])) == [2, 3, 1])
check("成功率 0（全部失敗）排在無紀錄的後面", order(hist([(1, false, 16, 5000)])) == [2, 3, 1]
      && order(hist([(2, true, 4, 5000), (3, false, 16, 4000)])) == [2, 1, 3])
check("多台成功率 0：彼此照設定順序、都在無紀錄之後", order(hist([(3, false, 16, 5000), (1, false, 16, 4000)])) == [2, 1, 3])
check("無紀錄的閘道彼此照設定順序", order(hist([(3, true, 4, 5000)])) == [3, 1, 2]
      && order(hist([(2, true, 4, 5000)])) == [2, 1, 3])
check("多台冷卻中：彼此照成功率排",
      order(hist([(1, true, 3, 5000), (1, false, 16, 100), (3, true, 3, 4000), (3, true, 3, 3900), (3, false, 16, 90), (2, true, 5, 3000)])) == [2, 3, 1])
check("多台冷卻中：同分照平均耗時、再照設定順序",
      order(hist([(3, true, 2, 5000), (3, false, 16, 50), (1, true, 7, 4000), (1, false, 16, 40), (2, false, 16, 30)])) == [3, 1, 2]
      && order(hist([(2, false, 16, 50), (1, false, 16, 40)])) == [3, 1, 2])
check("上次成功但冷卻中：不排第一", order(hist([(2, true, 3, 5000), (1, true, 3, 3000), (1, false, 16, 20)])) == [2, 3, 1])
check("略過未設定的閘道", order(empty, ["a", " ", "c"]) == [1, 3])
check("上次成功的閘道被清空：照設定順序", order(hist([(2, true, 3, 100)]), ["a", "", "c"]) == [1, 3])
check("全部未設定：空", order(empty, ["", "", ""]).isEmpty)

// 清除紀錄
var cleared = hist([(3, true, 3, 3000), (1, false, 16, 60)])
check("清除前：3 優先、1 冷卻", order(cleared) == [3, 2, 1])
cleared = GatewayHistory()   // VPNController.clearHistory() 做的事
check("清除紀錄 → 恢復設定順序", order(cleared) == [1, 2, 3] && cleared.lastSuccess == nil)
var all = hist([(3, true, 3, 3000), (1, false, 16, 60), (2, true, 2, 50)])
all.removeAll()   // VPNController.clearHistory() 呼叫的就是這個
check("removeAll → 排序回到設定順序", all.attempts.isEmpty && order(all) == [1, 2, 3])
var one = hist([(3, true, 3, 3000), (1, false, 16, 3000)])
one.clear(gateway: 3)
check("清除單台：上次成功也跟著消失", one.lastSuccess == nil && one.records(3).isEmpty && one.records(1).count == 1)

// 每台只保留最近 10 筆
var many = GatewayHistory()
for k in 0..<15 { many.record(GatewayAttempt(gateway: 1, address: "a", success: k >= 5, seconds: Double(k), time: now.addingTimeInterval(Double(k)))) }
many.record(GatewayAttempt(gateway: 2, address: "b", success: false, seconds: 1, time: now))
check("每台只留 10 筆", many.records(1).count == 10 && many.records(2).count == 1)
check("丟掉的是最舊的", many.records(1).first?.seconds == 5 && many.records(1).last?.seconds == 14)
check("成功率只算最近 10 次", many.successRate(1) == 1.0)

// 位址變更：該台舊紀錄清除
let moved = hist([(1, true, 3, 100), (2, true, 4, 90)]).pruned(gateways: ["a", "b2", "c"])
check("位址改了：該台紀錄清除，其他台保留", moved.records(2).isEmpty && moved.records(1).count == 1)
check("閘道被清空：該台紀錄清除", hist([(3, true, 3, 100)]).pruned(gateways: ["a", "b", ""]).attempts.isEmpty)
check("位址只差大小寫與空白：保留", hist([(1, true, 3, 100)], gateways: ["VPN.Example.com", "b", "c"])
      .pruned(gateways: [" vpn.example.COM ", "b", "c"]).records(1).count == 1)
check("位址沒變：原樣保留", hist([(1, true, 3, 100)]).pruned(gateways: [" a ", "b", "c"]).records(1).count == 1)

// 存檔格式（F3 診斷報告會讀）
let saved = hist([(1, true, 3.2, 100), (2, false, 16, 50)])
check("JSON 來回不變", GatewayHistory.decode(saved.encoded()) == saved)
check("壞掉的資料 → 空紀錄", GatewayHistory.decode(Data("x".utf8)) == GatewayHistory() && GatewayHistory.decode(nil) == GatewayHistory())
check("JSON 欄位可讀", String(data: saved.encoded() ?? Data(), encoding: .utf8).map {
    ["\"attempts\"", "\"gateway\"", "\"success\"", "\"seconds\"", "\"time\"", "\"address\""].allSatisfy($0.contains)
} ?? false)

// 要不要記錄（審查第 2、6 條）
check("成功一律記", GatewayHistory.shouldRecord(gateway: 2, success: true, output: "ok vpn2", interrupted: true))
check("helper 印 fail vpnN：記", GatewayHistory.shouldRecord(gateway: 2, success: false, output: "initiate failed\nfail vpn2", interrupted: false))
check("sudo 失敗（沒有 fail vpnN）：不記", !GatewayHistory.shouldRecord(gateway: 1, success: false,
      output: "sudo: a password is required", interrupted: false))
check("輔助程式不存在：不記", !GatewayHistory.shouldRecord(gateway: 1, success: false,
      output: "sudo: /usr/local/libexec/splitswan-helper: command not found", interrupted: false))
check("台號不符：不記", !GatewayHistory.shouldRecord(gateway: 1, success: false, output: "fail vpn2", interrupted: false))
check("fail all 不算單台：不記", !GatewayHistory.shouldRecord(gateway: 1, success: false, output: "fail all", interrupted: false))
check("被斷線搶先或網路中斷：不記", !GatewayHistory.shouldRecord(gateway: 3, success: false, output: "fail vpn3", interrupted: true))
check("連線名稱 → 台號", GatewayHistory.gateway(fromConnection: "vpn2") == 2 && GatewayHistory.gateway(fromConnection: "VPN3") == 3)
check("連線名稱認不出來 → nil", [nil, "", "vpn", "vpn4", "corp", "vpnx"].allSatisfy { GatewayHistory.gateway(fromConnection: $0) == nil })

// 連上後被踢／卡在連線中補記的失敗（耗時不明）：進冷卻、也不再是上次成功
let kicked = hist([(3, true, 3, 100)]).adding(GatewayAttempt(gateway: 3, address: "c", success: false, seconds: nil, time: now))
check("補記失敗後進冷卻、排最後", kicked.isCooling(3, now: now) && order(kicked) == [1, 2, 3])
check("補記失敗不影響平均耗時", kicked.averageSuccessSeconds(3) == 3)

// 遷移舊的 LastGoodGateway（審查第 4 條）
let seeded = GatewayHistory.migrated(GatewayHistory(), legacyLastGood: 2, gateways: g, now: now)
check("舊 key → 種子成功紀錄，先試該台", seeded.records(3).count == 1 && seeded.lastSuccess == 3 && order(seeded) == [3, 1, 2])
check("種子耗時不明：不算進平均", seeded.records(3).first?.seconds == nil && seeded.averageSuccessSeconds(3) == nil)
let seededMore = seeded.adding(GatewayAttempt(gateway: 3, address: "c", success: true, seconds: 4, time: now))
check("種子之後的成功：平均只算有耗時的", seededMore.averageSuccessSeconds(3) == 4)
check("種子狀態文字：上次連上", seeded.statusText(3) == "VPN3 · 上次連上")
check("已有紀錄：不遷移", GatewayHistory.migrated(hist([(1, true, 3, 100)]), legacyLastGood: 2, gateways: g, now: now).records(3).isEmpty)
check("舊 key 指到未設定或超出範圍：不遷移",
      GatewayHistory.migrated(GatewayHistory(), legacyLastGood: 1, gateways: ["a", " ", "c"], now: now).attempts.isEmpty
      && GatewayHistory.migrated(GatewayHistory(), legacyLastGood: 5, gateways: g, now: now).attempts.isEmpty
      && GatewayHistory.migrated(GatewayHistory(), legacyLastGood: nil, gateways: g, now: now).attempts.isEmpty)
check("舊版 JSON（耗時非 nil）仍可讀", GatewayHistory.decode(Data(#"{"attempts":[{"gateway":1,"address":"a","success":true,"seconds":2.5,"time":0}]}"#.utf8)).averageSuccessSeconds(1) == 2.5)

// 狀態文字
let st = hist([(2, true, 3.24, 100), (1, true, 3, 900), (1, false, 16, 800), (1, false, 16, 700), (1, false, 16, 600)])
check("狀態文字：上次 3.2 秒連上", st.statusText(2) == "VPN2 · 上次 3.2 秒連上")
check("狀態文字：最近 3 次失敗（連續失敗次數）", st.statusText(1) == "VPN1 · 最近 3 次失敗")
check("狀態文字：無紀錄只顯示 VPNn", st.statusText(3) == "VPN3" && st.detail(3) == nil)
check("狀態文字：失敗後又成功，顯示成功", hist([(1, false, 16, 200), (1, true, 4, 100)]).detail(1) == "上次 4.0 秒連上")
check("狀態文字：失敗 1 次", hist([(1, true, 4, 200), (1, false, 16, 100)]).statusText(1) == "VPN1 · 最近 1 次失敗")

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

// MARK: A1 連線失敗原因（輔助程式 up N 的 reason 行）
let newFail = "reason vpn2 auth\nfail vpn2"
check("新格式：解析出 auth", ConnectFailReason.parse(newFail, gateway: 2) == .auth)
let helperCodes: [String] = ["auth", "proposal", "ts", "timeout", "unreachable", "unknown"]
check("新格式：每種代碼都認得", helperCodes.allSatisfy { (c: String) in
    ConnectFailReason.parse("reason vpn1 \(c)\nfail vpn1", gateway: 1)?.rawValue == c })
check("舊格式（只有 fail vpnN）：沒有原因 → nil", ConnectFailReason.parse("fail vpn2", gateway: 2) == nil)
check("sudo 失敗：沒有原因 → nil", ConnectFailReason.parse("sudo: a password is required", gateway: 1) == nil)
check("台號不符：不採用", ConnectFailReason.parse("reason vpn1 auth\nfail vpn1", gateway: 2) == nil)
check("認不得的代碼 → unknown", ConnectFailReason.parse("reason vpn3 cert\nfail vpn3", gateway: 3) == .unknown)
check("輔助程式不能冒充 App 端逾時", ConnectFailReason.parse("reason vpn1 helper-timeout", gateway: 1) == .unknown)
check("up auto 多行：取該台那一行", ConnectFailReason.parse("reason vpn1 auth\nreason vpn2 ts\nfail all", gateway: 2) == .ts)
check("成功（code 0）→ nil", ConnectFailReason.from(code: 0, output: "ok vpn1", gateway: 1) == nil)
check("App 端逾時 → helperTimeout", ConnectFailReason.from(code: HelperRun.timeoutCode,
      output: HelperRun.timeoutNote(120), gateway: 1) == .helperTimeout)
check("輔助程式自己回 124 但沒有逾時說明 → 照輸出解析", ConnectFailReason.from(code: 124, output: "reason vpn1 ts\nfail vpn1", gateway: 1) == .ts)
check("每種原因都有中文短句", ConnectFailReason.allCases.allSatisfy { !$0.text.isEmpty && $0.text != $0.rawValue })

// 失敗原因不改變 F4 記錄語意：新格式仍以「fail vpnN」那一行判斷
check("新格式失敗：照樣記錄", GatewayHistory.shouldRecord(gateway: 2, success: false, output: newFail, interrupted: false))
check("新格式失敗但被中斷：照樣不記", !GatewayHistory.shouldRecord(gateway: 2, success: false, output: newFail, interrupted: true))
check("只有 reason 行、沒有 fail vpnN：不記", !GatewayHistory.shouldRecord(gateway: 2, success: false, output: "reason vpn2 auth", interrupted: false))
check("App 端逾時：不記（原因不確定在閘道）", !GatewayHistory.shouldRecord(gateway: 1, success: false,
      output: HelperRun.timeoutNote(120), interrupted: false))

// 畫面訊息
check("單台＋原因", ConnectFailReason.message(order: [2], reasons: [2: .auth], isSingle: true)
      == "VPN2 連線失敗：帳號、密碼或預先共用金鑰（PSK）錯誤。將自動重試同一台")
check("單台、舊版輔助程式：維持原本文字", ConnectFailReason.message(order: [2], reasons: [:], isSingle: true)
      == "VPN2 連線失敗，將自動重試同一台；請開啟連線 log 查看原因")
check("多台同一原因：合併成一句", ConnectFailReason.message(order: [1, 2, 3], reasons: [1: .auth, 2: .auth, 3: .auth], isSingle: false)
      == "所有閘道都連不上：帳號、密碼或預先共用金鑰（PSK）錯誤。將自動重試")
check("多台不同原因：逐台列出", ConnectFailReason.message(order: [3, 1], reasons: [1: .unreachable, 3: .ts], isSingle: false)
      == "所有閘道都連不上（VPN3：通道網段不被閘道接受；VPN1：閘道沒有回應或連不到），將自動重試")
check("多台部分有原因：只列有原因的", ConnectFailReason.message(order: [1, 2], reasons: [2: .auth], isSingle: false)
      == "所有閘道都連不上（VPN2：帳號、密碼或預先共用金鑰（PSK）錯誤），將自動重試")
check("多台都沒有原因：維持原本文字", ConnectFailReason.message(order: [1, 2], reasons: [:], isSingle: false)
      == "所有閘道都連不上，將自動重試")

// MARK: A2 輔助程式逾時
check("log 不限時", HelperRun.timeout(for: ["log"]) == nil)
check("up 時限 > 三台輪替的 swanctl --timeout 總和（5＋15＋3×25＝95 秒）", (HelperRun.timeout(for: ["up", "2"]) ?? 0) > 95)
check("status、down、reload 都有時限", [["status"], ["down"], ["reload"], ["reload-settings"], ["logtrim"], ["sas"]]
      .allSatisfy { (HelperRun.timeout(for: $0) ?? 0) > 0 })
var t1 = Date()
let (slowCode, slowOut) = await VPNController.run("/bin/sleep", ["10"], timeout: 1)
var took = Date().timeIntervalSince(t1)
check("逾時：1 秒時限、sleep 10 → \(String(format: "%.1f", took)) 秒內回來", took < 4)
check("逾時：回 124 與可辨識的說明", slowCode == HelperRun.timeoutCode && HelperRun.isTimeout(code: slowCode, output: slowOut)
      && slowOut.contains("超過 1 秒"))
t1 = Date()
let (stubCode, _) = await VPNController.run("/bin/sh", ["-c", "trap '' TERM; sleep 10"], timeout: 1)
took = Date().timeIntervalSince(t1)
check("逾時：不理 SIGTERM 的程式在寬限 \(Int(HelperRun.termGrace)) 秒後被 SIGKILL（\(String(format: "%.1f", took)) 秒）",
      stubCode == HelperRun.timeoutCode && took >= 1 + HelperRun.termGrace - 0.2 && took < 1 + HelperRun.termGrace + 3)
// 會處理 SIGTERM 的程式（像新版輔助程式的 trap）：寬限內就結束，不用等滿
t1 = Date()
let (trapCode, trapOut) = await VPNController.run("/bin/bash", ["-c", "trap 'echo 收尾; exit 143' TERM; sleep 10 & wait"], timeout: 1)
took = Date().timeIntervalSince(t1)
check("逾時：有 TERM trap 的程式收尾後就回來（\(String(format: "%.1f", took)) 秒）、收尾輸出保留",
      trapCode == HelperRun.timeoutCode && took < 1 + HelperRun.termGrace && trapOut.contains("收尾"))
check("status 連續逾時：1 次不暫停，2 次起 30→60→120，上限 120",
      [0, 1, 2, 3, 4, 5, 50].map { HelperRun.statusPause(afterTimeouts: $0) } == [0, 0, 30, 60, 120, 120, 120])
let (fastCode, fastOut) = await VPNController.run("/bin/sh", ["-c", "echo reason vpn1 auth; echo fail vpn1; exit 1"], timeout: 5)
check("時限內完成：照常回傳結束代碼與輸出", fastCode == 1 && fastOut == "reason vpn1 auth\nfail vpn1" && !HelperRun.isTimeout(code: fastCode, output: fastOut))
let (bigCode, bigOut) = await VPNController.run("/bin/sh", ["-c", "yes 0123456789 | head -c 300000"], timeout: 5)
check("大量輸出不會卡住 pipe", bigCode == 0 && bigOut.utf8.count >= 299_000)
let (nlCode, nlOut) = await VPNController.run("/bin/echo", ["ok"])
check("不限時（brew、osascript 用）：行為不變", nlCode == 0 && nlOut == "ok")
let (missCode, _) = await VPNController.run("/nonexistent/bin", [], timeout: 1)
check("執行檔不存在 → 127", missCode == 127)
// 共用的 ProcessRunner：預設寬限 1 秒（診斷、主機檢查、一鍵更新沿用），逾時本身不改寫結束代碼
t1 = Date()
// exec 讓 sleep 直接取代 sh（忽略 TERM 的設定會沿用），被 SIGKILL 後沒有孫程序握著 pipe，計時才準
let pr = await ProcessRunner.execute("/bin/sh", ["-c", "trap '' TERM; exec sleep 10"], timeout: 1)
took = Date().timeIntervalSince(t1)
check("ProcessRunner：預設寬限 1 秒後 SIGKILL（\(String(format: "%.1f", took)) 秒）",
      pr.timedOut && pr.code == SIGKILL && took >= 1.8 && took < 3.5)
let prMiss = await ProcessRunner.runLimited("/nonexistent/bin", [], timeout: 1)
check("ProcessRunner.runLimited：執行檔不存在 → 127 與說明", prMiss.code == 127 && !prMiss.timedOut
      && prMiss.output.hasPrefix("無法執行 /nonexistent/bin"))
let prEnv = await ProcessRunner.execute("/bin/sh", ["-c", "printf %s \"$SPLITSWAN_T\""], env: ["SPLITSWAN_T": "x1"], timeout: 5)
check("ProcessRunner：env 會傳給子程序", prEnv.code == 0 && prEnv.output == "x1" && !prEnv.timedOut)

// MARK: A3 app.log 落檔、權限、輪替
let base = (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()) + "/applog-\(getpid())"
let logURL = URL(fileURLWithPath: base + "/Logs/SplitSwan/app.log")
func perm(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? Int) ?? -1 }
func fsize(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int) ?? -1 }
let stamp = Date(timeIntervalSince1970: 1_800_000_000)
check("格式：時間＋內容、一筆一行", AppLogFile.format("開始連線\n第二行", at: stamp).hasSuffix(" 開始連線 第二行\n")
      && AppLogFile.format("x", at: stamp).filter { $0 == "\n" }.count == 1)
do {
    try AppLogFile.append(AppLogFile.format("第一筆", at: stamp), to: logURL)
    check("建立目錄與檔案", FileManager.default.fileExists(atPath: logURL.path))
    check("目錄權限 700", perm(logURL.deletingLastPathComponent().path) == 0o700)
    check("檔案權限 600", perm(logURL.path) == 0o600)
    chmod(logURL.path, 0o644); chmod(logURL.deletingLastPathComponent().path, 0o755)
    try AppLogFile.append(AppLogFile.format("第二筆", at: stamp), to: logURL)
    check("權限被改過：下次寫入修正回 600／700", perm(logURL.path) == 0o600 && perm(logURL.deletingLastPathComponent().path) == 0o700)
    let content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    check("附加寫入、不覆蓋", content.contains("第一筆") && content.contains("第二筆"))
    // 小上限模擬輪替：max 4000、keep 1000
    for k in 0..<200 { try AppLogFile.append(AppLogFile.format("第 \(k) 行 xxxxxxxxxx", at: stamp), to: logURL, maxBytes: 4000, keepBytes: 1000) }
    let sz = fsize(logURL.path)
    check("輪替：檔案不超過上限（\(sz) bytes）", sz > 0 && sz <= 4000)
    let after = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    check("輪替：保留最新的、丟掉最舊的", after.contains("第 199 行") && !after.contains("第一筆"))
    check("輪替：第一行是完整的一行", after.hasPrefix("20") && after.hasSuffix("\n"))
    check("輪替後權限仍是 600", perm(logURL.path) == 0o600)
    check("輪替不留暫存檔", ((try? FileManager.default.contentsOfDirectory(atPath: logURL.deletingLastPathComponent().path)) ?? []) == ["app.log"])
    // 預設上限：灌超過 1 MB
    let bigURL = URL(fileURLWithPath: base + "/big/app.log")
    let chunk = String(repeating: "y", count: 1000) + "\n"
    for _ in 0..<1100 { try AppLogFile.append(chunk, to: bigURL) }
    check("預設上限：不會超過 1 MB（\(fsize(bigURL.path)) bytes）", fsize(bigURL.path) <= AppLogFile.maxBytes && fsize(bigURL.path) >= AppLogFile.keepBytes / 2)
} catch {
    check("app.log 寫入不應失敗：\(error)", false)
}
// symlink 拒絕
let linkDir = URL(fileURLWithPath: base + "/linkdir")
try? FileManager.default.createSymbolicLink(atPath: linkDir.path, withDestinationPath: base + "/Logs")
check("目錄是 symlink → 拒絕", (try? AppLogFile.append("x\n", to: linkDir.appendingPathComponent("app.log"))) == nil)
let linkFileDir = URL(fileURLWithPath: base + "/lf")
try? FileManager.default.createDirectory(at: linkFileDir, withIntermediateDirectories: true)
try? FileManager.default.createSymbolicLink(atPath: linkFileDir.path + "/app.log", withDestinationPath: base + "/elsewhere.txt")
check("檔案是 symlink → 拒絕，也不會建立目標檔", (try? AppLogFile.append("x\n", to: linkFileDir.appendingPathComponent("app.log"))) == nil
      && !FileManager.default.fileExists(atPath: base + "/elsewhere.txt"))
check("預設路徑在 ~/Library/Logs/<App>/app.log", AppLogFile.defaultURL.path.hasSuffix("/Library/Logs/\(AppInfo.name)/app.log"))

// MARK: A3 log 串流重接退避
var sb = StreamBackoff()
check("連續失敗：5→10→20→40→60→60", [1, 1, 1, 1, 1, 1].map { sb.next(ranFor: $0) } == [5, 10, 20, 40, 60, 60])
check("串流撐過 30 秒算成功：下次從 5 秒開始", sb.next(ranFor: 31) == 5 && sb.next(ranFor: 2) == 10)
var sb2 = StreamBackoff()
check("一直失敗也不會超過上限", (0..<100).map { _ in sb2.next(ranFor: 0) }.allSatisfy { $0 <= StreamBackoff.cap })
print("\n通過 \(pass)，失敗 \(fail)")
