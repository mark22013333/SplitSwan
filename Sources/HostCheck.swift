// 「某台公司主機連不上？」一鍵檢查的純邏輯：解析輸入、抽 IP、判斷網段涵蓋、組結果文字。
// 不碰 UI 與 Process，方便單獨測試；實際執行指令在 HostCheckRunner。
import Foundation

enum HostCheck {
    struct Target: Equatable {
        var host: String
        var port: Int?
    }

    /// 接受 `host`、`host:port`、URL（`https://user@host:8443/path?q`）。
    /// host 只接受半形英數、點、連字號，避免換行或特殊字元混進指令參數與設定檔
    static func parseTarget(_ input: String) -> Target? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<i]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        var port: Int?
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        if parts.count == 2 {
            let p = parts[1]
            guard !p.isEmpty, p.count <= 5, p.allSatisfy({ ("0"..."9").contains($0) }),
                  let n = Int(p), (1...65535).contains(n) else { return nil }
            port = n
        }
        let host = String(parts[0]).lowercased()
        guard isValidHost(host) else { return nil }
        return Target(host: host, port: port)
    }

    static func isValidHost(_ h: String) -> Bool {
        guard !h.isEmpty, h.count <= 253, !h.hasPrefix("-"), !h.hasPrefix("."), !h.hasSuffix("-") else { return false }
        let ok = h.unicodeScalars.allSatisfy { c in
            ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "." || c == "-"
        }
        guard ok else { return false }
        // 全是數字和點的話，必須是合法 IPv4（避免 1.2.3 這種被當成網域）
        if h.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }) { return DiagnosticReport.ipv4(h) != nil }
        return true
    }

    static func isIPv4(_ s: String) -> Bool { DiagnosticReport.ipv4(s) != nil }

    /// `dscacheutil -q host -a name X` 的輸出 → IPv4 清單（去重、保留順序，略過 IPv6）
    static func ipv4s(fromDscacheutil output: String) -> [String] {
        var out: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("ip_address:") else { continue }
            let v = t.dropFirst("ip_address:".count).trimmingCharacters(in: .whitespaces)
            if isIPv4(v), !out.contains(v) { out.append(v) }
        }
        return out
    }

    /// cidr（a.b.c.d/n）是否涵蓋 ip；格式錯誤或 /0 一律回 false
    static func contains(cidr: String, ip: String) -> Bool {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let mask = Int(parts[1]), (1...32).contains(mask),
              let net = DiagnosticReport.ipv4(String(parts[0])), let v = DiagnosticReport.ipv4(ip) else { return false }
        let m: UInt32 = ~UInt32(0) << UInt32(32 - mask)
        return net & m == v & m
    }

    /// 現有網段（逗號或換行分隔）中第一個涵蓋 ip 的
    static func coveringSubnet(ip: String, in remoteTS: String) -> String? {
        remoteTS.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { contains(cidr: $0, ip: ip) }
    }

    /// RFC 1918 私有位址
    static func isPrivate(_ ip: String) -> Bool {
        ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].contains { contains(cidr: $0, ip: ip) }
    }

    /// 還沒被涵蓋的 IP → 要新增的 `IP/32`（「檢查並加入」直接加入這些；「只檢查」則列為待加入）
    static func proposal(ips: [String], existing remoteTS: String) -> [String] {
        ips.filter { coveringSubnet(ip: $0, in: remoteTS) == nil }.map { "\($0)/32" }
    }

    /// 網段清單（`IP/32`）中屬於公網的 IP（去掉前綴長度）；只看單一主機 /32，其他格式略過
    static func publicIPs(in subnets: [String]) -> [String] {
        subnets.compactMap { s -> String? in
            let p = s.trimmingCharacters(in: .whitespaces).split(separator: "/")
            guard p.count == 2, p[1] == "32", isIPv4(String(p[0])), !isPrivate(String(p[0])) else { return nil }
            return String(p[0])
        }
    }

    /// 加入（或準備加入）公網位址時的警告；沒有公網位址回 nil
    static func publicWarning(_ publicIPs: [String]) -> String? {
        guard !publicIPs.isEmpty else { return nil }
        return "\(publicIPs.joined(separator: ", ")) 是公網位址，可能是 DNS 沒有走公司端。加入後，連到這個位址的流量都會改走 VPN。"
    }

    /// 結果最上方的「已加入」摘要；沒有加入任何網段回 nil
    static func addedSummary(_ added: [String]) -> String? {
        added.isEmpty ? nil : "已加入：\(added.joined(separator: ", "))"
    }

    /// 「只檢查」發現有 IP 不在通道網段內時的說明；connected 決定按鈕名稱
    static func pendingText(_ pending: [String], connected: Bool) -> String? {
        guard !pending.isEmpty else { return nil }
        let action = connected ? "加入並重新連線" : "加入網段"
        return "\(pending.joined(separator: ", ")) 不在通道網段內，流量不會走 VPN。按「\(action)」加入（不會改動其他設定）。"
    }

    /// 每個 IP 的驗證結果
    struct IPResult: Equatable {
        var ip: String
        var interface: String?        // route -n get 的 interface
        var viaTunnel: Bool
        var portOK: Bool?             // 沒指定連接埠時為 nil
    }

    /// `swanctl --list-sas`（輔助程式 sas）輸出中，CHILD_SA 的遠端網段（逗號分隔）；沒有就 nil。
    /// CHILD_SA 那行是「    remote 10.0.0.0/24 10.0.1.0/24」；IKE 那行是「  remote '<身分>' @ <位址>[埠]」，第二欄有引號，不算
    static func activeRemoteTS(fromListSas output: String) -> String? {
        var nets: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard p.count >= 2, p[0] == "remote" else { continue }
            for tok in p.dropFirst() {
                // 可能帶協定／埠：10.0.0.0/24[tcp/22]
                let cidr = String(tok.split(separator: "[", maxSplits: 1).first ?? "")
                let parts = cidr.split(separator: "/")
                guard parts.count == 2, isIPv4(String(parts[0])), let m = Int(parts[1]), (0...32).contains(m) else { continue }
                if !nets.contains(cidr) { nets.append(cidr) }
            }
        }
        return nets.isEmpty ? nil : nets.joined(separator: ",")
    }

    /// 路由檢查結果該給哪種建議
    enum RouteAdvice: Equatable {
        /// 全部走 VPN
        case viaTunnel
        /// 沒走 VPN 的 IP 都已在目前通道的網段內，路由卻沒走 utun：strongSwan 狀態異常，重新連線（新版輔助程式會自動重啟 strongSwan）
        case staleRoute
        /// 網段尚未生效（不在目前通道的網段內，或讀不到通道網段）：確認已儲存並重新連線
        case notApplied
    }

    /// activeTS：目前 CHILD_SA 的遠端網段（activeRemoteTS 的結果）；讀不到時傳 nil，一律當成尚未生效
    static func routeAdvice(results: [IPResult], activeTS: String?) -> RouteAdvice {
        let off = results.filter { !$0.viaTunnel }
        if off.isEmpty { return .viaTunnel }
        guard let ts = activeTS, off.allSatisfy({ coveringSubnet(ip: $0.ip, in: ts) != nil }) else { return .notApplied }
        return .staleRoute
    }

    /// staleRoute（網段已生效但路由沒走 VPN）時該給使用者哪一種下一步
    enum StaleRouteHint: Equatable {
        /// 已安裝的系統元件跟 App 內附的不同：舊版沒有自動修復，先到「環境檢查」更新
        case updateHelper
        /// 系統元件是新版：按「重新連線」，連上後輔助程式會檢查路由、必要時重啟 strongSwan
        case reconnect
        /// 已經按過重新連線、路由仍沒走 VPN：自動修復沒有成功，請產生診斷報告（不再提供同一個按鈕）
        case report
    }

    /// helperOutdated：系統元件需要安裝或更新（EnvChecker 的比對結果）；retried：這次結果是按「重新連線」之後檢查的
    static func staleRouteHint(helperOutdated: Bool, retried: Bool) -> StaleRouteHint {
        if helperOutdated { return .updateHelper }
        return retried ? .report : .reconnect
    }

    /// staleRoute 時顯示的說明
    static func staleRouteText(_ hint: StaleRouteHint) -> String {
        let head = "網段已在通道內，但目前路由沒走 VPN，可能是 VPN 服務（strongSwan）狀態異常。"
        switch hint {
        case .updateHelper:
            return head + "目前安裝的系統元件不是最新版：請先到「環境檢查」按系統元件的「更新」，再回來按「再檢查一次」。"
        case .reconnect:
            return head + "按「重新連線」，連上後會檢查路由，必要時自動重啟 VPN 服務再連一次。"
        case .report:
            return "已重新連線，但路由仍沒走 VPN，自動修復沒有成功。請到「環境檢查」產生診斷報告，交給管理者。"
        }
    }

    /// 給管理員的結果文字（可直接貼上）
    static func report(target: Target, results: [IPResult], added: [String], vpnIP: String?, pending: [String] = []) -> String {
        var lines = ["主機：\(target.host)" + (target.port.map { "，連接埠 \($0)" } ?? "")]
        if let v = vpnIP { lines.append("我的 VPN 位址：\(v)") }
        if !added.isEmpty { lines.append("本次新增網段：\(added.joined(separator: ", "))") }
        if !pending.isEmpty { lines.append("不在通道網段內：\(pending.joined(separator: ", "))") }
        for r in results {
            var s = "\(r.ip)：路由 \(r.interface ?? "查不到")（\(r.viaTunnel ? "有走 VPN" : "沒走 VPN")）"
            if let ok = r.portOK, let p = target.port { s += "，TCP \(p) \(ok ? "可連線" : "連不上")" }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }
}
