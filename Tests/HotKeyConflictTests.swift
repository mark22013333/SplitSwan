import Foundation
// 全域熱鍵衝突比對：系統快捷鍵 plist、CopySymbolicHotKeys 結果、「服務」快捷鍵的解析與比對（純邏輯，資料均為虛構）
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }

typealias C = HotKeyConflicts
typealias HK = PluginShortcuts.HotKey

let cmdShiftO = HK(keyCode: 31, modifiers: HK.command | HK.shift, key: "O")
let cmdShift4 = HK(keyCode: 21, modifiers: HK.command | HK.shift, key: "4")
let ctrlLeft = HK(keyCode: 123, modifiers: HK.control, key: "←")
let ctrlF = HK(keyCode: 3, modifiers: HK.control, key: "F")

func symbolic(_ id: Int, enabled: Bool, _ params: [Int]? = nil) -> (String, Any) {
    var item: [String: Any] = ["enabled": NSNumber(value: enabled)]
    if let params { item["value"] = ["parameters": params.map { NSNumber(value: $0) }, "type": "standard"] }
    return (String(id), item)
}
func sources(symbolic items: [(String, Any)] = [], effective: [[String: Any]]? = nil, services: [String: Any] = [:]) -> C.Sources {
    C.Sources(symbolic: C.parseSymbolic(Dictionary(items, uniquingKeysWith: { a, _ in a })),
              effective: effective.map(C.parseEffective), services: C.parseServices(services))
}
func effective(_ code: Int, _ mods: Int, enabled: Bool = true) -> [String: Any] {
    ["kHISymbolicHotKeyCode": NSNumber(value: code), "kHISymbolicHotKeyModifiers": NSNumber(value: mods),
     "kHISymbolicHotKeyEnabled": NSNumber(value: enabled)]
}

// 修飾鍵格式轉換
check("NSEvent ⌘⇧（1179648）轉成 Carbon ⌘⇧", C.carbonModifiers(cocoa: 1_179_648) == HK.command | HK.shift)
check("NSEvent ⌃⇧⌘（1441792）轉成 Carbon", C.carbonModifiers(cocoa: 1_441_792) == HK.command | HK.shift | HK.control)
check("NSEvent ⌃⌥（786432）轉成 Carbon", C.carbonModifiers(cocoa: 786_432) == HK.control | HK.option)
check("NSEvent fn 位元不轉成任何 Carbon 修飾鍵", C.carbonModifiers(cocoa: 0x80_0000) == 0)
let service = C.parseKeyEquivalent("@$o")
check("服務格式 @$o 是 ⌘⇧O", service?.key == "O" && service?.modifiers == HK.command | HK.shift)
let all4 = C.parseKeyEquivalent("^~$@K")
check("服務格式 ^~$@K 四個修飾鍵都認得", all4?.modifiers == HK.command | HK.shift | HK.option | HK.control)
check("服務格式含未知符號時不採用", C.parseKeyEquivalent("@#O") == nil && C.parseKeyEquivalent("") == nil)

// ⌘⇧O 範例：服務與使用者自訂的系統快捷鍵
let openService = ["com.example.reader - 開啟閱讀器 - openReader": ["key_equivalent": "@$O", "enabled_services_menu": NSNumber(value: true)]]
check("⌘⇧O 撞到服務時寫出服務名稱",
      C.conflicts(of: cmdShiftO, in: sources(services: openService)) == ["服務「開啟閱讀器」"])
check("⌘⇧O 撞到不認得編號的系統快捷鍵時寫出編號",
      C.conflicts(of: cmdShiftO, in: sources(symbolic: [symbolic(999, enabled: true, [111, 31, 1_179_648])]))
          == ["macOS 系統快捷鍵（編號 999）"])
check("⌘⇧O 沒有任何來源佔用時沒有衝突", C.conflicts(of: cmdShiftO, in: sources(effective: [effective(21, 768)])).isEmpty)
let disabledService = ["com.example.reader - 開啟閱讀器 - openReader": ["key_equivalent": "@$O", "enabled_services_menu": NSNumber(value: false)]]
check("停用的服務不算衝突", C.conflicts(of: cmdShiftO, in: sources(services: disabledService)).isEmpty)
check("服務名稱取中間段，含「 - 」也保留",
      C.serviceName("com.example - 甲 - 乙 - doIt") == "甲 - 乙" && C.serviceName("沒有分隔") == "沒有分隔")

// 系統快捷鍵：plist 改過的、停用的、沿用預設的
check("啟用中的 ⌘⇧4 寫出截圖名稱",
      C.conflicts(of: cmdShift4, in: sources(symbolic: [symbolic(30, enabled: true, [52, 21, 1_179_648])]))
          == ["系統快捷鍵「將所選區域的圖片儲存為檔案」"])
check("停用的 ⌘⇧4 不算衝突",
      C.conflicts(of: cmdShift4, in: sources(symbolic: [symbolic(30, enabled: false, [52, 21, 1_179_648])],
                                             effective: [effective(21, 768, enabled: false)])).isEmpty)
check("CopySymbolicHotKeys 標為停用的項目不算衝突",
      C.conflicts(of: cmdShift4, in: sources(effective: [effective(21, 768, enabled: false)])).isEmpty)
check("plist 沒有的系統預設，由 CopySymbolicHotKeys 確認啟用後依預設表寫出名稱",
      C.conflicts(of: cmdShift4, in: sources(effective: [effective(21, 768)])) == ["系統快捷鍵「將所選區域的圖片儲存為檔案」"])
check("讀不到 CopySymbolicHotKeys 時不猜系統預設", C.conflicts(of: cmdShift4, in: sources()).isEmpty)
check("預設項目已被改成別組時不用預設表的名稱，改寫一般名稱",
      C.conflicts(of: cmdShift4, in: sources(symbolic: [symbolic(30, enabled: true, [99, 8, 1_179_648])],
                                             effective: [effective(21, 768)])) == ["macOS 系統快捷鍵"])
check("plist 只寫啟用、沒有 parameters 時沿用預設表",
      C.conflicts(of: cmdShift4, in: sources(symbolic: [symbolic(30, enabled: true)], effective: [effective(21, 768)]))
          == ["系統快捷鍵「將所選區域的圖片儲存為檔案」"])
check("同一組同時在 plist 與預設表命中時只列一次",
      C.conflicts(of: cmdShift4, in: sources(symbolic: [symbolic(30, enabled: true, [52, 21, 1_179_648])],
                                             effective: [effective(21, 768)])) == ["系統快捷鍵「將所選區域的圖片儲存為檔案」"])

// fn 位元：方向鍵一律帶 fn，比對時忽略；字母鍵需要 fn 的項目外掛熱鍵撞不到
check("⌃← 撞到「向左移動一個空間」（plist 帶 fn 位元）",
      C.conflicts(of: ctrlLeft, in: sources(symbolic: [symbolic(79, enabled: true, [65535, 123, 0x84_0000])]))
          == ["系統快捷鍵「向左移動一個空間」"])
check("CopySymbolicHotKeys 的方向鍵帶 Carbon fn 位元仍會比對到，預設表中要按 🌐 的「並排左側一半」不列入",
      C.conflicts(of: ctrlLeft, in: sources(effective: [effective(123, 0x2_1000)])) == ["系統快捷鍵「向左移動一個空間」"])
check("需要 🌐 的「填滿」（⌃🌐F）不算 ⌃F 的衝突",
      C.conflicts(of: ctrlF, in: sources(symbolic: [symbolic(237, enabled: true, [102, 3, 0x84_0000])],
                                         effective: [effective(3, 0x2_1000)])).isEmpty)

// 系統與服務同時命中時，系統在前
let both = C.conflicts(of: cmdShiftO, in: sources(symbolic: [symbolic(999, enabled: true, [111, 31, 1_179_648])], services: openService))
check("系統與服務都命中時全部列出、系統在前", both == ["macOS 系統快捷鍵（編號 999）", "服務「開啟閱讀器」"])
check("預設表的編號都有中文名稱", C.systemTable.values.allSatisfy { !$0.name.isEmpty } && C.systemTable[64]?.name == "顯示Spotlight搜尋")

print("通過 \(pass)，失敗 \(fail)")
exit(fail == 0 ? 0 : 1)
