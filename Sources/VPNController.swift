// 連線控制：透過 `sudo -n /usr/local/libexec/splitswan-helper` 操作 strongSwan，
// 狀態列選單與主視窗共用同一個實例。
//
// F1 自動重連（docs/SPEC-1.3.md §3）：
//   - 使用者按過「連線」後（wantConnected），睡眠喚醒、換網路、通道失聯都會自動重連
//   - 所有連線動作都經過同一個協調器，同一時間只執行一個
//   - 只有使用者按「斷線」才會清除連線意圖
import AppKit
import Combine
import Network

let helperPath = "/usr/local/libexec/splitswan-helper"

enum VPNState: Equatable {
    case disconnected
    case connecting(String)
    case connected(String, String)   // 連線名稱、虛擬 IP
    case helperMissing

    var isConnected: Bool { if case .connected = self { return true }; return false }
    var isConnecting: Bool { if case .connecting = self { return true }; return false }
}

/// 輔助程式 `status` 的解析結果。新版多了本機 IP 與已建立秒數，舊版只有前三欄
struct HelperStatus: Equatable {
    var state: VPNState
    var localIP: String?          // SA 的本機位址（@ 後面），舊版輔助程式沒有
    var establishedSeconds: Int?  // SA 已建立秒數，舊版輔助程式沒有
    var extended: Bool { localIP != nil }

    static func parse(_ line: String) -> HelperStatus {
        let p = line.split(separator: " ").map(String.init)
        switch p.first {
        case "connected" where p.count >= 3:
            let lip = p.count >= 4 && p[3] != "-" ? p[3] : nil
            let est = p.count >= 5 ? Int(p[4]) : nil
            return HelperStatus(state: .connected(p[1], p[2]), localIP: lip, establishedSeconds: est)
        case "connecting" where p.count >= 2:
            return HelperStatus(state: .connecting(p[1]), localIP: nil, establishedSeconds: nil)
        case "disconnected":
            return HelperStatus(state: .disconnected, localIP: nil, establishedSeconds: nil)
        default:
            return HelperStatus(state: .helperMissing, localIP: nil, establishedSeconds: nil)
        }
    }
}

/// 自動重連用到的純邏輯，不碰系統狀態，方便單獨測試
enum ReconnectPolicy {
    /// 一整輪都失敗後，第 n 次（從 0 起）重試前要等的秒數：5、15、30、60，之後固定 60
    static func backoff(_ n: Int) -> TimeInterval {
        let steps: [TimeInterval] = [5, 15, 30, 60]
        return steps[min(max(n, 0), steps.count - 1)]
    }

    // 自動輪替的嘗試順序在 GatewayHistory.order（F4）

    /// 是不是 VPN 自己的介面（連線、斷線時會增減，不能當成「換網路」）
    static func isTunnelInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }
}

/// F2 非預期斷線通知的判定（docs/SPEC-1.3.md §4），純邏輯，不碰系統狀態，方便單獨測試。
/// 每次狀態更新餵一次，回傳這次要不要發通知
struct DropDetector {
    enum Action: Equatable { case none, notifyDrop, notifyRestore }

    /// 想連線但沒連上持續多久才算掉線
    static let grace: TimeInterval = 30
    /// 設定頁「VPN 中斷時通知」的 UserDefaults key，預設開啟
    static let enabledKey = "NotifyOnDrop"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private(set) var downSince: Date?        // 第一次觀察到「想連線但沒連上」的時間
    private(set) var dropNotified = false    // 這次掉線已發過通知

    /// 通知關閉時直接不發，並重置狀態：重新開啟後從頭計時，也不會補發恢復通知。
    /// paused：沒有網路、或讀不到輔助程式狀態（helperMissing）時，這段時間不算掉線，
    /// 恢復後重新計時；已發過的掉線通知保留，之後接回仍會發恢復通知
    mutating func update(now: Date, wantConnected: Bool, isConnected: Bool, enabled: Bool,
                         paused: Bool = false) -> Action {
        guard wantConnected, enabled else { reset(); return .none }
        if isConnected {
            let notified = dropNotified
            reset()
            return notified ? .notifyRestore : .none
        }
        if paused { downSince = nil; return .none }
        if downSince == nil { downSince = now }
        if !dropNotified, let since = downSince, now.timeIntervalSince(since) >= Self.grace {
            dropNotified = true
            return .notifyDrop
        }
        return .none
    }

    mutating func reset() {
        downSince = nil
        dropNotified = false
    }

    /// 睡眠喚醒時呼叫：睡眠期間不算進寬限時間，從喚醒後重新計時（規格 §4.2 喚醒重建不通知）
    mutating func restartGrace() { downSince = nil }

    // 通知文字
    static func dropTitle(app: String) -> String { "\(app) 已斷線" }
    static let dropBody = "VPN 中斷超過 30 秒，正在自動重連"
    static func restoreTitle(app: String) -> String { "\(app) 已恢復連線" }
    /// connection 是 status 回報的連線名稱（例：vpn2）；取不到台號就省略
    static func restoreBody(connection: String?) -> String {
        guard let c = connection, c.lowercased().hasPrefix("vpn"), c.count > 3 else { return "VPN 已重新連上" }
        return "\(c.uppercased()) 已重新連上"
    }
}

@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var state: VPNState = .disconnected
    @Published private(set) var busy = false            // 協調器正在執行連線／斷線
    @Published private(set) var busyText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var retryNote: String?      // 自動重連的等待狀態，例：「連線中斷，15 秒後重試」
    @Published var settings: VPNSettings = ConfigStore.load()

    /// 使用者的連線意圖。只有按「斷線」才會變成 false（規格 §3.2）
    @Published private(set) var wantConnected: Bool = UserDefaults.standard.bool(forKey: "WantConnected") {
        didSet { UserDefaults.standard.set(wantConnected, forKey: "WantConnected") }
    }
    /// F4 閘道連線紀錄。「上次成功的閘道」也由它推得（取代舊的 LastGoodGateway），只有一個來源
    @Published private(set) var history: GatewayHistory = {
        let ud = UserDefaults.standard
        let gateways = ConfigStore.load().gateways
        let legacy = ud.object(forKey: "LastGoodGateway") as? Int   // 1.3 以前的舊 key
        let h = GatewayHistory.migrated(GatewayHistory.decode(ud.data(forKey: GatewayHistory.defaultsKey)),
                                        legacyLastGood: legacy, gateways: gateways, now: Date())
            .pruned(gateways: gateways)
        if legacy != nil {
            // 先存下遷移結果再移除舊 key（初始值不會觸發 didSet）
            ud.set(h.encoded(), forKey: GatewayHistory.defaultsKey)
            ud.removeObject(forKey: "LastGoodGateway")
        }
        return h
    }() {
        didSet { UserDefaults.standard.set(history.encoded(), forKey: GatewayHistory.defaultsKey) }
    }

    private var timer: Timer?
    private var logTrimTimer: Timer?
    private var refreshing = false
    private var status = HelperStatus(state: .disconnected, localIP: nil, establishedSeconds: nil)
    private var firstRefreshDone = false

    // 協調器狀態
    private var opTask: Task<Void, Never>?           // 目前執行中的連線動作
    private var retryTask: Task<Void, Never>?        // 排定中的下一次重試
    private var backoffStep = 0
    private var pendingDown = false                  // up 執行中按了斷線：回來後馬上 down
    private var recheckAfterOp = false               // 執行中收到網路事件：完成後重新比對一次
    private var ignorePathUntil = Date.distantPast   // App 自己的 up/down 之後 10 秒內忽略路徑變更
    private var lastWake = Date.distantPast
    private var connectingSince: Date?
    private var disconnectedAt: Date?
    private var lastUpAt = Date.distantPast           // 最近一次 up 成功的時間（判斷「連上就被踢」）
    private var retryTargets: [Int]?                 // 手動指定單台失敗時，重試同一台；nil 代表自動輪替
    private var retrySoon = false                    // 連線動作執行中網路恢復：失敗後 1 秒就重試
    private var dropDetector = DropDetector()        // F2 非預期斷線通知的判定

    // 網路監聽
    private let pathMonitor = NWPathMonitor()
    private var networkUp = true
    private var pathDebounce: Task<Void, Never>?

    func start() {
        DropNotifier.shared.activate()
        refresh()
        // 輔助程式可能剛更新：讓 charon 重新讀取重送參數（舊版輔助程式不認得這個子命令，失敗無妨）
        Task { _ = await Self.runHelper(["reload-settings"]) }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // F3：App 執行中每小時控制一次 charon log 大小（規格 §5.3）
        logTrimTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { await VPNController.trimCharonLog() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.handlePath(satisfied: ok) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "splitswan.path"))
    }

    func gatewayTitle(_ index: Int) -> String {
        let gw = settings.gateways.indices.contains(index) ? settings.gateways[index] : ""
        return gw.isEmpty ? "VPN\(index + 1)（未設定）" : "VPN\(index + 1)（\(gw)）"
    }

    // MARK: 使用者操作

    /// target：auto 或 1／2／3
    func connect(_ target: String) {
        wantConnected = true
        pendingDown = false
        lastError = nil
        cancelRetry()
        backoffStep = 0
        guard opTask == nil else { return }   // 已經有連線動作在跑（例：自動重連），讓它完成
        retryTargets = (target == "auto") ? nil : Int(target).map { [$0] }
        if target == "auto" {
            runConnectSequence(autoOrder(), reason: "手動")
        } else if let n = Int(target) {
            runConnectSequence([n], reason: "手動", isSingle: true)
        }
    }

    /// 斷線可以搶先：up 還在跑就先記下，回來後馬上 down（規格 §3.3）
    func disconnect() {
        wantConnected = false
        retryTargets = nil
        retrySoon = false
        cancelRetry()
        retryNote = nil
        dropDetector.reset()                   // 手動斷線不算掉線（規格 §4）
        if opTask != nil {
            pendingDown = true
            busyText = "斷線中…"
            return
        }
        runDown(reason: "手動")
    }

    /// 輔助程式安裝或更新完成後呼叫（規格 §2.1）
    func helperUpdated() {
        Task {
            _ = await Self.runHelper(["reload"])
            _ = await Self.runHelper(["reload-settings"])
            self.refresh()
        }
    }

    /// 設定頁「清除閘道連線紀錄」：之後自動輪替恢復設定順序（上次成功的閘道也由紀錄推得，一併清掉）
    func clearHistory() {
        history.removeAll()
        note("已清除閘道連線紀錄")
    }

    /// 儲存設定後重新載入，已連線中的通道不受影響，下次連線才套用
    func reloadConfig() {
        settings = ConfigStore.load()
        // 閘道位址改了，該台的舊紀錄就沒有參考價值
        let kept = history.pruned(gateways: settings.gateways)
        if kept != history { history = kept; note("閘道位址變更，已清除該台的連線紀錄") }
        Task {
            _ = await Self.runHelper(["reload"])
            _ = await Self.runHelper(["reload-settings"])
        }
    }

    /// 設定頁一鍵加入網段後呼叫：確定 strongSwan 已載入新設定，再斷線重連讓新網段生效。
    /// 沒在連線、或已有連線動作在跑時不做事，回傳 false
    @discardableResult
    func reconnect(reason: String) -> Bool {
        guard wantConnected, state.isConnected, opTask == nil else { return false }
        cancelRetry()
        backoffStep = 0
        Task {
            _ = await Self.runHelper(["reload"])
            self.rebuild(reason: reason)
        }
        return true
    }

    // MARK: 狀態輪詢

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            let (code, out) = await Self.runHelper(["status"])
            let new = code == 0 ? HelperStatus.parse(out) : HelperStatus(state: .helperMissing, localIP: nil, establishedSeconds: nil)
            apply(new)
        }
    }

    private func apply(_ new: HelperStatus) {
        let old = state
        status = new
        state = new.state

        // 已連線時間：App 啟動時已連著就用 SA 秒數初始化，之後自己計時（規格 §3.5）
        switch new.state {
        case .connected:
            connectingSince = nil
            if connectedSince == nil {
                if !firstRefreshDone, let est = new.establishedSeconds {
                    connectedSince = Date().addingTimeInterval(-TimeInterval(est))
                } else if let at = disconnectedAt, Date().timeIntervalSince(at) > 30 {
                    connectedSince = Date()
                } else {
                    connectedSince = connectedSince ?? Date()
                }
            }
            disconnectedAt = nil
            retryNote = nil
        case .connecting:
            if connectingSince == nil { connectingSince = Date() }
            if old.isConnected { disconnectedAt = Date() }
        case .disconnected, .helperMissing:
            connectingSince = nil
            if old.isConnected || (disconnectedAt == nil && connectedSince != nil) { disconnectedAt = Date() }
            // 失聯超過 30 秒才歸零已連線時間；使用者不想連就直接歸零
            if !wantConnected { connectedSince = nil }
            else if let at = disconnectedAt, Date().timeIntervalSince(at) > 30 { connectedSince = nil }
        }
        let wasFirst = !firstRefreshDone
        firstRefreshDone = true
        checkDrop(new.state)
        // 連線穩定超過 60 秒才把退避歸零；連上沒多久就被踢，下次重試仍照退避間隔
        if new.state.isConnected, Date().timeIntervalSince(lastUpAt) > 60 { backoffStep = 0 }

        guard wantConnected, opTask == nil, new.state != .helperMissing else { return }

        switch new.state {
        case .disconnected:
            guard retryTask == nil, networkUp else { break }
            if old.isConnected, Date().timeIntervalSince(lastUpAt) < 60 {
                // 連上不到 60 秒就失聯（例：被閘道踢掉）：視為失敗，照退避間隔重試，避免無間斷重連
                note("連上 \(Int(Date().timeIntervalSince(lastUpAt))) 秒就失聯，改走退避重試")
                if case .connected(let c, _) = old { recordLateFailure(connection: c, why: "連上不到 60 秒就失聯") }
                scheduleRetry()
            } else {
                // App 啟動時、或通道失聯（dpd_action = clear 會移除 SA）→ 重連
                runConnectSequence(nextOrder(),
                                   reason: wasFirst ? "啟動時接回" : (old.isConnected ? "通道失聯" : "重試"))
            }
        case .connecting:
            // 卡在連線中超過 30 秒：視為一次失敗（規格 §3.3）；啟動時看到 connecting 也走這條，不直接 up
            if retryTask == nil, let since = connectingSince, Date().timeIntervalSince(since) > 30 {
                connectingSince = nil
                if case .connecting(let c) = new.state { recordLateFailure(connection: c, why: "卡在連線中超過 30 秒") }
                runDown(reason: "卡在連線中") { [weak self] in self?.scheduleRetry() }
            }
        default:
            break
        }
    }

    /// F2：想連線但沒連上超過 30 秒發掉線通知，之後恢復時發恢復通知（規格 §4）。
    /// App 自己重建通道時的 down 也照算，30 秒內接回就不發
    private func checkDrop(_ state: VPNState) {
        let action = dropDetector.update(now: Date(), wantConnected: wantConnected,
                                         isConnected: state.isConnected, enabled: DropDetector.enabled,
                                         paused: !networkUp || state == .helperMissing)
        switch action {
        case .notifyDrop:
            note("中斷超過 \(Int(DropDetector.grace)) 秒，發送斷線通知")
            DropNotifier.shared.send(title: DropDetector.dropTitle(app: AppInfo.name), body: DropDetector.dropBody)
        case .notifyRestore:
            var conn: String?
            if case .connected(let c, _) = state { conn = c }
            note("已恢復連線，發送恢復通知")
            DropNotifier.shared.send(title: DropDetector.restoreTitle(app: AppInfo.name),
                                     body: DropDetector.restoreBody(connection: conn))
        case .none:
            break
        }
    }

    // MARK: 事件

    private func handleWake() {
        lastWake = Date()
        dropDetector.restartGrace()
        guard wantConnected else { return }
        backoffStep = 0
        cancelRetry()
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard self.wantConnected else { return }
            if self.opTask != nil { self.recheckAfterOp = true; return }
            // 同網路下 SA 看起來還在，閘道端可能早已刪除：一律重建（規格 §3.3）
            self.rebuild(reason: "睡眠喚醒")
        }
    }

    private func handlePath(satisfied: Bool) {
        let wasUp = networkUp
        networkUp = satisfied
        guard wantConnected else { return }
        if !satisfied {
            cancelRetry()
            retryNote = "沒有網路，恢復後自動重連"
            return
        }
        if !wasUp {
            // 網路恢復：重設退避
            backoffStep = 0
            retryNote = nil
            if opTask != nil {
                // 動作執行中（例：喚醒重建時網路還沒好）：失敗後 1 秒就重試，成功就重新比對 IP
                retrySoon = true
                recheckAfterOp = true
            } else if state.isConnected {
                // 換 Wi-Fi 常會短暫斷網，SA 仍顯示已連線：馬上比對 IP，不等 DPD
                scheduleIPCheck(after: 3)
            } else {
                cancelRetry(); scheduleRetry(after: 1)
            }
            return
        }
        if opTask != nil { recheckAfterOp = true; return }
        // App 自己連線／斷線造成的 utun 增減，或喚醒後 15 秒內的變化：忽略（規格 §3.3）
        if Date() < ignorePathUntil || Date().timeIntervalSince(lastWake) < 15 { return }
        scheduleIPCheck(after: 3)
    }

    private func scheduleIPCheck(after seconds: UInt64) {
        pathDebounce?.cancel()
        pathDebounce = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.checkLocalIPChanged()
        }
    }

    /// 重試要連哪些閘道：手動指定單台就重試同一台，否則自動輪替
    private func nextOrder() -> [Int] {
        retryTargets ?? autoOrder()
    }

    /// 自動輪替：依連線紀錄排序（F4）
    private func autoOrder() -> [Int] {
        GatewayHistory.order(gateways: settings.gateways, history: history, now: Date())
    }

    /// 主要介面的 IPv4 跟 SA 的本機 IP 不同 → 換了網路，重建通道
    private func checkLocalIPChanged() {
        guard wantConnected, state.isConnected, let saIP = status.localIP else { return }
        if opTask != nil { recheckAfterOp = true; return }
        let current = Self.primaryIPv4s()
        guard !current.isEmpty, !current.contains(saIP) else { return }
        backoffStep = 0
        rebuild(reason: "網路改變（\(saIP) → \(current.first ?? "?")）")
    }

    // MARK: 協調器

    private func rebuild(reason: String) {
        runDown(reason: reason) { [weak self] in
            guard let self, self.wantConnected else { return }
            self.runConnectSequence(self.nextOrder(), reason: reason)
        }
    }

    private func runConnectSequence(_ order: [Int], reason: String, isSingle: Bool = false) {
        guard opTask == nil else { return }
        guard !order.isEmpty else { lastError = "尚未設定閘道"; return }
        guard networkUp else { retryNote = "沒有網路，恢復後自動重連"; return }
        busy = true
        retryNote = nil
        note("開始連線（\(reason)）：依序嘗試 \(order.map { "VPN\($0)" }.joined(separator: " → "))")
        opTask = Task {
            // F3：每次連線嘗試前控制 charon log 大小（規格 §5.3）；舊版輔助程式不認得，結果一律不管
            await Self.trimCharonLog()
            var ok = false
            for n in order {
                if self.pendingDown || !self.wantConnected || !self.networkUp { break }
                self.busyText = "連線 VPN\(n)…"
                let address = self.settings.gateways.indices.contains(n - 1) ? self.settings.gateways[n - 1] : ""
                let started = Date()
                let (code, out) = await Self.runHelper(["up", "\(n)"])
                self.recordAttempt(n, address: address, success: code == 0, output: out, started: started)
                if code == 0 { ok = true; self.lastUpAt = Date(); self.note("VPN\(n) 已連線"); break }
                note("VPN\(n) 連線失敗")
            }
            self.finishOp()
            if self.pendingDown || !self.wantConnected {
                self.pendingDown = false
                self.runDown(reason: "連線中按了斷線")
                return
            }
            let soon = self.retrySoon
            self.retrySoon = false
            if ok {
                // 退避要等連線穩定 60 秒才歸零（見 apply）
                self.lastError = nil
            } else if !self.networkUp {
                self.retryNote = "沒有網路，恢復後自動重連"
            } else {
                self.lastError = isSingle
                    ? "VPN\(order[0]) 連線失敗，將自動重試同一台；請開啟連線 log 查看原因"
                    : "所有閘道都連不上，將自動重試"
                if soon { self.scheduleRetry(after: 1) } else { self.scheduleRetry() }
            }
            self.afterOpRecheck()
            self.refresh()
        }
    }

    /// F4：記錄一次 up N 的結果。失敗但原因可能不在閘道時不記（判斷規則見 GatewayHistory.shouldRecord）
    private func recordAttempt(_ n: Int, address: String, success: Bool, output: String, started: Date) {
        guard GatewayHistory.shouldRecord(gateway: n, success: success, output: output,
                                          interrupted: pendingDown || !wantConnected || !networkUp) else { return }
        let secs = (Date().timeIntervalSince(started) * 10).rounded() / 10
        history.record(GatewayAttempt(gateway: n, address: address, success: success, seconds: secs, time: Date()))
    }

    /// F4：up 回報成功、之後才失敗的情況（連上不到 60 秒被踢、卡在連線中超過 30 秒），
    /// 替 status 回報的那台補記一筆失敗，否則它會一直是「上次成功」、不進冷卻。
    /// 台號取自 status 的連線名稱（vpnN），不用最近一筆成功紀錄推：卡在連線中的可能是命令列或上一個程序發起的
    private func recordLateFailure(connection: String, why: String) {
        guard networkUp, let n = GatewayHistory.gateway(fromConnection: connection),
              settings.gateways.indices.contains(n - 1), !settings.gateways[n - 1].isEmpty else { return }
        history.record(GatewayAttempt(gateway: n, address: settings.gateways[n - 1], success: false, seconds: nil, time: Date()))
        note("VPN\(n) \(why)，記為一次失敗")
    }

    private func runDown(reason: String, then next: (() -> Void)? = nil) {
        guard opTask == nil else { return }
        busy = true
        busyText = "斷線中…"
        note("斷線（\(reason)）")
        opTask = Task {
            _ = await Self.runHelper(["down"])
            self.finishOp()
            self.refresh()
            if let next { next() } else { self.afterOpRecheck() }
        }
    }

    /// 寫進 App 內的連線紀錄，同時留一份在系統 log
    private func note(_ s: String) {
        NSLog("[SplitSwan] %@", s)
        LogStore.shared.app(s)
    }

    private func finishOp() {
        opTask = nil
        connectingSince = nil
        busy = false
        busyText = ""
        ignorePathUntil = Date().addingTimeInterval(10)
    }

    private func afterOpRecheck() {
        guard recheckAfterOp else { return }
        recheckAfterOp = false
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.refresh()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.checkLocalIPChanged()
        }
    }

    private func scheduleRetry(after fixed: TimeInterval? = nil) {
        guard wantConnected, networkUp else { return }
        cancelRetry()
        let wait = fixed ?? ReconnectPolicy.backoff(backoffStep)
        if fixed == nil { backoffStep += 1 }
        retryNote = "連線中斷，\(Int(wait)) 秒後重試"
        note("\(Int(wait)) 秒後重試")
        retryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.retryTask = nil
            guard self.wantConnected, self.networkUp, !self.state.isConnected else { return }
            self.runConnectSequence(self.nextOrder(), reason: "重試")
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: 系統資訊

    /// 目前實體網路介面（排除 VPN 的 utun、loopback、虛擬機橋接）上的 IPv4 位址
    nonisolated static func primaryIPv4s() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard !ReconnectPolicy.isTunnelInterface(name), !name.hasPrefix("bridge"), !name.hasPrefix("lo") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    // MARK: 呼叫輔助程式

    nonisolated static func runHelper(_ args: [String]) async -> (Int32, String) {
        await run("/usr/bin/sudo", ["-n", helperPath] + args)
    }

    /// 輔助程式 logtrim：charon log 太大時就地截斷。舊版輔助程式會回 usage 錯誤，
    /// sudo 失敗也一樣，都安靜略過，不影響連線
    nonisolated static func trimCharonLog() async {
        _ = await runHelper(["logtrim"])
    }

    nonisolated static func run(_ exe: String, _ args: [String], env: [String: String]? = nil) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let env { p.environment = env }
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                var code: Int32 = 127
                var data = Data()
                do {
                    try p.run()
                    data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    code = p.terminationStatus
                } catch {}
                let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(returning: (code, out))
            }
        }
    }
}
