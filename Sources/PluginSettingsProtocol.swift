import Foundation

/// 外掛設定只傳遞資料；欄位與動作不能指定可執行檔、shell 或任意檔案路徑。
enum PluginSettingsProtocol {
    static let version = 1
    static let maxBytes = 64 * 1024

    enum Value: Codable, Equatable, Sendable {
        case text(String), flag(Bool), list([String])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .flag(b) }
            else if let s = try? c.decode(String.self) { self = .text(s) }
            else { self = .list(try c.decode([String].self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .flag(let b): try c.encode(b)
            case .list(let a): try c.encode(a)
            }
        }
        var text: String { if case .text(let s) = self { return s }; return "" }
        var flag: Bool { self == .flag(true) }
        var list: [String] { if case .list(let a) = self { return a }; return [] }
    }

    struct Option: Codable, Equatable, Identifiable { let id: String; let title: String }
    struct Tab: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let help: String?
        var guide: Guide? = nil
    }
    struct Guide: Codable, Equatable {
        let summary: String
        let steps: [Step]
        let checkAction: String
        let refreshFields: [String]
        let managementActions: [String]
        var complete: Bool { steps.allSatisfy { $0.state == "completed" } }
        var currentStep: String? { steps.first { $0.state != "completed" }?.id }
    }
    struct Step: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let help: String
        let state: String
        let fields: [String]
        let actions: [String]
        var details: String? = nil
        var primaryAction: String? = nil
        var saveTitle: String? = nil
    }
    struct Field: Codable, Equatable, Identifiable {
        let id: String
        let tab: String
        let title: String
        let type: String
        let help: String?
        let options: [Option]?
    }
    struct Action: Codable, Equatable, Identifiable {
        let id: String
        let tab: String
        let title: String
        let destructive: Bool?
        /// file 匯入內容只在使用者透過 NSOpenPanel 選取後，經 stdin 傳給此外掛。
        let input: String?
        let afterField: String?
        var opensExternal: Bool? = nil
        var recheckAfter: Bool? = nil
    }
    struct Job: Codable, Equatable { let id: String; let state: String; let message: String }
    struct Snapshot: Codable, Equatable {
        let version: Int
        let title: String
        let revision: String
        let tabs: [Tab]
        let fields: [Field]
        let values: [String: Value]
        let actions: [Action]
        let job: Job?
    }
    struct Request: Encodable {
        let revision: String
        var values: [String: Value]? = nil
        var id: String? = nil
        var input: String? = nil
    }
    struct Failure: Decodable { let error: String; let message: String }
    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 說明文字保留換行，但每一行仍套用既有的控制字元與雙向文字過濾。
    static func displayText(_ text: String) -> String {
        text.components(separatedBy: "\n").map(PluginLogic.sanitize).joined(separator: "\n")
    }

    static func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= maxBytes else { throw Problem(message: "外掛設定資料過大") }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            throw Problem(message: PluginLogic.clip(PluginLogic.sanitize(failure.message)))
        }
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            throw Problem(message: "外掛設定資料不是有效的 v1 JSON 表單")
        }
        let validID: (String) -> Bool = { value in
            !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0)
            }
        }
        let unique: ([String]) -> Bool = { Set($0).count == $0.count }
        let tabIDs = Set(s.tabs.map(\.id))
        let types: Set<String> = ["text", "secret", "stringList", "toggle", "time", "select", "multiselect", "readonly"]
        guard s.version == version, !s.title.isEmpty, !s.revision.isEmpty,
              s.revision.utf8.count <= 256, (1...10).contains(s.tabs.count), s.fields.count <= 100,
              s.actions.count <= 50, unique(s.tabs.map(\.id)), unique(s.fields.map(\.id)),
              unique(s.actions.map(\.id)), s.tabs.allSatisfy({ validID($0.id) }),
              s.fields.allSatisfy({ validID($0.id) && tabIDs.contains($0.tab) && types.contains($0.type) }),
              s.actions.allSatisfy({ action in
                  validID(action.id) && tabIDs.contains(action.tab) && (action.input == nil || action.input == "jsonFile")
                  && (action.afterField == nil || s.fields.contains { $0.id == action.afterField && $0.tab == action.tab })
              })
        else { throw Problem(message: "外掛設定協定版本或欄位格式不正確") }
        for f in s.fields {
            let options = f.options ?? []
            guard options.count <= 200, unique(options.map(\.id)), options.allSatisfy({ !$0.id.isEmpty })
            else { throw Problem(message: "外掛設定選項格式不正確") }
            guard let v = s.values[f.id] else { throw Problem(message: "外掛設定缺少欄位值") }
            switch (f.type, v) {
            case ("toggle", .flag), ("stringList", .list), ("multiselect", .list),
                 ("text", .text), ("time", .text), ("select", .text), ("readonly", .text): break
            case ("secret", .text(let value)) where value.isEmpty: break
            default: throw Problem(message: "外掛設定欄位值型別不正確")
            }
        }
        for tab in s.tabs {
            guard let guide = tab.guide else { continue }
            let fields = Set(s.fields.filter { $0.tab == tab.id }.map(\.id))
            let actions = s.actions.filter { $0.tab == tab.id }
            let actionIDs = Set(actions.map(\.id))
            let references = guide.steps.flatMap(\.fields)
            let actionReferences = guide.steps.flatMap(\.actions) + guide.managementActions
            guard (1...10).contains(guide.steps.count), unique(guide.steps.map(\.id)),
                  unique(references), unique(actionReferences),
                  Set(references).isSubset(of: fields), Set(actionReferences).isSubset(of: actionIDs),
                  unique(guide.refreshFields), Set(guide.refreshFields).isSubset(of: fields),
                  let check = actions.first(where: { $0.id == guide.checkAction }),
                  check.input == nil, check.destructive != true, check.opensExternal != true, check.recheckAfter != true,
                  guide.steps.allSatisfy({ step in
                      validID(step.id) && !step.title.isEmpty &&
                      ["pending", "checking", "completed", "attention"].contains(step.state) &&
                      (step.primaryAction == nil || step.actions.contains(step.primaryAction!))
                  }) else { throw Problem(message: "外掛設定精靈的步驟或參照不正確") }
        }
        if let job = s.job {
            guard validID(job.id), ["running", "succeeded", "failed"].contains(job.state) else {
                throw Problem(message: "外掛設定工作格式不正確")
            }
        }
        return s
    }
}
