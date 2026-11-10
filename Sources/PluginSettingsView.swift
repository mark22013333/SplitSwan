// 設定頁的「外掛」區塊：啟用開關、開啟外掛資料夾、立即重新整理、診斷紀錄、每個外掛一行狀態
import SwiftUI
import UniformTypeIdentifiers

struct PluginSettingsView: View {
    @ObservedObject private var runner: PluginRunner
    @StateObject private var packages: PluginPackageModel
    @AppStorage(PluginRunner.enabledKey) private var enabled = false
    @State private var diagnosticsMessage: String?
    @ObservedObject private var hotKeys = GlobalHotKey.shared
    @State private var hotKey = PluginShortcuts.hotKey()
    @AppStorage(PluginShortcuts.hotKeyTargetKey) private var hotKeyTarget = ""
    @State private var recorder: Any?

    init(runner: PluginRunner? = nil) {
        let selected = runner ?? PluginRunner.shared
        _runner = ObservedObject(wrappedValue: selected)
        _packages = StateObject(wrappedValue: PluginPackageModel(runner: selected))
    }

    var body: some View {
        Group {
            Toggle("啟用外掛", isOn: $enabled)
                .toggleStyle(.switch)
                .onChange(of: enabled) { _, on in runner.setEnabled(on); if !on { runner.scan() } }
            PluginPackageImportView(model: packages)
            Text("外掛安裝包可攜帶程式與資源；原有單檔腳本仍可放入外掛資料夾。外掛以你的使用者身分執行，請只安裝可信任的來源。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("開啟外掛資料夾") { runner.openFolder() }
                Button("立即重新整理") { Task { await runner.refreshAll() } }
                    .disabled(!enabled)
                if !enabled {
                    Button("掃描外掛設定…") { runner.scan() }
                }
                Menu("診斷紀錄…") {
                    Button("在 Finder 中顯示") { revealLog() }
                    Button("匯出診斷報告…") { exportReport() }
                }.fixedSize()
                Spacer()
            }
            if let diagnosticsMessage {
                Text(diagnosticsMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if enabled { hotKeyRow }
            Text(runner.directory.path.replacingOccurrences(of: PluginRunner.home, with: "~"))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if enabled {
                if runner.folderMissing {
                    Text("外掛資料夾還不存在，按「開啟外掛資料夾」建立")
                        .font(.callout).foregroundStyle(.secondary)
                } else if runner.plugins.isEmpty {
                    Text("資料夾內沒有可執行的外掛").font(.callout).foregroundStyle(.secondary)
                }
                if !runner.skipped.isEmpty {
                    Text("外掛最多 \(PluginLogic.maxPlugins) 個，已略過：\(runner.skipped.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            ForEach(runner.packageErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            ForEach(runner.plugins) { p in row(p) }
        }.onAppear { runner.scan() }
    }

    private var hotKeyRow: some View {
        let candidates = Self.settingsCandidates(runner)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("開啟外掛設定的快捷鍵")
                Button(recorder != nil ? "請按下新的組合鍵…（Esc 取消）" : hotKey?.display ?? "未設定") { recorder == nil ? startRecording() : stopRecording() }
                    .font(.body.monospaced())
                if hotKey != nil { Button("清除") { saveHotKey(nil) } }
                if hotKey != .default { Button("還原預設") { saveHotKey(.default) } }
                if candidates.count > 1 {
                    Picker("開啟", selection: Binding(
                        get: { PluginShortcuts.target(stored: hotKeyTarget, candidates: candidates.map(\.id)) ?? "" },
                        set: { hotKeyTarget = $0 })) {
                        ForEach(candidates) { p in Text(p.package?.record.manifest.name ?? p.id).tag(p.id) }
                    }.fixedSize()
                }
                Spacer()
            }
            Text(hotKeys.conflict ? "這組按鍵已被其他 App 使用，請換一組。" : "在任何 App 中按下就會開啟外掛設定；設定視窗內的按鈕若有快捷鍵，會標在按鈕旁。")
                .font(.caption).foregroundStyle(hotKeys.conflict ? .orange : .secondary)
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        hotKeys.suspended = true
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let modifiers = (flags.contains(.control) ? PluginShortcuts.HotKey.control : 0) | (flags.contains(.option) ? PluginShortcuts.HotKey.option : 0)
                | (flags.contains(.shift) ? PluginShortcuts.HotKey.shift : 0) | (flags.contains(.command) ? PluginShortcuts.HotKey.command : 0)
            let candidate = PluginShortcuts.HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                                                   key: (event.charactersIgnoringModifiers ?? "").uppercased())
            guard candidate.isUsable else { NSSound.beep(); return nil }
            saveHotKey(candidate)
            return nil
        }
    }
    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        if hotKeys.suspended { hotKeys.suspended = false }
    }
    private func saveHotKey(_ value: PluginShortcuts.HotKey?) {
        PluginShortcuts.setHotKey(value)
        hotKey = PluginShortcuts.hotKey()
        stopRecording()
        hotKeys.sync()
    }

    /// 全域熱鍵可開啟的外掛：有設定視窗且沒有載入問題。
    static func settingsCandidates(_ runner: PluginRunner) -> [PluginRunner.Plugin] {
        runner.plugins.filter { p in
            p.problem == nil && (p.package.map { $0.record.manifest.settings } ?? (p.output?.settingsAvailable == true))
        }
    }

    private func revealLog() {
        let log = runner.eventLog, fm = FileManager.default
        if fm.fileExists(atPath: log.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log.fileURL]); diagnosticsMessage = nil
        } else if fm.fileExists(atPath: log.directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log.directory]); diagnosticsMessage = nil
        } else {
            diagnosticsMessage = "目前沒有記錄"
        }
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.title = "匯出外掛診斷報告"
        panel.nameFieldStringValue = PluginDiagnostics.defaultReportName()
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                diagnosticsMessage = "正在產生診斷報告…"
                let text = await runner.diagnosticsReport(pluginsEnabled: enabled)
                do {
                    try await Task.detached(priority: .utility) { try PluginDiagnostics.writeReport(text, to: url) }.value
                    diagnosticsMessage = "已匯出 " + url.lastPathComponent
                } catch {
                    diagnosticsMessage = "無法匯出診斷報告：" + error.localizedDescription
                }
            }
        }
    }

    private func row(_ p: PluginRunner.Plugin) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: p.isEnabled ? (p.failure == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") : "pause.circle.fill")
                .foregroundStyle(p.isEnabled ? (p.failure == nil ? .green : .orange) : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.package.map { $0.record.manifest.name + " · " + $0.record.manifest.version } ?? p.id).font(.callout.weight(.medium))
                Text(statusText(p)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
            Menu("管理") {
                if !hasSettingsWindow(p) {
                    Toggle("鎖定時持續執行", isOn: Binding(
                        get: { p.runWhenLocked },
                        set: { runner.setRunWhenLocked(p.id, $0) }
                    ))
                }
                Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([p.finderSelection]) }
                Divider()
                if let package = p.package {
                    Button("更新…") { packages.choose(updateID: p.id) }
                    Button("匯出…") { packages.export(package) }
                    Divider()
                }
                Button("移除外掛…", role: .destructive) { packages.beginRemoval(p) }
            }.fixedSize().disabled(packages.busy || packages.preview != nil || packages.removal != nil)
            if hasSettingsWindow(p) {
                Button("設定…") { PluginConfigurationWindows.shared.open(pluginID: p.id) }
                    .disabled(p.problem != nil)
            }
            Toggle("", isOn: Binding(
                get: { p.isEnabled },
                set: { runner.setPluginEnabled(p.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(p.problem != nil && !p.isEnabled)
            .help(p.isEnabled ? "停用此外掛" : "啟用此外掛")
        }
    }

    /// 有設定視窗的外掛把「鎖定時持續執行」放在視窗裡，沒有的才留在「管理」選單
    private func hasSettingsWindow(_ p: PluginRunner.Plugin) -> Bool {
        p.package.map { $0.record.manifest.settings } ?? (p.output?.settingsAvailable == true || !p.isEnabled || !runner.isActive)
    }

    private func statusText(_ p: PluginRunner.Plugin) -> String {
        var parts = p.isEnabled ? ["每 \(PluginLogic.intervalText(p.interval))"] : ["已停用", "每 \(PluginLogic.intervalText(p.interval))"]
        if p.package == nil { parts.insert("單檔外掛", at: 0) }
        if p.runWhenLocked { parts.append("鎖定時持續執行") }
        if let d = runner.lastRuns[p.id] {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            parts.append("上次 \(f.string(from: d))")
        } else if p.problem == nil {
            parts.append(runner.runningIDs.contains(p.id) ? "執行中…" : "尚未執行")
        }
        if runner.notifyCapped.contains(p.id) {
            parts.append("今天的通知已達上限（\(PluginLogic.maxNotifyKeysPerDay) 則），明天恢復")
        }
        if let why = p.failure {
            parts.append(why + (p.problem == nil && p.error != nil ? p.errorCode.map { "（\($0.rawValue)）" } ?? "" : ""))
        } else if let o = p.output {
            parts.append("\(o.items.filter { !$0.isSeparator }.count) 個項目" + (o.truncated ? "（已截斷）" : ""))
        }
        return parts.joined(separator: " · ")
    }
}

extension PluginRunner {
    /// 匯出診斷報告的全文；讀套件登錄與計算單檔雜湊都在背景做
    func diagnosticsReport(pluginsEnabled: Bool, generated: Date = Date()) async -> String {
        let recent = await eventLog.recent(limit: PluginDiagnostics.reportLimit)
        let (packages, scripts) = await Task.detached(priority: .utility) { [packageStore, directory] in
            (packageStore.discover().installed.map {
                PluginDiagnostics.Package(id: $0.record.manifest.id, version: $0.record.manifest.version, digest: $0.record.digest,
                                          enabled: $0.record.enabled, trusted: $0.record.trusted)
            }, PluginDiagnostics.scripts(in: directory))
        }.value
        return PluginDiagnostics.report(recent: recent, packages: packages, singleFiles: scripts, pluginsEnabled: pluginsEnabled,
                                        appVersion: AppInfo.version, build: AppInfo.build,
                                        macOS: ProcessInfo.processInfo.operatingSystemVersionString, generated: generated)
    }
}
