// 設定頁「某台公司主機連不上？」一鍵檢查：
// 「檢查並加入」查 IP → 不在網段內的直接加入並重連 → 驗證路由與連接埠；
// 「只檢查」查 IP 並驗證，不改設定，有 IP 不在網段內時在結果中提供「加入並重新連線」
import AppKit
import SwiftUI

struct HostCheckPanel: View {
    @ObservedObject var vpn: VPNController
    let savedTS: () -> String              // 已儲存的通道網段
    let isDirty: () -> Bool                // 表單是否有未儲存的修改
    let apply: ([String]) throws -> Void   // 加入網段並存檔
    let helperOutdated: () -> Bool         // 系統元件需要安裝或更新（EnvChecker 的比對結果）
    let openEnvironment: () -> Void        // 切到「環境檢查」頁（更新系統元件、產生診斷報告）

    enum Phase {
        case idle
        case working(String)
        /// 目前沒有連線：added 是剛加入的網段，pending 是「只檢查」發現還不在網段內的
        case needConnect(target: HostCheck.Target, ips: [String], added: [String], pending: [String])
        case done(target: HostCheck.Target, results: [HostCheck.IPResult], added: [String], pending: [String],
                  advice: HostCheck.RouteAdvice, retried: Bool)
        case failed(String)
    }

    @State private var input = ""
    @State private var phase: Phase = .idle

    private var isWorking: Bool { if case .working = phase { return true }; return false }
    private var inputEmpty: Bool { input.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("某台公司主機連不上？").font(.callout.weight(.medium))
            HStack(spacing: 8) {
                TextField("", text: $input, prompt: Text("主機網域或網址，例：intranet.example.com:8443"))
                    .onSubmit { start(addMissing: true) }   // Enter 等同「檢查並加入」
                Button("檢查並加入") { start(addMissing: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputEmpty || isWorking)
                Button("只檢查") { start(addMissing: false) }
                    .disabled(inputEmpty || isWorking)
            }
            Text("「檢查並加入」會查出主機的 IP，不在通道網段內的直接加入並重新連線（目前連線會中斷約數秒），再檢查是否走 VPN；「只檢查」不改設定。有填連接埠會一併測試能否連線。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text).font(.callout) }
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case let .needConnect(target, ips, added, pending):
            VStack(alignment: .leading, spacing: 8) {
                addedHeader(added)
                if let text = HostCheck.pendingText(pending, connected: false) {
                    infoLabel(text)
                    publicWarning(pending)
                } else {
                    infoLabel(added.isEmpty ? "這台主機已在通道網段內。目前沒有連線，連線後即可驗證。"
                                            : "目前沒有連線，連線後新網段才會生效。")
                }
                HStack(spacing: 10) {
                    if !pending.isEmpty {
                        Button("加入網段") { addAndApply(target: target, ips: ips, add: pending) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("連線並驗證") { connectAndVerify(target: target, ips: ips, added: added, pending: pending) }
                }
            }
        case let .done(target, results, added, pending, advice, retried):
            resultView(target: target, results: results, added: added, pending: pending, advice: advice, retried: retried)
        }
    }

    /// 結果最上方的「已加入：…」，加入的有公網位址時接著顯示橘色警告
    @ViewBuilder private func addedHeader(_ added: [String]) -> some View {
        if let summary = HostCheck.addedSummary(added) {
            Label(summary, systemImage: "plus.circle.fill")
                .foregroundStyle(.green)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            publicWarning(added)
        }
    }

    @ViewBuilder private func publicWarning(_ subnets: [String]) -> some View {
        if let text = HostCheck.publicWarning(HostCheck.publicIPs(in: subnets)) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoLabel(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    private func resultView(target: HostCheck.Target, results: [HostCheck.IPResult], added: [String], pending: [String],
                            advice: HostCheck.RouteAdvice, retried: Bool) -> some View {
        let hint = HostCheck.staleRouteHint(helperOutdated: helperOutdated(), retried: retried)
        let portOK = results.allSatisfy { $0.portOK ?? true }
        let report = HostCheck.report(target: target, results: results, added: added, vpnIP: vpnIP, pending: pending)
        return VStack(alignment: .leading, spacing: 6) {
            addedHeader(added)
            ForEach(results, id: \.ip) { r in
                row(r.viaTunnel, "\(r.ip) 路由：\(r.interface ?? "查不到")（\(r.viaTunnel ? "有走 VPN" : "沒走 VPN")）")
                if let ok = r.portOK, let p = target.port {
                    row(ok, "\(r.ip) 連接埠 \(p)：\(ok ? "可連線" : "連不上")")
                }
            }
            Group {
                if let text = HostCheck.pendingText(pending, connected: vpn.state.isConnected) {
                    // 「只檢查」：有 IP 不在網段內，先讓使用者決定要不要加入
                    Text(text)
                } else if advice == .staleRoute {
                    Text(HostCheck.staleRouteText(hint))
                } else if advice == .notApplied {
                    Text("還沒走 VPN：確認網段已儲存且已重新連線；若剛重連，稍等幾秒再按「再檢查一次」。")
                } else if !portOK {
                    Text("已走 VPN 但連不上，可能是公司端沒有開放。請按「複製結果」交給管理者。")
                } else if target.port == nil {
                    Text("已走 VPN。若仍連不上，可填上連接埠（例：主機:443）再檢查一次。")
                } else {
                    Text("已走 VPN，連接埠也能連線。")
                }
            }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !pending.isEmpty { publicWarning(pending) }
            HStack(spacing: 10) {
                if !pending.isEmpty {
                    Button(vpn.state.isConnected ? "加入並重新連線" : "加入網段") {
                        addAndApply(target: target, ips: results.map(\.ip), add: pending)
                    }
                    .buttonStyle(.borderedProminent)
                } else if advice == .staleRoute {
                    switch hint {
                    case .reconnect:
                        Button("重新連線") { reconnectAndVerify(target: target, ips: results.map(\.ip), added: added) }
                            .buttonStyle(.borderedProminent)
                    case .updateHelper:
                        Button("前往環境檢查") { openEnvironment() }.buttonStyle(.borderedProminent)
                    case .report:
                        Button("前往產生診斷報告") { openEnvironment() }.buttonStyle(.borderedProminent)
                    }
                }
                Button("複製結果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                // 再檢查一次不改設定，避免使用者只是想重驗卻又觸發重連
                Button("再檢查一次") { start(addMissing: false) }
            }
        }
    }

    private func row(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? .green : .red)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
    }

    private var vpnIP: String? {
        if case let .connected(_, ip) = vpn.state { return ip }
        return nil
    }

    // MARK: 流程

    /// addMissing：true＝「檢查並加入」（不在網段內的直接加入），false＝「只檢查」（不改設定）
    private func start(addMissing: Bool) {
        guard !isWorking else { return }
        guard let target = HostCheck.parseTarget(input) else {
            phase = .failed("格式不正確：請輸入主機網域、IP、主機:連接埠或網址"); return
        }
        phase = .working("查詢 \(target.host) 的 IP…")
        Task {
            let ips = await HostCheckRunner.resolve(target.host)
            guard !ips.isEmpty else {
                phase = .failed("查不到 \(target.host) 的 IPv4 位址。若這是公司內部網域，可能要先連上 VPN，或請管理者提供 IP。")
                return
            }
            let add = HostCheck.proposal(ips: ips, existing: savedTS())
            if addMissing && !add.isEmpty {
                addAndApply(target: target, ips: ips, add: add)
                return
            }
            // 全部已在網段內（或只檢查）：不改設定，直接驗證；沒在網段內的列為待加入
            if vpn.state.isConnected { await verify(target: target, ips: ips, added: [], pending: add) }
            else { phase = .needConnect(target: target, ips: ips, added: [], pending: add) }
        }
    }

    private func addAndApply(target: HostCheck.Target, ips: [String], add: [String]) {
        // 一鍵加入會整份存檔，表單有改到一半的內容就先擋下
        guard !isDirty() else {
            phase = .failed("設定表單有還沒儲存的修改，請先按「儲存」或「還原」再試一次")
            return
        }
        do { try apply(add) } catch {
            phase = .failed("無法加入網段：\(error.localizedDescription)"); return
        }
        guard vpn.state.isConnected else {
            phase = .needConnect(target: target, ips: ips, added: add, pending: []); return
        }
        phase = .working("已加入 \(add.joined(separator: ", "))，重新連線中…")
        Task {
            guard vpn.reconnect(reason: "套用新網段") else {
                phase = .failed("已加入 \(add.joined(separator: ", "))，但目前有連線動作在進行，請稍後手動斷線再連線")
                return
            }
            await waitConnected()
            await verify(target: target, ips: ips, added: add)
        }
    }

    private func connectAndVerify(target: HostCheck.Target, ips: [String], added: [String], pending: [String]) {
        phase = .working("連線中…")
        vpn.connect("auto")
        Task {
            await waitConnected()
            await verify(target: target, ips: ips, added: added, pending: pending)
        }
    }

    /// 先等協調器開始動作，再等到連線完成，最多 130 秒：要大於輔助程式 up 單台最壞耗時（含路由修復），
    /// 否則修復還在進行就會誤報「沒有連上」
    private func waitConnected() async {
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<128 {
            if vpn.state.isConnected && !vpn.busy { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func verify(target: HostCheck.Target, ips: [String], added: [String], pending: [String] = [],
                        retried: Bool = false) async {
        guard vpn.state.isConnected else {
            phase = .failed("130 秒內沒有連上 VPN，請看主畫面的連線紀錄"); return
        }
        phase = .working("檢查路由" + (target.port.map { "與連接埠 \($0)" } ?? "") + "…")
        let results = await HostCheckRunner.verify(ips: ips, port: target.port)
        // 有 IP 沒走 VPN 時，查目前通道實際的網段，區分「網段尚未生效」與「網段已生效但路由錯」
        var activeTS: String?
        if !results.allSatisfy(\.viaTunnel) { activeTS = await HostCheckRunner.activeRemoteTS() }
        phase = .done(target: target, results: results, added: added, pending: pending,
                      advice: HostCheck.routeAdvice(results: results, activeTS: activeTS), retried: retried)
    }

    /// 網段已在通道內但路由沒走 VPN：重新連線（新版輔助程式連上後會檢查路由，必要時重啟 strongSwan），再驗證一次
    private func reconnectAndVerify(target: HostCheck.Target, ips: [String], added: [String]) {
        phase = .working("重新連線中…")
        Task {
            guard vpn.reconnect(reason: "主機檢查：路由沒走 VPN") else {
                phase = .failed("目前有連線動作在進行或沒有連線，請稍後再試，或手動斷線再連線")
                return
            }
            await waitConnected()
            await verify(target: target, ips: ips, added: added, retried: true)
        }
    }
}
