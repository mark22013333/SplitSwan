import Foundation
import Darwin

// 自動分流轉為 failed 的當下，把路由、DNS 與介面位址寫成現場紀錄；VPN 可能幾秒後就改掉路由，事後重現不了。
enum ExternalFailureLog {
    typealias Runner = @Sendable (String, [String]) async -> String
    static let keep = 10
    private static let pattern = try! NSRegularExpression(pattern: #"^external-split-failure-([0-9]{8}-[0-9]{6})(?:-([0-9]{1,2}))?\.txt$"#)

    static func shouldRecord(operation: String, previous: ExternalVPNPhase, next: ExternalVPNPhase) -> Bool {
        operation == "tick" && previous != .failed && next == .failed
    }

    static func directory(_ preferences: UserDefaults, home: String = NSHomeDirectory()) -> URL {
        if let path = preferences.string(forKey: "ExternalFailureLogDir"), path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/SplitSwan", isDirectory: true)
    }

    static func interfaceSummary(_ ifconfig: String) -> String {
        ifconfig.split(separator: "\n").compactMap { line -> String? in
            if line.first?.isWhitespace == false { return line.split(separator: ":").first.map { String($0) + ":" } }
            let trimmed = line.drop(while: \.isWhitespace)
            return trimmed.hasPrefix("inet ") ? "\t" + trimmed : nil
        }.joined(separator: "\n")
    }

    static func maskHome(_ text: String, home: String) -> String {
        guard home.count > 1 else { return text }
        let regex = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: home) + #"(?![A-Za-z0-9._-])"#)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func compose(statusJSON: String, sections: [(String, String)], date: Date, home: String) -> String {
        var text = "SplitSwan 自動分流失敗現場紀錄 \(stamp(date))\n\n== 狀態 ==\n\(statusJSON)\n"
        for (title, body) in sections { text += "\n== \(title) ==\n\(body)\n" }
        return maskHome(text, home: home)
    }

    static func record(statusJSON: String, directory: URL, home: String = NSHomeDirectory(), now: Date = Date(), run: Runner) async -> URL? {
        let sections = [
            ("netstat -rn -f inet", await run("/usr/sbin/netstat", ["-rn", "-f", "inet"])),
            ("scutil --dns", await run("/usr/sbin/scutil", ["--dns"])),
            ("ifconfig（只列介面名稱與 inet）", interfaceSummary(await run("/sbin/ifconfig", [])))
        ]
        let text = compose(statusJSON: statusJSON, sections: sections, date: now, home: home)
        return await Task.detached(priority: .utility) { try? write(text, to: directory, date: now) }.value
    }

    static func write(_ text: String, to directory: URL, date: Date) throws -> URL {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if info.st_mode & 0o777 != 0o700 { chmod(directory.path, 0o700) }
        let data = Data(text.utf8)
        for attempt in 1...20 {
            let url = directory.appendingPathComponent("external-split-failure-\(stamp(date))\(attempt == 1 ? "" : "-\(attempt)").txt")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { close(fd) }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == data.count else { throw POSIXError(.EIO) }
            prune(directory)
            return url
        }
        throw POSIXError(.EEXIST)
    }

    static func prune(_ directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let ours = names.compactMap { name -> (String, Int, String)? in
            guard let match = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let stampRange = Range(match.range(at: 1), in: name) else { return nil }
            let attempt = Range(match.range(at: 2), in: name).flatMap { Int(name[$0]) } ?? 1
            return (String(name[stampRange]), attempt, name)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        for (_, _, name) in ours.dropLast(keep) {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { unlink(path) }
        }
    }
}
