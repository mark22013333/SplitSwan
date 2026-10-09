// 外掛區塊的純邏輯（不碰檔案系統、不執行程式），方便單元測試：
// 檔名→間隔、輸出解析（SwiftBar 子集＋notify 擴充）、href／bash／顏色驗證、通知每日去重、權限判斷。
// 執行與排程在 PluginRunner.swift。
import Foundation

enum PluginLogic {
    static let minInterval: TimeInterval = 10        // 最短間隔，更短一律當 10 秒
    static let defaultInterval: TimeInterval = 300   // 檔名沒有間隔段時用 5 分鐘
    static let maxPlugins = 10                       // 外掛數量上限
    static let maxOutputBytes = 64 * 1024            // 輸出上限，超過截斷
    static let maxItems = 30                         // 每個外掛最多顯示的項目數（含子選單項目）
    static let maxTextLength = 200                   // 單一項目文字上限，避免整個選單被撐爆
    static let timeout: TimeInterval = 10            // 每次執行的時間上限

    // MARK: 檔名

    struct FileName: Equatable {
        var name: String            // 第一段，例：punch-reminder
        var interval: TimeInterval
    }

    /// `<名稱>.<間隔>.<副檔名>`（沿用 SwiftBar）。隱藏檔或沒有名稱回 nil。
    /// 間隔：數字＋s/m/h/d，數字只接受半形 0-9；沒有間隔段用 5 分鐘；短於 10 秒當 10 秒。
    static func parseFileName(_ file: String) -> FileName? {
        guard !file.hasPrefix("."), !file.contains("/") else { return nil }
        let parts = file.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        var interval = defaultInterval
        if parts.count >= 2, let sec = intervalSeconds(parts[1]) {
            interval = max(minInterval, sec)
        }
        return FileName(name: name, interval: interval)
    }

    /// 「30s」「5m」「1h」「1d」→ 秒數；格式不符回 nil
    static func intervalSeconds(_ s: String) -> TimeInterval? {
        guard let unit = s.last, let mul: TimeInterval = ["s": 1, "m": 60, "h": 3600, "d": 86400][unit] else { return nil }
        let digits = s.dropLast()
        guard (1...6).contains(digits.count), digits.allSatisfy({ ("0"..."9").contains($0) }),
              let n = Double(String(digits)) else { return nil }
        return n * mul
    }

    /// 間隔的顯示文字，例：60 → 「1 分鐘」
    static func intervalText(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s % 86400 == 0 { return "\(s / 86400) 天" }
        if s % 3600 == 0 { return "\(s / 3600) 小時" }
        if s % 60 == 0 { return "\(s / 60) 分鐘" }
        return "\(s) 秒"
    }

    // MARK: 輸出解析

    struct Item: Equatable {
        var text: String
        var params: [String: String] = [:]
        var isSeparator = false
        var children: [Item] = []

        static let separator = Item(text: "", isSeparator: true)

        /// 只接受 http／https 的 href
        var href: URL? { params["href"].flatMap(PluginLogic.safeURL) }
        /// bash= 只接受絕對路徑（擁有者／權限另由 PluginRunner 執行前檢查）
        var bash: String? { params["bash"].flatMap(PluginLogic.absolutePath) }
        /// param1…param9，遇到第一個缺的就停
        var bashArgs: [String] {
            var a: [String] = []
            for i in 1...9 { guard let v = params["param\(i)"] else { break }; a.append(v) }
            return a
        }
        var refresh: Bool { params["refresh"]?.lowercased() == "true" }
        var notify: Bool { params["notify"]?.lowercased() == "true" }
        /// 通知去重鍵：notify_id，沒給就用該行文字
        var notifyKey: String { params["notify_id"].flatMap { $0.isEmpty ? nil : $0 } ?? text }
        var color: String? { params["color"].flatMap(PluginLogic.normalizedColor) }
    }

    struct Output: Equatable {
        var title: String
        var items: [Item]
        var truncated = false     // 輸出超過 64 KB 或項目超過 30 個
    }

    /// 解析外掛的 stdout。第一個 `---` 之前的第一行是標題，其餘 header 行忽略；
    /// 之後每行一個項目，單獨一行 `---` 是分隔線，`--` 開頭是上一個項目的子選單（只支援一層）。
    static func parseOutput(_ raw: String) -> Output {
        var text = raw
        var truncated = false
        if raw.utf8.count > maxOutputBytes {
            truncated = true
            text = String(decoding: raw.utf8.prefix(maxOutputBytes), as: UTF8.self)
            // 最後一行可能被切一半，丟掉
            if let nl = text.lastIndex(where: { $0 == "\n" || $0 == "\r\n" }) { text = String(text[..<nl]) }
        }
        // "\r\n" 在 Swift 是單一個 Character，要一起當成換行
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }

        var title = ""
        var items: [Item] = []
        var inBody = false
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBody {
                if trimmed == "---" { inBody = true; continue }
                if title.isEmpty, !trimmed.isEmpty { title = parseLine(trimmed).text }
                continue
            }
            if trimmed == "---" {
                // 開頭或連續的分隔線不必顯示
                if let last = items.last, !last.isSeparator { items.append(.separator) }
                continue
            }
            if line.hasPrefix("--") {
                // 子選單：掛在上一個非分隔線項目底下
                guard let i = items.indices.last, !items[i].isSeparator else { continue }
                let rest = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest == "---" { items[i].children.append(.separator); continue }
                let child = parseLine(rest)
                guard !child.text.isEmpty else { continue }
                if count >= maxItems { truncated = true; break }
                items[i].children.append(child)
                count += 1
                continue
            }
            let item = parseLine(trimmed)
            guard !item.text.isEmpty else { continue }   // 空字串項目略過
            if count >= maxItems { truncated = true; break }
            items.append(item)
            count += 1
        }
        if items.last?.isSeparator == true { items.removeLast() }
        return Output(title: title, items: items, truncated: truncated)
    }

    /// 一行：`文字 | key=value key2="有 空白"`
    static func parseLine(_ line: String) -> Item {
        guard let bar = line.firstIndex(of: "|") else { return Item(text: clip(line.trimmingCharacters(in: .whitespaces))) }
        let text = clip(String(line[..<bar]).trimmingCharacters(in: .whitespaces))
        return Item(text: text, params: parseParams(String(line[line.index(after: bar)...])))
    }

    /// 空白分隔的 key=value；value 可用雙引號包含空白（不支援跳脫）。格式不符的片段略過。
    static func parseParams(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let c = Array(s)
        var i = 0
        while i < c.count {
            while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 }
            guard i < c.count else { break }
            var key = ""
            while i < c.count, c[i] != "=", c[i] != " ", c[i] != "\t" { key.append(c[i]); i += 1 }
            guard i < c.count, c[i] == "=" else { continue }   // 沒有 = 的片段略過
            i += 1
            var value = ""
            if i < c.count, c[i] == "\"" {
                i += 1
                while i < c.count, c[i] != "\"" { value.append(c[i]); i += 1 }
                i += 1   // 跳過結尾引號（沒有結尾引號就吃到行尾）
            } else {
                while i < c.count, c[i] != " ", c[i] != "\t" { value.append(c[i]); i += 1 }
            }
            let validKey = !key.isEmpty && key.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
            }
            if validKey { out[key] = value }
        }
        return out
    }

    private static func clip(_ s: String) -> String {
        s.count > maxTextLength ? String(s.prefix(maxTextLength)) + "…" : s
    }

    // MARK: 驗證

    /// href 只接受 http／https，且要有主機名稱
    static func safeURL(_ s: String) -> URL? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }

    /// 絕對路徑才接受；不可含換行或 NUL
    static func absolutePath(_ s: String) -> String? {
        guard s.hasPrefix("/"), s.count > 1, !s.contains("\n"), !s.contains("\0") else { return nil }
        return s
    }

    static let namedColors: Set<String> = ["red", "orange", "green", "gray"]

    /// `#RRGGBB` 或 red／orange／green／gray；其他回 nil（忽略）
    static func normalizedColor(_ s: String) -> String? {
        let l = s.lowercased()
        if namedColors.contains(l) { return l }
        if l == "grey" { return "gray" }
        let hex = l.unicodeScalars
        guard l.hasPrefix("#"), hex.count == 7,
              hex.dropFirst().allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return l
    }

    /// `#rrggbb` → (r, g, b) 0…1
    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    // MARK: 通知每日去重

    /// 今天（本地日期）已發過的通知鍵
    struct NotifyLog: Codable, Equatable {
        var day = ""
        var keys: [String] = []
    }

    static func notifyKey(plugin: String, key: String) -> String { plugin + "\u{1F}" + key }

    /// 同一外掛同一去重鍵每天只發一次
    static func shouldNotify(plugin: String, key: String, today: String, log: NotifyLog) -> Bool {
        log.day != today || !log.keys.contains(notifyKey(plugin: plugin, key: key))
    }

    /// 記錄已發送；換日就只保留今天的
    static func recordNotify(plugin: String, key: String, today: String, log: NotifyLog) -> NotifyLog {
        var l = log.day == today ? log : NotifyLog(day: today, keys: [])
        let k = notifyKey(plugin: plugin, key: key)
        if !l.keys.contains(k) { l.keys.append(k) }
        return l
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: 權限判斷

    /// stat 結果中用得到的欄位
    struct FileStat: Equatable {
        var uid: UInt32
        var mode: UInt16     // st_mode（含檔案類型位元）
        var isDirectory: Bool { mode & 0o170000 == 0o040000 }
        var isRegular: Bool { mode & 0o170000 == 0o100000 }
        var groupOrOtherWritable: Bool { mode & 0o022 != 0 }
        var ownerExecutable: Bool { mode & 0o100 != 0 }
    }

    /// 外掛（或 bash= 指向的程式）能不能執行：目錄與檔案都必須屬於目前使用者，且不可被 group／other 寫入。
    /// 回傳 nil 表示可以執行，否則回傳原因。file／dir 是 symlink 解析後的目標。
    static func permissionProblem(file: FileStat?, dir: FileStat?, uid: UInt32) -> String? {
        guard let dir else { return "找不到所在資料夾" }
        guard dir.isDirectory else { return "所在位置不是資料夾" }
        if dir.uid != uid { return "所在資料夾不屬於目前使用者" }
        if dir.groupOrOtherWritable { return "所在資料夾可被其他使用者寫入（請執行 chmod go-w）" }
        guard let file else { return "找不到檔案" }
        guard file.isRegular else { return "不是一般檔案" }
        if file.uid != uid { return "檔案不屬於目前使用者" }
        if file.groupOrOtherWritable { return "檔案可被其他使用者寫入（請執行 chmod go-w）" }
        if !file.ownerExecutable { return "檔案不可執行（請執行 chmod u+x）" }
        return nil
    }
}
