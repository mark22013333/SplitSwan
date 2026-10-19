// 外掛區塊的純邏輯（不碰檔案系統、不執行程式），方便單元測試：
// 檔名→間隔、輸出解析（SwiftBar 子集＋notify 擴充）、href／bash／顏色驗證、通知每日去重、權限判斷。
// 執行與排程在 PluginRunner.swift。
import CryptoKit
import Foundation

enum PluginLogic {
    static let minInterval: TimeInterval = 30        // 最短間隔，更短一律當 30 秒
    static let maxConcurrent = 2                     // 同時執行的外掛數上限，其餘排隊
    static let defaultInterval: TimeInterval = 300   // 檔名沒有間隔段時用 5 分鐘
    static let maxPlugins = 10                       // 外掛數量上限
    static let maxOutputBytes = 64 * 1024            // 輸出上限，超過截斷
    static let maxItems = 30                         // 每個外掛最多顯示的項目數（含子選單項目）
    static let maxTextLength = 200                   // 單一項目文字上限（字元），避免整個選單被撐爆
    static let maxTextBytes = 600                    // 單一項目文字上限（UTF-8 bytes），擋住帶大量組合字元的單一字
    static let maxNotifyIDLength = 64                // notify_id 超過就改用雜湊
    static let maxNotifyPerRun = 3                   // 每個外掛每次執行最多發幾則通知
    static let maxNotifyKeysPerDay = 20              // 每個外掛每天最多幾個不同的去重鍵，達上限當天不再發
    static let timeout: TimeInterval = 10            // 每次執行的時間上限

    // MARK: 檔名

    struct FileName: Equatable {
        var name: String            // 第一段，例：punch-reminder
        var interval: TimeInterval
    }

    /// `<名稱>.<間隔>.<副檔名>`（沿用 SwiftBar）。隱藏檔或沒有名稱回 nil。
    /// 間隔：數字＋s/m/h/d，數字只接受半形 0-9；沒有間隔段用 5 分鐘；短於 30 秒當 30 秒。
    static func parseFileName(_ file: String) -> FileName? {
        guard !file.hasPrefix("."), !file.contains("/"), sanitize(file) == file else { return nil }   // 含控制字元的檔名不當外掛
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

    struct Item: Equatable, Sendable {
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
        /// 超過 64 字元改用 SHA-256 前 32 碼，避免不受信任的輸出把去重紀錄撐大
        var notifyKey: String {
            let k = params["notify_id"].flatMap { $0.isEmpty ? nil : $0 } ?? text
            guard k.count > PluginLogic.maxNotifyIDLength || k.utf8.count > PluginLogic.maxNotifyIDLength * 4 else { return k }
            let hex = SHA256.hash(data: Data(k.utf8)).map { String(format: "%02x", $0) }.joined()
            return "#" + hex.prefix(32)
        }
        var color: String? { params["color"].flatMap(PluginLogic.normalizedColor) }
    }

    struct Output: Equatable, Sendable {
        var title: String
        var items: [Item]
        var truncated = false     // 輸出超過 64 KB 或項目超過 30 個
        var settingsAvailable = false
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
        var settingsAvailable = false
        var items: [Item] = []
        var inBody = false
        var count = 0
        var pendingSeparator = false
        var pendingChildSeparatorFor: Int?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBody {
                if trimmed == "---" { inBody = true; continue }
                if title.isEmpty, !trimmed.isEmpty {
                    let header = parseLine(trimmed)
                    title = header.text
                    settingsAvailable = header.params["settings"] == "true"
                }
                continue
            }
            if trimmed == "---" {
                // 延後到後面真的有項目時才加入，避免尾端分隔線佔用上限。
                pendingChildSeparatorFor = nil
                if let last = items.last, !last.isSeparator { pendingSeparator = true }
                continue
            }
            if line.hasPrefix("--") {
                // 子選單：掛在上一個非分隔線項目底下
                guard !pendingSeparator, let i = items.indices.last, !items[i].isSeparator else { continue }
                let rest = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest == "---" {
                    // 子層開頭、連續或尾端分隔線都不顯示。
                    if let last = items[i].children.last, !last.isSeparator {
                        pendingChildSeparatorFor = i
                    }
                    continue
                }
                let child = parseLine(rest)
                guard !child.text.isEmpty else { continue }
                let needsSeparator = pendingChildSeparatorFor == i
                let needed = needsSeparator ? 2 : 1
                if count + needed > maxItems { truncated = true; break }
                if needsSeparator {
                    items[i].children.append(.separator)
                    count += 1
                }
                items[i].children.append(child)
                count += 1
                pendingChildSeparatorFor = nil
                continue
            }
            let item = parseLine(trimmed)
            guard !item.text.isEmpty else { continue }   // 空字串項目略過
            pendingChildSeparatorFor = nil
            let needed = pendingSeparator ? 2 : 1
            if count + needed > maxItems { truncated = true; break }
            if pendingSeparator {
                items.append(.separator)
                count += 1
            }
            items.append(item)
            count += 1
            pendingSeparator = false
        }
        return Output(title: title, items: items, truncated: truncated, settingsAvailable: settingsAvailable)
    }

    /// 一行：`文字 | key=value key2="有 空白"`
    static func parseLine(_ line: String) -> Item {
        guard let bar = line.firstIndex(of: "|") else { return Item(text: clip(sanitize(line).trimmingCharacters(in: .whitespaces))) }
        let text = clip(sanitize(String(line[..<bar])).trimmingCharacters(in: .whitespaces))
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

    /// 字元數與 UTF-8 bytes 都設上限（單一字元可帶上萬個組合符號）
    static func clip(_ s: String) -> String {
        var t = s.count > maxTextLength ? String(s.prefix(maxTextLength)) : s
        var cut = t.count < s.count
        if t.utf8.count > maxTextBytes {
            var scalars = String.UnicodeScalarView()
            var bytes = 0
            for u in t.unicodeScalars {
                let n = String(u).utf8.count
                if bytes + n > maxTextBytes { break }
                scalars.append(u); bytes += n
            }
            t = String(scalars)
            cut = true
        }
        return cut ? t + "…" : t
    }

    /// 去掉控制字元（Cc）、格式字元（Cf，含 bidi 方向控制）與行／段分隔符，
    /// 避免外掛輸出在選單或通知裡做出假的換行、反轉文字
    static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            // 放行 ZWJ（U+200D，組合 emoji 如 👨‍💻）與 tag 字元（U+E0020–E007F，旗幟 emoji）；其他格式字元照濾
            if u.value == 0x200D || (0xE0020...0xE007F).contains(u.value) { out.append(u); continue }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: out.append(u)
            }
        }
        return String(out)
    }

    // MARK: 驗證

    /// href 只接受 http／https，且要有主機名稱；含帳密（`user:pw@`）的拒絕，避免用來偽裝網址
    static func safeURL(_ s: String) -> URL? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return nil }
        return u
    }

    /// bash= 的目標（symlink 解析後）只能是外掛本身（解析後的實際路徑）。
    /// 擁有者檢查擋不住 Homebrew 直譯器（屬於使用者本人），資料夾內其他工具也可能接受任意參數，所以一律只准外掛自己。
    /// 兩個參數都必須是 realpath 的結果（沒有 ..、沒有 symlink）。
    static func bashTargetProblem(resolved: String, pluginSelf: String?) -> String? {
        guard let pluginSelf, resolved == pluginSelf else { return "只能執行外掛本身" }
        return nil
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

    /// 排程 timer 的容許誤差：間隔的 10%，至少 1 秒，讓系統合併喚醒
    static func timerTolerance(_ interval: TimeInterval) -> TimeInterval { max(1, interval * 0.1) }

    // MARK: 通知每日去重

    /// 單一外掛今天（本地日期）已發過的通知鍵；每個外掛一份，只保留當天
    struct NotifyLog: Codable, Equatable, Sendable {
        var day = ""
        var keys: Set<String> = []
    }

    struct NotifyPlan: Equatable {
        var send: [Item]          // 這次要發的通知
        var log: NotifyLog        // 更新後的紀錄
        var capped: Bool          // 今天已達去重鍵上限，之後不再發
    }

    /// 決定這次執行要發哪些通知：同一去重鍵每天只發一次；每次最多 3 則；每天最多 20 個不同的鍵，達上限當天不再發。
    /// 超過「每次 3 則」的部分不記錄，下次執行再發
    static func planNotifications(_ items: [Item], today: String, log: NotifyLog) -> NotifyPlan {
        var l = log.day == today ? log : NotifyLog(day: today, keys: [])
        var send: [Item] = []
        var seen: Set<String> = []
        for item in items where item.notify && !item.isSeparator {
            let k = item.notifyKey
            guard !l.keys.contains(k), seen.insert(k).inserted else { continue }
            if l.keys.count >= maxNotifyKeysPerDay || send.count >= maxNotifyPerRun { break }
            l.keys.insert(k)
            send.append(item)
        }
        return NotifyPlan(send: send, log: l, capped: l.keys.count >= maxNotifyKeysPerDay)
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
        var sticky: Bool { mode & 0o1000 != 0 }
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

    /// 外掛資料夾以上的每一層（直到 /）：必須屬於目前使用者或 root；
    /// 可被 group／other 寫入的只接受設了 sticky bit 的（例：/private/tmp，他人無法改名或刪除不屬於他的項目）
    static func ancestorProblem(_ dir: FileStat?, path: String, uid: UInt32) -> String? {
        guard let dir, dir.isDirectory else { return "找不到上層資料夾 \(path)" }
        if dir.uid != uid && dir.uid != 0 { return "上層資料夾 \(path) 不屬於目前使用者" }
        if dir.groupOrOtherWritable && !dir.sticky { return "上層資料夾 \(path) 可被其他使用者寫入" }
        return nil
    }
}
