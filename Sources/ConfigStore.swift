// 設定檔讀寫：產生 swanctl.conf（連線設定）與 conf.d/secrets.conf（PSK、密碼）
// 兩個檔案都在使用者可寫入的 /opt/homebrew/etc/swanctl 底下，App 直接寫，不需要 root。
import Foundation

struct VPNSettings: Codable, Equatable {
    var username: String = ""
    var gateways: [String] = ["", "", ""]
    var remoteTS: String = ""   // 通道網段（split tunnel），逗號分隔；只有這些目的地走 VPN

    /// 公司設定（閘道、網段）不寫在程式裡，由 CompanyPresetStore 從設定檔或環境變數讀取
    static func fromPreset(_ p: CompanyPreset?) -> VPNSettings {
        var s = VPNSettings()
        if let p { s.gateways = p.gateways; s.remoteTS = p.remoteTS }
        return s
    }
}

enum ConfigError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let m): return m }
    }
}

enum ConfigStore {
    static let swanctlDir = "/opt/homebrew/etc/swanctl"
    static let confPath = swanctlDir + "/swanctl.conf"
    static let secretsPath = swanctlDir + "/conf.d/secrets.conf"
    static let marker = "# 由 \(AppInfo.name).app 產生"
    /// charon 的全域參數（重送），strongswan.conf 會載入 strongswan.d/*.conf
    static let charonTuningPath = "/opt/homebrew/etc/strongswan.d/splitswan.conf"
    private static let defaultsKey = "VPNSettings"

    // MARK: 讀取

    /// 讀取順序：App 存過的設定 → 現有 swanctl.conf（從手動設定升級）→ 公司設定檔／環境變數 → 空白讓使用者填
    static func load() -> VPNSettings {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let s = try? JSONDecoder().decode(VPNSettings.self, from: data) {
            return normalized(s)
        }
        if let s = parseExistingConf() { return normalized(s) }
        return normalized(VPNSettings.fromPreset(CompanyPresetStore.load()))
    }

    /// 去掉前後空白，閘道固定補到 3 筆，其他程式可以放心用 gateways[0...2]
    static func normalized(_ s: VPNSettings) -> VPNSettings {
        var n = s
        n.username = s.username.trimmingCharacters(in: .whitespaces)
        n.gateways = Array((s.gateways.map { $0.trimmingCharacters(in: .whitespaces) } + ["", "", ""]).prefix(3))
        n.remoteTS = s.remoteTS.trimmingCharacters(in: .whitespaces)
        return n
    }

    private static func parseExistingConf() -> VPNSettings? {
        guard let text = try? String(contentsOfFile: confPath, encoding: .utf8) else { return nil }
        var s = VPNSettings()
        let addrs = matches(#"remote_addrs\s*=\s*(\S+)"#, in: text)
        guard !addrs.isEmpty else { return nil }
        for (i, a) in addrs.prefix(3).enumerated() { s.gateways[i] = a }
        s.username = matches(#"eap_id\s*=\s*(\S+)"#, in: text).first ?? ""
        if let ts = firstLineValue(#"remote_ts\s*=\s*([^#\n]+)"#, in: text) { s.remoteTS = ts }
        return s
    }

    /// secrets.conf 裡 PSK、密碼是否已經填好（不是空的，也不是範本的佔位字串）
    static func secretsStatus() -> (psk: Bool, password: Bool) {
        let (psk, pwd) = existingSecrets()
        return (isRealSecret(psk), isRealSecret(pwd))
    }

    private static func isRealSecret(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        return !(s.hasPrefix("<") && s.hasSuffix(">"))
    }

    /// 回傳 secrets.conf 裡 ike 與 eap 兩段的 secret 原始字串（保留跳脫字元，原樣寫回用）
    private static func existingSecrets() -> (String?, String?) {
        guard let text = try? String(contentsOfFile: secretsPath, encoding: .utf8) else { return (nil, nil) }
        let re = #"(ike|eap)-[\w-]+\s*\{[^}]*?secret\s*=\s*"((?:[^"\\]|\\.)*)""#
        var ike: String?, eap: String?
        guard let regex = try? NSRegularExpression(pattern: re) else { return (nil, nil) }
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let kind = Range(m.range(at: 1), in: text), let val = Range(m.range(at: 2), in: text) else { continue }
            if text[kind] == "ike", ike == nil { ike = String(text[val]) }
            if text[kind] == "eap", eap == nil { eap = String(text[val]) }
        }
        return (ike, eap)
    }

    /// 設定檔是不是本 App 產生的（看開頭的標記）
    /// 目前 secrets.conf 裡的 PSK（還原跳脫字元後的原文），匯出加密設定檔用；沒設定回傳 nil
    static func currentPSK() -> String? {
        guard let raw = existingSecrets().0, isRealSecret(raw) else { return nil }
        return unquote(raw)
    }

    /// quote() 的反向：\\ → \、\" → "
    static func unquote(_ s: String) -> String {
        var out = "", esc = false
        for c in s {
            if esc { out.append(c); esc = false }
            else if c == "\\" { esc = true }
            else { out.append(c) }
        }
        return out
    }

    static var confGeneratedByApp: Bool {
        guard let text = try? String(contentsOfFile: confPath, encoding: .utf8) else { return false }
        // 標記裡的 App 名稱可能因改名而不同（見 app.env），所以只比對格式
        return text.range(of: #"^# 由 \S+\.app 產生"#, options: .regularExpression) != nil
    }

    // MARK: 驗證

    /// 檢查輸入，避免換行、大括號等字元破壞設定檔結構
    static func validate(_ s: VPNSettings) throws {
        guard s.username.range(of: #"^[A-Za-z0-9._@-]+$"#, options: .regularExpression) != nil else {
            throw ConfigError.invalid("帳號只能包含英數字與 . _ @ -")
        }
        let filled = s.gateways.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !filled.isEmpty else { throw ConfigError.invalid("至少要填一台閘道") }
        for g in filled where g.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) == nil {
            throw ConfigError.invalid("閘道格式不正確：\(g)")
        }
        // 用 [0-9] 而不是 \d：ICU 的 \d 會吃全形數字，strongSwan 載入時會失敗
        let cidr = #"^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$"#
        let nets = s.remoteTS.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !nets.isEmpty else { throw ConfigError.invalid("通道網段不可空白") }
        for n in nets {
            let parts = n.split(whereSeparator: { $0 == "." || $0 == "/" }).compactMap { Int($0) }
            guard n.range(of: cidr, options: .regularExpression) != nil, parts.count == 5,
                  parts[0..<4].allSatisfy({ $0 <= 255 }), parts[4] <= 32 else {
                throw ConfigError.invalid("通道網段格式不正確：\(n)（例：10.0.0.0/8）")
            }
            // 全流量模式在 macOS 上會讓外網 DNS 失效，也最容易被拿來把所有流量導去別處
            guard parts[4] >= 1 else {
                throw ConfigError.invalid("不可使用 \(n)（全部流量走 VPN），請只填公司網段")
            }
        }
    }

    private static func validateSecret(_ s: String, name: String) throws {
        guard !s.contains("\n"), !s.contains("\r") else { throw ConfigError.invalid("\(name)不可包含換行") }
    }

    /// strongSwan 設定語法的雙引號字串：跳脫反斜線與雙引號
    static func quote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: 寫入

    /// psk、password 傳 nil 代表沿用 secrets.conf 裡原本的值
    static func save(_ input: VPNSettings, psk: String?, password: String?) throws {
        let s = normalized(input)
        try validate(s)
        let (oldPSK, oldPwd) = existingSecrets()
        let pskValue: String
        if let psk, !psk.isEmpty { try validateSecret(psk, name: "預設共享金鑰"); pskValue = quote(psk) }
        else if let oldPSK, isRealSecret(oldPSK) { pskValue = oldPSK }
        else { throw ConfigError.invalid("請填入預設共享金鑰") }
        let pwdValue: String
        if let password, !password.isEmpty { try validateSecret(password, name: "密碼"); pwdValue = quote(password) }
        else if let oldPwd, isRealSecret(oldPwd) { pwdValue = oldPwd }
        else { throw ConfigError.invalid("請填入密碼") }

        let fm = FileManager.default
        guard fm.fileExists(atPath: swanctlDir) else {
            throw ConfigError.invalid("找不到 \(swanctlDir)，請先到「環境檢查」安裝 strongSwan")
        }
        try fm.createDirectory(atPath: swanctlDir + "/conf.d", withIntermediateDirectories: true)

        try writePrivate(renderConf(s), to: confPath)
        try writeCharonTuning()
        try writePrivate(renderSecrets(username: s.username, psk: pskValue, password: pwdValue), to: secretsPath)

        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    /// 縮短重送參數：失聯判定約 26 秒、連不上的閘道約 16 秒放棄（規格 §2.2，數字待實測 Q6）。
    /// 內容沒變就不寫，回傳是否有更新（有更新才需要 reload-settings）
    @discardableResult
    static func writeCharonTuning() throws -> Bool {
        let text = """
        \(marker)，請勿手動修改。
        # 縮短重送參數，讓 DPD 更快判定失聯（預設約 185 秒 → 約 26 秒）
        charon {
            retransmit_timeout = 2.0
            retransmit_tries = 3
            retransmit_base = 1.5
        }

        """
        if (try? String(contentsOfFile: charonTuningPath, encoding: .utf8)) == text { return false }
        guard FileManager.default.fileExists(atPath: (charonTuningPath as NSString).deletingLastPathComponent) else { return false }
        try writePrivate(text, to: charonTuningPath)
        // charon 以 root 讀取，一般使用者可讀即可，不含機密
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: charonTuningPath)
        return true
    }

    /// App 啟動時把既有的設定檔更新成目前版本的格式（例：1.2 → 1.3 的 DPD 參數）。
    /// 只處理 App 產生的設定檔，而且沿用原本的密碼與 PSK；回傳是否有變更
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        guard confGeneratedByApp else { return false }
        let s = load()
        guard (try? validate(s)) != nil, secretsStatus() == (true, true) else { return false }
        let before = try? String(contentsOfFile: confPath, encoding: .utf8)
        let tuned = (try? writeCharonTuning()) ?? false
        if before != renderConf(s) {
            do { try save(s, psk: nil, password: nil) } catch { return tuned }
            return true
        }
        return tuned
    }

    /// 先寫暫存檔再改名，權限 600
    private static func writePrivate(_ text: String, to path: String) throws {
        let tmp = path + ".tmp"
        unlink(tmp)   // 上次失敗留下的暫存檔
        // 直接以 600 建檔（O_EXCL 確保是新檔），密碼不會有任何時間點以較寬的權限存在
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ConfigError.invalid("無法寫入 \(tmp)：\(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        } else {
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    static func renderConf(_ s: VPNSettings) -> String {
        let ts = s.remoteTS.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        var out = """
        \(marker)，請用 App 的「設定」頁修改，手動修改會在下次儲存時被覆蓋。
        # 公司 FortiGate IPsec VPN（IKEv2 + PSK + EAP + Mode Config）
        #   Phase 1：AES128/AES256 + SHA256，DH 20（ecp384），金鑰有效期 86400 秒，DPD 每 10 秒
        #   Phase 2：AES128/AES256 + SHA256，金鑰有效期 43200 秒
        # 密碼與 PSK 在 conf.d/secrets.conf（權限 600）。

        connections {

        """
        for (i, raw) in s.gateways.enumerated() {
            let gw = raw.trimmingCharacters(in: .whitespaces)
            guard !gw.isEmpty else { continue }
            out += """
                vpn\(i + 1) {
                    version = 2
                    remote_addrs = \(gw)
                    proposals = aes128-sha256-ecp384, aes256-sha256-ecp384
                    rekey_time = 86400s
                    vips = 0.0.0.0
                    mobike = no
                    fragmentation = yes
                    dpd_delay = 10s

                    local {
                        auth = eap
                        eap_id = \(s.username)
                    }
                    remote {
                        auth = psk
                        id = %any
                    }
                    children {
                        corp {
                            local_ts = dynamic
                            remote_ts = \(ts)
                            esp_proposals = aes128-sha256-ecp384, aes256-sha256-ecp384, aes128-sha256, aes256-sha256
                            rekey_time = 43200s
                            dpd_action = clear     # 失聯時直接移除，重連交給 App（規格 §2.2）
                            start_action = none
                            close_action = none
                        }
                    }
                }


            """
        }
        out += "}\n\ninclude conf.d/*.conf\n"
        return out
    }

    private static func renderSecrets(username: String, psk: String, password: String) -> String {
        """
        \(marker)，請勿提交版控或貼到任何地方。
        secrets {
            ike-fortigate {
                secret = "\(psk)"
            }
            eap-user {
                id = \(username)
                secret = "\(password)"
            }
        }

        """
    }

    // MARK: 小工具

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func firstLineValue(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text).first?.trimmingCharacters(in: .whitespaces)
    }
}
