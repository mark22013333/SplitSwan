import Foundation

/// 外掛匯入、更新、移除、啟用、執行的逐步記錄。一行一筆 JSON（JSON Lines），寫在 ~/Library/Logs/SplitSwan/plugins.jsonl。
/// 同事遇到問題時靠它還原每一步；欄位只收固定種類的事實，所有字串寫入前都經 `redact`。
/// 記錄失敗絕不影響呼叫端：所有錯誤一律吞掉。
actor PluginEventLog {
    enum Operation: String, Codable, Sendable {
        case importPackage = "import", update, legacyUpgrade, remove, enable, disable, export, run
    }
    enum Stage: String, Codable, Sendable {
        case read, preflight, archive, manifest, payload, entrypoint, compare, legacy, install, enable, remove, export, run
    }
    enum Outcome: String, Codable, Sendable { case started, passed, failed, cancelled, recovered }

    /// 事實只能是這幾種固定形狀，不收自由格式的鍵值，避免有人隨手把秘密塞進記錄
    enum Fact: Equatable, Sendable, Codable {
        case fileSize(Int)
        case sha256(String)
        case entryCount(expected: Int, actual: Int)
        case topPaths([String])
        case manifest(id: String, version: String)
        case legacyScript(name: String, sha256: String)
        case exitCode(Int32)
        case timedOut
        case stderrTail(String)
        case appVersion(String)
        case macOS(String)

        private enum Key: String, CodingKey { case kind, value, expected, actual, paths, id, version, name, sha256 }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "fileSize": self = .fileSize(try c.decode(Int.self, forKey: .value))
            case "sha256": self = .sha256(try c.decode(String.self, forKey: .value))
            case "entryCount": self = .entryCount(expected: try c.decode(Int.self, forKey: .expected), actual: try c.decode(Int.self, forKey: .actual))
            case "topPaths": self = .topPaths(try c.decode([String].self, forKey: .paths))
            case "manifest": self = .manifest(id: try c.decode(String.self, forKey: .id), version: try c.decode(String.self, forKey: .version))
            case "legacyScript": self = .legacyScript(name: try c.decode(String.self, forKey: .name), sha256: try c.decode(String.self, forKey: .sha256))
            case "exitCode": self = .exitCode(try c.decode(Int32.self, forKey: .value))
            case "timedOut": self = .timedOut
            case "stderrTail": self = .stderrTail(try c.decode(String.self, forKey: .value))
            case "appVersion": self = .appVersion(try c.decode(String.self, forKey: .value))
            case "macOS": self = .macOS(try c.decode(String.self, forKey: .value))
            case let k: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "未知的事實種類 \(k)")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            switch self {
            case .fileSize(let v): try c.encode("fileSize", forKey: .kind); try c.encode(v, forKey: .value)
            case .sha256(let v): try c.encode("sha256", forKey: .kind); try c.encode(v, forKey: .value)
            case .entryCount(let e, let a): try c.encode("entryCount", forKey: .kind); try c.encode(e, forKey: .expected); try c.encode(a, forKey: .actual)
            case .topPaths(let p): try c.encode("topPaths", forKey: .kind); try c.encode(p, forKey: .paths)
            case .manifest(let id, let v): try c.encode("manifest", forKey: .kind); try c.encode(id, forKey: .id); try c.encode(v, forKey: .version)
            case .legacyScript(let n, let h): try c.encode("legacyScript", forKey: .kind); try c.encode(n, forKey: .name); try c.encode(h, forKey: .sha256)
            case .exitCode(let v): try c.encode("exitCode", forKey: .kind); try c.encode(v, forKey: .value)
            case .timedOut: try c.encode("timedOut", forKey: .kind)
            case .stderrTail(let v): try c.encode("stderrTail", forKey: .kind); try c.encode(v, forKey: .value)
            case .appVersion(let v): try c.encode("appVersion", forKey: .kind); try c.encode(v, forKey: .value)
            case .macOS(let v): try c.encode("macOS", forKey: .kind); try c.encode(v, forKey: .value)
            }
        }
    }

    struct Record: Codable, Equatable, Sendable {
        var time: Date
        var attempt: UUID
        var plugin: String?
        var operation: Operation
        var stage: Stage
        var outcome: Outcome
        var failure: PluginFailure?
        var detail: String?
        var facts: [Fact]
        var repeats: Int?
        var firstTime: Date?

        init(time: Date, attempt: UUID, plugin: String? = nil, operation: Operation, stage: Stage, outcome: Outcome,
             failure: PluginFailure? = nil, detail: String? = nil, facts: [Fact] = [], repeats: Int? = nil, firstTime: Date? = nil) {
            self.time = time; self.attempt = attempt; self.plugin = plugin; self.operation = operation; self.stage = stage
            self.outcome = outcome; self.failure = failure; self.detail = detail; self.facts = facts
            self.repeats = repeats; self.firstTime = firstTime
        }
    }

    static let fileName = "plugins.jsonl"
    static let rotatedName = "plugins.1.jsonl"
    static let dirOverrideKey = "PluginLogDir"   // 開發用：open SplitSwan.app --args -PluginLogDir <絕對路徑>
    static let maxStderrBytes = 1024
    /// 同一個外掛連續相同失敗最多合併這麼多次就先寫出一筆摘要，避免長時間失敗時完全沒有新紀錄
    static let maxMerged = 60

    static var defaultDirectory: URL {
        if let o = UserDefaults.standard.string(forKey: dirOverrideKey), o.hasPrefix("/") { return URL(fileURLWithPath: o) }
        // 測試執行檔沒有 bundle：沒指定資料夾時寫到暫存區，絕不碰使用者真正的記錄
        guard Bundle.main.bundleIdentifier != nil else { return FileManager.default.temporaryDirectory.appendingPathComponent("SplitSwan-unbundled-plugin-logs") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SplitSwan")
    }
    static let shared = PluginEventLog(directory: PluginEventLog.defaultDirectory)

    let directory: URL
    let fileURL: URL
    private let rotatedURL: URL
    private let now: @Sendable () -> Date
    private let maxBytes: Int
    private var runs: [String: RunState] = [:]

    /// 某外掛目前連續失敗的狀態：merged 是已被合併、尚未寫出摘要的次數
    private struct RunState { var failure: PluginFailure; var merged = 0; var first: Date?; var last: Record }

    init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }, maxBytes: Int = 256 * 1024) {
        self.directory = directory
        fileURL = directory.appendingPathComponent(Self.fileName)
        rotatedURL = directory.appendingPathComponent(Self.rotatedName)
        self.now = now
        self.maxBytes = maxBytes
    }

    // MARK: 寫入

    func append(_ record: Record) {
        let r = Self.scrub(record)
        guard r.operation == .run else { write(r); return }
        let key = r.plugin ?? ""
        switch r.outcome {
        case .failed:
            guard let f = r.failure else { write(r); return }
            if var s = runs[key], s.failure == f {
                s.merged += 1
                if s.first == nil { s.first = r.time }
                s.last = r
                runs[key] = s
                if s.merged >= Self.maxMerged { flushSummary(key) }
            } else {
                flushSummary(key)
                write(r)
                runs[key] = RunState(failure: f, last: r)
            }
        case .passed:
            // 成功本身不記錄，否則每分鐘排程一行；只有「失敗後恢復」才有資訊量
            guard runs[key] != nil else { return }
            flushSummary(key)
            runs[key] = nil
            var ok = r
            ok.outcome = .recovered
            write(ok)
        default:
            write(r)
        }
    }

    private func flushSummary(_ key: String) {
        guard var s = runs[key], s.merged > 0 else { return }
        var summary = s.last
        summary.time = now()
        summary.repeats = s.merged
        summary.firstTime = s.first
        write(summary)
        s.merged = 0; s.first = nil
        runs[key] = s
    }

    private func write(_ r: Record) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? enc.encode(r) else { return }
        data.append(0x0A)
        guard prepareDirectory() else { return }
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        var st = Darwin.stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { close(fd); return }
        fchmod(fd, 0o600)
        var off = 0
        let ok = data.withUnsafeBytes { buf -> Bool in
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        let size = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
        close(fd)
        if ok && size > maxBytes { rotate() }
    }

    /// 只保留一份舊檔：先移掉舊的舊檔，再把目前檔改名
    private func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
    }

    /// 資料夾必須是屬於目前使用者的真資料夾（不是 symlink）；不存在就建立成 700
    private func prepareDirectory() -> Bool {
        var st = Darwin.stat()
        if lstat(directory.path, &st) != 0 {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return false }
            guard lstat(directory.path, &st) == 0 else { return false }
        }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o777 != 0o700 { chmod(directory.path, 0o700) }
        return true
    }

    // MARK: 讀取

    func records(attempt: UUID) -> [Record] { all().filter { $0.attempt == attempt } }

    func recent(limit: Int) -> [Record] { Array(all().suffix(max(0, limit))) }

    private func all() -> [Record] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return [rotatedURL, fileURL].flatMap { url -> [Record] in
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return [] }
            let data = (try? FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd()) ?? Data()
            return data.split(separator: 0x0A).compactMap { try? dec.decode(Record.self, from: Data($0)) }
        }
    }

    // MARK: 遮蔽（所有字串進記錄前的唯一入口）

    private static let regexes: (home: NSRegularExpression?, url: NSRegularExpression?, auth: NSRegularExpression?,
                                bearer: NSRegularExpression?, key: NSRegularExpression?, blob: NSRegularExpression?) = (
        try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: FileManager.default.homeDirectoryForCurrentUser.path) + #"(?![A-Za-z0-9_.-])"#),
        // 私密日曆等網址的權杖常在路徑裡，只留 scheme 與主機
        try? NSRegularExpression(pattern: #"(https?://[^\s/?#"'<>]+)[^\s"'<>]*"#),
        try? NSRegularExpression(pattern: #"(?i)(Authorization[ \t]*:[ \t]*)[^\n]+"#),
        try? NSRegularExpression(pattern: #"(?i)(Bearer[ \t]+)[^\s"']+"#),
        try? NSRegularExpression(pattern: #"(?i)(\b(?:[A-Za-z]+_)?(?:token|key)[ \t]*[=:][ \t]*)[^\s&"']+"#),
        // 不含 / 與 -：路徑與連字號名稱很長但不是秘密；base64 的 / 會把長串切成較短片段，仍有機會被其他規則攔下
        try? NSRegularExpression(pattern: #"[A-Za-z0-9+]{32,}={0,2}"#)
    )

    private static func sub(_ re: NSRegularExpression?, _ s: String, _ template: String) -> String {
        guard let re else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func redact(_ text: String) -> String {
        var s = sub(regexes.home, text, "~")
        s = DiagnosticReport.redact(s, secrets: [])
        s = sub(regexes.url, s, "$1")
        s = sub(regexes.auth, s, "$1***")
        s = sub(regexes.bearer, s, "$1***")
        s = sub(regexes.key, s, "$1***")
        s = sub(regexes.blob, s, "***")
        return PluginLogic.sanitize(s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
    }

    /// 保留尾端（錯誤訊息的結論通常在最後），在 Unicode 純量邊界上切
    static func tail(_ s: String, bytes: Int) -> String {
        guard s.utf8.count > bytes else { return s }
        var used = 0
        var cut = s.unicodeScalars.endIndex
        while cut > s.unicodeScalars.startIndex {
            let prev = s.unicodeScalars.index(before: cut)
            let n = String(s.unicodeScalars[prev]).utf8.count
            if used + n > bytes { break }
            used += n; cut = prev
        }
        return String(s.unicodeScalars[cut...])
    }

    static func isSHA256(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) } }

    /// 一次操作：同一個 id 串起開始到結果，每個事件 await 寫完才回來，所以同一次操作的紀錄依序
    struct Attempt: Sendable {
        let id = UUID()
        var operation: Operation
        var plugin: String?
        let log: PluginEventLog

        init(_ operation: Operation, plugin: String? = nil, log: PluginEventLog) {
            self.operation = operation; self.plugin = plugin; self.log = log
        }
        func started(_ stage: Stage) async {
            await record(stage, .started, facts: [.appVersion(AppInfo.version), .macOS(ProcessInfo.processInfo.operatingSystemVersionString)])
        }
        func passed(_ stage: Stage, _ facts: [Fact] = [], detail: String? = nil) async { await record(stage, .passed, detail: detail, facts: facts) }
        func cancelled(_ stage: Stage) async { await record(stage, .cancelled) }
        func record(_ stage: Stage, _ outcome: Outcome, failure: PluginFailure? = nil, detail: String? = nil, facts: [Fact] = []) async {
            await log.append(Record(time: Date(), attempt: id, plugin: plugin, operation: operation, stage: stage, outcome: outcome,
                                    failure: failure, detail: detail, facts: facts))
        }
    }

    static func scrub(_ r: Record) -> Record {
        var out = r
        out.plugin = r.plugin.map(redact)
        out.detail = r.detail.map(redact)
        // sha256 是型別欄位，格式不合就整筆丟掉，不經 redact（否則會被長字串規則蓋成 ***）
        out.facts = r.facts.compactMap { f in
            switch f {
            case .sha256(let h): return isSHA256(h) ? f : nil
            case .legacyScript(let n, let h): return isSHA256(h) ? .legacyScript(name: redact(n), sha256: h) : nil
            case .topPaths(let p): return .topPaths(p.prefix(10).map(redact))
            case .manifest(let id, let v): return .manifest(id: redact(id), version: redact(v))
            case .stderrTail(let t): return .stderrTail(tail(redact(t), bytes: maxStderrBytes))
            case .appVersion(let v): return .appVersion(redact(v))
            case .macOS(let v): return .macOS(redact(v))
            case .fileSize, .entryCount, .exitCode, .timedOut: return f
            }
        }
        return out
    }
}
