// 外掛的掃描、權限檢查、執行與排程。純邏輯在 PluginLogic.swift。
// 外掛以使用者身分執行（絕不經 sudo／helper），每次執行限時 10 秒，環境變數只給固定的幾個。
//
// 效能原則（外掛不可讓 App 變吃資源）：
// - 關閉時零開銷：沒有 timer、不掃描、不建立 plugin-state、不訂閱任何事件（isActive 為 false）。
// - 不輪詢資料夾：用 DispatchSource 監看外掛資料夾本身的 write／delete／rename（kernel 事件，閒置時零成本），
//   另外在開啟設定頁、手動重新整理、喚醒時重新掃描。
// - 每個外掛一個 repeating Timer，tolerance＝間隔 10%（至少 1 秒）讓系統合併喚醒。
// - 執行、權限檢查、輸出解析都在背景（QoS .utility），主執行緒只在結果真的變了才更新 @Published。
// - 睡眠、螢幕關閉、鎖定、螢幕保護程式期間暫停全部排程，恢復後各跑一次再恢復排程。
// - 同時最多執行 2 個外掛，其餘排隊。
import AppKit
import Foundation

@MainActor
final class PluginRunner: ObservableObject {
    static let shared = PluginRunner(directory: PluginRunner.defaultDirectory, stateRoot: PluginRunner.defaultStateRoot)

    static let enabledKey = "PluginsEnabled"          // 設定頁的啟用開關，預設關
    // 開發用：open SplitSwan.app --args -PluginsDir <絕對路徑> -PluginStateDir <絕對路徑> -PluginsEnabled YES
    static let dirOverrideKey = "PluginsDir"
    static let stateOverrideKey = "PluginStateDir"

    nonisolated static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static var defaultDirectory: URL {
        if let o = UserDefaults.standard.string(forKey: dirOverrideKey), o.hasPrefix("/") { return URL(fileURLWithPath: o) }
        return URL(fileURLWithPath: home + "/.config/splitswan/plugins")
    }
    static var defaultStateRoot: URL {
        if let o = UserDefaults.standard.string(forKey: stateOverrideKey), o.hasPrefix("/") { return URL(fileURLWithPath: o) }
        return URL(fileURLWithPath: home + "/.config/splitswan/plugin-state")
    }

    /// 外掛執行時的 PATH（不沿用 App 的環境變數）
    nonisolated static let pluginPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// 讀取輸出的上限：比 64 KB 多 1 byte，PluginLogic.parseOutput 才知道被截斷
    nonisolated static let readLimit = PluginLogic.maxOutputBytes + 1

    /// 選單需要的內容。只有這些欄位真的變了才會發布，選單才會重建
    struct Plugin: Identifiable, Equatable {
        let id: String               // 檔名
        var name: String
        var interval: TimeInterval
        var path: String             // 外掛資料夾內的路徑
        var resolved: String?        // symlink 解析後的實際路徑（實際執行的就是它）
        var problem: String?         // 權限檢查不通過的原因（不會執行）
        var output: PluginLogic.Output?
        var error: String?           // 上次執行的錯誤（非 0 結束、逾時）：選單只顯示原因
        var actionError: String?     // 上次點擊動作的錯誤：保留上次的項目，只在標題加 ⚠︎

        var title: String {
            if let t = output?.title, !t.isEmpty { return t }
            return name
        }
        /// 讓選單只顯示原因、不顯示項目的錯誤
        var blocking: String? { problem ?? error }
        /// 選單與設定頁顯示的錯誤原因
        var failure: String? { problem ?? error ?? actionError }
    }

    enum PauseReason: Hashable { case sleep, screenSleep, locked, screenSaver }

    @Published private(set) var plugins: [Plugin] = []
    @Published private(set) var skipped: [String] = []      // 超過數量上限而略過的檔名
    @Published private(set) var folderMissing = false
    // 設定頁才需要的執行狀態，分開發布，選單不訂閱
    @Published private(set) var lastRuns: [String: Date] = [:]
    @Published private(set) var runningIDs: Set<String> = []

    let directory: URL
    let stateRoot: URL
    var timeout: TimeInterval = PluginLogic.timeout
    /// 通知發送端（App 內接到 DropNotifier；測試時換成記錄用的閉包）
    var notifier: (_ title: String, _ body: String, _ href: URL?) -> Void = { _, _, _ in }
    var now: () -> Date = Date.init

    /// 開關打開後才為 true；false 時不持有任何 timer、監看或事件訂閱
    private(set) var isActive = false
    private(set) var paused: Set<PauseReason> = []
    private var timers: [String: Timer] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var watchDebounce: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var notifyLog: PluginLogic.NotifyLog?
    /// 正在跑或排隊中的外掛（排程執行或點擊動作）。關閉開關不會清掉，
    /// 所以關閉後立刻重開也不會和還沒結束的那次重疊執行
    private var inFlight: Set<String> = []
    private var slotsInUse = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    init(directory: URL, stateRoot: URL) {
        self.directory = directory
        self.stateRoot = stateRoot
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// 量測／測試用：目前持有的資源
    var resources: (timers: Int, watching: Bool, observers: Int) { (timers.count, watcher != nil, observers.count) }
    func timerTolerance(_ id: String) -> TimeInterval? { timers[id]?.tolerance }

    // MARK: 啟動／停止

    /// App 啟動時呼叫；開關關閉時什麼都不做
    func start() {
        if Self.isEnabled { setEnabled(true) }
    }

    /// 設定頁切換開關時呼叫
    func setEnabled(_ on: Bool) {
        if on {
            if !isActive {
                isActive = true
                addObservers()
            }
            Task { await refreshAll() }
            return
        }
        guard isActive else { return }
        isActive = false
        paused = []
        removeObservers()
        stopWatcher()
        cancelTimers()
        setPlugins([])
        if !skipped.isEmpty { skipped = [] }
    }

    /// 開啟設定頁、喚醒時呼叫
    func refreshIfEnabled() {
        guard isActive else { return }
        Task { await refreshAll() }
    }

    /// 重新掃描、同步監看與排程，並立刻執行全部外掛（測試也直接呼叫這個）
    func refreshAll() async {
        scan()
        for p in plugins where p.actionError != nil { update(p.id) { $0.actionError = nil } }
        syncWatcher()
        syncTimers()
        await withTaskGroup(of: Void.self) { group in
            for p in plugins { group.addTask { await self.run(p.id) } }
        }
    }

    // MARK: 暫停／恢復（睡眠、螢幕關閉、鎖定、螢幕保護程式）

    func pause(_ reason: PauseReason) {
        guard isActive else { return }
        paused.insert(reason)
        cancelTimers()
    }

    /// 所有暫停原因都解除後，各跑一次再恢復排程
    func resume(_ reason: PauseReason) {
        guard isActive, paused.remove(reason) != nil, paused.isEmpty else { return }
        Task { await refreshAll() }
    }

    private func addObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        let table: [(NotificationCenter, Notification.Name, PauseReason, Bool)] = [
            (ws, NSWorkspace.willSleepNotification, .sleep, true),
            (ws, NSWorkspace.didWakeNotification, .sleep, false),
            (ws, NSWorkspace.screensDidSleepNotification, .screenSleep, true),
            (ws, NSWorkspace.screensDidWakeNotification, .screenSleep, false),
            (dist, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (dist, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
            (dist, Notification.Name("com.apple.screensaver.didstart"), .screenSaver, true),
            (dist, Notification.Name("com.apple.screensaver.didstop"), .screenSaver, false),
        ]
        for (center, name, reason, isPause) in table {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if isPause { self?.pause(reason) } else { self?.resume(reason) }
                }
            }
            observers.append((center, token))
        }
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    // MARK: 排程

    /// 每個外掛一個 repeating Timer；暫停中或關閉時一個都不留
    private func syncTimers() {
        guard isActive, paused.isEmpty else { cancelTimers(); return }
        let want = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0.interval) })
        for (id, t) in timers where want[id] != t.timeInterval {
            t.invalidate()
            timers[id] = nil
        }
        for (id, interval) in want where timers[id] == nil {
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire(id) }
            }
            t.tolerance = PluginLogic.timerTolerance(interval)
            RunLoop.main.add(t, forMode: .common)
            timers[id] = t
        }
    }

    private func fire(_ id: String) {
        Task { await run(id) }
    }

    private func cancelTimers() {
        for t in timers.values { t.invalidate() }
        timers = [:]
    }

    // MARK: 監看外掛資料夾

    private func syncWatcher() {
        guard isActive, !folderMissing else { stopWatcher(); return }
        guard watcher == nil else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            let flags = src.data
            MainActor.assumeIsolated { self?.folderChanged(flags) }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func stopWatcher() {
        watchDebounce?.cancel()
        watchDebounce = nil
        watcher?.cancel()
        watcher = nil
    }

    /// 資料夾內容變了：等 1 秒沒有新變動再重新掃描（複製檔案時會連續觸發），新出現的外掛立刻跑一次
    private func folderChanged(_ flags: DispatchSource.FileSystemEvent) {
        if flags.contains(.delete) || flags.contains(.rename) { stopWatcher() }   // 資料夾本身被移走
        watchDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.folderSettled() }
        }
        watchDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func folderSettled() {
        guard isActive else { return }
        let before = Set(plugins.map(\.id))
        scan()
        syncWatcher()
        syncTimers()
        for p in plugins where !before.contains(p.id) {
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
            guard let o = old[p.id] else { return p }
            var n = p
            n.output = o.output
            n.error = p.problem == nil ? o.error : nil
            n.actionError = o.actionError
            return n
        })
    }

    /// 執行目標（symlink 解析後）與它所在的資料夾、以及外掛資料夾本身，都要屬於目前使用者且不可被 group／other 寫入
    nonisolated static func permissionProblem(resolved: String, pluginDir: String?, uid: UInt32) -> String? {
        let parent = (resolved as NSString).deletingLastPathComponent
        if let pluginDir, let r = PluginLogic.permissionProblem(file: statOf(resolved), dir: statOf(pluginDir), uid: uid) {
            return r
        }
        return PluginLogic.permissionProblem(file: statOf(resolved), dir: statOf(parent), uid: uid)
    }

    nonisolated static func statOf(_ path: String) -> PluginLogic.FileStat? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return PluginLogic.FileStat(uid: st.st_uid, mode: UInt16(st.st_mode))
    }

    nonisolated static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    // MARK: 執行

    /// 背景執行一次的結果
    struct ExecResult: Sendable {
        var problem: String?            // 執行前重新檢查權限不通過（不會執行）
        var error: String?
        var output: PluginLogic.Output?
        var code: Int32 = 0
        var timedOut = false
    }

    func run(_ id: String) async {
        guard let p = plugins.first(where: { $0.id == id }), !inFlight.contains(id) else { return }
        setInFlight(id, true)
        await acquireSlot()
        let r = await Task.detached(priority: .utility) { [stateRoot, directory, timeout] in
            await Self.execute(path: p.path, name: p.name, pluginDir: directory.path, stateRoot: stateRoot.path,
                               args: [], timeout: timeout, parse: true)
        }.value
        releaseSlot()
        setInFlight(id, false)
        if r.problem == nil { lastRuns[id] = now() }
        update(id) { pl in
            pl.problem = r.problem
            guard r.problem == nil else { return }
            pl.error = r.error
            if r.error == nil { pl.output = r.output }
        }
        if r.problem == nil, r.error == nil, let out = r.output {
            sendNotifications(plugin: p.name, output: out)
        }
    }

    /// 在背景執行：重新檢查權限（掃描後可能被改過）→ 建立狀態資料夾 → 限時執行 → 解析輸出
    nonisolated static func execute(path: String, name: String, pluginDir: String, stateRoot: String,
                                    args: [String], timeout: TimeInterval, parse: Bool, exeOverride: String? = nil) async -> ExecResult {
        let exe: String
        if let exeOverride { exe = exeOverride } else {
            guard let resolved = realPath(path) else { return ExecResult(problem: "找不到檔案") }
            if let why = permissionProblem(resolved: resolved, pluginDir: pluginDir, uid: getuid()) {
                return ExecResult(problem: why)
            }
            exe = resolved
        }
        guard let state = prepareStateDir(root: stateRoot, name: name) else {
            return ExecResult(error: "無法建立外掛的狀態資料夾")
        }
        let r = await ProcessRunner.runLimited("/usr/bin/env", wrapperArgs(exe: exe, args: args, state: state),
                                               timeout: timeout, maxBytes: readLimit, qos: .utility)
        var out = ExecResult(code: r.code, timedOut: r.timedOut)
        if r.timedOut {
            out.error = "執行逾時（超過 \(Int(timeout)) 秒）"
        } else if r.code != 0 {
            let detail = lastLine(ofFile: state + "/.stderr")
            out.error = "結束碼 \(r.code)" + (detail.map { "：\($0)" } ?? "")
        } else if parse {
            out.output = PluginLogic.parseOutput(r.output)
        }
        return out
    }

    /// 經 /usr/bin/env -i 清空環境變數，再由 /bin/sh 以固定字串 exec 外掛（外掛路徑與參數都是獨立的 argv，不拼進 shell 字串）。
    /// stdout 是外掛輸出；stderr 寫到狀態資料夾的 .stderr，錯誤時顯示最後一行。
    nonisolated static func wrapperArgs(exe: String, args: [String], state: String) -> [String] {
        ["-i", "PATH=\(pluginPATH)", "HOME=\(home)", "SPLITSWAN_PLUGIN_STATE=\(state)", "SPLITSWAN=1",
         "/bin/sh", "-c", "exec \"$0\" \"$@\" 2>\"$SPLITSWAN_PLUGIN_STATE/.stderr\"", exe] + args
    }

    /// 建立 plugin-state/<名稱>（700），回傳路徑。只在真的要執行外掛時才建立
    nonisolated static func prepareStateDir(root: String, name: String) -> String? {
        let fm = FileManager.default
        let dir = root + "/" + name
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        } catch { return nil }
        return dir
    }

    nonisolated static func lastLine(ofFile path: String) -> String? {
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

    // MARK: 同時執行上限

    private func acquireSlot() async {
        if slotsInUse < PluginLogic.maxConcurrent { slotsInUse += 1; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in slotWaiters.append(c) }
        // 釋放者把名額直接交給排隊者，slotsInUse 不變
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty { slotsInUse -= 1 } else { slotWaiters.removeFirst().resume() }
    }

    private func setInFlight(_ id: String, _ on: Bool) {
        if on { inFlight.insert(id) } else { inFlight.remove(id) }
        let r = inFlight
        if r != runningIDs { runningIDs = r }
    }

    /// 只在內容真的變了才發布，選單不會無謂重建
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
        let all = output.items.flatMap { [$0] + $0.children }.filter { $0.notify && !$0.isSeparator }
        guard !all.isEmpty else { return }       // 沒有通知行就不讀寫紀錄檔
        let today = PluginLogic.dayString(now())
        var log = notifyLog ?? (try? JSONDecoder().decode(PluginLogic.NotifyLog.self, from: Data(contentsOf: notifyLogURL)))
            ?? PluginLogic.NotifyLog()
        var changed = false
        if log.day != today { log = PluginLogic.NotifyLog(day: today, keys: []); changed = true }
        for item in all {
            guard PluginLogic.shouldNotify(plugin: plugin, key: item.notifyKey, today: today, log: log) else { continue }
            notifier(output.title.isEmpty ? plugin : output.title, item.text, item.href)
            log = PluginLogic.recordNotify(plugin: plugin, key: item.notifyKey, today: today, log: log)
            changed = true
        }
        notifyLog = log
        if changed, let data = try? JSONEncoder().encode(log) {
            try? data.write(to: notifyLogURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notifyLogURL.path)
        }
    }

    // MARK: 點擊

    /// 選單項目被點擊：href 開網址；bash= 必須是外掛本身或外掛資料夾內的程式，且通過擁有者／權限檢查才執行；
    /// refresh=true 完成後重跑外掛。點擊動作與排程執行共用 inFlight 與同時執行上限，不會重疊；
    /// 失敗時保留上次的項目、標題加 ⚠︎
    func perform(pluginID: String, item: PluginLogic.Item) {
        if let url = item.href { NSWorkspace.shared.open(url) }
        guard let p = plugins.first(where: { $0.id == pluginID }) else { return }
        guard let bash = item.bash else {
            if item.refresh { Task { await run(pluginID) } }
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
            await acquireSlot()
            let r = await Task.detached(priority: .utility) { [stateRoot, directory, timeout] in
                await Self.execute(path: p.path, name: p.name, pluginDir: directory.path, stateRoot: stateRoot.path,
                                   args: item.bashArgs, timeout: timeout, parse: false, exeOverride: exe)
            }.value
            releaseSlot()
            setInFlight(pluginID, false)
            update(pluginID) { pl in
                pl.actionError = r.timedOut ? "點擊動作逾時" : (r.code != 0 ? "點擊動作結束碼 \(r.code)" : r.error)
            }
            if item.refresh { await run(pluginID) }
        }
    }

    // MARK: 設定頁

    /// 「開啟外掛資料夾」：不存在就建立（700）；開關打開時順便重新掃描並開始監看
    func openFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(directory)
        refreshIfEnabled()
    }
}
