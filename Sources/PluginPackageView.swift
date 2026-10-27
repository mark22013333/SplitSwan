import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PluginPackageModel: ObservableObject {
    struct Preview: Identifiable {
        let id = UUID()
        let prepared: PluginPackage.Prepared
        let change: PluginPackageStore.Change
        let previous: PluginPackage.Manifest?
        let legacy: PluginLegacyReplacement.Match?
        let attempt: PluginEventLog.Attempt
        init(prepared: PluginPackage.Prepared, change: PluginPackageStore.Change, previous: PluginPackage.Manifest?, legacy: PluginLegacyReplacement.Match? = nil, attempt: PluginEventLog.Attempt) {
            self.prepared = prepared; self.change = change; self.previous = previous; self.legacy = legacy; self.attempt = attempt
        }
    }
    struct Removal: Identifiable {
        let id = UUID()
        let plugin: PluginRunner.Plugin
        var title: String { plugin.package.map { $0.record.manifest.name + " · " + $0.record.manifest.version } ?? plugin.id }
    }
    @Published var preview: Preview?
    @Published var removal: Removal?
    @Published var busy = false
    @Published var message: String?
    @Published var failed = false
    /// 最後一次失敗的操作，供「複製診斷資訊」讀回同一次的記錄；成功、取消或開始新操作時清掉
    struct Failure: Equatable { let attempt: UUID; let code: PluginFailure? }
    @Published private(set) var lastFailure: Failure? { didSet { copied = false } }
    @Published private(set) var copied = false
    /// 測試換成記錄用閉包，不碰使用者的剪貼簿
    var pasteboardWriter: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @Published private(set) var legacyBackup: URL?
    @Published private(set) var backgroundSummary = "正在檢查背景工作…"
    @Published private(set) var checkingBackground = false
    @Published private(set) var removalProgress = ""
    let runner: PluginRunner
    init(runner: PluginRunner? = nil) { self.runner = runner ?? .shared }
    func choose(updateID: String? = nil) {
        guard !busy, preview == nil, removal == nil else { return }
        let panel = NSOpenPanel()
        panel.title = updateID == nil ? "匯入外掛安裝包" : "選擇新版外掛安裝包"
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "splitswan-plugin") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self.prepare(url, updateID: updateID) }
        }
    }
    func prepare(_ url: URL, updateID: String? = nil) async {
        guard !busy, preview == nil, removal == nil else { return }
        busy = true; message = "正在驗證安裝包…"; failed = false; lastFailure = nil
        defer { busy = false }
        var attempt = PluginEventLog.Attempt(updateID == nil ? .importPackage : .update, log: runner.eventLog)
        await attempt.started(.read)
        // 讀到安裝包之後的失敗沒有自帶檔案佐證，補上大小與雜湊
        var facts: [PluginEventLog.Fact] = []
        do {
            guard ["zip", "splitswan-plugin"].contains(url.pathExtension.lowercased()) else { throw PluginPackage.fail(.packageBadExtension) }
            let store = runner.packageStore
            let prepared = try await Task.detached(priority: .utility) { try PluginPackage.prepare(url, appVersion: store.appVersion) }.value
            facts = prepared.facts
            attempt.plugin = prepared.manifest.id
            do {
                if let updateID, "package:" + prepared.manifest.id != updateID { throw PluginPackage.fail(.packageUpdateIDMismatch) }
                let change = try store.change(for: prepared)
                if case .update = change { attempt.operation = .update }
                let legacy = try runner.legacyReplacement(for: prepared)
                if change == .identical, legacy == nil {
                    await attempt.passed(.compare, facts, detail: "已安裝相同版本及內容，未重新安裝")
                    prepared.discard(); message = "已安裝相同版本及內容，不需重新安裝。"
                    return
                }
                if change == .install, runner.plugins.count >= PluginLogic.maxPlugins,
                   !runner.plugins.contains(where: { $0.id == legacy?.fileName }) { throw PluginPackage.fail(.packagePluginLimit) }
                let previous = try? store.read(prepared.manifest.id).manifest
                // 先寫完記錄再顯示預覽：預覽出現時 busy 若還沒清掉，立刻按「安裝」會被靜默忽略
                await attempt.passed(.compare, facts)
                preview = Preview(prepared: prepared, change: change, previous: previous, legacy: legacy, attempt: attempt)
                message = nil
            } catch { prepared.discard(); throw error }
        } catch {
            await attempt.failed(error, at: .read, facts)
            fail(error, attempt)
        }
    }
    func cancel() {
        guard !busy else { return }
        if let attempt = preview?.attempt { Task { await attempt.cancelled(.compare) } }
        preview?.prepared.discard(); preview = nil; message = "已取消，未安裝外掛。"; failed = false; lastFailure = nil
    }
    func install() async {
        guard !busy, let preview else { return }
        guard PluginConfigurationWindows.shared.prepareForPackageUpdate("package:" + preview.prepared.manifest.id) else { return }
        if let legacy = preview.legacy,
           !PluginConfigurationWindows.shared.prepareForModification(legacy.fileName, operation: "升級") { return }
        busy = true; failed = false; lastFailure = nil
        defer { busy = false }
        var attempt = preview.attempt
        var facts = preview.prepared.facts
        if let legacy = preview.legacy {
            attempt.operation = .legacyUpgrade
            facts.append(.legacyScript(name: legacy.fileName, sha256: legacy.sha256))
        }
        do {
            try await runner.installPackage(preview.prepared, replacing: preview.legacy)
            legacyBackup = runner.latestLegacyBackup
            message = preview.legacy != nil ? "已升級並取代舊腳本，保留原啟用狀態。舊入口已備份，私人資料原地保留；外掛自身的排程切換請依設定頁完成。" : preview.change == .install ? "外掛已安裝，預設停用。確認後可開啟個別外掛開關。" : "外掛已更新，本機設定與啟用狀態已保留。"
            await attempt.passed(.install, facts)
            preview.prepared.discard(); self.preview = nil
        } catch {
            await attempt.failed(error, at: .install, facts)
            fail(error, attempt)
        }
    }
    func export(_ installed: PluginPackageStore.Installed) {
        guard !busy, preview == nil, removal == nil else { return }
        let panel = NSSavePanel()
        panel.title = "匯出外掛安裝包"
        panel.nameFieldStringValue = "\(installed.record.manifest.id)-\(installed.record.manifest.version).splitswan-plugin"
        panel.allowedContentTypes = [UTType(filenameExtension: "splitswan-plugin") ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.busy = true; self.failed = false; self.lastFailure = nil; self.message = "正在驗證匯出內容…"
                defer { self.busy = false }
                let attempt = PluginEventLog.Attempt(.export, plugin: installed.record.manifest.id, log: self.runner.eventLog)
                let facts: [PluginEventLog.Fact] = [.manifest(id: installed.record.manifest.id, version: installed.record.manifest.version)]
                do {
                    try await Task.detached(priority: .utility) { try installed.store.export(installed, to: url) }.value
                    await attempt.passed(.export, facts)
                    self.message = "已匯出程式、資源與預設值；未包含本機設定、授權或紀錄。"
                } catch {
                    await attempt.failed(error, at: .export, facts)
                    self.fail(error, attempt)
                }
            }
        }
    }
    func beginRemoval(_ plugin: PluginRunner.Plugin) {
        guard !busy, preview == nil, removal == nil else { return }
        removal = Removal(plugin: plugin); message = nil; failed = false; lastFailure = nil
        backgroundSummary = "正在檢查背景程序與登入背景服務…"; checkingBackground = true
        let request = removal!.id
        Task {
            do {
                let report = try await runner.inspectBackground(plugin)
                guard removal?.id == request else { return }
                backgroundSummary = report.summary
            } catch {
                guard removal?.id == request else { return }
                backgroundSummary = "無法完成背景檢查：\(error.localizedDescription)"
            }
            checkingBackground = false
        }
    }
    func cancelRemoval() {
        guard !busy else { return }
        removal = nil; message = "已取消，未移除外掛。"; failed = false; lastFailure = nil
        checkingBackground = false
    }
    func remove(trash: @escaping PluginPackageStore.TrashOperation = PluginPackageStore.moveToTrash) async {
        guard !busy, let removal else { return }
        guard PluginConfigurationWindows.shared.prepareForModification(removal.plugin.id, operation: "移除") else { return }
        busy = true; failed = false
        removalProgress = "正在停止 App 排程並檢查背景工作…"
        defer { busy = false }
        do {
            let result = try await runner.removePlugin(removal.plugin, trash: trash) { [self] progress in
                await MainActor.run { self.removalProgress = progress }
            }
            self.removal = nil
            message = result.summary + " 外掛程式已移到垃圾桶；本機設定、授權與紀錄已保留。"
        } catch { failed = true; message = "外掛已保留並停用，未恢復排程。\n" + error.localizedDescription }
    }
    private func fail(_ error: Error, _ attempt: PluginEventLog.Attempt) {
        failed = true; message = error.localizedDescription
        lastFailure = Failure(attempt: attempt.id, code: (error as? PluginPackage.Problem)?.failure)
    }
    func copyDiagnostics() async {
        guard let failure = lastFailure else { return }
        let records = await runner.eventLog.records(attempt: failure.attempt)
        pasteboardWriter(PluginDiagnostics.summary(records, appVersion: AppInfo.version, build: AppInfo.build,
                                                   macOS: ProcessInfo.processInfo.operatingSystemVersionString))
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            if lastFailure == failure { copied = false }
        }
    }
    func receive(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, preview == nil, removal == nil else { return false }
        guard providers.count == 1, let provider = providers.first else { failed = true; lastFailure = nil; message = "每次請拖入一個安裝包。"; return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            Task { @MainActor in
                guard let url, url.isFileURL else { self.failed = true; self.lastFailure = nil; self.message = "請拖入本機的外掛安裝包。"; return }
                await self.prepare(url)
            }
        }
        return true
    }
}

struct PluginPackageImportView: View {
    @ObservedObject var model: PluginPackageModel
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("匯入外掛安裝包").font(.headline)
                    Text("拖曳一個 .splitswan-plugin 或 .zip 到這裡，也可以選擇檔案。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("匯入外掛…") { model.choose() }.disabled(model.busy || model.preview != nil)
            }
            Text("相同識別碼的新版會更新；開發者有宣告舊腳本且內容驗證相符時，可確認升級並取代。全新安裝預設停用。")
                .font(.caption).foregroundStyle(.secondary)
            if model.busy { ProgressView().controlSize(.small).accessibilityLabel("正在處理安裝包") }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(model.failed ? .red : .secondary).textSelection(.enabled)
                PluginFailureDiagnosticsRow(model: model)
            }
            if let backup = model.legacyBackup {
                Button("開啟舊腳本備份") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5])))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted, perform: model.receive)
        .sheet(item: $model.preview, onDismiss: { model.preview?.prepared.discard() }) { preview in
            PluginPackagePreviewView(model: model, preview: preview)
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.removal) { removal in
            PluginRemovalView(model: model, removal: removal).interactiveDismissDisabled()
        }
    }
}

/// 失敗訊息下方的錯誤碼與「複製診斷資訊」，讓使用者不用跑指令就能把這次的記錄交給維護者
struct PluginFailureDiagnosticsRow: View {
    @ObservedObject var model: PluginPackageModel
    var body: some View {
        if model.failed, let failure = model.lastFailure {
            HStack(spacing: 10) {
                if let code = failure.code {
                    Text("錯誤碼 " + code.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(model.copied ? "已複製" : "複製診斷資訊") { Task { await model.copyDiagnostics() } }
                    .controlSize(.small)
            }
        }
    }
}

struct PluginRemovalView: View {
    @ObservedObject var model: PluginPackageModel
    let removal: PluginPackageModel.Removal
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("確認移除外掛").font(.title2.bold())
            Text(removal.title).font(.headline).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(removal.plugin.package == nil ? "將單檔腳本移到垃圾桶，並停止 App 對它的排程。" : "將這個外掛的已安裝版本移到垃圾桶，並停止 App 對它的排程。")
                    Text("保留本機設定、帳密、日曆授權及紀錄；不執行外掛提供的移除腳本。")
                    Label("背景工作檢查", systemImage: "checkmark.shield").font(.headline)
                    HStack(alignment: .top) {
                        if model.checkingBackground { ProgressView().controlSize(.small) }
                        Text(model.backgroundSummary).foregroundStyle(.secondary)
                    }
                    Text("會檢查目前使用者的程序與登入背景服務，自動停止能確認屬於此外掛的工作。若無法確認已停止，會保留外掛並顯示原因。")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.failed, let message = model.message { Text(message).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text(model.removalProgress).font(.callout) }
                Spacer()
                Button("取消") { model.cancelRemoval() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("停止並移除", role: .destructive) { Task { await model.remove() } }
                    .keyboardShortcut(.defaultAction).disabled(model.busy || model.checkingBackground)
            }
        }.padding(24).frame(width: 500, height: 370)
    }
}

struct PluginPackagePreviewView: View {
    @ObservedObject var model: PluginPackageModel
    let preview: PluginPackageModel.Preview
    private var manifest: PluginPackage.Manifest { preview.prepared.manifest }
    private var updating: Bool { preview.previous != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preview.legacy != nil ? "確認升級舊腳本" : updating ? "確認更新外掛" : "確認安裝外掛").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(manifest.name).font(.headline)
                    Text(manifest.description).fixedSize(horizontal: false, vertical: true)
                    if let legacy = preview.legacy {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("將取代：\(legacy.fileName)").font(.headline)
                            Text("檔名與 SHA-256 均符合開發者宣告。確認後會備份舊入口，沿用其\(legacy.enabled ? "啟用" : "停用")狀態；不執行舊腳本或安裝鉤子。")
                            Text("私人資料原地保留，由支援此升級的套件承接。App 只替換入口，不會自行變更獨立服務；請依套件設定確認排程已切換。")
                        }.font(.callout).padding(10).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow { Text("識別碼").foregroundStyle(.secondary); Text(manifest.id).textSelection(.enabled) }
                        GridRow { Text("版本").foregroundStyle(.secondary); Text(preview.previous.map { $0.version + " → " + manifest.version } ?? manifest.version) }
                        GridRow { Text("作者").foregroundStyle(.secondary); Text(preview.previous.map { $0.author == manifest.author ? manifest.author : $0.author + " → " + manifest.author } ?? manifest.author) }
                        GridRow { Text("執行環境").foregroundStyle(.secondary); Text(([manifest.runtime] + manifest.dependencies).joined(separator: "、")) }
                        if let old = preview.previous {
                            GridRow { Text("原執行環境").foregroundStyle(.secondary); Text(([old.runtime] + old.dependencies).joined(separator: "、")) }
                        }
                        GridRow { Text("安裝內容").foregroundStyle(.secondary); Text("\(manifest.files.count) 個程式、資源或文件") }
                    }.font(.callout)
                    Text("作者資訊由開發者自行提供，尚未驗證身分。外掛會以你的使用者身分執行，能存取帳號可讀寫的檔案；只安裝可信任的來源。")
                        .font(.callout).foregroundStyle(.secondary)
                    if !preview.prepared.missingDependencies.isEmpty {
                        Text("缺少：" + preview.prepared.missingDependencies.joined(separator: "、") + "。可先安裝套件，補齊執行環境後才能啟用；App 不會自動安裝依賴。")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    DisclosureGroup("檔案清單") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(manifest.files, id: \.path) { Text($0.path).font(.caption.monospaced()) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                    Text(preview.legacy != nil ? "僅取代已驗證的舊入口。若升級失敗，會還原原套件與舊入口；未備妥的背景設定仍須在套件設定中處理。" : updating ? "保留本機設定、授權與啟用狀態；不執行任何安裝或移轉腳本。" : "新外掛預設停用；安裝時不會執行外掛。沒有宣告及驗證相符的舊腳本不會被取代。")
                        .font(.callout)
                    if model.failed, let message = model.message {
                        Text(message).foregroundStyle(.red)
                        PluginFailureDiagnosticsRow(model: model)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text("正在安裝…").font(.callout) }
                Spacer()
                Button("取消") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button(preview.legacy != nil ? "信任並取代舊腳本" : updating ? "信任並更新" : "信任並安裝") { Task { await model.install() } }
                    .keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }.padding(24).frame(width: 570, height: 530)
    }
}
