// 連線紀錄：在 App 內顯示 strongSwan 的即時 log（取代另開終端機），
// 並把 App 自己的動作（連線、重試、重建通道）一起記進來。畫面只保留最近 1,000 行；
// App 自己的動作另外寫進 ~/Library/Logs/<App>/app.log（AppLogFile），App 重開後仍在，也會併入診斷報告。
import Foundation
import Combine

/// App 動作紀錄檔（A3）。檔案 600、目錄 700；超過 maxBytes 就只留最後 keepBytes（丟掉被切斷的半行）。
/// 只有 App 自己寫，所以輪替用「寫暫存檔再改名」即可。函式都接受路徑參數，方便測試
enum AppLogFile {
    static let maxBytes = 1024 * 1024
    static let keepBytes = 512 * 1024

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(AppInfo.name)/app.log")
    }

    enum Failure: Error { case unsafe(String) }

    /// 例：「2026-10-09 23:05:01 開始連線（手動）…」
    static func format(_ text: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // 一筆紀錄固定一行，內容裡的換行改成空白
        let oneLine = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "\(f.string(from: date)) \(oneLine)\n"
    }

    /// 附加一行，必要時輪替。目錄或檔案是 symlink 一律拒絕
    static func append(_ line: String, to url: URL, maxBytes: Int = maxBytes, keepBytes: Int = keepBytes) throws {
        let dir = url.deletingLastPathComponent()
        try ensureDirectory(dir)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unsafe("無法開啟 \(url.path)：\(String(cString: strerror(errno)))") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        fchmod(fd, 0o600)   // 既有檔案權限不對時一併修正
        try h.write(contentsOf: Data(line.utf8))
        let size = try h.seekToEnd()
        try h.close()
        if size > UInt64(maxBytes) { try rotate(url, keepBytes: keepBytes) }
    }

    /// 只留最後 keepBytes：寫到同目錄的暫存檔（600）再改名蓋過去
    static func rotate(_ url: URL, keepBytes: Int = keepBytes) throws {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return }
        let size = try h.seekToEnd()
        let start = size > UInt64(keepBytes) ? size - UInt64(keepBytes) : 0
        try h.seek(toOffset: start)
        var data = try h.readToEnd() ?? Data()
        try h.close()
        if start > 0, let nl = data.firstIndex(of: 0x0A) { data = Data(data[data.index(after: nl)...]) }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".app.log.\(getpid()).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unsafe("無法建立 \(tmp.path)：\(String(cString: strerror(errno)))") }
        let w = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        fchmod(fd, 0o600)
        try w.write(contentsOf: data)
        try w.close()
        guard rename(tmp.path, url.path) == 0 else { throw Failure.unsafe("無法輪替 \(url.path)：\(String(cString: strerror(errno)))") }
    }

    /// 建立目錄（700）；已存在就確認是自己的一般目錄並修正權限
    static func ensureDirectory(_ dir: URL) throws {
        var st = stat()
        if lstat(dir.path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafe("\(dir.path) 不是目錄") }
            guard st.st_uid == getuid() else { throw Failure.unsafe("\(dir.path) 不屬於目前使用者") }
            if st.st_mode & 0o777 != 0o700 { chmod(dir.path, 0o700) }
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)   // 不受 umask 影響
    }
}

/// strongSwan log 串流中斷後的重接間隔（A3）：5、10、20、40 秒，之後固定 60 秒；
/// 串流撐過 stableAfter 秒才算成功，下次中斷從 5 秒重新開始。
/// 不用「有沒有收到輸出」判斷成功：sudo 失敗也會印一行錯誤
struct StreamBackoff: Equatable {
    static let base: TimeInterval = 5
    static let cap: TimeInterval = 60
    static let stableAfter: TimeInterval = 30

    private(set) var failures = 0

    /// 串流結束時呼叫，回傳要等幾秒再重接
    mutating func next(ranFor seconds: TimeInterval) -> TimeInterval {
        if seconds >= Self.stableAfter { failures = 0 }
        let wait = min(Self.base * pow(2, Double(failures)), Self.cap)
        failures = min(failures + 1, 16)
        return wait
    }
}

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    struct Line: Identifiable, Equatable {
        let id: Int
        let time: Date
        let text: String
        let fromApp: Bool   // true：App 自己的動作；false：strongSwan 的 log
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var streaming = false
    private var nextID = 0
    private var process: Process?
    private var buffer = Data()
    private let maxLines = 1000
    private var backoff = StreamBackoff()
    private var streamStarted = Date()
    /// 寫檔在背景依序進行，不卡主執行緒
    private let fileQueue = DispatchQueue(label: "splitswan.applog")
    private var fileErrorLogged = false

    /// App 自己的動作：顯示在連線紀錄，並寫進 app.log
    func app(_ text: String) {
        append(text, fromApp: true)
        let line = AppLogFile.format(text, at: Date())
        let url = AppLogFile.defaultURL
        fileQueue.async { [weak self] in
            do { try AppLogFile.append(line, to: url) } catch {
                let why = "\(error)"
                Task { @MainActor in self?.fileFailed(why) }
            }
        }
    }

    /// 寫不進 app.log 只提示一次（不再寫檔，避免遞迴）
    private func fileFailed(_ why: String) {
        guard !fileErrorLogged else { return }
        fileErrorLogged = true
        append("無法寫入 App 紀錄檔：\(why)", fromApp: true)
    }

    func clear() { lines.removeAll() }

    /// App 結束時停止串流，避免 swanctl --log 留在背景
    func stop() {
        guard let p = process else { return }
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminate()
        process = nil
        streaming = false
    }

    var allText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return lines.map { "\(f.string(from: $0.time)) \($0.fromApp ? "[App] " : "")\($0.text)" }.joined(separator: "\n")
    }

    /// 開始讀取 strongSwan 的即時 log（輔助程式 `log` 子命令）。中斷就依 StreamBackoff 退避後重接
    /// （輔助程式沒裝好時不會每 5 秒就叫一次 sudo）
    func startStreaming() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", helperPath, "log"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.streaming = false
                let wait = self.backoff.next(ranFor: Date().timeIntervalSince(self.streamStarted))
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self.startStreaming()
            }
        }
        do {
            try p.run()
            process = p
            streaming = true
            streamStarted = Date()
        } catch {
            app("無法讀取 strongSwan log：\(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let text = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { append(text, fromApp: false) }
        }
    }

    private func append(_ text: String, fromApp: Bool) {
        lines.append(Line(id: nextID, time: Date(), text: text, fromApp: fromApp))
        nextID += 1
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}
