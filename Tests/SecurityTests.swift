import Foundation
let T = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: T + "/marks", withIntermediateDirectories: true)
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
func rejected(_ f: () throws -> Any) -> Bool { (try? f()) == nil }
let fm = FileManager.default
/// 用 zsh 以 set -a; source 載入文字，回傳指定的標記檔有沒有被建立
func sourced(_ text: String, marker: String) -> Bool {
  let f = "\(T)/env-\(marker).env"; try! text.write(toFile: f, atomically: true, encoding: .utf8)
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-f", "-c", "set -a; source '\(f)'"]
  try! p.run(); p.waitUntilExit()
  return fm.fileExists(atPath: "\(T)/marks/\(marker)")
}
let good = "203.0.113.10,203.0.113.20"

// 正對照：確認 sourced() 抓得到注入（未防護的寫法）
check("正對照：未防護的雙引號寫法會被執行", sourced("X=\"a $(touch \(T)/marks/control)\"\n", marker: "control"))

// 攻擊 1：名稱注入 $(…) 與反引號
let p1 = try! CompanyPresetStore.strictPreset(name: "Acme $(touch \(T)/marks/name1) `touch \(T)/marks/name2`", gatewaysCSV: good, remoteTS: "10.0.0.0/24")
let e1 = CompanyPresetStore.renderEnv(name: p1.name, gateways: p1.gateways, remoteTS: p1.remoteTS)
check("名稱注入：source 後不會執行 $(…)", !sourced(e1, marker: "name1"))
check("名稱注入：source 後不會執行反引號", !fm.fileExists(atPath: "\(T)/marks/name2"))
check("名稱的危險字元被移除", !p1.name.contains("$") && !p1.name.contains("`") && !p1.name.contains("/"))

// 攻擊 2：第 4 筆閘道夾帶指令
check("閘道超過 3 筆 → 整份拒絕", rejected { try CompanyPresetStore.strictPreset(name: "x", gatewaysCSV: "\(good),203.0.113.30,$(touch \(T)/marks/gw4)", remoteTS: "10.0.0.0/24") })
// 攻擊 3：單筆閘道含換行，重新定義變數並夾帶指令
check("閘道含換行 → 拒絕", rejected { try CompanyPresetStore.strictPreset(name: "x", gatewaysCSV: "1.2.3.4\nSPLITSWAN_GATEWAYS=\"1.2.3.4\"\n$(touch \(T)/marks/gwnl)", remoteTS: "10.0.0.0/24") })
check("閘道含 $ 字元 → 拒絕", rejected { try CompanyPresetStore.strictPreset(name: "x", gatewaysCSV: "$(id)", remoteTS: "10.0.0.0/24") })
// 網段
check("網段 0.0.0.0/0 → 拒絕", rejected { try CompanyPresetStore.strictPreset(name: "x", gatewaysCSV: good, remoteTS: "0.0.0.0/0") })
check("網段 /0 混在其他網段中 → 拒絕", rejected { try CompanyPresetStore.strictPreset(name: "x", gatewaysCSV: good, remoteTS: "10.0.0.0/24, 1.2.3.0/0") })
check("網段夾帶指令 → 拒絕", rejected { try CompanyPresetStore.strictPreset(name: "x", gatewaysCSV: good, remoteTS: "10.0.0.0/24,$(touch \(T)/marks/ts)") })

// 攻擊 4：明文 company.env 夾帶額外指令行
let evil = "SPLITSWAN_GATEWAYS=\"\(good)\"\nSPLITSWAN_REMOTE_TS=\"10.0.0.0/24\"\ntouch \(T)/marks/plain\n"
let evilURL = URL(fileURLWithPath: "\(T)/evil.env"); try! evil.write(to: evilURL, atomically: true, encoding: .utf8)
let p4 = try! CompanyPresetStore.readFile(at: evilURL)
let e4 = CompanyPresetStore.renderEnv(name: p4.name, gateways: p4.gateways, remoteTS: p4.remoteTS)
check("明文匯入重新產生內容，額外指令行不會被保留", !e4.contains("touch") && !sourced(e4, marker: "plain"))
check("重新產生的內容 source 後值正確", {
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
  let f = "\(T)/good.env"; try! e4.write(toFile: f, atomically: true, encoding: .utf8)
  p.arguments = ["-f", "-c", "set -a; source '\(f)'; print -r -- \"$SPLITSWAN_GATEWAYS|$SPLITSWAN_REMOTE_TS\""]
  let pipe = Pipe(); p.standardOutput = pipe; try! p.run(); p.waitUntilExit()
  return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .newlines) == "\(good)|10.0.0.0/24"
}())

// 加密檔的上限與正規化
let payload = ExportPayload(name: "N", gateways: [good], remoteTS: "10.0.0.0/24", psk: "k")
let nfc = "café-pass", nfd = "cafe\u{301}-pass"
let enc = try! ConfigExport.encrypt(payload, passphrase: nfc)
check("NFC 匯出、NFD 匯入可以解開", (try? ConfigExport.decrypt(enc, passphrase: nfd)) == payload)
var o = try! JSONSerialization.jsonObject(with: enc) as! [String: Any]
o["salt"] = Data(count: 65).base64EncodedString()
check("salt 超過 64 bytes → 拒絕", rejected { try ConfigExport.decrypt(JSONSerialization.data(withJSONObject: o), passphrase: nfc) })
o = try! JSONSerialization.jsonObject(with: enc) as! [String: Any]; o["iterations"] = 3_000_000
check("iterations 超過 2,000,000 → 拒絕", rejected { try ConfigExport.decrypt(JSONSerialization.data(withJSONObject: o), passphrase: nfc) })
check("超過 1 MB 的檔案 → 拒絕", rejected { try ConfigExport.decrypt(Data(count: 1_000_001), passphrase: nfc) })

// ConfigStore.validate：帳號白名單（換行、大括號會破壞 swanctl.conf 結構）
func settings(user: String = "alice", gw: String = "203.0.113.1", ts: String = "10.0.0.0/24") -> VPNSettings {
  var s = VPNSettings(); s.username = user; s.gateways = [gw, "", ""]; s.remoteTS = ts; return s
}
func valid(_ s: VPNSettings) -> Bool { (try? ConfigStore.validate(s)) != nil }
check("正對照：合法帳號、閘道、網段 → 接受", valid(settings(user: "alice.b_c@corp-1")))
check("帳號含換行 → 拒絕", !valid(settings(user: "alice\neap_id = mallory")))
check("帳號含 CR → 拒絕", !valid(settings(user: "alice\rbob")))
check("帳號含左大括號 → 拒絕", !valid(settings(user: "alice{")))
check("帳號含右大括號 → 拒絕", !valid(settings(user: "alice}")))
check("帳號含全形數字 → 拒絕", !valid(settings(user: "alice１２３")))
check("帳號含空白 → 拒絕", !valid(settings(user: "alice bob")))
check("帳號含雙引號 → 拒絕", !valid(settings(user: "alice\"")))
check("帳號空白 → 拒絕", !valid(settings(user: "")))
check("閘道含換行與大括號 → 拒絕", !valid(settings(gw: "203.0.113.1\n}\nx {")))
check("網段用全形數字 → 拒絕", !valid(settings(ts: "１０.0.0.0/24")))
check("網段前綴用全形數字 → 拒絕", !valid(settings(ts: "10.0.0.0/２４")))

// ConfigStore.quote：密碼、PSK 寫進 secret = "…" 前的跳脫
check("雙引號跳脫成 \\\"", ConfigStore.quote("a\"b") == "a\\\"b")
check("反斜線跳脫成 \\\\", ConfigStore.quote("a\\b") == "a\\\\b")
check("反斜線在雙引號前也各自跳脫", ConfigStore.quote("\\\"") == "\\\\\\\"")
for raw in ["p\"; } secrets { x", "end\\", "\\\"\\\"", "普通密碼"] {
  let q = ConfigStore.quote(raw)
  // 跳脫後的字串裡，每個雙引號前面都必須有奇數個反斜線（也就是不會提早結束字串）
  var unescapedQuote = false, slashes = 0
  for c in q { if c == "\\" { slashes += 1 } else { if c == "\"" && slashes % 2 == 0 { unescapedQuote = true }; slashes = 0 } }
  check("跳脫後沒有會結束字串的雙引號，且結尾不是落單反斜線：\(raw.debugDescription)", !unescapedQuote && slashes % 2 == 0)
  check("unquote(quote(x)) == x：\(raw.debugDescription)", ConfigStore.unquote(q) == raw)
}

// 密碼、PSK 含換行：直接測 validateSecret，不經由會寫入 /opt/homebrew/etc/swanctl 的 save()
check("PSK 含換行 → 拒絕", rejected { try ConfigStore.validateSecret("k\n}", name: "PSK") })
check("PSK 含 CR → 拒絕", rejected { try ConfigStore.validateSecret("k\r", name: "PSK") })
check("密碼含換行 → 拒絕", rejected { try ConfigStore.validateSecret("p\nsecret = x", name: "密碼") })
check("一般密碼（含引號、反斜線）→ 接受", !rejected { try ConfigStore.validateSecret("p\"a\\b", name: "密碼") })

let leftovers = (try? fm.contentsOfDirectory(atPath: "\(T)/marks"))?.filter { $0 != "control" } ?? []
check("所有攻擊標記檔都不存在（除了正對照）", leftovers.isEmpty)
print("\n通過 \(pass)，失敗 \(fail)")
