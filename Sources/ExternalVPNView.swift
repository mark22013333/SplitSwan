import SwiftUI

struct ExternalVPNTab: View {
    @ObservedObject var model: ExternalVPNController
    var helperReady: Bool
    var installing: Bool
    var fortiBusy: Bool
    var install: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("VPN 自動分流", systemImage: "arrow.triangle.branch")
                    .font(.title2.weight(.semibold))
                Text("使用原本的 VPN 程式登入，VPN 系統走通道，一般 IPv4 上網走原本網路。")
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(statusMessage, systemImage: statusIcon)
                            .foregroundStyle(model.status.phase == .failed || model.status.phase == .recoveryRequired ? Color.orange : Color.primary)
                            .textSelection(.enabled)
                        if let interface = model.status.interface {
                            Text("一般上網：\(interface)" + (model.status.tunnel.map { "　VPN：\($0)" } ?? ""))
                                .font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                        if model.status.phase == .active { Text("已加入 \(model.status.routeCount) 筆分流路由").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                Picker("DNS 處理", selection: $model.dnsMode) {
                    Text("依網域分流 DNS").tag(ExternalVPNDNSMode.splitDomains)
                    Text("沿用 VPN DNS").tag(ExternalVPNDNSMode.preserveVPN)
                }.pickerStyle(.menu).disabled(!model.canPrepare || model.busy)
                if model.dnsMode == .preserveVPN {
                    Text("沿用 VPN 連線後的 DNS，不另外修改。一般網站也會依這組 DNS 設定解析。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.status.companyCapability == 1 && model.status.dnsMode == .preserveVPN {
                    Text("分流啟用後，可在「連線」頁連接公司 VPN。公司連線沿用目前 DNS；公司專屬網域名稱尚未驗證。停止分流或結束 App 會先中斷公司 VPN。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.canRetry {
                    Text("已保留連線前的上網快照；可調整進階範圍後按「重新嘗試分流」，不必先中斷 VPN。")
                        .font(.callout)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. VPN 尚未連線時，先按「開始等待 VPN 並自動分流」。")
                        Text("2. 使用原本的 VPN 程式完成登入，SplitSwan 會自動偵測並嘗試分流。")
                        Text("3. 使用完畢按停止並復原，再由原本程式中斷 VPN。")
                    }.font(.callout)
                }
                HStack {
                    Button(model.canRetry ? "重新嘗試分流" : "開始等待 VPN 並自動分流") { Task { await model.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!helperReady || installing || fortiBusy || model.busy || !model.canPrepare)
                    Button(model.status.companyState == nil ? "停止並復原" : "停止公司 VPN 並復原分流") { Task { await model.stop() } }
                        .disabled(model.busy || (!model.isManaging && model.status.phase != .failed))
                    if model.busy { ProgressView().controlSize(.small) }
                }
                if !helperReady {
                    Button(installing ? "正在安裝系統元件…" : "安裝／更新分流系統元件…", action: install).disabled(installing)
                    Text("自動分流不需要 strongSwan 或 FortiGate 帳密。安裝系統元件時會要求 macOS 管理員授權。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if fortiBusy && !model.isManaging { Text("請先停止 SplitSwan 的 FortiGate 連線，再使用自動分流。").font(.callout).foregroundStyle(.orange) }
                GroupBox("進階保留範圍") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("另外保留走 VPN 的 IPv4 網段")
                        TextField("例如 203.0.113.0/24，多筆以空白或逗號分隔", text: $model.protectedNetworks)
                            .textFieldStyle(.roundedBorder)
                        Text("私人網段及 VPN 已推送的細部路由會保留。VPN 內使用公用 IP 的服務，若只有全通道路由，仍需在此補上網段。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("指定走原本網路的 IPv4 位址")
                        TextField("例如 203.0.113.8，多筆以空白或逗號分隔", text: $model.directIPv4)
                            .textFieldStyle(.roundedBorder)
                        Text("每筆僅指定一個 IP，不改動其他保留範圍。位址變動時需手動更新；不可與 DNS 或公司通道網段重疊。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("保留使用 VPN DNS 的網域")
                        TextField("例如 internal.example.com，多筆以空白或逗號分隔", text: $model.dnsDomains)
                            .textFieldStyle(.roundedBorder).disabled(model.dnsMode == .preserveVPN)
                        Text(model.dnsMode == .preserveVPN ? "此模式不使用 DNS 網域欄位，原有內容會保留供切回依網域分流時使用。" : "留空時採用可辨識的 VPN 內部 DNS 網域。若 VPN 沒提供網域，會停止並提示填寫，避免把內部名稱送往外部 DNS。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }.disabled(!model.canPrepare || model.busy)
                Text("目前支援 IPv4。偵測到 VPN 接管 IPv6、無法安全辨識 DNS，或路由被 VPN 保護時，會停止並嘗試撤回本次變更。這項功能不會解除 VPN 自己的網路限制。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private var statusMessage: String {
        guard model.status.phase == .active else { return model.status.message }
        return model.status.dnsMode == .preserveVPN ? "IPv4 自動分流已啟用，沿用 VPN DNS" : "IPv4 與 DNS 自動分流已啟用"
    }

    private var statusIcon: String {
        switch model.status.phase {
        case .active: return "checkmark.circle.fill"
        case .waiting: return "clock"
        case .failed, .recoveryRequired: return "exclamationmark.triangle.fill"
        default: return "network"
        }
    }
}

@MainActor
final class ExternalVPNMenu: NSObject {
    struct Availability {
        var helperReady: Bool
        var installing: Bool
        var companyBusy: Bool
    }

    let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let startItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let stopItem = NSMenuItem(title: "停止自動分流並復原", action: nil, keyEquivalent: "")
    let settingsItem = NSMenuItem(title: "自動分流設定…", action: nil, keyEquivalent: "")
    private let model: ExternalVPNController
    private let availability: () -> Availability
    private let openSettings: () -> Void

    init(model: ExternalVPNController, availability: @escaping () -> Availability, openSettings: @escaping () -> Void) {
        self.model = model
        self.availability = availability
        self.openSettings = openSettings
        super.init()
        startItem.action = #selector(start)
        stopItem.action = #selector(stop)
        settingsItem.action = #selector(showSettings)
        for item in [startItem, stopItem, settingsItem] { item.target = self }
        render()
    }

    func append(to menu: NSMenu) {
        for item in [statusItem, startItem, stopItem, settingsItem] { menu.addItem(item) }
    }

    func render() {
        let state: String
        switch model.status.phase {
        case .idle: state = "未啟用"
        case .waiting: state = "等待 VPN 連線"
        case .applying: state = "套用中…"
        case .active: state = "已啟用"
        case .restoring: state = "復原中…"
        case .failed: state = "未完成，請查看設定"
        case .recoveryRequired: state = "需要復原，請查看設定"
        }
        statusItem.title = "VPN 自動分流 · " + state
        statusItem.isEnabled = false
        startItem.title = model.canRetry ? "重新嘗試自動分流" : "開始等待 VPN 並自動分流"
        startItem.isEnabled = canStart
        stopItem.title = model.status.companyState == nil ? "停止自動分流並復原" : "停止公司 VPN 與自動分流並復原"
        stopItem.isEnabled = canStop
        settingsItem.isEnabled = true
    }

    private var canStart: Bool {
        let current = availability()
        return current.helperReady && !current.installing && !current.companyBusy && !model.busy && model.canPrepare
    }

    private var canStop: Bool {
        !model.busy && (model.isManaging || model.status.phase == .failed)
    }

    @objc private func start() {
        guard canStart else { return }
        Task {
            guard canStart else { return }
            await model.start()
        }
    }

    @objc private func stop() {
        guard canStop else { return }
        Task {
            guard canStop else { return }
            await model.stop()
        }
    }

    @objc private func showSettings() { openSettings() }
}
