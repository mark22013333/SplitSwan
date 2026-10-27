import Foundation
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
check("逗號 → 一行一個", SettingsLogic.lines("10.0.0.0/24, 198.51.100.5/32") == "10.0.0.0/24\n198.51.100.5/32")
check("一行一個 → 逗號", SettingsLogic.commaList("10.0.0.0/24\n198.51.100.5/32") == "10.0.0.0/24, 198.51.100.5/32")
check("混用換行與逗號、多餘空白與空行", SettingsLogic.commaList("  10.0.0.0/24 ,\n\n 198.51.100.5/32\n") == "10.0.0.0/24, 198.51.100.5/32")
check("來回轉換不變", SettingsLogic.commaList(SettingsLogic.lines("a/32, b/24, c/32")) == "a/32, b/24, c/32")
check("空白 → 空字串", SettingsLogic.commaList(" \n ") == "")

// 一鍵加入網段前的「表單有未儲存修改」判斷
var saved = VPNSettings(); saved.username = "alice"; saved.gateways = ["203.0.113.1", "", ""]; saved.remoteTS = "10.0.0.0/24, 198.51.100.5/32"
let cleanTS = SettingsLogic.lines(saved.remoteTS)
check("未修改 → 不算有修改", !SettingsLogic.isDirty(draft: saved, tsText: cleanTS, psk: "", password: "", saved: saved))
check("網段只差空白與換行 → 不算有修改", !SettingsLogic.isDirty(draft: saved, tsText: " 10.0.0.0/24 ,\n\n198.51.100.5/32 ", psk: "", password: "", saved: saved))
check("改了網段 → 有修改", SettingsLogic.isDirty(draft: saved, tsText: cleanTS + "\n203.0.113.9/32", psk: "", password: "", saved: saved))
var d2 = saved; d2.gateways[1] = "198.51.100.1"
check("改了閘道 → 有修改", SettingsLogic.isDirty(draft: d2, tsText: cleanTS, psk: "", password: "", saved: saved))
check("填了密碼或 PSK → 有修改", SettingsLogic.isDirty(draft: saved, tsText: cleanTS, psk: "x", password: "", saved: saved)
      && SettingsLogic.isDirty(draft: saved, tsText: cleanTS, psk: "", password: "y", saved: saved))

// 側欄「未儲存」與儲存列：每個分類各自判斷
func dirty(_ d: VPNSettings, _ ts: String, psk: String = "", password: String = "") -> Set<SettingsCategory> {
    SettingsLogic.dirtyCategories(draft: d, tsText: ts, psk: psk, password: password, saved: saved)
}
check("未修改 → 沒有分類有修改", dirty(saved, cleanTS).isEmpty)
var d3 = saved; d3.username = "bob"
check("改帳號 → 只有連線", dirty(d3, cleanTS) == [.connection])
check("改閘道 → 只有連線", dirty(d2, cleanTS) == [.connection])
check("填密碼或 PSK → 只有連線", dirty(saved, cleanTS, password: "y") == [.connection] && dirty(saved, cleanTS, psk: "x") == [.connection])
check("改網段 → 只有通道網段", dirty(saved, cleanTS + "\n203.0.113.9/32") == [.subnets])
check("網段只差空白與逗號 → 沒有修改", dirty(saved, "10.0.0.0/24,198.51.100.5/32").isEmpty)
var d4 = saved; d4.username = "  alice "; d4.gateways = [" 203.0.113.1", ""]
check("帳號與閘道只差前後空白、閘道少於三台 → 沒有修改", dirty(d4, cleanTS).isEmpty)
var imported = saved; imported.gateways = ["198.51.100.20", "203.0.113.30", ""]
check("匯入設定檔（閘道、網段、PSK）→ 連線與通道網段", dirty(imported, "10.40.8.0/24", psk: "k") == [.connection, .subnets])
check("isDirty 與 dirtyCategories 一致", SettingsLogic.isDirty(draft: imported, tsText: cleanTS, psk: "", password: "", saved: saved)
      && !SettingsLogic.isDirty(draft: saved, tsText: cleanTS, psk: "", password: "", saved: saved))
check("設定檔分類不會單獨被標成未儲存", !dirty(imported, "10.40.8.0/24", psk: "k").contains(.profile))
check("儲存列文字依側欄順序", SettingsLogic.unsavedSummary([.subnets, .connection]) == "連線、通道網段有修改尚未儲存"
      && SettingsLogic.unsavedSummary([]) == nil)
check("網段數只算非空行與逗號分隔", SettingsLogic.subnetCount("10.20.0.0/16\n\n 10.30.5.0/24 , 198.51.100.44/32\n") == 3
      && SettingsLogic.subnetCount("  \n") == 0)
check("分類分兩組，需要儲存的是連線、通道網段、設定檔",
      SettingsCategory.allCases.filter { $0.group == .needsSave } == [.connection, .subnets, .profile]
      && SettingsCategory.allCases.filter { $0.group == .live } == [.appearance, .plugins, .general])
check("啟動參數的分類 id 可還原", SettingsCategory.allCases.allSatisfy { SettingsCategory(rawValue: $0.rawValue) == $0 }
      && SettingsCategory(rawValue: "plugins") == .plugins && SettingsCategory(rawValue: "nope") == nil)
check("記住選擇與啟動參數用不同 key", SettingsCategory.storageKey != SettingsCategory.launchArgumentKey)
print("通過 \(pass)，失敗 \(fail)")
