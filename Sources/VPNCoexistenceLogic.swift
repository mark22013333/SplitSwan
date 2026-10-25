import Foundation
import CryptoKit

enum CompanyVPNError: LocalizedError {
    case admission(String), requiresReprepare, busy, recovery(String)
    var errorDescription: String? {
        switch self {
        case .admission(let text), .recovery(let text): return text
        case .requiresReprepare: return "公司網段或閘道與現有分流衝突，需停止後重新準備；目前 F5 分流保持原狀"
        case .busy: return "另一個 VPN 操作正在執行"
        }
    }
    var code: String {
        switch self {
        case .requiresReprepare: return "requiresReprepare"
        case .busy: return "busy"
        case .recovery: return "recoveryRequired"
        case .admission: return "unsupported"
        }
    }
}

struct CompanyPolicy: Codable, Equatable {
    let revision: String
    let slot: Int
    let selectors: [ExternalIPv4Network]
    let peer: ExternalIPv4
    let dnsMode: String

    init(revision: String, slot: Int, selectors: [String], peer: String) throws {
        guard (1...3).contains(slot), revision.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw CompanyVPNError.admission("公司設定版本無法驗證")
        }
        self.revision = revision; self.slot = slot
        self.selectors = try Self.normalized(selectors)
        self.peer = try ExternalIPv4(peer)
        self.dnsMode = "keepCurrentResolvers"
        guard !self.selectors.contains(where: { $0.contains(self.peer) }) else { throw CompanyVPNError.requiresReprepare }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func normalized(_ values: [String]) throws -> [ExternalIPv4Network] {
        guard !values.isEmpty, values.count <= 128 else { throw CompanyVPNError.admission("公司通道網段數量無法驗證") }
        var networks = try values.map(ExternalIPv4Network.init)
        guard networks.allSatisfy({ $0.prefix >= 2 }) else { throw CompanyVPNError.admission("雙 VPN 僅支援明確 IPv4 分流，不接受預設或半個網際網路的通道") }
        networks = Array(Set(networks)).filter { item in !networks.contains { $0 != item && $0.contains(item) } }
        var changed = true
        while changed {
            changed = false
            for item in networks where item.prefix > 0 {
                let parent = ExternalIPv4Network(address: item.address, prefix: item.prefix - 1)
                if parent.halves.allSatisfy(networks.contains) {
                    networks.removeAll { parent.halves.contains($0) }; networks.append(parent); changed = true; break
                }
            }
        }
        guard networks.allSatisfy({ $0.prefix >= 2 }) else { throw CompanyVPNError.admission("公司選擇器合併後涵蓋預設或半個網際網路") }
        return networks.sorted { $0.address == $1.address ? $0.prefix < $1.prefix : $0.address < $1.address }
    }
}

struct CompanyIdentity: Codable, Equatable {
    let daemon: String
    let ikeID: Int
    let childID: Int
    let vip: ExternalIPv4
    let interface: String
    let peer: ExternalIPv4
    let local: ExternalIPv4
    let selectors: [ExternalIPv4Network]
}

enum CompanyLeaseState: String, Codable { case admitting, active, releasing, recoveryRequired }
struct CompanyLease: Codable {
    let id: UUID
    let policy: CompanyPolicy
    var state: CompanyLeaseState
    var identity: CompanyIdentity?
    var daemon: String?
    // Root 建立的公司路由意圖；釋放靠結束 SA 讓 utun 退役，核心一併移除，不以目的地刪除。
    var routes: [ExternalRoute]? = nil
}

// Envelope versions keep older helpers from dropping newer route or ownership evidence.
struct ExternalVPNJournal: Codable {
    let schemaVersion: Int
    let session: ExternalVPNSession
    static func decode(_ data: Data) throws -> ExternalVPNSession {
        let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if keys?["schemaVersion"] != nil {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard [2, 3].contains(value.schemaVersion), value.session.journalVersion == value.schemaVersion else { throw CompanyVPNError.admission("分流紀錄版本不支援") }
            if value.schemaVersion == 2 {
                guard value.session.routingEvidence == nil, value.session.profile.directIPv4.isEmpty,
                      !value.session.addedRoutes.contains(where: { $0.nextHopKind != nil }) else { throw CompanyVPNError.admission("分流紀錄不可降級") }
            } else if value.session.phase == .active || value.session.phase == .applying {
                guard value.session.routingEvidence != nil else { throw CompanyVPNError.admission("分流紀錄缺少完整路由證據") }
            }
            return value.session
        }
        let session = try JSONDecoder().decode(ExternalVPNSession.self, from: data)
        guard session.company == nil, session.journalVersion == nil, session.routingEvidence == nil, session.profile.directIPv4.isEmpty, !session.addedRoutes.contains(where: { $0.nextHopKind != nil }) else { throw CompanyVPNError.admission("舊版紀錄不能包含公司連線所有權") }
        return session
    }
    static func encode(_ session: ExternalVPNSession) throws -> Data {
        if session.journalVersion == 3 {
            guard (session.phase != .active && session.phase != .applying) || session.routingEvidence != nil else {
                throw CompanyVPNError.admission("分流紀錄缺少完整路由證據")
            }
            return try JSONEncoder().encode(Self(schemaVersion: 3, session: session))
        }
        guard session.routingEvidence == nil, session.profile.directIPv4.isEmpty,
              !session.addedRoutes.contains(where: { $0.nextHopKind != nil }) else { throw CompanyVPNError.admission("完整路由證據不得降級") }
        if session.journalVersion == 2 { return try JSONEncoder().encode(Self(schemaVersion: 2, session: session)) }
        guard session.company == nil, session.journalVersion == nil else { throw CompanyVPNError.admission("公司連線紀錄不得降級") }
        return try JSONEncoder().encode(session)
    }
}

enum CompanyVPNPlanner {
    static func overlaps(_ a: ExternalIPv4Network, _ b: ExternalIPv4Network) -> Bool { a.contains(b) || b.contains(a) }

    static func validateExternal(_ session: ExternalVPNSession, _ current: ExternalNetworkSnapshot) throws {
        guard session.phase == .active, session.profile.dnsMode == .preserveVPN,
              ExternalVPNPlanner.sameBoot(session.baseline, current), current.interface == session.baseline.interface,
              current.address == session.baseline.address, current.gateway == session.baseline.gateway,
              current.localNetwork == session.baseline.localNetwork,
              try ExternalVPNPlanner.tunnel(in: current) == session.tunnel,
              session.tunnel != nil, session.preservedDNS?.matches(current) == true else {
            throw CompanyVPNError.admission("F5 分流或原 DNS 已變更，請先檢查並復原；未開始公司連線")
        }
        guard session.journalVersion == 3, let evidence = session.routingEvidence else {
            throw CompanyVPNError.admission("舊分流紀錄缺少完整路由證據，請停止後重新準備")
        }
        try evidence.validate(session, current: current)
    }

    static func admit(_ policy: CompanyPolicy, session: ExternalVPNSession, current: ExternalNetworkSnapshot) throws {
        try validateExternal(session, current)
        let reserved = try session.profile.protectedNetworks.map(ExternalIPv4Network.init)
        let direct = try session.profile.directIPv4.map { ExternalIPv4Network(address: try ExternalIPv4($0), prefix: 32) }
        let dns = try current.dns.flatMap(\.servers).map { ExternalIPv4Network(address: try ExternalIPv4($0), prefix: 32) }
        for selector in policy.selectors {
            guard !([current.localNetwork] + reserved + dns + direct).contains(where: { overlaps(selector, $0) }) else {
                throw CompanyVPNError.admission("公司網段與本機、保留的 F5 網段或 DNS 重疊")
            }
            for route in current.routes where route.flags.contains("U") && !route.flags.contains("I") && overlaps(selector, route.network) {
                if session.addedRoutes.contains(where: { $0.network == route.network && $0.gateway == route.gateway && $0.interface == route.interface && route.isOwned }) {
                    if route.network.prefix >= selector.prefix { throw CompanyVPNError.requiresReprepare }
                } else if route.network.prefix >= 2 {
                    let existingPhysical = route.interface == session.baseline.interface &&
                        route.gateway == session.baseline.gateway && route.network.prefix < selector.prefix &&
                        session.baseline.routes.contains(route)
                    guard existingPhysical else {
                        throw CompanyVPNError.admission("公司網段與既有細部路由重疊，無法確認歸屬")
                    }
                }
            }
        }
        try underlay(policy.peer, session: session, current: current)
    }

    static func underlay(_ peer: ExternalIPv4, session: ExternalVPNSession, current: ExternalNetworkSnapshot) throws {
        let routes = winners(peer, routes: current.routes)
        guard !routes.isEmpty, routes.allSatisfy({ $0.isUsable && $0.interface == session.baseline.interface && $0.gateway == session.baseline.gateway }) else {
            throw CompanyVPNError.requiresReprepare
        }
    }

    // 與 charon 原生形狀相同：/32 以實體閘道為 gateway、輸出介面為公司 utun；其餘為直連公司 utun。都帶 proto1，F5 不會刪除。
    static func routes(_ policy: CompanyPolicy, identity: CompanyIdentity, gateway: String) -> [ExternalRoute] {
        policy.selectors.map { selector in
            selector.prefix == 32
                ? ExternalRoute(network: selector, gateway: gateway, interface: identity.interface, flags: "UGHS1", nextHopKind: .gateway)
                : ExternalRoute(network: selector, gateway: identity.interface, interface: identity.interface, flags: "US1", nextHopKind: .directInterface)
        }
    }

    // 停止後仍存在的公司路由。只要同網段還有 proto1 就算殘留，不論介面；路由表裡找不到任何經原本實體閘道的路由時視為讀取不完整。
    static func remainingRoutes(_ owned: [ExternalRoute], current: ExternalNetworkSnapshot, baseline: ExternalNetworkSnapshot) throws -> [ExternalRoute] {
        guard current.routes.contains(where: { $0.interface == baseline.interface && $0.gateway == baseline.gateway && $0.isUsable }) else {
            throw CompanyVPNError.recovery("無法讀取完整路由表，未確認公司路由已移除")
        }
        return current.routes.filter { actual in actual.isOwned && owned.contains { $0.network == actual.network } }
    }

    static func winners(_ ip: ExternalIPv4, routes: [ExternalRoute]) -> [ExternalRoute] {
        let matches = routes.filter { $0.flags.contains("U") && !$0.flags.contains("I") && $0.network.contains(ip) }
        guard let prefix = matches.map(\.network.prefix).max() else { return [] }
        return matches.filter { $0.network.prefix == prefix }
    }

    static func coverage(_ policy: CompanyPolicy, identity: CompanyIdentity, session: ExternalVPNSession, current: ExternalNetworkSnapshot) throws -> [ExternalIPv4] {
        guard identity.interface.range(of: #"^utun[0-9]{1,4}$"#, options: .regularExpression) != nil,
              identity.interface != session.tunnel, identity.peer == policy.peer,
              identity.local.description == session.baseline.address,
              identity.ikeID > 0, identity.childID > 0, !identity.daemon.isEmpty,
              try CompanyPolicy.normalized(identity.selectors.map(\.description)) == policy.selectors else {
            throw CompanyVPNError.admission("公司 SA、虛擬位址、協商網段或獨立通道無法驗證")
        }
        var probes: [ExternalIPv4] = []
        for selector in policy.selectors {
            let start = UInt64(selector.address.value)
            let end = start + (UInt64(1) << (32 - selector.prefix))
            var boundaries: Set<UInt64> = [start, end]
            for route in current.routes where overlaps(selector, route.network) {
                let lo = UInt64(route.network.address.value)
                let hi = lo + (UInt64(1) << (32 - route.network.prefix))
                if lo > start && lo < end { boundaries.insert(lo) }
                if hi > start && hi < end { boundaries.insert(hi) }
            }
            guard probes.count + boundaries.count <= 4096 else { throw CompanyVPNError.admission("公司路由區間超過驗證上限") }
            for boundary in boundaries.sorted().dropLast() {
                let ip = ExternalIPv4(value: UInt32(boundary))
                let routes = winners(ip, routes: current.routes)
                guard !routes.isEmpty, routes.allSatisfy({ $0.isUsable && $0.interface == identity.interface }) else {
                    throw CompanyVPNError.admission("公司通道未涵蓋全部網段，已取消公司連線")
                }
                probes.append(ip)
            }
        }
        return probes
    }
}

protocol CompanyVPNRuntime: ExternalVPNRuntime {
    func beginCompanyRecovery()
    func companyPolicy(slot: Int, revision: String?) throws -> CompanyPolicy
    func companyIdle() throws
    func companyPrepare(_ policy: CompanyPolicy) throws -> String
    func companyInitiate(_ policy: CompanyPolicy) throws
    func companyIdentity(_ policy: CompanyPolicy) throws -> CompanyIdentity
    func companyAddRoute(_ route: ExternalRoute) throws
    func companyStop(_ lease: CompanyLease) throws
    func companyRoutesAbsent(_ lease: CompanyLease, baseline: ExternalNetworkSnapshot) throws
    func companyNormalMode() throws
    func verifyLookup(_ ip: ExternalIPv4, interface: String, gateway: String?) throws
}

extension CompanyVPNRuntime {
    func beginCompanyRecovery() {}
}

final class CompanyVPNEngine {
    private let runtime: CompanyVPNRuntime
    init(runtime: CompanyVPNRuntime) { self.runtime = runtime }

    func up(_ original: ExternalVPNSession, slot: Int, revision: String?) throws -> ExternalVPNSession {
        var session = original
        if session.company != nil { session = try down(session) }
        let policy = try runtime.companyPolicy(slot: slot, revision: revision)
        let current = try runtime.snapshot(baseline: session.baseline)
        try CompanyVPNPlanner.admit(policy, session: session, current: current)
        try runtime.verifyLookup(policy.peer, interface: session.baseline.interface, gateway: session.baseline.gateway)
        try runtime.companyIdle()
        session.journalVersion = max(session.journalVersion ?? 2, 2)
        session.company = CompanyLease(id: UUID(), policy: policy, state: .admitting)
        try runtime.save(session)
        do {
            session.company?.daemon = try runtime.companyPrepare(policy)
            try runtime.save(session)
            try runtime.companyInitiate(policy)
            let identity = try runtime.companyIdentity(policy)
            session.company?.identity = identity
            let routes = CompanyVPNPlanner.routes(policy, identity: identity, gateway: session.baseline.gateway)
            session.company?.routes = routes
            try runtime.save(session)
            for route in routes { try runtime.companyAddRoute(route) }
            try verify(session)
            session.company?.state = .active
            try runtime.save(session)
            return session
        } catch {
            runtime.beginCompanyRecovery()
            do { _ = try down(session) }
            catch { throw CompanyVPNError.recovery("公司連線未能完全停止；已保留 F5 分流與復原紀錄") }
            throw error
        }
    }

    func tick(_ session: ExternalVPNSession) throws -> ExternalVPNSession {
        guard let lease = session.company else { return session }
        do {
            guard lease.state == .active else { throw CompanyVPNError.recovery("公司交易尚未完成") }
            try verify(session)
            return session
        } catch {
            runtime.beginCompanyRecovery()
            var cleaned = try down(session)
            cleaned.message = "公司通道已停止：" + error.localizedDescription
            try runtime.save(cleaned)
            return cleaned
        }
    }

    func verify(_ session: ExternalVPNSession) throws {
        guard let lease = session.company, let identity = lease.identity else { throw CompanyVPNError.admission("公司連線仍待復原") }
        guard identity.daemon == lease.daemon else { throw CompanyVPNError.admission("公司 daemon 與本次 lease 不符") }
        let observed = try runtime.companyIdentity(lease.policy)
        guard observed == identity else { throw CompanyVPNError.admission("公司 SA 已變更，需重新驗證連線") }
        let current = try runtime.snapshot(baseline: session.baseline)
        try CompanyVPNPlanner.validateExternal(session, current)
        try CompanyVPNPlanner.underlay(lease.policy.peer, session: session, current: current)
        try runtime.verifyLookup(lease.policy.peer, interface: session.baseline.interface, gateway: session.baseline.gateway)
        let probes = try CompanyVPNPlanner.coverage(lease.policy, identity: identity, session: session, current: current)
        for ip in probes { try runtime.verifyLookup(ip, interface: identity.interface, gateway: nil) }
    }

    func down(_ input: ExternalVPNSession) throws -> ExternalVPNSession {
        var session = input
        guard var lease = session.company else { return session }
        lease.state = .releasing; session.company = lease
        try runtime.save(session)
        do {
            try runtime.companyStop(lease)
            try runtime.companyRoutesAbsent(lease, baseline: session.baseline)
            try runtime.companyNormalMode()
            session.company = nil
            try runtime.save(session)
            return session
        } catch {
            session.company?.state = .recoveryRequired
            try runtime.save(session)
            throw CompanyVPNError.recovery("公司通道無法確認已停止，請重試；F5 分流路由保持原狀")
        }
    }
}

// Parse only the generated profile and the documented swanctl text surface. Unknown shapes fail closed.
enum CompanyVPNText {
    static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range == NSRange(text.startIndex..., in: text) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
    static func selectors(_ text: String) throws -> [ExternalIPv4Network] {
        try CompanyPolicy.normalized(text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { value in
            let text = String(value)
            return text.contains("/") ? text : text + "/32"
        })
    }
    static func isolatedConfiguration(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw CompanyVPNError.admission("公司設定編碼錯誤") }
        let connectionKeys: Set<String> = ["version", "remote_addrs", "proposals", "rekey_time", "vips", "mobike", "fragmentation", "dpd_delay"]
        let childKeys: Set<String> = ["local_ts", "remote_ts", "esp_proposals", "rekey_time", "dpd_action", "start_action", "close_action"]
        var path: [String] = []
        var sections = Set<String>()
        var fields: [String: Set<String>] = [:]
        var lines: [String] = []
        var includeSeen = false
        func fail() -> CompanyVPNError { .admission("公司設定包含未知結構；雙 VPN 僅接受 App 產生的明確分流設定") }
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "include conf.d/*.conf", path.isEmpty, !includeSeen {
                includeSeen = true
                continue
            }
            if let opening = captures(#"([A-Za-z0-9_-]+)\s*\{"#, line) {
                let name = opening[0]
                let valid = (path.isEmpty && name == "connections") ||
                    (path == ["connections"] && ["vpn1", "vpn2", "vpn3"].contains(name)) ||
                    (path.count == 2 && ["local", "remote", "children"].contains(name)) ||
                    (path.count == 3 && path.last == "children" && name == "corp")
                guard valid else { throw fail() }
                path.append(name)
                guard sections.insert(path.joined(separator: "/")).inserted else { throw fail() }
            } else if line == "}" {
                guard !path.isEmpty else { throw fail() }
                path.removeLast()
            } else {
                guard let assignment = captures(#"([a-z_]+)\s*=\s*([A-Za-z0-9.,@% /_=-]+)"#, line) else { throw fail() }
                let key = assignment[0], value = assignment[1].trimmingCharacters(in: .whitespaces)
                let allowed: Set<String>
                switch path.count {
                case 2: allowed = connectionKeys
                case 3: allowed = path.last == "local" ? ["auth", "eap_id"] : path.last == "remote" ? ["auth", "id"] : []
                case 4: allowed = childKeys
                default: allowed = []
                }
                let location = path.joined(separator: "/")
                guard allowed.contains(key), fields[location, default: []].insert(key).inserted else { throw fail() }
                let fixed = ["version": "2", "vips": "0.0.0.0", "mobike": "no", "fragmentation": "yes", "local_ts": "dynamic", "dpd_action": "clear", "start_action": "none", "close_action": "none", "id": "%any"]
                if let expected = fixed[key], value != expected { throw fail() }
                if key == "auth", value != (path.last == "local" ? "eap" : "psk") { throw fail() }
                if key == "remote_addrs" { _ = try ExternalIPv4(value) }
                if key == "remote_ts" { _ = try selectors(value) }
                if ["rekey_time", "dpd_delay"].contains(key), captures(#"([0-9]+s)"#, value) == nil { throw fail() }
                if key == "eap_id", captures(#"([A-Za-z0-9._@-]+)"#, value) == nil { throw fail() }
            }
            lines.append(line)
        }
        guard path.isEmpty, includeSeen, sections.contains("connections") else { throw fail() }
        let connections = sections.filter { $0.split(separator: "/").count == 2 }
        guard !connections.isEmpty, connections.count <= 3 else { throw fail() }
        for base in connections {
            guard fields[base] == connectionKeys, fields[base + "/local"] == ["auth", "eap_id"],
                  fields[base + "/remote"] == ["auth", "id"], fields[base + "/children/corp"] == childKeys else { throw fail() }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func policy(_ data: Data, slot: Int, revision: String?) throws -> CompanyPolicy {
        _ = try isolatedConfiguration(data)
        let digest = CompanyPolicy.digest(data)
        guard revision == nil || revision == digest, let text = String(data: data, encoding: .utf8) else {
            throw CompanyVPNError.admission("公司設定已變更，請重新載入後再連線")
        }
        var path: [String] = []; var peers: [String] = []; var ranges: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let fields = captures(#"([A-Za-z0-9_-]+)\s*\{"#, line) { path.append(fields[0]); continue }
            if line == "}" { guard !path.isEmpty else { throw CompanyVPNError.admission("公司設定結構無法辨識") }; path.removeLast(); continue }
            if path == ["connections", "vpn\(slot)"], let fields = captures(#"remote_addrs\s*=\s*(\S+)"#, line) { peers.append(fields[0]) }
            if path == ["connections", "vpn\(slot)", "children", "corp"], let fields = captures(#"remote_ts\s*=\s*(.+)"#, line) { ranges.append(fields[0]) }
        }
        guard path.isEmpty, peers.count == 1, ranges.count == 1 else { throw CompanyVPNError.admission("公司設定不符合可驗證的 split profile") }
        return try CompanyPolicy(revision: digest, slot: slot, selectors: selectors(ranges[0]).map(\.description), peer: peers[0])
    }
    static func validateLoaded(_ text: String, policy: CompanyPolicy) throws {
        var block: [String] = []; var selected = false
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if !line.hasPrefix(" ") { selected = line.hasPrefix("vpn\(policy.slot): IKEv2,") }
            if selected { block.append(line) }
        }
        let peers = block.compactMap { captures(#"  remote: ([0-9.]+)\[[0-9]+\]"#, $0)?.first }
        let remotes = block.compactMap { captures(#"    remote: (.+)"#, $0)?.first }
        let children = block.filter { captures(#"  [A-Za-z0-9_-]+: .+"#, $0) != nil && !$0.hasPrefix("  remote:") && !$0.hasPrefix("  local:") }
        guard peers == [policy.peer.description], remotes.count == 1, children.count == 1,
              children[0].hasPrefix("  corp: TUNNEL,"), try selectors(remotes[0]) == policy.selectors else {
            throw CompanyVPNError.admission("實際載入的公司設定與已核准的網段不一致")
        }
    }
    static func identity(_ text: String, policy: CompanyPolicy, daemon: String, interfaces: [String: [String]]) throws -> CompanyIdentity {
        let lines = text.split(separator: "\n").map(String.init)
        let headers = lines.filter { !$0.hasPrefix(" ") }
        guard headers.count == 1,
              let ike = captures("vpn\(policy.slot): #([0-9]+), ESTABLISHED, IKEv2, .+", headers[0]), let ikeID = Int(ike[0]) else {
            throw CompanyVPNError.admission("公司 IKE SA 無法唯一辨識")
        }
        let child = lines.compactMap { captures(#"  corp: #([0-9]+), reqid [0-9]+, INSTALLED, TUNNEL(?:-in-UDP)?, ESP:.+"#, $0) }
        let childHeaders = lines.filter { captures(#"  [^ ]+: #[0-9]+,.*"#, $0) != nil }
        let local = lines.compactMap { captures(#"  local  '.*' @ ([0-9.]+)\[[0-9]+\] \[([0-9.]+)\]"#, $0) }
        let remote = lines.compactMap { captures(#"  remote '.*' @ ([0-9.]+)\[[0-9]+\](?: .*)?"#, $0) }
        let ranges = lines.compactMap { captures(#"    remote (.+)"#, $0)?.first }
        let locals = lines.compactMap { captures(#"    local  (.+)"#, $0)?.first }
        guard child.count == 1, childHeaders.count == 1, let childID = Int(child[0][0]), local.count == 1,
              remote.count == 1, ranges.count == 1, locals.count == 1 else { throw CompanyVPNError.admission("公司 CHILD SA 或虛擬位址無法驗證") }
        let vip = try ExternalIPv4(local[0][1])
        let owners = interfaces.filter { $0.value.contains(vip.description) }.map(\.key)
        guard owners.count == 1, try selectors(locals[0]) == [ExternalIPv4Network(address: vip, prefix: 32)] else {
            throw CompanyVPNError.admission("公司虛擬位址沒有唯一的本機通道")
        }
        return CompanyIdentity(daemon: daemon, ikeID: ikeID, childID: childID, vip: vip, interface: owners[0],
                               peer: try ExternalIPv4(remote[0][0]), local: try ExternalIPv4(local[0][0]), selectors: try selectors(ranges[0]))
    }
    static func plugins(_ text: String) throws -> Set<String> {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let found = lines.filter { $0.hasPrefix("loaded plugins:") }
        guard found.count == 1 else { throw CompanyVPNError.admission("無法驗證 strongSwan 實際載入的外掛") }
        let plugins = Set(found[0].dropFirst("loaded plugins:".count).split(whereSeparator: \.isWhitespace).map(String.init))
        guard !plugins.isEmpty else { throw CompanyVPNError.admission("strongSwan 未回報外掛") }
        return plugins
    }
}
