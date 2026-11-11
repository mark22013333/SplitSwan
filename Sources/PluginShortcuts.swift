// 外掛快捷鍵的純邏輯：設定視窗內動作的 ⌘ 按鍵，以及每支外掛開啟自己設定視窗的全域熱鍵（存 UserDefaults）。
import Foundation

enum PluginShortcuts {
    /// 設定視窗已用 ⌘S 儲存；其餘是 macOS 標準編輯與視窗指令，不讓外掛覆蓋。
    static let reservedActionKeys: Set<String> = ["s", "w", "q", "h", "m", "a", "c", "v", "x", "z", ","]

    static func validActionKey(_ key: String) -> Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            && !reservedActionKeys.contains(key)
    }

    /// 每支外掛各一組熱鍵，存成 [外掛完整 ID: HotKey] 的 JSON。
    static let hotKeysKey = "PluginSettingsHotKeys"
    /// 1.9.17 的單一熱鍵與開啟對象，只在第一次轉換時讀取，轉換後移除。
    static let legacyHotKeyKey = "PluginSettingsHotKey"
    static let legacyTargetKey = "PluginSettingsHotKeyTarget"

    /// 開啟某支外掛設定視窗的全域熱鍵；`modifiers` 用 Carbon 的修飾鍵位元（RegisterEventHotKey 直接使用）。
    struct HotKey: Codable, Equatable {
        static let command: UInt32 = 0x0100, shift: UInt32 = 0x0200, option: UInt32 = 0x0800, control: UInt32 = 0x1000
        static let `default` = HotKey(keyCode: 40, modifiers: control | option | command, key: "K")
        let keyCode: UInt32
        let modifiers: UInt32
        let key: String

        /// 至少要有 ⌃、⌥、⌘ 其中之一，只按 ⇧ 或不按修飾鍵會吃掉一般打字。
        var isUsable: Bool {
            modifiers & (Self.control | Self.option | Self.command) != 0 && !key.isEmpty && key.count <= 8
        }
        var display: String {
            (modifiers & Self.control != 0 ? "⌃" : "") + (modifiers & Self.option != 0 ? "⌥" : "")
                + (modifiers & Self.shift != 0 ? "⇧" : "") + (modifiers & Self.command != 0 ? "⌘" : "") + key
        }
    }

    /// 尚未轉換過時回傳 nil；轉換後即使全部清除也是空字典。
    static func storedHotKeys(_ defaults: UserDefaults = .standard) -> [String: HotKey]? {
        guard let data = defaults.data(forKey: hotKeysKey) else { return nil }
        let all = (try? JSONDecoder().decode([String: HotKey].self, from: data)) ?? [:]
        return all.filter { $0.value.isUsable }
    }
    static func hotKeys(_ defaults: UserDefaults = .standard) -> [String: HotKey] { storedHotKeys(defaults) ?? [:] }

    /// 1.9.17 只有一組熱鍵：沒設定過等於預設 ⌃⌥⌘K，清除過存空資料。轉給當時會開啟的那支外掛；
    /// 還沒有任何外掛提供設定視窗時不轉換，等外掛載入後再做。
    static func migrateLegacy(candidates: [String], _ defaults: UserDefaults = .standard) {
        guard storedHotKeys(defaults) == nil, !candidates.isEmpty else { return }
        let legacy: HotKey?
        if let data = defaults.data(forKey: legacyHotKeyKey) {
            legacy = (try? JSONDecoder().decode(HotKey.self, from: data)).flatMap { $0.isUsable ? $0 : nil }
        } else {
            legacy = .default
        }
        let stored = defaults.string(forKey: legacyTargetKey)
        let target = stored.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates[0]
        write(legacy.map { [target: $0] } ?? [:], defaults)
        defaults.removeObject(forKey: legacyHotKeyKey)
        defaults.removeObject(forKey: legacyTargetKey)
    }

    /// 這組按鍵已經給 `candidates` 裡的哪支外掛用了（不含自己）；已移除的外掛不算。
    static func owner(of hotKey: HotKey, excluding pluginID: String, candidates: [String], _ defaults: UserDefaults = .standard) -> String? {
        hotKeys(defaults).first { $0.key != pluginID && $0.value == hotKey && candidates.contains($0.key) }?.key
    }

    /// 設定或清除一支外掛的熱鍵。同一組若還記在已移除的外掛上，一併拿掉，避免重新安裝時撞鍵。
    static func setHotKey(_ value: HotKey?, for pluginID: String, _ defaults: UserDefaults = .standard) {
        var all = hotKeys(defaults)
        if let value { all = all.filter { $0.value != value } }
        all[pluginID] = value
        write(all, defaults)
    }

    private static func write(_ all: [String: HotKey], _ defaults: UserDefaults) {
        defaults.set((try? JSONEncoder().encode(all)) ?? Data(), forKey: hotKeysKey)
    }
}
