import Foundation

enum ExternalVPNError: LocalizedError {
    case invalid(String)
    case busy
    var errorDescription: String? { switch self { case .invalid(let text): return text; case .busy: return "另一個 VPN 操作正在執行" } }
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
    var dictionary: [String: Any] { (try? PropertyListSerialization.propertyList(from: value, format: nil)) as? [String: Any] ?? [:] }
    var servers: [String] { dictionary["ServerAddresses"] as? [String] ?? [] }
    static func equalValues(_ lhs: Data?, _ rhs: Data?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard let left = try? PropertyListSerialization.propertyList(from: lhs, format: nil) as? NSDictionary,
              let right = try? PropertyListSerialization.propertyList(from: rhs, format: nil) as? NSDictionary else { return false }
        return left.isEqual(right)
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

    func matches(_ snapshot: ExternalNetworkSnapshot) -> Bool {
        entries.count == snapshot.dns.count && defaultServers == snapshot.defaultDNSServers
            && defaultDomains == snapshot.defaultDNSDomains && entries.allSatisfy { entry in
                snapshot.dns.contains { $0.key == entry.key && $0.interface == entry.interface && ExternalDNSEntry.equalValues($0.value, entry.value) }
            }
    }
}

struct ExternalDNSPlan {
    let changes: [ExternalDNSChange]
    let preserved: ExternalDNSState?
    var skippedEndpointDNS: [String] = []
}

struct ExternalVPNFailure: Codable, Equatable {
    enum Stage: String, Codable { case preparing, observing, planning, applyingRoutes, applyingDNS, verifying, restoring }
    let stage: Stage
    let message: String
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

    var hasPendingMutations: Bool { !addedRoutes.isEmpty || !dnsChanges.isEmpty || company != nil }
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
    static var idle: Self { Self(phase: .idle, message: "尚未開始分流", interface: nil, tunnel: nil, routeCount: 0) }
    init(session: ExternalVPNSession) {
        phase = session.phase; message = session.message; interface = session.baseline.interface
        tunnel = session.tunnel; routeCount = session.addedRoutes.count
        canRetry = session.canRetry; dnsMode = session.profile.dnsMode
        companyCapability = session.journalVersion == 3 && session.routingEvidence != nil ? 1 : nil; companyState = session.company?.state
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
            throw ExternalVPNError.invalid("原本的網路已變更，請停止後重新開始等待")
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
            throw ExternalVPNError.invalid("原本的實體介面編號已變更，請停止後重新開始等待")
        }
        guard let tunnel = session.tunnel, try ExternalVPNPlanner.tunnel(in: current) == tunnel else {
            throw ExternalVPNError.invalid("原本的 VPN 全通道已變更，已停止分流並復原")
        }
        let dns = current.dns.flatMap(\.servers).compactMap { try? ExternalIPv4($0) }
        guard !directHosts.contains(where: { host in dns.contains { host.contains($0) } }),
              !directHosts.contains(where: { host in session.company?.policy.selectors.contains { CompanyVPNPlanner.overlaps(host, $0) } == true }) else {
            throw ExternalVPNError.invalid("指定直連 IP 與 DNS 或公司通道網段重疊")
        }
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
        if snapshot.ipv6TunnelDefault { throw ExternalVPNError.invalid("偵測到 VPN 接管 IPv6；此版本僅支援 IPv4，未套用分流") }
        let candidates = Set(snapshot.routes.filter { $0.isTunnel && $0.network.prefix <= 1 && $0.flags.contains("U") && !$0.flags.contains("I") }.map(\.interface))
        guard candidates.count <= 1 else { throw ExternalVPNError.invalid("有多個 VPN 接管預設路由，無法安全自動判斷") }
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
        guard !direct.contains(where: { host in dns.contains { $0.contains(host) } }),
              !direct.contains(where: { host in session.company?.policy.selectors.contains { $0.contains(host) } == true }) else {
            throw ExternalVPNError.invalid("指定直連 IP 與 DNS 或公司通道網段重疊")
        }
        let physicalRanges = current.routes.filter {
            $0.interface == baseline.interface && $0.network.prefix >= 2 && !$0.flags.contains("I")
                && !direct.contains($0.network)
        }.map(\.network) + [baseline.localNetwork]
        guard !protected.contains(where: { requested in
            physicalRanges.contains { $0.contains(requested) || requested.contains($0) }
        }) else {
            throw ExternalVPNError.invalid("保留 VPN 的網段與本機網路或既有實體路由重疊，未套用分流")
        }
        let vpnPrecise = current.routes.filter {
            $0.interface == tunnel && $0.network.prefix >= 2 && $0.flags.contains("U") && !$0.flags.contains("I")
        }.map(\.network)
        let vpnDNS = try current.dns.filter { $0.interface == tunnel }.flatMap(\.servers).map {
            ExternalIPv4Network(address: try ExternalIPv4($0), prefix: 32)
        }
        let required = publicNetworks(excluding: protected + vpnPrecise + vpnDNS + [baseline.localNetwork])
        let precise = current.routes.filter { $0.network.prefix >= 2 }.map(\.network)
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
        guard lanRoutes.allSatisfy({ evidence.isLANRoute($0, session: session) }) else {
            throw ExternalVPNError.invalid("本機網段有其他通道的相同或更細路由，未套用分流")
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
        guard unknown.isEmpty else { throw ExternalVPNError.invalid("VPN 修改了無法辨識歸屬的 DNS，未套用分流；請保留診斷供管理者確認") }
        guard !tunnelDNS.isEmpty else {
            guard current.defaultDNSServers == session.baseline.defaultDNSServers,
                  current.defaultDNSDomains == session.baseline.defaultDNSDomains else {
                throw ExternalVPNError.invalid("VPN 變更了無法對應服務的預設 DNS，未套用分流")
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
            throw ExternalVPNError.invalid("無法確定原本上網 DNS 的歸屬，未套用分流")
        }
        let endpoints = tunnelEndpoints(current.routes, interface: tunnel)
        var skipped: [String] = []
        for server in entry.servers {
            guard let ip = try? ExternalIPv4(server) else { throw ExternalVPNError.invalid("原本 DNS 含 IPv6 位址，此版本無法安全分流") }
            guard !tunnelDNS.contains(where: { $0.servers.contains(server) }) else {
                throw ExternalVPNError.invalid("原本與 VPN 的 DNS 位址重疊，無法安全分開查詢")
            }
            let covering = current.routes.filter { $0.isTunnel && $0.network.prefix >= 2 && $0.network.contains(ip) }
            guard let finest = covering.max(by: { $0.network.prefix < $1.network.prefix }) else { continue }
            let host = ExternalIPv4Network(address: ip, prefix: 32)
            guard endpoints.contains(ip), covering.allSatisfy({ $0.interface == tunnel && $0.network == host }) else {
                throw ExternalVPNError.invalid("原本的 DNS \(server) 被 \(finest.interface) 的 \(finest.network) 路由接管，未套用分流")
            }
            skipped.append(server)
        }
        guard skipped.count < entry.servers.count else {
            throw ExternalVPNError.invalid("原本的 DNS（\(skipped.joined(separator: "、"))）全部被 VPN 通道端點佔用，未套用分流")
        }
        if session.profile.dnsMode == .preserveVPN {
            let knownDNS = tunnelDNS + [entry]
            for server in current.defaultDNSServers {
                let owners = current.dns.filter { $0.servers.contains(server) }
                guard !owners.isEmpty, owners.allSatisfy({ knownDNS.contains($0) }) else {
                    throw ExternalVPNError.invalid("VPN 的預設 DNS 無法確定服務歸屬，未套用分流")
                }
            }
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
            guard !domains.isEmpty else { throw ExternalVPNError.invalid("VPN DNS 接管所有查詢，但未提供內部網域；請填入保留 VPN DNS 的網域後重試") }
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
            let current = try runtime.snapshot(baseline: previous.baseline)
            let baseline = previous.baseline
            guard ExternalVPNPlanner.sameBoot(baseline, current), current.interface == baseline.interface,
                  current.address == baseline.address, current.gateway == baseline.gateway,
                  current.localNetwork == baseline.localNetwork else {
                throw ExternalVPNError.invalid("原本的網路已變更，請停止後重新開始等待")
            }
            var session = ExternalVPNSession(owner: owner, baseline: baseline, profile: profile)
            session.journalVersion = 3
            session.firstFailure = previous.firstFailure
            session.latestFailure = previous.latestFailure
            session.message = "沿用原本上網快照，等待重新嘗試分流"
            try runtime.save(session)
            return session
        }
        let snapshot = try runtime.snapshot(baseline: nil)
        guard ExternalVPNPlanner.isPhysical(snapshot.interface), try ExternalVPNPlanner.tunnel(in: snapshot) == nil else {
            throw ExternalVPNError.invalid("請先中斷外部 VPN，再開始等待，才能記住正常上網出口")
        }
        var session = ExternalVPNSession(owner: owner, baseline: snapshot, profile: profile)
        session.journalVersion = 3
        try runtime.save(session)
        return session
    }

    func failed(_ input: ExternalVPNSession, error: Error, stage: ExternalVPNFailure.Stage) throws -> ExternalVPNSession {
        var session = input
        let failure = ExternalVPNFailure(stage: stage, message: error.localizedDescription)
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
                guard try ExternalVPNPlanner.tunnel(in: current) == session.tunnel,
                      let evidence = session.routingEvidence, session.journalVersion == 3 else {
                    throw ExternalVPNError.invalid("VPN 路由紀錄缺少完整驗證證據，請停止後重新準備")
                }
                try evidence.validate(session, current: current)
                if session.profile.dnsMode == .preserveVPN {
                    guard let preserved = session.preservedDNS, preserved.matches(current), let tunnel = session.tunnel else {
                        throw ExternalVPNError.invalid("保留的 VPN DNS 已改變或缺少觀察紀錄，已停止分流並復原")
                    }
                    _ = try ExternalVPNPlanner.dnsPlan(session, current: current, tunnel: tunnel)
                }
                for change in session.dnsChanges where try !ExternalDNSEntry.equalValues(runtime.dnsValue(change.key), change.after) {
                    throw ExternalVPNError.invalid("VPN 重新設定 DNS，已停止分流並復原")
                }
                if let physicalDNS = session.dnsChanges.first(where: { change in
                    session.baseline.dns.contains { $0.key == change.key && $0.interface == session.baseline.interface }
                }) {
                    let expected = (try? PropertyListSerialization.propertyList(from: physicalDNS.after, format: nil)) as? [String: Any]
                    guard current.defaultDNSServers == expected?["ServerAddresses"] as? [String] else {
                        throw ExternalVPNError.invalid("macOS 未採用原本的上網 DNS，已停止分流並復原")
                    }
                }
                return session
            }
            guard ExternalVPNPlanner.sameBoot(session.baseline, current), current.address == session.baseline.address,
                  current.gateway == session.baseline.gateway else { throw ExternalVPNError.invalid("原本的網路已變更，請停止後重新開始等待") }
            guard let tunnel = try ExternalVPNPlanner.tunnel(in: current) else { return session }
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
            guard session.hasPendingMutations else { return session }
            do {
                session = try restore(session)
                return try failed(session, error: error, stage: stage)
            } catch {
                return try failed(session, error: error, stage: .restoring)
            }
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
