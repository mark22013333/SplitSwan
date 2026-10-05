// F3 App 內建診斷報告（docs/SPEC-1.3.md §5）：收集資料、寫到桌面。
// 外部指令都在背景執行並各自限時，整份在 20 秒內完成；UI 狀態只在主執行緒更新。
// 只讀取現況：不呼叫 up／down／reload，不會改變連線狀態。組字與遮蔽在 DiagnosticReport。
import AppKit
import Combine

@MainActor
final class DiagnosticRunner: ObservableObject {
    static let shared = DiagnosticRunner()

    @Published private(set) var running = false
    @Published private(set) var progressText = ""
    @Published private(set) var lastMessage: String?
    private var collecting = false   // 收集階段中才接受進度更新

    /// 「環境檢查」頁的「產生診斷報告」按鈕
    func generate(checks: [CheckItem]) {
        guard !running else { return }
        running = true
        lastMessage = nil
        progressText = "正在收集診斷資訊…"
        let checkLines = checks.map { "\(Self.mark($0.level)) \($0.title)：\($0.detail)" }
        collecting = true
        Task {
            let started = Date()
            let (text, name) = await Self.collect(checks: checkLines, started: started) { done, total in
                // 進度更新是另外排進主執行緒的，可能比「正在寫入報告…」晚到：收集階段結束後一律丟掉
                Task { @MainActor in
                    guard self.collecting else { return }
                    self.progressText = "正在收集診斷資訊（\(done)/\(total)）…"
                }
            }
            collecting = false
            progressText = "正在寫入報告…"
            let result = await Self.write(text, name: name)
            running = false
            progressText = ""
            switch result {
            case .success(let url):
                lastMessage = "已產生 \(url.lastPathComponent)（在桌面）"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error):
                lastMessage = "無法寫入診斷報告：\(error.localizedDescription)"
            }
        }
    }

    private static func mark(_ l: CheckLevel) -> String {
        switch l {
        case .ok: return "[正常]"
        case .warn: return "[注意]"
        case .fail: return "[異常]"
        case .checking: return "[檢查中]"
        }
    }

    // MARK: 收集

    /// 所有外部指令同時跑，各自限時；回傳遮蔽後的全文與檔名
    nonisolated private static func collect(checks: [String], started: Date,
                                            progress: @escaping @Sendable (Int, Int) -> Void) async -> (String, String) {
        let settings = ConfigStore.load()
        let history = GatewayHistory.decode(UserDefaults.standard.data(forKey: GatewayHistory.defaultsKey))
        let sec = ConfigStore.secretsStatus()
        let secrets = ConfigStore.secretsForRedaction()
        let targets = DiagnosticReport.targets(remoteTS: settings.remoteTS)
        let host = DiagnosticReport.probeHost

        enum Job { case chip, status, sas, dns, dnsProbe, https, route(String) }
        var jobs: [Job] = [.chip, .status, .sas, .dns, .dnsProbe, .https]
        jobs += targets.map { .route($0) }
        let total = jobs.count + 1   // 加上讀 log 檔

        var results: [String: DiagnosticReport.CommandResult] = [:]
        await withTaskGroup(of: (String, DiagnosticReport.CommandResult).self) { group in
            for job in jobs {
                group.addTask {
                    switch job {
                    case .chip:
                        return ("chip", await runLimited("/usr/bin/uname", ["-m"], timeout: 3))
                    case .status:
                        return ("status", await runLimited("/usr/bin/sudo", ["-n", helperPath, "status"], timeout: 5))
                    case .sas:
                        return ("sas", await runLimited("/usr/bin/sudo", ["-n", helperPath, "sas"], timeout: 6))
                    case .dns:
                        return ("dns", await runLimited("/usr/sbin/scutil", ["--dns"], timeout: 5))
                    case .dnsProbe:
                        return ("dnsProbe", await runLimited("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host], timeout: 5))
                    case .https:
                        // curl 自己限時 5 秒；外層多給 1 秒讓它正常結束並印出結果
                        return ("https", await runLimited("/usr/bin/curl",
                            ["-sS", "-o", "/dev/null", "-w", "http=%{http_code} time=%{time_total}s\n",
                             "--max-time", "5", "https://\(host)"], timeout: 6))
                    case .route(let ip):
                        return ("route:" + ip, await runLimited("/sbin/route", ["-n", "get", ip], timeout: 3))
                    }
                }
            }
            var done = 0
            for await (key, r) in group {
                results[key] = r
                done += 1
                progress(done, total)
            }
        }
        let log = DiagnosticReport.readTail(path: ConfigStore.charonLogPath)
        progress(total, total)

        let missing = DiagnosticReport.CommandResult(code: 127, output: "")
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?")（build \(info["CFBundleVersion"] as? String ?? "?")）"
        let input = DiagnosticReport.Input(
            generatedAt: started,
            elapsed: Date().timeIntervalSince(started),
            appName: AppInfo.name,
            appVersion: version,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: results["chip"] ?? missing,
            checks: checks,
            helperStatus: results["status"] ?? missing,
            helperSAs: results["sas"] ?? missing,
            settings: settings,
            pskSet: sec.psk,
            passwordSet: sec.password,
            history: history,
            routes: targets.map { ($0, results["route:" + $0] ?? missing) },
            dns: results["dns"] ?? missing,
            dnsProbe: results["dnsProbe"] ?? missing,
            httpsProbe: results["https"] ?? missing,
            charonLog: log,
            logPath: ConfigStore.charonLogPath)
        let text = DiagnosticReport.build(input, secrets: secrets)
        return (text, DiagnosticReport.fileName(app: AppInfo.name, date: started))
    }

    /// 寫到桌面（背景執行）。報告含公司閘道與網段，以 600 權限建立；
    /// 用 O_EXCL 建新檔，不覆蓋既有檔案、也不跟隨 symlink（同一秒產生兩份時檔名加 -2、-3…）
    nonisolated private static func write(_ text: String, name: String) async -> Result<URL, Error> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask,
                                                              appropriateFor: nil, create: false)
                    cont.resume(returning: .success(try writePrivate(Data(text.utf8), dir: desktop, name: name)))
                } catch {
                    cont.resume(returning: .failure(error))
                }
            }
        }
    }

    /// 在 dir 底下以 600 權限建立新檔並寫入，回傳實際路徑
    nonisolated static func writePrivate(_ data: Data, dir: URL, name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...20 {
            let candidate = n == 1 ? name : "\(base)-\(n).\(ext)"
            let url = dir.appendingPathComponent(candidate)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw ConfigError.invalid("無法建立 \(url.path)：\(String(cString: strerror(errno)))")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            return url
        }
        throw ConfigError.invalid("桌面上已有太多同名的報告檔")
    }

    // MARK: 限時執行外部指令

    /// 實作在 ProcessRunner；保留這個名稱給既有呼叫端
    nonisolated static func runLimited(_ exe: String, _ args: [String], timeout: TimeInterval) async -> DiagnosticReport.CommandResult {
        await ProcessRunner.runLimited(exe, args, timeout: timeout)
    }
}
