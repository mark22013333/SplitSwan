import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PluginConfigurationModel: ObservableObject {
    typealias P = PluginSettingsProtocol
    let pluginID: String
    @Published var snapshot: P.Snapshot?
    @Published var draft: [String: P.Value] = [:]
    @Published var busy = false
    @Published var error: String?
    @Published var selectedTabID = ""
    @Published private(set) var checkDeferred = false
    private let command: @MainActor (String, P.Request?) async throws -> P.Snapshot
    private let now: () -> Date
    private let pollInterval: Duration
    private var polling: Task<Void, Never>?
    private var visible = true
    private var lastChecks: [String: Date] = [:]
    private var pendingChecks: [String: Bool] = [:]
    private var externalTab: String?
    private var postJobCheck: (id: String, tab: String)?

    init(pluginID: String, command: (@MainActor (String, P.Request?) async throws -> P.Snapshot)? = nil,
         now: @escaping () -> Date = Date.init, pollInterval: Duration = .seconds(2)) {
        self.pluginID = pluginID
        self.now = now
        self.pollInterval = pollInterval
        self.command = command ?? { operation, request in
            try await PluginRunner.shared.settingsCommand(pluginID: pluginID, operation: operation, request: request)
        }
    }
    var dirty: Bool {
        snapshot?.fields.contains { $0.type != "readonly" && draft[$0.id] != snapshot?.values[$0.id] } ?? false
    }
    func cancelEdits() {
        draft = snapshot?.values ?? [:]
        error = nil
        Task { await drainCheck() }
    }
    func stop() {
        visible = false
        polling?.cancel()
        polling = nil
        pendingChecks.removeAll()
        externalTab = nil
        postJobCheck = nil
    }
    func load() async { _ = await execute("snapshot") }
    func enterTab(_ id: String) async {
        selectedTabID = id
        await checkCurrentTab()
    }
    func returnedFromExternal() async {
        guard let tab = externalTab else { return }
        externalTab = nil
        pendingChecks[tab] = true
        await drainCheck()
    }
    func checkCurrentTab(force: Bool = false) async {
        guard snapshot?.tabs.first(where: { $0.id == selectedTabID })?.guide != nil else { return }
        pendingChecks[selectedTabID] = force || pendingChecks[selectedTabID] == true
        await drainCheck()
    }
    func save() async {
        guard let s = snapshot else { return }
        let changedGuides = s.tabs.filter { tab in
            tab.guide?.refreshFields.contains { draft[$0] != s.values[$0] } == true
        }.map(\.id)
        let editable = Set(s.fields.filter { $0.type != "readonly" }.map(\.id))
        if await execute("save", request: P.Request(revision: s.revision, values: draft.filter { editable.contains($0.key) })) {
            for id in changedGuides { pendingChecks[id] = true }
            await drainCheck()
        }
    }
    func action(_ a: P.Action, input: String? = nil) async {
        guard let s = snapshot, !dirty, s.actions.contains(where: { $0 == a }) else { return }
        if a.opensExternal == true { externalTab = a.tab }
        if await execute("action", request: P.Request(revision: s.revision, id: a.id, input: input)), a.recheckAfter == true {
            if let job = snapshot?.job, job.state == "running" {
                postJobCheck = (job.id, a.tab)
            } else if snapshot?.job?.state != "failed" {
                pendingChecks[a.tab] = true
                await drainCheck()
            }
        }
    }
    private func drainCheck() async {
        checkDeferred = dirty && pendingChecks[selectedTabID] != nil
        guard visible, !dirty, !busy, snapshot?.job?.state != "running",
              let force = pendingChecks.removeValue(forKey: selectedTabID),
              let guide = snapshot?.tabs.first(where: { $0.id == selectedTabID })?.guide,
              let action = snapshot?.actions.first(where: { $0.id == guide.checkAction }) else { return }
        checkDeferred = false
        if !force, let last = lastChecks[selectedTabID], now().timeIntervalSince(last) < 30 { return }
        lastChecks[selectedTabID] = now()
        await self.action(action)
    }
    @discardableResult
    private func execute(_ operation: String, request: P.Request? = nil) async -> Bool {
        guard !busy, visible, snapshot?.job?.state != "running" || operation == "snapshot" else { return false }
        busy = true
        error = nil
        var succeeded = false
        do {
            let wasDirty = dirty
            let fresh = try await command(operation, request)
            if visible {
                snapshot = fresh
                if !wasDirty || operation == "save" { draft = fresh.values }
                if let followup = postJobCheck, fresh.job?.id == followup.id, fresh.job?.state != "running" {
                    postJobCheck = nil
                    if fresh.job?.state == "succeeded" { pendingChecks[followup.tab] = true }
                }
                if fresh.job?.state == "running", polling == nil { startPolling() }
                succeeded = true
            }
        } catch is CancellationError { }
        catch { if visible { self.error = error.localizedDescription } }
        busy = false
        // 儲存由呼叫端合併「延後檢查」與欄位變更，避免同次儲存連續查詢兩次。
        if operation != "save" { await drainCheck() }
        return succeeded
    }
    private func startPolling() {
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { break }
                do { try await Task.sleep(for: interval) } catch { break }
                guard let self, self.visible else { break }
                await self.load()
                if self.error != nil || self.snapshot?.job?.state != "running" { break }
            }
            self?.polling = nil
        }
    }
}

/// 一支外掛只保留一個視窗；關閉時停止工作查詢，未儲存的表單須先確認捨棄。
@MainActor
final class PluginConfigurationWindows: NSObject, NSWindowDelegate {
    static let shared = PluginConfigurationWindows()
    private var windows: [String: NSWindow] = [:]
    private var models: [String: PluginConfigurationModel] = [:]

    func open(pluginID: String) {
        if let window = windows[pluginID] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = PluginConfigurationModel(pluginID: pluginID)
        let view = PluginConfigurationView(model: model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "外掛設定：\(pluginID)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 680))
        window.minSize = NSSize(width: 680, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        models[pluginID] = model
        windows[pluginID] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func prepareForPackageUpdate(_ id: String) -> Bool {
        prepareForModification(id, operation: "更新")
    }
    func prepareForModification(_ id: String, operation: String) -> Bool {
        guard let model = models[id] else { return true }
        if model.dirty || (operation != "移除" && (model.busy || model.snapshot?.job?.state == "running")) {
            windows[id]?.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.messageText = "請先完成外掛設定，再\(operation)"
            alert.informativeText = model.dirty ? "請儲存或取消尚未儲存的變更，再回到管理畫面。" : "此外掛仍有設定工作進行中，完成後即可\(operation)。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            return false
        }
        windows[id]?.close()
        return true
    }
    private func id(for window: NSWindow) -> String? { windows.first { $0.value === window }?.key }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = id(for: sender), let model = models[id], model.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "捨棄尚未儲存的設定？"
        alert.informativeText = "尚未儲存的變更不會套用至外掛。"
        alert.addButton(withTitle: "繼續編輯")
        alert.addButton(withTitle: "捨棄變更")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = id(for: window) else { return }
        models[id]?.stop()
        models[id] = nil
        windows[id] = nil
    }
}

struct PluginConfigurationView: View {
    @ObservedObject var model: PluginConfigurationModel
    @State private var confirming: PluginSettingsProtocol.Action?
    @State private var stepExpanded: [String: Bool] = [:]
    @State private var editingGuides: Set<String> = []

    private func label(_ text: String) -> String { PluginLogic.sanitize(text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(label(model.snapshot?.title ?? "外掛設定")).font(.title2.weight(.semibold))
                    Text("設定與背景工作由此外掛管理；外掛顯示開關不代表背景工作已停用。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("正在載入外掛設定") }
            }
            if let message = model.error {
                Text(PluginSettingsProtocol.displayText(message)).foregroundStyle(.red).textSelection(.enabled)
            }
            if let s = model.snapshot {
                if let job = s.job {
                    HStack {
                        if job.state == "running" { ProgressView().controlSize(.small) }
                        Text(PluginSettingsProtocol.displayText(job.message)).font(.callout)
                    }
                    .foregroundStyle(job.state == "failed" ? .orange : .secondary)
                }
                TabView(selection: $model.selectedTabID) {
                    ForEach(s.tabs) { tab in
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    if let help = tab.help {
                                        Text(PluginSettingsProtocol.displayText(help)).font(.callout).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    }
                                    if let guide = tab.guide {
                                        guideView(guide, tab: tab, snapshot: s)
                                    } else {
                                        formFields(s.fields.filter { $0.tab == tab.id }, snapshot: s)
                                        ForEach(s.actions.filter { $0.tab == tab.id && $0.afterField == nil }) { action in
                                            actionView(action)
                                        }
                                    }
                                }
                                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .onChange(of: tab.guide?.currentStep) {
                                if model.selectedTabID == tab.id, let step = tab.guide?.currentStep {
                                    proxy.scrollTo(step, anchor: .top)
                                }
                            }
                        }
                        .tabItem { Text(label(tab.title)) }.tag(tab.id)
                    }
                }
                Divider()
                HStack {
                    Button("重新載入") { Task { await model.load() } }.disabled(model.busy || model.dirty)
                    if model.dirty {
                        Text(model.checkDeferred ? "有未儲存變更；儲存或取消後會接續檢查。" : "請先儲存或取消變更，再執行測試與其他操作。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消") { model.cancelEdits() }.disabled(model.busy || !model.dirty)
                    Button(saveTitle) { Task { await model.save() } }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.dirty || s.job?.state == "running")
                }
            } else if !model.busy {
                Button("重試") { Task { await model.load() } }
                Spacer()
            }
        }
        .padding(24).frame(minWidth: 640, minHeight: 500)
        .task {
            await model.load()
            model.selectedTabID = model.snapshot?.tabs.first?.id ?? ""
        }
        .onChange(of: model.selectedTabID) {
            Task { await model.enterTab(model.selectedTabID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.returnedFromExternal() }
        }
        .alert("確認執行此操作？", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("取消", role: .cancel) { confirming = nil }
            Button("執行", role: .destructive) {
                if let action = confirming { perform(action) }
                confirming = nil
            }
        } message: { Text(label(confirming?.title ?? "")) }
    }

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { model.draft[id]?.text ?? "" }, set: { model.draft[id] = .text($0) })
    }
    private var saveTitle: String {
        let guide = model.snapshot?.tabs.first { $0.id == model.selectedTabID }?.guide
        return guide?.steps.first { step in
            step.saveTitle != nil && step.fields.contains { model.draft[$0] != model.snapshot?.values[$0] }
        }?.saveTitle ?? "儲存"
    }
    @ViewBuilder private func formFields(_ fields: [PluginSettingsProtocol.Field], snapshot: PluginSettingsProtocol.Snapshot) -> some View {
        ForEach(fields) { field in
            fieldView(field)
            ForEach(snapshot.actions.filter { $0.tab == field.tab && $0.afterField == field.id }) { action in
                actionView(action)
            }
        }
    }
    private func stateTitle(_ state: String) -> String {
        ["pending": "待處理", "checking": "檢查中", "completed": "已完成", "attention": "需要處理"][state] ?? "待處理"
    }
    @ViewBuilder private func guideView(_ guide: PluginSettingsProtocol.Guide, tab: PluginSettingsProtocol.Tab,
                                       snapshot s: PluginSettingsProtocol.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(PluginSettingsProtocol.displayText(guide.summary)).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let check = s.actions.first(where: { $0.id == guide.checkAction }) {
                    Button(label(check.title)) { Task { await model.checkCurrentTab(force: true) } }
                        .disabled(model.busy || model.dirty || s.job?.state == "running")
                }
                if guide.complete {
                    Button(editingGuides.contains(tab.id) ? "收合設定" : "調整設定") {
                        if !editingGuides.insert(tab.id).inserted { editingGuides.remove(tab.id) }
                    }
                }
            }
            if !guide.complete || editingGuides.contains(tab.id) {
                ForEach(Array(guide.steps.enumerated()), id: \.element.id) { index, step in
                    DisclosureGroup(isExpanded: Binding(get: {
                        stepExpanded[tab.id + "|" + step.id] ?? (guide.currentStep == step.id)
                    }, set: { stepExpanded[tab.id + "|" + step.id] = $0 })) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(PluginSettingsProtocol.displayText(step.help)).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if let details = step.details {
                                DisclosureGroup("查看操作說明") {
                                    Text(PluginSettingsProtocol.displayText(details)).font(.callout).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                                }
                            }
                            ForEach(s.fields.filter { step.fields.contains($0.id) }) { field in fieldView(field) }
                            ForEach(step.actions, id: \.self) { id in
                                if let action = s.actions.first(where: { $0.id == id }) {
                                    actionView(action, primary: step.primaryAction == id)
                                }
                            }
                        }.padding(.top, 12)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(index + 1). \(label(step.title))").font(.headline)
                            Spacer()
                            Text(stateTitle(step.state)).font(.caption.weight(.medium))
                                .foregroundStyle(step.state == "attention" ? Color.orange : step.state == "completed" ? Color.green : Color.secondary)
                        }
                    }
                    .id(step.id)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(guide.currentStep == step.id ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))
                }
            }
            // 未參與精靈的新欄位仍可操作，不因可選的精靈描述而消失。
            ForEach(s.fields.filter { $0.tab == tab.id && !guide.steps.flatMap(\.fields).contains($0.id) }) { field in fieldView(field) }
            let extra = s.actions.filter { action in
                action.tab == tab.id && action.id != guide.checkAction && !guide.steps.flatMap(\.actions).contains(action.id)
            }
            if !extra.isEmpty {
                DisclosureGroup("連線與進階管理") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(extra) { action in actionView(action) }
                    }.padding(.top, 12)
                }
            }
        }
        .onChange(of: guide.currentStep) { stepExpanded = stepExpanded.filter { !$0.key.hasPrefix(tab.id + "|") } }
    }
    @ViewBuilder private func actionView(_ action: PluginSettingsProtocol.Action, primary: Bool = false) -> some View {
        if action.destructive == true { Divider() }
        let button = Button(label(action.title), role: action.destructive == true ? .destructive : nil) {
            if action.destructive == true { confirming = action }
            else { perform(action) }
        }
        .disabled(model.busy || model.dirty || model.snapshot?.job?.state == "running")
        if primary { button.buttonStyle(.borderedProminent) }
        else { button }
    }
    @ViewBuilder private func fieldView(_ f: PluginSettingsProtocol.Field) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if f.type != "toggle" { Text(label(f.title)).font(.headline) }
            switch f.type {
            case "toggle":
                Toggle(label(f.title), isOn: Binding(get: { model.draft[f.id]?.flag ?? false }, set: { model.draft[f.id] = .flag($0) }))
                    .toggleStyle(.switch)
            case "text", "time":
                TextField(f.type == "time" ? "HH:mm" : "", text: textBinding(f.id)).textFieldStyle(.roundedBorder)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 28)
                    .accessibilityLabel(label(f.title))
            case "secret":
                SecureField("貼上新值；留空保留原設定", text: textBinding(f.id))
                    .textFieldStyle(.roundedBorder)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 28)
                    .accessibilityLabel(label(f.title))
            case "stringList":
                TextEditor(text: Binding(get: { (model.draft[f.id]?.list ?? []).joined(separator: "\n") }, set: {
                    model.draft[f.id] = .list($0.components(separatedBy: "\n"))
                })).font(.body).frame(height: 76).border(.quaternary).accessibilityLabel(label(f.title))
            case "select":
                Picker(label(f.title), selection: textBinding(f.id)) {
                    ForEach(f.options ?? []) { Text(label($0.title)).tag($0.id) }
                }.labelsHidden()
            case "multiselect":
                if (f.options ?? []).isEmpty { Text("尚無可選取項目，請先完成連接或重新載入清單。").foregroundStyle(.secondary) }
                ForEach(f.options ?? []) { option in
                    Toggle(label(option.title), isOn: Binding(get: {
                        model.draft[f.id]?.list.contains(option.id) ?? false
                    }, set: { on in
                        var values = model.draft[f.id]?.list ?? []
                        values.removeAll { $0 == option.id }
                        if on { values.append(option.id) }
                        model.draft[f.id] = .list(values)
                    }))
                }
            default:
                Text(PluginSettingsProtocol.displayText(model.snapshot?.values[f.id]?.text ?? "")).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let help = f.help { Text(PluginSettingsProtocol.displayText(help)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        // TabView 重新排版時，單行原生控制項的高度不能被壓縮為零。
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.busy || model.snapshot?.job?.state == "running")
    }
    private func perform(_ action: PluginSettingsProtocol.Action) {
        if action.input == "jsonFile" {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let h = try FileHandle(forReadingFrom: url)
                defer { try? h.close() }
                let data = try h.read(upToCount: 32 * 1024 + 1) ?? Data()
                guard data.count <= 32 * 1024, let input = String(data: data, encoding: .utf8) else {
                    throw PluginSettingsProtocol.Problem(message: "匯入檔案過大或不是 UTF-8 JSON")
                }
                _ = try JSONSerialization.jsonObject(with: data)
                Task { await model.action(action, input: input) }
            } catch { model.error = error.localizedDescription }
        } else {
            Task { await model.action(action) }
        }
    }
}
