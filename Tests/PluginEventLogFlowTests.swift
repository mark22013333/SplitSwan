import AppKit
import Foundation
// 安裝記錄接進實際流程：匯入、升級、啟用、執行、總開關關閉。記錄一律寫在暫存目錄並讀回，不碰 ~/Library/Logs
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) { if ok { passed += 1 } else { failed += 1; print("❌ " + name) } }
typealias Log = PluginEventLog

@MainActor
func runFlow() async throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    let fixtures = root.appendingPathComponent("fixtures")
    NSApplication.shared.setActivationPolicy(.accessory)
    var count = 0
    func runner(allowInactive: Bool = false, runtimes: [String] = PluginPackage.runtimeDirectories, directory: URL? = nil) throws -> (PluginRunner, Log, URL) {
        count += 1
        let base = root.appendingPathComponent("case\(count)")
        try PluginPackageStore.createSecureDirectory(base)
        let logDir = base.appendingPathComponent("logs")
        let r = PluginRunner(directory: directory ?? base.appendingPathComponent("plugins"), stateRoot: base.appendingPathComponent("state"),
                             allowInactiveExecution: allowInactive, preferences: UserDefaults(suiteName: "SplitSwan.LogFlow." + UUID().uuidString)!,
                             packageRoot: base.appendingPathComponent("packages"), appVersion: "1.8.6", runtimeDirectories: runtimes)
        let log = Log(directory: logDir)
        r.eventLog = log
        return (r, log, logDir)
    }
    func records(_ log: Log) async -> [Log.Record] { await log.recent(limit: 100) }
    func until(_ log: Log, _ ready: ([Log.Record]) -> Bool) async -> [Log.Record] {
        let end = Date().addingTimeInterval(5)
        var all = await records(log)
        while !ready(all), Date() < end { try? await Task.sleep(for: .milliseconds(10)); all = await records(log) }
        return all
    }
    func fileFacts(_ url: URL) throws -> [Log.Fact] {
        let data = try Data(contentsOf: url)
        return [.fileSize(data.count), .sha256(PluginPackage.hash(data))]
    }
    func topPaths(_ r: Log.Record?) -> [String]? {
        r?.facts.lazy.compactMap { if case .topPaths(let p) = $0 { return p } else { return nil } }.first
    }

    // (a) 重新壓縮的安裝包
    do {
        let (r, log, _) = try runner()
        let source = fixtures.appendingPathComponent("repacked-folder.splitswan-plugin")
        await PluginPackageModel(runner: r).prepare(source)
        let all = await records(log)
        check("(a) 重新壓縮：同一 attempt 依序 started → failed", all.map(\.outcome) == [.started, .failed] && Set(all.map(\.attempt)).count == 1 && all.allSatisfy { $0.operation == .importPackage })
        check("(a) started 帶 App 版本與 macOS", all.first?.stage == .read && all.first?.facts.contains { if case .appVersion = $0 { return true } else { return false } } == true
              && all.first?.facts.contains { if case .macOS = $0 { return true } else { return false } } == true)
        let f = all.last
        check("(a) failure=archive.repacked、stage=archive", f?.failure == .archiveRepacked && f?.stage == .archive)
        let expected = try fileFacts(source)
        check("(a) facts 含安裝包大小與 SHA-256", expected.allSatisfy { f?.facts.contains($0) == true })
        check("(a) facts 含排序後的頂層路徑", topPaths(f).map { $0 == $0.sorted() && $0.contains("example-plugin/manifest.json") && $0.count <= 10 } == true)
    }

    // (b) 同名舊腳本內容與宣告不符
    do {
        let legacyDir = root.appendingPathComponent("legacy-mismatch")
        try PluginPackageStore.createSecureDirectory(legacyDir)
        let entry = legacyDir.appendingPathComponent("legacy.1m.sh")
        let changed = Data("#!/bin/sh\necho changed\n".utf8)
        try changed.write(to: entry); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entry.path)
        let (r, log, _) = try runner(directory: legacyDir)
        r.scan()
        let source = fixtures.appendingPathComponent("legacy-upgrade.splitswan-plugin")
        let model = PluginPackageModel(runner: r)
        await model.prepare(source)
        let all = await records(log)
        let f = all.last
        check("(b) 舊腳本不符：started → failed，畫面文字不變", all.map(\.outcome) == [.started, .failed] && model.message == PluginFailure.legacyContentMismatch.message)
        check("(b) failure=legacy.contentMismatch、stage=legacy、plugin=manifest id", f?.failure == .legacyContentMismatch && f?.stage == .legacy && f?.plugin == "org.example.fixture")
        check("(b) legacyScript 的 SHA-256 是舊腳本實際內容的雜湊", f?.facts.contains(.legacyScript(name: "legacy.1m.sh", sha256: PluginPackage.hash(changed))) == true)
        check("(b) 也帶安裝包大小與雜湊", try fileFacts(source).allSatisfy { f?.facts.contains($0) == true })
    }

    // (c) 缺少執行環境時啟用
    do {
        let (r, log, _) = try runner(runtimes: [])
        let prepared = try PluginPackage.prepare(fixtures.appendingPathComponent("valid.splitswan-plugin"), appVersion: "1.8.6")
        defer { prepared.discard() }
        try await r.installPackage(prepared)
        r.setPluginEnabled("package:org.example.fixture", true)
        let all = await until(log) { $0.contains { $0.outcome == .failed } }
        let f = all.first { $0.outcome == .failed }
        check("(c) 啟用失敗：operation=enable、failure=store.missingRuntime、stage=enable",
              f?.operation == .enable && f?.failure == .storeMissingRuntime && f?.stage == .enable && f?.plugin == "org.example.fixture")
        check("(c) 畫面仍顯示原本的缺少執行環境訊息", r.plugins.first?.problem?.contains("缺少執行環境") == true)
    }

    // (d) 外掛連續 3 次非 0 結束後成功
    let flaky = Data("""
        #!/bin/sh
        n=$(cat "$SPLITSWAN_PLUGIN_STATE/n" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$SPLITSWAN_PLUGIN_STATE/n"
        if [ "$n" -le 3 ]; then echo "boom $n" >&2; exit 3; fi
        echo OK

        """.utf8)
    func flakyDir(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try PluginPackageStore.createSecureDirectory(dir)
        let file = dir.appendingPathComponent("flaky.1m.sh")
        try flaky.write(to: file); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return dir
    }
    do {
        let (r, log, _) = try runner(allowInactive: true, directory: try flakyDir("flaky-run"))
        r.scan()
        check("(d) 測試外掛通過權限檢查", r.plugins.count == 1 && r.plugins[0].problem == nil)
        for _ in 0..<4 { await r.run("flaky.1m.sh") }
        check("(d) 第 4 次成功輸出 OK", r.plugins.first?.output?.title == "OK" && r.plugins.first?.error == nil)
        let all = await records(log)
        check("(d) 共 3 筆：failed、repeats=2 摘要、recovered", all.count == 3 && all.map(\.outcome) == [.failed, .failed, .recovered]
              && all[0].repeats == nil && all[1].repeats == 2 && all.allSatisfy { $0.operation == .run && $0.plugin == "flaky.1m.sh" })
        check("(d) 第一筆 failure=runner.exitNonZero、exitCode=3、stderr 尾端", all.first?.failure == .runnerExitNonZero && all.first?.facts.contains(.exitCode(3)) == true
              && all.first?.facts.contains { if case .stderrTail(let t) = $0 { return t.contains("boom 1") } else { return false } } == true)
    }
    do {
        let dir = try flakyDir("unsafe-run")
        try fm.setAttributes([.posixPermissions: 0o722], ofItemAtPath: dir.appendingPathComponent("flaky.1m.sh").path)
        let (r, log, _) = try runner(allowInactive: true, directory: dir)
        r.scan()
        for _ in 0..<2 { await r.run("flaky.1m.sh") }
        let all = await records(log)
        check("執行前安全檢查擋下時記錄 runner.unsafe 與原因，重複擋下只記一筆", all.count == 1 && all[0].failure == .runnerUnsafe && all[0].stage == .run
              && all[0].detail?.isEmpty == false)
    }

    // (e) 外掛總開關關閉：執行、掃描、重新整理都不寫記錄
    do {
        let (r, _, logDir) = try runner(directory: try flakyDir("flaky-off"))
        r.start()
        r.scan()
        await r.run("flaky.1m.sh")
        await r.refreshAll()
        r.requestRefresh()
        try await Task.sleep(for: .milliseconds(300))
        check("(e) 關閉時沒有記錄檔也沒有記錄資料夾", !r.isActive && !fm.fileExists(atPath: logDir.appendingPathComponent(Log.fileName).path) && !fm.fileExists(atPath: logDir.path))
        check("(e) 關閉時零資源", r.resources.timers == 0 && !r.resources.watching && r.resources.observers == 0)
    }

    // (f) 成功匯入：同一 attempt 從讀取到安裝；另測取消
    do {
        let (r, log, _) = try runner()
        let model = PluginPackageModel(runner: r)
        let source = fixtures.appendingPathComponent("valid.splitswan-plugin")
        await model.prepare(source)
        let attempt = model.preview?.attempt.id
        await model.install()
        let all = await records(log)
        check("(f) 安裝成功", !model.failed && r.plugins.count == 1)
        check("(f) started(read) → passed(compare) → passed(install)", all.map(\.outcome) == [.started, .passed, .passed] && all.map(\.stage) == [.read, .compare, .install])
        check("(f) 三筆是同一個 attempt，且就是預覽帶著的那個", attempt != nil && all.allSatisfy { $0.attempt == attempt })
        check("(f) compare 與 install 帶 manifest 與安裝包佐證", try ([Log.Fact.manifest(id: "org.example.fixture", version: "1.0.0")] + fileFacts(source)).allSatisfy { f in all.dropFirst().allSatisfy { $0.facts.contains(f) } })
        await model.prepare(source)
        let same = await records(log).suffix(2)
        check("已安裝相同版本也記 passed 並註明", same.map(\.outcome) == [.started, .passed] && same.last?.detail?.contains("相同版本") == true)
        await model.prepare(fixtures.appendingPathComponent("update.splitswan-plugin"))
        model.cancel()
        let cancelled = await until(log) { $0.last?.outcome == .cancelled }
        check("取消預覽記 cancelled，operation 為 update", cancelled.last?.outcome == .cancelled && cancelled.last?.operation == .update && cancelled.last?.plugin == "org.example.fixture")
    }

    // 錯誤碼對應階段
    let domains: Set<String> = ["archive", "manifest", "legacy", "store", "background", "runner", "package"]
    check("每個錯誤碼的領域都在階段對照表內", PluginFailure.allCases.allSatisfy { domains.contains(String($0.rawValue.prefix(while: { $0 != "." }))) })
    check("階段對應抽查", PluginFailure.archiveRepacked.stage == .archive && PluginFailure.legacyContentMismatch.stage == .legacy && PluginFailure.storeMissingRuntime.stage == .enable
          && PluginFailure.packageBadExtension.stage == .read && PluginFailure.backgroundKillFailed.stage == .remove && PluginFailure.runnerExitNonZero.stage == .run
          && PluginFailure.manifestBadShebang.stage == .entrypoint && PluginFailure.storeActivateFailed.stage == .install)
}

do { try await runFlow() } catch { check("記錄流程：\(error.localizedDescription)", false) }
print("通過 \(passed)，失敗 \(failed)")
exit(failed == 0 ? 0 : 1)
