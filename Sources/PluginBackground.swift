import Foundation
import Darwin
import CryptoKit

/// 移除只處理可由執行路徑或外掛狀態目錄確認歸屬的工作，不比對程序名稱或執行外掛鉤子。
struct PluginBackground: Sendable {
    struct Context: Sendable {
        let entrypoint: String
        let codeRoot: String?
        let state: String

        func owns(_ path: String) -> Bool {
            guard path.hasPrefix("/"), !path.contains("\0") else { return false }
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            return path == entrypoint || [codeRoot, state].compactMap { $0 }.contains { path.hasPrefix($0 + "/") }
        }
        func matches(executable: String, arguments: [String], environment: [String: String]) -> Bool {
            if environment["SPLITSWAN_PLUGIN_STATE"] == state { return true }
            if owns(executable) { return true }
            // 編輯器、搜尋或其他程式提到外掛檔名，不代表它正在執行外掛。
            let interpreter = URL(fileURLWithPath: executable).lastPathComponent
            guard ["sh", "bash", "zsh", "node", "python", "python3", "ruby", "perl", "osascript"].contains(interpreter) || interpreter.hasPrefix("python3.") else { return false }
            let args = Array(arguments.dropFirst())
            guard !args.contains("-c"), !args.contains("-e") else { return false }
            return args.first(where: { !$0.hasPrefix("-") }).map(owns) == true
        }
    }
    struct Identity: Hashable, Sendable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64
    }
    struct Job: Sendable {
        let identity: Identity
        let parent: Int32
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }
    struct Service: Sendable {
        let url: URL
        let label: String
        let digest: Data
    }
    struct ServiceStatus: Sendable {
        let code: Int32
        var path = ""
        var executable = ""
        var arguments: [String] = []
        var environment: [String: String] = [:]
        var identity: Identity?
    }
    struct Report: Sendable {
        let jobs: [Job]
        let services: [Service]
        var summary: String {
            if jobs.isEmpty && services.isEmpty { return "未偵測到可辨識的外掛背景程序或登入背景服務。移除時會再次檢查。" }
            return "偵測到 \(jobs.count) 個相關程序、\(services.count) 個登入背景服務。確認後會先停止，再移除外掛。"
        }
    }
    struct Result: Sendable {
        var processes = 0
        var services = 0
        var summary: String { "已停止 App 排程，停止 \(processes) 個相關程序、移除 \(services) 個登入背景服務，並完成再次檢查。" }
    }
    var agents: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    var readJobs: @Sendable () throws -> [Job] = { try Self.processes() }
    var signal: @Sendable (Identity, Int32) throws -> Void = { try Self.sendSignal($0, $1) }
    var serviceStatus: @Sendable (String) async -> ServiceStatus = { await Self.lookupService($0) }
    var command: @Sendable ([String]) async -> Int32 = { arguments in
        let r = await ProcessRunner.execute("/bin/launchctl", arguments, timeout: 5, maxBytes: 1024, qos: .utility)
        return r.launchError == nil && !r.timedOut ? r.code : -1
    }

    func inspect(_ context: Context) throws -> Report {
        Report(jobs: related(try readJobs(), context: context), services: try services(context))
    }
    func related(_ all: [Job], context: Context, known: Set<Identity> = [], includeDirect: Bool = true) -> [Job] {
        var selected = Set(all.filter { known.contains($0.identity) || (includeDirect && context.matches(executable: $0.executable, arguments: $0.arguments, environment: $0.environment)) }.map { $0.identity.pid })
        selected.remove(getpid())
        var changed = true
        while changed {
            changed = false
            for job in all where job.identity.pid != getpid() && selected.contains(job.parent) {
                if selected.insert(job.identity.pid).inserted { changed = true }
            }
        }
        return all.filter { selected.contains($0.identity.pid) }
    }
    func services(_ context: Context) throws -> [Service] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: agents.path) else { return [] }
        try PluginPackageStore.securePath(agents.path, regular: false)
        let urls = try fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)
        guard urls.count <= 2000 else { throw PluginPackage.fail(.backgroundTooManyJobs) }
        var matches: [Service] = []
        for url in urls where url.pathExtension == "plist" {
            var st = stat()
            guard lstat(url.path, &st) == 0, [getuid(), 0].contains(st.st_uid),
                  [S_IFREG, S_IFLNK].contains(st.st_mode & S_IFMT) else { continue }
            var target = stat()
            guard stat(url.path, &target) == 0, target.st_mode & S_IFMT == S_IFREG,
                  target.st_size <= 65536, let data = try? Data(contentsOf: url), data.count <= 65536,
                  let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
            let args = dict["ProgramArguments"] as? [String] ?? []
            let executable = dict["Program"] as? String ?? args.first ?? ""
            let env = dict["EnvironmentVariables"] as? [String: String] ?? [:]
            guard context.matches(executable: executable, arguments: args, environment: env) else { continue }
            try PluginPackageStore.securePath(url.path, regular: true)
            guard let label = dict["Label"] as? String, !label.isEmpty, label.utf8.count <= 255,
                  label.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
                throw PluginPackage.fail(.backgroundInvalidLabel)
            }
            matches.append(Service(url: url, label: label, digest: Data(SHA256.hash(data: data))))
        }
        guard Set(matches.map(\.label)).count == matches.count else { throw PluginPackage.fail(.backgroundDuplicateLabel) }
        guard matches.count <= 20 else { throw PluginPackage.fail(.backgroundTooManyMatches) }
        return matches
    }

    func stop(_ context: Context, trash: @escaping PluginPackageStore.TrashOperation,
              progress: @Sendable (String) async -> Void = { _ in }) async throws -> Result {
        var result = Result()
        let serviceDeadline = ContinuousClock.now.advanced(by: .seconds(25))
        func status(_ target: String) async throws -> ServiceStatus {
            guard .now < serviceDeadline else { throw PluginPackage.fail(.backgroundCheckTimeout) }
            return await serviceStatus(target)
        }
        func run(_ args: [String]) async throws -> Int32 {
            guard .now < serviceDeadline else { throw PluginPackage.fail(.backgroundStopTimeout) }
            return await command(args)
        }
        func verify(_ value: ServiceStatus, _ service: Service) throws {
            guard value.code == 0, value.path.hasPrefix("/"),
                  URL(fileURLWithPath: value.path).resolvingSymlinksInPath().path == service.url.resolvingSymlinksInPath().path,
                  context.matches(executable: value.executable, arguments: value.arguments, environment: value.environment) else {
                throw PluginPackage.fail(.backgroundServiceMismatch)
            }
        }
        await progress("正在停用登入背景服務…")
        for service in try services(context) {
            try PluginPackageStore.securePath(service.url.path, regular: true)
            guard Data(SHA256.hash(data: try Data(contentsOf: service.url))) == service.digest else {
                throw PluginPackage.fail(.backgroundChangedDuringCheck)
            }
            let target = "gui/\(getuid())/" + service.label
            let initial = try await status(target)
            if initial.code != 113 { try verify(initial, service) }
            guard try await run(["disable", target]) == 0 else { throw PluginPackage.fail(.backgroundDisableFailed) }
            let current = try await status(target)
            if current.code != 113 {
                try verify(current, service)
                // launchd 的 bootout 是非同步收尾；忽略 TERM 的程序會讓服務持續顯示為已載入。
                // 先記住經驗證的該服務程序樹，再同時卸載與收尾，不能把其他服務一併殺掉。
                let family = try current.identity.map { id in
                    Set(related(try readJobs(), context: context, known: [id], includeDirect: false).map(\.identity))
                }
                let unloading = Task { try await run(["bootout", target]) }
                do {
                    if let family { result.processes += try await stopProcesses(context, roots: family) }
                    _ = try await unloading.value
                } catch {
                    _ = try? await unloading.value
                    throw error
                }
            }
            while true {
                let remaining = try await status(target)
                if remaining.code == 113 { break }
                try verify(remaining, service)
                try await Task.sleep(for: .milliseconds(80))
            }
            // 保留可復原的 plist；從 LaunchAgents 移出後，下次登入也不會再次排程。
            try PluginPackageStore.securePath(service.url.path, regular: true)
            guard Data(SHA256.hash(data: try Data(contentsOf: service.url))) == service.digest else { throw PluginPackage.fail(.backgroundContentChanged) }
            try trash(service.url)
            result.services += 1
        }
        await progress("正在停止相關程序並確認結果…")
        result.processes += try await stopProcesses(context)
        guard try services(context).isEmpty else { throw PluginPackage.fail(.backgroundReappeared) }
        return result
    }

    func stopProcesses(_ context: Context, roots: Set<Identity>? = nil) async throws -> Int {
        var tracked = roots ?? []
        var terminated = Set<Identity>()
        let start = ContinuousClock.now
        while true {
            let all = try readJobs()
            for job in related(all, context: context, known: tracked, includeDirect: roots == nil) { tracked.insert(job.identity) }
            // 即使父程序先退出，已確認歸屬的子程序也要清理；以啟動時間防止 PID 重用。
            let alive = all.filter { tracked.contains($0.identity) }
            if alive.isEmpty {
                try await Task.sleep(for: .milliseconds(80))
                if related(try readJobs(), context: context, known: tracked, includeDirect: roots == nil).isEmpty { break }
            }
            guard start.duration(to: .now) < .seconds(5) else { throw PluginPackage.fail(.backgroundProcessRestarting) }
            for job in alive {
                let first = terminated.insert(job.identity).inserted
                if first || start.duration(to: .now) >= .seconds(2) {
                    try signal(job.identity, first ? SIGTERM : SIGKILL)
                }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        return terminated.count
    }

    static func identity(_ pid: Int32) -> (Identity, Int32)? {
        var info = proc_bsdinfo()
        guard pid > 1, pid != getpid(), proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == getuid(), info.pbi_ruid == getuid(), info.pbi_status != SZOMB else { return nil }
        return (Identity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec), Int32(info.pbi_ppid))
    }
    static func lookupService(_ target: String) async -> ServiceStatus {
        let r = await ProcessRunner.execute("/bin/launchctl", ["print", target], timeout: 5, maxBytes: 131072, qos: .utility, stderrLimit: 1024)
        guard r.launchError == nil, !r.timedOut, !r.truncated else { return ServiceStatus(code: -1) }
        var result = ServiceStatus(code: r.code)
        var inArguments = false
        for raw in r.output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("path = ") && result.path.isEmpty { result.path = String(line.dropFirst(7)) }
            if line.hasPrefix("program = ") && result.executable.isEmpty { result.executable = String(line.dropFirst(10)) }
            if line.hasPrefix("pid = "), let pid = Int32(line.dropFirst(6)) { result.identity = identity(pid)?.0 }
            if line == "arguments = {" { inArguments = true; continue }
            if inArguments {
                if line == "}" { inArguments = false } else { result.arguments.append(line) }
            }
            if line.hasPrefix("SPLITSWAN_PLUGIN_STATE => ") { result.environment["SPLITSWAN_PLUGIN_STATE"] = String(line.dropFirst(26)) }
        }
        return result
    }
    static func sendSignal(_ expected: Identity, _ value: Int32) throws {
        guard identity(expected.pid)?.0 == expected else { return }
        guard kill(expected.pid, value) == 0 || errno == ESRCH else { throw PluginPackage.fail(.backgroundKillFailed) }
    }
    static func processes() throws -> [Job] {
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 32768 else { throw PluginPackage.fail(.backgroundProcessListUnreadable) }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard actual >= 0, actual < pids.count else { throw PluginPackage.fail(.backgroundProcessListChanging) }
        return pids.prefix(Int(actual)).compactMap { pid in
            guard let (id, parent) = identity(pid) else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            _ = proc_pidpath(pid, &path, UInt32(path.count))
            let executable = String(cString: path)
            let values = arguments(pid)
            return Job(identity: id, parent: parent, executable: executable, arguments: values.0, environment: values.1)
        }
    }
    /// 只保留歸屬判斷所需的環境鍵；不輸出或保存其他程序的環境、參數或憑證。
    static func arguments(_ pid: Int32) -> ([String], [String: String]) {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        let limit = sysconf(_SC_ARG_MAX)
        guard limit > 4, limit <= 2 * 1024 * 1024 else { return ([], [:]) }
        var bytes = [UInt8](repeating: 0, count: limit)
        var size = bytes.count
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return ([], [:]) }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 32768 else { return ([], [:]) }
        var offset = 4
        func next() -> String? {
            guard offset < size else { return nil }
            let begin = offset
            while offset < size && bytes[offset] != 0 { offset += 1 }
            guard offset < size else { return nil }
            let value = String(decoding: bytes[begin..<offset], as: UTF8.self)
            offset += 1
            return value
        }
        guard next() != nil else { return ([], [:]) }
        while offset < size && bytes[offset] == 0 { offset += 1 }
        var args: [String] = []
        for _ in 0..<argc { guard let arg = next() else { return ([], [:]) }; args.append(arg) }
        var env: [String: String] = [:]
        while let pair = next(), !pair.isEmpty {
            if pair.hasPrefix("SPLITSWAN_PLUGIN_STATE=") { env["SPLITSWAN_PLUGIN_STATE"] = String(pair.dropFirst(23)) }
        }
        return (args, env)
    }
}
