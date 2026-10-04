// 產生 C# GatewayHistory 測試用的 fixture：用 Mac 版 Sources/GatewayHistory.swift 實際跑出期望值。
// 編譯方式見 Fixtures/README.md「gateway-cases.json」。範例位址只用 RFC 5737。
import Foundation

let outDir = CommandLine.arguments[1]
let now = Date(timeIntervalSince1970: 2_000_000)

// 固定種子的亂數（LCG），每次產生的內容相同
var seed: UInt64 = 20261004
func rnd(_ n: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Int((seed >> 33) % UInt64(n))
}
func pick<T>(_ a: [T]) -> T { a[rnd(a.count)] }

let addrPool = ["203.0.113.10", "198.51.100.20", "192.0.2.30", "VPN.Example.com", "vpn.example.com ", "", " ", "\t"]
let agoPool: [Double] = [0, 1, 30, 300, 598, 599, 599.5, 600, 600.5, 601, 1200, 3000, 5000, -10]
let secsPool: [Double?] = [nil, 0, 0.05, 0.15, 1, 2.25, 2.35, 3.24, 3.25, 4.45, 9.95, 16, 0.1 + 0.2]

struct AttemptOut: Codable { var gateway: Int; var address: String; var success: Bool; var seconds: Double?; var ago: Double }
struct GwOut: Codable {
    var n: Int; var cooling: Bool; var successRate: Double?; var avg: Double?; var consecutiveFailures: Int
    var records: Int; var detail: String?; var statusText: String
}
struct Case: Codable {
    var gateways: [String]; var attempts: [AttemptOut]
    var order: [Int]; var lastSuccess: Int?; var perGateway: [GwOut]
    var after: [AttemptOut]        // record 之後實際保留的紀錄（依序）
    var pruneWith: [String]; var pruned: [AttemptOut]
}

var cases: [Case] = []
for _ in 0..<200 {
    let gCount = 1 + rnd(4)                       // 1～4 台（含超出範圍的編號）
    var gws: [String] = (0..<gCount).map { _ in pick(addrPool) }
    if rnd(4) == 0 { gws = ["203.0.113.10", "198.51.100.20", "192.0.2.30"] }
    var h = GatewayHistory()
    var ins: [AttemptOut] = []
    for _ in 0..<rnd(30) {
        let n = 1 + rnd(4)
        let addr = n <= gws.count ? gws[n - 1] : pick(addrPool)
        let ago = pick(agoPool)
        let a = GatewayAttempt(gateway: n, address: rnd(8) == 0 ? pick(addrPool) : addr,
                               success: rnd(2) == 0, seconds: pick(secsPool), time: now.addingTimeInterval(-ago))
        ins.append(AttemptOut(gateway: a.gateway, address: a.address, success: a.success, seconds: a.seconds, ago: ago))
        h.record(a)
    }
    func out(_ x: GatewayHistory) -> [AttemptOut] {
        x.attempts.map { AttemptOut(gateway: $0.gateway, address: $0.address, success: $0.success, seconds: $0.seconds,
                                    ago: now.timeIntervalSince($0.time)) }
    }
    let per = (1...4).map { n in
        GwOut(n: n, cooling: h.isCooling(n, now: now), successRate: h.successRate(n), avg: h.averageSuccessSeconds(n),
              consecutiveFailures: h.consecutiveFailures(n), records: h.records(n).count, detail: h.detail(n), statusText: h.statusText(n))
    }
    let pw: [String] = (0..<(1 + rnd(3))).map { _ in pick(addrPool) }
    cases.append(Case(gateways: gws, attempts: ins, order: GatewayHistory.order(gateways: gws, history: h, now: now),
                      lastSuccess: h.lastSuccess, perGateway: per, after: out(h), pruneWith: pw, pruned: out(h.pruned(gateways: pw))))
}

struct RecordCase: Codable { var n: Int; var success: Bool; var output: String; var interrupted: Bool; var expected: Bool }
let outputs = ["", "fail vpn1", "fail vpn2", "fail vpn3", " fail vpn2 ", "\tfail vpn1\t", "FAIL VPN1", "fail vpn10", "fail vpn1x",
               "x\nfail vpn1\ny", "x\r\nfail vpn2\r\n", "a\rfail vpn3", "a\u{2028}fail vpn1", "a\u{85}fail vpn2", "a\u{0B}fail vpn3",
               "fail  vpn1", "fail all", "sudo: a password is required", "ok vpn1", "\u{00A0}fail vpn1\u{3000}",
               "\u{200B}fail vpn2", "fail vpn1\u{200B}", "prefix fail vpn1"]
var recordCases: [RecordCase] = []
for o in outputs { for n in 1...3 { for s in [false, true] { for i in [false, true] {
    recordCases.append(RecordCase(n: n, success: s, output: o, interrupted: i,
                                  expected: GatewayHistory.shouldRecord(gateway: n, success: s, output: o, interrupted: i)))
} } } }

struct ConnCase: Codable { var input: String?; var expected: Int? }
let conns: [String?] = [nil, "", "vpn", "vpn1", "vpn2", "vpn3", "vpn4", "vpn0", "VPN3", "Vpn2", "vpn+2", "vpn-1", "vpn02",
                        "vpn 2", "vpn2 ", "vpnx", "corp", "vpn99999999999999999999", "vpn１", "xvpn1", "vpn+", "vpn-"]
let connCases = conns.map { ConnCase(input: $0, expected: GatewayHistory.gateway(fromConnection: $0)) }

struct All: Codable { var cases: [Case]; var shouldRecord: [RecordCase]; var gatewayFromConnection: [ConnCase] }
let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys]
let data = try! enc.encode(All(cases: cases, shouldRecord: recordCases, gatewayFromConnection: connCases))
try! data.write(to: URL(fileURLWithPath: outDir + "/gateway-cases.json"))
print("cases=\(cases.count) shouldRecord=\(recordCases.count) conn=\(connCases.count)")
