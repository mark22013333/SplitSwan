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

    /// 還沒被涵蓋的 IP → 要新增的 `IP/32`
    static func proposal(ips: [String], existing remoteTS: String) -> [String] {
        ips.filter { coveringSubnet(ip: $0, in: remoteTS) == nil }.map { "\($0)/32" }
    }

    /// 每個 IP 的驗證結果
    struct IPResult: Equatable {
        var ip: String
        var interface: String?        // route -n get 的 interface
        var viaTunnel: Bool
        var portOK: Bool?             // 沒指定連接埠時為 nil
    }

    /// 給管理員的結果文字（可直接貼上）
    static func report(target: Target, results: [IPResult], added: [String], vpnIP: String?) -> String {
        var lines = ["主機：\(target.host)" + (target.port.map { "，連接埠 \($0)" } ?? "")]
        if let v = vpnIP { lines.append("我的 VPN 位址：\(v)") }
        if !added.isEmpty { lines.append("本次新增網段：\(added.joined(separator: ", "))") }
        for r in results {
            var s = "\(r.ip)：路由 \(r.interface ?? "查不到")（\(r.viaTunnel ? "有走 VPN" : "沒走 VPN")）"
            if let ok = r.portOK, let p = target.port { s += "，TCP \(p) \(ok ? "可連線" : "連不上")" }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }
}
