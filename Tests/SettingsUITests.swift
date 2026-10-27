import AppKit
import SwiftUI

// 設定頁側欄＋面板的離屏截圖。資料全是虛構範例；@AppStorage 導到隔離的 suite，不讀真實設定
struct Harness: View {
    @State var category: SettingsCategory
    @State var draft: VPNSettings
    @State var tsText: String
    @State var password = ""
    @State var psk = ""
    @State var showHelp = false
    @State var launchAtLogin = true
    @State var notifyDrop = true
    let saved: VPNSettings
    let runner: PluginRunner

    var dirty: Set<SettingsCategory> {
        SettingsLogic.dirtyCategories(draft: draft, tsText: tsText, psk: psk, password: password, saved: saved)
    }

    var body: some View {
        SettingsSplitView(selection: $category, dirty: dirty, message: nil, revert: {}, save: {}) {
            switch category {
            case .connection:
                ConnectionSettingsPanel(draft: $draft, password: $password, psk: $psk, secretState: (psk: true, password: true),
                                        canClearHistory: true, clearHistory: {})
            case .subnets:
                // 真正的 HostCheckPanel 需要 VPNController（會讀本機設定、呼叫輔助程式），這裡用同樣排版的替身
                SubnetsSettingsPanel(tsText: $tsText, showHelp: $showHelp) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("某台公司主機連不上？（替身）").font(.callout.weight(.medium))
                        HStack(spacing: 8) {
                            TextField("", text: .constant(""), prompt: Text("主機網域或網址，例：intranet.example.com:8443"))
                            Button("檢查並加入") {}.buttonStyle(.borderedProminent).disabled(true)
                            Button("只檢查") {}.disabled(true)
                        }
                    }
                }
            case .profile:
                ProfileSettingsPanel(presetText: "公司設定：範例公司（~/.config/splitswan/company.env）", canRestore: true,
                                     importPreset: {}, exportConfig: {}, restorePreset: {})
            case .appearance:
                SettingsCard("狀態列圖示") { IconStylePicker() }
            case .plugins:
                PluginSettingsView(runner: runner).controlSize(.small)
            case .general:
                GeneralSettingsPanel(launchAtLogin: $launchAtLogin, notifyDrop: $notifyDrop, notifyDenied: true,
                                     launchAtLoginChanged: { _ in }, notifyDropChanged: {})
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

@MainActor
func runSettingsUI() async throws -> Int {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool) { if ok { passed += 1 } else { failed += 1; print("❌ " + name) } }

    let suite = UserDefaults(suiteName: "SplitSwan.SettingsUI." + UUID().uuidString)!
    let plugins = root.appendingPathComponent("plugins")
    try PluginPackageStore.createSecureDirectory(plugins)
    let script = plugins.appendingPathComponent("punch-reminder.1m.sh")
    try Data("#!/bin/bash\necho 打卡提醒範例\n".utf8).write(to: script)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let runner = PluginRunner(directory: plugins, stateRoot: root.appendingPathComponent("state"), preferences: suite,
                              packageRoot: root.appendingPathComponent("packages"), appVersion: "1.9.7")
    runner.scan()
    check("範例單檔外掛被掃描到", runner.plugins.count == 1)

    var saved = VPNSettings()
    saved.username = "example.user"
    saved.gateways = ["203.0.113.10", "198.51.100.20", "203.0.113.30"]
    saved.remoteTS = "10.20.0.0/16, 10.30.5.0/24, 198.51.100.44/32"
    var edited = saved; edited.gateways[2] = "203.0.113.31"

    let screenshots = root.appendingPathComponent("screenshots")
    try fm.createDirectory(at: screenshots, withIntermediateDirectories: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let size = NSSize(width: 600, height: 750)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); window.orderBack(nil)
    defer { window.orderOut(nil) }

    let cases: [(String, SettingsCategory, VPNSettings, String)] = [
        ("connection-dirty", .connection, edited, SettingsLogic.lines(saved.remoteTS)),
        ("subnets-dirty", .subnets, saved, SettingsLogic.lines(saved.remoteTS) + "\n10.40.8.0/24"),
        ("profile", .profile, saved, SettingsLogic.lines(saved.remoteTS)),
        ("appearance", .appearance, saved, SettingsLogic.lines(saved.remoteTS)),
        ("plugins", .plugins, saved, SettingsLogic.lines(saved.remoteTS)),
        ("general", .general, saved, SettingsLogic.lines(saved.remoteTS)),
    ]
    for (name, category, draft, ts) in cases {
        let harness = Harness(category: category, draft: draft, tsText: ts, saved: saved, runner: runner)
        // 外層照 MainView 包一層 TabView，面板寬度才跟實際視窗一樣
        let root = TabView(selection: .constant(2)) {
            ForEach(Array(["連線", "自動分流", "設定", "環境檢查", "關於"].enumerated()), id: \.offset) { i, title in
                Group { if i == 2 { harness } else { Color.clear } }.tabItem { Text(title) }.tag(i)
            }
        }
        .padding(16).controlSize(.large)
        .background(Color(nsColor: .windowBackgroundColor))   // 離屏截圖不含視窗本身的底色
        window.contentViewController = NSHostingController(rootView: root.defaultAppStorage(suite))
        window.setContentSize(size)
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for _ in 0..<5 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) }
            guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                check("\(name)-\(suffix) 截圖可建立", false); continue
            }
            content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: screenshots.appendingPathComponent("\(name)-\(suffix).png"))
            check("\(name)-\(suffix) 在 600×750 排版", content.bounds.size == size)
        }
    }
    let connectionDirty = SettingsLogic.dirtyCategories(draft: edited, tsText: SettingsLogic.lines(saved.remoteTS), psk: "", password: "", saved: saved)
    check("截圖情境的未儲存分類正確", connectionDirty == [.connection])
    print("通過 \(passed)，失敗 \(failed)")
    return failed
}
do { exit(Int32(try await runSettingsUI() == 0 ? 0 : 1)) }
catch { print("❌ 設定頁截圖：\(error.localizedDescription)\n通過 0，失敗 1"); exit(1) }
