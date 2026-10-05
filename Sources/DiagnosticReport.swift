// F3 App 內建診斷報告（docs/SPEC-1.3.md §5）：報告的組字與遮蔽。
// 這裡只有純函式，不執行外部指令、不碰系統狀態，方便單獨測試；
// 收集資料（執行指令、讀檔、寫到桌面）在 DiagnosticRunner。
import Foundation

enum DiagnosticReport {
    static let logTailLines = 300
    static let dnsHeadLines = 40
    /// 外網探測用的網域：選中性、穩定的站
    static let probeHost = "www.apple.com"
    /// 通道網段推導出的目標最多測幾個，避免網段很多時拖太久
    static let maxTargets = 32
    /// 讀 log 檔尾端最多讀多少 bytes（300 行綽綽有餘）
    static let logTailBytes = 512 * 1024

    /// 一個外部指令的結果
    struct CommandResult: Equatable {
        var code: Int32
        var output: String
        var timedOut = false
        var seconds: TimeInterval = 0   // 逾時上限，顯示用
    }

    /// charon log 檔的讀取結果
    enum LogRead: Equatable {
        case missing
        case unreadable(String)
        case content(String, size: UInt64)
    }

    /// 組報告需要的全部資料（都已經收集好）
    struct Input {
        var generatedAt: Date
        var elapsed: TimeInterval
        var appName: String
        var appVersion: String
        var macOSVersion: String
        var chip: CommandResult
        var checks: [String]              // 環境檢查結果，每項一行
        var helperStatus: CommandResult
        var helperSAs: CommandResult
        var settings: VPNSettings
        var pskSet: Bool
        var passwordSet: Bool
        var history: GatewayHistory
        var routes: [(target: String, result: CommandResult)]
        var dns: CommandResult
        var dnsProbe: CommandResult
        var httpsProbe: CommandResult
        var charonLog: LogRead
        var logPath: String
    }

    // MARK: 檔名

    /// 例：SplitSwan-診斷-20260930-142530.txt（App 名稱從 AppInfo 來，不寫死）
    static func fileName(app: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(app)-診斷-\(f.string(from: date)).txt"
    }

    // MARK: 通道網段 → 測試目標

    /// 跟 diag.sh 相同的推導規則：/32 直接測該位址；其他網段測第一個可用位址（網路位址 + 1）；/0 略過。
    /// 格式不對的略過，重複的只留一個
    static func targets(remoteTS: String) -> [String] {
        var out: [String] = []
        for raw in remoteTS.split(separator: ",") {
            let cidr = raw.trimmingCharacters(in: .whitespaces)
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let mask = Int(parts[1]), (1...32).contains(mask),
                  let ip = ipv4(String(parts[0])) else { continue }
            let target: UInt32
            if mask >= 31 {
                target = ip
            } else {
                let netmask: UInt32 = mask == 0 ? 0 : ~UInt32(0) << UInt32(32 - mask)
                target = (ip & netmask) + 1
            }
            let s = ipv4String(target)
            if !out.contains(s) { out.append(s) }
        }
        return Array(out.prefix(maxTargets))
    }

    static func ipv4(_ s: String) -> UInt32? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for x in p {
            // 只接受半形數字（跟 ConfigStore.validate 一樣，不用 \d）
            guard !x.isEmpty, x.count <= 3, x.allSatisfy({ ("0"..."9").contains($0) }),
                  let n = UInt32(x), n <= 255 else { return nil }
            v = v << 8 | n
        }
        return v
    }

    static func ipv4String(_ v: UInt32) -> String {
        "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)"
    }

    /// route -n get 輸出中的「interface: utun6」
    static func interface(fromRoute output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                let v = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    // MARK: 文字工具

    static func head(_ text: String, lines n: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).prefix(n).joined(separator: "\n")
    }

    static func tail(_ text: String, lines n: Int) -> String {
        var ls = text.split(separator: "\n", omittingEmptySubsequences: false)
        if ls.last == "" { ls.removeLast() }   // 檔尾的換行不算一行
        return ls.suffix(n).joined(separator: "\n")
    }

    /// 讀檔案尾端最多 maxBytes（log 檔可能到 2 MB，不整份讀進來）。
    /// 從檔案中間開始讀時，丟掉第一個不完整的行
    static func readTail(path: String, maxBytes: Int = logTailBytes) -> LogRead {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .missing }
        guard let h = FileHandle(forReadingAtPath: path) else { return .unreadable("沒有讀取權限") }
        defer { try? h.close() }
        do {
            let size = try h.seekToEnd()
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try h.seek(toOffset: start)
            var data = try h.readToEnd() ?? Data()
            if start > 0, let nl = data.firstIndex(of: 0x0A) { data = data[data.index(after: nl)...] }
            return .content(String(decoding: data, as: UTF8.self), size: size)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    // MARK: 遮蔽

    /// 遮蔽規則。值是雙引號字串（含跳脫字元）或單引號字串時只換字串本身；
    /// 沒加引號時一律遮到該行結尾（值可能含 ; , } 或空白）。空白只用 [ \t]，不可跨行
    static let redactionPatterns: [String] = [
        // key = value／key: value，例：secret = "…"（swanctl 語法）、PSK: …、password=…、eap_password=…、"password": "…"
        #"(?i)([A-Za-z_-]*(?:secret|psk|pre-?shared[ _-]?key|password|passwd|passphrase|pwd|eap|xauth)["']?[ \t]*[=:][ \t]*)("(?:[^"\\\n]|\\.)*"|'[^'\n]*'|[^\n]+)"#,
        // ipsec.secrets 語法：<選擇器> : PSK "…"、: EAP "…"、: XAUTH …
        #"(?i)(:[ \t]*(?:PSK|EAP|XAUTH|NTLM)[ \t]+)("(?:[^"\\\n]|\\.)*"|'[^'\n]*'|[^\n]+)"#,
    ]

    /// 精確取代只處理這個長度以上的字串：太短的密碼（例：數字串）會把 IP 片段等相同子字串也換掉，
    /// 讀者反而能從位置反推密碼，報告也難讀；短字串只靠正則
    static let minExactRedactLength = 6

    /// 寫入報告前的遮蔽：先用正則處理所有 secret／PSK／password 形式，
    /// 再把目前設定裡實際的密碼與 PSK（長度夠長的）做精確字串取代（第二道防線）
    static func redact(_ text: String, secrets: [String]) -> String {
        var out = text
        for p in redactionPatterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1***")
        }
        // 長的先換，避免一個密碼是另一個的子字串時留下殘段
        for s in secrets.filter({ $0.count >= minExactRedactLength }).sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: s, with: "***")
        }
        return out
    }

    // MARK: 組報告

    /// 組好並遮蔽，這是唯一應該寫進檔案的版本
    static func build(_ input: Input, secrets: [String]) -> String {
        redact(render(input), secrets: secrets)
    }

    /// 組報告全文（未遮蔽，只給 build 與測試用）
    static func render(_ i: Input) -> String {
        var out = ""
        func sec(_ title: String) { out += "\n===== \(title) =====\n" }
        func line(_ s: String) { out += s + "\n" }
        func cmd(_ r: CommandResult) { line(describe(r)) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        line("\(i.appName) 診斷報告")
        line("產生時間：\(df.string(from: i.generatedAt))（收集耗時 \(String(format: "%.1f", i.elapsed)) 秒）")
        line("本報告只是現況快照，產生時不會連線、斷線或重新載入設定；密碼與預設共享金鑰已遮蔽。")

        sec("App 與系統")
        line("App：\(i.appName) \(i.appVersion)")
        line("macOS：\(i.macOSVersion)")
        line("晶片：\(oneLine(i.chip))")

        sec("環境檢查")
        if i.checks.isEmpty { line("（沒有檢查結果）") } else { i.checks.forEach(line) }

        sec("連線狀態（輔助程式 status）")
        cmd(i.helperStatus)

        sec("SA 清單（輔助程式 sas）")
        cmd(i.helperSAs)

        sec("設定摘要")
        line("帳號：\(i.settings.username.isEmpty ? "（未設定）" : i.settings.username)")
        for (n, gw) in i.settings.gateways.enumerated() {
            line("閘道 VPN\(n + 1)：\(gw.isEmpty ? "（未設定）" : gw)")
        }
        line("通道網段：\(i.settings.remoteTS.isEmpty ? "（未設定）" : i.settings.remoteTS)")
        line("預設共享金鑰：\(i.pskSet ? "已設定" : "未設定")")
        line("密碼：\(i.passwordSet ? "已設定" : "未設定")")

        sec("閘道連線紀錄（每台最近 \(GatewayHistory.keepPerGateway) 筆）")
        var anyRecord = false
        for n in 1...3 {
            let r = i.history.records(n)
            guard !r.isEmpty else { continue }
            anyRecord = true
            var head = i.history.statusText(n)
            if let rate = i.history.successRate(n) { head += "；成功率 \(Int((rate * 100).rounded()))%" }
            if let avg = i.history.averageSuccessSeconds(n) { head += "；平均 \(String(format: "%.1f", avg)) 秒" }
            if i.history.isCooling(n, now: i.generatedAt) { head += "；冷卻中" }
            line(head)
            for a in r {
                let secs = a.seconds.map { String(format: "%.1f 秒", $0) } ?? "耗時不明"
                line("  \(df.string(from: a.time))  \(a.success ? "成功" : "失敗")  \(secs)  \(a.address)")
            }
        }
        if !anyRecord { line("（沒有紀錄）") }
        let order = GatewayHistory.order(gateways: i.settings.gateways, history: i.history, now: i.generatedAt)
        line("目前自動輪替順序：\(order.isEmpty ? "（沒有已設定的閘道）" : order.map { "VPN\($0)" }.joined(separator: " → "))")

        sec("通道網段內的目標走哪個介面（utun = 走 VPN，en0 = 走一般網路）")
        if i.routes.isEmpty { line("（沒有可測的目標）") }
        for (target, r) in i.routes {
            if let ifc = interface(fromRoute: r.output), r.code == 0 {
                line("  \(target)  介面=\(ifc)")
            } else {
                line("  \(target)  介面=?  \(oneLine(r))")
            }
        }

        sec("DNS 設定（scutil --dns 前 \(dnsHeadLines) 行）")
        cmd(CommandResult(code: i.dns.code, output: head(i.dns.output, lines: dnsHeadLines),
                          timedOut: i.dns.timedOut, seconds: i.dns.seconds))

        sec("外網探測")
        line("系統 DNS 解析 \(probeHost)：")
        cmd(i.dnsProbe)
        line("HTTPS 連線 https://\(probeHost)：")
        cmd(i.httpsProbe)

        sec("charon log（\(i.logPath) 最後 \(logTailLines) 行）")
        switch i.charonLog {
        case .missing:
            line("找不到 log 檔。系統元件可能是舊版，請到「環境檢查」按系統元件的「更新」後，重新連線一次再產生報告。")
        case .unreadable(let why):
            line("無法讀取 log 檔：\(why)")
        case .content(let text, let size):
            line("（檔案大小 \(size) bytes）")
            let t = tail(text, lines: logTailLines)
            line(t.isEmpty ? "（log 檔是空的：可能還沒連線過，或設定尚未套用）" : t)
        }
        return out
    }

    /// 指令結果：原始輸出，另外註明結束代碼與逾時
    static func describe(_ r: CommandResult) -> String {
        var s = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "（沒有輸出）" }
        if r.timedOut { s += "\n（超過 \(Int(r.seconds)) 秒未完成，已中止）" }
        else if r.code != 0 { s += "\n（結束代碼 \(r.code)）" }
        return s
    }

    private static func oneLine(_ r: CommandResult) -> String {
        describe(r).replacingOccurrences(of: "\n", with: " ")
    }
}
