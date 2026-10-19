// 設定頁的「外掛」區塊：啟用開關、開啟外掛資料夾、立即重新整理、每個外掛一行狀態
import SwiftUI

struct PluginSettingsView: View {
    @ObservedObject private var runner: PluginRunner
    @StateObject private var packages: PluginPackageModel
    @AppStorage(PluginRunner.enabledKey) private var enabled = false

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
                Spacer()
            }
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
                if let package = p.package {
                    Button("更新…") { packages.choose(updateID: p.id) }
                    Button("匯出…") { packages.export(package) }
                    Divider()
                }
                Button("移除外掛…", role: .destructive) { packages.beginRemoval(p) }
            }.fixedSize().disabled(packages.busy || packages.preview != nil || packages.removal != nil)
            if p.package.map({ $0.record.manifest.settings }) ?? (p.output?.settingsAvailable == true || !p.isEnabled || !runner.isActive) {
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

    private func statusText(_ p: PluginRunner.Plugin) -> String {
        var parts = p.isEnabled ? ["每 \(PluginLogic.intervalText(p.interval))"] : ["已停用", "每 \(PluginLogic.intervalText(p.interval))"]
        if p.package == nil { parts.insert("單檔外掛", at: 0) }
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
            parts.append(why)
        } else if let o = p.output {
            parts.append("\(o.items.filter { !$0.isSeparator }.count) 個項目" + (o.truncated ? "（已截斷）" : ""))
        }
        return parts.joined(separator: " · ")
    }
}
