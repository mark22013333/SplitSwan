import Foundation
import AppKit

var passed = 0, failed = 0
func check(_ name: String, _ condition: Bool) { if condition { passed += 1 } else { failed += 1; print("❌ " + name) } }
func rejected(_ name: String, _ body: () throws -> Void) { do { try body(); check(name, false) } catch { check(name, true) } }
@MainActor
func runTests() async throws {
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let fixtures = root.appendingPathComponent("fixtures")
struct Case: Decodable { let file: String; let valid: Bool; let message: String? }
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixtures.appendingPathComponent("cases.json")))
for c in cases {
    do {
        let p = try PluginPackage.prepare(fixtures.appendingPathComponent(c.file), appVersion: "1.8.6")
        p.discard(); check("Swift 共用案例：" + c.file, c.valid)
    } catch {
        let message = error.localizedDescription
        check("Swift 共用案例：" + c.file + "：" + message, !c.valid && (c.message.map { message.contains($0) } ?? true))
    }
}
// 已隔離下載的來源，確認信任後才安裝，匯出仍保留來源隔離資訊。
let quarantinedURL = root.appendingPathComponent("quarantined.splitswan-plugin")
try fm.copyItem(at: fixtures.appendingPathComponent("valid.splitswan-plugin"), to: quarantinedURL)
let quarantine = Data("0081;00000000;SplitSwanPackageTest;".utf8)
let tagged = quarantine.withUnsafeBytes { setxattr(quarantinedURL.path, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, 0) }
check("可建立測試隔離來源", tagged == 0)
let quarantined = try PluginPackage.prepare(quarantinedURL, appVersion: "1.8.6")
defer { quarantined.discard() }
check("匯入不移除原檔隔離標記", PluginPackage.readQuarantine(quarantinedURL.path) == quarantine && quarantined.quarantine == quarantine)
let qStore = PluginPackageStore(root: root.appendingPathComponent("quarantine-store"), appVersion: "1.8.6")
try qStore.install(quarantined, confirmed: true)
let qInstalled = PluginPackageStore.Installed(store: qStore, record: try qStore.read(quarantined.manifest.id))
try qInstalled.check()
let qExport = root.appendingPathComponent("quarantine-export.splitswan-plugin")
try qStore.export(qInstalled, to: qExport)
check("匯出保留隔離來源資訊", PluginPackage.readQuarantine(qExport.path) == quarantine)
let first = try PluginPackage.prepare(fixtures.appendingPathComponent("valid.splitswan-plugin"), appVersion: "1.8.6")
let second = try PluginPackage.prepare(fixtures.appendingPathComponent("update.splitswan-plugin"), appVersion: "1.8.6")
let same = try PluginPackage.prepare(fixtures.appendingPathComponent("same-version.splitswan-plugin"), appVersion: "1.8.6")
defer { first.discard(); second.discard(); same.discard() }
// 注入空的執行環境搜尋路徑，與開發機是否已安裝 Node／Python 無關。
let missingStore = PluginPackageStore(root: root.appendingPathComponent("missing-runtime-store"), appVersion: "1.8.6", runtimeDirectories: [])
try missingStore.install(first, confirmed: true)
rejected("缺少執行環境不得啟用") { try missingStore.setEnabled(first.manifest.id, true) }
let missingInstalled = PluginPackageStore.Installed(store: missingStore, record: try missingStore.read(first.manifest.id))
let missingState = root.appendingPathComponent("missing-runtime-state")
let missingRun = await PluginRunner.execute(path: missingInstalled.entrypoint, id: missingInstalled.id, pluginDir: "", stateRoot: missingState.path, args: [], timeout: 1, parse: true, package: missingInstalled)
check("缺少依賴時零執行、零狀態寫入", missingRun.problem?.contains("缺少執行環境") == true && !fm.fileExists(atPath: missingState.path))
let store = PluginPackageStore(root: root.appendingPathComponent("store"), appVersion: "1.8.6")
check("固定識別碼與完整多檔清單", first.manifest.id == "org.example.fixture" && first.manifest.files.count == 3)
rejected("未確認不得安裝") { try store.install(first, confirmed: false) }
try store.install(first, confirmed: true)
let initial = try store.read(first.manifest.id)
check("新安裝預設停用", !initial.enabled)
check("相同內容免重裝", try store.change(for: first) == .identical)
rejected("同版本改內容拒絕") { _ = try store.change(for: same) }
let installed = PluginPackageStore.Installed(store: store, record: initial)
try installed.check()
let exported = root.appendingPathComponent("export.splitswan-plugin")
try store.export(installed, to: exported)
let roundtrip = try PluginPackage.prepare(exported, appVersion: "1.8.6")
check("匯出再匯入保持內容", roundtrip.digest == first.digest);roundtrip.discard()
rejected("匯出不得覆寫管理目錄") { try store.export(installed, to: installed.root.appendingPathComponent("manifest.json")) }
try store.setEnabled(first.manifest.id, true)
try store.install(second, confirmed: true)
let updated = try store.read(first.manifest.id)
check("更新保留啟用狀態與前一版本", updated.enabled && updated.previous == first.digest && updated.manifest.version == "1.1.0")
rejected("降版拒絕") { _ = try store.change(for: first) }
rejected("舊排隊描述不可在更新後執行") { try installed.check() }
let current = PluginPackageStore.Installed(store: store, record: updated)
let original = try Data(contentsOf: current.root.appendingPathComponent("main.sh"))
try Data("tampered".utf8).write(to: current.root.appendingPathComponent("main.sh"))
rejected("程式遭修改阻擋執行") { try current.check() }
rejected("程式遭修改阻擋匯出") { try store.export(current, to: root.appendingPathComponent("bad-export.zip")) }
try original.write(to: current.root.appendingPathComponent("main.sh"))
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.root.appendingPathComponent("main.sh").path)
try Data().write(to: current.root.appendingPathComponent("unexpected"))
rejected("套件多出檔案阻擋") { try current.check() }
try fm.removeItem(at: current.root.appendingPathComponent("unexpected"))
try fm.setAttributes([.posixPermissions: 0o770], ofItemAtPath: current.root.path)
rejected("不安全資料夾權限阻擋") { try current.check() }
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.root.path)
let resource = current.root.appendingPathComponent("resources/defaults.json")
let resourceData = try Data(contentsOf: resource)
try fm.removeItem(at: resource);try fm.createSymbolicLink(atPath: resource.path, withDestinationPath: "/etc/hosts")
rejected("資源 symlink 阻擋") { try current.check() }
try fm.removeItem(at: resource);try resourceData.write(to: resource);try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resource.path)
// 驗證來源 ZIP 遭替換，payload 完整也不能匯出。
let archive = current.root.deletingLastPathComponent().appendingPathComponent("source.zip")
let archiveData = try Data(contentsOf: archive)
try Data("broken".utf8).write(to: archive)
rejected("匯出重新驗證來源 ZIP") { try store.export(current, to: root.appendingPathComponent("bad-source.zip")) }
try archiveData.write(to: archive)
// 觀察實際假程序與狀態，不以方法呼叫次數模擬互斥。
let prefs = UserDefaults(suiteName: "SplitSwan.PackageTests." + UUID().uuidString)!
let runner = PluginRunner(directory: root.appendingPathComponent("missing-legacy"), stateRoot: root.appendingPathComponent("state"), allowInactiveExecution: true, preferences: prefs, packageRoot: root.appendingPathComponent("runner-packages"), appVersion: "1.8.6")
try await runner.installPackage(first)
let id = "package:" + first.manifest.id
let state = root.appendingPathComponent("state/packages/" + first.manifest.id)
check("沒有舊資料夾仍掃描套件", runner.plugins.count == 1 && runner.folderMissing)
check("匯入不執行、不建立私人狀態", !fm.fileExists(atPath: state.path) && !runner.plugins[0].isEnabled && !runner.isActive)
await runner.run(id)
check("新安裝停用不執行", !fm.fileExists(atPath: state.path))
runner.setPluginEnabled(id, true)
await runner.run(id)
check("直接執行假外掛並取得套件環境", runner.plugins[0].output?.title == "Package Fixture" && (try? String(contentsOf: state.appendingPathComponent("id"), encoding: .utf8)) == first.manifest.id)
check("多檔外掛能讀取套件資源", (try? String(contentsOf: state.appendingPathComponent("resource"), encoding: .utf8)) == "{\"example\":true}\n")
try Data("private-state".utf8).write(to: state.appendingPathComponent("settings.json"))
try Data().write(to: state.appendingPathComponent("hold"))
let running = Task { await runner.run(id) }
func until(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(8)
    while !condition(), Date() < deadline { await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}
check("假程序已進入可觀測等待點", await until { fm.fileExists(atPath: state.appendingPathComponent("started").path) })
let updating = Task { try await runner.installPackage(second) }
await Task.yield()
check("舊程序進行中仍使用舊 active", (try? runner.packageStore.read(first.manifest.id).digest) == first.digest)
try fm.removeItem(at: state.appendingPathComponent("hold"))
await running.value
try await updating.value
check("舊結果不會交付至新版", runner.plugins[0].output == nil)
check("更新保留私人設定及啟用狀態", (try? String(contentsOf: state.appendingPathComponent("settings.json"), encoding: .utf8)) == "private-state" && runner.plugins[0].isEnabled)
await runner.run(id)
check("下一次執行使用新版本", runner.plugins[0].output?.items.contains(where: { $0.text == "version=1.1.0" }) == true)
check("管理操作未啟用全域排程", !runner.isActive && runner.resources.timers == 0 && !runner.resources.watching)
// 移除等待實際程序結束，不交付舊結果；測試垃圾桶使用暫存目錄，避免碰使用者垃圾桶。
let trashRoot = root.appendingPathComponent("test-trash")
try fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)
let trash: PluginPackageStore.TrashOperation = { url in
    try FileManager.default.moveItem(at: url, to: trashRoot.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
}
let selected = runner.plugins.first { $0.id == id }!
do {
    try await runner.removePlugin(selected, trash: { _ in throw PluginPackage.fail("fixture trash failure") })
    check("垃圾桶失敗不可回報移除成功", false)
} catch { check("移除失敗保留原版本並停用，避免恢復排程", (try? runner.packageStore.read(first.manifest.id).enabled) == false && runner.plugins.contains { $0.id == id }) }
runner.setPluginEnabled(id, true)
try fm.removeItem(at: state.appendingPathComponent("started"))
try Data().write(to: state.appendingPathComponent("hold"))
let lastRun = Task { await runner.run(id) }
check("移除前假工作已啟動", await until { fm.fileExists(atPath: state.appendingPathComponent("started").path) })
let removing = Task { try await runner.removePlugin(selected, trash: trash) }
check("移除開始即停用持久設定，背景工作不能繼續點擊", await until { (try? runner.packageStore.read(first.manifest.id).enabled) != true })
try fm.removeItem(at: state.appendingPathComponent("hold"))
await lastRun.value
try await removing.value
check("移除後不再列出外掛及執行結果", !runner.plugins.contains { $0.id == id } && runner.lastRuns[id] == nil)
check("移除保留私人設定與紀錄", (try? String(contentsOf: state.appendingPathComponent("settings.json"), encoding: .utf8)) == "private-state")
check("套件程式移至測試垃圾桶", (try fm.contentsOfDirectory(atPath: trashRoot.path)).count == 1 && runner.packageStore.discover().installed.isEmpty)
try await runner.installPackage(first)
check("移除後重新匯入視為新安裝且停用", !runner.plugins.first { $0.id == id }!.isEnabled && (try? String(contentsOf: state.appendingPathComponent("settings.json"), encoding: .utf8)) == "private-state")
rejected("舊版本移除描述不能移除重新安裝的不同版本") { try runner.packageStore.remove(selected.package!, trash: trash) }
rejected("移除識別碼不能路徑穿越") { _ = try store.read("../outside") }
// 舊腳本和套件不會自動合併；移除舊腳本只移動入口，不追蹤連結或外部服務。
let legacyDirectory = root.appendingPathComponent("legacy-remove")
try fm.createDirectory(at: legacyDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let legacyEntry = legacyDirectory.appendingPathComponent("legacy.1m.sh")
try Data("#!/bin/sh\necho Legacy\n".utf8).write(to: legacyEntry)
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacyEntry.path)
let legacyState = root.appendingPathComponent("legacy-private")
try fm.createDirectory(at: legacyState, withIntermediateDirectories: true)
try Data("keep".utf8).write(to: legacyState.appendingPathComponent("settings.json"))
let legacyRunner = PluginRunner(directory: legacyDirectory, stateRoot: legacyState, preferences: prefs, packageRoot: root.appendingPathComponent("separate-packages"))
legacyRunner.scan()
try await legacyRunner.removePlugin(legacyRunner.plugins[0], trash: trash)
check("單檔移除不影響周邊資料", legacyRunner.plugins.isEmpty && !fm.fileExists(atPath: legacyEntry.path) && fm.fileExists(atPath: legacyState.appendingPathComponent("settings.json").path))
try fm.createSymbolicLink(at: legacyEntry, withDestinationURL: legacyState.appendingPathComponent("settings.json"))
let linked = PluginRunner.Plugin(id: "legacy.1m.sh", name: "Legacy", interval: 60, path: legacyEntry.path)
// 掃描只列出可執行目標；讓目標可執行以確認「移除連結本身」的邊界。
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacyState.appendingPathComponent("settings.json").path)
legacyRunner.scan()
try await legacyRunner.removePlugin(linked, trash: trash)
check("移除單檔連結不碰外部目標", !fm.fileExists(atPath: legacyEntry.path) && fm.fileExists(atPath: legacyState.appendingPathComponent("settings.json").path))
// 舊入口升級使用共用 manifest 案例；只有完整雜湊相符才可移動。
let replacement = try PluginPackage.prepare(fixtures.appendingPathComponent("legacy-upgrade.splitswan-plugin"), appVersion: "1.8.6")
defer { replacement.discard() }
let upgradeDir = root.appendingPathComponent("upgrade-legacy")
try PluginPackageStore.createSecureDirectory(upgradeDir)
let upgradeEntry = upgradeDir.appendingPathComponent("legacy.1m.sh")
let legacyBytes = try Data(contentsOf: fixtures.appendingPathComponent("legacy.1m.sh"))
func putLegacy(_ bytes: Data) throws {
    try bytes.write(to: upgradeEntry); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: upgradeEntry.path)
}
try putLegacy(legacyBytes)
let upgradeRunner = PluginRunner(directory: upgradeDir, stateRoot: root.appendingPathComponent("upgrade-state"), allowInactiveExecution: true, preferences: UserDefaults(suiteName: "SplitSwan.LegacyUpgrade." + UUID().uuidString)!, packageRoot: root.appendingPathComponent("upgrade-packages"), appVersion: "1.8.6")
upgradeRunner.scan()
let match = try upgradeRunner.legacyReplacement(for: replacement)!
try putLegacy(Data("#!/bin/sh\necho changed\n".utf8))
rejected("同名不同內容不得取代") { _ = try upgradeRunner.legacyReplacement(for: replacement) }
try putLegacy(legacyBytes)
let external = root.appendingPathComponent("external-script")
try fm.moveItem(at: upgradeEntry, to: external)
try fm.createSymbolicLink(at: upgradeEntry, withDestinationURL: external)
rejected("舊入口連結不得取代") { _ = try upgradeRunner.legacyReplacement(for: replacement) }
try fm.removeItem(at: upgradeEntry);try fm.moveItem(at: external, to: upgradeEntry)
let heldState = root.appendingPathComponent("upgrade-state/legacy.1m.sh")
try PluginPackageStore.createSecureDirectory(heldState)
try Data().write(to: heldState.appendingPathComponent("hold"))
let heldRun = Task { await upgradeRunner.run("legacy.1m.sh") }
check("升級前舊入口工作已到等待點", await until { fm.fileExists(atPath: heldState.appendingPathComponent("started").path) })
let replacingTask = Task { try await upgradeRunner.installPackage(replacement, replacing: match) }
await Task.yield()
check("舊工作未結束前不移走入口", fm.fileExists(atPath: upgradeEntry.path))
try fm.removeItem(at: heldState.appendingPathComponent("hold"))
await heldRun.value
try await replacingTask.value
check("升級捨棄舊工作結果", upgradeRunner.lastRuns["legacy.1m.sh"] == nil && upgradeRunner.plugins.allSatisfy { $0.output == nil })
check("升級只保留套件一列並沿用啟用狀態", upgradeRunner.plugins.count == 1 && upgradeRunner.plugins[0].package != nil && upgradeRunner.plugins[0].isEnabled)
let backup = upgradeRunner.latestLegacyBackup!
check("舊入口完整備份，未執行安裝程式", !fm.fileExists(atPath: upgradeEntry.path) && (try? Data(contentsOf: backup)) == legacyBytes && !fm.fileExists(atPath: root.appendingPathComponent("upgrade-state/packages/org.example.fixture/calls").path))
let receiptURL = root.appendingPathComponent("upgrade-state/packages/org.example.fixture/" + PluginLegacyReplacement.receiptName)
let receipt = try JSONDecoder().decode(PluginLegacyReplacement.Receipt.self, from: Data(contentsOf: receiptURL))
check("固定狀態收據指向已驗證備份", receipt.packageID == replacement.manifest.id && receipt.sha256 == match.sha256 && receipt.backup == backup.path)
try putLegacy(legacyBytes)
let failedReplacement = try PluginPackage.prepare(fixtures.appendingPathComponent("legacy-next.splitswan-plugin"), appVersion: "1.8.6")
defer { failedReplacement.discard() }
try Data("damaged".utf8).write(to: failedReplacement.payload.appendingPathComponent("main.sh"))
rejected("升級安裝失敗會回滾") { _ = try PluginLegacyReplacement.commit(failedReplacement, match: match, store: upgradeRunner.packageStore, directory: upgradeDir, stateRoot: root.appendingPathComponent("upgrade-state")) }
check("失敗還原原入口、收據及 active", (try? Data(contentsOf: upgradeEntry)) == legacyBytes && (try? JSONDecoder().decode(PluginLegacyReplacement.Receipt.self, from: Data(contentsOf: receiptURL)).backup) == backup.path && (try? upgradeRunner.packageStore.read(replacement.manifest.id).digest) == replacement.digest)
upgradeRunner.scan();upgradeRunner.setPluginEnabled("legacy.1m.sh", false)
guard let disabledMatch = try upgradeRunner.legacyReplacement(for: replacement) else { throw PluginPackage.fail("測試：復原舊入口遺失") }
try await upgradeRunner.installPackage(replacement, replacing: disabledMatch)
check("停用舊入口升級後仍停用", !upgradeRunner.plugins[0].isEnabled)
// 安裝階段失敗必須保留目前 active。
let failedStore = PluginPackageStore(root: root.appendingPathComponent("failed-store"), appVersion: "1.8.6")
try failedStore.install(first, confirmed: true)
let oldDigest = try failedStore.read(first.manifest.id).digest
try Data("changed staging".utf8).write(to: second.payload.appendingPathComponent("main.sh"))
rejected("暫存損壞更新失敗") { try failedStore.install(second, confirmed: true) }
check("更新失敗原版本仍有效", try failedStore.read(first.manifest.id).digest == oldDigest)
try PluginPackageStore.Installed(store: failedStore, record: failedStore.read(first.manifest.id)).check()
check("SemVer prerelease 排序", PluginPackage.Version("1.0.0-beta.2")! < PluginPackage.Version("1.0.0-beta.11")! && PluginPackage.Version("1.0.0-rc.1")! < PluginPackage.Version("1.0.0")!)
}
do { try await runTests() } catch { check("套件整合流程：\(error.localizedDescription)", false) }
print("通過 \(passed)，失敗 \(failed)")
exit(failed == 0 ? 0 : 1)
