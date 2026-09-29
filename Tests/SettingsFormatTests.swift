import Foundation
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
check("逗號 → 一行一個", SettingsTab.lines("10.0.0.0/24, 198.51.100.5/32") == "10.0.0.0/24\n198.51.100.5/32")
check("一行一個 → 逗號", SettingsTab.commaList("10.0.0.0/24\n198.51.100.5/32") == "10.0.0.0/24, 198.51.100.5/32")
check("混用換行與逗號、多餘空白與空行", SettingsTab.commaList("  10.0.0.0/24 ,\n\n 198.51.100.5/32\n") == "10.0.0.0/24, 198.51.100.5/32")
check("來回轉換不變", SettingsTab.commaList(SettingsTab.lines("a/32, b/24, c/32")) == "a/32, b/24, c/32")
check("空白 → 空字串", SettingsTab.commaList(" \n ") == "")
print("通過 \(pass)，失敗 \(fail)")
