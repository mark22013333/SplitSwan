// 外掛快捷鍵的純邏輯：設定視窗內動作的 ⌘ 按鍵，以及開啟外掛設定的全域熱鍵（存 UserDefaults）。
import Foundation

enum PluginShortcuts {
    /// 設定視窗已用 ⌘S 儲存；其餘是 macOS 標準編輯與視窗指令，不讓外掛覆蓋。
    static let reservedActionKeys: Set<String> = ["s", "w", "q", "h", "m", "a", "c", "v", "x", "z", ","]

    static func validActionKey(_ key: String) -> Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            && !reservedActionKeys.contains(key)
    }

    static let hotKeyKey = "PluginSettingsHotKey"
    static let hotKeyTargetKey = "PluginSettingsHotKeyTarget"

    /// 開啟外掛設定的全域熱鍵；`modifiers` 用 Carbon 的修飾鍵位元（RegisterEventHotKey 直接使用）。
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

    /// 尚未設定時用預設值；使用者清除後存空資料，代表「不使用熱鍵」。
    static func hotKey(_ defaults: UserDefaults = .standard) -> HotKey? {
        guard let data = defaults.data(forKey: hotKeyKey) else { return .default }
        guard let value = try? JSONDecoder().decode(HotKey.self, from: data), value.isUsable else { return nil }
        return value
    }
    static func setHotKey(_ value: HotKey?, _ defaults: UserDefaults = .standard) {
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: hotKeyKey)
    }

    /// 熱鍵開啟哪個外掛：使用者選過且仍可用就用它，否則用第一個有設定視窗的外掛。
    static func target(stored: String?, candidates: [String]) -> String? {
        if let stored, candidates.contains(stored) { return stored }
        return candidates.first
    }
}
