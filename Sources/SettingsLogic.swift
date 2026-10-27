// 設定頁的純函式（網段格式轉換、未儲存修改判斷）。
// 從 MainView.swift 抽出來，讓單元測試不必連同整個 SwiftUI 介面一起編譯。
import Foundation

enum SettingsLogic {
    /// 「a, b, c」→ 一行一個
    static func lines(_ ts: String) -> String {
        ts.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 編輯框的內容（換行或逗號分隔都接受）→ 設定檔用的「a, b, c」
    static func commaList(_ text: String) -> String {
        lines(text).split(separator: "\n").joined(separator: ", ")
    }

    /// 表單是否有還沒儲存的修改（一鍵加入網段會整份存檔，有未儲存的修改時要先擋下）
    static func isDirty(draft: VPNSettings, tsText: String, psk: String, password: String, saved: VPNSettings) -> Bool {
        !dirtyCategories(draft: draft, tsText: tsText, psk: psk, password: password, saved: saved).isEmpty
    }

    /// 哪些分類有未儲存的修改。設定檔分類本身沒有欄位，匯入後改到的閘道、網段、PSK 會算在連線或通道網段
    static func dirtyCategories(draft: VPNSettings, tsText: String, psk: String, password: String,
                                saved: VPNSettings) -> Set<SettingsCategory> {
        let d = ConfigStore.normalized(draft), s = ConfigStore.normalized(saved)
        var out: Set<SettingsCategory> = []
        if !psk.isEmpty || !password.isEmpty || d.username != s.username || d.gateways != s.gateways { out.insert(.connection) }
        if commaList(tsText) != commaList(saved.remoteTS) { out.insert(.subnets) }
        return out
    }

    /// 儲存列左側的文字，例：「連線、通道網段有修改尚未儲存」
    static func unsavedSummary(_ dirty: Set<SettingsCategory>) -> String? {
        let names = SettingsCategory.allCases.filter(dirty.contains).map(\.title)
        return names.isEmpty ? nil : names.joined(separator: "、") + "有修改尚未儲存"
    }

    /// 網段編輯框裡的網段數（空行、逗號分隔都照存檔時的規則算）
    static func subnetCount(_ text: String) -> Int {
        lines(text).split(separator: "\n").count
    }
}

/// 設定頁左側的分類。rawValue 是 `-SettingsCategory <id>` 啟動參數與記住選擇用的值
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case connection, subnets, profile, appearance, plugins, general

    enum Group: CaseIterable { case needsSave, live }

    var id: String { rawValue }
    var group: Group {
        switch self {
        case .connection, .subnets, .profile: return .needsSave
        case .appearance, .plugins, .general: return .live
        }
    }
    var title: String {
        switch self {
        case .connection: return "連線"
        case .subnets: return "通道網段"
        case .profile: return "設定檔"
        case .appearance: return "外觀"
        case .plugins: return "外掛"
        case .general: return "一般"
        }
    }
    var symbol: String {
        switch self {
        case .connection: return "person.fill"
        case .subnets: return "arrow.triangle.branch"
        case .profile: return "doc.text.fill"
        case .appearance: return "menubar.rectangle"
        case .plugins: return "puzzlepiece.extension.fill"
        case .general: return "gearshape.fill"
        }
    }
    /// 記住上次選的分類；跟啟動參數用不同的 key，否則參數會蓋住使用者之後的點選
    static let storageKey = "SettingsCategorySelection"
    static let launchArgumentKey = "SettingsCategory"
}

extension SettingsCategory.Group {
    var title: String { self == .needsSave ? "寫入 VPN 設定" : "即時生效" }
}
