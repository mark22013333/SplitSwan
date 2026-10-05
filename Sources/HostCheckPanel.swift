// 設定頁「某台公司主機連不上？」一鍵檢查：查 IP → 使用者確認 → 加入網段並重連 → 驗證路由與連接埠
import AppKit
import SwiftUI

struct HostCheckPanel: View {
    @ObservedObject var vpn: VPNController
    let savedTS: () -> String              // 已儲存的通道網段
    let isDirty: () -> Bool                // 表單是否有未儲存的修改
    let apply: ([String]) throws -> Void   // 加入網段並存檔

    enum Phase {
        case idle
        case working(String)
        case confirm(target: HostCheck.Target, ips: [String], add: [String])
        case needConnect(target: HostCheck.Target, ips: [String], added: [String])
        case done(target: HostCheck.Target, results: [HostCheck.IPResult], added: [String])
        case failed(String)
    }

    @State private var input = ""
    @State private var phase: Phase = .idle

    private var isWorking: Bool { if case .working = phase { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("某台公司主機連不上？").font(.callout.weight(.medium))
            HStack(spacing: 8) {
                TextField("", text: $input, prompt: Text("主機網域或網址，例：intranet.example.com:8443"))
                    .onSubmit { start() }
                Button("檢查") { start() }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
            Text("會查出主機的 IP，確認後自動加入通道網段、重新連線，並檢查是否走 VPN；有填連接埠會一併測試能否連線。")
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
        case let .confirm(target, ips, add):
            confirmView(target: target, ips: ips, add: add)
        case let .needConnect(target, ips, added):
            VStack(alignment: .leading, spacing: 8) {
                Label(added.isEmpty ? "這台主機已在通道網段內。目前沒有連線，連線後即可驗證。"
                                    : "已加入 \(added.joined(separator: ", "))。目前沒有連線，連線後新網段才會生效。",
                      systemImage: "info.circle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("連線並驗證") { connectAndVerify(target: target, ips: ips, added: added) }
            }
        case let .done(target, results, added):
            resultView(target: target, results: results, added: added)
        }
    }

    private func confirmView(target: HostCheck.Target, ips: [String], add: [String]) -> some View {
        let publicIPs = ips.filter { !HostCheck.isPrivate($0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(target.host) 解析到：").font(.callout)
            ForEach(ips, id: \.self) { ip in
                let cover = HostCheck.coveringSubnet(ip: ip, in: savedTS())
                Text("• \(ip)　" + (cover.map { "已在網段 \($0) 內" } ?? "將新增 \(ip)/32"))
                    .font(.system(.callout, design: .monospaced))
            }
            if !publicIPs.isEmpty {
                Label("\(publicIPs.joined(separator: ", ")) 是公網位址，可能是 DNS 沒有走公司端。加入後，連到這個位址的流量都會改走 VPN。",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(vpn.state.isConnected ? "按下後會儲存設定並重新連線，目前的 VPN 連線會中斷約數秒。"
                                       : "按下後會儲存設定；目前沒有連線，連線後新網段才會生效。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(vpn.state.isConnected ? "加入並重新連線" : "加入網段") { addAndApply(target: target, ips: ips, add: add) }
                    .buttonStyle(.borderedProminent)
                Button("取消") { phase = .idle }
            }
        }
    }

    private func resultView(target: HostCheck.Target, results: [HostCheck.IPResult], added: [String]) -> some View {
        let routeOK = results.allSatisfy(\.viaTunnel)
        let portOK = results.allSatisfy { $0.portOK ?? true }
        let report = HostCheck.report(target: target, results: results, added: added, vpnIP: vpnIP)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(results, id: \.ip) { r in
                row(r.viaTunnel, "\(r.ip) 路由：\(r.interface ?? "查不到")（\(r.viaTunnel ? "有走 VPN" : "沒走 VPN")）")
                if let ok = r.portOK, let p = target.port {
                    row(ok, "\(r.ip) 連接埠 \(p)：\(ok ? "可連線" : "連不上")")
                }
            }
            Group {
                if !routeOK {
                    Text("還沒走 VPN：確認網段已儲存且已重新連線；若剛重連，稍等幾秒再按一次「檢查」。")
                } else if !portOK {
                    Text("已走 VPN 但連不上，可能是公司端沒有開放。請按「複製結果」交給管理者。")
                } else if target.port == nil {
                    Text("已走 VPN。若仍連不上，可填上連接埠（例：主機:443）再檢查一次。")
                } else {
                    Text("已走 VPN，連接埠也能連線。")
                }
            }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("複製結果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                Button("再檢查一次") { start() }
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

    private func start() {
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
            if add.isEmpty {
                if vpn.state.isConnected { await verify(target: target, ips: ips, added: []) }
                else { phase = .needConnect(target: target, ips: ips, added: []) }
                return
            }
            phase = .confirm(target: target, ips: ips, add: add)
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
            phase = .needConnect(target: target, ips: ips, added: add); return
        }
        phase = .working("重新連線中…")
        Task {
            guard vpn.reconnect(reason: "套用新網段") else {
                phase = .failed("已加入網段，但目前有連線動作在進行，請稍後手動斷線再連線")
                return
            }
            await waitConnected()
            await verify(target: target, ips: ips, added: add)
        }
    }

    private func connectAndVerify(target: HostCheck.Target, ips: [String], added: [String]) {
        phase = .working("連線中…")
        vpn.connect("auto")
        Task {
            await waitConnected()
            await verify(target: target, ips: ips, added: added)
        }
    }

    /// 先等協調器開始動作，再等到連線完成，最多 60 秒
    private func waitConnected() async {
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<58 {
            if vpn.state.isConnected && !vpn.busy { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func verify(target: HostCheck.Target, ips: [String], added: [String]) async {
        guard vpn.state.isConnected else {
            phase = .failed("60 秒內沒有連上 VPN，請看主畫面的連線紀錄"); return
        }
        phase = .working("檢查路由" + (target.port.map { "與連接埠 \($0)" } ?? "") + "…")
        let results = await HostCheckRunner.verify(ips: ips, port: target.port)
        phase = .done(target: target, results: results, added: added)
    }
}
