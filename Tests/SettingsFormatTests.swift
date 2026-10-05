import Foundation
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
check("逗號 → 一行一個", SettingsTab.lines("10.0.0.0/24, 198.51.100.5/32") == "10.0.0.0/24\n198.51.100.5/32")
check("一行一個 → 逗號", SettingsTab.commaList("10.0.0.0/24\n198.51.100.5/32") == "10.0.0.0/24, 198.51.100.5/32")
check("混用換行與逗號、多餘空白與空行", SettingsTab.commaList("  10.0.0.0/24 ,\n\n 198.51.100.5/32\n") == "10.0.0.0/24, 198.51.100.5/32")
check("來回轉換不變", SettingsTab.commaList(SettingsTab.lines("a/32, b/24, c/32")) == "a/32, b/24, c/32")
check("空白 → 空字串", SettingsTab.commaList(" \n ") == "")

// 一鍵加入網段前的「表單有未儲存修改」判斷
var saved = VPNSettings(); saved.username = "alice"; saved.gateways = ["203.0.113.1", "", ""]; saved.remoteTS = "10.0.0.0/24, 198.51.100.5/32"
let cleanTS = SettingsTab.lines(saved.remoteTS)
check("未修改 → 不算有修改", !SettingsTab.isDirty(draft: saved, tsText: cleanTS, psk: "", password: "", saved: saved))
check("網段只差空白與換行 → 不算有修改", !SettingsTab.isDirty(draft: saved, tsText: " 10.0.0.0/24 ,\n\n198.51.100.5/32 ", psk: "", password: "", saved: saved))
check("改了網段 → 有修改", SettingsTab.isDirty(draft: saved, tsText: cleanTS + "\n203.0.113.9/32", psk: "", password: "", saved: saved))
var d2 = saved; d2.gateways[1] = "198.51.100.1"
check("改了閘道 → 有修改", SettingsTab.isDirty(draft: d2, tsText: cleanTS, psk: "", password: "", saved: saved))
check("填了密碼或 PSK → 有修改", SettingsTab.isDirty(draft: saved, tsText: cleanTS, psk: "x", password: "", saved: saved)
      && SettingsTab.isDirty(draft: saved, tsText: cleanTS, psk: "", password: "y", saved: saved))
print("通過 \(pass)，失敗 \(fail)")
