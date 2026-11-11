import Foundation

/// 外掛設定基準：記住「哪些欄位必須保持已設定」，不記任何值，所以改時間不算缺漏。
/// 基準只會自動往上加；欄位變少一律回報，只有使用者確認「這是刻意的」才從基準移除。
enum PluginSettingsBaseline {
    typealias Field = PluginSettingsProtocol.Field
    typealias Snapshot = PluginSettingsProtocol.Snapshot

    /// 基準提醒不佔外掛自己的每日通知上限，另外限制：同一組缺漏每天 1 則，每支外掛每天最多 3 則。
    static let maxRemindersPerDay = 3

    struct Record: Codable, Equatable, Sendable {
        var version = 1
        var fields: Set<String>
    }
    struct Missing: Equatable, Sendable {
        let id: String
        let title: String
        let tab: String
    }
    struct Evaluation: Equatable {
        /// 依 snapshot.fields 順序
        let missing: [Missing]
        let next: Record
    }

    static func participates(_ f: Field, in s: Snapshot) -> Bool {
        guard f.baseline != false else { return false }
        switch f.type {
        case "text", "time", "select", "stringList", "multiselect", "toggle": return true
        // 舊外掛不回報 configured 時無從得知機密是否存在，不可誤報。
        case "secret": return s.configured != nil
        default: return false
        }
    }

    static func isFilled(_ f: Field, in s: Snapshot) -> Bool {
        let value = s.values[f.id]
        switch f.type {
        case "text", "time", "select": return !(value?.text ?? "").isEmpty
        case "stringList", "multiselect": return !(value?.list ?? []).isEmpty
        case "toggle": return value?.flag == true
        case "secret": return s.configured?.contains(f.id) == true
        default: return false
        }
    }

    private static func filledIDs(_ s: Snapshot) -> Set<String> {
        Set(s.fields.filter { participates($0, in: s) && isFilled($0, in: s) }.map(\.id))
    }

    static func capture(_ s: Snapshot) -> Record { Record(fields: filledIDs(s)) }

    /// 基準內但目前不在 snapshot 的欄位（例：切換模式後消失）視為不適用：不算缺漏，也不移除。
    static func evaluate(_ r: Record, _ s: Snapshot) -> Evaluation {
        let missing = s.fields.filter { r.fields.contains($0.id) && participates($0, in: s) && !isFilled($0, in: s) }
            .map { Missing(id: $0.id, title: $0.title, tab: $0.tab) }
        return Evaluation(missing: missing, next: Record(version: r.version, fields: r.fields.union(filledIDs(s))))
    }

    static func acknowledge(_ ids: Set<String>, in r: Record) -> Record {
        Record(version: r.version, fields: r.fields.subtracting(ids))
    }

    static func notificationKey(_ missing: [Missing]) -> String {
        missing.map(\.id).sorted().joined(separator: ",")
    }

    /// 回傳寫回的紀錄；nil 表示這組缺漏今天不再提醒。
    static func planReminder(_ key: String, today: String, log: PluginLogic.NotifyLog) -> PluginLogic.NotifyLog? {
        var l = log.day == today ? log : PluginLogic.NotifyLog(day: today, keys: [])
        guard !l.keys.contains(key), l.keys.count < maxRemindersPerDay else { return nil }
        l.keys.insert(key)
        return l
    }

    /// 選單與通知共用的缺漏描述；標題來自外掛，先過濾控制字元。
    static func summary(_ missing: [Missing]) -> String {
        PluginLogic.clip("設定比基準少了：" + missing.map { PluginLogic.sanitize($0.title) }.joined(separator: "、"))
    }
}
