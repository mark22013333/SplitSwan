import Foundation
// 外掛診斷資訊與診斷報告：排版的確切輸出、分段、遮蔽、寫檔權限與原子替換（全部在暫存目錄）
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
func same(_ n: String, _ got: String, _ want: String) {
    check(n, got == want)
    if got != want { print("--- 實際 ---\n\(got)\n--- 預期 ---\n\(want)") }
}

typealias Rec = PluginEventLog.Record
let taipei = TimeZone(identifier: "Asia/Taipei")!
let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 16:00:00 +08:00
let importID = UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001")!
let runID = UUID(uuidString: "99887766-0000-4000-8000-000000000002")!
let hash = String(repeating: "a", count: 64), legacyHash = String(repeating: "b", count: 64)

let importRecords = [
    Rec(time: t0, attempt: importID, operation: .importPackage, stage: .read, outcome: .started,
        facts: [.appVersion("1.9.6"), .macOS("Version 15.1")]),
    Rec(time: t0 + 2, attempt: importID, plugin: "org.example.demo", operation: .importPackage, stage: .payload, outcome: .failed,
        failure: .archiveHashMismatch, detail: "payload/run.sh",
        facts: [.fileSize(2048), .sha256(hash), .entryCount(expected: 3, actual: 4), .topPaths(["manifest.json", "payload"]),
                .manifest(id: "org.example.demo", version: "1.0.0")]),
]

same("summary：標頭、操作、事件、失敗訊息、facts 的確切輸出",
     PluginDiagnostics.summary(importRecords, appVersion: "1.9.6", build: "33", macOS: "15.1", timeZone: taipei), """
SplitSwan 1.9.6（build 33）· macOS 15.1
操作 1a2b3c4d · import · -
16:00:00 read started
  App 版本 1.9.6 · macOS Version 15.1
16:00:02 payload failed archive.hashMismatch
  檔案雜湊不符：payload/run.sh
  大小 2048 bytes · SHA-256 \(hash) · ZIP 項目 預期 3／實際 4 · 頂層路徑 manifest.json、payload · Manifest org.example.demo 1.0.0
""")

let runRecords = [
    Rec(time: t0 + 60, attempt: runID, plugin: "punch.1m.sh", operation: .run, stage: .run, outcome: .failed,
        failure: .runnerExitNonZero, facts: [.exitCode(2), .stderrTail("curl: (6) Could not resolve host")]),
    Rec(time: t0 + 600, attempt: runID, plugin: "punch.1m.sh", operation: .run, stage: .run, outcome: .failed,
        failure: .runnerTimedOut, facts: [.timedOut], repeats: 4, firstTime: t0 + 120),
    Rec(time: t0 + 610, attempt: runID, plugin: "punch.1m.sh", operation: .legacyUpgrade, stage: .legacy, outcome: .failed,
        detail: "磁碟已滿", facts: [.legacyScript(name: "punch.1m.sh", sha256: legacyHash)]),
]
same("summary：結束碼、stderr、逾時、合併次數、沒有錯誤碼的失敗只顯示描述",
     PluginDiagnostics.summary(runRecords, appVersion: "1.9.6", build: "33", macOS: "15.1", timeZone: taipei), """
SplitSwan 1.9.6（build 33）· macOS 15.1
操作 99887766 · run · punch.1m.sh
16:01:00 run failed runner.exitNonZero
  外掛結束碼不是 0
  結束碼 2 · stderr：curl: (6) Could not resolve host
16:10:00 run failed runner.timedOut（另 4 次相同失敗，自 16:02:00）
  外掛執行逾時
  逾時
16:10:10 legacy failed
  磁碟已滿
  舊腳本 punch.1m.sh SHA-256 \(legacyHash)
""")

same("summary：沒有記錄時說明找不到",
     PluginDiagnostics.summary([], appVersion: "1.9.6", build: "33", macOS: "15.1", timeZone: taipei), """
SplitSwan 1.9.6（build 33）· macOS 15.1
找不到這次操作的記錄
""")

// 兩次操作交錯寫入時，報告依操作分段，各段維持時間順序
let interleaved = [importRecords[0], runRecords[0], importRecords[1], runRecords[1]]
let packages = [PluginDiagnostics.Package(id: "org.example.demo", version: "1.0.0", digest: String(repeating: "c", count: 64), enabled: true, trusted: true),
                PluginDiagnostics.Package(id: "org.example.off", version: "0.3.0", digest: String(repeating: "d", count: 64), enabled: false, trusted: false)]
let report = PluginDiagnostics.report(recent: interleaved, packages: packages,
                                      singleFiles: [.init(name: "punch.1m.sh", sha256: legacyHash), .init(name: "api_token=hunter2hunter2.sh", sha256: hash)],
                                      pluginsEnabled: true, appVersion: "1.9.6", build: "33", macOS: "15.1", generated: t0 + 3600, timeZone: taipei)
let lines = report.components(separatedBy: "\n")
check("report 標頭：標題、產生時間、版本、總開關", Array(lines.prefix(4)) == ["SplitSwan 外掛診斷報告", "產生時間 2027-01-15 17:00:00 +08:00",
                                                                     "SplitSwan 1.9.6（build 33）· macOS 15.1", "外掛總開關 開啟"])
check("report 列出套件 id、版本、digest 前 12 碼、啟用、信任",
      lines.contains("  org.example.demo 1.0.0 · digest cccccccccccc · 已啟用 · 已信任")
      && lines.contains("  org.example.off 0.3.0 · digest dddddddddddd · 已停用 · 未信任") && lines.contains("已安裝套件（2）"))
check("report 列出單檔腳本與 SHA-256", lines.contains("外掛資料夾單檔腳本（2）") && lines.contains("  punch.1m.sh SHA-256 \(legacyHash)"))
check("report 的單檔腳本檔名經遮蔽", !report.contains("hunter2") && lines.contains("  api_token=*** SHA-256 \(hash)"))
check("report 事件筆數", lines.contains("最近事件（4 筆，最多 200 筆）"))
let importHead = lines.firstIndex(of: "操作 1a2b3c4d · import · - · 2027-01-15")
let runHead = lines.firstIndex(of: "操作 99887766 · run · punch.1m.sh · 2027-01-15")
check("report 依操作分段，先出現的操作在前", importHead != nil && runHead != nil && importHead! < runHead!)
if let i = importHead, let r = runHead {
    check("同一操作的事件集中在該段且維持順序", lines[i + 1] == "16:00:00 read started" && lines[i + 3] == "16:00:02 payload failed archive.hashMismatch"
          && lines[r + 1] == "16:01:00 run failed runner.exitNonZero" && lines[r + 4].hasPrefix("16:10:00 run failed runner.timedOut"))
}
check("report 只取最近 200 筆", PluginDiagnostics.report(recent: Array(repeating: importRecords[0], count: 250), packages: [], singleFiles: [],
                                                     pluginsEnabled: false, appVersion: "1", build: "1", macOS: "1", timeZone: taipei)
          .contains("最近事件（200 筆，最多 200 筆）"))

let empty = PluginDiagnostics.report(recent: [], packages: [], singleFiles: [], pluginsEnabled: false,
                                     appVersion: "1.9.6", build: "33", macOS: "15.1", generated: t0, timeZone: taipei)
same("report：全部為空時的確切輸出", empty, """
SplitSwan 外掛診斷報告
產生時間 2027-01-15 16:00:00 +08:00
SplitSwan 1.9.6（build 33）· macOS 15.1
外掛總開關 關閉

已安裝套件（0）
  （無）

外掛資料夾單檔腳本（0）
  （無）

最近事件（0 筆，最多 200 筆）
  （無）

""")
check("預設檔名", PluginDiagnostics.defaultReportName(t0, timeZone: taipei) == "SplitSwan-外掛診斷-20270115-160000.txt")

// MARK: 寫檔與單檔雜湊（暫存目錄）
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("plugin-diag-tests-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
func perms(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int ?? -1) & 0o777 }
func inode(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path)[.systemFileNumber]) as? Int) ?? -1 }
let out = root.appendingPathComponent("SplitSwan-外掛診斷-20270115-160000.txt")
try PluginDiagnostics.writeReport(report, to: out)
check("報告寫入內容完整、權限 600", (try? String(contentsOf: out, encoding: .utf8)) == report && perms(out) == 0o600)
try Data("old".utf8).write(to: out); try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: out.path)
let before = inode(out)
try PluginDiagnostics.writeReport("new", to: out)
check("覆寫既有檔案是改名替換（inode 不同）且恢復 600", (try? String(contentsOf: out, encoding: .utf8)) == "new" && inode(out) != before && perms(out) == 0o600)
let target = root.appendingPathComponent("target.txt"), link = root.appendingPathComponent("link.txt")
try Data("keep".utf8).write(to: target); try fm.createSymbolicLink(at: link, withDestinationURL: target)
try PluginDiagnostics.writeReport("report", to: link)
check("目的地是 symlink 時取代連結本身，不寫到目標", (try? String(contentsOf: target, encoding: .utf8)) == "keep"
      && (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil && (try? String(contentsOf: link, encoding: .utf8)) == "report")
check("寫檔後資料夾沒有殘留暫存檔", ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).allSatisfy { !$0.hasSuffix(".tmp") })
check("資料夾不存在時丟出錯誤", (try? PluginDiagnostics.writeReport("x", to: root.appendingPathComponent("missing/r.txt"))) == nil)

let plugins = root.appendingPathComponent("plugins")
try fm.createDirectory(at: plugins.appendingPathComponent("sub"), withIntermediateDirectories: true)
try Data("hi\n".utf8).write(to: plugins.appendingPathComponent("b.1m.sh"))
try Data("x".utf8).write(to: plugins.appendingPathComponent(".hidden"))
try fm.createSymbolicLink(at: plugins.appendingPathComponent("a.5m.sh"), withDestinationURL: plugins.appendingPathComponent("b.1m.sh"))
try Data().write(to: plugins.appendingPathComponent("c.empty"))
check("可建立 FIFO", mkfifo(plugins.appendingPathComponent("d.fifo").path, 0o600) == 0)
let scripts = PluginDiagnostics.scripts(in: plugins)
let hi = "98ea6e4f216f2fb4b69fff9b3a44842c38686ca685f3f55dc48c5d3fb1107be4"
let emptySHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
check("單檔腳本：第一層一般檔案依名稱排序，略過隱藏檔、資料夾與 FIFO，symlink 不跟隨，空檔案照算",
      scripts == [.init(name: "a.5m.sh", sha256: "（連結，未計算）"), .init(name: "b.1m.sh", sha256: hi), .init(name: "c.empty", sha256: emptySHA)])
check("外掛資料夾不存在時回空清單", PluginDiagnostics.scripts(in: root.appendingPathComponent("none")).isEmpty)

try? fm.removeItem(at: root)
print("通過 \(pass)，失敗 \(fail)")
exit(fail == 0 ? 0 : 1)
