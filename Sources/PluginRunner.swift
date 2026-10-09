// 外掛的掃描、權限檢查、執行與排程。純邏輯在 PluginLogic.swift。
// 外掛以使用者身分執行（絕不經 sudo／helper），每次執行限時 10 秒，環境變數只給固定的幾個。
import AppKit
import Foundation

@MainActor
final class PluginRunner: ObservableObject {
    static let shared = PluginRunner(directory: PluginRunner.defaultDirectory, stateRoot: PluginRunner.defaultStateRoot)

    static let enabledKey = "PluginsEnabled"          // 設定頁的啟用開關，預設關
    // 開發用：open SplitSwan.app --args -PluginsDir <絕對路徑> -PluginStateDir <絕對路徑> -PluginsEnabled YES
    static let dirOverrideKey = "PluginsDir"
    static let stateOverrideKey = "PluginStateDir"

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static var defaultDirectory: URL {
        if let o = UserDefaults.standard.string(forKey: dirOverrideKey), o.hasPrefix("/") { return URL(fileURLWithPath: o) }
        return URL(fileURLWithPath: home + "/.config/splitswan/plugins")
    }
    static var defaultStateRoot: URL {
        if let o = UserDefaults.standard.string(forKey: stateOverrideKey), o.hasPrefix("/") { return URL(fileURLWithPath: o) }
        return URL(fileURLWithPath: home + "/.config/splitswan/plugin-state")
    }

    /// 外掛執行時的 PATH（不沿用 App 的環境變數）
    static let pluginPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    struct Plugin: Identifiable, Equatable {
        let id: String               // 檔名
        var name: String
        var interval: TimeInterval
        var path: String             // 外掛資料夾內的路徑
        var resolved: String?        // symlink 解析後的實際路徑（實際執行的就是它）
        var problem: String?         // 權限檢查不通過的原因（不會執行）
        var lastRun: Date?
        var output: PluginLogic.Output?
        var error: String?           // 上次執行的錯誤（非 0 結束、逾時）：選單只顯示原因
        var actionError: String?     // 上次點擊動作的錯誤：保留上次的項目，只在標題加 ⚠︎
        var running = false

        var title: String {
            if let t = output?.title, !t.isEmpty { return t }
            return name
        }
        /// 讓選單只顯示原因、不顯示項目的錯誤
        var blocking: String? { problem ?? error }
        /// 選單與設定頁顯示的錯誤原因
        var failure: String? { problem ?? error ?? actionError }
    }

    @Published private(set) var plugins: [Plugin] = []
    @Published private(set) var skipped: [String] = []      // 超過數量上限而略過的檔名
    @Published private(set) var folderMissing = false

    let directory: URL
    let stateRoot: URL
    var timeout: TimeInterval = PluginLogic.timeout
    /// 通知發送端（App 內接到 DropNotifier；測試時換成記錄用的閉包）
    var notifier: (_ title: String, _ body: String, _ href: URL?) -> Void = { _, _, _ in }
    var now: () -> Date = Date.init

    private var nextDue: [String: Date] = [:]
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var notifyLog: PluginLogic.NotifyLog?
    /// 有程序正在跑的外掛（排程執行或點擊動作）。關閉開關不會清掉，
    /// 所以關閉後立刻重開也不會和還沒結束的那次重疊執行
    private var inFlight: Set<String> = []

    init(directory: URL, stateRoot: URL) {
        self.directory = directory
        self.stateRoot = stateRoot
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    // MARK: 啟動／停止

    /// App 啟動時呼叫；開關關閉時什麼都不做
    func start() {
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshIfEnabled() }
            }
        }
        setEnabled(Self.isEnabled)
    }

    /// 設定頁切換開關時呼叫
    func setEnabled(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else {
            setPlugins([])
            if !skipped.isEmpty { skipped = [] }
            nextDue = [:]
            return
        }
        // 每 5 秒檢查一次哪些外掛到期；同一外掛前一次還沒跑完不會重疊執行
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await refreshAll() }
    }

    /// 喚醒、開啟設定頁時呼叫
    func refreshIfEnabled() {
        guard Self.isEnabled else { return }
        Task { await refreshAll() }
    }

    /// 重新掃描並立刻執行全部外掛（測試也直接呼叫這個）
    func refreshAll() async {
        scan()
        for p in plugins where p.actionError != nil { update(p.id) { $0.actionError = nil } }
        await withTaskGroup(of: Void.self) { group in
            for p in plugins { group.addTask { await self.run(p.id) } }
        }
    }

    private func tick() {
        scan()
        let t = now()
        for p in plugins where !inFlight.contains(p.id) && (nextDue[p.id] ?? .distantPast) <= t {
            Task { await run(p.id) }
        }
    }

    // MARK: 掃描

    /// 列出外掛資料夾內「可執行的一般檔案」，依檔名排序、最多 10 個，並做權限檢查
    func scan() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            if !folderMissing { folderMissing = true }
            setPlugins([])
            if !skipped.isEmpty { skipped = [] }
            return
        }
        if folderMissing { folderMissing = false }
        let uid = getuid()
        var found: [Plugin] = []
        for file in names.sorted() {
            guard let fn = PluginLogic.parseFileName(file) else { continue }   // 隱藏檔
            let path = directory.appendingPathComponent(file).path
            guard let resolved = Self.realPath(path), let st = Self.statOf(resolved),
                  st.isRegular, access(resolved, X_OK) == 0 else { continue }  // 子目錄、不可執行檔略過
            let problem = Self.permissionProblem(resolved: resolved, pluginDir: directory.path, uid: uid)
            found.append(Plugin(id: file, name: fn.name, interval: fn.interval, path: path,
                                resolved: resolved, problem: problem))
        }
        let newSkipped = found.dropFirst(PluginLogic.maxPlugins).map(\.id)
        if newSkipped != skipped { skipped = newSkipped }
        found = Array(found.prefix(PluginLogic.maxPlugins))
        // 保留上次的執行結果
        let old = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        setPlugins(found.map { p in
            var n = p
            n.running = inFlight.contains(p.id)
            guard let o = old[p.id] else { return n }
            n.lastRun = o.lastRun
            n.output = o.output
            n.error = p.problem == nil ? o.error : nil
            n.actionError = o.actionError
            return n
        })
        let ids = Set(plugins.map(\.id))
        nextDue = nextDue.filter { ids.contains($0.key) }
    }

    /// 執行目標（symlink 解析後）與它所在的資料夾、以及外掛資料夾本身，都要屬於目前使用者且不可被 group／other 寫入
    static func permissionProblem(resolved: String, pluginDir: String?, uid: UInt32) -> String? {
        let parent = (resolved as NSString).deletingLastPathComponent
        if let pluginDir, let r = PluginLogic.permissionProblem(file: statOf(resolved), dir: statOf(pluginDir), uid: uid) {
            return r
        }
        return PluginLogic.permissionProblem(file: statOf(resolved), dir: statOf(parent), uid: uid)
    }

    static func statOf(_ path: String) -> PluginLogic.FileStat? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return PluginLogic.FileStat(uid: st.st_uid, mode: UInt16(st.st_mode))
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    // MARK: 執行

    func run(_ id: String) async {
        guard let i = plugins.firstIndex(where: { $0.id == id }), !inFlight.contains(id) else { return }
        let p = plugins[i]
        nextDue[id] = now().addingTimeInterval(p.interval)
        guard p.problem == nil, let exe = p.resolved else { return }   // 權限不符：不執行，原因已在 problem
        guard let state = prepareStateDir(p.name) else {
            update(id) { $0.error = "無法建立外掛的狀態資料夾"; $0.lastRun = self.now() }
            return
        }
        setInFlight(id, true)
        let r = await ProcessRunner.runLimited("/usr/bin/env", Self.wrapperArgs(exe: exe, args: [], state: state),
                                               timeout: timeout, maxBytes: Self.readLimit)
        setInFlight(id, false)
        let finished = now()
        update(id) { pl in
            pl.lastRun = finished
            if r.timedOut {
                pl.error = "執行逾時（超過 \(Int(self.timeout)) 秒）"
            } else if r.code != 0 {
                let detail = Self.lastLine(ofFile: state + "/.stderr")
                pl.error = "結束碼 \(r.code)" + (detail.map { "：\($0)" } ?? "")
            } else {
                pl.error = nil
                pl.output = PluginLogic.parseOutput(r.output)
            }
        }
        if r.code == 0, !r.timedOut, let out = plugins.first(where: { $0.id == id })?.output {
            sendNotifications(plugin: p.name, output: out)
        }
    }

    /// 讀取輸出的上限：比 64 KB 多 1 byte，PluginLogic.parseOutput 才知道被截斷
    static let readLimit = PluginLogic.maxOutputBytes + 1

    private func setInFlight(_ id: String, _ on: Bool) {
        if on { inFlight.insert(id) } else { inFlight.remove(id) }
        update(id) { $0.running = on }
    }

    /// 經 /usr/bin/env -i 清空環境變數，再由 /bin/sh 以固定字串 exec 外掛（外掛路徑與參數都是獨立的 argv，不拼進 shell 字串）。
    /// stdout 是外掛輸出；stderr 寫到狀態資料夾的 .stderr，錯誤時顯示最後一行。
    static func wrapperArgs(exe: String, args: [String], state: String) -> [String] {
        ["-i", "PATH=\(pluginPATH)", "HOME=\(home)", "SPLITSWAN_PLUGIN_STATE=\(state)", "SPLITSWAN=1",
         "/bin/sh", "-c", "exec \"$0\" \"$@\" 2>\"$SPLITSWAN_PLUGIN_STATE/.stderr\"", exe] + args
    }

    /// 建立 plugin-state/<名稱>（700），回傳路徑
    private func prepareStateDir(_ name: String) -> String? {
        let fm = FileManager.default
        let dir = stateRoot.appendingPathComponent(name).path
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateRoot.path)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        } catch { return nil }
        return dir
    }

    static func lastLine(ofFile path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let data = (try? h.readToEnd()) ?? Data()
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let line, !line.isEmpty else { return nil }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    /// 只在內容真的變了才發布，選單不會每 5 秒整段重建
    private func update(_ id: String, _ f: (inout Plugin) -> Void) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        var p = plugins[i]
        f(&p)
        if p != plugins[i] { plugins[i] = p }
    }

    private func setPlugins(_ new: [Plugin]) {
        if new != plugins { plugins = new }
    }

    // MARK: 通知

    private var notifyLogURL: URL { stateRoot.appendingPathComponent("notified.json") }

    private func sendNotifications(plugin: String, output: PluginLogic.Output) {
        let today = PluginLogic.dayString(now())
        var log = notifyLog ?? (try? JSONDecoder().decode(PluginLogic.NotifyLog.self, from: Data(contentsOf: notifyLogURL)))
            ?? PluginLogic.NotifyLog()
        var changed = false
        let all = output.items.flatMap { [$0] + $0.children }
        for item in all where item.notify && !item.isSeparator {
            guard PluginLogic.shouldNotify(plugin: plugin, key: item.notifyKey, today: today, log: log) else { continue }
            notifier(output.title.isEmpty ? plugin : output.title, item.text, item.href)
            log = PluginLogic.recordNotify(plugin: plugin, key: item.notifyKey, today: today, log: log)
            changed = true
        }
        if log.day != today { log = PluginLogic.NotifyLog(day: today, keys: []); changed = true }
        notifyLog = log
        if changed, let data = try? JSONEncoder().encode(log) {
            try? data.write(to: notifyLogURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notifyLogURL.path)
        }
    }

    // MARK: 點擊

    /// 選單項目被點擊：href 開網址；bash= 必須是外掛本身或外掛資料夾內的程式，且通過擁有者／權限檢查才執行；
    /// refresh=true 完成後重跑外掛。點擊動作與排程執行共用 inFlight，不會重疊；失敗時保留上次的項目、標題加 ⚠︎
    func perform(pluginID: String, item: PluginLogic.Item) {
        if let url = item.href { NSWorkspace.shared.open(url) }
        guard let p = plugins.first(where: { $0.id == pluginID }) else { return }
        guard let bash = item.bash else {
            if item.refresh { rerun(pluginID) }
            return
        }
        guard let exe = Self.realPath(bash), let dir = Self.realPath(directory.path) else {
            update(pluginID) { $0.actionError = "點擊動作被拒：找不到 \(bash)" }
            return
        }
        if let why = PluginLogic.bashTargetProblem(resolved: exe, pluginDir: dir, pluginSelf: p.resolved)
            ?? Self.permissionProblem(resolved: exe, pluginDir: nil, uid: getuid()) {
            update(pluginID) { $0.actionError = "點擊動作被拒：\(why)" }
            return
        }
        guard let state = prepareStateDir(p.name) else { return }
        Task {
            // 外掛正在跑（排程或上一個點擊）就等它結束，最多等一次執行的時間
            let deadline = Date().addingTimeInterval(timeout + 3)
            while inFlight.contains(pluginID), Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !inFlight.contains(pluginID) else {
                update(pluginID) { $0.actionError = "點擊動作略過：外掛仍在執行中" }
                return
            }
            setInFlight(pluginID, true)
            let r = await ProcessRunner.runLimited("/usr/bin/env", Self.wrapperArgs(exe: exe, args: item.bashArgs, state: state),
                                                   timeout: timeout, maxBytes: Self.readLimit)
            setInFlight(pluginID, false)
            update(pluginID) { pl in
                pl.actionError = r.timedOut ? "點擊動作逾時" : (r.code != 0 ? "點擊動作結束碼 \(r.code)" : nil)
            }
            if item.refresh { rerun(pluginID) }
        }
    }

    /// 立刻重跑；正在執行中就排到下一次檢查（最多 5 秒後）
    private func rerun(_ id: String) {
        nextDue[id] = .distantPast
        Task { await run(id) }
    }

    // MARK: 設定頁

    /// 「開啟外掛資料夾」：不存在就建立（700）
    func openFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(directory)
        scan()
    }
}
