// 主視窗：連線、設定、環境檢查、關於四個分頁
import SwiftUI
import ServiceManagement

enum MainTab: Hashable { case connection, settings, environment, about }

@MainActor
final class WindowModel: ObservableObject {
    @Published var tab: MainTab = .connection
    @Published var showLog = false
}

struct MainView: View {
    @ObservedObject var vpn: VPNController
    @ObservedObject var env: EnvChecker
    @ObservedObject var window: WindowModel

    var body: some View {
        TabView(selection: $window.tab) {
            ConnectionTab(vpn: vpn, env: env, window: window)
                .tabItem { Label("連線", systemImage: "network") }
                .tag(MainTab.connection)
            SettingsTab(vpn: vpn, env: env)
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(MainTab.settings)
            EnvironmentTab(env: env, window: window)
                .tabItem { Label("環境檢查", systemImage: "checklist") }
                .tag(MainTab.environment)
            AboutTab()
                .tabItem { Label("關於", systemImage: "info.circle") }
                .tag(MainTab.about)
        }
        .padding(16)
        .controlSize(.large)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 620, idealHeight: 720)
    }
}

// MARK: - 連線

struct ConnectionTab: View {
    @ObservedObject var vpn: VPNController
    @ObservedObject var env: EnvChecker
    @ObservedObject var window: WindowModel
    @AppStorage(MenuBarIcon.styleKey) private var styleRaw = MenuBarIconStyle.shield.rawValue

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 4)
            bigIcon
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: vpn.busy || vpn.state.isConnecting)
            VStack(spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                if case .connected(_, let ip) = vpn.state {
                    Text("虛擬 IP：\(ip)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if let since = vpn.connectedSince {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("已連線 \(duration(since, ctx.date))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if vpn.busy { Text(vpn.busyText).font(.callout).foregroundStyle(.secondary) }
                else if let note = vpn.retryNote { Text(note).font(.callout).foregroundStyle(.orange) }
            }

            if vpn.state == .helperMissing || !env.allOK {
                Button("尚未完成環境設定，前往環境檢查") { window.tab = .environment }
                    .buttonStyle(.link)
            }

            VStack(spacing: 10) {
                // 有連線意圖（含自動重連中、等待重試）或通道還在，就顯示斷線；斷線可以搶先執行中的連線
                if vpn.wantConnected || vpn.state.isConnected || vpn.state.isConnecting {
                    Button(role: .destructive) { vpn.disconnect() } label: {
                        Label(vpn.state.isConnected ? "斷線" : "停止連線", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(vpn.busyText == "斷線中…")
                } else {
                    Button { vpn.connect("auto") } label: {
                        Label("連線（自動輪替）", systemImage: "bolt.horizontal.circle").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(vpn.busy || vpn.state == .helperMissing)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(0..<3, id: \.self) { i in
                            VStack(spacing: 4) {
                                Button("VPN\(i + 1)") { vpn.connect("\(i + 1)") }
                                    .frame(maxWidth: .infinity)
                                    .help(vpn.gatewayTitle(i))
                                    .disabled(vpn.busy || vpn.state == .helperMissing || vpn.settings.gateways[i].isEmpty)
                                // 最近狀態（F4），例：「上次 3.2 秒連上」；沒有紀錄就不顯示
                                if let d = vpn.history.detail(i + 1) {
                                    Text(d).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).minimumScaleFactor(0.8)
                                        .help(vpn.history.statusText(i + 1))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(maxWidth: 320)

            if let err = vpn.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 8)
            LogPanel(expanded: $window.showLog)
        }
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch vpn.state {
        case .connected(let c, _): return "已連線：\(c.uppercased())"
        case .connecting(let c): return "連線中：\(c.uppercased())…"
        case .disconnected: return vpn.busy ? "處理中…" : "未連線"
        case .helperMissing: return "系統元件未就緒"
        }
    }
    /// 跟狀態列同一組樣式的大圖示
    @ViewBuilder private var bigIcon: some View {
        let style = MenuBarIconStyle(rawValue: styleRaw) ?? .shield
        let st = MenuBarIcon.state(for: vpn.state, busy: vpn.busy)
        if let name = style.symbol(st) {
            Image(systemName: name).font(.system(size: 64, weight: .regular))
        } else {
            Image(nsImage: MenuBarIcon.textImage(state: st, height: 60, tint: nil))
                .renderingMode(.template)
        }
    }
    private var color: Color {
        switch vpn.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return vpn.busy ? .orange : .secondary
        case .helperMissing: return .red
        }
    }
    private func duration(_ from: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(from)))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

// MARK: - 設定

struct SettingsTab: View {
    @ObservedObject var vpn: VPNController
    @ObservedObject var env: EnvChecker

    @State private var draft = VPNSettings()
    @State private var password = ""
    @State private var psk = ""
    @State private var message: (String, Bool)?     // 訊息、是否為錯誤
    @State private var secretState = (psk: false, password: false)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var preset: CompanyPreset? = CompanyPresetStore.load()

    @AppStorage(DropDetector.enabledKey) private var notifyDrop = true
    @State private var notifyDenied = false          // macOS 通知權限被拒絕
    @State private var tsText = ""                  // 通道網段編輯框：一行一個
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsCard("帳號") {
                        FieldRow("使用者名稱") {
                            TextField("", text: $draft.username, prompt: Text("VPN 帳號"))
                        }
                        FieldRow("密碼") {
                            SecureField("", text: $password, prompt: Text(secretState.password ? "已設定，留空表示不變" : "尚未設定"))
                        }
                        FieldRow("預設共享金鑰（PSK）") {
                            SecureField("", text: $psk, prompt: Text(secretState.psk ? "已設定，留空表示不變" : "尚未設定"))
                        }
                    }

                    SettingsCard("閘道") {
                        ForEach(0..<3, id: \.self) { i in
                            FieldRow("VPN\(i + 1)") {
                                TextField("", text: $draft.gateways[i], prompt: Text("IP 或網域，可留空"))
                            }
                        }
                        // F4：自動輪替依過去的連線結果排序；位址改了並儲存時，該台紀錄會自動清除
                        HStack(spacing: 10) {
                            Button("清除閘道連線紀錄") {
                                vpn.clearHistory()
                                message = ("已清除閘道連線紀錄，自動輪替恢復設定順序", false)
                            }
                            .disabled(vpn.history.attempts.isEmpty)
                            Text("自動輪替會先試最近連得上、連得快的閘道")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    SettingsCard("通道網段") {
                        Text("只有這些目的地會走 VPN，其他流量（Teams、Google Meet、一般上網）走原本的網路。**一行一個**；單一主機寫成 `IP/32`。**不要填 0.0.0.0/0**，全部流量走 VPN 會讓外網 DNS 失效。")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: $tsText)
                            .font(.system(size: 14, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 150)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
                        HStack(spacing: 10) {
                            Button("匯入設定檔…") { importPreset() }
                            Button("匯出加密設定檔…") { exportConfig() }
                            Button("從公司設定還原") {
                                guard let p = preset else { return }
                                draft.gateways = p.gateways
                                tsText = Self.lines(p.remoteTS)
                                message = ("已填入公司設定，按「儲存」後生效", false)
                            }
                            .disabled(preset == nil)
                            Spacer()
                        }
                        Text(preset.map { "公司設定：\($0.name)（\($0.source == CompanyPresetStore.path ? "~/.config/splitswan/company.env" : $0.source)）" } ?? "尚未匯入公司設定檔")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        DisclosureGroup("某台公司主機連不上？", isExpanded: $showHelp) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("1. 查出主機的 IP：終端機執行 `dig +short 主機網域`")
                                Text("2. 在上面的通道網段加一行 `IP/32`，按「儲存」")
                                Text("3. 斷線後重新連線，新網段才會生效")
                                Text("4. 確認有走 VPN：終端機執行 `route -n get IP`，interface 應該是 utun 開頭")
                                Text("5. 還是不通，請把 IP 與使用的連接埠告訴管理者，確認公司端是否允許")
                            }
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .padding(.top, 6)
                        }
                    }

                    SettingsCard("狀態列圖示") {
                        IconStylePicker()
                    }

                    SettingsCard("其他") {
                        Toggle("登入時自動啟動", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                        Toggle("VPN 中斷時通知", isOn: $notifyDrop)
                            .toggleStyle(.switch)
                            .onChange(of: notifyDrop) { _, _ in checkNotifyPermission() }
                        if notifyDrop && notifyDenied {
                            Text("macOS 未允許通知，請到「系統設定 → 通知」開啟")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            }

            Divider().padding(.vertical, 10)
            // 底部固定：訊息與儲存，不必捲到最下面才按得到
            HStack(spacing: 10) {
                if let (text, isError) = message {
                    Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? .orange : .green).font(.callout)
                        .lineLimit(2)
                }
                Spacer()
                Button("還原") { loadDraft() }
                Button("儲存") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { loadDraft(); checkNotifyPermission() }
    }

    private func checkNotifyPermission() {
        Task { notifyDenied = await DropNotifier.isDenied() }
    }

    /// 「a, b, c」→ 一行一個
    static func lines(_ ts: String) -> String {
        ts.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 編輯框的內容（換行或逗號分隔都接受）→ 設定檔用的「a, b, c」
    static func commaList(_ text: String) -> String {
        lines(text).split(separator: "\n").joined(separator: ", ")
    }

    private func loadDraft() {
        draft = ConfigStore.load()
        while draft.gateways.count < 3 { draft.gateways.append("") }
        tsText = Self.lines(draft.remoteTS)
        password = ""; psk = ""; message = nil
        secretState = ConfigStore.secretsStatus()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        preset = CompanyPresetStore.load()
    }

    /// 匯入設定檔：加密的 .splitswan（會詢問密碼）或明文的 company.env。
    /// 公司設定存到 ~/.config/splitswan/company.env；PSK 先放進欄位，按「儲存」才寫入 strongSwan
    private func importPreset() {
        let panel = NSOpenPanel()
        panel.title = "選擇設定檔"
        panel.message = "選擇管理者提供的設定檔（加密的 .splitswan，或 company.env）"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if ConfigExport.isEncryptedFile(data) {
                guard let pass = Self.askPassphrase(title: "輸入設定檔密碼",
                                                    info: "這是加密的設定檔，請輸入匯出時設定的密碼。", confirm: false) else { return }
                let payload = try ConfigExport.decrypt(data, passphrase: pass)
                // 來源不可信：整份嚴格驗證，並讓使用者確認閘道與網段後才寫入
                let p = try CompanyPresetStore.strictPreset(name: payload.name,
                                                             gatewaysCSV: payload.gateways.joined(separator: ","),
                                                             remoteTS: payload.remoteTS)
                if let k = payload.psk, k.contains(where: { $0.isNewline }) {
                    throw ConfigError.invalid("設定檔裡的 PSK 含有換行，已拒絕")
                }
                guard Self.confirmImport(p, hasPSK: payload.psk?.isEmpty == false) else { return }
                try CompanyPresetStore.apply(p)
                preset = p
                draft.gateways = p.gateways
                tsText = Self.lines(p.remoteTS)
                if let k = payload.psk, !k.isEmpty { psk = k }
                message = (payload.psk == nil ? "已匯入「\(p.name)」（不含 PSK），填好帳號密碼與 PSK 後按「儲存」"
                                              : "已匯入「\(p.name)」與 PSK，填好帳號密碼後按「儲存」", false)
            } else {
                let p = try CompanyPresetStore.readFile(at: url)
                guard Self.confirmImport(p, hasPSK: false) else { return }
                try CompanyPresetStore.apply(p)
                preset = p
                draft.gateways = p.gateways
                tsText = Self.lines(p.remoteTS)
                message = ("已匯入「\(p.name)」，確認帳號密碼後按「儲存」", false)
            }
        } catch {
            message = (error.localizedDescription, true)
        }
    }

    /// 匯出加密設定檔：目前畫面上的閘道、通道網段＋PSK（不含個人帳號密碼），用自訂密碼加密
    private func exportConfig() {
        var probe = draft
        probe.username = "probe"
        probe.remoteTS = Self.commaList(tsText)
        do { try ConfigStore.validate(probe) } catch { message = (error.localizedDescription, true); return }

        let key = psk.isEmpty ? ConfigStore.currentPSK() : psk
        if key == nil {
            let a = NSAlert()
            a.messageText = "尚未設定 PSK"
            a.informativeText = "匯出的檔案不會包含預設共享金鑰，同事匯入後要自己輸入。要繼續嗎？"
            a.addButton(withTitle: "繼續匯出")
            a.addButton(withTitle: "取消")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let pass = Self.askPassphrase(title: "設定匯出密碼",
                                            info: "同事匯入時需要輸入這組密碼。請把檔案與密碼分開傳送（例：檔案用 email、密碼用 Teams 口頭告知）。至少 \(ConfigExport.minPassphraseLength) 個字元。",
                                            confirm: true) else { return }

        let panel = NSSavePanel()
        panel.title = "匯出加密設定檔"
        panel.nameFieldStringValue = "\(preset?.name ?? "公司")-VPN設定.\(ConfigExport.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let payload = ExportPayload(name: preset?.name ?? "公司設定", gateways: draft.gateways,
                                        remoteTS: Self.commaList(tsText), psk: key)
            let data = try ConfigExport.encrypt(payload, passphrase: pass)
            // 一建立就是 600，再換到目標位置
            let tmp = url.path + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
            guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw ConfigError.invalid("無法寫入 \(url.lastPathComponent)")
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: URL(fileURLWithPath: tmp))
            } else {
                try FileManager.default.moveItem(atPath: tmp, toPath: url.path)
            }
            message = ("已匯出到 \(url.lastPathComponent)\(key == nil ? "（不含 PSK）" : "（含 PSK，不含帳號密碼）")", false)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            message = (error.localizedDescription, true)
        }
    }

    /// 匯入前讓使用者確認閘道與網段：加密只能保密，不能證明檔案是管理者發的，
    /// 惡意檔案可能把閘道換成別人的主機（帳號密碼會送過去）
    static func confirmImport(_ p: CompanyPreset, hasPSK: Bool) -> Bool {
        let a = NSAlert()
        a.messageText = "確認要套用這份設定嗎？"
        let gws = p.gateways.enumerated().filter { !$0.element.isEmpty }.map { "VPN\($0.offset + 1)：\($0.element)" }.joined(separator: "\n")
        let nets = p.remoteTS.split(separator: ",").map { "  " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        a.informativeText = """
        名稱：\(p.name)
        \(gws)
        \(hasPSK ? "含預設共享金鑰（PSK）" : "不含 PSK")

        會走 VPN 的網段：
        \(nets)

        請確認閘道位址是公司的。來路不明的設定檔可能把你的帳號密碼送到別人的主機。
        """
        a.addButton(withTitle: "套用")
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// 詢問密碼的對話框；confirm = true 時要輸入兩次。取消回傳 nil
    static func askPassphrase(title: String, info: String, confirm: Bool) -> String? {
        while true {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = info
            a.addButton(withTitle: "確定")
            a.addButton(withTitle: "取消")
            let p1 = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 30 : 0, width: 280, height: 24))
            p1.placeholderString = "密碼"
            let p2 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            p2.placeholderString = "再輸入一次"
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: confirm ? 54 : 24))
            box.addSubview(p1)
            if confirm { box.addSubview(p2) }
            a.accessoryView = box
            a.window.initialFirstResponder = p1
            guard a.runModal() == .alertFirstButtonReturn else { return nil }
            let v = p1.stringValue
            if confirm && v.count < ConfigExport.minPassphraseLength {
                Self.warn("密碼至少要 \(ConfigExport.minPassphraseLength) 個字元"); continue
            }
            if confirm && v != p2.stringValue { Self.warn("兩次輸入的密碼不一致"); continue }
            return v
        }
    }

    private static func warn(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.alertStyle = .warning
        a.runModal()
    }

    private func save() {
        draft.remoteTS = Self.commaList(tsText)
        do {
            try ConfigStore.save(draft, psk: psk.isEmpty ? nil : psk, password: password.isEmpty ? nil : password)
            vpn.reloadConfig()
            env.check()
            loadDraft()
            message = ("已儲存；目前的連線不受影響，下次連線時套用", false)
        } catch {
            message = (error.localizedDescription, true)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on, SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if !on, SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {
            message = ("無法設定自動啟動：\(error.localizedDescription)", true)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// 連線紀錄：strongSwan 的即時 log＋App 自己的動作，可展開收合、拷貝、清除
struct LogPanel: View {
    @Binding var expanded: Bool
    @ObservedObject var store = LogStore.shared
    @State private var appOnly = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Label("連線紀錄（\(store.lines.count)）", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                if !store.streaming {
                    Text("未連到 strongSwan").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if expanded {
                    Toggle("只看 App 動作", isOn: $appOnly).toggleStyle(.checkbox).font(.caption)
                    Button("拷貝") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.allText, forType: .string)
                    }
                    .controlSize(.small)
                    Button("清除") { store.clear() }.controlSize(.small)
                }
            }
            if expanded {
                let shown = appOnly ? store.lines.filter(\.fromApp) : store.lines
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(shown) { line in
                                Text("\(Self.timeFmt.string(from: line.time))  \(line.text)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(line.fromApp ? Color.accentColor : Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                            if shown.isEmpty {
                                Text("還沒有紀錄。連線時這裡會顯示協商過程。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(8)
                    }
                    .frame(height: 220)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                    .onChange(of: store.lines.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }   // 新紀錄自動捲到底
                    }
                    .onAppear { if let id = shown.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 狀態列圖示樣式選擇：每個樣式顯示四種狀態的預覽，點一下就套用
struct IconStylePicker: View {
    @AppStorage(MenuBarIcon.styleKey) private var styleRaw = MenuBarIconStyle.shield.rawValue
    @AppStorage(MenuBarIcon.colorKey) private var colored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    let selected = style.rawValue == styleRaw
                    Button { styleRaw = style.rawValue } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(style.title).font(.callout.weight(.medium))
                                Spacer()
                                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            }
                            HStack(spacing: 14) {
                                ForEach(IconState.allCases, id: \.self) { st in
                                    if let img = MenuBarIcon.image(style: style, state: st, colored: colored, pointSize: 17) {
                                        Image(nsImage: img)
                                            .renderingMode(img.isTemplate ? .template : .original)
                                            .help(st.title)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("每組由左到右：未連線、已連線、連線中、異常。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("已連線時顯示綠色", isOn: $colored).toggleStyle(.switch)
        }
    }
}

/// 設定頁的區塊：標題＋圓角底
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        }
    }
}

/// 標籤在上、輸入框佔滿整行
struct FieldRow<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field
    init(_ label: String, @ViewBuilder field: () -> Field) { self.label = label; self.field = field() }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            field.font(.system(size: 14)).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 環境檢查

struct EnvironmentTab: View {
    @ObservedObject var env: EnvChecker
    @ObservedObject var window: WindowModel
    @ObservedObject private var report = DiagnosticRunner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(env.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(item.level))
                        .foregroundStyle(color(item.level))
                        .font(.title3)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.body.weight(.medium))
                        Text(item.detail).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if item.action != .none {
                        Button(item.actionTitle) { perform(item.action) }
                            .disabled(env.running)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                if env.running {
                    ProgressView().controlSize(.small)
                    Text(env.runningText).font(.callout).foregroundStyle(.secondary)
                } else if let msg = env.lastMessage {
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新檢查") { env.check() }.disabled(env.running)
            }

            // F3：診斷報告（規格 §5）。只讀取現況，不會改變連線狀態
            HStack {
                if report.running {
                    ProgressView().controlSize(.small)
                    Text(report.progressText).font(.callout).foregroundStyle(.secondary)
                } else if let msg = report.lastMessage {
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("連線有問題時，產生報告傳給管理者（不含密碼與預設共享金鑰）")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("產生診斷報告") { report.generate(checks: env.items) }
                    .disabled(report.running)
            }
        }
        .onAppear { env.check() }
    }

    private func perform(_ a: CheckAction) {
        switch a {
        case .installStrongSwan: env.installStrongSwan()
        case .installHelper: env.installHelper()
        case .openSettings: window.tab = .settings
        case .none: break
        }
    }
    private func symbol(_ l: CheckLevel) -> String {
        switch l {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .checking: return "clock"
        }
    }
    private func color(_ l: CheckLevel) -> Color {
        switch l {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .checking: return .secondary
        }
    }
}

// MARK: - 關於

struct AboutTab: View {
    private enum UpdateState: Equatable {
        case idle, checking
        case done(AboutInfo.Outcome)
    }
    @State private var update = UpdateState.idle
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 版本
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppInfo.name).font(.title2.weight(.semibold))
                        Text(AboutInfo.versionText(version: AppInfo.version, build: AppInfo.build))
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("拷貝版本資訊") { copyVersionInfo() }
                        Text(copied ? "已拷貝" : " ").font(.caption).foregroundStyle(.green)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

                SettingsCard("連結") {
                    linkButton("GitHub 專案頁", systemImage: "chevron.left.forwardslash.chevron.right", url: AppInfo.repoURL)
                    linkButton("使用說明（README）", systemImage: "book", url: AppInfo.readmeURL)
                    linkButton("所有版本下載（Releases）", systemImage: "arrow.down.circle", url: AppInfo.releasesURL)
                }

                SettingsCard("檢查更新") {
                    HStack(spacing: 10) {
                        Button(update == .checking ? "檢查中…" : "檢查更新") { checkUpdate() }
                            .disabled(update == .checking)
                        if update == .checking { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    updateResult
                    Text("只有按下「檢查更新」時才會連到 GitHub；不會自動下載或安裝。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SettingsCard("授權與致謝") {
                    HStack(spacing: 8) {
                        Text("\(AppInfo.name) 以 MIT 授權釋出。")
                        Button("查看授權") { NSWorkspace.shared.open(AppInfo.licenseURL) }
                            .buttonStyle(.link)
                        Spacer()
                    }
                    Text("使用 strongSwan（GPLv2）作為 VPN 引擎，以獨立程序呼叫，未連結或散布其程式碼，由使用者透過 Homebrew 安裝。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("FortiGate、FortiClient 是 Fortinet 的商標，本專案與 Fortinet 無關。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
            .padding(4)
        }
    }

    @ViewBuilder private var updateResult: some View {
        if case .done(let outcome) = update {
            switch outcome {
            case .newer(let v, let url):
                HStack(spacing: 10) {
                    Label("有新版本 \(v)", systemImage: "arrow.up.circle.fill").foregroundStyle(.orange)
                    Button("前往下載") { NSWorkspace.shared.open(url) }.buttonStyle(.borderedProminent)
                    Spacer()
                }
            case .upToDate(let v):
                Label("已是最新版本（\(v)）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let reason):
                HStack(spacing: 10) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("開啟 Releases 頁") { NSWorkspace.shared.open(AppInfo.releasesURL) }
                    Spacer()
                }
            }
        }
    }

    private func linkButton(_ title: String, systemImage: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: { Label(title, systemImage: systemImage) }
            .buttonStyle(.link)
            .help(url.absoluteString)
    }

    private func copyVersionInfo() {
        let text = AboutInfo.copyText(app: AppInfo.name, version: AppInfo.version, build: AppInfo.build,
                                      macOS: AboutInfo.macOSVersion, chip: AboutInfo.chip)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// 按下才連網；View 的 Task 跑在主執行緒，回來後直接更新狀態
    private func checkUpdate() {
        update = .checking
        Task { @MainActor in
            let outcome = await AboutInfo.fetchLatest()
            update = .done(outcome)
        }
    }
}
