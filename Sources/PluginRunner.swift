// 外掛的掃描、權限檢查、執行與排程。純邏輯在 PluginLogic.swift。
// 外掛以使用者身分執行（絕不經 sudo／helper），每次執行限時 10 秒，環境變數只給固定的幾個。
//
// 效能原則（外掛不可讓 App 變吃資源）：
// - 關閉時零開銷：沒有 timer、不掃描、不建立 plugin-state、不訂閱任何事件（isActive 為 false）。
// - 不輪詢資料夾：用 DispatchSource 監看外掛資料夾本身的 write／delete／rename（kernel 事件，閒置時零成本），
//   另外在開啟設定頁、手動重新整理、喚醒時重新掃描。
// - 每個外掛一個 repeating Timer，tolerance＝間隔 10%（至少 1 秒）讓系統合併喚醒。
// - 執行、權限檢查、輸出解析都在背景（QoS .utility），主執行緒只在結果真的變了才更新 @Published。
// - 睡眠時暫停全部排程；螢幕關閉、鎖定、螢幕保護程式期間只執行使用者允許的背景外掛。
// - 同時最多執行 2 個外掛，其餘排隊。
//
// 資安原則：外掛輸出是不受信任的資料。執行前完整檢查擁有者、寫入權限、ACL、隔離標記與上層資料夾；
// bash= 只能是外掛本身；通知標題固定「外掛：<名稱>」；文字過濾控制字元並限長；通知每次、每天都有上限。
import AppKit
import Darwin.membership
import Foundation
import os

@MainActor
final class PluginRunner: ObservableObject {
    static let shared = PluginRunner(directory: PluginRunner.defaultDirectory, stateRoot: PluginRunner.defaultStateRoot)

    static let enabledKey = "PluginsEnabled"          // 設定頁的啟用開關，預設關
    static let disabledPluginsKey = "DisabledPlugins" // 個別停用的外掛檔名
    static let backgroundPluginsKey = "BackgroundPlugins"
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
        var package: PluginPackageStore.Installed? = nil
        var name: String
        var interval: TimeInterval
        var path: String             // 外掛資料夾內的路徑
        var resolved: String?        // symlink 解析後的實際路徑（實際執行的就是它）
        var problem: String?         // 權限檢查不通過的原因（不會執行）
        var output: PluginLogic.Output?
        var error: String?           // 上次執行的錯誤（非 0 結束、逾時）：選單只顯示原因
        var actionError: String?     // 上次點擊動作的錯誤：保留上次的項目，只在標題加 ⚠︎
        var isEnabled: Bool = true   // 個別開關；停用時保留於設定頁，但不排程、不執行
        var runWhenLocked: Bool = false

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
    @Published private(set) var notifyCapped: Set<String> = []   // 今天通知已達上限的外掛

    let directory: URL
    let stateRoot: URL
    let packageStore: PluginPackageStore
    @Published private(set) var packageErrors: [String] = []
    private var updatingPackages: Set<String> = []
    private(set) var latestLegacyBackup: URL?
    var timeout: TimeInterval = PluginLogic.timeout
    var background = PluginBackground()
    /// 通知發送端（App 內接到 DropNotifier；測試時換成記錄用的閉包）。title 固定為「外掛：<名稱>」，subtitle 是外掛輸出的標題
    var notifier: (_ title: String, _ subtitle: String?, _ body: String, _ href: URL?) -> Void = { _, _, _, _ in }
    /// 網址開啟端（測試時可改為記錄用閉包）。
    var urlOpener: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    var now: () -> Date = Date.init

    /// 開關打開後才為 true；false 時不持有任何 timer、監看或事件訂閱
    @Published private(set) var isActive = false
    private(set) var paused: Set<PauseReason> = []
    private var timers: [String: Timer] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var watchDebounce: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var notifyLogs: [String: PluginLogic.NotifyLog] = [:]
    /// 手動操作與普通排程不能跨越鎖定；背景排程只有關閉或真正睡眠才失效。
    private var epoch = 0
    private var backgroundEpoch = 0
    private struct RefreshGeneration: Sendable {
        let foreground: Int
        let background: Int

        func epoch(for plugin: Plugin) -> Int { plugin.runWhenLocked ? background : foreground }
    }
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SplitSwan", category: "plugins")
    private let allowInactiveExecution: Bool
    private let preferences: UserDefaults
    private var pluginGenerations: [String: Int] = [:]
    private var idleWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// 要求執行時該外掛還在跑（例：關閉後立刻重開、暫停中途恢復，舊的那次結果會被丟棄），
    /// 等它結束後補跑一次，不重疊、不必等到下一個間隔
    private var rerunAfter: Set<String> = []
    /// 正在跑或排隊中的外掛（排程執行或點擊動作）。關閉開關不會清掉，
    /// 所以關閉後立刻重開也不會和還沒結束的那次重疊執行
    private var inFlight: Set<String> = []
    private var slotsInUse = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    init(directory: URL, stateRoot: URL, allowInactiveExecution: Bool = false,
         preferences: UserDefaults = .standard, packageRoot: URL? = nil, appVersion: String = AppInfo.version) {
        self.packageStore = PluginPackageStore(root: packageRoot ?? directory.deletingLastPathComponent().appendingPathComponent("plugin-packages"), appVersion: appVersion)
        self.directory = directory
        self.stateRoot = stateRoot
        self.allowInactiveExecution = allowInactiveExecution
        self.preferences = preferences
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// 量測／測試用：目前持有的資源
    var resources: (timers: Int, watching: Bool, observers: Int) { (timers.count, watcher != nil, observers.count) }
    var pendingIdleWaiterCount: Int { idleWaiters.values.reduce(0) { $0 + $1.count } }
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
                logLifecycle("start")
            }
            requestRefresh()
            return
        }
        guard isActive else { return }
        isActive = false
        epoch += 1
        backgroundEpoch += 1
        rerunAfter = []
        paused = []
        removeObservers()
        stopWatcher()
        cancelTimers()
        setPlugins([])
        if !skipped.isEmpty { skipped = [] }
        logLifecycle("stop")
    }

    /// 開啟設定頁、喚醒時呼叫
    func refreshIfEnabled() {
        requestRefresh()
    }

    /// 掃描可跨越軟暫停；普通外掛仍不能沿用鎖定前的執行請求。
    func requestRefresh() {
        guard isActive, canRefresh else { logLifecycle("refresh.blocked"); return }
        let generation = RefreshGeneration(foreground: epoch, background: backgroundEpoch)
        Task { await refreshAll(generation: generation) }
    }

    /// 重新掃描、同步監看與排程，並立刻執行全部外掛（測試也直接呼叫這個）
    func refreshAll() async {
        let generation = RefreshGeneration(foreground: epoch, background: backgroundEpoch)
        guard canRefresh else { logLifecycle("refresh.blocked"); return }
        await refreshAll(generation: generation)
    }

    private func refreshAll(generation: RefreshGeneration) async {
        guard canRefresh else { logLifecycle("refresh.blocked"); return }
        guard generation.background == backgroundEpoch else { logLifecycle("refresh.stale"); return }
        scan()
        for p in plugins where p.actionError != nil { update(p.id) { $0.actionError = nil } }
        syncWatcher()
        syncTimers()
        logLifecycle("refresh.applied")
        await withTaskGroup(of: Void.self) { group in
            for p in plugins { group.addTask { await self.run(p.id, refresh: generation) } }
        }
    }

    // MARK: 暫停／恢復（睡眠、螢幕關閉、鎖定、螢幕保護程式）

    func pause(_ reason: PauseReason) {
        guard isActive else { return }
        paused.insert(reason)
        epoch += 1
        if reason == .sleep { backgroundEpoch += 1 }
        syncTimers()
        logLifecycle("pause")
    }

    /// 喚醒時即使仍鎖定，也恢復已授權的背景排程。
    func resume(_ reason: PauseReason) {
        guard isActive, paused.remove(reason) != nil else { return }
        logLifecycle("resume")
        requestRefresh()
    }

    private func logLifecycle(_ event: String) {
        let reasons = paused.map { String(describing: $0) }.sorted().joined(separator: ",")
        Self.logger.notice("""
            event=\(event, privacy: .public) paused=\(reasons, privacy: .public) \
            active=\(self.isActive, privacy: .public) loaded=\(self.plugins.count, privacy: .public) \
            timers=\(self.timers.count, privacy: .public)
            """)
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

    private func syncTimers() {
        guard isActive else { cancelTimers(); return }
        let want = Dictionary(uniqueKeysWithValues: plugins.filter { canSchedule($0.id) && $0.problem == nil }.map { ($0.id, $0.interval) })
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

    /// 列出外掛資料夾內「可執行的一般檔案」，依檔名排序、最多 10 個，並做完整的權限檢查
    func scan() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        folderMissing = !fm.fileExists(atPath: directory.path)
        let uid = getuid()
        var found: [Plugin] = []
        for file in names.sorted() {
            guard let fn = PluginLogic.parseFileName(file) else { continue }   // 隱藏檔、含控制字元的檔名
            let path = directory.appendingPathComponent(file).path
            guard let resolved = Self.realPath(path), let st = Self.statOf(resolved),
                  st.isRegular, access(resolved, X_OK) == 0 else { continue }  // 子目錄、不可執行檔略過
            let check = Self.fullCheck(path: path, pluginDir: directory.path, uid: uid)
            found.append(Plugin(id: file, name: fn.name, interval: fn.interval, path: path,
                                resolved: check.resolved ?? resolved, problem: check.problem,
                                isEnabled: !disabledPluginIDs.contains(file), runWhenLocked: backgroundPluginIDs.contains(file)))
        }
        let discovered = packageStore.discover()
        packageErrors = discovered.errors
        for package in discovered.installed {
            var problem: String?
            do { try package.availability() } catch { problem = error.localizedDescription }
            let m = package.record.manifest
            found.append(Plugin(id: package.id, package: package, name: m.name, interval: TimeInterval(m.interval),
                                path: package.entrypoint, resolved: package.entrypoint, problem: problem,
                                isEnabled: package.record.enabled, runWhenLocked: backgroundPluginIDs.contains(package.id)))
        }
        let newSkipped = found.dropFirst(PluginLogic.maxPlugins).map(\.id)
        if newSkipped != skipped { skipped = newSkipped }
        found = Array(found.prefix(PluginLogic.maxPlugins))
        // 保留上次的執行結果
        let old = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        setPlugins(found.map { p in
            guard let o = old[p.id], o.package?.record.digest == p.package?.record.digest else { return p }
            var n = p
            n.output = o.output
            n.error = p.problem == nil ? o.error : nil
            n.actionError = o.actionError
            n.isEnabled = p.isEnabled
            return n
        })
    }

    /// 執行前的完整檢查（掃描、每次執行、點擊動作取得名額之後都會再做一次）：
    /// 1. symlink 解析後的實際檔案必須在外掛資料夾第一層（擋住指向 python3 等外部程式的 symlink）
    /// 2. 檔案與外掛資料夾屬於目前使用者、不可被 group／other 寫入、檔案可執行
    /// 3. 檔案與外掛資料夾沒有允許其他人寫入的 ACL
    /// 4. 檔案沒有 com.apple.quarantine（下載來的腳本）
    /// 5. 外掛資料夾以上每一層直到 /：屬於自己或 root、不可被他人寫入（sticky 例外）、沒有允許他人寫入的 ACL
    nonisolated static func fullCheck(path: String, pluginDir: String, uid: uid_t) -> (resolved: String?, problem: String?) {
        guard let resolved = realPath(path) else { return (nil, "找不到檔案") }
        guard let dir = realPath(pluginDir) else { return (resolved, "找不到外掛資料夾") }
        if (resolved as NSString).deletingLastPathComponent != dir {
            return (resolved, "實際檔案不在外掛資料夾內（symlink 指到外面）")
        }
        if let why = PluginLogic.permissionProblem(file: statOf(resolved), dir: statOf(dir), uid: uid) { return (resolved, why) }
        if let why = aclProblem(resolved, uid: uid) ?? aclProblem(dir, uid: uid) { return (resolved, why) }
        if hasQuarantine(resolved) {
            return (resolved, "檔案帶有下載隔離標記（com.apple.quarantine），確認內容後可自行用 xattr 移除")
        }
        var d = (dir as NSString).deletingLastPathComponent
        while true {
            if let why = PluginLogic.ancestorProblem(statOf(d), path: d, uid: uid) ?? aclProblem(d, uid: uid) {
                return (resolved, why)
            }
            if d == "/" || d.isEmpty { break }
            d = (d as NSString).deletingLastPathComponent
        }
        return (resolved, nil)
    }

    /// ACL 中只要有一條 allow 把寫入類權限（寫入／附加／新增檔案或子資料夾／刪除／改屬性／改權限／改擁有者）
    /// 給目前使用者以外的人，就回傳原因。deny 規則與給自己的規則不影響
    nonisolated static func aclProblem(_ path: String, uid: uid_t) -> String? {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return nil }   // 沒有 ACL
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writePerms: [acl_perm_t] = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES,
                                        ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        var entry: acl_entry_t?
        var which = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, which, &entry) == 0, let e = entry {
            which = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(e, &tag) == 0, tag == ACL_EXTENDED_ALLOW else { continue }
            var isSelf = false
            if let q = acl_get_qualifier(e) {
                var ident = id_t(0)
                var idType = Int32(0)
                if mbr_uuid_to_id(q.assumingMemoryBound(to: UInt8.self), &ident, &idType) == 0 {
                    isSelf = idType == ID_TYPE_UID && ident == uid
                }
                acl_free(q)
            }
            if isSelf { continue }
            var perms: acl_permset_t?
            guard acl_get_permset(e, &perms) == 0, let perms else { continue }
            if writePerms.contains(where: { acl_get_perm_np(perms, $0) == 1 }) {
                return "\(path) 有 ACL 允許其他使用者寫入（請執行 chmod -N 移除 ACL）"
            }
        }
        return nil
    }

    nonisolated static func hasQuarantine(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
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

    /// stderr 最多保留的 bytes（只用來顯示錯誤原因）
    nonisolated static let stderrLimit = 4096

    func run(_ id: String) async {
        await run(id, refresh: nil)
    }

    private func run(_ id: String, refresh: RefreshGeneration?) async {
        guard canSchedule(id), let p = plugins.first(where: { $0.id == id }) else { return }
        if let refresh, refresh.epoch(for: p) != scheduledEpoch(id) { return }
        if inFlight.contains(id) { rerunAfter.insert(id); return }
        let myEpoch = scheduledEpoch(id)
        let myGeneration = pluginGenerations[id, default: 0]
        setInFlight(id, true)
        await acquireSlot()
        // 排隊期間被關閉或暫停：不開始
        guard myEpoch == scheduledEpoch(id), myGeneration == pluginGenerations[id, default: 0], canSchedule(id) else {
            releaseSlot()
            setInFlight(id, false)
            return
        }
        let r = await Task.detached(priority: .utility) { [stateRoot, directory, timeout] in
            await Self.execute(path: p.path, id: p.id, pluginDir: directory.path, stateRoot: stateRoot.path,
                               args: [], timeout: timeout, parse: true, package: p.package)
        }.value
        releaseSlot()
        setInFlight(id, false)
        // 執行資格或世代失效後，不更新選單、不發通知、不寫紀錄。
        guard myEpoch == scheduledEpoch(id), myGeneration == pluginGenerations[id, default: 0], canSchedule(id) else { return }
        if r.problem == nil { lastRuns[id] = now() }
        update(id) { pl in
            pl.problem = r.problem
            guard r.problem == nil else { return }
            pl.error = r.error
            if r.error == nil { pl.output = r.output }
        }
        if r.problem == nil, r.error == nil, let out = r.output {
            await sendNotifications(plugin: p, output: out, epoch: myEpoch, generation: myGeneration)
        }
    }

    /// 在背景執行：完整檢查（掃描後可能被改過）→ 建立狀態資料夾 → 限時執行 → 解析輸出。
    /// 直接執行外掛檔案本身（不經 shell），環境變數整組換掉，stderr 另外收集且有上限
    nonisolated static func execute(path: String, id: String, pluginDir: String, stateRoot: String,
                                    args: [String], timeout: TimeInterval, parse: Bool, package: PluginPackageStore.Installed? = nil) async -> ExecResult {
        let check = executionCheck(path: path, pluginDir: pluginDir, package: package)
        if let why = check.problem { return ExecResult(problem: why) }
        guard let exe = check.resolved else { return ExecResult(problem: "找不到檔案") }
        guard let state = executionState(root: stateRoot, id: id, package: package) else {
            return ExecResult(error: "無法建立外掛的狀態資料夾")
        }
        var env = ["PATH": pluginPATH, "HOME": home, "SPLITSWAN_PLUGIN_STATE": state, "SPLITSWAN": "1",
                   "SPLITSWAN_PLUGIN_SETTINGS_PROTOCOL": "1", "SPLITSWAN_APP_PID": String(getpid())]
        env.merge(package?.environment ?? [:]) { _, new in new }
        let r = await ProcessRunner.execute(exe, args, env: env, timeout: timeout, maxBytes: readLimit,
                                            qos: .utility, stderrLimit: stderrLimit)
        var out = ExecResult(code: r.code, timedOut: r.timedOut)
        if let err = r.launchError {
            out.error = "無法執行：\(PluginLogic.clip(PluginLogic.sanitize(err)))"
        } else if r.timedOut {
            out.error = "執行逾時（超過 \(Int(timeout)) 秒）"
        } else if r.code != 0 {
            let detail = lastLine(r.errorOutput)
            out.error = "結束碼 \(r.code)" + (detail.map { "：\($0)" } ?? "")
        } else if parse {
            out.output = PluginLogic.parseOutput(r.output)
        }
        return out
    }

    nonisolated static func executionState(root: String, id: String, package: PluginPackageStore.Installed?) -> String? {
        guard let package else { return prepareStateDir(root: root, name: id) }
        let url = URL(fileURLWithPath: root).appendingPathComponent("packages/" + package.record.manifest.id)
        do { try PluginPackageStore.createSecureDirectory(url); return url.path } catch { return nil }
    }

    /// 建立 plugin-state/<完整檔名>（700），回傳路徑。只在真的要執行外掛時才建立
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

    /// stderr 的最後一個非空行（過濾控制字元、限長）
    nonisolated static func lastLine(_ text: String) -> String? {
        let line = text.split(separator: "\n").last.map { PluginLogic.sanitize(String($0)).trimmingCharacters(in: .whitespaces) }
        guard let line, !line.isEmpty else { return nil }
        return PluginLogic.clip(line)
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
        if !on, var waiters = idleWaiters[id], !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                idleWaiters[id] = nil
            } else {
                idleWaiters[id] = waiters
            }
            next.resume()
        }
        if !on, rerunAfter.remove(id) != nil, canSchedule(id) {
            Task { await run(id) }
        }
    }

    /// 等到該外掛沒有在跑（不輪詢）
    private func waitUntilIdle(_ id: String) async {
        while inFlight.contains(id) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in idleWaiters[id, default: []].append(c) }
        }
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

    /// 每個外掛一份去重紀錄：plugin-state/.notified/<完整檔名>.json（600）
    nonisolated static func notifyLogURL(root: String, id: String) -> URL {
        URL(fileURLWithPath: root + "/.notified/" + id + ".json")
    }

    nonisolated static func loadNotifyLog(_ url: URL) -> PluginLogic.NotifyLog? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size <= 16 * 1024,             // 異常大的紀錄檔不讀
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PluginLogic.NotifyLog.self, from: data)
    }

    nonisolated static func saveNotifyLog(_ log: PluginLogic.NotifyLog, to url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().path
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 通知標題固定為「外掛：<檔名中的名稱>」，外掛輸出的標題只放副標題，避免冒充 SplitSwan 自己的通知。
    /// 讀寫紀錄檔在背景；關閉或暫停後不發、不寫
    private func sendNotifications(plugin p: Plugin, output: PluginLogic.Output, epoch myEpoch: Int, generation: Int) async {
        let items = output.items.flatMap { [$0] + $0.children }.filter { $0.notify && !$0.isSeparator }
        guard !items.isEmpty else { return }
        let url = Self.notifyLogURL(root: stateRoot.path, id: p.id)
        var log = notifyLogs[p.id]
        if log == nil {
            log = await Task.detached(priority: .utility) { Self.loadNotifyLog(url) }.value ?? PluginLogic.NotifyLog()
        }
        guard myEpoch == scheduledEpoch(p.id), generation == pluginGenerations[p.id, default: 0], canSchedule(p.id) else { return }
        let plan = PluginLogic.planNotifications(items, today: PluginLogic.dayString(now()), log: log ?? PluginLogic.NotifyLog())
        let wasCapped = notifyCapped.contains(p.id)
        if plan.capped != wasCapped {
            if plan.capped { notifyCapped.insert(p.id) } else { notifyCapped.remove(p.id) }
        }
        guard plan.log != log else { return }
        notifyLogs[p.id] = plan.log
        let title = "外掛：" + p.name
        let subtitle = output.title.isEmpty || output.title == p.name ? nil : output.title
        for item in plan.send { notifier(title, subtitle, item.text, item.href) }
        let toSave = plan.log
        Task.detached(priority: .utility) { Self.saveNotifyLog(toSave, to: url) }
    }

    /// 正式路徑必須已啟用；只有建構時明確開啟的測試 runner 可在 inactive 狀態直接執行。
    private var isActiveOrDirect: Bool { isActive || allowInactiveExecution }

    private func canSchedule(_ id: String) -> Bool {
        guard isActiveOrDirect, !updatingPackages.contains(id), !paused.contains(.sleep),
              let plugin = plugins.first(where: { $0.id == id }), plugin.isEnabled else { return false }
        return paused.isEmpty || plugin.runWhenLocked
    }

    private func scheduledEpoch(_ id: String) -> Int {
        plugins.first(where: { $0.id == id })?.runWhenLocked == true ? backgroundEpoch : epoch
    }

    private var canRefresh: Bool {
        isActiveOrDirect && !paused.contains(.sleep) && (paused.isEmpty || !backgroundPluginIDs.isEmpty)
    }

    // MARK: 點擊

    /// 明確開啟設定才允許執行管理命令；不受顯示開關影響，也不啟用一般排程。
    /// 與排程／點擊共用互斥鎖，取得執行名額後再次驗證檔案。
    func settingsCommand(pluginID: String, operation: String, request: PluginSettingsProtocol.Request? = nil) async throws -> PluginSettingsProtocol.Snapshot {
        let generation = pluginGenerations[pluginID, default: 0]
        guard !updatingPackages.contains(pluginID), ["snapshot", "save", "action"].contains(operation),
              let p = plugins.first(where: { $0.id == pluginID }), paused.isEmpty else {
            throw PluginSettingsProtocol.Problem(message: "外掛已移除或目前無法執行設定命令")
        }
        let input = try request.map { try JSONEncoder().encode($0) }
        guard (input?.count ?? 0) <= PluginSettingsProtocol.maxBytes else {
            throw PluginSettingsProtocol.Problem(message: "設定內容過大")
        }
        await waitUntilIdle(pluginID)
        setInFlight(pluginID, true)
        await acquireSlot()
        defer { releaseSlot(); setInFlight(pluginID, false) }
        guard !Task.isCancelled, paused.isEmpty, !updatingPackages.contains(pluginID),
              generation == pluginGenerations[pluginID, default: 0],
              plugins.contains(where: { $0.id == p.id && $0.resolved == p.resolved }) else {
            throw PluginSettingsProtocol.Problem(message: "外掛狀態已變更，請重新開啟設定")
        }
        let result = try await Task.detached(priority: .utility) { [directory, stateRoot, timeout] in
            let check = Self.executionCheck(path: p.path, pluginDir: directory.path, package: p.package)
            if let why = check.problem { throw PluginSettingsProtocol.Problem(message: why) }
            guard let exe = check.resolved, exe == p.resolved,
                  let state = Self.executionState(root: stateRoot.path, id: p.id, package: p.package) else {
                throw PluginSettingsProtocol.Problem(message: "無法準備外掛設定")
            }
            var environment = ["PATH": Self.pluginPATH, "HOME": Self.home, "SPLITSWAN": "1",
                      "SPLITSWAN_PLUGIN_STATE": state, "SPLITSWAN_PLUGIN_SETTINGS_PROTOCOL": "1", "SPLITSWAN_APP_PID": String(getpid())]
            environment.merge(p.package?.environment ?? [:]) { _, new in new }
            return await ProcessRunner.execute(exe, ["--splitswan-settings", operation], env: environment,
                timeout: timeout, maxBytes: PluginSettingsProtocol.maxBytes + 1, qos: .utility,
                stderrLimit: Self.stderrLimit, input: input)
        }.value
        guard !result.timedOut else { throw PluginSettingsProtocol.Problem(message: "外掛設定命令逾時") }
        guard result.launchError == nil, result.code == 0 else {
            throw PluginSettingsProtocol.Problem(message: "外掛設定命令失敗（結束碼 \(result.code)）")
        }
        guard !Task.isCancelled else { throw CancellationError() }
        guard generation == pluginGenerations[pluginID, default: 0], !updatingPackages.contains(pluginID) else {
            throw PluginSettingsProtocol.Problem(message: "外掛狀態已變更，已捨棄舊設定結果")
        }
        return try PluginSettingsProtocol.decode(Data(result.output.utf8))
    }

    /// 選單項目被點擊：href 開網址；bash= 只能是外掛本身（解析後的實際路徑）；
    /// 取得執行名額之後、執行之前再做一次完整檢查；refresh=true 完成後重跑外掛。
    /// 點擊動作與排程執行共用 inFlight 與同時執行上限，不會重疊；失敗時保留上次的項目、標題加 ⚠︎
    func perform(pluginID: String, item: PluginLogic.Item) {
        guard isActiveOrDirect, paused.isEmpty,
              !updatingPackages.contains(pluginID), let p = plugins.first(where: { $0.id == pluginID }), p.isEnabled else { return }
        if let url = item.href { urlOpener(url) }
        guard let bash = item.bash else {
            if item.refresh { Task { await run(pluginID) } }
            return
        }
        guard let exe = Self.realPath(bash) else {
            update(pluginID) { $0.actionError = "點擊動作被拒：找不到 \(PluginLogic.clip(bash))" }
            return
        }
        if let why = PluginLogic.bashTargetProblem(resolved: exe, pluginSelf: p.resolved) {
            update(pluginID) { $0.actionError = "點擊動作被拒：\(why)" }
            return
        }
        let myEpoch = epoch
        let myGeneration = pluginGenerations[pluginID, default: 0]
        Task {
            await waitUntilIdle(pluginID)        // 外掛正在跑（排程或上一個點擊）就等它結束
            setInFlight(pluginID, true)
            await acquireSlot()
            guard myEpoch == epoch, myGeneration == pluginGenerations[pluginID, default: 0],
                  isPluginEnabled(pluginID), isActiveOrDirect, paused.isEmpty else {
                releaseSlot()
                setInFlight(pluginID, false)
                return
            }
            // execute 會在取得名額之後重新做完整檢查，並確認仍是外掛本身
            let r = await Task.detached(priority: .utility) { [stateRoot, directory, timeout] in
                await Self.execute(path: p.path, id: p.id, pluginDir: directory.path, stateRoot: stateRoot.path,
                                   args: item.bashArgs, timeout: timeout, parse: false, package: p.package)
            }.value
            releaseSlot()
            setInFlight(pluginID, false)
            guard myEpoch == epoch, myGeneration == pluginGenerations[pluginID, default: 0],
                  isPluginEnabled(pluginID), isActiveOrDirect, paused.isEmpty else { return }
            update(pluginID) { pl in
                if let why = r.problem { pl.actionError = "點擊動作被拒：\(why)"; return }
                pl.actionError = r.timedOut ? "點擊動作逾時" : (r.code != 0 ? "點擊動作結束碼 \(r.code)" : r.error)
            }
            if item.refresh { await run(pluginID) }
        }
    }

    // MARK: 設定頁

    private var disabledPluginIDs: Set<String> {
        Set(preferences.stringArray(forKey: Self.disabledPluginsKey) ?? [])
    }

    private var backgroundPluginIDs: Set<String> {
        Set(preferences.stringArray(forKey: Self.backgroundPluginsKey) ?? [])
    }

    private func isPluginEnabled(_ id: String) -> Bool {
        !updatingPackages.contains(id) && plugins.first(where: { $0.id == id })?.isEnabled == true
    }

    func setRunWhenLocked(_ id: String, _ on: Bool) {
        guard !updatingPackages.contains(id), let plugin = plugins.first(where: { $0.id == id }), plugin.runWhenLocked != on else { return }
        var background = backgroundPluginIDs
        if on { background.insert(id) } else { background.remove(id) }
        preferences.set(background.sorted(), forKey: Self.backgroundPluginsKey)
        pluginGenerations[id, default: 0] += 1
        rerunAfter.remove(id)
        update(id) { $0.runWhenLocked = on }
        syncTimers()
        if isActive, canSchedule(id) { Task { await run(id) } }
    }

    /// 個別外掛開關：停用後立刻停止新排程；進行中的結果會丟棄，不再更新選單或發通知。
    func setPluginEnabled(_ id: String, _ on: Bool) {
        guard !updatingPackages.contains(id), let plugin = plugins.first(where: { $0.id == id }), plugin.isEnabled != on else { return }
        if let package = plugin.package {
            do { try packageStore.setEnabled(package.record.manifest.id, on) }
            catch { update(id) { $0.problem = error.localizedDescription }; return }
        }
        var disabled = disabledPluginIDs
        if on { disabled.remove(id) } else { disabled.insert(id) }
        preferences.set(disabled.sorted(), forKey: Self.disabledPluginsKey)
        pluginGenerations[id, default: 0] += 1
        rerunAfter.remove(id)
        if !on {
            timers[id]?.invalidate()
            timers[id] = nil
        }
        update(id) { $0.isEnabled = on }
        syncTimers()
        if on, isActive, canSchedule(id) { Task { await run(id) } }
    }

    nonisolated static func executionCheck(path: String, pluginDir: String, package: PluginPackageStore.Installed?) -> (resolved: String?, problem: String?) {
        guard let package else { return fullCheck(path: path, pluginDir: pluginDir, uid: getuid()) }
        do {
            guard path == package.entrypoint else { throw PluginPackage.fail("套件執行入口不一致") }
            try package.check()
            return (path, nil)
        } catch { return (nil, error.localizedDescription) }
    }

    /// 更新與所有設定／選單／排程共用同一支外掛的互斥，不影響其他外掛或 VPN。
    func legacyReplacement(for prepared: PluginPackage.Prepared) throws -> PluginLegacyReplacement.Match? {
        let file = prepared.manifest.legacyReplacement?.fileName ?? ""
        return try PluginLegacyReplacement.inspect(prepared.manifest, directory: directory, enabled: !disabledPluginIDs.contains(file))
    }

    func installPackage(_ prepared: PluginPackage.Prepared, replacing legacy: PluginLegacyReplacement.Match? = nil) async throws {
        let id = "package:" + prepared.manifest.id
        let ids: Set<String> = Set([id] + (legacy.map { [$0.fileName] } ?? []))
        guard ids.isDisjoint(with: updatingPackages) else { throw PluginPackage.fail("此外掛正在更新或移除") }
        updatingPackages.formUnion(ids)
        for key in ids {
            pluginGenerations[key, default: 0] += 1
            rerunAfter.remove(key)
            timers[key]?.invalidate(); timers[key] = nil
        }
        defer { updatingPackages.subtract(ids); scan(); syncTimers() }
        for key in ids { await waitUntilIdle(key) }
        try Task.checkCancellation()
        latestLegacyBackup = try await Task.detached(priority: .utility) { [packageStore, directory, stateRoot] () -> URL? in
            if let legacy {
                return try PluginLegacyReplacement.commit(prepared, match: legacy, store: packageStore, directory: directory, stateRoot: stateRoot)
            }
            try packageStore.install(prepared, confirmed: true)
            return nil
        }.value
        if let legacy {
            var disabled = disabledPluginIDs
            if legacy.enabled { disabled.remove(id) } else { disabled.insert(id) }
            preferences.set(disabled.sorted(), forKey: Self.disabledPluginsKey)
            lastRuns.removeValue(forKey: legacy.fileName)
            notifyCapped.remove(legacy.fileName)
            notifyLogs.removeValue(forKey: legacy.fileName)
        }
    }

    func backgroundContext(_ plugin: Plugin) -> PluginBackground.Context {
        let packageID = plugin.package?.record.manifest.id
        return PluginBackground.Context(entrypoint: plugin.path,
            codeRoot: packageID.map { packageStore.root.appendingPathComponent($0).path },
            state: packageID.map { stateRoot.appendingPathComponent("packages/" + $0).path } ?? stateRoot.appendingPathComponent(plugin.id).path)
    }
    func inspectBackground(_ plugin: Plugin) async throws -> PluginBackground.Report {
        let monitor = background, context = backgroundContext(plugin)
        return try await Task.detached(priority: .utility) { try monitor.inspect(context) }.value
    }

    /// 先停止新工作，再清理已確認歸屬的程序／登入服務；不執行外掛移除鉤子。
    @discardableResult
    func removePlugin(_ plugin: Plugin, trash: @escaping PluginPackageStore.TrashOperation = PluginPackageStore.moveToTrash,
                      progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> PluginBackground.Result {
        let id = plugin.id
        guard !updatingPackages.contains(id), plugins.contains(where: { $0.id == id && $0.path == plugin.path }) else {
            throw PluginPackage.fail("此外掛正在變更或已移除，請重新整理後再試")
        }
        updatingPackages.insert(id)
        pluginGenerations[id, default: 0] += 1
        rerunAfter.remove(id)
        timers[id]?.invalidate(); timers[id] = nil
        var removed = false
        defer {
            if !removed {
                var disabled = disabledPluginIDs; disabled.insert(id)
                preferences.set(disabled.sorted(), forKey: Self.disabledPluginsKey)
                if let package = plugin.package { try? packageStore.setEnabled(package.record.manifest.id, false) }
            }
            updatingPackages.remove(id); scan(); syncTimers()
        }
        // 套件的背景子程序也會讀此開關；在任何 await 前落盤，阻止正在登入的工作繼續點擊。
        var disabledAtStart = disabledPluginIDs; disabledAtStart.insert(id)
        preferences.set(disabledAtStart.sorted(), forKey: Self.disabledPluginsKey)
        if let package = plugin.package { try packageStore.setEnabled(package.record.manifest.id, false) }
        let monitor = background, context = backgroundContext(plugin)
        var result = try await Task.detached(priority: .utility) { try await monitor.stop(context, trash: trash, progress: progress) }.value
        await progress("正在等候 App 工作收尾並移到垃圾桶…")
        await waitUntilIdle(id)
        try Task.checkCancellation()
        // 排隊／驗證中的工作可能在第一次掃描後才建立程序，收尾後再次清理才移走程式。
        let final = try await Task.detached(priority: .utility) { try await monitor.stop(context, trash: trash, progress: progress) }.value
        result.processes += final.processes; result.services += final.services
        try await Task.detached(priority: .utility) { [packageStore, directory] in
            if let package = plugin.package {
                try packageStore.remove(package, trash: trash)
            } else {
                guard PluginLogic.parseFileName(id) != nil,
                      directory.appendingPathComponent(id).path == plugin.path else { throw PluginPackage.fail("單檔外掛路徑不一致") }
                try PluginPackageStore.securePath(directory.path, regular: false)
                var info = stat()
                guard lstat(plugin.path, &info) == 0, info.st_uid == getuid(),
                      [S_IFREG, S_IFLNK].contains(info.st_mode & S_IFMT) else { throw PluginPackage.fail("找不到可移除的單檔外掛") }
                // 移動選到的檔案或連結本身，絕不解析連結後刪除其他位置的目標。
                try trash(URL(fileURLWithPath: plugin.path))
            }
        }.value
        var disabled = disabledPluginIDs
        disabled.insert(id) // 從垃圾桶放回舊腳本時也先保持停用。
        preferences.set(disabled.sorted(), forKey: Self.disabledPluginsKey)
        var background = backgroundPluginIDs
        background.remove(id)
        preferences.set(background.sorted(), forKey: Self.backgroundPluginsKey)
        lastRuns.removeValue(forKey: id)
        notifyCapped.remove(id)
        notifyLogs.removeValue(forKey: id)
        removed = true
        return result
    }

    /// 「開啟外掛資料夾」：不存在就建立（700）；開關打開時順便重新掃描並開始監看
    func openFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(directory)
        refreshIfEnabled()
    }
}
