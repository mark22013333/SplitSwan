// 公司設定（閘道、通道網段）：不寫在程式裡，從設定檔或環境變數讀取，
// 所以原始碼可以公開，公司位址只存在各自電腦的 ~/.config/splitswan/company.env。
//
// 檔案格式（KEY=VALUE，可直接被 shell source）：
//   SPLITSWAN_GATEWAYS="1.2.3.4,5.6.7.8,9.10.11.12"     最多 3 台，逗號分隔
//   SPLITSWAN_REMOTE_TS="10.0.0.0/24,1.2.3.4/32"         要走 VPN 的網段，逗號分隔
//   SPLITSWAN_PRESET_NAME="我的公司"                       選填，顯示在設定頁
import Foundation

struct CompanyPreset: Equatable {
    var name: String
    var gateways: [String]
    var remoteTS: String
    var source: String       // 從哪裡讀到的（顯示給使用者看）
}

enum CompanyPresetStore {
    static let envPrefix = "SPLITSWAN_"
    static let dir = NSHomeDirectory() + "/.config/splitswan"
    static let path = dir + "/company.env"

    /// 優先讀設定檔；沒有的話讀環境變數（只有從終端機啟動 App 時才會有）
    static func load() -> CompanyPreset? {
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           let p = preset(from: parse(text), source: path) {
            return p
        }
        return preset(from: ProcessInfo.processInfo.environment, source: "環境變數")
    }

    /// 解析 KEY=VALUE：略過註解與空行，接受 `export ` 前綴，去掉成對的引號
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, let f = val.first, let l = val.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                val = String(val.dropFirst().dropLast())
            }
            out[key] = val
        }
        return out
    }

    static func preset(from values: [String: String], source: String) -> CompanyPreset? {
        func v(_ key: String) -> String? { values[envPrefix + key] }
        let gws = (v("GATEWAYS") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ts = (v("REMOTE_TS") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !gws.isEmpty, !ts.isEmpty else { return nil }
        return CompanyPreset(name: v("PRESET_NAME") ?? "公司設定",
                             gateways: Array((gws + ["", "", ""]).prefix(3)),
                             remoteTS: ts, source: source)
    }

    /// 讀取使用者選的明文設定檔並驗證（不寫入）。確認後再呼叫 apply(_:)
    static func readFile(at url: URL) throws -> CompanyPreset {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfigError.invalid("無法讀取檔案，請確認是文字檔")
        }
        let v = parse(text)
        func get(_ k: String) -> String? { v[envPrefix + k] }
        return try strictPreset(name: get("PRESET_NAME") ?? "公司設定",
                                gatewaysCSV: get("GATEWAYS") ?? "",
                                remoteTS: get("REMOTE_TS") ?? "")
    }

    /// 匯入來源不可信（檔案可能是別人做的）：整份嚴格驗證，任何一項不合格就整份拒絕，
    /// 不做「截斷後再驗證」，避免多出來的內容被寫進會被 shell source 的 company.env
    static func strictPreset(name: String, gatewaysCSV: String, remoteTS: String) throws -> CompanyPreset {
        let all = name + gatewaysCSV + remoteTS
        guard !all.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }) else {
            throw ConfigError.invalid("設定檔含有不允許的控制字元")
        }
        let gws = gatewaysCSV.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !gws.isEmpty else { throw ConfigError.invalid("設定檔裡沒有閘道") }
        guard gws.count <= 3 else { throw ConfigError.invalid("閘道最多 3 台，設定檔裡有 \(gws.count) 台") }
        for g in gws where g.range(of: #"^[A-Za-z0-9.-]{1,253}$"#, options: .regularExpression) == nil {
            throw ConfigError.invalid("閘道格式不正確：\(g.prefix(40))")
        }
        let nets = remoteTS.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !nets.isEmpty else { throw ConfigError.invalid("設定檔裡沒有通道網段") }
        let p = CompanyPreset(name: safeName(name),
                              gateways: Array((gws + ["", "", ""]).prefix(3)),
                              remoteTS: nets.joined(separator: ", "), source: path)
        var probe = VPNSettings()
        probe.username = "probe"
        probe.gateways = p.gateways
        probe.remoteTS = p.remoteTS
        try ConfigStore.validate(probe)   // 逐筆檢查 CIDR，並拒絕 /0
        return p
    }

    /// 名稱只保留文字、數字、空白與少數標點，最多 40 字（會寫進 shell 可 source 的檔案）
    static func safeName(_ s: String) -> String {
        let kept = s.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || " -_.()（）".unicodeScalars.contains($0)
        }
        let out = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "公司設定" : String(out.prefix(40))
    }

    /// 驗證過的設定寫到 company.env：一律用解析出的值重新產生，不照抄原檔
    static func apply(_ p: CompanyPreset) throws {
        try store(renderEnv(name: p.name, gateways: p.gateways, remoteTS: p.remoteTS))
    }

    /// 產生 company.env 的內容。值用單引號包住（shell 不展開 $(…) 與反引號），
    /// 且每個值都已通過 strictPreset 的白名單驗證，不會含單引號
    static func renderEnv(name: String, gateways: [String], remoteTS: String) -> String {
        let gws = gateways.filter { !$0.isEmpty }.joined(separator: ",")
        let ts = remoteTS.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
        return """
        # 由 \(AppInfo.name) 匯入，請勿提交版控或公開分享。
        \(envPrefix)PRESET_NAME='\(safeName(name))'
        \(envPrefix)GATEWAYS='\(gws)'
        \(envPrefix)REMOTE_TS='\(ts)'

        """
    }

    /// 寫到 ~/.config/splitswan/company.env（權限 600）
    private static func store(_ text: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = Data(text.utf8)
        FileManager.default.createFile(atPath: path + ".tmp", contents: data, attributes: [.posixPermissions: 0o600])
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: path + ".tmp"))
        } else {
            try FileManager.default.moveItem(atPath: path + ".tmp", toPath: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
