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
    /// 由 `opensTab` 進入隱藏頁籤前所在的頁籤，供「返回」使用。
    @Published private(set) var returnTabID: String?
    @Published private(set) var jobOrigin: JobOrigin?
    @Published private(set) var dismissedJobID: String?
    /// 由視窗管理者設定；取消時關閉所在視窗。
    var requestClose: (() -> Void)?
    struct JobOrigin: Equatable { let jobID: String; let title: String; let at: Date }
    struct Notice: Equatable { let origin: JobOrigin?; let job: P.Job }
    private let command: @MainActor (String, P.Request?) async throws -> P.Snapshot
    private let now: () -> Date
    private let pollInterval: Duration
    private var polling: Task<Void, Never>?
    private var visible = true
    private var lastChecks: [String: Date] = [:]
    private var pendingChecks: [String: Bool] = [:]
    private var externalTab: String?
    private var postJobCheck: (id: String, tab: String)?
    /// 上一次進入的頁籤；開窗後第一次進入不算使用者切換。
    private var enteredTabID: String?

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
    var canCancel: Bool { !busy }
    /// 對話框慣例：取消即捨棄未儲存的變更並關閉視窗，所以不會再跳出捨棄確認。
    func cancelAndClose() {
        cancelEdits()
        requestClose?()
    }
    func stop() {
        visible = false
        polling?.cancel()
        polling = nil
        pendingChecks.removeAll()
        externalTab = nil
        postJobCheck = nil
    }
    /// 頂端只顯示目前工作的訊息；由此視窗觸發的工作附上動作標題與時間。
    var notice: Notice? {
        guard let job = snapshot?.job, job.id != dismissedJobID else { return nil }
        return Notice(origin: jobOrigin?.jobID == job.id ? jobOrigin : nil, job: job)
    }
    func dismissNotice() { dismissedJobID = snapshot?.job?.id }
    func load() async { _ = await execute("snapshot") }
    func enterTab(_ id: String) async {
        selectedTabID = id
        if snapshot?.tabs.first(where: { $0.id == id })?.hidden != true { returnTabID = nil }
        if let previous = enteredTabID, previous != id, let job = snapshot?.job, job.state == "succeeded" { dismissedJobID = job.id }
        enteredTabID = id
        await checkCurrentTab()
    }
    func returnFromHiddenTab() {
        selectedTabID = returnTabID ?? snapshot?.visibleTabs.first?.id ?? ""
        returnTabID = nil
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
        guard let s = snapshot, s.actions.contains(where: { $0 == a }) else { return }
        if let target = a.opensTab {
            if returnTabID == nil { returnTabID = selectedTabID }
            selectedTabID = target
            return
        }
        guard !dirty else { return }
        if a.opensExternal == true { externalTab = a.tab }
        if await execute("action", request: P.Request(revision: s.revision, id: a.id, input: input), origin: a.title),
           a.recheckAfter == true {
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
    private func execute(_ operation: String, request: P.Request? = nil, origin: String? = nil) async -> Bool {
        guard !busy, visible, snapshot?.job?.state != "running" || operation == "snapshot" else { return false }
        busy = true
        error = nil
        var succeeded = false
        do {
            let wasDirty = dirty
            let previousJob = snapshot?.job?.id
            let fresh = try await command(operation, request)
            if visible {
                snapshot = fresh
                if let origin, let job = fresh.job, job.id != previousJob {
                    jobOrigin = JobOrigin(jobID: job.id, title: origin, at: now())
                }
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
        model.requestClose = { [weak window] in window?.performClose(nil) }
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

private struct LabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension PluginSettingsProtocol.Tone {
    var color: Color {
        switch self {
        case .ok: .green
        case .info: .accentColor
        case .warn: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }
}

struct PluginConfigurationView: View {
    typealias P = PluginSettingsProtocol
    @ObservedObject var model: PluginConfigurationModel
    @State private var confirming: P.Action?
    @State private var stepExpanded: [String: Bool] = [:]
    @State private var editingGuides: Set<String> = []
    @State private var openHelp: Set<String> = []
    /// 同一頁籤所有分組共用的標題欄寬度，取各標題自然寬度的最大值。
    @State private var labelColumn: CGFloat?

    private func label(_ text: String) -> String { PluginLogic.sanitize(text) }
    private var locked: Bool { model.busy || model.snapshot?.job?.state == "running" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(label(model.snapshot?.title ?? "外掛設定")).font(.title2.weight(.semibold))
                    Text("背景工作與設定由此外掛管理。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("正在載入外掛設定") }
            }
            if let message = model.error {
                Text(P.displayText(message)).foregroundStyle(.red).textSelection(.enabled)
            }
            if let s = model.snapshot {
                if let notice = model.notice { noticeView(notice) }
                navigation(s)
                if let tab = s.tabs.first(where: { $0.id == model.selectedTabID }) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            tabContent(tab, snapshot: s).padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: tab.guide?.currentStep) {
                            if let step = tab.guide?.currentStep { proxy.scrollTo(step, anchor: .top) }
                        }
                    }
                    .id(tab.id)
                } else {
                    Spacer()
                }
                Divider()
                HStack {
                    Button("重新載入") { Task { await model.load() } }.disabled(model.busy || model.dirty)
                    if model.dirty {
                        Text(model.checkDeferred ? "有未儲存變更；儲存或取消後會接續檢查。" : "請先儲存或取消變更，再執行測試與其他操作。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消") { model.cancelAndClose() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!model.canCancel)
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
            model.selectedTabID = model.snapshot?.visibleTabs.first?.id ?? ""
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

    @ViewBuilder private func navigation(_ s: P.Snapshot) -> some View {
        if let current = s.tabs.first(where: { $0.id == model.selectedTabID }), current.hidden == true {
            HStack(spacing: 10) {
                Button { model.returnFromHiddenTab() } label: { Label("返回", systemImage: "chevron.left") }
                Text(label(current.title)).font(.headline)
                Spacer()
            }
        } else {
            // 頁籤多或標題長、分段控制放不下時改用選單，避免超出視窗。
            ViewThatFits(in: .horizontal) {
                tabPicker(s).pickerStyle(.segmented).fixedSize()
                tabPicker(s).pickerStyle(.menu).fixedSize()
            }
            .frame(maxWidth: .infinity)
        }
    }
    private func tabPicker(_ s: P.Snapshot) -> some View {
        Picker("頁籤", selection: $model.selectedTabID) {
            ForEach(s.visibleTabs) { Text(label($0.title)).tag($0.id) }
        }
        .labelsHidden()
    }
    private func noticeView(_ notice: PluginConfigurationModel.Notice) -> some View {
        let tone: P.Tone = notice.job.state == "failed" ? .warn : notice.job.state == "running" ? .info : .ok
        return HStack(alignment: .top, spacing: 10) {
            if notice.job.state == "running" { ProgressView().controlSize(.small) }
            else { Image(systemName: tone == .warn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(tone.color) }
            VStack(alignment: .leading, spacing: 2) {
                if let origin = notice.origin {
                    Text("\(label(origin.title)) · \(origin.at.formatted(date: .omitted, time: .shortened))").font(.callout.weight(.semibold))
                }
                Text(P.displayText(notice.job.message)).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if notice.job.state != "running" {
                Button { model.dismissNotice() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("關閉訊息")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tone.color.opacity(0.1)))
    }
    @ViewBuilder private func tabContent(_ tab: P.Tab, snapshot s: P.Snapshot) -> some View {
        let layout = s.layout(of: tab)
        VStack(alignment: .leading, spacing: 16) {
            if let help = tab.help {
                Text(P.displayText(help)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let guide = tab.guide {
                guideView(guide, tab: tab, snapshot: s)
            } else {
                if let summary = layout.summary { summaryCard(summary, snapshot: s) }
                ForEach(layout.groups) { group in groupCard(group, tab: tab, snapshot: s) }
                ForEach(layout.looseFields) { field in
                    fieldView(field)
                    ForEach(layout.actions(after: field.id)) { action in actionView(action) }
                }
                ForEach(layout.trailingActions) { action in actionView(action) }
            }
        }
        // 掛在整個頁籤上才會合併所有分組；掛在 ForEach 上會變成每組各自回報。
        .onPreferenceChange(LabelWidthKey.self) { labelColumn = $0 > 0 ? min($0, 200) : nil }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }
    private func dot(_ tone: P.Tone) -> some View {
        Circle().fill(tone.color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
    private func badge(_ text: String, _ tone: P.Tone) -> some View {
        Text(label(text)).font(.caption2.weight(.medium)).foregroundStyle(tone.color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(tone.color.opacity(0.15)))
    }
    private func summaryCard(_ summary: P.Summary, snapshot s: P.Snapshot) -> some View {
        card {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label(summary.eyebrow)).font(.caption).foregroundStyle(.secondary)
                    Text(label(summary.headline)).font(.title.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let reason = summary.reason {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            dot(summary.tone)
                            Text(P.displayText(reason)).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let id = summary.toggleField, let field = s.fields.first(where: { $0.id == id }) {
                    summaryToggle(field, snapshot: s)
                }
            }
            if !summary.metrics.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(summary.metrics.enumerated()), id: \.offset) { index, metric in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(metric.label)).font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(label(metric.value)).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                if let b = metric.badge { badge(b.text, b.tone) }
                            }
                            if let detail = metric.detail {
                                Text(P.displayText(detail)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    private func summaryToggle(_ field: P.Field, snapshot s: P.Snapshot) -> some View {
        let saved = s.values[field.id]?.flag ?? false
        let pending = model.draft[field.id] != s.values[field.id]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label(field.title)).font(.callout.weight(.semibold))
                HStack(spacing: 5) {
                    dot(pending ? .warn : saved ? .ok : .neutral)
                    Text(pending ? "尚未儲存" : saved ? "已啟用" : "未啟用").font(.caption)
                        .foregroundStyle(pending ? P.Tone.warn.color : saved ? P.Tone.ok.color : .secondary)
                }
            }
            Toggle(label(field.title), isOn: flagBinding(field.id)).toggleStyle(.switch).labelsHidden()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .help(field.help.map(P.displayText) ?? "")
        .disabled(locked)
    }
    private func groupCard(_ group: P.Group, tab: P.Tab, snapshot s: P.Snapshot) -> some View {
        let key = tab.id + "|" + group.id
        let fields = group.fields.compactMap { id in s.fields.first { $0.id == id } }
        let actions = group.actions.compactMap { id in s.actions.first { $0.id == id } }
        let trailing = actions.filter { a in !group.fields.contains { $0 == a.afterField } }
        return card {
            HStack(alignment: .firstTextBaseline) {
                Text(label(group.title)).font(.headline)
                Spacer()
                if group.help != nil {
                    Button(openHelp.contains(key) ? "收合說明" : "說明") {
                        if !openHelp.insert(key).inserted { openHelp.remove(key) }
                    }
                    .buttonStyle(.link)
                }
            }
            if let help = group.help, openHelp.contains(key) {
                Text(P.displayText(help)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                ForEach(fields) { field in
                    GridRow {
                        groupLabel(field.title)
                        VStack(alignment: .leading, spacing: 6) {
                            control(field, compact: true)
                            if let help = field.help {
                                Text(P.displayText(help)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(actions.filter { $0.afterField == field.id }) { action in actionView(action, inline: true) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(locked)
                    }
                }
                ForEach(Array((group.rows ?? []).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        groupLabel(row.label)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let tone = row.tone { dot(tone) }
                            Text(P.displayText(row.value)).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let id = row.action, let action = s.actions.first(where: { $0.id == id }) {
                                actionView(action, inline: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !trailing.isEmpty {
                    GridRow {
                        Color.clear.frame(width: labelColumn ?? 0).gridCellUnsizedAxes(.vertical)
                        HStack(spacing: 8) { ForEach(trailing) { action in actionView(action, inline: true) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// 標題靠左、固定為共用欄寬；以不受欄寬限制的隱藏副本量測自然寬度。
    private func groupLabel(_ text: String) -> some View {
        Text(label(text))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: labelColumn, alignment: .leading)
            .background(Text(label(text)).fixedSize().hidden().background(GeometryReader { proxy in
                Color.clear.preference(key: LabelWidthKey.self, value: proxy.size.width)
            }))
            .gridColumnAlignment(.leading)
    }
    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { model.draft[id]?.text ?? "" }, set: { model.draft[id] = .text($0) })
    }
    private func flagBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.draft[id]?.flag ?? false }, set: { model.draft[id] = .flag($0) })
    }
    private var saveTitle: String {
        let guide = model.snapshot?.tabs.first { $0.id == model.selectedTabID }?.guide
        return guide?.steps.first { step in
            step.saveTitle != nil && step.fields.contains { model.draft[$0] != model.snapshot?.values[$0] }
        }?.saveTitle ?? "儲存"
    }
    private func stateTitle(_ state: String) -> String {
        ["pending": "待處理", "checking": "檢查中", "completed": "已完成", "attention": "需要處理"][state] ?? "待處理"
    }
    @ViewBuilder private func guideView(_ guide: P.Guide, tab: P.Tab, snapshot s: P.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(P.displayText(guide.summary)).font(.callout).textSelection(.enabled)
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
                            Text(P.displayText(step.help)).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if let details = step.details {
                                DisclosureGroup("查看操作說明") {
                                    Text(P.displayText(details)).font(.callout).textSelection(.enabled)
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
    /// `inline` 用於卡片內的列尾或表單列，不另加分隔線。
    @ViewBuilder private func actionView(_ action: P.Action, primary: Bool = false, inline: Bool = false) -> some View {
        if action.destructive == true, !inline { Divider() }
        HStack(spacing: 6) {
            if action.signsIn == true { badge("會登入", .error) }
            let button = Button(label(action.title), role: action.destructive == true ? .destructive : nil) {
                if action.destructive == true { confirming = action }
                else { perform(action) }
            }
            // 切換到隱藏頁籤本身不呼叫外掛，草稿與執行中的工作都不影響按鈕。
            .disabled(action.opensTab == nil && (model.busy || model.dirty || model.snapshot?.job?.state == "running"))
            if primary { button.buttonStyle(.borderedProminent) }
            else { button }
        }
    }
    private static func clockTime(_ text: String) -> Date? {
        let parts = text.split(separator: ":")
        guard text.count == 5, parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date(timeIntervalSinceReferenceDate: 0))
    }
    private static func clockText(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    /// 可解析的 HH:mm 用 24 小時制時間選擇器；外掛給的值無法解析時退回窄文字欄位，避免默默改值。
    @ViewBuilder private func timeControl(_ f: P.Field) -> some View {
        if let current = Self.clockTime(model.draft[f.id]?.text ?? "") {
            DatePicker(label(f.title), selection: Binding(get: { Self.clockTime(model.draft[f.id]?.text ?? "") ?? current },
                                                          set: { model.draft[f.id] = .text(Self.clockText($0)) }),
                       displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField).labelsHidden().fixedSize()
                .environment(\.locale, Locale(identifier: "en_GB"))
        } else {
            TextField("HH:mm", text: textBinding(f.id)).textFieldStyle(.roundedBorder).frame(width: 80)
                .accessibilityLabel(label(f.title))
        }
    }
    /// 欄位本身的輸入控制項；標題與說明由外層決定排版。分組卡片內的文字欄位改用固定上限寬度。
    @ViewBuilder private func control(_ f: P.Field, compact: Bool = false) -> some View {
        switch f.type {
        case "toggle":
            Toggle(label(f.title), isOn: flagBinding(f.id)).toggleStyle(.switch).labelsHidden()
        case "time":
            timeControl(f)
        case "text":
            TextField("", text: textBinding(f.id)).textFieldStyle(.roundedBorder)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 28).frame(maxWidth: compact ? 220 : .infinity)
                .accessibilityLabel(label(f.title))
        case "secret":
            SecureField("貼上新值；留空保留原設定", text: textBinding(f.id))
                .textFieldStyle(.roundedBorder)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 28).frame(maxWidth: compact ? 300 : .infinity)
                .accessibilityLabel(label(f.title))
        case "stringList":
            TextEditor(text: Binding(get: { (model.draft[f.id]?.list ?? []).joined(separator: "\n") }, set: {
                model.draft[f.id] = .list($0.components(separatedBy: "\n"))
            })).font(.body).frame(maxWidth: compact ? 360 : .infinity).frame(height: 76).border(.quaternary).accessibilityLabel(label(f.title))
        case "select":
            Picker(label(f.title), selection: textBinding(f.id)) {
                ForEach(f.options ?? []) { Text(label($0.title)).tag($0.id) }
            }.labelsHidden().frame(maxWidth: compact ? 320 : nil)
        case "multiselect":
            VStack(alignment: .leading, spacing: 6) {
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
            }
        default:
            Text(P.displayText(model.snapshot?.values[f.id]?.text ?? "")).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    /// 未分組欄位維持原本「標題在上、控制項在下」的排版。
    @ViewBuilder private func fieldView(_ f: P.Field) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if f.type == "toggle" {
                Toggle(label(f.title), isOn: flagBinding(f.id)).toggleStyle(.switch)
            } else {
                Text(label(f.title)).font(.headline)
                control(f)
            }
            if let help = f.help { Text(P.displayText(help)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        // 重新排版時，單行原生控制項的高度不能被壓縮為零。
        .fixedSize(horizontal: false, vertical: true)
        .disabled(locked)
    }
    private func perform(_ action: P.Action) {
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
                    throw P.Problem(message: "匯入檔案過大或不是 UTF-8 JSON")
                }
                _ = try JSONSerialization.jsonObject(with: data)
                Task { await model.action(action, input: input) }
            } catch { model.error = error.localizedDescription }
        } else {
            Task { await model.action(action) }
        }
    }
}
