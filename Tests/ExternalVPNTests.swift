import Foundation

var pass = 0, fail = 0
func check(_ name: String, _ condition: Bool) { print((condition ? "✅ " : "❌ ") + name); condition ? (pass += 1) : (fail += 1) }
func rejected(_ action: () throws -> Any) -> Bool { do { _ = try action(); return false } catch { return true } }
func network(_ value: String) -> ExternalIPv4Network { try! ExternalIPv4Network(value) }
func route(_ cidr: String, _ gateway: String = "192.0.2.1", _ interface: String = "en0", _ flags: String = "UGS") -> ExternalRoute {
    ExternalRoute(network: network(cidr), gateway: gateway, interface: interface, flags: flags)
}
func plist(_ dictionary: [String: Any]) -> Data { try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0) }
let physicalDNS = ExternalDNSEntry(key: "State:/Network/Service/physical/DNS", interface: "en0", value: plist(["ServerAddresses": ["192.0.2.1"]]))
let vpnDNS = ExternalDNSEntry(key: "State:/Network/Service/external/DNS", interface: "ppp0", value: plist(["ServerAddresses": ["198.51.100.53"], "SupplementalMatchDomains": [""], "SearchDomains": ["internal.example.com"]]))
func baseline() -> ExternalNetworkSnapshot {
    ExternalNetworkSnapshot(bootID: "test-boot", interface: "en0", address: "192.0.2.5", gateway: "192.0.2.1", localNetwork: network("192.0.2.0/24"), routes: [route("0.0.0.0/0"), route("192.0.2.0/24", "link#1", "en0", "UCS")], dns: [physicalDNS], ipv6TunnelDefault: false, interfaceIndex: 1)
}
func connected() -> ExternalNetworkSnapshot {
    var state = baseline()
    state.routes += [route("0.0.0.0/1", "198.51.100.1", "ppp0"), route("128.0.0.0/1", "198.51.100.1", "ppp0"), route("198.51.100.0/24", "198.51.100.1", "ppp0")]
    state.dns.append(vpnDNS)
    return state
}
final class FakeRuntime: ExternalVPNRuntime {
    var state = baseline()
    var saved: ExternalVPNSession?
    var adds = 0
    var removes = 0
    var dnsWrites = 0
    var failAt = Int.max
    var failRemove = false
    var conflictOnFailure: ExternalRoute?
    var failAfterAdd = false
    var intentsObserved = true
    var snapshots = 0
    var mutateSnapshot: ((inout ExternalNetworkSnapshot, Int) -> Void)?
    var failSnapshotAt = Int.max
    var savedHistory: [ExternalVPNSession] = []
    func snapshot(baseline: ExternalNetworkSnapshot?) throws -> ExternalNetworkSnapshot {
        snapshots += 1
        if snapshots == failSnapshotAt { throw ExternalVPNError.invalid("測試無法讀取復原快照") }
        mutateSnapshot?(&state, snapshots)
        return state
    }
    func add(_ route: ExternalRoute) throws {
        adds += 1
        intentsObserved = intentsObserved && saved?.addedRoutes.last?.network == route.network
        if adds == failAt {
            if failAfterAdd {
                state.routes.append(route)
                throw ExternalVPNError.invalid("測試核心已新增路由，但指令逾時")
            }
            if let conflictOnFailure { state.routes.append(conflictOnFailure) }
            throw ExternalVPNRouteError.notAdded("測試新增遭拒")
        }
        state.routes.append(route)
    }
    func remove(_ route: ExternalRoute) throws {
        if failRemove { throw ExternalVPNError.invalid("測試復原失敗") }
        removes += 1
        state.routes.removeAll { $0 == route }
    }
    func dnsValue(_ key: String) throws -> Data? { state.dns.first(where: { $0.key == key })?.value }
    func setDNS(_ key: String, value: Data) throws {
        dnsWrites += 1
        let old = state.dns.first(where: { $0.key == key })!
        state.dns.removeAll { $0.key == key }
        state.dns.append(ExternalDNSEntry(key: key, interface: old.interface, value: value))
        if old.interface == "en0" {
            let dictionary = (try? PropertyListSerialization.propertyList(from: value, format: nil)) as? [String: Any]
            state.defaultDNSServers = dictionary?["ServerAddresses"] as? [String] ?? []
        }
    }
    func save(_ session: ExternalVPNSession?) throws { saved = session; if let session { savedHistory.append(session) } }
}

check("IPv4 位址正規化", try! ExternalIPv4("192.000.2.5").description == "192.0.2.5")
for invalid in ["", "192.0.2", "256.0.0.1", "１２７.0.0.1", "192.0.2.1;id", "-1.0.0.0"] {
    check("拒絕無效 IPv4 \(invalid)", rejected { try ExternalIPv4(invalid) })
}
check("CIDR 對齊網段", network("192.0.2.123/24").description == "192.0.2.0/24")
check("/0 包含全位址", network("0.0.0.0/0").contains(try! ExternalIPv4("255.255.255.255")))
check("/32 不包含隔壁主機", !network("192.0.2.5/32").contains(try! ExternalIPv4("192.0.2.6")))
check("拒絕過寬 VPN 保留範圍", rejected { try ExternalVPNProfile(protectedNetworks: ["0.0.0.0/0"]).validated() })
for domain in ["", "example", "*.example.com", "example.com/evil", "example.com\nquit", "-bad.example.com"] {
    check("拒絕 DNS 注入 \(domain.debugDescription)", rejected { try ExternalVPNProfile(dnsDomains: [domain]).validated() })
}
check("DNS 網域正規化", try! ExternalVPNProfile(dnsDomains: ["Internal.Example.COM"]).validated().dnsDomains == ["internal.example.com"])

let parsed = ExternalVPNPlanner.parseRoutes("Destination Gateway Flags Netif Expire\ndefault 192.0.2.1 UGScg en0\n0/1 198.51.100.1 UGSc ppp0\n128.0/1 198.51.100.1 UGSc ppp0\n192.0.2.7 192.0.2.1 UGHS1 en0\n")
check("解析縮寫的兩個 /1 與 PPP", parsed.count == 4 && parsed[1].network.description == "0.0.0.0/1" && parsed[2].network.description == "128.0.0.0/1")
check("解析 host 與本程式路由標記", parsed.last?.network.prefix == 32 && parsed.last?.isOwned == true)
check("偵測 PPP 全通道", try! ExternalVPNPlanner.tunnel(in: connected()) == "ppp0")
var scoped = baseline(); scoped.routes.append(route("0.0.0.0/0", "link#7", "utun0", "UGcIg"))
check("背景的 scoped IPv4 VPN 不當成全通道", try! ExternalVPNPlanner.tunnel(in: scoped) == nil)
check("背景 scoped IPv6 不阻擋正常準備", !ExternalVPNPlanner.hasIPv6TunnelDefault("default fe80::1%utun0 UGcIg utun0\n"))
check("非 scoped IPv6 全通道拒絕", ExternalVPNPlanner.hasIPv6TunnelDefault("::/1 fe80::1 UGSc utun8\n"))
var two = connected(); two.routes.append(route("0.0.0.0/0", "198.51.100.1", "utun9"))
check("多個全通道不猜測", rejected { try ExternalVPNPlanner.tunnel(in: two) })

let publicPlan = ExternalVPNPlanner.publicNetworks(excluding: [network("8.0.0.0/8")])
check("補集路由皆可優先於 /1", publicPlan.allSatisfy { $0.prefix >= 2 })
check("補集保留明確指定公開網段", !publicPlan.contains { $0.contains(try! ExternalIPv4("8.8.8.8")) })
for sample in ["10.1.2.3", "127.0.0.1", "169.254.1.2", "172.16.1.2", "192.168.1.2", "192.0.2.5", "198.51.100.5", "203.0.113.5", "224.0.0.1"] {
    check("補集不將特殊位址導向外網 \(sample)", !publicPlan.contains { $0.contains(try! ExternalIPv4(sample)) })
}
check("一般公開目的地有分流路由", publicPlan.contains { $0.contains(try! ExternalIPv4("1.1.1.1")) })

var overlappingSession = ExternalVPNSession(owner: 501, baseline: baseline(), profile: ExternalVPNProfile(protectedNetworks: ["192.0.2.0/24"]))
check("明確保留網段與本機 LAN 重疊時拒絕", rejected { try ExternalVPNPlanner.plan(overlappingSession, current: connected(), tunnel: "ppp0") })
overlappingSession = ExternalVPNSession(owner: 501, baseline: baseline(), profile: ExternalVPNProfile(protectedNetworks: ["8.0.0.0/8"]))
check("獨立的明確保留網段可分流", !rejected { try ExternalVPNPlanner.plan(overlappingSession, current: connected(), tunnel: "ppp0") })
var physicalConflict = connected(); physicalConflict.routes.append(route("8.8.8.8/32"))
check("明確保留網段含實體精確路由時拒絕", rejected { try ExternalVPNPlanner.plan(overlappingSession, current: physicalConflict, tunnel: "ppp0") })

let fake = FakeRuntime(); let engine = ExternalVPNEngine(runtime: fake)
var session = try! engine.prepare(owner: 501, profile: ExternalVPNProfile())
check("準備只記錄、不新增路由", session.phase == .waiting && fake.adds == 0)
check("尚未連 VPN 時繼續等待", try! engine.tick(session).phase == .waiting)
fake.state = connected()
session = try! engine.tick(session)
check("連上 PPP 後自動分流", session.phase == .active && !session.addedRoutes.isEmpty && session.tunnel == "ppp0")
check("新增前已保存復原意圖", fake.intentsObserved)
check("原 VPN /1 未被刪除", fake.state.routes.contains { $0.isTunnel && $0.network.prefix == 1 })
let defaultDNS = fake.state.dns.first(where: { $0.interface == "en0" })!.dictionary
check("一般 DNS 明確使用原本實體服務", defaultDNS["SupplementalMatchDomains"] as? [String] == [""] && defaultDNS["SearchOrder"] as? Int == 1)
let splitDNS = fake.state.dns.first(where: { $0.interface == "ppp0" })!.dictionary
check("內部 DNS 僅比對原本 VPN suffix", splitDNS["SupplementalMatchDomains"] as? [String] == ["internal.example.com"])
check("作用中再次觀察不重複加路由", try! engine.tick(session).addedRoutes.count == fake.adds)
session = try! engine.restore(session)
check("停止復原自己路由與 DNS", session.phase == .idle && fake.state.routes.count == connected().routes.count && ExternalDNSEntry.equalValues(try! fake.dnsValue(physicalDNS.key), physicalDNS.value))

let failed = FakeRuntime(); let failedEngine = ExternalVPNEngine(runtime: failed)
let pending = try! failedEngine.prepare(owner: 501, profile: ExternalVPNProfile())
failed.state = connected(); failed.failAt = 3
let result = try! failedEngine.tick(pending)
check("中途新增失敗會復原已新增路由", result.phase == .failed && failed.removes == 2 && result.addedRoutes.isEmpty)
let failedPlan = try! ExternalVPNPlanner.plan(pending, current: connected(), tunnel: "ppp0").additions
let race = FakeRuntime(); let raceEngine = ExternalVPNEngine(runtime: race)
let racePending = try! raceEngine.prepare(owner: 501, profile: ExternalVPNProfile())
race.state = connected(); race.failAt = 1; race.conflictOnFailure = failedPlan[0]
_ = try! raceEngine.tick(racePending)
check("新增拒絕不刪除同時存在的同值路由", race.removes == 0 && race.state.routes.contains(failedPlan[0]))

let uncertain = FakeRuntime(); let uncertainEngine = ExternalVPNEngine(runtime: uncertain)
let uncertainPending = try! uncertainEngine.prepare(owner: 501, profile: ExternalVPNProfile())
uncertain.state = connected(); uncertain.failAt = 3; uncertain.failAfterAdd = true
let uncertainResult = try! uncertainEngine.tick(uncertainPending)
check("核心已新增後才逾時，仍依意圖復原全部路由", uncertainResult.phase == .failed && uncertain.removes == 3 && uncertainResult.addedRoutes.isEmpty && !uncertain.state.routes.contains(where: \.isOwned))
let uncertainRecovery = FakeRuntime(); let uncertainRecoveryEngine = ExternalVPNEngine(runtime: uncertainRecovery)
let uncertainRecoveryPending = try! uncertainRecoveryEngine.prepare(owner: 501, profile: ExternalVPNProfile())
uncertainRecovery.state = connected(); uncertainRecovery.failAt = 1; uncertainRecovery.failAfterAdd = true; uncertainRecovery.failRemove = true
let uncertainRetained = try! uncertainRecoveryEngine.tick(uncertainRecoveryPending)
check("逾時且復原失敗時保留未確定路由供下次復原", uncertainRetained.phase == .recoveryRequired && uncertainRetained.addedRoutes.count == 1)
uncertainRecovery.failRemove = false
check("重新啟動引擎仍可清除逾時路由", try! ExternalVPNEngine(runtime: uncertainRecovery).restore(uncertainRetained).phase == .idle)

var publicDNSState = connected()
publicDNSState.dns[1] = ExternalDNSEntry(key: vpnDNS.key, interface: "ppp0", value: plist(["ServerAddresses": ["8.8.4.4"], "SupplementalMatchDomains": [""], "SupplementalMatchOrders": [100], "SearchDomains": ["internal.example.com", "other.example.com"]]))
let publicDNSPlan = try! ExternalVPNPlanner.plan(pending, current: publicDNSState, tunnel: "ppp0").additions
check("公網 IP 的內部 DNS 保留 VPN 路由", !publicDNSPlan.contains { $0.network.contains(try! ExternalIPv4("8.8.4.4")) } && publicDNSPlan.contains { $0.network.contains(try! ExternalIPv4("1.1.1.1")) })
let publicDNSChanges = try! ExternalVPNPlanner.dnsPlan(pending, current: publicDNSState, tunnel: "ppp0")
let multipleDomains = try! PropertyListSerialization.propertyList(from: publicDNSChanges.changes[0].after, format: nil) as! [String: Any]
check("改成多個內部網域時移除過期比對順序", multipleDomains["SupplementalMatchOrders"] == nil && (multipleDomains["SupplementalMatchDomains"] as? [String])?.count == 2)
publicDNSState.routes.append(route("8.8.4.4/32"))
check("內部 DNS 被實體精確路由接管時拒絕分流", rejected { try ExternalVPNPlanner.dnsPlan(pending, current: publicDNSState, tunnel: "ppp0") })

let recovery = FakeRuntime(); let recoveryEngine = ExternalVPNEngine(runtime: recovery)
var active = try! recoveryEngine.prepare(owner: 501, profile: ExternalVPNProfile())
recovery.state = connected(); active = try! recoveryEngine.tick(active)
recovery.failRemove = true
let retained = try! recoveryEngine.restore(active)
check("復原失敗保留紀錄與 recoveryRequired", retained.phase == .recoveryRequired && !retained.addedRoutes.isEmpty && recovery.saved != nil)
recovery.failRemove = false
check("重新復原可完成", try! recoveryEngine.restore(retained).phase == .idle)

let foreign = FakeRuntime(); let foreignEngine = ExternalVPNEngine(runtime: foreign)
var own = try! foreignEngine.prepare(owner: 501, profile: ExternalVPNProfile())
foreign.state = connected(); own = try! foreignEngine.tick(own)
let replaced = own.addedRoutes[0]
foreign.state.routes.removeAll { $0.network == replaced.network }
foreign.state.routes.append(route(replaced.network.description, replaced.gateway, replaced.interface, "UGS1I"))
let foreignResult = try! foreignEngine.restore(own)
check("同目的 scoped 第三方路由不刪除", foreignResult.phase == .recoveryRequired && foreign.state.routes.contains { $0.flags == "UGS1I" })

let unknown = FakeRuntime(); let unknownEngine = ExternalVPNEngine(runtime: unknown)
let unknownPending = try! unknownEngine.prepare(owner: 501, profile: ExternalVPNProfile())
unknown.state = connected()
unknown.state.dns[1] = ExternalDNSEntry(key: vpnDNS.key, interface: nil, value: vpnDNS.value)
check("無法辨識 DNS 歸屬不改路由", try! unknownEngine.tick(unknownPending).phase == .failed && unknown.adds == 0)
let missing = FakeRuntime(); let missingEngine = ExternalVPNEngine(runtime: missing)
let missingPending = try! missingEngine.prepare(owner: 501, profile: ExternalVPNProfile())
missing.state = connected()
missing.state.dns[1] = ExternalDNSEntry(key: vpnDNS.key, interface: "ppp0", value: plist(["ServerAddresses": ["198.51.100.53"], "SupplementalMatchDomains": [""]]))
check("缺少內部 DNS suffix 不洩漏查詢", try! missingEngine.tick(missingPending).phase == .failed && missing.adds == 0)
let global = FakeRuntime(); let globalEngine = ExternalVPNEngine(runtime: global)
let globalPending = try! globalEngine.prepare(owner: 501, profile: ExternalVPNProfile())
global.state = connected(); global.state.dns = [physicalDNS]; global.state.defaultDNSServers = ["198.51.100.53"]
check("只有 Global DNS 被修改時拒絕猜測", try! globalEngine.tick(globalPending).phase == .failed && global.adds == 0)
var v6 = baseline(); v6.ipv6TunnelDefault = true
let ipv6 = FakeRuntime(); ipv6.state = v6
check("IPv6 全通道於準備時拒絕", rejected { try ExternalVPNEngine(runtime: ipv6).prepare(owner: 501, profile: ExternalVPNProfile()) })
let moved = FakeRuntime(); let movedEngine = ExternalVPNEngine(runtime: moved)
let oldNetwork = try! movedEngine.prepare(owner: 501, profile: ExternalVPNProfile())
moved.state.address = "192.0.2.6"
check("等待中換網路不沿用舊閘道", try! movedEngine.tick(oldNetwork).phase == .failed && moved.adds == 0)

let retryRuntime = FakeRuntime(); let retryEngine = ExternalVPNEngine(runtime: retryRuntime)
let original = try! retryEngine.prepare(owner: 501, profile: ExternalVPNProfile())
var cleanFailure = try! retryEngine.failed(original, error: ExternalVPNError.invalid("第一次 DNS 判斷失敗"), stage: .planning)
retryRuntime.state = connected()
let retried = try! retryEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsDomains: ["internal.example.com"]), previous: cleanFailure)
check("已連 VPN 的乾淨失敗沿用連線前快照", retried.phase == .waiting && retried.baseline.routes.count == original.baseline.routes.count && retried.firstFailure == cleanFailure.firstFailure && retryRuntime.adds == 0)
cleanFailure.phase = .recoveryRequired
check("舊版零變更 recoveryRequired 可明確重試", try! retryEngine.prepare(owner: 501, profile: ExternalVPNProfile(), previous: cleanFailure).phase == .waiting && ExternalVPNStatus(session: cleanFailure).canRetry == true)
check("不同使用者不得沿用快照", rejected { try retryEngine.prepare(owner: 502, profile: ExternalVPNProfile(), previous: cleanFailure) })
for (name, change) in [
    ("開機", { (state: inout ExternalNetworkSnapshot) in state.bootID = "other-boot" }),
    ("實體介面", { (state: inout ExternalNetworkSnapshot) in state.interface = "en1" }),
    ("來源位址", { (state: inout ExternalNetworkSnapshot) in state.address = "192.0.2.6" }),
    ("閘道", { (state: inout ExternalNetworkSnapshot) in state.gateway = "192.0.2.2" }),
    ("本機網段", { (state: inout ExternalNetworkSnapshot) in state.localNetwork = network("192.0.2.0/25") })
] {
    retryRuntime.state = connected(); change(&retryRuntime.state)
    check("重試時\(name)已改變便拒絕", rejected { try retryEngine.prepare(owner: 501, profile: ExternalVPNProfile(), previous: cleanFailure) })
}
retryRuntime.state = connected()
var dirtyDNS = cleanFailure
dirtyDNS.dnsChanges = [ExternalDNSChange(key: physicalDNS.key, before: physicalDNS.value, after: physicalDNS.value)]
check("只有 DNS 尚待復原時不開放重試", !dirtyDNS.canRetry && rejected { try retryEngine.prepare(owner: 501, profile: ExternalVPNProfile(), previous: dirtyDNS) })
var dirtyRoute = cleanFailure; dirtyRoute.addedRoutes = [route("1.0.0.0/8", "192.0.2.1", "en0", "UGS1")]
check("尚有路由待復原時不開放重試", !dirtyRoute.canRetry && rejected { try retryEngine.prepare(owner: 501, profile: ExternalVPNProfile(), previous: dirtyRoute) })
var unsafeBaseline = connected(); unsafeBaseline.ipv6TunnelDefault = true
var untrusted = ExternalVPNSession(owner: 501, baseline: unsafeBaseline, profile: ExternalVPNProfile()); untrusted.phase = .failed
check("原快照含 IPv6 全通道不能用作重試依據", !untrusted.canRetry && rejected { try retryEngine.prepare(owner: 501, profile: ExternalVPNProfile(), previous: untrusted) })
let again = try! retryEngine.failed(cleanFailure, error: ExternalVPNError.invalid("後續準備被拒絕"), stage: .preparing)
check("乾淨重試失敗不升級成待復原且保留首次原因", again.phase == .failed && again.firstFailure?.message == "第一次 DNS 判斷失敗" && again.latestFailure?.message == "後續準備被拒絕" && again.message.contains("第一次 DNS 判斷失敗"))
let rollbackFailure = FakeRuntime(); let rollbackEngine = ExternalVPNEngine(runtime: rollbackFailure)
let rollbackPending = try! rollbackEngine.prepare(owner: 501, profile: ExternalVPNProfile())
rollbackFailure.state = connected(); rollbackFailure.failAt = 2; rollbackFailure.failSnapshotAt = 3
let rollbackResult = try! rollbackEngine.tick(rollbackPending)
check("復原讀取失敗仍保留最初套用原因", rollbackResult.phase == .recoveryRequired && rollbackResult.firstFailure?.message == "測試新增遭拒" && rollbackResult.latestFailure?.stage == .restoring)
check("復原開始之前已保存首次失敗", rollbackFailure.savedHistory.contains { $0.phase == .recoveryRequired && $0.firstFailure?.message == "測試新增遭拒" && $0.latestFailure?.stage == .applyingRoutes })
let jsonEncoder = JSONEncoder()
var oldSession = try! JSONSerialization.jsonObject(with: jsonEncoder.encode(cleanFailure)) as! [String: Any]
oldSession.removeValue(forKey: "firstFailure"); oldSession.removeValue(forKey: "latestFailure")
let decodedOld = try! JSONDecoder().decode(ExternalVPNSession.self, from: JSONSerialization.data(withJSONObject: oldSession))
check("舊版沒有失敗欄位的紀錄可解碼並重試", decodedOld.firstFailure == nil && decodedOld.latestFailure == nil && decodedOld.canRetry)
var oldStatus = try! JSONSerialization.jsonObject(with: jsonEncoder.encode(ExternalVPNStatus(session: cleanFailure))) as! [String: Any]
oldStatus.removeValue(forKey: "canRetry")
check("舊版沒有能力欄位的狀態可解碼", try! JSONDecoder().decode(ExternalVPNStatus.self, from: JSONSerialization.data(withJSONObject: oldStatus)).canRetry == nil)

let preserveProfile = ExternalVPNProfile(dnsMode: .preserveVPN)
check("明確保留模式拒絕同時指定 DNS 網域", rejected { try ExternalVPNProfile(dnsDomains: ["internal.example.com"], dnsMode: .preserveVPN).validated() })
let legacyProfileData = Data(#"{"protectedNetworks":[],"dnsDomains":[]}"#.utf8)
check("舊設定缺少 DNS 模式時維持依網域分流", try! JSONDecoder().decode(ExternalVPNProfile.self, from: legacyProfileData).dnsMode == .splitDomains)
check("未知 DNS 模式不靜默降級", rejected { try JSONDecoder().decode(ExternalVPNProfile.self, from: Data(#"{"protectedNetworks":[],"dnsDomains":[],"dnsMode":"unknown"}"#.utf8)) })
func noSuffix() -> ExternalNetworkSnapshot {
    var state = connected()
    state.dns[1] = ExternalDNSEntry(key: vpnDNS.key, interface: "ppp0", value: plist(["ServerAddresses": ["198.51.100.53"], "SupplementalMatchDomains": [""]]))
    state.defaultDNSServers = ["198.51.100.53"]; state.defaultDNSDomains = [""]
    return state
}
func preserving(_ state: ExternalNetworkSnapshot = noSuffix()) -> (FakeRuntime, ExternalVPNEngine, ExternalVPNSession) {
    let runtime = FakeRuntime(); let engine = ExternalVPNEngine(runtime: runtime)
    let pending = try! engine.prepare(owner: 501, profile: preserveProfile)
    runtime.state = state
    return (runtime, engine, try! engine.tick(pending))
}
let keepInitial = noSuffix()
let (keep, keepEngine, keepActive) = preserving(keepInitial)
check("缺 suffix 只在明確保留模式套用路由", keepActive.phase == .active && keep.adds > 0 && keepActive.dnsChanges.isEmpty && keepActive.preservedDNS != nil)
check("保留模式完全不寫 DNS 與預設解析順序", keep.dnsWrites == 0 && keep.state.dns == keepInitial.dns && keep.state.defaultDNSServers == keepInitial.defaultDNSServers && keep.state.defaultDNSDomains == keepInitial.defaultDNSDomains)
check("新增第一筆路由前已保存唯讀 DNS 證據", keep.savedHistory.contains { $0.phase == .applying && $0.addedRoutes.isEmpty && $0.preservedDNS != nil })
check("狀態回報實際 DNS 模式且不宣稱連外成功", ExternalVPNStatus(session: keepActive).dnsMode == .preserveVPN && keepActive.message.contains("仍待確認"))
check("作用中保留 DNS 再觀察不增加路由", try! keepEngine.tick(keepActive).phase == .active && keep.adds == keepActive.addedRoutes.count && keep.dnsWrites == 0)
check("保留模式停止只清自己路由", try! keepEngine.restore(keepActive).phase == .idle && keep.dnsWrites == 0 && keep.state.dns == keepInitial.dns)
var publicKeep = noSuffix()
publicKeep.dns[1] = ExternalDNSEntry(key: vpnDNS.key, interface: "ppp0", value: plist(["ServerAddresses": ["8.8.4.4"], "SupplementalMatchDomains": [""]]))
publicKeep.defaultDNSServers = ["8.8.4.4"]
let (publicKeepRuntime, _, publicKeepActive) = preserving(publicKeep)
check("保留模式的公用 VPN DNS 位址不落入外網路由", publicKeepActive.phase == .active && !publicKeepActive.addedRoutes.contains { $0.network.contains(try! ExternalIPv4("8.8.4.4")) } && publicKeepRuntime.dnsWrites == 0)
var physicalGlobal = noSuffix()
physicalGlobal.defaultDNSServers = physicalDNS.servers
let (physicalGlobalRuntime, _, physicalGlobalActive) = preserving(physicalGlobal)
check("保留模式接受可歸屬原本實體服務的全域 DNS", physicalGlobalActive.phase == .active && physicalGlobalRuntime.dnsWrites == 0)
var emptyGlobal = noSuffix()
emptyGlobal.defaultDNSServers = []
let (emptyGlobalRuntime, _, emptyGlobalActive) = preserving(emptyGlobal)
check("保留模式接受沒有全域 DNS 清單的服務快照", emptyGlobalActive.phase == .active && emptyGlobalRuntime.dnsWrites == 0)
for (name, servers, extra) in [
    ("無法對應服務的全域解析器", ["8.8.8.8"], Optional<ExternalDNSEntry>.none),
    ("合法與未知全域解析器並存", ["198.51.100.53", "8.8.8.8"], nil),
    ("全域解析器歸屬不明的其他服務", ["198.51.100.53"], ExternalDNSEntry(key: "State:/Network/Service/unknown/DNS", interface: nil, value: plist(["ServerAddresses": ["198.51.100.53"]])))
] {
    let runtime = FakeRuntime(); let engine = ExternalVPNEngine(runtime: runtime)
    if let extra { runtime.state.dns.append(extra) }
    let pending = try! engine.prepare(owner: 501, profile: preserveProfile)
    runtime.state = noSuffix(); runtime.state.defaultDNSServers = servers
    if let extra { runtime.state.dns.append(extra) }
    let result = try! engine.tick(pending)
    check("保留模式拒絕\(name)且路由與 DNS 零寫入", result.phase == .failed && runtime.adds == 0 && runtime.dnsWrites == 0)
}
for (name, change) in [
    ("未知歸屬", { (state: inout ExternalNetworkSnapshot) in state.dns[1] = ExternalDNSEntry(key: vpnDNS.key, interface: nil, value: state.dns[1].value) }),
    ("只有全域解析器", { (state: inout ExternalNetworkSnapshot) in state.dns = [physicalDNS] }),
    ("空伺服器", { (state: inout ExternalNetworkSnapshot) in state.dns[1] = ExternalDNSEntry(key: vpnDNS.key, interface: "ppp0", value: plist(["SupplementalMatchDomains": [""]])) }),
    ("後續 DNS 項目無效", { (state: inout ExternalNetworkSnapshot) in state.dns.append(ExternalDNSEntry(key: "State:/Network/Service/second/DNS", interface: "ppp0", value: plist(["ServerAddresses": []]))) }),
    ("DNS 路由離開 VPN", { (state: inout ExternalNetworkSnapshot) in state.routes.append(route("198.51.100.53/32")) })
] {
    var state = noSuffix(); change(&state)
    let (runtime, _, result) = preserving(state)
    check("保留模式仍拒絕\(name)且零寫入", result.phase == .failed && runtime.adds == 0 && runtime.dnsWrites == 0)
}
let (drift, driftEngine, driftActive) = preserving()
drift.state.dns[1] = ExternalDNSEntry(key: vpnDNS.key, interface: "ppp0", value: plist(["ServerAddresses": ["198.51.100.54"], "SupplementalMatchDomains": [""]]))
let driftDNS = drift.state.dns
let driftResult = try! driftEngine.tick(driftActive)
check("DNS 變動時只撤回路由並保留外部 DNS 新值", driftResult.phase == .failed && driftResult.addedRoutes.isEmpty && drift.dnsWrites == 0 && drift.state.dns == driftDNS)
let (globalDrift, globalDriftEngine, globalDriftActive) = preserving()
globalDrift.state.defaultDNSServers = ["198.51.100.54"]
check("全域解析器變動也停止保留模式", try! globalDriftEngine.tick(globalDriftActive).phase == .failed && globalDrift.dnsWrites == 0)
let (unownedGlobal, unownedGlobalEngine, unownedGlobalActive) = preserving()
unownedGlobal.state.defaultDNSServers.append("8.8.8.8")
let unownedGlobalResult = try! unownedGlobalEngine.tick(unownedGlobalActive)
check("作用中出現未知全域 DNS 會撤回自己路由且不寫 DNS", unownedGlobalResult.phase == .failed && !unownedGlobal.state.routes.contains(where: \.isOwned) && unownedGlobal.dnsWrites == 0)
let (legacyGlobal, legacyGlobalEngine, legacyGlobalActive) = preserving()
legacyGlobal.state.defaultDNSServers = ["8.8.8.8"]
var legacyGlobalSession = legacyGlobalActive
legacyGlobalSession.preservedDNS = ExternalDNSState(legacyGlobal.state)
let legacyGlobalResult = try! legacyGlobalEngine.tick(legacyGlobalSession)
check("舊作用中紀錄即使 DNS 證據吻合仍須驗證全域解析器歸屬", legacyGlobalResult.phase == .failed && !legacyGlobal.state.routes.contains(where: \.isOwned) && legacyGlobal.dnsWrites == 0)
let (dnsRouteDrift, dnsRouteEngine, dnsRouteActive) = preserving(publicKeep)
dnsRouteDrift.state.routes.append(route("8.8.4.4/32"))
check("DNS 值不變但路由被外部接管仍會復原", try! dnsRouteEngine.tick(dnsRouteActive).phase == .failed && dnsRouteDrift.dnsWrites == 0 && dnsRouteDrift.state.routes.contains { $0.network == network("8.8.4.4/32") })
let (lost, lostEngine, lostActive) = preserving()
lost.state.routes.removeAll { $0.isTunnel }
check("VPN 中斷時撤回自己路由且不改 DNS", try! lostEngine.tick(lostActive).phase == .failed && !lost.state.routes.contains(where: \.isOwned) && lost.dnsWrites == 0)
let (noEvidence, noEvidenceEngine, noEvidenceActive) = preserving()
var missingEvidence = noEvidenceActive; missingEvidence.preservedDNS = nil
check("保留模式缺少觀察紀錄時復原而不猜測", try! noEvidenceEngine.tick(missingEvidence).phase == .failed && noEvidence.dnsWrites == 0)
let partialKeep = FakeRuntime(); let partialKeepEngine = ExternalVPNEngine(runtime: partialKeep)
let partialKeepPending = try! partialKeepEngine.prepare(owner: 501, profile: preserveProfile)
partialKeep.state = noSuffix(); partialKeep.failAt = 2
let partialKeepResult = try! partialKeepEngine.tick(partialKeepPending)
check("保留模式中途路由遭拒會復原且留下首次原因", partialKeepResult.phase == .failed && partialKeep.removes == 1 && partialKeep.dnsWrites == 0 && partialKeepResult.firstFailure?.stage == .applyingRoutes)
var semanticState = noSuffix()
semanticState.dns[1] = ExternalDNSEntry(key: vpnDNS.key, interface: "ppp0", value: try! PropertyListSerialization.data(fromPropertyList: noSuffix().dns[1].dictionary, format: .xml, options: 0))
check("唯讀 DNS 證據使用語意比對而非 plist 位元組順序", ExternalDNSState(noSuffix()).matches(semanticState))
var trulyOldSession = oldSession
var trulyOldProfile = trulyOldSession["profile"] as! [String: Any]; trulyOldProfile.removeValue(forKey: "dnsMode"); trulyOldSession["profile"] = trulyOldProfile
trulyOldSession.removeValue(forKey: "preservedDNS")
let decodedLegacy = try! JSONDecoder().decode(ExternalVPNSession.self, from: JSONSerialization.data(withJSONObject: trulyOldSession))
check("舊紀錄缺少 DNS 模式與觀察證據仍可解碼", decodedLegacy.profile.dnsMode == .splitDomains && decodedLegacy.preservedDNS == nil)
oldStatus.removeValue(forKey: "dnsMode")
check("舊狀態缺少 DNS 模式可解碼", try! JSONDecoder().decode(ExternalVPNStatus.self, from: JSONSerialization.data(withJSONObject: oldStatus)).dnsMode == nil)


func connectedBorrowing(_ state: ExternalNetworkSnapshot) -> ExternalNetworkSnapshot {
    var result = state
    result.routes += connected().routes.filter(\.isTunnel)
    result.dns.append(vpnDNS)
    return result
}
let endpointRuntime = FakeRuntime()
let endpointEngine = ExternalVPNEngine(runtime: endpointRuntime)
let endpointProfile = ExternalVPNProfile(dnsMode: .preserveVPN, directIPv4: ["203.0.113.8"])
let endpointPending = try! endpointEngine.prepare(owner: 501, profile: endpointProfile)
let f5Endpoint = route("203.0.113.8/32", "192.0.2.1", "en0", "UGHSc")
endpointRuntime.state = connected()
endpointRuntime.state.routes.append(f5Endpoint)
check("F5 端點只在連線後出現，未記錄於 baseline", !endpointPending.baseline.routes.contains(f5Endpoint))
var endpointPlan: ExternalVPNRoutePlan?
do {
    endpointPlan = try ExternalVPNPlanner.plan(endpointPending, current: endpointRuntime.state, tunnel: "ppp0")
    check("新出現的正確實體端點可通過完整覆蓋規劃", true)
} catch {
    check("新出現的正確實體端點可通過完整覆蓋規劃，實際錯誤 \(error.localizedDescription)", false)
}

if let endpointPlan {
    let withoutEndpoint = try! ExternalVPNPlanner.plan(endpointPending, current: connected(), tunnel: "ppp0")
    check("借用新端點不縮小公網或指定 IP 驗證範圍", endpointPlan.evidence.publicNetworks == withoutEndpoint.evidence.publicNetworks && endpointPlan.evidence.directHosts == [f5Endpoint.network])
    check("新端點凍結為 borrowed，未列入新增意圖", endpointPlan.evidence.borrowedRoutes.contains(f5Endpoint) && !endpointPlan.additions.contains { $0.network == f5Endpoint.network })
    let endpointActive = try! endpointEngine.tick(endpointPending)
    check("新端點存在時正常啟用分流", endpointActive.phase == .active && !endpointActive.addedRoutes.isEmpty)
    check("啟用時先持久化端點證據且不取得端點刪除權", endpointRuntime.savedHistory.contains { $0.phase == .applying && $0.addedRoutes.isEmpty && $0.routingEvidence?.borrowedRoutes.contains(f5Endpoint) == true } && endpointRuntime.savedHistory.allSatisfy { !$0.addedRoutes.contains { $0.network == f5Endpoint.network } })
    let endpointRecord = try! ExternalVPNJournal.decode(ExternalVPNJournal.encode(endpointActive))
    check("新端點證據可持久化且未變成自有路由", endpointRecord.routingEvidence?.borrowedRoutes.contains(f5Endpoint) == true && !endpointRecord.addedRoutes.contains { $0.network == f5Endpoint.network })
    let endpointSnapshot = endpointRuntime.state
    let endpointAddCount = endpointRuntime.adds
    check("作用中再次觀察借用端點維持 active 且不新增路由", try! endpointEngine.tick(endpointRecord).phase == .active && endpointRuntime.adds == endpointAddCount)
    check("公司准入接受新端點的完整實體覆蓋", !rejected { try CompanyVPNPlanner.validateExternal(endpointRecord, endpointSnapshot) })
    let endpointStopped = try! endpointEngine.restore(endpointRecord)
    check("停止只移除自己新增的路由並保留 F5 端點", endpointStopped.phase == .idle && endpointRuntime.state.routes.contains(f5Endpoint) && endpointRuntime.removes == endpointRecord.addedRoutes.count && !endpointRuntime.state.routes.contains(where: \.isOwned))
    var wrongKind = f5Endpoint
    wrongKind.nextHopKind = .directInterface
    let endpointDrifts: [(String, ExternalRoute?)] = [
        ("消失", nil),
        ("更換閘道", route("203.0.113.8/32", "192.0.2.254", "en0", "UGHSc")),
        ("更換介面", route("203.0.113.8/32", "192.0.2.1", "en1", "UGHSc")),
        ("更換 next-hop 型態", wrongKind),
        ("down", route("203.0.113.8/32", "192.0.2.1", "en0", "GHSc")),
        ("scoped", route("203.0.113.8/32", "192.0.2.1", "en0", "UGHScI")),
        ("reject", route("203.0.113.8/32", "192.0.2.1", "en0", "UGHScR")),
        ("blackhole", route("203.0.113.8/32", "192.0.2.1", "en0", "UGHScB")),
        ("更換 proto1 身分", route("203.0.113.8/32", "192.0.2.1", "en0", "UGHSc1"))
    ]
    for (name, replacement) in endpointDrifts {
        var changed = endpointSnapshot
        changed.routes.removeAll { $0 == f5Endpoint }
        if let replacement { changed.routes.append(replacement) }
        check("凍結後端點\(name)拒絕完整覆蓋驗證", rejected { try endpointRecord.routingEvidence!.validate(endpointRecord, current: changed) })
        check("凍結後端點\(name)拒絕公司准入", rejected { try CompanyVPNPlanner.validateExternal(endpointRecord, changed) })
        let driftRuntime = FakeRuntime()
        driftRuntime.state = changed
        let driftEngine = ExternalVPNEngine(runtime: driftRuntime)
        let driftResult = try! driftEngine.tick(endpointRecord)
        check("凍結後端點\(name)撤回分流且不重新借用", driftResult.phase == .failed && driftResult.firstFailure?.stage == .verifying && driftRuntime.adds == 0 && driftResult.addedRoutes.isEmpty && replacement.map { driftRuntime.state.routes.contains($0) } != false)
    }
    for (name, replacement) in endpointDrifts where !["消失", "scoped", "更換 proto1 身分"].contains(name) {
        var changed = connected()
        changed.routes.append(replacement!)
        check("新端點\(name)無法借用為初始規劃證據", rejected { try ExternalVPNPlanner.plan(endpointPending, current: changed, tunnel: "ppp0") })
    }
    let protoEndpoint = route("203.0.113.8/32", "192.0.2.1", "en0", "UGHS1")
    let protoRuntime = FakeRuntime()
    let protoEngine = ExternalVPNEngine(runtime: protoRuntime)
    let protoPending = try! protoEngine.prepare(owner: 501, profile: endpointProfile)
    protoRuntime.state = connected()
    protoRuntime.state.routes.append(protoEndpoint)
    let protoActive = try! protoEngine.tick(protoPending)
    check("連線後新出現 proto1 端點也只借用而不取得刪除權", protoActive.phase == .active && protoActive.routingEvidence?.borrowedRoutes.contains(protoEndpoint) == true && !protoActive.addedRoutes.contains { $0.network == protoEndpoint.network })
    let protoStopped = try! protoEngine.restore(protoActive)
    check("還原保留連線後新出現的 foreign proto1 端點", protoStopped.phase == .idle && protoRuntime.state.routes.contains(protoEndpoint) && protoRuntime.removes == protoActive.addedRoutes.count)
}

let borrowedRuntime = FakeRuntime()
let borrowedCoverage = ExternalVPNPlanner.publicNetworks(excluding: []).map { route($0.description, "192.0.2.1", "en0", "UGS1") }
borrowedRuntime.state.routes += borrowedCoverage
let borrowedEngine = ExternalVPNEngine(runtime: borrowedRuntime)
let borrowedPending = try! borrowedEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
borrowedRuntime.state = connectedBorrowing(borrowedRuntime.state)
let borrowedPlan = try! ExternalVPNPlanner.plan(borrowedPending, current: borrowedRuntime.state, tunnel: "ppp0")
check("完整既有實體覆蓋允許零新增規劃", borrowedPlan.additions.isEmpty && !borrowedPlan.evidence.publicNetworks.isEmpty)
let borrowedActive = try! borrowedEngine.tick(borrowedPending)
check("零新增仍需完整證據才成 active", borrowedActive.phase == .active && borrowedActive.addedRoutes.isEmpty && borrowedActive.routingEvidence != nil && borrowedActive.journalVersion == 3 && borrowedRuntime.adds == 0)
check("零新增完整覆蓋允許公司驗證", !rejected { try CompanyVPNPlanner.validateExternal(borrowedActive, borrowedRuntime.state) })
let borrowedSnapshot = borrowedRuntime.state
let borrowedStopped = try! borrowedEngine.restore(borrowedActive)
check("借用 proto1 路由不取得刪除權", borrowedStopped.phase == .idle && borrowedRuntime.removes == 0 && borrowedRuntime.state.routes == borrowedSnapshot.routes)
let representative = borrowedCoverage.first { $0.network.prefix < 30 }!
let interior = ExternalIPv4(value: representative.network.address.value + 1)
for (name, replacement) in [
    ("錯誤閘道", route(representative.network.description, "192.0.2.254", "en0", "UGS1")),
    ("錯誤介面", route(representative.network.description, "192.0.2.1", "en1", "UGS1")),
    ("down", route(representative.network.description, "192.0.2.1", "en0", "GS1")),
    ("scoped", route(representative.network.description, "192.0.2.1", "en0", "UGS1I")),
    ("reject", route(representative.network.description, "192.0.2.1", "en0", "UGSR1")),
    ("blackhole", route(representative.network.description, "192.0.2.1", "en0", "UGSB1"))
] {
    var state = borrowedSnapshot
    state.routes.removeAll { $0 == representative }; state.routes.append(replacement)
    check("借用覆蓋\(name)不能通過初始規劃", rejected { try ExternalVPNPlanner.plan(borrowedPending, current: state, tunnel: "ppp0") })
    check("借用覆蓋\(name)不能通過公司驗證", rejected { try CompanyVPNPlanner.validateExternal(borrowedActive, state) })
}
for (name, extra) in [
    ("區間內部 VPN /32", route("\(interior)/32", "198.51.100.1", "ppp0", "UGHS")),
    ("等長 VPN 勝者", route(representative.network.description, "198.51.100.1", "utun9", "UGS"))
] {
    var state = borrowedSnapshot; state.routes.append(extra)
    check("凍結證據拒絕\(name)", rejected { try borrowedActive.routingEvidence!.validate(borrowedActive, current: state) })
    check("公司准入共用驗證拒絕\(name)", rejected { try CompanyVPNPlanner.validateExternal(borrowedActive, state) })
}
borrowedRuntime.state = borrowedSnapshot
borrowedRuntime.state.routes.removeAll { borrowedCoverage.contains($0) }
let lostBorrowed = try! borrowedEngine.tick(borrowedActive)
check("借用路由消失時不維持零新增 active", lostBorrowed.phase == .failed && borrowedRuntime.removes == 0 && lostBorrowed.canRetry)
var partialBorrowing = borrowedSnapshot
partialBorrowing.routes.removeAll { $0 == representative }
let partialPlan = try! ExternalVPNPlanner.plan(borrowedPending, current: partialBorrowing, tunnel: "ppp0")
check("部分既有覆蓋只新增缺口", !partialPlan.additions.isEmpty && partialPlan.additions.allSatisfy { representative.network.contains($0.network) })

let lanRuntime = FakeRuntime(); lanRuntime.state.interfaceIndex = 1
let lanEngine = ExternalVPNEngine(runtime: lanRuntime)
let lanPending = try! lanEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
lanRuntime.state = connected(); lanRuntime.state.interfaceIndex = 1
let intactLAN = try! ExternalVPNPlanner.plan(lanPending, current: lanRuntime.state, tunnel: "ppp0")
check("正常 connected LAN 不重複新增", !intactLAN.additions.contains { $0.network == lanPending.baseline.localNetwork })
lanRuntime.state.routes.removeAll { $0.network == lanPending.baseline.localNetwork }
let missingLAN = try! ExternalVPNPlanner.plan(lanPending, current: lanRuntime.state, tunnel: "ppp0")
check("缺失 LAN 優先規劃真正 direct route", missingLAN.additions.first?.kind == .directInterface && missingLAN.additions.first?.gateway == "link#1" && missingLAN.additions.first?.network == lanPending.baseline.localNetwork)
let lanActive = try! lanEngine.tick(lanPending)
check("缺失 LAN 套用後完整驗證成功", lanActive.phase == .active && lanActive.addedRoutes.first?.kind == .directInterface && lanRuntime.intentsObserved)
check("direct route 先保存 schema3 證據", lanRuntime.savedHistory.contains { $0.phase == .applying && $0.addedRoutes.first?.kind == .directInterface && $0.journalVersion == 3 && $0.routingEvidence != nil })
let directRecord = try! ExternalVPNJournal.decode(ExternalVPNJournal.encode(lanActive))
check("direct route 型態可經 v3 持久化", directRecord.addedRoutes.first?.nextHopKind == .directInterface)
check("啟用時實體介面索引可經 v3 持久化", directRecord.routingEvidence?.physicalInterfaceIndex == 1)
let lanStop = try! lanEngine.restore(directRecord)
check("direct route 精確復原只移除自己的路由", lanStop.phase == .idle && !lanRuntime.state.routes.contains { $0.network == lanPending.baseline.localNetwork })
for conflict in [route("192.0.2.128/25", "198.51.100.1", "ppp0", "UGS"), route("192.0.2.0/24", "198.51.100.1", "ppp0", "UGS")] {
    var state = connected(); state.interfaceIndex = 1
    state.routes.removeAll { $0.network == lanPending.baseline.localNetwork }; state.routes.append(conflict)
    check("LAN 相同或更細 VPN 路由拒絕覆寫 \(conflict.network)", rejected { try ExternalVPNPlanner.plan(lanPending, current: state, tunnel: "ppp0") })
}
var oldLANBaseline = baseline(); oldLANBaseline.interfaceIndex = nil
var noIndex = lanPending; noIndex = ExternalVPNSession(owner: noIndex.owner, baseline: oldLANBaseline, profile: noIndex.profile)
var missingNoIndex = connected(); missingNoIndex.interfaceIndex = nil; missingNoIndex.routes.removeAll { $0.network == noIndex.baseline.localNetwork }
check("缺少介面 index 不能猜測 LAN direct route", rejected { try ExternalVPNPlanner.plan(noIndex, current: missingNoIndex, tunnel: "ppp0") })
missingNoIndex.interfaceIndex = 1
check("舊 failed baseline 可用原 link 身分與實際 index 恢復 LAN", !rejected { try ExternalVPNPlanner.plan(noIndex, current: missingNoIndex, tunnel: "ppp0") })
missingNoIndex.interfaceIndex = 2
check("舊 baseline link 與目前 index 不符時拒絕", rejected { try ExternalVPNPlanner.plan(noIndex, current: missingNoIndex, tunnel: "ppp0") })
let lanNetwork = baseline().localNetwork
var lanlessBaseline = baseline(); lanlessBaseline.routes.removeAll { $0.network == lanNetwork }
var lanlessCurrent = connected(); lanlessCurrent.routes.removeAll { $0.network == lanNetwork }
let modernLanless = ExternalVPNSession(owner: 501, baseline: lanlessBaseline, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
let modernLANPlan = try? ExternalVPNPlanner.plan(modernLanless, current: lanlessCurrent, tunnel: "ppp0")
check("root 擷取的 baseline 缺原 LAN 路由時，以介面 index 與位址遮罩補直連", modernLANPlan?.additions.first.map { $0.kind == .directInterface && $0.gateway == "link#1" && $0.network == lanlessBaseline.localNetwork } == true)
lanlessCurrent.interfaceIndex = 2
check("baseline 缺原 LAN 路由且介面 index 變更時拒絕", rejected { try ExternalVPNPlanner.plan(modernLanless, current: lanlessCurrent, tunnel: "ppp0") })
lanlessCurrent.interfaceIndex = 1; lanlessCurrent.address = "192.0.2.6"
check("baseline 缺原 LAN 路由且實體位址變更時拒絕", rejected { try ExternalVPNPlanner.plan(modernLanless, current: lanlessCurrent, tunnel: "ppp0") })
var emptyAddress = lanlessBaseline; emptyAddress.address = ""
var emptyCurrent = connected(); emptyCurrent.address = ""; emptyCurrent.routes.removeAll { $0.network == lanNetwork }
check("baseline 缺原 LAN 路由且沒有實體位址時拒絕", rejected { try ExternalVPNPlanner.plan(ExternalVPNSession(owner: 501, baseline: emptyAddress, profile: ExternalVPNProfile(dnsMode: .preserveVPN)), current: emptyCurrent, tunnel: "ppp0") })
var legacyLanless = lanlessBaseline; legacyLanless.interfaceIndex = nil
var legacyCurrent = connected(); legacyCurrent.routes.removeAll { $0.network == lanNetwork }
check("舊 baseline 沒有介面 index 也沒有原 LAN 路由時拒絕", rejected { try ExternalVPNPlanner.plan(ExternalVPNSession(owner: 501, baseline: legacyLanless, profile: ExternalVPNProfile(dnsMode: .preserveVPN)), current: legacyCurrent, tunnel: "ppp0") })
var neighbors = connected(); neighbors.interfaceIndex = 1
neighbors.routes += [route("192.0.2.8/32", "aa:bb:cc:dd:ee:ff", "en0", "UHLWI"), route("192.0.2.9/32", "aa:bb:cc:dd:ee:01", "en0", "UHLW")]
var selfBaseline = baseline(); selfBaseline.interfaceIndex = 1
let ownLocalRoute = route("192.0.2.5/32", "127.0.0.1", "lo0", "UHL")
selfBaseline.routes.append(ownLocalRoute); neighbors.routes.append(ownLocalRoute)
let selfSession = ExternalVPNSession(owner: 501, baseline: selfBaseline, profile: ExternalVPNProfile())
check("LAN 容許合法 ARP 與原有本機 lo0 delivery", !rejected { try ExternalVPNPlanner.plan(selfSession, current: neighbors, tunnel: "ppp0") })
let reappeared = FakeRuntime(); reappeared.state.interfaceIndex = 1
let reappearedEngine = ExternalVPNEngine(runtime: reappeared)
let reappearedPending = try! reappearedEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
reappeared.state = connected(); reappeared.state.interfaceIndex = 1
reappeared.state.routes.removeAll { $0.network == reappearedPending.baseline.localNetwork }
let reappearedActive = try! reappearedEngine.tick(reappearedPending)
reappeared.state.routes.removeAll { $0.kind == .directInterface && $0.isOwned }
let originalLAN = reappearedPending.baseline.routes.first { $0.network == reappearedPending.baseline.localNetwork }!
reappeared.state.routes.append(originalLAN)
let removesBefore = reappeared.removes
let reappearedStop = try! reappearedEngine.restore(reappearedActive)
check("OS 重建原 baseline LAN 時放棄已消失 intent 並保留原路由", reappearedStop.phase == .idle && reappeared.state.routes.contains(originalLAN) && reappeared.removes - removesBefore == reappearedActive.addedRoutes.count - 1)
let rebuilt = FakeRuntime(); rebuilt.state.interfaceIndex = 1
rebuilt.state.routes.removeAll { $0.network == lanNetwork }
let rebuiltEngine = ExternalVPNEngine(runtime: rebuilt)
let rebuiltPending = try! rebuiltEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
rebuilt.state = connected(); rebuilt.state.interfaceIndex = 1
rebuilt.state.routes.removeAll { $0.network == lanNetwork }
let rebuiltActive = try! rebuiltEngine.tick(rebuiltPending)
check("baseline 缺原 LAN 時啟用會補直連", rebuiltActive.phase == .active && rebuiltActive.addedRoutes.first?.kind == .directInterface)
rebuilt.state.routes.removeAll { $0.kind == .directInterface && $0.isOwned }
let nativeLAN = route("192.0.2.0/24", "link#1", "en0", "UCS")
rebuilt.state.routes.append(nativeLAN)
let rebuiltRemovesBefore = rebuilt.removes
let rebuiltStop = try! rebuiltEngine.restore(rebuiltActive)
check("baseline 缺原 LAN、停止時 OS 已重建原生直連，放棄已消失 intent 並保留原生路由", rebuiltStop.phase == .idle && rebuilt.state.routes.contains(nativeLAN) && rebuilt.removes - rebuiltRemovesBefore == rebuiltActive.addedRoutes.count - 1)
for foreign in [route("192.0.2.0/24", "link#1", "en1", "UCS"), route("192.0.2.0/24", "link#1", "en0", "UCSI"), route("192.0.2.0/24", "link#2", "en0", "UCS"), route("192.0.2.0/24", "link#1", "en0", "US"), route("192.0.2.0/24", "198.51.100.1", "ppp0", "UGS")] {
    let other = FakeRuntime(); other.state.interfaceIndex = 1
    other.state.routes.removeAll { $0.network == lanNetwork }
    let otherEngine = ExternalVPNEngine(runtime: other)
    let otherPending = try! otherEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
    other.state = connected(); other.state.interfaceIndex = 1
    other.state.routes.removeAll { $0.network == lanNetwork }
    let otherActive = try! otherEngine.tick(otherPending)
    other.state.routes.removeAll { $0.kind == .directInterface && $0.isOwned }
    other.state.routes.append(foreign)
    let otherStop = try! otherEngine.restore(otherActive)
    check("非原生直連的同網段路由 \(foreign.gateway) \(foreign.flags) 保留復原紀錄", otherStop.phase == .recoveryRequired && other.state.routes.contains(foreign))
}
let directTimeout = FakeRuntime(); directTimeout.state.interfaceIndex = 1
let directTimeoutEngine = ExternalVPNEngine(runtime: directTimeout)
let directTimeoutPending = try! directTimeoutEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
directTimeout.state = connected(); directTimeout.state.interfaceIndex = 1
directTimeout.state.routes.removeAll { $0.network == directTimeoutPending.baseline.localNetwork }
directTimeout.failAt = 1; directTimeout.failAfterAdd = true
let directTimeoutFailed = try! directTimeoutEngine.tick(directTimeoutPending)
check("direct 新增後逾時可依 WAL 精確復原", directTimeoutFailed.phase == .failed && directTimeout.removes == 1 && directTimeoutFailed.addedRoutes.isEmpty)

let directProfile = ExternalVPNProfile(protectedNetworks: ["203.0.0.0/16"], dnsMode: .preserveVPN, directIPv4: ["203.0.113.8"])
check("指定 IP 正規化並去重", try! ExternalVPNProfile(directIPv4: ["203.000.113.8", "203.0.113.8"]).validated().directIPv4 == ["203.0.113.8"])
for invalid in ["203.0.113.8/32", "203.0.113.8;id", "10.0.0.8", "127.0.0.1", "224.0.0.1", "255.255.255.255"] {
    check("指定 IP 拒絕無效或非公用位址 \(invalid)", rejected { try ExternalVPNProfile(directIPv4: [invalid]).validated() })
}
check("指定 IP 限制小型清單", rejected { try ExternalVPNProfile(directIPv4: Array(repeating: "203.0.113.8", count: 33)).validated() })
let directRuntime = FakeRuntime(); let directEngine = ExternalVPNEngine(runtime: directRuntime)
let directPending = try! directEngine.prepare(owner: 501, profile: directProfile)
directRuntime.state = connected(); directRuntime.state.routes.append(route("203.0.0.0/16", "198.51.100.1", "ppp0"))
let directActive = try! directEngine.tick(directPending)
check("保留 /16 只新增明確指定 /32", directActive.phase == .active && directActive.addedRoutes.contains { $0.network == network("203.0.113.8/32") && $0.interface == "en0" })
check("指定 IP 旁的同網段位址仍走 VPN", CompanyVPNPlanner.winners(try! ExternalIPv4("203.0.113.9"), routes: directRuntime.state.routes).allSatisfy { $0.interface == "ppp0" })
let conflictingDNSProfile = ExternalVPNProfile(dnsMode: .preserveVPN, directIPv4: ["198.51.100.53"])
let conflictingDNSSession = ExternalVPNSession(owner: 501, baseline: baseline(), profile: conflictingDNSProfile)
check("指定 IP 不得繞過 VPN DNS", rejected { try ExternalVPNPlanner.plan(conflictingDNSSession, current: connected(), tunnel: "ppp0") })
var hostCollision = connected(); hostCollision.routes += [route("203.0.0.0/16", "198.51.100.1", "ppp0"), route("203.0.113.8/32", "198.51.100.1", "ppp0")]
check("指定 IP 遇相同 host foreign 路由不覆寫", rejected { try ExternalVPNPlanner.plan(directPending, current: hostCollision, tunnel: "ppp0") })
var legacyActive = borrowedActive; legacyActive.routingEvidence = nil; legacyActive.journalVersion = nil
borrowedRuntime.state = borrowedSnapshot
check("舊 active 無證據不維持成功", try! borrowedEngine.tick(legacyActive).phase == .failed)
let endpointEvidence = ExternalVPNRoutingEvidence(publicNetworks: [network("255.255.255.255/32")], directHosts: [], borrowedRoutes: baseline().routes, physicalInterfaceIndex: 1)
var endpointSession = ExternalVPNSession(owner: 501, baseline: baseline(), profile: ExternalVPNProfile())
endpointSession.tunnel = "ppp0"
var endpointCurrent = baseline(); endpointCurrent.routes.append(route("0.0.0.0/1", "198.51.100.1", "ppp0"))
check("完整區間驗證可表示 IPv4 最大半開端點", !rejected { try endpointEvidence.validate(endpointSession, current: endpointCurrent) })
var excessive = connected()
excessive.routes += (0..<9000).map { route("\(ExternalIPv4(value: UInt32(0xcb000000 + $0 * 2)))/32") }
let oversizedEvidence = ExternalVPNRoutingEvidence(publicNetworks: [network("203.0.0.0/16")], directHosts: [], borrowedRoutes: baseline().routes, physicalInterfaceIndex: 1)
check("路由切分超過上限明確拒絕而不抽樣", rejected { try oversizedEvidence.validate(endpointSession, current: excessive) })


for legacyVersion: Int? in [nil, 2] {
    let oldRuntime = FakeRuntime()
    let oldEngine = ExternalVPNEngine(runtime: oldRuntime)
    var oldBaseline = baseline(); oldBaseline.interfaceIndex = nil
    var previous = ExternalVPNSession(owner: 501, baseline: oldBaseline, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
    previous.phase = .failed; previous.journalVersion = legacyVersion
    let decoded = try! ExternalVPNJournal.decode(ExternalVPNJournal.encode(previous))
    oldRuntime.state = connected(); oldRuntime.state.interfaceIndex = 1
    oldRuntime.state.routes.removeAll { $0.network == decoded.baseline.localNetwork }
    let retry = try! oldEngine.prepare(owner: 501, profile: decoded.profile, previous: decoded)
    let retriedLAN = try! oldEngine.tick(retry)
    check("legacy \(legacyVersion ?? 1) failed 重試沿用原快照成功補 LAN", retriedLAN.phase == .active && retriedLAN.baseline.routes == previous.baseline.routes && retriedLAN.baseline.interfaceIndex == nil && retriedLAN.journalVersion == 3 && retriedLAN.addedRoutes.first?.gateway == "link#1")
    var renumbered = oldRuntime.state; renumbered.interfaceIndex = 2
    check("legacy \(legacyVersion ?? 1) 遷移後持續拒絕 ifindex 變動", rejected { try retriedLAN.routingEvidence!.validate(retriedLAN, current: renumbered) })
    for index: UInt32? in [nil, 0] {
        var invalid = oldRuntime.state; invalid.interfaceIndex = index
        check("legacy \(legacyVersion ?? 1) 遷移後持續拒絕缺少或零 ifindex \(index ?? 0)", rejected { try retriedLAN.routingEvidence!.validate(retriedLAN, current: invalid) })
    }
    var legacyRestore = previous
    let legacyOwned = route("203.0.113.8/32", "192.0.2.1", "en0", "UGHS1")
    legacyRestore.addedRoutes = [legacyOwned]; legacyRestore.phase = .active
    oldRuntime.state = connected(); oldRuntime.state.routes.append(legacyOwned)
    let restored = try! oldEngine.restore(ExternalVPNJournal.decode(ExternalVPNJournal.encode(legacyRestore)))
    check("legacy \(legacyVersion ?? 1) active 無新證據仍可精確復原", restored.phase == .idle && !oldRuntime.state.routes.contains(legacyOwned))
}
var missingOriginal = baseline(); missingOriginal.interfaceIndex = nil; missingOriginal.routes.removeAll { $0.network == network("192.0.2.0/24") }
let unprovenLAN = ExternalVPNSession(owner: 501, baseline: missingOriginal, profile: ExternalVPNProfile())
var currentUnprovenLAN = connected(); currentUnprovenLAN.interfaceIndex = 1
currentUnprovenLAN.routes.removeAll { $0.network == network("192.0.2.0/24") }
check("legacy 無原始 connected link 證據不得恢復 LAN", rejected { try ExternalVPNPlanner.plan(unprovenLAN, current: currentUnprovenLAN, tunnel: "ppp0") })
for (name, replacement) in [
    ("link 身分不同", route("192.0.2.0/24", "link#2", "en0", "US1")),
    ("介面不同", route("192.0.2.0/24", "link#1", "en1", "US1")),
    ("其他程式重建非原路由", route("192.0.2.0/24", "link#2", "en0", "UCS"))
] {
    let conflictRuntime = FakeRuntime(); conflictRuntime.state.interfaceIndex = 1
    let conflictEngine = ExternalVPNEngine(runtime: conflictRuntime)
    let pending = try! conflictEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
    conflictRuntime.state = connected(); conflictRuntime.state.interfaceIndex = 1
    conflictRuntime.state.routes.removeAll { $0.network == pending.baseline.localNetwork }
    let active = try! conflictEngine.tick(pending)
    conflictRuntime.state.routes.removeAll { $0.network == pending.baseline.localNetwork }
    conflictRuntime.state.routes.append(replacement)
    let cleaned = try! conflictEngine.restore(active)
    check("direct CAS \(name)保留紀錄且不刪外來路由", cleaned.phase == .recoveryRequired && cleaned.addedRoutes.count == 1 && conflictRuntime.state.routes.contains(replacement))
}
let verifyFailureRuntime = FakeRuntime(); let verifyFailureEngine = ExternalVPNEngine(runtime: verifyFailureRuntime)
let verifyFailurePending = try! verifyFailureEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
verifyFailureRuntime.state = connected(); verifyFailureRuntime.failSnapshotAt = 3
let verificationFailed = try! verifyFailureEngine.tick(verifyFailurePending)
check("套用後無法讀取驗證快照不標 active 並撤回 owned", verificationFailed.phase == .failed && verificationFailed.latestFailure?.stage == .verifying && verificationFailed.addedRoutes.isEmpty && verifyFailureRuntime.removes > 0)

for index: UInt32? in [nil, 0] {
    var oldBaseline = baseline(); oldBaseline.interfaceIndex = nil
    let oldSession = ExternalVPNSession(owner: 501, baseline: oldBaseline, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
    var current = connected(); current.interfaceIndex = index
    check("原 LAN 仍在也拒絕缺少或零 activation ifindex \(index ?? 0)", rejected { try ExternalVPNPlanner.plan(oldSession, current: current, tunnel: "ppp0") })
}
let vanishedRuntime = FakeRuntime(); let vanishedEngine = ExternalVPNEngine(runtime: vanishedRuntime)
let vanishedPending = try! vanishedEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
vanishedRuntime.state = connected()
vanishedRuntime.mutateSnapshot = { current, count in
    if count == 3 { current.routes.removeAll(where: \.isTunnel) }
}
let vanishedResult = try! vanishedEngine.tick(vanishedPending)
check("套用第 3 次快照 F5 消失不得 active 並撤回 owned", vanishedResult.phase == .failed && vanishedResult.latestFailure?.stage == .verifying && vanishedResult.addedRoutes.isEmpty && vanishedRuntime.removes > 0 && !vanishedRuntime.state.routes.contains(where: \.isOwned))
var unselected = borrowedActive; unselected.tunnel = nil
check("完整證據缺少已選通道不得驗證成功", rejected { try borrowedActive.routingEvidence!.validate(unselected, current: borrowedSnapshot) })
check("未選通道仍可單獨驗證實體網路身分", !rejected { try ExternalVPNRoutingEvidence.validateNetwork(unselected, borrowedSnapshot) })

let mixedRuntime = FakeRuntime()
mixedRuntime.state.dns = [ExternalDNSEntry(key: physicalDNS.key, interface: "en0", value: plist(["ServerAddresses": ["203.0.113.53", "2001:db8::53"]]))]
mixedRuntime.state.defaultDNSServers = ["203.0.113.53", "2001:db8::53"]
let mixedEngine = ExternalVPNEngine(runtime: mixedRuntime)
let mixedPending = try! mixedEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN, directIPv4: ["203.0.113.8"]))
mixedRuntime.state.routes += connected().routes.filter(\.isTunnel)
check("混合 IPv4 IPv6 原 DNS 保持不變時可規劃 DNS", !rejected { try ExternalVPNPlanner.dnsPlan(mixedPending, current: mixedRuntime.state, tunnel: "ppp0") })
check("混合 IPv4 IPv6 原 DNS 保持不變時可規劃路由", !rejected { try ExternalVPNPlanner.plan(mixedPending, current: mixedRuntime.state, tunnel: "ppp0") })
let mixedActive = try! mixedEngine.tick(mixedPending)
check("混合 IPv4 IPv6 原 DNS 可分流且持續驗證", mixedActive.phase == .active && (try! mixedEngine.tick(mixedActive)).phase == .active && mixedRuntime.dnsWrites == 0)
let mixedCollisionProfile = ExternalVPNProfile(dnsMode: .preserveVPN, directIPv4: ["203.0.113.53"])
let mixedCollision = ExternalVPNSession(owner: mixedPending.owner, baseline: mixedPending.baseline, profile: mixedCollisionProfile)
var mixedCollisionCurrent = mixedPending.baseline
mixedCollisionCurrent.routes += connected().routes.filter(\.isTunnel)
check("混合 DNS 的 IPv4 仍不得被指定直連繞過", rejected { try ExternalVPNPlanner.plan(mixedCollision, current: mixedCollisionCurrent, tunnel: "ppp0") })
if let evidence = mixedActive.routingEvidence {
    var collision = mixedRuntime.state
    collision.dns[0] = ExternalDNSEntry(key: physicalDNS.key, interface: "en0", value: plist(["ServerAddresses": ["203.0.113.8", "2001:db8::53"]]))
    check("作用中混合 DNS 的 IPv4 直連碰撞仍拒絕", rejected { try evidence.validate(mixedActive, current: collision) })
} else { check("作用中混合 DNS 保留完整路由證據", false) }

let bootUUID = "F7D0D772-8831-4A8E-8119-D42D6F275D15"
func bootSnapshot(_ id: String, _ session: String?) -> ExternalNetworkSnapshot { var state = baseline(); state.bootID = id; state.bootSession = session; return state }
check("同一次開機的 boottime 微秒漂移仍視為同一次開機", ExternalVPNPlanner.sameBoot(bootSnapshot("1792598984.86325", bootUUID), bootSnapshot("1792598984.92919", bootUUID)))
check("開機 session UUID 不同即視為不同開機", !ExternalVPNPlanner.sameBoot(bootSnapshot("1792598984.86325", bootUUID), bootSnapshot("1792598984.86325", "00000000-0000-0000-0000-000000000000")))
check("舊紀錄沒有 UUID 時以秒數比對", ExternalVPNPlanner.sameBoot(bootSnapshot("1792598984.86325", nil), bootSnapshot("1792598984.92919", bootUUID)))
check("舊紀錄秒數不同即視為重新開機", !ExternalVPNPlanner.sameBoot(bootSnapshot("1792598984.86325", nil), bootSnapshot("1792699999.1", bootUUID)))
check("無法解析的開機識別只接受完全相同", ExternalVPNPlanner.sameBoot(bootSnapshot("test-boot", nil), bootSnapshot("test-boot", nil)) && !ExternalVPNPlanner.sameBoot(bootSnapshot("test-boot", nil), bootSnapshot("other-boot", nil)))
let newJournal = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(bootSnapshot("1792598984.86325", bootUUID))) as! [String: Any]
check("bootID 維持舊格式，UUID 另存欄位供降版相容", newJournal["bootID"] as? String == "1792598984.86325" && newJournal["bootSession"] as? String == bootUUID)
let bootDriftRuntime = FakeRuntime(); bootDriftRuntime.state.bootID = "1792598984.86325"; bootDriftRuntime.state.bootSession = bootUUID
let bootDriftEngine = ExternalVPNEngine(runtime: bootDriftRuntime)
let bootDriftPending = try! bootDriftEngine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: .preserveVPN))
bootDriftRuntime.state = connected(); bootDriftRuntime.state.bootID = "1792598984.92919"; bootDriftRuntime.state.bootSession = bootUUID
let bootDriftActive = try! bootDriftEngine.tick(bootDriftPending)
check("boottime 微秒漂移後仍可啟用分流", bootDriftActive.phase == .active)
let bootDriftAdds = bootDriftRuntime.adds, bootDriftRemovesBefore = bootDriftRuntime.removes
let bootDriftStop = try! bootDriftEngine.restore(bootDriftActive)
check("boottime 微秒漂移後停止會實際移除自己的路由", bootDriftStop.phase == .idle && bootDriftRuntime.removes - bootDriftRemovesBefore == bootDriftAdds)

// F5 point-to-point 通道：對端位址剛好是公司 DHCP 給的 DNS 1.1.1.1，路由形狀照實測 netstat -rn 欄位。
let f5Tunnel = """
0/1                10.0.0.127         UScg                utun4
1.1.1.1            10.0.0.127         UHr                 utun4
1.1.1.1/32         link#34            UCS                 utun4
10/8               10.0.0.127         UGSc                utun4
10.0.0.127/32      1.1.1.1            USc                 utun4
128.0/1            10.0.0.127         USc                 utun4
"""
let f5DNS = ExternalDNSEntry(key: "State:/Network/Service/f5/DNS", interface: "utun4", value: plist(["ServerAddresses": ["10.0.0.53"], "SupplementalMatchDomains": ["internal.example.com"]]))
func f5Baseline(_ servers: [String]) -> ExternalNetworkSnapshot {
    var state = baseline()
    state.dns = [ExternalDNSEntry(key: physicalDNS.key, interface: "en0", value: plist(["ServerAddresses": servers]))]
    state.defaultDNSServers = servers
    return state
}
func f5Connected(_ servers: [String], tunnel: String = f5Tunnel) -> ExternalNetworkSnapshot {
    var state = f5Baseline(servers)
    state.routes += ExternalVPNPlanner.parseRoutes(tunnel)
    state.dns.append(f5DNS)
    return state
}
func f5Session(_ servers: [String], _ profile: ExternalVPNProfile = ExternalVPNProfile()) -> ExternalVPNSession {
    ExternalVPNSession(owner: 501, baseline: f5Baseline(servers), profile: profile)
}
func dnsError(_ session: ExternalVPNSession, _ current: ExternalNetworkSnapshot) -> String? {
    do { _ = try ExternalVPNPlanner.dnsPlan(session, current: current, tunnel: "utun4"); return nil } catch { return error.localizedDescription }
}
let companyDNS = ["1.1.1.1", "168.95.1.1", "8.8.8.8"]
let f5Routes = ExternalVPNPlanner.parseRoutes(f5Tunnel)
check("F5 對端主機路由加成對反向路由認定為通道端點", ExternalVPNPlanner.tunnelEndpoints(f5Routes, interface: "utun4") == [try! ExternalIPv4("1.1.1.1")])
check("其他介面不認定 F5 端點", ExternalVPNPlanner.tunnelEndpoints(f5Routes, interface: "utun5").isEmpty)
check("帶 G 的主機路由不是通道端點", ExternalVPNPlanner.tunnelEndpoints(ExternalVPNPlanner.parseRoutes("1.1.1.1 10.0.0.127 UGHr utun4\n10.0.0.127/32 1.1.1.1 USc utun4\n"), interface: "utun4").isEmpty)
check("反向路由指向別的位址不是通道端點", ExternalVPNPlanner.tunnelEndpoints(ExternalVPNPlanner.parseRoutes("1.1.1.1 10.0.0.127 UHr utun4\n10.0.0.127/32 1.0.0.1 USc utun4\n"), interface: "utun4").isEmpty)

let f5Plan = try? ExternalVPNPlanner.dnsPlan(f5Session(companyDNS), current: f5Connected(companyDNS), tunnel: "utun4")
check("(a) F5 端點撞 DNS 1.1.1.1 但另有實體 DNS 時照常規劃", f5Plan != nil)
check("(a) 略過的端點 DNS 只有 1.1.1.1", f5Plan?.skippedEndpointDNS == ["1.1.1.1"])
for mode in [ExternalVPNDNSMode.splitDomains, .preserveVPN] {
    let runtime = FakeRuntime(); runtime.state = f5Baseline(companyDNS)
    let engine = ExternalVPNEngine(runtime: runtime)
    let pending = try! engine.prepare(owner: 501, profile: ExternalVPNProfile(dnsMode: mode))
    runtime.state = f5Connected(companyDNS)
    let active = try! engine.tick(pending)
    check("(a) \(mode.rawValue) F5 端點撞 DNS 時啟用分流並說明", active.phase == .active && active.message.contains("1.1.1.1 是 VPN 通道端點"))
    let again = try! engine.tick(active)
    check("(a) \(mode.rawValue) 作用中重新驗證維持 active 且不重複附註", again.phase == .active && again.message == active.message && runtime.adds == active.addedRoutes.count)
}
let onlyEndpoint = dnsError(f5Session(["1.1.1.1"]), f5Connected(["1.1.1.1"]))
check("(b) 原本 DNS 只有通道端點時拒絕", onlyEndpoint?.contains("全部") == true && onlyEndpoint?.contains("1.1.1.1") == true)
let coveredOnly = dnsError(f5Session(companyDNS), f5Connected(companyDNS, tunnel: "0/1 10.0.0.127 UScg utun4\n1.1.1/24 10.0.0.127 USc utun4\n10/8 10.0.0.127 UGSc utun4\n128.0/1 10.0.0.127 USc utun4\n"))
check("(c) 原本 DNS 被一般通道網段接管照舊拒絕並寫出細節", coveredOnly == "原本的 DNS 1.1.1.1 被 utun4 的 1.1.1.0/24 路由接管，未套用分流")
let coveredEndpoint = dnsError(f5Session(companyDNS), f5Connected(companyDNS, tunnel: f5Tunnel + "\n1.1.1/24 10.0.0.127 USc utun4\n"))
check("(c) 端點同時被較寬通道網段覆蓋仍拒絕", coveredEndpoint?.contains("原本的 DNS 1.1.1.1 被 utun4") == true)
let oneWay = dnsError(f5Session(companyDNS), f5Connected(companyDNS, tunnel: "0/1 10.0.0.127 UScg utun4\n1.1.1.1 10.0.0.127 UHr utun4\n10/8 10.0.0.127 UGSc utun4\n128.0/1 10.0.0.127 USc utun4\n"))
check("(d) 只有單向主機路由不認定為端點且照舊拒絕", oneWay == "原本的 DNS 1.1.1.1 被 utun4 的 1.1.1.1/32 路由接管，未套用分流")
let otherTunnel = dnsError(f5Session(companyDNS), f5Connected(companyDNS, tunnel: f5Tunnel + "\n1.1.1.1/32 10.0.0.9 USc utun9\n"))
check("端點另被其他通道介面的 /32 覆蓋時拒絕", otherTunnel != nil)
let failedRuntime = FakeRuntime(); failedRuntime.state = f5Baseline(["1.1.1.1"])
let failedF5Engine = ExternalVPNEngine(runtime: failedRuntime)
let failedF5Pending = try! failedF5Engine.prepare(owner: 501, profile: ExternalVPNProfile())
failedRuntime.state = f5Connected(["1.1.1.1"])
let failedF5 = try! failedF5Engine.tick(failedF5Pending)
check("(b) 只有端點 DNS 時 tick 失敗且零寫入", failedF5.phase == .failed && failedRuntime.adds == 0 && failedRuntime.dnsWrites == 0)

print("通過 \(pass)，失敗 \(fail)")
exit(fail == 0 ? 0 : 1)
