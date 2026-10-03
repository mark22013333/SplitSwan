// 產生 C# 測試用的 fixture：用 Mac 版原始碼實際跑出期望值
import Foundation

let out = CommandLine.arguments[1]
func write(_ name: String, _ text: String) {
    try! text.write(toFile: out + "/" + name, atomically: true, encoding: .utf8)
}
func esc(_ s: String) -> String {
    let d = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
    let t = String(data: d, encoding: .utf8)!
    return String(t.dropFirst().dropLast())
}

// 1. renderConf / renderSecrets
struct RenderCase { var name: String; var user: String; var gws: [String]; var ts: String; var psk: String; var pwd: String }
let renderCases = [
    RenderCase(name: "three", user: "alice@example.com", gws: ["203.0.113.10", "203.0.113.20", "198.51.100.30"],
               ts: "203.0.113.0/24, 198.51.100.5/32,192.0.2.0/24", psk: #"p"s\k 密鑰 !@#"#, pwd: #"pa"ss\wo"rd"#),
    RenderCase(name: "one", user: "bob", gws: ["vpn.example.com", "", ""], ts: "198.51.100.0/25", psk: "fake-psk", pwd: "secret"),
    RenderCase(name: "gap", user: "c.d_e-f", gws: ["", "203.0.113.20", "203.0.113.30"], ts: " 192.0.2.0/24 ,198.51.100.0/24 ", psk: "k", pwd: "p"),
    RenderCase(name: "padded", user: " carol ", gws: [" 203.0.113.10 ", "\t203.0.113.20", ""], ts: "  192.0.2.128/25  ", psk: "k2", pwd: "p2"),
]
var idx = "["
for (i, c) in renderCases.enumerated() {
    var s = VPNSettings()
    s.username = c.user; s.gateways = c.gws; s.remoteTS = c.ts
    let n = ConfigStore.normalized(s)
    write("render-\(c.name).conf", ConfigStore.renderConf(n))
    write("render-\(c.name).secrets", ConfigStore.renderSecrets(username: n.username, psk: ConfigStore.quote(c.psk), password: ConfigStore.quote(c.pwd)))
    let valid = (try? ConfigStore.validate(n)) != nil
    idx += (i > 0 ? ",\n" : "\n") + "{\"name\":\(esc(c.name)),\"user\":\(esc(c.user)),\"gateways\":[\(c.gws.map(esc).joined(separator: ","))],\"ts\":\(esc(c.ts)),\"psk\":\(esc(c.psk)),\"pwd\":\(esc(c.pwd)),\"macValid\":\(valid)}"
}
write("render-cases.json", idx + "\n]\n")

// 2. validate：每個案例記錄 Mac 版第一個錯誤訊息（null＝合法）
let G = ["203.0.113.10", "", ""]
let vcases: [(String, String, [String], String)] = [
    ("ok", "alice", G, "192.0.2.0/24"),
    ("ok-email", "a.b_c-d@example.com", G, "192.0.2.0/24"),
    ("user-empty", "", G, "192.0.2.0/24"),
    ("user-space", "al ice", G, "192.0.2.0/24"),
    ("user-newline-mid", "al\nice", G, "192.0.2.0/24"),
    ("user-newline-end", "alice\n", G, "192.0.2.0/24"),
    ("user-brace", "a}b", G, "192.0.2.0/24"),
    ("user-quote", "a\"b", G, "192.0.2.0/24"),
    ("user-unicode", "café", G, "192.0.2.0/24"),
    ("user-fullwidth-digit", "user１", G, "192.0.2.0/24"),
    ("user-padded-nbsp", "\u{00A0}alice\t", G, "192.0.2.0/24"),
    ("gw-none", "alice", ["", " ", ""], "192.0.2.0/24"),
    ("gw-hostname", "alice", ["vpn-1.example.com", "", ""], "192.0.2.0/24"),
    ("gw-bad-char", "alice", ["203.0.113.10;x", "", ""], "192.0.2.0/24"),
    ("gw-brace", "alice", ["203.0.113.10}", "", ""], "192.0.2.0/24"),
    ("gw-dollar", "alice", ["$(id)", "", ""], "192.0.2.0/24"),
    ("gw-newline-mid", "alice", ["203.0.113.10\nx", "", ""], "192.0.2.0/24"),
    ("gw-newline-end", "alice", ["203.0.113.10\n", "", ""], "192.0.2.0/24"),
    ("gw-second-bad", "alice", ["203.0.113.10", "bad gw", ""], "192.0.2.0/24"),
    ("ts-empty", "alice", G, ""),
    ("ts-only-commas", "alice", G, ",,"),
    ("ts-blank-item", "alice", G, "198.51.100.0/24, ,192.0.2.0/24"),
    ("ts-double-comma", "alice", G, "198.51.100.0/24,,192.0.2.0/24"),
    ("ts-zero", "alice", G, "203.0.113.0/0"),
    ("ts-zero-mixed", "alice", G, "192.0.2.0/24, 198.51.100.0/0"),
    ("ts-bare-ip", "alice", G, "198.51.100.5"),
    ("ts-octet-256", "alice", G, "192.0.2.256/32"),
    ("ts-prefix-33", "alice", G, "192.0.2.0/33"),
    ("ts-prefix-3digit", "alice", G, "192.0.2.0/100"),
    ("ts-prefix-32", "alice", G, "198.51.100.5/32"),
    ("ts-prefix-1", "alice", G, "198.51.100.0/1"),
    ("ts-fullwidth", "alice", G, "198.51.100.１/32"),
    ("ts-arabic-digit", "alice", G, "198.51.100.١/32"),
    ("ts-inject", "alice", G, "192.0.2.0/24,$(touch x)"),
    ("ts-newline", "alice", G, "198.51.100.0/24\n192.0.2.0/24"),
    ("ts-newline-end", "alice", G, "192.0.2.0/24\n"),
    ("ts-brace", "alice", G, "192.0.2.0/24}"),
    ("ts-ipv6", "alice", G, "2001:db8::/32"),
    ("ts-leading-zero", "alice", G, "198.51.100.010/32"),
    ("ts-four-digit", "alice", G, "198.51.100.1000/32"),
]
var v = "["
for (i, c) in vcases.enumerated() {
    var s = VPNSettings(); s.username = c.1; s.gateways = c.2; s.remoteTS = c.3
    var err = "null"
    do { try ConfigStore.validate(ConfigStore.normalized(s)) } catch { err = esc(error.localizedDescription) }
    v += (i > 0 ? ",\n" : "\n") + "{\"name\":\(esc(c.0)),\"user\":\(esc(c.1)),\"gateways\":[\(c.2.map(esc).joined(separator: ","))],\"ts\":\(esc(c.3)),\"macError\":\(err)}"
}
write("validate-cases.json", v + "\n]\n")

// 3. .splitswan：Mac 版 ConfigExport.encrypt 實際產生
let p1 = ExportPayload(name: "Demo", gateways: ["203.0.113.10", "203.0.113.20", ""], remoteTS: "192.0.2.0/24, 198.51.100.5/32", psk: #"p"s\k 密鑰 !@#"#)
try! ConfigExport.encrypt(p1, passphrase: "correct horse").write(to: URL(fileURLWithPath: out + "/demo.splitswan"))
let p2 = ExportPayload(name: "NoPsk", gateways: ["vpn.example.com"], remoteTS: "192.0.2.0/24", psk: nil)
try! ConfigExport.encrypt(p2, passphrase: "café-pass").write(to: URL(fileURLWithPath: out + "/nopsk-nfc.splitswan"))
let p3 = ExportPayload(name: "Evil", gateways: ["203.0.113.10", "203.0.113.20", "203.0.113.30", "203.0.113.40"], remoteTS: "203.0.113.0/0", psk: "a\nb")
try! ConfigExport.encrypt(p3, passphrase: "correct horse").write(to: URL(fileURLWithPath: out + "/evil.splitswan"))
// 自我驗證：Swift 能解回去
print((try? ConfigExport.decrypt(Data(contentsOf: URL(fileURLWithPath: out + "/demo.splitswan")), passphrase: "correct horse")) == p1 ? "demo 回解 OK" : "demo 回解失敗")
print((try? ConfigExport.decrypt(Data(contentsOf: URL(fileURLWithPath: out + "/nopsk-nfc.splitswan")), passphrase: "cafe\u{301}-pass")) == p2 ? "nopsk NFD 回解 OK" : "nopsk 回解失敗")
print("完成")
