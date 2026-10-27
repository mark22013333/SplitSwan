// 設定頁的版面：左側分類欄＋右側面板＋底部儲存列，以及各分類的面板。
// 面板只收 binding 與動作，不碰 VPNController／ConfigStore，測試可以離屏畫出來。
import SwiftUI

extension SettingsCategory {
    var tint: Color {
        switch self {
        case .connection: return .blue
        case .subnets: return .green
        case .profile, .general: return .gray
        case .appearance: return .purple
        case .plugins: return .orange
        }
    }
}

/// 系統設定風格的彩色圓角方塊圖示
struct SettingsIconTile: View {
    let category: SettingsCategory
    var size: CGFloat = 20
    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25).fill(category.tint.gradient))
    }
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory
    let dirty: Set<SettingsCategory>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.Group.allCases, id: \.self) { group in
                Text(group.title)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, group == .needsSave ? 2 : 14).padding(.bottom, 3)
                ForEach(SettingsCategory.allCases.filter { $0.group == group }) { row($0) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ c: SettingsCategory) -> some View {
        let selected = c == selection
        return Button { selection = c } label: {
            HStack(spacing: 8) {
                SettingsIconTile(category: c)
                Text(c.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                if dirty.contains(c) {
                    Circle().fill(selected ? Color.white : Color.accentColor)
                        .frame(width: 7, height: 7)
                        .help("這個分類有修改尚未儲存")
                        .accessibilityLabel("未儲存")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 側欄＋面板＋底部列。只有「寫入 VPN 設定」的分類有還原／儲存
struct SettingsSplitView<Panel: View>: View {
    @Binding var selection: SettingsCategory
    let dirty: Set<SettingsCategory>
    let message: (text: String, isError: Bool)?
    let revert: () -> Void
    let save: () -> Void
    @ViewBuilder var panel: Panel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection, dirty: dirty)
                .frame(width: 150)
                .background(Color.secondary.opacity(0.06))
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        panel
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(selection)   // 換分類時從頂端開始
                Divider()
                footer.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SettingsIconTile(category: selection, size: 26)
            Text(selection.title).font(.title3.weight(.semibold))
            Spacer()
            Text(selection.group == .needsSave ? "按「儲存」後寫入" : "立即生效")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError ? .orange : .green).font(.callout)
                    .lineLimit(2)
            } else if selection.group == .live {
                Text("變更會立即生效").font(.callout).foregroundStyle(.secondary)
            } else if let summary = SettingsLogic.unsavedSummary(dirty) {
                HStack(spacing: 6) {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    Text(summary).font(.callout).lineLimit(2)
                }
            } else {
                Text("沒有未儲存的修改").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selection.group == .needsSave {
                Button("還原", action: revert).disabled(dirty.isEmpty)
                Button("儲存", action: save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(dirty.isEmpty)
            }
        }
        .frame(minHeight: 28)
    }
}

// MARK: - 各分類的面板

struct ConnectionSettingsPanel: View {
    @Binding var draft: VPNSettings
    @Binding var password: String
    @Binding var psk: String
    let secretState: (psk: Bool, password: Bool)
    let canClearHistory: Bool
    let clearHistory: () -> Void

    var body: some View {
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
            Button("清除閘道連線紀錄", action: clearHistory).disabled(!canClearHistory)
            Text("自動輪替會先試最近連得上、連得快的閘道")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct SubnetsSettingsPanel<HostCheck: View>: View {
    @Binding var tsText: String
    @Binding var showHelp: Bool
    @ViewBuilder var hostCheck: HostCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("走 VPN 的目的地").font(.headline)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    chip("VPN", .accentColor)
                    Text("這 \(SettingsLogic.subnetCount(tsText)) 個網段")
                    Spacer(minLength: 8)
                    chip("原本網路", .secondary)
                    Text("其他全部").foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 7)
                Divider()
                TextEditor(text: $tsText)
                    .font(.system(size: 14, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
            Text("只有這些目的地會走 VPN，其他流量（Teams、Google Meet、一般上網）走原本的網路。**一行一個**；單一主機寫成 `IP/32`。**不要填 0.0.0.0/0**，全部流量走 VPN 會讓外網 DNS 失效。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SettingsCard {
            hostCheck
            Divider()
            DisclosureGroup("手動排查步驟（5 步）", isExpanded: $showHelp) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 查出主機的 IP：終端機執行 `dig +short 主機網域`")
                    Text("2. 在上面的通道網段加一行 `IP/32`，按「儲存」")
                    Text("3. 斷線後重新連線，新網段才會生效")
                    Text("4. 確認有走 VPN：終端機執行 `route -n get IP`，interface 應該是 utun 開頭")
                    Text("5. 還是不通，請把 IP 與使用的連接埠告訴管理者，確認公司端是否允許")
                }
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }
}

struct ProfileSettingsPanel: View {
    let presetText: String
    let canRestore: Bool
    let importPreset: () -> Void
    let exportConfig: () -> Void
    let restorePreset: () -> Void

    var body: some View {
        SettingsCard {
            row("加密的 .splitswan 或 company.env，套用前會先請你確認閘道") {
                Button("匯入設定檔…", action: importPreset)
            }
            Divider()
            row("目前的閘道、網段與 PSK，不含個人帳號密碼") {
                Button("匯出加密設定檔…", action: exportConfig)
            }
            Divider()
            row("把閘道與網段填回公司設定的值") {
                Button("從公司設定還原", action: restorePreset).disabled(!canRestore)
            }
        }
        Text(presetText)
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private func row<B: View>(_ detail: String, @ViewBuilder button: () -> B) -> some View {
        HStack(spacing: 10) {
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            button()
        }
    }
}

struct GeneralSettingsPanel: View {
    @Binding var launchAtLogin: Bool
    @Binding var notifyDrop: Bool
    let notifyDenied: Bool
    let launchAtLoginChanged: (Bool) -> Void
    let notifyDropChanged: () -> Void

    var body: some View {
        SettingsCard {
            Toggle("登入時自動啟動", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { _, on in launchAtLoginChanged(on) }
            Divider()
            Toggle("VPN 中斷時通知", isOn: $notifyDrop)
                .toggleStyle(.switch)
                .onChange(of: notifyDrop) { _, _ in notifyDropChanged() }
            if notifyDrop && notifyDenied {
                Text("macOS 未允許通知，請到「系統設定 → 通知」開啟")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
                            HStack(spacing: 10) {
                                ForEach(IconState.allCases, id: \.self) { st in
                                    if let img = MenuBarIcon.image(style: style, state: st, colored: colored, pointSize: 17) {
                                        // 可縮放：側欄旁的格子較窄時，「VPN 字樣」這類寬圖示等比例縮小而不是撐出格子
                                        Image(nsImage: img)
                                            .renderingMode(img.isTemplate ? .template : .original)
                                            .resizable().scaledToFit()
                                            .frame(maxWidth: img.size.width, maxHeight: img.size.height)
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

/// 設定頁的區塊：標題（可省略）＋圓角底
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
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
