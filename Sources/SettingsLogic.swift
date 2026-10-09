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
        if !psk.isEmpty || !password.isEmpty { return true }
        var d = draft
        d.remoteTS = commaList(tsText)
        var s = saved
        s.remoteTS = commaList(saved.remoteTS)
        return ConfigStore.normalized(d) != ConfigStore.normalized(s)
    }
}
