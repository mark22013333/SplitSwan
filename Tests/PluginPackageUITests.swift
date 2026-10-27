import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
func runPackageUI() async throws -> Int {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    let fixtures = root.appendingPathComponent("fixtures")
    let preferences = UserDefaults(suiteName: "SplitSwan.PackageUI." + UUID().uuidString)!
    let runner = PluginRunner(directory: root.appendingPathComponent("plugins"), stateRoot: root.appendingPathComponent("state"), preferences: preferences, packageRoot: root.appendingPathComponent("packages"), appVersion: "1.8.6")
    let model = PluginPackageModel(runner: runner)
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool) { if ok { passed += 1 } else { failed += 1; print("❌ " + name) } }
    func settle(_ ready: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !ready(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentViewController: NSHostingController(rootView: PluginPackageImportView(model: model)))
    window.styleMask = [.titled,.closable,.resizable]
    window.setContentSize(NSSize(width: 700,height: 230))
    window.setFrameOrigin(NSPoint(x: -20000,y: -20000));window.orderBack(nil)
    defer { window.orderOut(nil) }
    let invalid = fixtures.appendingPathComponent("hash-mismatch.splitswan-plugin")
    await model.prepare(invalid)
    check("無效包顯示原因且沒有確認按鈕", model.failed && model.preview == nil && model.message != nil)
    let valid = fixtures.appendingPathComponent("valid.splitswan-plugin")
    await model.prepare(valid, updateID: "package:org.example.other")
    check("指定更新識別碼不符拒絕", model.failed && model.preview == nil)
    await model.prepare(valid)
    check("有效包先預覽，尚未安裝", model.preview != nil && runner.packageStore.discover().installed.isEmpty)
    let staging = model.preview!.prepared.staging
    model.cancel()
    check("取消清理暫存、不安裝", !fm.fileExists(atPath: staging.path) && model.preview == nil && runner.plugins.isEmpty)
    let provider = NSItemProvider(item: valid as NSURL, typeIdentifier: UTType.fileURL.identifier)
    check("單檔拖曳可接受", model.receive([provider]))
    await settle { model.preview != nil || model.failed }
    check("拖曳走相同驗證與預覽流程", model.preview?.prepared.manifest.id == "org.example.fixture")
    await model.install()
    check("確認安裝後顯示停用套件", runner.plugins.count == 1 && !runner.plugins[0].isEnabled && model.preview == nil && !model.failed)
    if model.failed { print("安裝原因：" + (model.message ?? "無")) }
    check("安裝未執行外掛或建立狀態", !fm.fileExists(atPath: root.appendingPathComponent("state").path))
    await model.prepare(valid)
    check("重複匯入有明確訊息、不再次確認", model.preview == nil && model.message?.contains("不需重新安裝") == true)
    await model.prepare(fixtures.appendingPathComponent("update.splitswan-plugin"))
    check("新版呈現更新前後資訊", model.preview?.previous?.version == "1.0.0" && model.preview?.prepared.manifest.version == "1.1.0")
    model.cancel()
    check("多檔拖曳有明確錯誤", !model.receive([provider,provider]) && model.failed && model.message?.contains("一個") == true)
    runner.setRunWhenLocked("package:org.example.fixture", true)
    check("管理頁可保留背景授權，不會因此啟用外掛", runner.plugins[0].runWhenLocked && !runner.plugins[0].isEnabled
          && !fm.fileExists(atPath: root.appendingPathComponent("state").path))
    // 真正 NSHostingController 排版；截圖只包含去識別化範例，不讀真實設定。
    let screenshots = root.appendingPathComponent("screenshots")
    try fm.createDirectory(at: screenshots, withIntermediateDirectories: true)
    for (name,appearance,size) in [("light",NSAppearance.Name.aqua,NSSize(width:720,height:500)),("dark-small",NSAppearance.Name.darkAqua,NSSize(width:620,height:430))] {
        let view = NSHostingController(rootView: Form { Section("外掛") { PluginSettingsView(runner: runner) } }.formStyle(.grouped))
        window.contentViewController = view;window.appearance = NSAppearance(named: appearance);window.setContentSize(size)
        await settle { window.contentView?.bounds.width == size.width }
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { check("原生截圖可建立",false);continue }
        content.cacheDisplay(in: content.bounds,to: bitmap)
        try bitmap.representation(using: .png,properties: [:])!.write(to: screenshots.appendingPathComponent(name + ".png"))
        check("原生管理頁在 \(name) 可排版", content.bounds.width == size.width && content.bounds.height == size.height)
    }
    let keyboard = PluginPackageModel(runner: runner)
    func showKeyboardPreview() async -> Bool {
        await keyboard.prepare(fixtures.appendingPathComponent("update.splitswan-plugin"))
        guard let preview = keyboard.preview else { return false }
        window.contentViewController = NSHostingController(rootView: PluginPackagePreviewView(model: keyboard, preview: preview).background(Color(nsColor: .windowBackgroundColor)))
        window.setContentSize(NSSize(width: 570, height: 530))
        window.contentView?.frame = NSRect(x: 0, y: 0, width: 570, height: 530)
        window.makeKey()
        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        await Task.yield()
        return true
    }
    func key(_ characters: String, code: UInt16) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code) else { return false }
        return window.performKeyEquivalent(with: event)
    }
    if await showKeyboardPreview() {
        for (name, appearance) in [("preview-light", NSAppearance.Name.aqua), ("preview-dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
            if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.effectiveAppearance.performAsCurrentDrawingAppearance {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                }
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: screenshots.appendingPathComponent(name + ".png")) }
            }
        }
        let handled = key("\u{1B}", code: 53)
        await settle { keyboard.preview == nil }
        check("原生 Esc 取消預覽且不更新版本", handled && keyboard.preview == nil && runner.plugins[0].package?.record.manifest.version == "1.0.0")
    } else { check("原生 Esc 預覽可建立", false) }
    if await showKeyboardPreview() {
        let handled = key("\r", code: 36)
        await settle { keyboard.preview == nil && !keyboard.busy }
        check("原生 Return 確認更新", handled && keyboard.preview == nil && !keyboard.failed && runner.plugins[0].package?.record.manifest.version == "1.1.0")
    } else { check("原生 Return 預覽可建立", false) }
    let selected = runner.plugins[0]
    keyboard.beginRemoval(selected)
    check("移除先確認，不執行或移走套件", keyboard.removal?.plugin.id == selected.id && runner.plugins.count == 1)
    await settle { !keyboard.checkingBackground }
    check("自動檢查顯示實際背景結果", keyboard.backgroundSummary.contains("未偵測到") && !keyboard.busy)
    if let removal = keyboard.removal {
        window.contentViewController = NSHostingController(rootView: PluginRemovalView(model: keyboard, removal: removal).background(Color(nsColor: .windowBackgroundColor)))
        window.setContentSize(NSSize(width: 500, height: 370)); window.makeKey()
        window.contentView?.frame = NSRect(x: 0, y: 0, width: 500, height: 370)
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for (name, appearance) in [("remove-light", NSAppearance.Name.aqua), ("remove-dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { check("移除確認頁 \(name) 截圖可建立", false); continue }
            content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: screenshots.appendingPathComponent(name + ".png"))
            check("移除確認頁 \(name) 在小視窗可排版", content.bounds.width == 500 && content.bounds.height == 370)
        }
        let handled = key("\u{1B}", code: 53)
        await settle { keyboard.removal == nil }
        check("原生 Esc 取消移除，版本保持完整", handled && keyboard.removal == nil && runner.plugins.count == 1)
    }
    keyboard.beginRemoval(selected)
    await keyboard.remove(trash: { _ in throw PluginPackage.fail(.storeExportWriteFailed, "fixture trash failure") })
    check("移除失敗留在確認頁並保留套件", keyboard.failed && keyboard.removal != nil && runner.plugins.count == 1)
    let privateState = root.appendingPathComponent("state/packages/org.example.fixture")
    try fm.createDirectory(at: privateState, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: privateState.appendingPathComponent("settings.json"))
    let trash = root.appendingPathComponent("removed-package")
    await keyboard.remove(trash: { try FileManager.default.moveItem(at: $0, to: trash) })
    check("確認移除後清除清單、保留設定且不執行外掛", keyboard.removal == nil && !keyboard.failed && runner.plugins.isEmpty && fm.fileExists(atPath: trash.path) && fm.fileExists(atPath: privateState.appendingPathComponent("settings.json").path))
    // 同名入口與套件固定識別碼都相符時顯示獨立升級確認；取消不得移動入口。
    let legacyDir = root.appendingPathComponent("legacy-upgrade")
    try PluginPackageStore.createSecureDirectory(legacyDir)
    let legacyEntry = legacyDir.appendingPathComponent("legacy.1m.sh")
    try fm.copyItem(at: fixtures.appendingPathComponent("legacy.1m.sh"), to: legacyEntry)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacyEntry.path)
    let legacyRunner = PluginRunner(directory: legacyDir, stateRoot: root.appendingPathComponent("legacy-state"), preferences: preferences, packageRoot: root.appendingPathComponent("legacy-packages"), appVersion: "1.8.6")
    legacyRunner.scan()
    let legacyModel = PluginPackageModel(runner: legacyRunner)
    await legacyModel.prepare(fixtures.appendingPathComponent("legacy-upgrade.splitswan-plugin"))
    check("舊腳本顯示升級預覽但尚未取代", legacyModel.preview?.legacy?.fileName == "legacy.1m.sh" && fm.fileExists(atPath: legacyEntry.path))
    if let preview = legacyModel.preview {
        window.contentViewController = NSHostingController(rootView: PluginPackagePreviewView(model: legacyModel, preview: preview).background(Color(nsColor: .windowBackgroundColor)))
        window.setContentSize(NSSize(width: 570, height: 590));window.makeKey()
        window.contentView?.frame = NSRect(x: 0, y: 0, width: 570, height: 590)
        for (name, appearance) in [("legacy-light", NSAppearance.Name.aqua), ("legacy-dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
            guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { check("升級頁截圖可建立",false);continue }
            content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: screenshots.appendingPathComponent(name + ".png"))
        }
        let handled = key("\u{1B}", code: 53)
        await settle { legacyModel.preview == nil }
        check("升級 Esc 不移動舊入口、不安裝套件", handled && legacyModel.preview == nil && fm.fileExists(atPath: legacyEntry.path) && legacyRunner.packageStore.discover().installed.isEmpty)
    }
    await legacyModel.prepare(fixtures.appendingPathComponent("legacy-upgrade.splitswan-plugin"))
    await legacyModel.install()
    check("升級確認後只留套件並提供備份入口", !legacyModel.failed && legacyModel.legacyBackup != nil && legacyRunner.plugins.count == 1 && legacyRunner.plugins[0].package != nil && !fm.fileExists(atPath: legacyEntry.path))
    print("通過 \(passed)，失敗 \(failed)")
    return failed
}
do { exit(Int32(try await runPackageUI() == 0 ? 0 : 1)) }
catch { print("❌ 原生介面流程：\(error.localizedDescription)\n通過 0，失敗 1"); exit(1) }
