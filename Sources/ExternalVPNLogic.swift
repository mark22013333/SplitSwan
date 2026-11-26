import Foundation

enum ExternalVPNError: LocalizedError {
    case invalid(String)
    case busy
    var errorDescription: String? { switch self { case .invalid(let text): return text; case .busy: return "另一個 VPN 操作正在執行" } }
}

struct ExternalVPNDetailedError: LocalizedError {
    let message: String
    let dnsDifferences: [String]
    var errorDescription: String? { message }
}

enum ExternalVPNRouteError: LocalizedError {
    case notAdded(String)
    var errorDescription: String? { switch self { case .notAdded(let text): return text } }
}

struct ExternalIPv4: Hashable, Comparable, Codable, CustomStringConvertible {
    let value: UInt32
    init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw ExternalVPNError.invalid("IPv4 位址格式不正確") }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let byte = UInt32(part), byte <= 255 else { throw ExternalVPNError.invalid("IPv4 位址格式不正確") }
            result = result << 8 | byte
        }
        value = result
    }
    init(value: UInt32) { self.value = value }
    var description: String { [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".") }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

struct ExternalIPv4Network: Hashable, Codable, CustomStringConvertible {
    let address: ExternalIPv4
    let prefix: Int
    init(_ text: String) throws {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let p = Int(parts[1]), (0...32).contains(p),
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw ExternalVPNError.invalid("網段格式須為 IPv4/CIDR")
        }
        self.init(address: try ExternalIPv4(String(parts[0])), prefix: p)
    }
    init(address: ExternalIPv4, prefix: Int) {
        self.prefix = prefix
        self.address = ExternalIPv4(value: address.value & (prefix == 0 ? 0 : UInt32.max << (32 - prefix)))
    }
    var description: String { "\(address)/\(prefix)" }
    func contains(_ ip: ExternalIPv4) -> Bool { Self(address: ip, prefix: prefix).address == address }
    func contains(_ network: Self) -> Bool { prefix <= network.prefix && contains(network.address) }
    var halves: [Self] {
        guard prefix < 32 else { return [self] }
        return [Self(address: address, prefix: prefix + 1),
                Self(address: ExternalIPv4(value: address.value | (1 << (31 - prefix))), prefix: prefix + 1)]
    }
    static func tableDestination(_ text: String, host: Bool) -> Self? {
        if text == "default" { return try? Self("0.0.0.0/0") }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(octets.count), parts.count <= 2 else { return nil }
        let expanded = (octets.map(String.init) + Array(repeating: "0", count: 4 - octets.count)).joined(separator: ".")
        let prefix = parts.count == 2 ? String(parts[1]) : String(host ? 32 : octets.count * 8)
        return try? Self(expanded + "/" + prefix)
    }
}

enum ExternalVPNDNSMode: String, Codable, CaseIterable {
    case splitDomains, preserveVPN
}

struct ExternalVPNProfile: Codable, Equatable {
    var protectedNetworks: [String] = []
    var dnsDomains: [String] = []
    var dnsMode: ExternalVPNDNSMode = .splitDomains
    var directIPv4: [String] = []

    func validated() throws -> Self {
        guard protectedNetworks.count <= 128, dnsDomains.count <= 32, directIPv4.count <= 32 else {
            throw ExternalVPNError.invalid("網段或 DNS 網域數量超過上限")
        }
        for text in protectedNetworks {
            let network = try ExternalIPv4Network(text)
            guard network.prefix >= 2 else { throw ExternalVPNError.invalid("保留 VPN 的網段須比 /1 更精確") }
        }
        guard dnsMode != .preserveVPN || dnsDomains.isEmpty else {
            throw ExternalVPNError.invalid("保留 VPN DNS 模式不接受 DNS 網域設定")
        }
        for domain in dnsDomains {
            guard domain.count <= 253, domain.contains("."), !domain.hasSuffix("."),
                  domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                      !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                      && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                  }) else { throw ExternalVPNError.invalid("DNS 網域格式不正確，請填完整網域，不含網址或萬用字元") }
        }
        let direct = try directIPv4.map(ExternalIPv4.init)
        let forbidden = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/3"].map { try! ExternalIPv4Network($0) }
        guard !direct.contains(where: { ip in forbidden.contains { $0.contains(ip) } }) else {
            throw ExternalVPNError.invalid("指定直連 IP 須為公用 IPv4 位址")
        }
        return Self(protectedNetworks: Array(Set(protectedNetworks)).sorted(), dnsDomains: Array(Set(dnsDomains.map { $0.lowercased() })).sorted(), dnsMode: dnsMode, directIPv4: Array(Set(direct.map(\.description))).sorted())
    }
}

extension ExternalVPNProfile {
    enum CodingKeys: String, CodingKey { case protectedNetworks, dnsDomains, dnsMode, directIPv4 }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(protectedNetworks: try values.decode([String].self, forKey: .protectedNetworks),
                  dnsDomains: try values.decode([String].self, forKey: .dnsDomains),
                  dnsMode: try values.decodeIfPresent(ExternalVPNDNSMode.self, forKey: .dnsMode) ?? .splitDomains,
                  directIPv4: try values.decodeIfPresent([String].self, forKey: .directIPv4) ?? [])
    }
}

enum ExternalRouteNextHop: String, Codable { case gateway, directInterface }

struct ExternalRoute: Codable, Equatable {
    let network: ExternalIPv4Network
    let gateway: String
    let interface: String
    let flags: String
    var nextHopKind: ExternalRouteNextHop?
    var kind: ExternalRouteNextHop { nextHopKind ?? (gateway.hasPrefix("link#") && !flags.contains("G") ? .directInterface : .gateway) }
    var isUsable: Bool { flags.contains("U") && !flags.contains("I") && !flags.contains("R") && !flags.contains("B") }
    func sameIdentity(as other: Self) -> Bool {
        network == other.network && gateway == other.gateway && interface == other.interface
            && kind == other.kind && isOwned == other.isOwned && flags.contains("I") == other.flags.contains("I")
    }
    var isTunnel: Bool { ExternalVPNPlanner.isTunnel(interface) }
    var isOwned: Bool { flags.contains("1") }
}

struct ExternalDNSEntry: Codable, Equatable {
    let key: String
    let interface: String?
    let value: Data
    var dictionary: [String: Any] { Self.dictionary(value) }
    var servers: [String] { dictionary["ServerAddresses"] as? [String] ?? [] }
    var label: String { "\(key)（\(interface ?? "未知介面")）" }
    var summary: String {
        let fields = dictionary.keys.sorted().map { "\($0)=\(Self.describe(dictionary[$0]))" }
        return fields.isEmpty ? "（無內容）" : fields.joined(separator: "；")
    }
    static func dictionary(_ data: Data) -> [String: Any] { (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:] }
    static func equalValues(_ lhs: Data?, _ rhs: Data?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard let left = try? PropertyListSerialization.propertyList(from: lhs, format: nil) as? NSDictionary,
              let right = try? PropertyListSerialization.propertyList(from: rhs, format: nil) as? NSDictionary else { return false }
        return left.isEqual(right)
    }
    static func describe(_ value: Any?) -> String {
        switch value {
        case nil: return "（無）"
        case let list as [Any]: return "[" + list.map { describe($0) }.joined(separator: ", ") + "]"
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let data as Data: return "<\(data.count) bytes>"
        case let some?: return "\(some)"
        }
    }
    // 只在語意不同時回傳；無法逐欄比對（例如 plist 解不開）時至少回一行，讓「有差異」不會被吞掉。
    static func fieldDifferences(from recorded: Data, to current: Data) -> [String] {
        guard !equalValues(recorded, current) else { return [] }
        let old = dictionary(recorded), new = dictionary(current)
        let lines = Set(old.keys).union(new.keys).sorted().compactMap { field -> String? in
            if let a = old[field] as? NSObject, let b = new[field] as? NSObject, a.isEqual(b) { return nil }
            return "\(field)：記錄時 \(describe(old[field])) → 目前 \(describe(new[field]))"
        }
        return lines.isEmpty ? ["內容：無法逐欄比對"] : lines
    }
}

struct ExternalNetworkSnapshot: Codable {
    var bootID: String
    var interface: String
    var address: String
    var gateway: String
    var localNetwork: ExternalIPv4Network
    var routes: [ExternalRoute]
    var dns: [ExternalDNSEntry]
    var ipv6TunnelDefault: Bool
    var interfaceIndex: UInt32?
    var bootSession: String? = nil
    var defaultDNSServers: [String] = []
    var defaultDNSDomains: [String] = []
}

enum ExternalVPNPhase: String, Codable {
    case idle, waiting, applying, active, restoring, recoveryRequired, failed
}

struct ExternalDNSChange: Codable {
    let key: String
    let before: Data
    let after: Data
}

struct ExternalDNSState: Codable {
    let entries: [ExternalDNSEntry]
    let defaultServers: [String]
    let defaultDomains: [String]

    init(_ snapshot: ExternalNetworkSnapshot) {
        entries = snapshot.dns
        defaultServers = snapshot.defaultDNSServers
        defaultDomains = snapshot.defaultDNSDomains
    }

    func matches(_ snapshot: ExternalNetworkSnapshot) -> Bool { Self(snapshot).differences(from: self).isEmpty }

    func differences(from recorded: Self) -> [String] {
        var lines = recorded.entries.filter { old in !entries.contains { $0.key == old.key } }.map { "消失 \($0.label)：\($0.summary)" }
        for entry in entries {
            guard let old = recorded.entries.first(where: { $0.key == entry.key }) else {
                lines.append("新增 \(entry.label)：\(entry.summary)")
                continue
            }
            if old.interface != entry.interface {
                lines.append("改變 \(entry.key) 的介面：記錄時 \(old.interface ?? "未知介面") → 目前 \(entry.interface ?? "未知介面")")
            }
            lines += ExternalDNSEntry.fieldDifferences(from: old.value, to: entry.value).map { "改變 \(entry.label) 的 \($0)" }
        }
        if defaultServers != recorded.defaultServers {
            lines.append("預設 DNS 伺服器：記錄時 \(ExternalDNSEntry.describe(recorded.defaultServers)) → 目前 \(ExternalDNSEntry.describe(defaultServers))")
        }
        if defaultDomains != recorded.defaultDomains {
            lines.append("預設 DNS 比對網域：記錄時 \(ExternalDNSEntry.describe(recorded.defaultDomains)) → 目前 \(ExternalDNSEntry.describe(defaultDomains))")
        }
        return lines
    }
}

// W（複製）路由隨連線出現與消失，不代表 VPN 設定在變，不列入。
struct ExternalTunnelFingerprint: Codable {
    let tunnel: String
    let routes: [ExternalRoute]
    let dns: ExternalDNSState

    init(tunnel: String, snapshot: ExternalNetworkSnapshot) {
        self.tunnel = tunnel
        routes = snapshot.routes.filter { $0.interface == tunnel && !$0.flags.contains("W") }.sorted {
            ($0.network.address, $0.network.prefix, $0.gateway, $0.flags) < ($1.network.address, $1.network.prefix, $1.gateway, $1.flags)
        }
        dns = ExternalDNSState(snapshot)
    }

    func same(as other: Self) -> Bool { tunnel == other.tunnel && routes == other.routes && dns.differences(from: other.dns).isEmpty }
}

struct ExternalSettlingObservation: Codable {
    static let required = 3
    let fingerprint: ExternalTunnelFingerprint
    let count: Int
}

struct ExternalDNSPlan {
    let changes: [ExternalDNSChange]
    let preserved: ExternalDNSState?
    var skippedEndpointDNS: [String] = []
}

// finding 是偵測到的環境事實（含介面與位址），steps 是使用者能自己做的調整。
// 以選填欄位走 status JSON，舊系統元件沒有它時 App 改用 display(for:) 的通用建議。
struct ExternalVPNAdvice: Codable, Equatable {
    var finding: String?
    var steps: [String]

    static func display(for failure: ExternalVPNFailure) -> ExternalVPNAdvice {
        if let advice = failure.advice { return advice }
        let log = "按「打開失敗紀錄資料夾」，把最新一份交給管理者確認"
        let stop = "按「停止並復原」撤回本次變更，再由原本的 VPN 程式中斷 VPN"
        switch failure.stage {
        case .preparing:
            return ExternalVPNAdvice(finding: nil, steps: ["確認 VPN 已中斷、網路連線正常後再按「開始等待 VPN 並自動分流」", "到「環境檢查」頁確認系統元件是最新版本", log])
        case .observing, .planning:
            return ExternalVPNAdvice(finding: nil, steps: [stop, "檢查「DNS」與「進階保留範圍」的設定是否符合這條 VPN", "重新按「開始等待 VPN 並自動分流」", log])
        case .applyingRoutes, .applyingDNS, .verifying:
            return ExternalVPNAdvice(finding: nil, steps: [stop, "到「環境檢查」頁確認系統元件是最新版本，再重新開始", log])
        case .restoring:
            return ExternalVPNAdvice(finding: nil, steps: ["再按一次「停止並復原」", "仍失敗時先由原本的 VPN 程式中斷 VPN，再按「停止並復原」", log])
        }
    }
}

// 使用者能靠調整環境或設定處理的失敗。錯誤訊息與建議在同一個 switch 定義，新增 case 時兩者不會漏掉其一。
enum ExternalVPNIssue: LocalizedError {
    struct DNSOwner: Equatable {
        let address: String
        let interfaces: [String]
    }

    case unattributedDefaultDNS([DNSOwner])
    case defaultDNSChanged(recorded: [String], current: [String])
    case unknownDNSChange([String])
    case baselineDNSOwnerUnknown
    case baselineDNSIPv6(String)
    case dnsOverlap(String)
    case baselineDNSCaptured(server: String, interface: String, network: String)
    case baselineDNSAllEndpoints([String])
    case noInternalDomains
    case ipv6Takeover
    case multipleTunnels([String])
    case protectedOverlap([String])
    case directOverlap([String])
    case foreignLocalRoutes([String])
    case vpnAlreadyConnected(tunnel: String?)
    case networkChanged
    case physicalInterfaceChanged
    case tunnelChanged
    case tunnelLost
    case noPhysicalExit
    case noPhysicalAddress
    case physicalOffline
    case noBaselineDNS
    case ignoredBaselineDNS(expected: [String], actual: [String])

    var errorDescription: String? { content.message }
    var advice: ExternalVPNAdvice { ExternalVPNAdvice(finding: content.finding, steps: content.steps) }

    private static let stopStep = "按「停止並復原」，再由原本的 VPN 程式中斷 VPN"
    private static let restartStep = "重新按「開始等待 VPN 並自動分流」"
    private static let logStep = "問題仍在時，按「打開失敗紀錄資料夾」，把最新一份交給管理者"

    private static func list(_ items: [String]) -> String { items.isEmpty ? "（無）" : items.joined(separator: "、") }

    private var content: (message: String, finding: String?, steps: [String]) {
        let stop = Self.stopStep, restart = Self.restartStep, log = Self.logStep
        switch self {
        case .unattributedDefaultDNS(let owners):
            let lines = owners.map { owner in
                owner.interfaces.isEmpty ? "預設 DNS \(owner.address) 找不到提供它的網路服務"
                    : "預設 DNS \(owner.address) 由 \(Self.list(owner.interfaces)) 提供"
            }
            return ("VPN 的預設 DNS 無法確定服務歸屬，未套用分流", lines.joined(separator: "；"),
                    ["暫時關閉該通道的 DNS 覆寫（例如 Tailscale 的 Use Tailscale DNS），再重新開始",
                     "或把「DNS 處理」改成「依網域分流 DNS」",
                     "或先\(stop)，在該通道已連線的狀態下再按「開始等待 VPN 並自動分流」",
                     log])
        case .defaultDNSChanged(let recorded, let current):
            return ("VPN 變更了無法對應服務的預設 DNS，未套用分流",
                    "預設 DNS：連線前 \(Self.list(recorded)) → 目前 \(Self.list(current))",
                    ["暫時關閉會接管系統預設 DNS 的其他通道或工具，再重新開始",
                     "或把「DNS 處理」改成「沿用 VPN DNS」", log])
        case .unknownDNSChange(let labels):
            return ("VPN 修改了無法辨識歸屬的 DNS，未套用分流；請保留診斷供管理者確認",
                    "連線後出現變動、且不屬於 VPN 通道的 DNS：\(Self.list(labels))",
                    ["先關閉其他會改 DNS 的通道或工具，只留這條 VPN 再重新開始", log])
        case .baselineDNSOwnerUnknown:
            return ("無法確定原本上網 DNS 的歸屬，未套用分流", nil,
                    ["確認一般上網的網卡只有一組 DNS，且 VPN 連線期間沒有人改動它",
                     "\(stop)，在 VPN 未連線時重新開始", log])
        case .baselineDNSIPv6(let server):
            return ("原本 DNS 含 IPv6 位址，此版本無法安全分流", "原本上網 DNS 含 IPv6 位址 \(server)",
                    ["到 macOS 網路設定，暫時把這張網卡的 DNS 改成只含 IPv4 位址", "\(stop)，再\(restart)"])
        case .dnsOverlap(let server):
            return ("原本與 VPN 的 DNS 位址重疊，無法安全分開查詢", "原本上網 DNS 與 VPN DNS 都使用 \(server)",
                    ["把原本網卡的 DNS 改成與 VPN DNS 不同的位址", "或把「DNS 處理」改成「沿用 VPN DNS」", "\(stop)，再\(restart)"])
        case .baselineDNSCaptured(let server, let interface, let network):
            return ("原本的 DNS \(server) 被 \(interface) 的 \(network) 路由接管，未套用分流",
                    "原本上網 DNS \(server) 的路由被 \(interface) 的 \(network) 接管",
                    ["請 VPN 管理者不要讓這條路由涵蓋原本的 DNS，或把原本網卡的 DNS 改成不在該網段的位址",
                     "或把「DNS 處理」改成「沿用 VPN DNS」", log])
        case .baselineDNSAllEndpoints(let servers):
            return ("原本的 DNS（\(servers.joined(separator: "、"))）全部被 VPN 通道端點佔用，未套用分流",
                    "原本上網 DNS 全是 VPN 通道端點：\(Self.list(servers))",
                    ["在 macOS 網路設定替原本的網卡加入一個不在 VPN 通道內的 DNS", "\(stop)，再\(restart)"])
        case .noInternalDomains:
            return ("VPN DNS 接管所有查詢，但未提供內部網域；請填入保留 VPN DNS 的網域後重試", "這條 VPN 的 DNS 沒有附帶內部網域",
                    ["在「保留使用 VPN DNS 的網域」欄位填入內部網域，再按「重新嘗試分流」",
                     "或把「DNS 處理」改成「沿用 VPN DNS」，一般網站也會改走 VPN 的 DNS"])
        case .ipv6Takeover:
            return ("偵測到 VPN 接管 IPv6；此版本僅支援 IPv4，未套用分流", "VPN 接管了 IPv6 預設路由",
                    ["到 VPN 程式關閉 IPv6 通道或「全部流量走 VPN」的選項", "\(stop)，再\(restart)"])
        case .multipleTunnels(let interfaces):
            return ("有多個 VPN 接管預設路由，無法安全自動判斷", "同時接管預設路由的通道：\(Self.list(interfaces))",
                    ["中斷其中不需要的 VPN，只留下要分流的那一條", "\(stop)，再\(restart)"])
        case .protectedOverlap(let networks):
            return ("保留 VPN 的網段與本機網路或既有實體路由重疊，未套用分流", "與本機網路重疊的保留網段：\(Self.list(networks))",
                    ["到「另外保留走 VPN 的 IPv4 網段」移除或縮小這些網段，再按「重新嘗試分流」"])
        case .directOverlap(let hosts):
            return ("指定直連 IP 與 DNS 或公司通道網段重疊", "與 DNS 或公司通道網段重疊的直連位址：\(Self.list(hosts))",
                    ["到「指定走原本網路的 IPv4 位址」移除這些位址，再按「重新嘗試分流」"])
        case .foreignLocalRoutes(let interfaces):
            return ("本機網段有其他通道的相同或更細路由，未套用分流", "有路由涵蓋本機網段的通道：\(Self.list(interfaces))",
                    ["中斷或調整這些通道，讓它不要涵蓋本機網段", "\(stop)，再\(restart)"])
        case .vpnAlreadyConnected(let tunnel):
            return ("請先中斷外部 VPN，再開始等待，才能記住正常上網出口",
                    tunnel.map { "目前已偵測到 VPN 通道 \($0)" } ?? "目前一般上網出口不是實體網卡",
                    ["先由原本的 VPN 程式中斷 VPN", restart + "，連線後它會自動偵測並分流"])
        case .networkChanged:
            return ("原本的網路已變更，請停止後重新開始等待", "上網的網卡、位址或閘道與記住的不同（常見於換 Wi-Fi 或重新開機）",
                    ["\(stop)", "確認已連上要使用的網路，再\(restart)"])
        case .physicalInterfaceChanged:
            return ("原本的實體介面編號已變更，請停止後重新開始等待", "原本的網卡被重新建立",
                    ["\(stop)", "確認網路正常後再\(restart)"])
        case .tunnelChanged:
            return ("原本的 VPN 全通道已變更，已停止分流並復原", "接管預設路由的通道與套用時不同",
                    ["先確認 VPN 程式沒有重新連線", "\(stop)，再\(restart)"])
        case .tunnelLost:
            return ("外部 VPN 通道已中斷或改變，已撤回分流", "VPN 通道已中斷或換了介面",
                    ["確認 VPN 程式仍在連線；若已中斷，重新連線後再\(restart)", "\(stop)"])
        case .noPhysicalExit:
            return ("找不到可保留的實體 IPv4 上網出口", "目前沒有經由實體網卡的 IPv4 預設路由",
                    ["確認 Wi-Fi 或有線網路已連上並能上網", "先中斷 VPN，再\(restart)"])
        case .noPhysicalAddress:
            return ("找不到實體 IPv4 位址", "上網的網卡沒有 IPv4 位址",
                    ["確認網路已取得 IPv4 位址（macOS 網路設定中不應顯示自行指定的 169.254.x.x）", "取得位址後再\(restart)"])
        case .physicalOffline:
            return ("原本的實體網卡已離線，請停止後重新開始", "記住的上網網卡已沒有 IPv4 位址",
                    ["確認網路已重新連上", "\(stop)，再\(restart)"])
        case .noBaselineDNS:
            return ("找不到原本網卡的 DNS，無法安全準備分流", "上網的網卡沒有設定 DNS 伺服器",
                    ["到 macOS 網路設定確認這張網卡有 DNS（可手動加入）", "確認 VPN 未連線後再\(restart)"])
        case .ignoredBaselineDNS(let expected, let actual):
            return ("macOS 未採用原本的上網 DNS，已停止分流並復原",
                    "預期預設 DNS \(Self.list(expected))，系統實際使用 \(Self.list(actual))",
                    ["暫時關閉其他會接管系統預設 DNS 的通道或工具", "\(stop)，再\(restart)", log])
        }
    }
}

struct ExternalVPNFailure: Codable, Equatable {
    enum Stage: String, Codable { case preparing, observing, planning, applyingRoutes, applyingDNS, verifying, restoring }
    let stage: Stage
    let message: String
    var dnsDifferences: [String]? = nil
    var advice: ExternalVPNAdvice? = nil

    static let maxDifferenceLines = 20
    static let maxDifferenceScalars = 300

    // 差異經 status JSON 交給 App，App 只讀 64 KB；新增或消失的項目會列整筆 DNS 字典，必須在這裡截短。
    // 以 Unicode scalar 計長度，才能限制位元組數（一個 Character 可以由任意多個 scalar 組成）。
    static func limited(_ lines: [String]) -> [String] {
        func clip(_ line: String) -> String {
            guard line.unicodeScalars.count > maxDifferenceScalars else { return line }
            return String(String.UnicodeScalarView(line.unicodeScalars.prefix(maxDifferenceScalars - 1))) + "…"
        }
        guard lines.count > maxDifferenceLines else { return lines.map(clip) }
        let shown = maxDifferenceLines - 1
        return lines.prefix(shown).map(clip) + ["另有 \(lines.count - shown) 項差異未列出"]
    }
}

struct ExternalVPNSession: Codable {
    let owner: UInt32
    let baseline: ExternalNetworkSnapshot
    let profile: ExternalVPNProfile
    var phase: ExternalVPNPhase = .waiting
    var tunnel: String?
    var addedRoutes: [ExternalRoute] = []
    var dnsChanges: [ExternalDNSChange] = []
    var preservedDNS: ExternalDNSState?
    var message: String = "已記住原本網路，等待外部 VPN 連線"
    var firstFailure: ExternalVPNFailure?
    var latestFailure: ExternalVPNFailure?
    var journalVersion: Int?
    var company: CompanyLease?
    var routingEvidence: ExternalVPNRoutingEvidence?
    var settling: ExternalSettlingObservation?
    var autoRetried: Bool?

    var hasPendingMutations: Bool { !addedRoutes.isEmpty || !dnsChanges.isEmpty || company != nil }

    func waitingMessage(_ text: String) -> String {
        guard autoRetried == true, let reason = latestFailure?.message else { return text }
        return text + "；自動重試中，第一次分流失敗：\(reason)"
    }

    var canRetry: Bool {
        guard (phase == .failed || phase == .recoveryRequired), !hasPendingMutations,
              ExternalVPNPlanner.isPhysical(baseline.interface) else { return false }
        do { return try ExternalVPNPlanner.tunnel(in: baseline) == nil }
        catch { return false }
    }
}

struct ExternalVPNStatus: Codable {
    var phase: ExternalVPNPhase
    var message: String
    var interface: String?
    var tunnel: String?
    var routeCount: Int
    var canRetry: Bool?
    var dnsMode: ExternalVPNDNSMode?
    var companyCapability: Int?
    var companyState: CompanyLeaseState?
    var busy: Bool?
    var latestFailure: ExternalVPNFailure?
    var autoRetried: Bool?
    static var idle: Self { Self(phase: .idle, message: "尚未開始分流", interface: nil, tunnel: nil, routeCount: 0) }
    init(session: ExternalVPNSession) {
        phase = session.phase; message = session.message; interface = session.baseline.interface
        tunnel = session.tunnel; routeCount = session.addedRoutes.count
        canRetry = session.canRetry; dnsMode = session.profile.dnsMode
        companyCapability = session.journalVersion == 3 && session.routingEvidence != nil ? 1 : nil; companyState = session.company?.state
        latestFailure = session.latestFailure; autoRetried = session.autoRetried
    }
    init(phase: ExternalVPNPhase, message: String, interface: String?, tunnel: String?, routeCount: Int, canRetry: Bool? = nil, dnsMode: ExternalVPNDNSMode? = nil) {
        self.phase = phase; self.message = message; self.interface = interface; self.tunnel = tunnel; self.routeCount = routeCount
        self.canRetry = canRetry; self.dnsMode = dnsMode
    }
}

struct ExternalVPNRoutePlan {
    let additions: [ExternalRoute]
    let evidence: ExternalVPNRoutingEvidence
}

struct ExternalVPNRoutingEvidence: Codable, Equatable {
    let publicNetworks: [ExternalIPv4Network]
    let directHosts: [ExternalIPv4Network]
    let borrowedRoutes: [ExternalRoute]
    let physicalInterfaceIndex: UInt32

    static func validateNetwork(_ session: ExternalVPNSession, _ current: ExternalNetworkSnapshot) throws {
        let baseline = session.baseline
        guard ExternalVPNPlanner.sameBoot(baseline, current), current.interface == baseline.interface,
              current.address == baseline.address, current.gateway == baseline.gateway,
              current.localNetwork == baseline.localNetwork,
              baseline.interfaceIndex == nil || current.interfaceIndex == baseline.interfaceIndex else {
            throw ExternalVPNIssue.networkChanged
        }
    }

    func isLANRoute(_ route: ExternalRoute, session: ExternalVPNSession) -> Bool {
        guard route.isUsable, !route.flags.contains("G") else { return false }
        if route.interface == session.baseline.interface { return true }
        return route.interface == "lo0" && route.network.prefix == 32
            && route.network.address.description == session.baseline.address
            && session.baseline.routes.contains(route)
    }

    func validate(_ session: ExternalVPNSession, current: ExternalNetworkSnapshot) throws {
        try Self.validateNetwork(session, current)
        guard physicalInterfaceIndex > 0, current.interfaceIndex == physicalInterfaceIndex else {
            throw ExternalVPNIssue.physicalInterfaceChanged
        }
        guard let tunnel = session.tunnel, try ExternalVPNPlanner.tunnel(in: current) == tunnel else {
            throw ExternalVPNIssue.tunnelChanged
        }
        let dns = current.dns.flatMap(\.servers).compactMap { try? ExternalIPv4($0) }
        let clashing = directHosts.filter { host in
            dns.contains { host.contains($0) } || session.company?.policy.selectors.contains { CompanyVPNPlanner.overlaps(host, $0) } == true
        }
        guard clashing.isEmpty else { throw ExternalVPNIssue.directOverlap(clashing.map { $0.address.description }) }
        var exemptions: [ExternalIPv4Network] = []
        if let lease = session.company, let identity = lease.identity {
            guard identity.daemon == lease.daemon else { throw ExternalVPNError.invalid("公司通道身分與紀錄不符") }
            _ = try CompanyVPNPlanner.coverage(lease.policy, identity: identity, session: session, current: current)
            exemptions = lease.policy.selectors
        }
        var count = 0
        func verify(_ networks: [ExternalIPv4Network], exclusions: [ExternalIPv4Network] = [], accepts: (ExternalRoute) -> Bool) throws {
            for network in networks {
                let start = UInt64(network.address.value)
                let end = start + (UInt64(1) << (32 - network.prefix))
                var boundaries: Set<UInt64> = [start, end]
                for item in current.routes.map(\.network) + exclusions where CompanyVPNPlanner.overlaps(network, item) {
                    let lo = UInt64(item.address.value)
                    let hi = lo + (UInt64(1) << (32 - item.prefix))
                    if lo > start && lo < end { boundaries.insert(lo) }
                    if hi > start && hi < end { boundaries.insert(hi) }
                }
                count += boundaries.count - 1
                guard count <= 16384 else { throw ExternalVPNError.invalid("路由區間超過完整驗證上限") }
                for point in boundaries.sorted().dropLast() {
                    let ip = ExternalIPv4(value: UInt32(point))
                    if exclusions.contains(where: { $0.contains(ip) }) { continue }
                    let winners = CompanyVPNPlanner.winners(ip, routes: current.routes)
                    guard !winners.isEmpty, winners.allSatisfy({ $0.isUsable && accepts($0) }) else {
                        throw ExternalVPNError.invalid("外網、指定 IP 或本機網段的完整路由覆蓋已變更")
                    }
                }
            }
        }
        func physical(_ route: ExternalRoute) -> Bool {
            route.interface == session.baseline.interface && route.gateway == session.baseline.gateway && route.kind == .gateway
                && (borrowedRoutes.contains { $0.sameIdentity(as: route) } || session.addedRoutes.contains { $0.sameIdentity(as: route) })
        }
        try verify(publicNetworks, exclusions: exemptions, accepts: physical)
        try verify(directHosts, accepts: physical)
        try verify([session.baseline.localNetwork]) { isLANRoute($0, session: session) }
    }
}

enum ExternalVPNPlanner {
    // boottime 的微秒會隨時鐘校正漂移，同一次開機以 kern.bootsessionuuid 判定。舊紀錄沒有 UUID 時退回比對秒數；
    // 漂移剛好跨秒仍會誤判為重新開機，但比原本逐微秒比對好。bootID 維持舊格式，降版的 helper 讀新紀錄不會更糟。
    static func sameBoot(_ recorded: ExternalNetworkSnapshot, _ current: ExternalNetworkSnapshot) -> Bool {
        if let left = recorded.bootSession, let right = current.bootSession { return left == right }
        func seconds(_ value: String) -> Substring? {
            let clock = value.split(separator: ".", omittingEmptySubsequences: false)
            return clock.count == 2 && clock.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) ? clock[0] : nil
        }
        if let left = seconds(recorded.bootID), let right = seconds(current.bootID) { return left == right }
        return recorded.bootID == current.bootID
    }

    static func isTunnel(_ name: String) -> Bool { name.range(of: #"^(utun|ppp)[0-9]{1,4}$"#, options: .regularExpression) != nil }
    static func isPhysical(_ name: String) -> Bool { name.range(of: #"^(en[0-9]{1,4}|bridge[0-9]{1,4})$"#, options: .regularExpression) != nil }

    static func parseRoutes(_ text: String) -> [ExternalRoute] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4, let network = ExternalIPv4Network.tableDestination(fields[0], host: fields[2].contains("H")),
                  let interface = fields.dropFirst(3).first(where: { $0.range(of: #"^[a-z]+[0-9]+$"#, options: .regularExpression) != nil }) else { return nil }
            return ExternalRoute(network: network, gateway: fields[1], interface: interface, flags: fields[2])
        }
    }

    static func tunnel(in snapshot: ExternalNetworkSnapshot) throws -> String? {
        if snapshot.ipv6TunnelDefault { throw ExternalVPNIssue.ipv6Takeover }
        let candidates = Set(snapshot.routes.filter { $0.isTunnel && $0.network.prefix <= 1 && $0.flags.contains("U") && !$0.flags.contains("I") }.map(\.interface))
        guard candidates.count <= 1 else { throw ExternalVPNIssue.multipleTunnels(candidates.sorted()) }
        return candidates.first
    }

    static func hasIPv6TunnelDefault(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            return fields.count >= 4 && ["default", "::/0", "::/1", "8000::/1"].contains(fields[0])
                && fields[2].contains("U") && !fields[2].contains("I")
                && fields.dropFirst(3).contains(where: isTunnel)
        }
    }

    static func publicNetworks(excluding excluded: [ExternalIPv4Network]) -> [ExternalIPv4Network] {
        let special = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3"].compactMap { try? ExternalIPv4Network($0) }
        let reserved = excluded + special
        func visit(_ network: ExternalIPv4Network) -> [ExternalIPv4Network] {
            if reserved.contains(where: { $0.contains(network) }) { return [] }
            if network.prefix >= 2 && !reserved.contains(where: { network.contains($0) }) { return [network] }
            return network.halves.flatMap(visit)
        }
        return visit(try! ExternalIPv4Network("0.0.0.0/0"))
    }

    static func plan(_ session: ExternalVPNSession, current: ExternalNetworkSnapshot, tunnel: String) throws -> ExternalVPNRoutePlan {
        let baseline = session.baseline
        try ExternalVPNRoutingEvidence.validateNetwork(session, current)
        let profile = try session.profile.validated()
        let protected = try profile.protectedNetworks.map(ExternalIPv4Network.init)
        let direct = try profile.directIPv4.map { ExternalIPv4Network(address: try ExternalIPv4($0), prefix: 32) }
        let dns = current.dns.flatMap(\.servers).compactMap { try? ExternalIPv4($0) }.map { ExternalIPv4Network(address: $0, prefix: 32) }
        let clashing = direct.filter { host in
            dns.contains { $0.contains(host) } || session.company?.policy.selectors.contains { $0.contains(host) } == true
        }
        guard clashing.isEmpty else { throw ExternalVPNIssue.directOverlap(clashing.map { $0.address.description }) }
        let physicalRanges = current.routes.filter {
            $0.interface == baseline.interface && $0.network.prefix >= 2 && !$0.flags.contains("I")
                && !direct.contains($0.network)
        }.map(\.network) + [baseline.localNetwork]
        let overlapping = protected.filter { requested in
            physicalRanges.contains { $0.contains(requested) || requested.contains($0) }
        }
        guard overlapping.isEmpty else { throw ExternalVPNIssue.protectedOverlap(overlapping.map(\.description)) }
        let vpnPrecise = current.routes.filter {
            $0.interface == tunnel && $0.network.prefix >= 2 && $0.flags.contains("U") && !$0.flags.contains("I")
        }.map(\.network)
        let vpnDNS = try current.dns.filter { $0.interface == tunnel }.flatMap(\.servers).map {
            ExternalIPv4Network(address: try ExternalIPv4($0), prefix: 32)
        }
        let required = publicNetworks(excluding: protected + vpnPrecise + vpnDNS + [baseline.localNetwork])
        // 限定介面（I）的路由只給綁定該介面的流量用，覆蓋驗證也不採計；若當成既有細部路由略過，會留下沒有實體路由的缺口。
        let precise = current.routes.filter { $0.network.prefix >= 2 && !$0.flags.contains("I") }.map(\.network)
        let networks = publicNetworks(excluding: protected + precise + vpnDNS + [baseline.localNetwork] + direct)
        guard required.count <= 2048, networks.count <= 2048 else { throw ExternalVPNError.invalid("外網路由範圍無法安全分流") }
        var additions = networks.map { ExternalRoute(network: $0, gateway: baseline.gateway, interface: baseline.interface, flags: "UGS1") }
        for host in direct {
            let exact = current.routes.filter { $0.network == host && !$0.flags.contains("I") }
            if exact.isEmpty {
                additions.append(ExternalRoute(network: host, gateway: baseline.gateway, interface: baseline.interface, flags: "UGHS1"))
            }
        }
        let borrowed = current.routes.filter { route in
            route.isUsable && route.interface == baseline.interface && route.gateway == baseline.gateway && route.kind == .gateway
        }
        let lan = baseline.localNetwork
        let originalLAN = baseline.routes.filter { $0.network == lan && $0.interface == baseline.interface && $0.isUsable && !$0.flags.contains("G") }
        let recordedIndices = Set(originalLAN.compactMap { route -> UInt32? in
            guard route.gateway.hasPrefix("link#") else { return nil }
            return UInt32(route.gateway.dropFirst(5))
        })
        let expectedIndex = baseline.interfaceIndex ?? (recordedIndices.count == 1 ? recordedIndices.first : nil)
        guard let physicalInterfaceIndex = current.interfaceIndex, physicalInterfaceIndex > 0,
              expectedIndex == physicalInterfaceIndex else {
            throw ExternalVPNError.invalid("無法確認原本實體網路的介面編號，未套用分流")
        }
        let evidence = ExternalVPNRoutingEvidence(publicNetworks: required, directHosts: direct, borrowedRoutes: borrowed, physicalInterfaceIndex: physicalInterfaceIndex)
        let lanRoutes = current.routes.filter { $0.flags.contains("U") && !$0.flags.contains("I") && $0.network.prefix >= lan.prefix && CompanyVPNPlanner.overlaps($0.network, lan) }
        let foreignLAN = lanRoutes.filter { !evidence.isLANRoute($0, session: session) }
        guard foreignLAN.isEmpty else {
            throw ExternalVPNIssue.foreignLocalRoutes(Array(Set(foreignLAN.map(\.interface))).sorted())
        }
        if !lanRoutes.contains(where: { $0.network == lan }) {
            // F5 會刪掉原生 LAN 路由，下次準備時 baseline 可能已缺它；root 由 getifaddrs 擷取的介面 index、位址與遮罩足以證明直連網段。
            let capturedInterface = baseline.interfaceIndex == physicalInterfaceIndex && !baseline.address.isEmpty
            guard capturedInterface || originalLAN.contains(where: { $0.gateway == "link#\(physicalInterfaceIndex)" }) else {
                throw ExternalVPNError.invalid("無法確認原本本機網段的直連介面，未套用分流")
            }
            additions.insert(ExternalRoute(network: lan, gateway: "link#\(physicalInterfaceIndex)", interface: baseline.interface, flags: "US1", nextHopKind: .directInterface), at: 0)
        }
        var proposed = session
        proposed.tunnel = tunnel
        proposed.routingEvidence = evidence
        proposed.journalVersion = 3
        proposed.addedRoutes += additions
        var simulated = current
        simulated.routes += additions
        try evidence.validate(proposed, current: simulated)
        return ExternalVPNRoutePlan(additions: additions, evidence: evidence)
    }

    // point-to-point 通道的對端位址：主機路由 A 經本端位址 L（無 G），且同介面有 L/32 指回 A。
    static func tunnelEndpoints(_ routes: [ExternalRoute], interface: String) -> Set<ExternalIPv4> {
        let local = routes.filter { $0.interface == interface }
        return Set(local.compactMap { route -> ExternalIPv4? in
            guard route.network.prefix == 32, route.flags.contains("H"), !route.flags.contains("G"),
                  let peer = try? ExternalIPv4(route.gateway),
                  local.contains(where: { $0.network == ExternalIPv4Network(address: peer, prefix: 32) && (try? ExternalIPv4($0.gateway)) == route.network.address })
            else { return nil }
            return route.network.address
        })
    }

    static func dnsPlan(_ session: ExternalVPNSession, current: ExternalNetworkSnapshot, tunnel: String) throws -> ExternalDNSPlan {
        let changed = current.dns.filter { entry in !ExternalDNSEntry.equalValues(session.baseline.dns.first(where: { $0.key == entry.key })?.value, entry.value) }
        let tunnelDNS = changed.filter { $0.interface == tunnel }
        let unknown = changed.filter { $0.interface != tunnel }
        guard unknown.isEmpty else { throw ExternalVPNIssue.unknownDNSChange(unknown.map(\.label)) }
        guard !tunnelDNS.isEmpty else {
            guard current.defaultDNSServers == session.baseline.defaultDNSServers,
                  current.defaultDNSDomains == session.baseline.defaultDNSDomains else {
                throw ExternalVPNIssue.defaultDNSChanged(recorded: session.baseline.defaultDNSServers, current: current.defaultDNSServers)
            }
            return ExternalDNSPlan(changes: [], preserved: session.profile.dnsMode == .preserveVPN ? ExternalDNSState(current) : nil)
        }
        for entry in tunnelDNS {
            guard !entry.servers.isEmpty else { throw ExternalVPNError.invalid("VPN 未提供可辨識的 DNS 伺服器，未套用分流") }
            for server in entry.servers {
                let ip = try ExternalIPv4(server)
                let matches = current.routes.filter { $0.flags.contains("U") && !$0.flags.contains("I") && $0.network.contains(ip) }
                let longest = matches.map(\.network.prefix).max()
                guard let longest, matches.filter({ $0.network.prefix == longest }).allSatisfy({ $0.interface == tunnel }) else {
                    throw ExternalVPNError.invalid("VPN DNS 的路由不在通道內，未套用分流")
                }
            }
        }
        let physical = current.dns.filter { $0.interface == session.baseline.interface && !$0.servers.isEmpty }
        guard physical.count == 1, let entry = physical.first,
              ExternalDNSEntry.equalValues(session.baseline.dns.first(where: { $0.key == entry.key })?.value, entry.value) else {
            throw ExternalVPNIssue.baselineDNSOwnerUnknown
        }
        let endpoints = tunnelEndpoints(current.routes, interface: tunnel)
        var skipped: [String] = []
        for server in entry.servers {
            guard let ip = try? ExternalIPv4(server) else { throw ExternalVPNIssue.baselineDNSIPv6(server) }
            guard !tunnelDNS.contains(where: { $0.servers.contains(server) }) else {
                throw ExternalVPNIssue.dnsOverlap(server)
            }
            let covering = current.routes.filter { $0.isTunnel && $0.network.prefix >= 2 && $0.network.contains(ip) }
            guard let finest = covering.max(by: { $0.network.prefix < $1.network.prefix }) else { continue }
            let host = ExternalIPv4Network(address: ip, prefix: 32)
            guard endpoints.contains(ip), covering.allSatisfy({ $0.interface == tunnel && $0.network == host }) else {
                throw ExternalVPNIssue.baselineDNSCaptured(server: server, interface: finest.interface, network: finest.network.description)
            }
            skipped.append(server)
        }
        guard skipped.count < entry.servers.count else {
            throw ExternalVPNIssue.baselineDNSAllEndpoints(skipped)
        }
        if session.profile.dnsMode == .preserveVPN {
            let knownDNS = tunnelDNS + [entry]
            // 連線前就是全域預設、且內容未被 VPN 改動的其他具名服務（例：Tailscale），沿用不影響分流。
            let untouched = current.dns.filter { candidate in
                candidate.interface != nil && candidate.interface != tunnel &&
                    ExternalDNSEntry.equalValues(session.baseline.dns.first(where: { $0.key == candidate.key })?.value, candidate.value)
            }
            var unattributed: [ExternalVPNIssue.DNSOwner] = []
            for server in current.defaultDNSServers {
                let owners = current.dns.filter { $0.servers.contains(server) }
                let preexisting = session.baseline.defaultDNSServers.contains(server)
                if owners.isEmpty || !owners.allSatisfy({ knownDNS.contains($0) || (preexisting && untouched.contains($0)) }) {
                    unattributed.append(.init(address: server, interfaces: Array(Set(owners.compactMap(\.interface))).sorted()))
                }
            }
            guard unattributed.isEmpty else { throw ExternalVPNIssue.unattributedDefaultDNS(unattributed) }
            return ExternalDNSPlan(changes: [], preserved: ExternalDNSState(current), skippedEndpointDNS: skipped)
        }
        var changes = try tunnelDNS.map { entry in
            var dictionary = entry.dictionary
            var domains = session.profile.dnsDomains
            if domains.isEmpty {
                domains = (dictionary["SupplementalMatchDomains"] as? [String] ?? []) + (dictionary["SearchDomains"] as? [String] ?? [])
                domains = domains.filter { !$0.isEmpty }
                domains = try ExternalVPNProfile(dnsDomains: domains).validated().dnsDomains
            }
            guard !domains.isEmpty else { throw ExternalVPNIssue.noInternalDomains }
            dictionary["SupplementalMatchDomains"] = domains
            dictionary.removeValue(forKey: "SupplementalMatchOrders")
            dictionary["SupplementalMatchDomainsNoSearch"] = 1
            dictionary.removeValue(forKey: "SearchDomains")
            dictionary.removeValue(forKey: "DomainName")
            let after = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            return ExternalDNSChange(key: entry.key, before: entry.value, after: after)
        }
        var dictionary = entry.dictionary
        // configd 仍可能把 VPN 主服務當成預設解析器，需明確提升原本 DNS 的全域比對順序。
        dictionary["SupplementalMatchDomains"] = [""]
        dictionary["SupplementalMatchOrders"] = [1]
        dictionary["SearchOrder"] = 1
        let after = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        changes.append(ExternalDNSChange(key: entry.key, before: entry.value, after: after))
        return ExternalDNSPlan(changes: changes, preserved: nil, skippedEndpointDNS: skipped)
    }
}

protocol ExternalVPNRuntime: AnyObject {
    func snapshot(baseline: ExternalNetworkSnapshot?) throws -> ExternalNetworkSnapshot
    func add(_ route: ExternalRoute) throws
    func remove(_ route: ExternalRoute) throws
    func dnsValue(_ key: String) throws -> Data?
    func setDNS(_ key: String, value: Data) throws
    func save(_ session: ExternalVPNSession?) throws
    func releaseCompany(_ session: ExternalVPNSession) throws -> ExternalVPNSession
}

extension ExternalVPNRuntime {
    func releaseCompany(_ session: ExternalVPNSession) throws -> ExternalVPNSession {
        guard session.company == nil else { throw CompanyVPNError.recovery("公司通道尚未停止，保留 F5 分流") }
        return session
    }
}

final class ExternalVPNEngine {
    private let runtime: ExternalVPNRuntime
    init(runtime: ExternalVPNRuntime) { self.runtime = runtime }

    func prepare(owner: UInt32, profile: ExternalVPNProfile, previous: ExternalVPNSession? = nil) throws -> ExternalVPNSession {
        let profile = try profile.validated()
        if let previous {
            guard previous.owner == owner, previous.canRetry else {
                throw ExternalVPNError.invalid("已有待復原的分流設定，請先停止並復原")
            }
            var session = try resume(previous, profile: profile)
            session.message = "沿用原本上網快照，等待重新嘗試分流"
            try runtime.save(session)
            return session
        }
        let snapshot = try runtime.snapshot(baseline: nil)
        guard ExternalVPNPlanner.isPhysical(snapshot.interface), try ExternalVPNPlanner.tunnel(in: snapshot) == nil else {
            throw ExternalVPNIssue.vpnAlreadyConnected(tunnel: try? ExternalVPNPlanner.tunnel(in: snapshot))
        }
        var session = ExternalVPNSession(owner: owner, baseline: snapshot, profile: profile)
        session.journalVersion = 3
        try runtime.save(session)
        return session
    }

    // VPN 仍連線時 snapshot(baseline:) 依 baseline 的介面名稱讀位址與 Router，與 waiting 每次 tick 的比對相同。
    private func resume(_ previous: ExternalVPNSession, profile: ExternalVPNProfile) throws -> ExternalVPNSession {
        let current = try runtime.snapshot(baseline: previous.baseline)
        let baseline = previous.baseline
        guard ExternalVPNPlanner.sameBoot(baseline, current), current.interface == baseline.interface,
              current.address == baseline.address, current.gateway == baseline.gateway,
              current.localNetwork == baseline.localNetwork else {
            throw ExternalVPNIssue.networkChanged
        }
        var session = ExternalVPNSession(owner: previous.owner, baseline: baseline, profile: profile)
        session.journalVersion = 3
        session.firstFailure = previous.firstFailure
        session.latestFailure = previous.latestFailure
        return session
    }

    private func retryOnce(_ failed: ExternalVPNSession) -> ExternalVPNSession {
        guard failed.autoRetried != true, failed.canRetry, let reason = failed.latestFailure?.message else { return failed }
        do {
            var session = try resume(failed, profile: failed.profile)
            session.autoRetried = true
            session.message = "第一次分流失敗：\(reason)；已自動復原並重新等待 VPN 設定穩定"
            try runtime.save(session)
            return session
        } catch { return failed }
    }

    func failed(_ input: ExternalVPNSession, error: Error, stage: ExternalVPNFailure.Stage) throws -> ExternalVPNSession {
        var session = input
        let failure = ExternalVPNFailure(stage: stage, message: error.localizedDescription, dnsDifferences: (error as? ExternalVPNDetailedError).map { ExternalVPNFailure.limited($0.dnsDifferences) }, advice: (error as? ExternalVPNIssue)?.advice)
        if session.firstFailure == nil { session.firstFailure = failure }
        session.latestFailure = failure
        session.phase = session.hasPendingMutations ? .recoveryRequired : .failed
        if let first = session.firstFailure, first != failure {
            session.message = "最初失敗：\(first.message)；這次失敗：\(failure.message)"
        } else { session.message = failure.message }
        if session.hasPendingMutations { session.message += "；仍有項目需要復原" }
        try runtime.save(session)
        return session
    }

    func tick(_ input: ExternalVPNSession) throws -> ExternalVPNSession {
        var session = input
        var stage = ExternalVPNFailure.Stage.observing
        guard session.phase == .waiting || session.phase == .active else { return session }
        do {
            let current = try runtime.snapshot(baseline: session.baseline)
            if session.phase == .active {
                stage = .verifying
                guard try ExternalVPNPlanner.tunnel(in: current) == session.tunnel else {
                    throw ExternalVPNIssue.tunnelLost
                }
                guard let evidence = session.routingEvidence, session.journalVersion == 3 else {
                    throw ExternalVPNError.invalid("VPN 路由紀錄缺少完整驗證證據，請停止後重新準備")
                }
                try evidence.validate(session, current: current)
                if session.profile.dnsMode == .preserveVPN {
                    let reason = "保留的 VPN DNS 已改變或缺少觀察紀錄，已停止分流並復原"
                    guard let preserved = session.preservedDNS, let tunnel = session.tunnel else { throw ExternalVPNError.invalid(reason) }
                    let differences = ExternalDNSState(current).differences(from: preserved)
                    guard differences.isEmpty else { throw ExternalVPNDetailedError(message: reason, dnsDifferences: differences) }
                    _ = try ExternalVPNPlanner.dnsPlan(session, current: current, tunnel: tunnel)
                }
                for change in session.dnsChanges {
                    let value = try runtime.dnsValue(change.key)
                    guard !ExternalDNSEntry.equalValues(value, change.after) else { continue }
                    let differences = value.map { ExternalDNSEntry.fieldDifferences(from: change.after, to: $0).map { "改變 \(change.key) 的 \($0)" } } ?? ["消失 \(change.key)"]
                    throw ExternalVPNDetailedError(message: "VPN 重新設定 DNS，已停止分流並復原", dnsDifferences: differences)
                }
                if let physicalDNS = session.dnsChanges.first(where: { change in
                    session.baseline.dns.contains { $0.key == change.key && $0.interface == session.baseline.interface }
                }) {
                    let expected = (try? PropertyListSerialization.propertyList(from: physicalDNS.after, format: nil)) as? [String: Any]
                    guard current.defaultDNSServers == expected?["ServerAddresses"] as? [String] else {
                        throw ExternalVPNIssue.ignoredBaselineDNS(expected: expected?["ServerAddresses"] as? [String] ?? [], actual: current.defaultDNSServers)
                    }
                }
                return session
            }
            guard ExternalVPNPlanner.sameBoot(session.baseline, current), current.address == session.baseline.address,
                  current.gateway == session.baseline.gateway else { throw ExternalVPNIssue.networkChanged }
            guard let tunnel = try ExternalVPNPlanner.tunnel(in: current) else {
                guard session.settling != nil else { return session }
                session.settling = nil
                session.message = session.waitingMessage("已記住原本網路，等待外部 VPN 連線")
                try runtime.save(session)
                return session
            }
            // VPN 可能先建通道與路由、幾秒後才設定 DNS；連續觀察到相同設定才規劃，避免記下半成品。
            let fingerprint = ExternalTunnelFingerprint(tunnel: tunnel, snapshot: current)
            let count = session.settling.map { $0.fingerprint.same(as: fingerprint) ? $0.count + 1 : 1 } ?? 1
            guard count >= ExternalSettlingObservation.required else {
                session.settling = ExternalSettlingObservation(fingerprint: fingerprint, count: count)
                session.message = session.waitingMessage("偵測到 VPN，等待設定穩定（\(count)/\(ExternalSettlingObservation.required)）")
                try runtime.save(session)
                return session
            }
            session.settling = nil
            stage = .planning
            let plan = try ExternalVPNPlanner.plan(session, current: current, tunnel: tunnel)
            let dns = try ExternalVPNPlanner.dnsPlan(session, current: current, tunnel: tunnel)
            session.phase = .applying; session.tunnel = tunnel; session.preservedDNS = dns.preserved
            session.routingEvidence = plan.evidence; session.journalVersion = 3
            try runtime.save(session)
            stage = .applyingRoutes
            for route in plan.additions {
                session.addedRoutes.append(route)
                try runtime.save(session)
                do { try runtime.add(route) } catch {
                    if case ExternalVPNRouteError.notAdded = error {
                        session.addedRoutes.removeLast()
                        try runtime.save(session)
                    }
                    throw error
                }
            }
            for change in dns.changes {
                stage = .applyingDNS
                guard try ExternalDNSEntry.equalValues(runtime.dnsValue(change.key), change.before) else { throw ExternalVPNError.invalid("DNS 在套用前已改變，已取消分流") }
                session.dnsChanges.append(change)
                try runtime.save(session)
                try runtime.setDNS(change.key, value: change.after)
            }
            stage = .verifying
            try plan.evidence.validate(session, current: runtime.snapshot(baseline: session.baseline))
            session.phase = .active
            session.message = session.profile.dnsMode == .preserveVPN
                ? "IPv4 路由已套用；DNS 維持 VPN 連線後原設定，外網與內網仍待確認"
                : "IPv4 分流已套用；請確認外網與 VPN 系統皆可使用"
            if !dns.skippedEndpointDNS.isEmpty {
                session.message += "；\(dns.skippedEndpointDNS.joined(separator: "、")) 是 VPN 通道端點，這段期間改用其他 DNS 查詢"
            }
            try runtime.save(session)
            return session
        } catch {
            session = try failed(session, error: error, stage: stage)
            if session.hasPendingMutations {
                do {
                    session = try restore(session)
                    session = try failed(session, error: error, stage: stage)
                } catch {
                    return try failed(session, error: error, stage: .restoring)
                }
            }
            return retryOnce(session)
        }
    }

    func restore(_ input: ExternalVPNSession) throws -> ExternalVPNSession {
        var session = try runtime.releaseCompany(input)
        session.phase = .restoring
        try runtime.save(session)
        let current = try runtime.snapshot(baseline: session.baseline)
        guard ExternalVPNPlanner.sameBoot(session.baseline, current) else {
            session.addedRoutes = []; session.dnsChanges = []; session.phase = .idle
            session.message = "系統已重新啟動，舊的暫時分流已失效"
            try runtime.save(nil)
            return session
        }
        var remainingDNS: [ExternalDNSChange] = []
        for change in session.dnsChanges.reversed() {
            do {
                let value = try runtime.dnsValue(change.key)
                if ExternalDNSEntry.equalValues(value, change.after) { try runtime.setDNS(change.key, value: change.before) }
                else if value != nil && !ExternalDNSEntry.equalValues(value, change.before) { remainingDNS.append(change) }
            } catch { remainingDNS.append(change) }
        }
        var remainingRoutes: [ExternalRoute] = []
        for route in session.addedRoutes.reversed() {
            let exact = current.routes.filter { $0.network == route.network }
            if let actual = exact.first(where: { $0.sameIdentity(as: route) && $0.isOwned }) {
                do { try runtime.remove(actual) } catch { remainingRoutes.append(route) }
            } else if !exact.isEmpty {
                let original = session.baseline.routes.filter { $0.network == route.network && $0.interface == route.interface && !$0.isOwned }
                // baseline 可能本來就缺 LAN 路由；OS 重建的原生 connected 路由（同 link、帶 cloning、無標記）不屬於我們，只放棄 intent。
                // 手動 -interface 加的同形路由無法區分，但這裡只放棄已無對象的紀錄，不會刪除它。
                func nativeLAN(_ actual: ExternalRoute) -> Bool {
                    route.kind == .directInterface && route.network == session.baseline.localNetwork && !actual.isOwned
                        && actual.interface == route.interface && actual.gateway == route.gateway && actual.kind == .directInterface
                        && actual.flags.contains("C") && !actual.flags.contains("I")
                }
                if !exact.allSatisfy({ actual in original.contains(actual) || nativeLAN(actual) }) { remainingRoutes.append(route) }
            }
        }
        session.addedRoutes = remainingRoutes.reversed(); session.dnsChanges = remainingDNS.reversed()
        session.phase = remainingRoutes.isEmpty && remainingDNS.isEmpty ? .idle : .recoveryRequired
        session.message = session.phase == .idle ? "本次分流已停止並復原" : "部分設定已被變更或復原失敗，保留紀錄供再次復原"
        try runtime.save(session.phase == .idle ? nil : session)
        return session
    }
}
