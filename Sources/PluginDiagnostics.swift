import CryptoKit
import Foundation

/// 把安裝記錄整理成可交給維護者的文字。記錄寫入時已遮蔽，這裡只排版；只有外掛資料夾裡的檔名是現場讀的，要另外遮蔽。
enum PluginDiagnostics {
    struct Package: Equatable, Sendable {
        let id: String, version: String, digest: String, enabled: Bool, trusted: Bool
    }
    struct Script: Equatable, Sendable {
        let name: String, sha256: String
    }
    static let reportLimit = 200
    static let scriptHashLimit = 20 * 1024 * 1024

    static func summary(_ records: [PluginEventLog.Record], appVersion: String, build: String, macOS: String,
                        timeZone: TimeZone = .current) -> String {
        var lines = [header(appVersion, build, macOS)]
        guard let first = records.first else { return (lines + ["找不到這次操作的記錄"]).joined(separator: "\n") }
        lines.append(attemptLine(first))
        lines += records.flatMap { eventLines($0, timeZone) }
        return lines.joined(separator: "\n")
    }

    static func report(recent: [PluginEventLog.Record], packages: [Package], singleFiles: [Script], pluginsEnabled: Bool,
                       appVersion: String, build: String, macOS: String,
                       generated: Date = Date(), timeZone: TimeZone = .current) -> String {
        var lines = ["SplitSwan 外掛診斷報告", "產生時間 " + format(generated, "yyyy-MM-dd HH:mm:ss ZZZZZ", timeZone),
                     header(appVersion, build, macOS), "外掛總開關 " + (pluginsEnabled ? "開啟" : "關閉"), ""]
        lines.append("已安裝套件（\(packages.count)）")
        lines += packages.isEmpty ? ["  （無）"] : packages.map {
            "  \($0.id) \($0.version) · digest \($0.digest.prefix(12)) · \($0.enabled ? "已啟用" : "已停用") · \($0.trusted ? "已信任" : "未信任")"
        }
        lines += ["", "外掛資料夾單檔腳本（\(singleFiles.count)）"]
        lines += singleFiles.isEmpty ? ["  （無）"] : singleFiles.map { "  \(PluginEventLog.redact($0.name)) SHA-256 \($0.sha256)" }
        let events = Array(recent.suffix(reportLimit))
        lines += ["", "最近事件（\(events.count) 筆，最多 \(reportLimit) 筆）"]
        if events.isEmpty { lines.append("  （無）") }
        // 不同操作的事件可能交錯（例如排程執行），依操作分段，段內維持時間順序
        var order: [UUID] = [], groups: [UUID: [PluginEventLog.Record]] = [:]
        for r in events {
            if groups[r.attempt] == nil { order.append(r.attempt) }
            groups[r.attempt, default: []].append(r)
        }
        for id in order {
            let group = groups[id]!
            lines += ["", attemptLine(group[0]) + " · " + format(group[0].time, "yyyy-MM-dd", timeZone)]
            lines += group.flatMap { eventLines($0, timeZone) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func defaultReportName(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        "SplitSwan-外掛診斷-" + format(date, "yyyyMMdd-HHmmss", timeZone) + ".txt"
    }

    /// 在目的地同一個資料夾以 600 建暫存檔再改名蓋過去：讀到的不是舊檔就是完整的新檔，也不跟隨目的地的 symlink
    static func writeReport(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    /// 外掛資料夾第一層的一般檔案（不含隱藏檔）；symlink 依目標計算，超過上限或讀不到的照列並註明
    static func scripts(in directory: URL) -> [Script] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.compactMap { name in
            let path = directory.appendingPathComponent(name).path
            var st = Darwin.stat()
            guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
            guard st.st_size <= scriptHashLimit else { return Script(name: name, sha256: "（超過 20 MiB，未計算）") }
            guard let data = FileManager.default.contents(atPath: path) else { return Script(name: name, sha256: "（無法讀取）") }
            return Script(name: name, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }

    // MARK: 排版

    private static func header(_ version: String, _ build: String, _ macOS: String) -> String {
        "SplitSwan \(version)（build \(build)）· macOS \(macOS)"
    }

    private static func attemptLine(_ r: PluginEventLog.Record) -> String {
        "操作 \(r.attempt.uuidString.lowercased().prefix(8)) · \(r.operation.rawValue) · \(r.plugin ?? "-")"
    }

    private static func eventLines(_ r: PluginEventLog.Record, _ timeZone: TimeZone) -> [String] {
        var head = "\(format(r.time, "HH:mm:ss", timeZone)) \(r.stage.rawValue) \(r.outcome.rawValue)"
        if let f = r.failure { head += " " + f.rawValue }
        if let n = r.repeats { head += "（另 \(n) 次相同失敗" + (r.firstTime.map { "，自 " + format($0, "HH:mm:ss", timeZone) } ?? "") + "）" }
        var lines = [head]
        if let text = r.failure.map({ $0.text(r.detail) }) ?? r.detail { lines.append("  " + text) }
        if !r.facts.isEmpty { lines.append("  " + r.facts.map(fact).joined(separator: " · ")) }
        return lines
    }

    static func fact(_ f: PluginEventLog.Fact) -> String {
        switch f {
        case .fileSize(let n): "大小 \(n) bytes"
        case .sha256(let h): "SHA-256 \(h)"
        case .entryCount(let e, let a): "ZIP 項目 預期 \(e)／實際 \(a)"
        case .topPaths(let p): "頂層路徑 " + p.joined(separator: "、")
        case .manifest(let id, let v): "Manifest \(id) \(v)"
        case .legacyScript(let n, let h): "舊腳本 \(n) SHA-256 \(h)"
        case .exitCode(let c): "結束碼 \(c)"
        case .timedOut: "逾時"
        case .stderrTail(let s): "stderr：" + s
        case .appVersion(let v): "App 版本 \(v)"
        case .macOS(let v): "macOS \(v)"
        }
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
