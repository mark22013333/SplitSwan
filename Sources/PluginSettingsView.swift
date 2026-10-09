// 設定頁的「外掛」區塊：啟用開關、開啟外掛資料夾、立即重新整理、每個外掛一行狀態
import SwiftUI

struct PluginSettingsView: View {
    @ObservedObject private var runner = PluginRunner.shared
    @AppStorage(PluginRunner.enabledKey) private var enabled = false

    var body: some View {
        Toggle("啟用外掛", isOn: $enabled)
            .toggleStyle(.switch)
            .onChange(of: enabled) { _, on in runner.setEnabled(on) }
        Text("把可執行的腳本放進外掛資料夾，輸出會顯示在狀態列選單裡（格式同 SwiftBar，詳見 README「外掛」段）。外掛以你的身分執行，只放你看得懂的腳本。")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            Button("開啟外掛資料夾") { runner.openFolder() }
            Button("立即重新整理") { Task { await runner.refreshAll() } }
                .disabled(!enabled)
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
            ForEach(runner.plugins) { p in row(p) }
            if !runner.skipped.isEmpty {
                Text("外掛最多 \(PluginLogic.maxPlugins) 個，已略過：\(runner.skipped.joined(separator: "、"))")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func row(_ p: PluginRunner.Plugin) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: p.failure == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(p.failure == nil ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(p.id)").font(.callout.weight(.medium))
                Text(statusText(p)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func statusText(_ p: PluginRunner.Plugin) -> String {
        var parts = ["每 \(PluginLogic.intervalText(p.interval))"]
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
