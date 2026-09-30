import Foundation
// F3 診斷報告（docs/SPEC-1.3.md §5）：組字、遮蔽、目標推導、log 讀取、filelog 設定
let T = CommandLine.arguments[1]
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
func count(_ s: String, in text: String) -> Int { text.components(separatedBy: s).count - 1 }

// 假的密碼與 PSK（只用於測試）
let fakePwd = "Tr0ub4dor&3-fakepw"
let fakePSK = "psk-XyZ-123-fakepsk"

// MARK: 檔名
var dc = DateComponents(); dc.year = 2026; dc.month = 9; dc.day = 30; dc.hour = 14; dc.minute = 5; dc.second = 7
let fixed = Calendar.current.date(from: dc)!
check("檔名：<App>-診斷-yyyyMMdd-HHmmss.txt", DiagnosticReport.fileName(app: "TestApp", date: fixed) == "TestApp-診斷-20260930-140507.txt")

// MARK: 通道網段 → 目標（跟 diag.sh 相同規則）
check("/8 → 第一個可用位址", DiagnosticReport.targets(remoteTS: "10.0.0.0/8") == ["10.0.0.1"])
check("/32 → 該位址本身", DiagnosticReport.targets(remoteTS: "198.51.100.5/32") == ["198.51.100.5"])
check("多筆、去重（同一網段兩種寫法）", DiagnosticReport.targets(remoteTS: "203.0.113.64/26, 203.0.113.70/26 ,198.51.100.5/32")
      == ["203.0.113.65", "198.51.100.5"])
check("/0、格式錯誤、全形數字略過", DiagnosticReport.targets(remoteTS: "0.0.0.0/0, abc, 1.2.3/24, １0.0.0.0/8, 10.0.0.0/33") == [])
check("空字串 → 沒有目標", DiagnosticReport.targets(remoteTS: "") == [])

// MARK: route 輸出解析
let routeOut = "   route to: 10.0.0.1\ndestination: 10.0.0.0\n       mask: 255.0.0.0\n  interface: utun6\n      flags: <UP,DONE,STATIC>\n"
check("route：取出 interface", DiagnosticReport.interface(fromRoute: routeOut) == "utun6")
check("route：沒有 interface 行 → nil", DiagnosticReport.interface(fromRoute: "route: writing to routing socket: not in table") == nil)

// MARK: head／tail
check("head 取前 N 行", DiagnosticReport.head("a\nb\nc\nd", lines: 2) == "a\nb")
check("tail 取後 N 行（檔尾換行不算一行）", DiagnosticReport.tail("a\nb\nc\n", lines: 2) == "b\nc")

// MARK: readTail
let small = T + "/small.log"
try! "第一行\n第二行\n".write(toFile: small, atomically: true, encoding: .utf8)
if case .content(let t, let size) = DiagnosticReport.readTail(path: small) {
    check("readTail：小檔整份讀入", t == "第一行\n第二行\n" && size == UInt64("第一行\n第二行\n".utf8.count))
} else { check("readTail：小檔整份讀入", false) }
let big = T + "/big.log"
try! (0..<1000).map { "line \($0) xxxxxxxxxx" }.joined(separator: "\n").appending("\n").write(toFile: big, atomically: true, encoding: .utf8)
if case .content(let t, _) = DiagnosticReport.readTail(path: big, maxBytes: 1000) {
    check("readTail：只讀尾端、丟掉被切斷的第一行", t.hasPrefix("line ") && t.hasSuffix("line 999 xxxxxxxxxx\n") && t.utf8.count < 1000)
} else { check("readTail：只讀尾端", false) }
check("readTail：檔案不存在 → missing", DiagnosticReport.readTail(path: T + "/nope.log") == .missing)

// MARK: 遮蔽（只靠正則，不給實際密碼）
let forms: [(String, String)] = [
    ("swanctl：secret = \"…\"", "    secret = \"\(fakePSK)\""),
    ("swanctl：secret 值含跳脫雙引號", "secret = \"ab\\\"\(fakePwd)\\\"cd\""),
    ("PSK: …", "  PSK: \(fakePSK)"),
    ("psk=…", "ike_psk=\(fakePSK)"),
    ("password=…", "password=\(fakePwd) next"),
    ("eap_password = '…'", "eap_password = '\(fakePwd)'"),
    ("JSON \"password\": \"…\"", "{\"password\": \"\(fakePwd)\", \"id\": 1}"),
    ("Pre-Shared Key: …", "Pre-Shared Key: \(fakePSK)"),
    ("xauth_secret=…", "xauth_secret=\(fakePwd)"),
    ("大寫 PASSWORD : …", "PASSWORD : \(fakePwd)"),
    // ipsec.secrets 語法
    ("ipsec.secrets : PSK \"…\"", "203.0.113.10 : PSK \"\(fakePSK)\""),
    ("ipsec.secrets : EAP \"…\"", "user01 : EAP \"\(fakePwd)\""),
    ("ipsec.secrets : XAUTH …（不加引號）", "user01 : XAUTH \(fakePwd)"),
    ("eap_secret=…", "eap=\(fakePwd)"),
    // 沒加引號、值含 ; , } 或空白：遮到行尾
    ("password=ab;…（分號後）", "password=ab;\(fakePwd)"),
    ("secret: 值含空白", "secret: my phrase \(fakePwd)"),
    ("psk=值含逗號與大括號", "psk=a,b}\(fakePSK)"),
]
for (name, input) in forms {
    let out = DiagnosticReport.redact(input, secrets: [])
    check("正則遮蔽 \(name)", !out.contains(fakePwd) && !out.contains(fakePSK) && out.contains("***"))
}
let benign = "12[IKE] authentication of '203.0.113.10' with pre-shared key successful\n13[IKE] EAP method EAP_MSCHAPV2 succeeded"
check("不含值的一般 log 不被改動", DiagnosticReport.redact(benign, secrets: []) == benign)
// 關鍵字在行尾時，不可以跨行把下一行（例：段落標題 =====）當成值吃掉
let crossLine = "status foo-psk\n\n===== 下一段 =====\n"
check("遮蔽不跨行", DiagnosticReport.redact(crossLine, secrets: []) == crossLine)
let toEOL = DiagnosticReport.redact("password=ab;\(fakePwd)\n下一行保留", secrets: [])
check("未加引號遮到行尾，但下一行保留", toEOL == "password=***\n下一行保留")
let quotedKeep = DiagnosticReport.redact("secret = \"\(fakePSK)\" # 註解保留", secrets: [])
check("加引號時只遮字串本身", quotedKeep == "secret = *** # 註解保留")
let benign2 = "13[IKE] received EAP identity 'user01'\n    auth = eap\n    eap_id = user01\n14:00:01 13[IKE] EAP method EAP_MSCHAPV2 succeeded"
check("一般的 EAP log 與設定不被改動", DiagnosticReport.redact(benign2, secrets: []) == benign2)

// MARK: 遮蔽（第二道防線：精確字串取代）
let loose = "12[CFG] 使用者輸入了 \(fakePwd) 這個字串"
check("正對照：不在關鍵字後面的密碼，正則抓不到", DiagnosticReport.redact(loose, secrets: []).contains(fakePwd))
check("精確取代：給了實際密碼就換掉", !DiagnosticReport.redact(loose, secrets: [fakePwd]).contains(fakePwd))
let escapedRaw = "pa\\\"ss-\(fakePwd)"          // secrets.conf 裡的原始寫法（含跳脫）
let escapedPlain = "pa\"ss-\(fakePwd)"          // 還原後
let mixed = "raw=\(escapedRaw)|plain \(escapedPlain)|"
let mixedOut = DiagnosticReport.redact(mixed, secrets: [escapedPlain, escapedRaw])
check("精確取代：原始與還原兩種寫法都換掉", !mixedOut.contains(fakePwd))
check("精確取代：空字串不影響輸出", DiagnosticReport.redact("abc", secrets: [""]) == "abc")
// 太短的密碼不做精確取代，避免把 IP 片段換掉、讓人從位置反推密碼
let ipText = "  10.12.0.1  介面=utun6\nvpn1: 203.0.113.12[4500]"
check("短密碼（\"12\"）不會把 IP 片段換掉", DiagnosticReport.redact(ipText, secrets: ["12"]) == ipText)
check("5 字元以下不取代、6 字元以上取代", DiagnosticReport.redact("x abcde y", secrets: ["abcde"]) == "x abcde y"
      && DiagnosticReport.redact("x abcdef y", secrets: ["abcdef"]) == "x *** y")
check("短密碼出現在關鍵字後面仍由正則遮蔽", DiagnosticReport.redact("password=12", secrets: ["12"]) == "password=***")

// MARK: 整份報告：假密碼散落在多處，輸出 0 命中
var h = GatewayHistory()
h.record(GatewayAttempt(gateway: 1, address: "203.0.113.10", success: true, seconds: 3.2, time: fixed.addingTimeInterval(-100)))
h.record(GatewayAttempt(gateway: 2, address: "203.0.113.20", success: false, seconds: 16.0, time: fixed.addingTimeInterval(-50)))
var settings = VPNSettings(); settings.username = "user01"; settings.gateways = ["203.0.113.10", "203.0.113.20", ""]
settings.remoteTS = "10.0.0.0/8, 198.51.100.5/32"
func ok(_ s: String) -> DiagnosticReport.CommandResult { .init(code: 0, output: s) }
let logLines = (0..<400).map { "2026-09-30 14:00:00 12[IKE] log 第 \($0) 行" }
    + ["2026-09-30 14:00:01 13[CFG] loaded EAP secret for user01 password=\(fakePwd)",
       "2026-09-30 14:00:02 13[IKE] 使用者輸入 \(fakePwd) 與 \(fakePSK)"]
let input = DiagnosticReport.Input(
    generatedAt: fixed, elapsed: 4.2, appName: "TestApp", appVersion: "9.9.9（build 99）",
    macOSVersion: "Version 15.0 (Build 24A335)", chip: ok("arm64"),
    checks: ["[正常] strongSwan：已安裝", "[異常] 測試項目：detail 含 \(fakePwd)"],
    helperStatus: ok("connected vpn1 10.255.0.4 198.51.100.10 30 \(fakePSK)"),
    helperSAs: ok("vpn1: #1, ESTABLISHED, IKEv2\n  secret = \"\(fakePSK)\"\n  corp: #1, INSTALLED\n  note \(fakePwd)"),
    settings: settings, pskSet: true, passwordSet: true, history: h,
    routes: [("10.0.0.1", ok(routeOut)), ("198.51.100.5", .init(code: 1, output: "route: not in table \(fakePwd)"))],
    dns: ok((0..<60).map { "dns 行 \($0)" }.joined(separator: "\n") + "\nnameserver \(fakePSK)"),
    dnsProbe: ok("name: www.apple.com\nip_address: 198.51.100.1"),
    httpsProbe: .init(code: 28, output: "curl: (28) timeout \(fakePwd)", timedOut: false, seconds: 6),
    charonLog: .content(logLines.joined(separator: "\n") + "\n", size: 12345),
    logPath: "/var/log/splitswan/charon.log")
let raw = DiagnosticReport.render(input)
check("正對照：未遮蔽版本確實含假密碼與假 PSK（測試有餵到）", count(fakePwd, in: raw) >= 5 && count(fakePSK, in: raw) >= 3)
let report = DiagnosticReport.build(input, secrets: [fakePwd, fakePSK])
check("報告裡找不到假密碼（0 命中）", count(fakePwd, in: report) == 0)
check("報告裡找不到假 PSK（0 命中）", count(fakePSK, in: report) == 0)
check("設定摘要：密碼與 PSK 只寫「已設定」", report.contains("預設共享金鑰：已設定") && report.contains("密碼：已設定"))
let unset = DiagnosticReport.build({ var x = input; x.pskSet = false; x.passwordSet = false; return x }(), secrets: [])
check("設定摘要：未設定時寫「未設定」", unset.contains("預設共享金鑰：未設定") && unset.contains("密碼：未設定"))
for title in ["App 與系統", "環境檢查", "連線狀態（輔助程式 status）", "SA 清單（輔助程式 sas）", "設定摘要",
              "閘道連線紀錄", "通道網段內的目標", "DNS 設定", "外網探測", "charon log"] {
    check("段落存在：\(title)", report.contains("===== \(title)"))
}
check("App 名稱、版本、macOS、晶片", report.contains("TestApp 9.9.9（build 99）") && report.contains("Version 15.0") && report.contains("晶片：arm64"))
check("設定摘要含帳號、閘道、網段", report.contains("帳號：user01") && report.contains("閘道 VPN1：203.0.113.10")
      && report.contains("閘道 VPN3：（未設定）") && report.contains("通道網段：10.0.0.0/8, 198.51.100.5/32"))
check("F4 紀錄：每台狀態與逐筆紀錄", report.contains("VPN1 · 上次 3.2 秒連上") && report.contains("VPN2 · 最近 1 次失敗")
      && report.contains("失敗  16.0 秒  203.0.113.20"))
check("路由：成功的顯示介面", report.contains("10.0.0.1  介面=utun6"))
check("路由：失敗的顯示 ? 與結束代碼", report.contains("198.51.100.5  介面=?") && report.contains("結束代碼 1"))
check("DNS 只取前 40 行", report.contains("dns 行 39") && !report.contains("dns 行 40"))
check("charon log 只取最後 300 行", !report.contains("log 第 101 行\n") && report.contains("log 第 102 行") && report.contains("log 第 399 行"))
check("外網探測：非 0 結束代碼有註明", report.contains("結束代碼 28"))
let timeoutReport = DiagnosticReport.describe(.init(code: 15, output: "", timedOut: true, seconds: 5))
check("逾時註明「超過 5 秒未完成」", timeoutReport.contains("超過 5 秒未完成"))

var noLog = input; noLog.charonLog = .missing
check("log 檔不存在：寫明並提示更新系統元件", DiagnosticReport.build(noLog, secrets: []).contains("找不到 log 檔") && DiagnosticReport.build(noLog, secrets: []).contains("更新"))
var emptyLog = input; emptyLog.charonLog = .content("", size: 0)
check("log 檔是空的：寫明", DiagnosticReport.build(emptyLog, secrets: []).contains("log 檔是空的"))

// MARK: filelog 設定（規格 §5.3）
let tuning = ConfigStore.renderCharonTuning()
check("filelog：路徑", tuning.contains("path = /var/log/splitswan/charon.log") && ConfigStore.charonLogPath == "/var/log/splitswan/charon.log")
check("filelog：等級固定 1", tuning.contains("default = 1"))
check("filelog：append = yes、flush_line = yes", tuning.contains("append = yes") && tuning.contains("flush_line = yes"))
check("filelog：time_format 帶日期時間", tuning.contains("time_format = %Y-%m-%d %H:%M:%S"))
check("保留既有重送參數", tuning.contains("retransmit_timeout = 2.0") && tuning.contains("retransmit_tries = 3") && tuning.contains("retransmit_base = 1.5"))
check("filelog 在 charon 區塊內、大括號成對", count("{", in: tuning) == count("}", in: tuning)
      && tuning.range(of: #"charon \{[\s\S]*filelog \{[\s\S]*splitswan \{"#, options: .regularExpression) != nil)

print("通過 \(pass)，失敗 \(fail)")
