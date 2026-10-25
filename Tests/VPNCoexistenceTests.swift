import Foundation

var pass = 0, fail = 0
func check(_ name: String, _ value: Bool) { print((value ? "✅ " : "❌ ") + name); value ? (pass += 1) : (fail += 1) }
func rejects(_ action: () throws -> Any) -> Bool { do { _ = try action(); return false } catch { return true } }
func net(_ text: String) -> ExternalIPv4Network { try! ExternalIPv4Network(text) }
func ip(_ text: String) -> ExternalIPv4 { try! ExternalIPv4(text) }
func route(_ cidr: String, _ interface: String = "en0", _ gateway: String = "192.0.2.1", _ flags: String = "UGS1") -> ExternalRoute {
    ExternalRoute(network: net(cidr), gateway: gateway, interface: interface, flags: flags)
}
let revision = String(repeating: "a", count: 64)
func policy(_ selectors: [String] = ["203.0.113.8/32", "10.10.10.0/24"]) -> CompanyPolicy {
    try! CompanyPolicy(revision: revision, slot: 1, selectors: selectors, peer: "198.51.100.8")
}
func fixtureSnapshot() -> ExternalNetworkSnapshot {
    let dns = ExternalDNSEntry(key: "State:/Network/Service/f5/DNS", interface: "utun5", value: try! PropertyListSerialization.data(fromPropertyList: ["ServerAddresses": ["198.51.100.53"]], format: .binary, options: 0))
    return ExternalNetworkSnapshot(bootID: "boot-a", interface: "en0", address: "192.0.2.9", gateway: "192.0.2.1", localNetwork: net("192.0.2.0/24"), routes: [route("0.0.0.0/1", "utun5", "link#5", "UGS"), route("128.0.0.0/1", "utun5", "link#5", "UGS"), route("203.0.113.0/24"), route("198.51.100.8/32"), route("192.0.2.0/24", "en0", "link#1", "UCS")] + ExternalVPNPlanner.publicNetworks(excluding: []).map { route($0.description) }, dns: [dns], ipv6TunnelDefault: false, interfaceIndex: 1)
}
func session() -> ExternalVPNSession {
    let current = fixtureSnapshot()
    var result = ExternalVPNSession(owner: 501, baseline: current, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
    result.phase = .active; result.tunnel = "utun5"
    result.addedRoutes = current.routes.filter(\.isOwned)
    result.preservedDNS = ExternalDNSState(current)
    result.journalVersion = 3
    result.routingEvidence = ExternalVPNRoutingEvidence(publicNetworks: result.addedRoutes.map(\.network), directHosts: [], borrowedRoutes: result.addedRoutes, physicalInterfaceIndex: 1)
    return result
}
func identity(_ selectors: [ExternalIPv4Network]? = nil, interface: String = "utun8", peer: String = "198.51.100.8", local: String = "192.0.2.9") -> CompanyIdentity {
    CompanyIdentity(daemon: "own-daemon", ikeID: 1, childID: 2, vip: ip("10.99.0.8"), interface: interface, peer: ip(peer), local: ip(local), selectors: selectors ?? policy().selectors)
}
struct LegacyLease: Codable { let id: UUID; let policy: CompanyPolicy; var state: CompanyLeaseState; var identity: CompanyIdentity?; var daemon: String? }
final class Runtime: CompanyVPNRuntime {
    var current = fixtureSnapshot()
    var saved: ExternalVPNSession? = session()
    var history: [ExternalVPNSession] = []
    var failAt: String?
    var stopFails = false
    var calls: [String] = []
    var lookupIPs: [ExternalIPv4] = []
    var observedIdentity = identity()
    var failSaveAt: Int?
    var saves = 0
    var dnsWrites = 0
    var routeRemoves = 0
    func event(_ name: String) throws {
        calls.append(name)
        if failAt == name { throw CompanyVPNError.admission("fixture " + name) }
    }
    func snapshot(baseline: ExternalNetworkSnapshot?) throws -> ExternalNetworkSnapshot { try event("snapshot"); return current }
    func save(_ value: ExternalVPNSession?) throws {
        saves += 1
        if saves == failSaveAt { throw CompanyVPNError.admission("journal write failed") }
        saved = value; if let value { history.append(value) }
    }
    func add(_ value: ExternalRoute) throws { current.routes.append(value) }
    func remove(_ value: ExternalRoute) throws { routeRemoves += 1; current.routes.removeAll { $0 == value } }
    func dnsValue(_ key: String) throws -> Data? { current.dns.first { $0.key == key }?.value }
    func setDNS(_ key: String, value: Data) throws { dnsWrites += 1 }
    func companyPolicy(slot: Int, revision: String?) throws -> CompanyPolicy { try event("policy"); return policy() }
    func companyIdle() throws { try event("idle") }
    func companyPrepare(_ policy: CompanyPolicy) throws -> String { try event("prepare"); return "own-daemon" }
    var stopLeavesRoutes = false
    var addFailsAt: Int?
    var routeAdds: [ExternalRoute] = []
    func companyInitiate(_ policy: CompanyPolicy) throws { try event("initiate") }
    func companyAddRoute(_ value: ExternalRoute) throws {
        try event("company-add")
        if addFailsAt == routeAdds.count + 1 { throw CompanyVPNError.admission("fixture add") }
        routeAdds.append(value); current.routes.append(value)
    }
    func companyRoutesAbsent(_ lease: CompanyLease, baseline: ExternalNetworkSnapshot) throws {
        try event("absent")
        guard try CompanyVPNPlanner.remainingRoutes(lease.routes ?? [], current: current, baseline: baseline).isEmpty else {
            throw CompanyVPNError.recovery("fixture routes remain")
        }
    }
    func companyIdentity(_ policy: CompanyPolicy) throws -> CompanyIdentity { try event("identity"); return observedIdentity }
    func companyStop(_ lease: CompanyLease) throws {
        try event("stop")
        if stopFails { throw CompanyVPNError.recovery("fixture cannot stop") }
        if !stopLeavesRoutes { current.routes.removeAll { $0.interface == "utun8" } }
    }
    func companyNormalMode() throws { try event("normal") }
    func verifyLookup(_ ip: ExternalIPv4, interface: String, gateway: String?) throws { lookupIPs.append(ip); try event(interface == "en0" ? "peer-lookup" : "company-lookup") }
    func beginCompanyRecovery() { calls.append("recovery") }
    func releaseCompany(_ input: ExternalVPNSession) throws -> ExternalVPNSession { try CompanyVPNEngine(runtime: self).down(input) }
}

check("接納較細公開 /32 與私人 /24", !rejects { try CompanyVPNPlanner.admit(policy(), session: session(), current: fixtureSnapshot()) })
for ranges in [["0.0.0.0/0"], ["0.0.0.0/1"], ["0.0.0.0/2", "64.0.0.0/2"], ["::/64"], [], ["203.0.113.8-203.0.113.9"]] {
    check("拒絕不支援的 selector \(ranges)", rejects { try CompanyPolicy(revision: revision, slot: 1, selectors: ranges, peer: "198.51.100.8") })
}
check("去重、涵蓋與相鄰 selector 正規化", try! CompanyPolicy.normalized(["10.10.10.128/25", "10.10.10.0/25", "10.10.10.4/32"]) == [net("10.10.10.0/24")])
for (label, extra) in [("相同 owned prefix", route("203.0.113.8/32")), ("foreign 路由", route("203.0.113.8/32", "utun9", "link#9", "US"))] {
    var state = fixtureSnapshot(); state.routes.append(extra)
    var record = session(); if extra.isOwned { record.addedRoutes.append(extra) }
    check("拒絕" + label, rejects { try CompanyVPNPlanner.admit(policy(), session: record, current: state) })
}
var baselineRoutes = session()
baselineRoutes.addedRoutes = []
check("原本已有更粗的實體路由不必認領或改動", !rejects { try CompanyVPNPlanner.admit(policy(), session: baselineRoutes, current: fixtureSnapshot()) })
var newForeign = fixtureSnapshot(); newForeign.routes.append(route("10.10.0.0/16"))
check("未在 baseline 的 foreign 路由仍拒絕", rejects { try CompanyVPNPlanner.admit(policy(), session: baselineRoutes, current: newForeign) })
var foreignGateway = fixtureSnapshot(); foreignGateway.routes[2] = route("203.0.113.0/24", "en0", "192.0.2.254")
check("相同網段但不同 gateway 不承認為 baseline 路由", rejects { try CompanyVPNPlanner.admit(policy(), session: baselineRoutes, current: foreignGateway) })
var finer = fixtureSnapshot(); finer.routes.append(route("10.10.10.4/32"))
var finerSession = session(); finerSession.addedRoutes.append(finer.routes.last!)
check("拒絕 owned 更細路由", rejects { try CompanyVPNPlanner.admit(policy(), session: finerSession, current: finer) })
for range in ["192.0.2.0/24", "198.51.100.53/32"] {
    check("拒絕 LAN 或 F5 DNS 重疊", rejects { try CompanyVPNPlanner.admit(policy([range]), session: session(), current: fixtureSnapshot()) })
}
var reserved = session(); reserved = ExternalVPNSession(owner: 501, baseline: reserved.baseline, profile: ExternalVPNProfile(protectedNetworks: ["10.10.10.0/24"], dnsMode: .preserveVPN), phase: .active, tunnel: "utun5", addedRoutes: reserved.addedRoutes, preservedDNS: reserved.preservedDNS)
check("拒絕明確外部 VPN 保留範圍", rejects { try CompanyVPNPlanner.admit(policy(), session: reserved, current: fixtureSnapshot()) })
var wrongPeer = fixtureSnapshot(); wrongPeer.routes.removeAll { $0.network == net("198.51.100.8/32") }
check("peer 走 F5 時拒絕且不新增 pin", rejects { try CompanyVPNPlanner.underlay(policy().peer, session: session(), current: wrongPeer) })
for changed in ["boot", "dns", "route", "interface", "ipv6"] {
    var state = fixtureSnapshot()
    switch changed {
    case "boot": state.bootID = "boot-b"
    case "dns": state.dns = []
    case "route": state.routes.removeAll { $0.network == net("198.51.100.8/32") }
    case "interface": state.interface = "en1"
    default: state.ipv6TunnelDefault = true
    }
    check("F5 \(changed) 漂移拒絕接納", rejects { try CompanyVPNPlanner.validateExternal(session(), state) })
}
var covered = fixtureSnapshot(); covered.routes += policy().selectors.map { route($0.description, "utun8", "link#8", "US") }
check("完整 TS 每區間核對公司出口", (try? CompanyVPNPlanner.coverage(policy(), identity: identity(), session: session(), current: covered))?.count == 2)
covered.routes.append(route("10.10.10.128/26", "utun9", "link#9", "US"))
check("起點正確但中段走其他 VPN 必須失敗", rejects { try CompanyVPNPlanner.coverage(policy(), identity: identity(), session: session(), current: covered) })
for actual in [identity(interface: "utun5"), identity(interface: "en0"), identity(peer: "198.51.100.9"), identity(local: "192.0.2.10"), identity([net("10.10.10.0/25")])] {
    check("拒絕錯誤 SA 身分或縮限 TS", rejects { try CompanyVPNPlanner.coverage(policy(), identity: actual, session: session(), current: covered) })
}
let good = Runtime(), engine = CompanyVPNEngine(runtime: Runtime())
let active = try! CompanyVPNEngine(runtime: good).up(session(), slot: 1, revision: revision)
check("公司交易成功才標記 active", active.company?.state == .active && active.journalVersion == 3)
check("company up 不撤除 F5 路由、不寫 DNS", good.routeRemoves == 0 && good.dnsWrites == 0 && active.addedRoutes == session().addedRoutes)
check("peer 與完整 TS 均實際 lookup", good.lookupIPs.contains(ip("10.10.10.0")) && good.lookupIPs.filter { $0 == policy().peer }.count == 2)
check("第一筆公司 journal 是 admitting", good.history.first?.company?.state == .admitting)
check("合法公司更細 selector 不會誤判成外網漂移", !rejects { try CompanyVPNPlanner.validateExternal(active, good.current) })
let duringCompany = try! ExternalVPNEngine(runtime: good).tick(active)
check("公司 active 時 external tick 保留合法公司通道", duringCompany.phase == .active && duringCompany.company?.state == .active)
var unknownCompanyHole = good.current
unknownCompanyHole.routes.append(route("203.0.113.8/32", "utun9", "link#9", "US"))
check("公司 selector 內等長外部通道不能被豁免", rejects { try CompanyVPNPlanner.validateExternal(active, unknownCompanyHole) })
var exceptionSession = session()
exceptionSession = ExternalVPNSession(owner: exceptionSession.owner, baseline: exceptionSession.baseline, profile: ExternalVPNProfile(dnsMode: .preserveVPN, directIPv4: ["203.0.113.8"]), phase: .active, tunnel: exceptionSession.tunnel, addedRoutes: exceptionSession.addedRoutes, preservedDNS: exceptionSession.preservedDNS, journalVersion: 3, routingEvidence: ExternalVPNRoutingEvidence(publicNetworks: exceptionSession.routingEvidence!.publicNetworks, directHosts: [net("203.0.113.8/32")], borrowedRoutes: exceptionSession.routingEvidence!.borrowedRoutes, physicalInterfaceIndex: 1))
check("指定直連 IP 與公司 selector 衝突時拒絕准入", rejects { try CompanyVPNPlanner.admit(policy(), session: exceptionSession, current: fixtureSnapshot()) })
exceptionSession.company = active.company
check("既有 company lease 不能豁免指定直連 IP", rejects { try CompanyVPNPlanner.validateExternal(exceptionSession, good.current) })
let lanPolicy = policy(["192.0.2.0/24"])
var lanLeaseSession = session()
let lanIdentity = identity(lanPolicy.selectors)
lanLeaseSession.company = CompanyLease(id: UUID(), policy: lanPolicy, state: .active, identity: lanIdentity, daemon: lanIdentity.daemon)
var lanLeaseRoutes = fixtureSnapshot()
lanLeaseRoutes.routes.removeAll { $0.network == net("192.0.2.0/24") }
lanLeaseRoutes.routes.append(route("192.0.2.0/24", "utun8", "link#8", "US"))
check("有效公司 lease 也不能豁免 LAN 保護", rejects { try CompanyVPNPlanner.validateExternal(lanLeaseSession, lanLeaseRoutes) })
let down = try! CompanyVPNEngine(runtime: good).down(active)
check("company down 只清自己的通道，恢復正常 daemon 模式", down.company == nil && good.current.routes == fixtureSnapshot().routes && good.calls.suffix(3) == ["stop", "absent", "normal"])
check("公司路由由 Root 以 proto1 建立，charon 不裝路由", good.routeAdds.count == 2 && good.routeAdds.allSatisfy { $0.isOwned && $0.interface == "utun8" })
check("公司 /32 走實體閘道但輸出介面為公司 utun", good.routeAdds.first { $0.network == net("203.0.113.8/32") }.map { $0.gateway == "192.0.2.1" && $0.kind == .gateway && $0.flags.contains("H") } == true)
check("公司子網為直連公司 utun", good.routeAdds.first { $0.network == net("10.10.10.0/24") }.map { $0.kind == .directInterface && !$0.flags.contains("G") } == true)
let firstAdd = good.calls.firstIndex(of: "company-add")!
check("新增公司路由前已保存完整路由意圖", good.history.contains { $0.company?.routes?.count == 2 && $0.company?.routes == good.routeAdds && $0.company?.state == .admitting } && good.calls[..<firstAdd].contains("identity"))
let leftover = Runtime(); let leftoverActive = try! CompanyVPNEngine(runtime: leftover).up(session(), slot: 1, revision: revision); leftover.stopLeavesRoutes = true
check("停止後公司路由仍在時不以目的地刪除，保留復原", rejects { try CompanyVPNEngine(runtime: leftover).down(leftoverActive) } && leftover.saved?.company?.state == .recoveryRequired && leftover.routeRemoves == 0 && !leftover.calls.contains("normal"))
for failing in [1, 2] {
    let partial = Runtime(); partial.addFailsAt = failing
    check("第 \(failing) 條公司路由新增失敗會停止公司並確認路由消失", rejects { try CompanyVPNEngine(runtime: partial).up(session(), slot: 1, revision: revision) } && partial.saved?.company == nil && !partial.current.routes.contains { $0.interface == "utun8" } && partial.calls.contains("absent") && partial.routeRemoves == 0)
}
let owned = CompanyVPNPlanner.routes(policy(), identity: identity(), gateway: "192.0.2.1")
var moved = fixtureSnapshot(); moved.routes.append(route("203.0.113.8/32", "en0", "192.0.2.1", "UGHS1"))
check("同網段 proto1 改掛其他介面仍算殘留", (try? CompanyVPNPlanner.remainingRoutes(owned, current: moved, baseline: fixtureSnapshot()))?.count == 1)
var reused = fixtureSnapshot(); reused.routes.append(route("10.10.10.0/24", "utun8", "utun8", "US1c"))
check("utun 名稱被重用時同網段 proto1 仍算殘留", (try? CompanyVPNPlanner.remainingRoutes(owned, current: reused, baseline: fixtureSnapshot()))?.count == 1)
var foreignSame = fixtureSnapshot(); foreignSame.routes.append(route("10.10.10.0/24", "utun9", "link#9", "US"))
check("同網段無標記的他人路由不算我方殘留", (try? CompanyVPNPlanner.remainingRoutes(owned, current: foreignSame, baseline: fixtureSnapshot()))?.isEmpty == true)
var emptyTable = fixtureSnapshot(); emptyTable.routes = []
check("讀不到經實體閘道的路由時不能判定已消失", rejects { try CompanyVPNPlanner.remainingRoutes(owned, current: emptyTable, baseline: fixtureSnapshot()) })
var legacyLease = active; legacyLease.company?.routes = nil
let legacyRuntime = Runtime(); legacyRuntime.current = good.current
check("舊 lease 沒有路由紀錄仍可停止", (try? CompanyVPNEngine(runtime: legacyRuntime).down(legacyLease))?.company == nil)
let leaseJSON = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(active.company!)) as! [String: Any]
check("公司路由意圖寫進 lease，舊版 decoder 會忽略此欄位", (leaseJSON["routes"] as? [Any])?.count == 2 && (try? JSONDecoder().decode(LegacyLease.self, from: JSONEncoder().encode(active.company!))) != nil)
for failure in ["policy", "snapshot", "idle", "peer-lookup", "prepare", "initiate", "identity", "company-lookup", "normal"] {
    let runtime = Runtime(); runtime.failAt = failure
    if failure == "normal" { runtime.failAt = "company-lookup"; runtime.stopFails = true }
    check("\(failure) 失敗回報拒絕", rejects { try CompanyVPNEngine(runtime: runtime).up(session(), slot: 1, revision: revision) })
    check("\(failure) 失敗保留全部 F5 路由和 DNS", runtime.routeRemoves == 0 && runtime.dnsWrites == 0 && runtime.saved?.addedRoutes == session().addedRoutes)
}
for saveNumber in 1...4 {
    let runtime = Runtime(); runtime.failSaveAt = saveNumber
    check("journal 第 \(saveNumber) 次寫入失敗可控", rejects { try CompanyVPNEngine(runtime: runtime).up(session(), slot: 1, revision: revision) })
    check("journal 失敗仍保留 F5", runtime.routeRemoves == 0 && runtime.dnsWrites == 0)
}
let stuck = Runtime(); let stuckActive = try! CompanyVPNEngine(runtime: stuck).up(session(), slot: 1, revision: revision); stuck.stopFails = true
check("公司停止失敗阻擋 external restore", rejects { try ExternalVPNEngine(runtime: stuck).restore(stuckActive) })
check("停止失敗保留 lease 與 F5 bypass", stuck.saved?.company?.state == .recoveryRequired && stuck.routeRemoves == 0)
let drift = Runtime(); let driftActive = try! CompanyVPNEngine(runtime: drift).up(session(), slot: 1, revision: revision)
drift.failAt = "company-lookup"
let afterDrift = try! CompanyVPNEngine(runtime: drift).tick(driftActive)
check("公司路由漂移先清公司，保留 F5", afterDrift.company == nil && drift.routeRemoves == 0)
let lostF5 = Runtime(); let lostActive = try! CompanyVPNEngine(runtime: lostF5).up(session(), slot: 1, revision: revision)
lostF5.current.routes.removeAll { $0.interface == "utun5" }
let stoppedCompany = try! CompanyVPNEngine(runtime: lostF5).tick(lostActive)
let restored = try! ExternalVPNEngine(runtime: lostF5).tick(stoppedCompany)
check("F5 消失時先停止公司再撤回 bypass", stoppedCompany.company == nil && restored.addedRoutes.isEmpty && lostF5.calls.contains("stop"))
let pending = Runtime(); var interrupted = session(); interrupted.journalVersion = 2; interrupted.company = CompanyLease(id: UUID(), policy: policy(), state: .admitting)
check("重啟後 pending lease 可復原", (try! CompanyVPNEngine(runtime: pending).tick(interrupted)).company == nil)
var legacy = session(); legacy.journalVersion = nil; legacy.routingEvidence = nil
let v1 = try! ExternalVPNJournal.encode(legacy)
check("v1 active 可讀並保留舊版本", try! ExternalVPNJournal.decode(v1).journalVersion == nil)
check("v1 active 不提供公司能力", ExternalVPNStatus(session: legacy).companyCapability == nil)
check("v1 active 無證據拒絕公司准入", rejects { try CompanyVPNPlanner.validateExternal(legacy, fixtureSnapshot()) })
var legacyCompany = active; legacyCompany.journalVersion = 2; legacyCompany.routingEvidence = nil
let v2 = try! ExternalVPNJournal.encode(legacyCompany)
check("v2 envelope 可讀", try! ExternalVPNJournal.decode(v2).company?.state == .active)
check("v2 active 不提供公司能力", ExternalVPNStatus(session: legacyCompany).companyCapability == nil)
check("v2 active 無證據拒絕公司准入", rejects { try CompanyVPNPlanner.validateExternal(legacyCompany, good.current) })
let v3 = try! ExternalVPNJournal.encode(active)
check("v3 evidence envelope 可往返", try! ExternalVPNJournal.decode(v3).routingEvidence == active.routingEvidence)
check("舊 flat decoder 無法誤讀 v3", rejects { try JSONDecoder().decode(ExternalVPNSession.self, from: v3) })
var downgrade = active; downgrade.journalVersion = 2
check("禁止 evidence 降級 v2", rejects { try ExternalVPNJournal.encode(downgrade) })
downgrade.journalVersion = nil
check("禁止 evidence 降級 v1", rejects { try ExternalVPNJournal.encode(downgrade) })
check("拒絕未知 journal 版本", rejects { try ExternalVPNJournal.decode(Data(String(decoding: v3, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":4").utf8)) })
var missingProof = active; missingProof.routingEvidence = nil
check("v3 active 缺少 evidence 不能寫入", rejects { try ExternalVPNJournal.encode(missingProof) })
var object = try! JSONSerialization.jsonObject(with: v3) as! [String: Any]
var nested = object["session"] as! [String: Any]; nested.removeValue(forKey: "routingEvidence"); object["session"] = nested
check("v3 active 缺少 evidence 不能讀成有效狀態", rejects { try ExternalVPNJournal.decode(JSONSerialization.data(withJSONObject: object)) })

let settings = VPNSettings(username: "test.user", gateways: ["198.51.100.8", "198.51.100.9", "198.51.100.10"], remoteTS: "203.0.113.8/32, 10.10.10.0/24")
let config = Data(ConfigStore.renderConf(settings).utf8)
check("真正 App 產生器設定可接納", !rejects { try CompanyVPNText.policy(config, slot: 1, revision: CompanyPolicy.digest(config)) })
check("root snapshot 不帶 include", !String(decoding: try! CompanyVPNText.isolatedConfiguration(config), as: UTF8.self).contains("include"))
check("App 舊 revision 拒絕", rejects { try CompanyVPNText.policy(config, slot: 1, revision: revision) })
for (before, after) in [("start_action = none", "start_action = start"), ("close_action = none", "close_action = restart"), ("include conf.d/*.conf", "include /tmp/inject.conf"), ("remote_ts =", "unknown_ts ="), ("corp {", "extra {"), ("mobike = no", "mobike = yes"), ("version = 2", "version = 2\n                    updown = /tmp/inject"), ("version = 2", "version = 2\n                    version = 2")] {
    let mutated = Data(String(decoding: config, as: UTF8.self).replacingOccurrences(of: before, with: after).utf8)
    check("拒絕設定變體 \(after)", rejects { try CompanyVPNText.policy(mutated, slot: 1, revision: nil) })
}
let loaded = """
vpn1: IKEv2, no reauthentication, rekeying every 86400s
  local:  %any[500]
  remote: 198.51.100.8[500]
  local EAP authentication:
    eap_id: test.user
  remote pre-shared key authentication:
    id: %any
  corp: TUNNEL, rekeying every 43200s, dpd action is clear
    local:  dynamic
    remote: 203.0.113.8/32 10.10.10.0/24
"""
check("已載入設定比對 peer 與 TS", !rejects { try CompanyVPNText.validateLoaded(loaded, policy: policy()) })
check("已載入額外 child 拒絕", rejects { try CompanyVPNText.validateLoaded(loaded + "\n  other: TUNNEL, no rekeying", policy: policy()) })
let sas = """
vpn1: #1, ESTABLISHED, IKEv2, abc_i* def_r
  local  'test.user' @ 192.0.2.9[4500] [10.99.0.8]
  remote 'example' @ 198.51.100.8[4500]
  corp: #2, reqid 1, INSTALLED, TUNNEL-in-UDP, ESP:AES_CBC-128
    local  10.99.0.8/32
    remote 203.0.113.8/32 10.10.10.0/24
"""
check("SA VIP 對應唯一公司 utun", (try? CompanyVPNText.identity(sas, policy: policy(), daemon: "own-daemon", interfaces: ["utun8": ["10.99.0.8"]])) == identity())
check("VIP 找不到介面拒絕", rejects { try CompanyVPNText.identity(sas, policy: policy(), daemon: "own-daemon", interfaces: [:]) })
check("VIP 對應多介面拒絕", rejects { try CompanyVPNText.identity(sas, policy: policy(), daemon: "own-daemon", interfaces: ["utun8": ["10.99.0.8"], "utun9": ["10.99.0.8"]]) })
check("多個 IKE SA 拒絕", rejects { try CompanyVPNText.identity(sas + "\nvpn2: #3, CONNECTING, IKEv2, x", policy: policy(), daemon: "own-daemon", interfaces: ["utun8": ["10.99.0.8"]]) })
check("無 plugins 證據拒絕", rejects { try CompanyVPNText.plugins("daemon running") })
check("讀取實際 plugins 而非設定推測", try! CompanyVPNText.plugins(" uptime: 1\n loaded plugins: charon vici kernel-pfkey kernel-pfroute socket-default") == ["charon", "vici", "kernel-pfkey", "kernel-pfroute", "socket-default"])
print("通過 \(pass)，失敗 \(fail)")
exit(fail == 0 ? 0 : 1)
