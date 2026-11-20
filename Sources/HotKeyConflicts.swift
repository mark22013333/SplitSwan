// 全域熱鍵與 macOS 系統快捷鍵、「服務」快捷鍵的衝突比對（純邏輯）。讀系統設定的邊界在 GlobalHotKey.swift。
// 第三方 App 的熱鍵沒有公開 API 可查，這裡不處理，只在錄製區提示。
import Foundation

enum HotKeyConflicts {
    /// 一組按鍵：鍵碼＋ Carbon 修飾鍵（只留 ⌘⇧⌥⌃）。
    struct Combo: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// `com.apple.symbolichotkeys` 的一筆。`custom` 表示有 parameters（使用者改過）；沒有時沿用系統預設。
    /// `combo` 為 nil：未指定按鍵，或需要 fn／🌐 鍵（外掛熱鍵不會有 fn，不可能撞到）。
    struct SymbolicEntry: Equatable {
        let id: Int
        let enabled: Bool
        let custom: Bool
        let combo: Combo?
    }

    struct Service: Equatable {
        let name: String
        let key: String
        let modifiers: UInt32
    }

    /// 錄製或開啟設定視窗時從系統讀一次。`effective` 是 CopySymbolicHotKeys 的結果（含沒被改過的系統預設、
    /// 只留啟用中的）；讀取失敗時為 nil，只比對 plist 裡改過的項目。
    struct Sources {
        var symbolic: [SymbolicEntry] = []
        var effective: Set<Combo>? = nil
        var services: [Service] = []
    }

    typealias HK = PluginShortcuts.HotKey
    static let modifierMask = HK.command | HK.shift | HK.option | HK.control
    private static let carbonFn: UInt32 = 0x2_0000
    private static let cocoaFn = 0x80_0000

    /// 方向鍵、F1–F20、Home／End／Page Up／Down、Forward Delete、Help：系統一律帶 fn 位元，比對時忽略。
    private static let fnImpliedKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        123, 124, 125, 126, 115, 119, 116, 121, 117, 114,
    ]

    /// NSEvent 修飾鍵位元（plist 與系統預設表用的格式）轉成 Carbon。
    static func carbonModifiers(cocoa: Int) -> UInt32 {
        (cocoa & 0x2_0000 != 0 ? HK.shift : 0) | (cocoa & 0x4_0000 != 0 ? HK.control : 0)
            | (cocoa & 0x8_0000 != 0 ? HK.option : 0) | (cocoa & 0x10_0000 != 0 ? HK.command : 0)
    }

    static func combo(keyCode: Int, carbon: UInt32, fn: Bool) -> Combo? {
        guard keyCode >= 0, keyCode < 0xFFFF else { return nil }
        let code = UInt32(keyCode)
        if fn && !fnImpliedKeyCodes.contains(code) { return nil }
        return Combo(keyCode: code, modifiers: carbon & modifierMask)
    }

    static func combo(_ hotKey: HK) -> Combo { Combo(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers & modifierMask) }

    /// AppleSymbolicHotKeys：{ "編號": { enabled, value: { parameters: [ascii, keyCode, modifiers] } } }
    static func parseSymbolic(_ raw: Any?) -> [SymbolicEntry] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.compactMap { key, value in
            guard let id = Int(key), let item = value as? [String: Any] else { return nil }
            let enabled = (item["enabled"] as? NSNumber)?.boolValue ?? false
            guard let params = (item["value"] as? [String: Any])?["parameters"] as? [NSNumber], params.count >= 3 else {
                return SymbolicEntry(id: id, enabled: enabled, custom: false, combo: nil)
            }
            let flags = params[2].intValue
            let combo = combo(keyCode: params[1].intValue, carbon: carbonModifiers(cocoa: flags), fn: flags & cocoaFn != 0)
            return SymbolicEntry(id: id, enabled: enabled, custom: true, combo: combo)
        }
        .sorted { $0.id < $1.id }
    }

    /// CopySymbolicHotKeys：每筆 kHISymbolicHotKeyCode／Modifiers（Carbon 位元）／Enabled，沒有編號。
    static func parseEffective(_ raw: [[String: Any]]) -> Set<Combo> {
        Set(raw.compactMap { item in
            guard (item["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true,
                  let code = (item["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue,
                  let mods = (item["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return nil }
            return combo(keyCode: code, carbon: mods, fn: mods & carbonFn != 0)
        })
    }

    /// 「服務」的按鍵格式：@＝⌘、$＝⇧、~＝⌥、^＝⌃，最後一個字元是按鍵。
    static func parseKeyEquivalent(_ text: String) -> (key: String, modifiers: UInt32)? {
        guard let last = text.last else { return nil }
        var modifiers: UInt32 = 0
        for c in text.dropLast() {
            switch c {
            case "@": modifiers |= HK.command
            case "$": modifiers |= HK.shift
            case "~": modifiers |= HK.option
            case "^": modifiers |= HK.control
            default: return nil
            }
        }
        return (String(last).uppercased(), modifiers)
    }

    /// `pbs` 網域的 NSServicesStatus：鍵是「Bundle ID - 選單名稱 - 訊息」，只取有 key_equivalent 且沒有停用的。
    static func parseServices(_ raw: Any?) -> [Service] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.compactMap { key, value in
            guard let item = value as? [String: Any],
                  let text = item["key_equivalent"] as? String,
                  let parsed = parseKeyEquivalent(text) else { return nil }
            if let on = item["enabled_services_menu"] as? NSNumber, !on.boolValue { return nil }
            return Service(name: serviceName(key), key: parsed.key, modifiers: parsed.modifiers)
        }
        .sorted { $0.name < $1.name }
    }

    static func serviceName(_ key: String) -> String {
        let parts = key.components(separatedBy: " - ")
        guard parts.count >= 3 else { return key }
        return parts.dropFirst().dropLast().joined(separator: " - ")
    }

    static func systemName(_ id: Int) -> String {
        systemTable[id].map { "系統快捷鍵「\($0.name)」" } ?? "macOS 系統快捷鍵（編號 \(id)）"
    }

    /// 這組熱鍵撞到哪些功能，依系統、服務排序且不重複；沒有衝突回傳空陣列。
    static func conflicts(of hotKey: HK, in sources: Sources) -> [String] {
        let target = combo(hotKey)
        var names: [String] = []
        let byID = Dictionary(sources.symbolic.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in sources.symbolic where e.enabled && e.custom && e.combo == target {
            names.append(systemName(e.id))
        }
        if sources.effective?.contains(target) == true {
            var found = false
            for (id, entry) in systemTable.sorted(by: { $0.key < $1.key }) {
                // 預設表的方向鍵不帶 fn 位元，帶了就是要按 🌐（例如「並排左側一半」是 ⌃🌐←），外掛熱鍵撞不到
                guard let keyCode = entry.keyCode, entry.cocoa & cocoaFn == 0,
                      combo(keyCode: keyCode, carbon: carbonModifiers(cocoa: entry.cocoa), fn: false) == target
                else { continue }
                if let e = byID[id], e.custom || !e.enabled { continue }
                names.append(systemName(id))
                found = true
            }
            if !found && names.isEmpty { names.append("macOS 系統快捷鍵") }
        }
        for s in sources.services where s.modifiers == target.modifiers && s.key == hotKey.key.uppercased() {
            names.append("服務「\(s.name)」")
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// 系統預設快捷鍵：編號 → 中文名稱與預設按鍵（鍵碼、NSEvent 修飾鍵位元）。
    /// 取自 macOS 27.2 的 KeyboardSettings.appex（zh_TW.lproj/DefaultShortcutsTable.xml、DefaultSpacesShortcuts.xml
    /// 與 DefaultShortcutsTable.loctable 的 zh_TW），以腳本轉出。「慢速」與別名編號只有名稱，預設按鍵不同或未知。
    struct S {
        let name: String
        /// 預設按鍵：鍵碼與 NSEvent 修飾鍵位元；nil 表示預設沒有按鍵，或預設值不明
        let keyCode: Int?
        let cocoa: Int
        init(_ name: String, _ keyCode: Int? = nil, _ cocoa: Int = 0) { (self.name, self.keyCode, self.cocoa) = (name, keyCode, cocoa) }
    }
    static let systemTable: [Int: S] = [
        7: S("移動焦點至選單列", 120, 0x40000),
        8: S("移動焦點至Dock", 99, 0x40000),
        9: S("移動焦點至使用中的視窗或下一個視窗", 118, 0x40000),
        10: S("移動焦點至視窗工具列", 96, 0x40000),
        11: S("移動焦點至浮動視窗", 97, 0x40000),
        12: S("啟用或停用鍵盤操控", 122, 0x40000),
        13: S("變更Tab鍵移動焦點的方式", 98, 0x40000),
        15: S("啟用或停用縮放", 28, 0x180000),
        17: S("放大", 24, 0x180000),
        19: S("縮小", 27, 0x180000),
        21: S("反相顏色", 28, 0x1C0000),
        23: S("啟用或停用影像平順"),
        25: S("增加對比", 47, 0x1C0000),
        26: S("降低對比", 43, 0x1C0000),
        27: S("移動焦點至下一個視窗", 50, 0x100000),
        28: S("將螢幕圖片儲存為檔案", 20, 0x120000),
        29: S("拷貝螢幕圖片至剪貼板", 20, 0x160000),
        30: S("將所選區域的圖片儲存為檔案", 21, 0x120000),
        31: S("拷貝所選區域的圖片至剪貼板", 21, 0x160000),
        32: S("指揮中心", 126, 0x40000),
        33: S("應用程式視窗", 125, 0x40000),
        34: S("指揮中心"),
        35: S("應用程式視窗"),
        36: S("顯示桌面", 103, 0x0),
        37: S("顯示桌面"),
        52: S("開啟/關閉隱藏Dock", 2, 0x180000),
        53: S("降低顯示器亮度", 107, 0x0),
        54: S("增加顯示器亮度", 113, 0x0),
        55: S("降低顯示器亮度"),
        56: S("增加顯示器亮度"),
        57: S("移動焦點至狀態選單", 100, 0x40000),
        59: S("啟用或停用「旁白」", 96, 0x100000),
        60: S("選擇上一個輸入方式", 49, 0x40000),
        61: S("在輸入選單中選擇下一個方式", 49, 0xC0000),
        64: S("顯示Spotlight搜尋", 49, 0x100000),
        65: S("顯示Finder搜尋視窗", 49, 0x180000),
        79: S("向左移動一個空間", 123, 0x40000),
        80: S("向左移動一個空間"),
        81: S("向右移動一個空間", 124, 0x40000),
        82: S("向右移動一個空間"),
        98: S("顯示輔助說明選單", 44, 0x120000),
        118: S("切換至桌面1", 18, 0x40000),
        119: S("切換至桌面2", 19, 0x40000),
        120: S("切換至桌面3", 20, 0x40000),
        121: S("切換至桌面4", 21, 0x40000),
        122: S("切換至桌面5", 23, 0x40000),
        123: S("切換至桌面6", 22, 0x40000),
        124: S("切換至桌面7", 26, 0x40000),
        125: S("切換至桌面8", 28, 0x40000),
        126: S("切換至桌面9", 25, 0x40000),
        127: S("切換至桌面10", 29, 0x40000),
        128: S("切換至桌面11", 18, 0xC0000),
        129: S("切換至桌面12", 19, 0xC0000),
        130: S("切換至桌面13", 20, 0xC0000),
        131: S("切換至桌面14", 21, 0xC0000),
        132: S("切換至桌面15", 23, 0xC0000),
        133: S("切換至桌面16", 22, 0xC0000),
        156: S("顯示/隱藏手寫輸入", 49, 0x60000),
        159: S("顯示項目特色選單", 36, 0x40000),
        160: S("顯示App"),
        162: S("顯示輔助使用控制項目", 96, 0x180000),
        163: S("顯示通知中心"),
        175: S("開啟/關閉勿擾模式"),
        179: S("開啟或關閉焦點跟隨"),
        181: S("將觸控列的圖片儲存為檔案", 26, 0x120000),
        182: S("拷貝觸控列的圖片到剪貼板", 26, 0x160000),
        184: S("截圖和錄製選項", 23, 0x120000),
        190: S("快速備忘錄", 12, 0x800000),
        215: S("開啟或關閉「即時字幕」"),
        216: S("暫停或繼續逐字稿"),
        217: S("開啟或關閉輸入來朗讀"),
        218: S("切換錄製電腦音訊和麥克風"),
        219: S("開啟或關閉保持螢幕顯示"),
        222: S("開啟/關閉幕前調度"),
        223: S("開啟或關閉「發表人置前」（大型畫面）"),
        224: S("開啟或關閉「發表人置前」（小型畫面）"),
        225: S("開啟或關閉「即時語音」"),
        226: S("切換能見度"),
        227: S("暫停或繼續語音"),
        228: S("取消語音"),
        229: S("隱藏或顯示詞句"),
        230: S("開啟或關閉朗讀所選範圍"),
        231: S("開啟或關閉朗讀指標下方項目"),
        232: S("開啟或關閉輸入回饋"),
        233: S("縮到最小", 46, 0x100000),
        235: S("縮放"),
        237: S("填滿", 3, 0x840000),
        238: S("中央", 8, 0x840000),
        239: S("返回上一個大小", 15, 0x840000),
        240: S("並排左側一半", 123, 0x840000),
        241: S("並排右側一半", 124, 0x840000),
        242: S("並排上方一半", 126, 0x840000),
        243: S("並排下方一半", 125, 0x840000),
        244: S("並排左上四分之一"),
        245: S("並排右上四分之一"),
        246: S("並排左下四分之一"),
        247: S("並排右下四分之一"),
        248: S("排列左側和右側", 123, 0x860000),
        249: S("排列右側和左側", 124, 0x860000),
        250: S("排列頂部和底部", 126, 0x860000),
        251: S("排列底部和頂部", 125, 0x860000),
        256: S("分成4個部分"),
        257: S("左側全螢幕並排"),
        258: S("右側全螢幕並排"),
        260: S("遊戲覆疊", 53, 0x100000),
        261: S("問問Siri所選區域的相關資訊", 22, 0x120000),
        263: S("問問Siri現用視窗的相關資訊", 49, 0x120000),
    ]
}
