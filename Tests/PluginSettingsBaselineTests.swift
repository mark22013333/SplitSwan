import Foundation
// 外掛設定基準：已設定判定、缺漏、往上併入、刻意移除、通知鍵（純邏輯，欄位名稱均為虛構）
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }

typealias B = PluginSettingsBaseline
typealias P = PluginSettingsProtocol

func field(_ id: String, _ type: String, tab: String = "general", baseline: Bool? = nil) -> P.Field {
    var f = P.Field(id: id, tab: tab, title: "標題-" + id, type: type, help: nil, options: nil)
    f.baseline = baseline
    return f
}
func snapshot(_ fields: [P.Field], _ values: [String: P.Value], configured: [String]? = nil) -> P.Snapshot {
    var s = P.Snapshot(version: 1, title: "範例", revision: "r1",
                       tabs: [P.Tab(id: "general", title: "一般", help: nil), P.Tab(id: "advanced", title: "進階", help: nil)],
                       fields: fields, values: values, actions: [], job: nil)
    s.configured = configured
    return s
}

let all = [field("name", "text"), field("at", "time"), field("mode", "select"), field("days", "stringList"),
           field("tags", "multiselect"), field("on", "toggle"), field("password", "secret", tab: "advanced"),
           field("state", "readonly"), field("preview", "text", baseline: false)]
let full: [String: P.Value] = ["name": .text("甲"), "at": .text("08:30"), "mode": .text("a"), "days": .list(["一"]),
                               "tags": .list(["x"]), "on": .flag(true), "password": .text(""), "state": .text("正常"),
                               "preview": .text("今天")]
let empty: [String: P.Value] = ["name": .text(""), "at": .text(""), "mode": .text(""), "days": .list([]),
                                "tags": .list([]), "on": .flag(false), "password": .text(""), "state": .text(""),
                                "preview": .text("")]
let filled = snapshot(all, full, configured: ["password"])
let blank = snapshot(all, empty, configured: [])

// MARK: 已設定判定
for f in all where !["state", "preview"].contains(f.id) {
    check("\(f.type)：有值算已設定、空值不算", B.isFilled(f, in: filled) && !B.isFilled(f, in: blank))
}
check("secret：configured 列出才算已設定", B.isFilled(all[6], in: filled) && !B.isFilled(all[6], in: blank))
check("readonly 不參與", !B.participates(all[7], in: filled))
check("baseline:false 不參與", !B.participates(all[8], in: filled))
let legacy = snapshot(all, full, configured: nil)
check("沒有 configured 時 secret 不參與", !B.participates(all[6], in: legacy) && B.participates(all[6], in: filled))

// MARK: 記住目前設定
let captured = B.capture(filled)
check("記住目前設定：只收參與且已設定的欄位",
      captured.fields == ["name", "at", "mode", "days", "tags", "on", "password"] && captured.version == 1)
check("記住目前設定：舊外掛不收 secret", !B.capture(legacy).fields.contains("password"))
check("記住目前設定：空的欄位不進基準", B.capture(blank).fields.isEmpty)

// MARK: 缺漏
var lessValues = full
lessValues["on"] = .flag(false)
lessValues["name"] = .text("")
let less = snapshot(all, lessValues, configured: [])
let lessEval = B.evaluate(captured, less)
check("缺漏依 snapshot.fields 順序列出", lessEval.missing.map(\.id) == ["name", "on", "password"])
check("缺漏帶標題與所在頁籤", lessEval.missing.last == B.Missing(id: "password", title: "標題-password", tab: "advanced"))
check("缺漏不會自動從基準移除", lessEval.next == captured)
var changedValues = full
changedValues["at"] = .text("08:40")
check("只改值不算缺漏", B.evaluate(captured, snapshot(all, changedValues, configured: ["password"])).missing.isEmpty)
check("舊外掛不回報 configured 時 secret 不誤報", B.evaluate(captured, legacy).missing.isEmpty)

// MARK: 欄位消失＝不適用
let reduced = snapshot(all.filter { $0.id != "days" }, full, configured: ["password"])
let reducedEval = B.evaluate(captured, reduced)
check("欄位消失不算缺漏、也不從基準移除", reducedEval.missing.isEmpty && reducedEval.next.fields.contains("days"))

// MARK: 往上併入
let partial = B.Record(fields: ["name"])
let up = B.evaluate(partial, filled)
check("新設定好的欄位自動併入基準", up.next.fields == captured.fields && up.next.fields.isSuperset(of: partial.fields))
check("evaluate 冪等", B.evaluate(partial, filled) == up && B.evaluate(up.next, filled).next == up.next)
check("next 永遠包含原基準", B.evaluate(captured, blank).next.fields.isSuperset(of: captured.fields))

// MARK: 這是刻意的
let acknowledged = B.acknowledge(["on"], in: captured)
check("這是刻意的：從基準移除該欄位", !acknowledged.fields.contains("on")
      && B.evaluate(acknowledged, less).missing.map(\.id) == ["name", "password"])
check("刻意移除後重新設定好又自動併回", B.evaluate(acknowledged, filled).next.fields.contains("on"))

// MARK: 通知鍵
let a = B.Missing(id: "b", title: "乙", tab: "general"), c = B.Missing(id: "a", title: "甲", tab: "general")
check("通知鍵與順序無關", B.notificationKey([a, c]) == B.notificationKey([c, a]) && B.notificationKey([a, c]) == "a,b")
check("通知鍵隨缺漏組合改變", B.notificationKey([a]) != B.notificationKey([a, c]))
check("缺漏描述過濾控制字元", B.summary([B.Missing(id: "x", title: "密碼\u{202E}\u{0007}", tab: "g"), c]) == "設定比基準少了：密碼、甲")

// MARK: 存檔格式
let encoded = try! JSONEncoder().encode(captured)
check("基準檔可往返", (try? JSONDecoder().decode(B.Record.self, from: encoded)) == captured)

print("通過 \(pass)，失敗 \(fail)")
