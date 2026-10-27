import Foundation
// 外掛安裝記錄：寫入讀回、權限、symlink、輪替、run 連續失敗合併、遮蔽（全部在暫存目錄，不碰真正的記錄資料夾）
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }

typealias Log = PluginEventLog
typealias Rec = PluginEventLog.Record

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    func tick() -> Date { lock.lock(); defer { lock.unlock() }; t += 1; return t }
}
let clock = Clock()
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("plugin-log-tests-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
var n = 0
func freshDir() -> URL { n += 1; return root.appendingPathComponent("d\(n)") }
func makeLog(_ dir: URL, maxBytes: Int = 256 * 1024) -> Log { Log(directory: dir, now: { clock.tick() }, maxBytes: maxBytes) }
func rec(_ plugin: String? = "demo.plugin", op: Log.Operation = .importPackage, stage: Log.Stage = .manifest, outcome: Log.Outcome = .failed,
         failure: PluginFailure? = .manifestBadFields, detail: String? = nil, facts: [Log.Fact] = [], attempt: UUID = UUID()) -> Rec {
    Rec(time: clock.tick(), attempt: attempt, plugin: plugin, operation: op, stage: stage, outcome: outcome, failure: failure, detail: detail, facts: facts)
}
func perms(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int ?? -1) & 0o777 }
func raw(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
let home = fm.homeDirectoryForCurrentUser.path

// MARK: 寫入與讀回
do {
    let dir = freshDir(), log = makeLog(dir)
    let a = UUID(), b = UUID()
    await log.append(rec(stage: .archive, outcome: .started, failure: nil, facts: [.fileSize(1234), .entryCount(expected: 3, actual: 4), .timedOut, .exitCode(-9)], attempt: a))
    await log.append(rec(stage: .manifest, detail: "缺少 id", facts: [.manifest(id: "demo.plugin", version: "1.2.0")], attempt: a))
    await log.append(rec(op: .remove, stage: .remove, outcome: .passed, failure: nil, attempt: b))
    let got = await log.records(attempt: a)
    check("依 attempt 過濾只讀回該次嘗試的 2 筆", got.count == 2 && got.allSatisfy { $0.attempt == a })
    check("讀回順序與寫入一致，failure 以錯誤碼還原", got.map(\.stage) == [.archive, .manifest] && got[1].failure == .manifestBadFields && got[0].failure == nil)
    check("Fact 讀回後相同（fileSize／entryCount／timedOut／exitCode／manifest）",
          got[0].facts == [.fileSize(1234), .entryCount(expected: 3, actual: 4), .timedOut, .exitCode(-9)] && got[1].facts == [.manifest(id: "demo.plugin", version: "1.2.0")])
    check("recent(limit: 2) 回最後 2 筆", await log.recent(limit: 2).map(\.operation) == [.importPackage, .remove])
    check("別的 attempt 查不到", await log.records(attempt: UUID()).isEmpty)
    let file = dir.appendingPathComponent("plugins.jsonl")
    let lines = raw(file).split(separator: "\n")
    check("檔案一行一筆", lines.count == 3 && lines.allSatisfy { $0.hasPrefix("{") && $0.hasSuffix("}") })
    check("failure 寫成穩定的 raw value 字串", raw(file).contains("\"failure\":\"manifest.badFields\""))
    check("import 的 raw value 是 import", raw(file).contains("\"operation\":\"import\""))
    check("檔案權限 600", perms(file) == 0o600)
    check("資料夾權限 700", perms(dir) == 0o700)
    var bad = raw(file); bad += "不是 JSON\n{\"kind\":1}\n"
    try bad.write(to: file, atomically: false, encoding: .utf8)
    check("損壞的行被略過，其餘照讀", await log.recent(limit: 100).count == 3)
}

// MARK: symlink
do {
    let real = freshDir(); try fm.createDirectory(at: real, withIntermediateDirectories: true)
    let link = freshDir(); try fm.createSymbolicLink(at: link, withDestinationURL: real)
    await makeLog(link).append(rec())
    check("資料夾是 symlink 時不寫（目標資料夾沒有記錄檔）", !fm.fileExists(atPath: real.appendingPathComponent("plugins.jsonl").path))

    let dir = freshDir(); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let victim = dir.appendingPathComponent("victim.txt")
    try Data().write(to: victim)
    try fm.createSymbolicLink(at: dir.appendingPathComponent("plugins.jsonl"), withDestinationURL: victim)
    await makeLog(dir).append(rec())
    check("記錄檔是 symlink 時不寫（目標檔仍是空的）", ((try? fm.attributesOfItem(atPath: victim.path)[.size]) as? Int) == 0)
}

// MARK: 輪替
do {
    let dir = freshDir()
    let probe = makeLog(dir)
    let tag = UUID()
    await probe.append(rec(attempt: tag))
    let size = (try fm.attributesOfItem(atPath: dir.appendingPathComponent("plugins.jsonl").path)[.size] as? Int) ?? 0
    check("探測：單筆記錄大小大於 0", size > 0)
    let dir2 = freshDir()
    let log = makeLog(dir2, maxBytes: size * 5 / 2)
    var ids: [UUID] = []
    for _ in 0..<4 { let id = UUID(); ids.append(id); await log.append(rec(attempt: id)) }
    let cur = dir2.appendingPathComponent("plugins.jsonl"), old = dir2.appendingPathComponent("plugins.1.jsonl")
    check("超過 maxBytes 後輪替出舊檔", fm.fileExists(atPath: old.path) && fm.fileExists(atPath: cur.path))
    check("讀取跨兩個檔，4 筆都在且順序正確", await log.recent(limit: 100).map(\.attempt) == ids)
    check("舊檔權限仍是 600", perms(old) == 0o600)
    for _ in 0..<2 { let id = UUID(); ids.append(id); await log.append(rec(attempt: id)) }
    check("再輪替一次後只留一份舊檔（沒有 plugins.2.jsonl）", !fm.fileExists(atPath: dir2.appendingPathComponent("plugins.2.jsonl").path))
    let left = await log.recent(limit: 100).map(\.attempt)
    check("最早的 3 筆已被捨棄，後 3 筆保留", left == Array(ids[3...]))
}

// MARK: run 連續失敗合併
func runRec(_ outcome: Log.Outcome, _ failure: PluginFailure? = nil, _ plugin: String = "p.one") -> Rec {
    rec(plugin, op: .run, stage: .run, outcome: outcome, failure: failure)
}
do {
    let log = makeLog(freshDir())
    for _ in 0..<5 { await log.append(runRec(.failed, .runnerBusy)) }
    var all = await log.recent(limit: 100)
    check("連續相同失敗 5 次只寫 1 筆", all.count == 1 && all[0].repeats == nil)
    await log.append(runRec(.passed))
    all = await log.recent(limit: 100)
    check("恢復時依序寫出：原失敗、repeats=4 摘要、recovered", all.count == 3 && all[1].repeats == 4 && all[1].outcome == .failed && all[2].outcome == .recovered)
    check("摘要帶 firstTime 且不晚於摘要時間，failure 保留", all[1].firstTime != nil && all[1].firstTime! <= all[1].time && all[1].failure == .runnerBusy)
    await log.append(runRec(.passed))
    check("恢復之後再成功不再寫入", await log.recent(limit: 100).count == 3)
}
do {
    let dir = freshDir(), log = makeLog(dir)
    await log.append(runRec(.failed, .runnerBusy))
    await log.append(rec())
    check("執行記錄寫進 plugin-runs.jsonl，安裝類記錄留在 plugins.jsonl",
          raw(dir.appendingPathComponent("plugin-runs.jsonl")).contains("runner.busy") && !raw(dir.appendingPathComponent("plugins.jsonl")).contains("runner.busy")
          && !raw(dir.appendingPathComponent("plugins.jsonl")).isEmpty)
    check("讀取時兩檔依時間合併", await log.recent(limit: 10).count == 2)
}
do {
    let log = makeLog(freshDir())
    for _ in 0..<61 { await log.append(runRec(.failed, .runnerBusy)) }
    var all = await log.recent(limit: 200)
    check("累計達 60 次寫出 repeats=60 摘要（共 1 筆原始＋1 筆摘要）", all.count == 2 && all[1].repeats == 60)
    await log.append(runRec(.failed, .runnerBusy))
    check("摘要之後繼續合併，不立刻再寫新行", await log.recent(limit: 200).count == 2)
    await log.append(runRec(.passed))
    all = await log.recent(limit: 200)
    check("恢復時再寫出 repeats=1 摘要與 recovered", all.count == 4 && all[2].repeats == 1 && all[3].outcome == .recovered)
}
do {
    let log = makeLog(freshDir())
    await log.append(runRec(.passed))
    check("run 成功且沒有先前失敗時不寫", await log.recent(limit: 10).isEmpty)
    await log.append(runRec(.failed, .runnerBusy)); await log.append(runRec(.failed, .runnerBusy)); await log.append(runRec(.failed, .runnerBusy))
    await log.append(runRec(.failed, .runnerChangedOrRemoved))
    let all = await log.recent(limit: 10)
    check("failure 改變時先寫出前一個的摘要（repeats=2），再寫新的", all.count == 3 && all[1].repeats == 2 && all[1].failure == .runnerBusy && all[2].failure == .runnerChangedOrRemoved && all[2].repeats == nil)
    await log.append(runRec(.failed, .runnerBusy, "p.two")); await log.append(runRec(.failed, .runnerBusy, "p.two"))
    await log.append(runRec(.failed, .runnerChangedOrRemoved, "p.one"))
    let two = await log.recent(limit: 10)
    check("不同外掛各自合併，互不影響", two.count == 4 && two[3].plugin == "p.two")
    await log.append(rec("p.one", op: .remove, stage: .remove, outcome: .failed, failure: .storeRemoveChanged))
    await log.append(rec("p.one", op: .remove, stage: .remove, outcome: .failed, failure: .storeRemoveChanged))
    check("非 run 的失敗不合併，每筆都寫", await log.recent(limit: 20).filter { $0.operation == .remove }.count == 2)
}

// MARK: 遮蔽
do {
    let dir = freshDir(), log = makeLog(dir)
    let sha = String(repeating: "ab12cd34", count: 8)
    let hex40 = String(repeating: "9f8e7d6c5b", count: 4)
    let detail = [
        "password=hunter2-fixture",
        "Authorization: Basic dXNlcjpwYXNzRklYVFVSRQ",
        "curl -H 'Bearer abcdefghijklmnopqrstuvwxyz0123456789' failed",
        "download https://example.com/cal.ics?token=SECRETFIXTURE#frag404 failed",
        "ical https://calendar.example.org/ical/private-PATHTOKENFIX/basic.ics",
        "api_key=KEYFIXTURE99",
        "fetch https://alice:USERINFOPW@calendar.example.org/x failed",
        "Cookie: sid=COOKIEFIXTURE; theme=dark",
        "Set-Cookie: SETCOOKIEFIX=1",
        "apikey=APIKEYFIX pass=PASSFIX sid=SIDFIX",
        "路徑 \(home)/Library/Application Support/demo",
        "雜湊 \(hex40)",
    ].joined(separator: "\n")
    let tail = String(repeating: "錯誤 ", count: 600)
    let id = UUID()
    await log.append(rec(detail: detail, facts: [.sha256(sha), .legacyScript(name: "old.sh", sha256: sha), .topPaths(["\(home)/x/y", "plain/path"]), .stderrTail(tail), .manifest(id: "demo", version: "1.0.0")], attempt: id))
    let file = dir.appendingPathComponent("plugins.jsonl")
    let text = raw(file)
    for secret in ["hunter2-fixture", "abcdefghijklmnopqrstuvwxyz0123456789", "SECRETFIXTURE", "KEYFIXTURE99", "dXNlcjpwYXNzRklYVFVSRQ", "frag404", "PATHTOKENFIX", "cal.ics", "USERINFOPW", "alice", "COOKIEFIXTURE", "SETCOOKIEFIX", "APIKEYFIX", "PASSFIX", "SIDFIX", home, hex40] {
        check("原始檔不含「\(secret)」", !text.contains(secret))
    }
    check("家目錄路徑換成 ~", text.contains("~/Library/Application Support/demo") && text.contains("~/x/y"))
    check("URL 只保留 scheme 與主機", text.contains("download https://example.com failed") && text.contains("ical https://calendar.example.org"))
    check("sha256 Fact 的 64 位 hex 原樣保留", text.contains("\"value\":\"\(sha)\"") && text.contains("\"sha256\":\"\(sha)\""))
    let back = await log.records(attempt: id)
    check("sha256 讀回與原值相同", back.first?.facts.first == .sha256(sha))
    check("一般文字不被誤傷（plain/path、錯誤碼、版本）", text.contains("plain/path") && text.contains("\"version\":\"1.0.0\"") && text.contains("manifest.badFields"))
    if case .stderrTail(let t)? = back.first?.facts.first(where: { if case .stderrTail = $0 { return true } else { return false } }) {
        check("stderrTail 超過 1024 bytes 被截斷", t.utf8.count <= 1024 && t.utf8.count >= 1020)
        check("截斷後仍是合法 UTF-8（原始檔可解碼）", (try? String(contentsOf: file, encoding: .utf8)) != nil && t.hasSuffix("錯誤 ") )
    } else { check("stderrTail 讀得回來", false) }
    await log.append(rec(facts: [.sha256("not-a-sha"), .sha256(sha.uppercased()), .legacyScript(name: "x", sha256: "zz"), .topPaths((0..<15).map { "p\($0)" })], attempt: id))
    let last = (await log.records(attempt: id)).last!
    check("格式不合的 sha256（含大寫、舊腳本）整筆丟棄", last.facts.count == 1)
    if case .topPaths(let p) = last.facts[0] { check("topPaths 最多 10 個", p.count == 10) } else { check("topPaths 最多 10 個", false) }
}

try? fm.removeItem(at: root)
print("通過 \(pass)，失敗 \(fail)")
