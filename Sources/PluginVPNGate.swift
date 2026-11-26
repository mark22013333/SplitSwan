import Combine
import Foundation

/// 外掛設定視窗的動作宣告 `requiresVPN` 時，由這層向公司 VPN 取得狀態與發起連線；測試以假的實作替換。
@MainActor
protocol PluginActionVPN: AnyObject {
    var gateStatus: PluginVPNGate.Status { get }
    func connectAuto()
    func cancelConnectionIntent()
    /// 狀態即將改變時呼叫（可能在同一輪連續多次）；釋放回傳值即停止通知。
    func observeChanges(_ onChange: @escaping () -> Void) -> AnyCancellable
    /// 連上後、執行外掛前呼叫，讓外掛收到的 `SPLITSWAN_VPN_STATE` 已是最新狀態。
    func publishToPlugins()
}

/// 「先連上公司 VPN 再執行外掛動作」的判斷，只在使用者於設定視窗親手按下動作時使用。
enum PluginVPNGate {
    static let timeout: Duration = .seconds(60)
    static let connectingText = "正在連線公司 VPN…"

    struct Status: Equatable {
        var connected: Bool
        var busy: Bool
        var wantConnected: Bool
        var lastError: String?
        /// 協調器真正放棄連線時遞增（見 `VPNController.failureGeneration`）。`retryNote` 也會出現在
        /// 1 秒短重試等暫時狀態，不能拿來判斷失敗。
        var failureGeneration = 0
        var failureReason: String?
        /// 連線意圖每被設定或取消一次就遞增，用來分辨意圖是不是還停在我們設的那一次。
        var intentGeneration = 0
    }
    enum Verdict: Equatable { case waiting, connected, failed(reason: String?) }
    enum Outcome: Equatable { case ready, failed(String), cancelled }

    static func needsConnection(_ action: PluginSettingsProtocol.Action, status: Status) -> Bool {
        action.requiresVPN == true && !status.connected
    }

    /// `failuresBefore`：發起連線前的 `failureGeneration`。
    static func judge(_ s: Status, failuresBefore: Int) -> Verdict {
        if s.connected { return .connected }
        if s.failureGeneration != failuresBefore { return .failed(reason: s.failureReason) }
        // 連線意圖被取消：公司分流不允許連線，或使用者在選單按了斷線
        if !s.wantConnected { return .failed(reason: s.lastError) }
        return .waiting
    }

    static func failureMessage(reason: String?) -> String {
        var text = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while text.hasSuffix("。") { text.removeLast() }
        return "公司 VPN 連不上：\(text.isEmpty ? "60 秒內沒有連上" : text)，未執行此動作"
    }

    /// 只有按下前不想連線、而且意圖仍是我們設的那一次才還原；等待期間使用者自己按了連線就不動。
    static func shouldRestoreIntent(wantConnectedBefore: Bool, ownIntent: Int, currentIntent: Int) -> Bool {
        !wantConnectedBefore && ownIntent == currentIntent
    }

    /// 已連線直接回 ready；否則發起連線並等到連上、失敗、逾時，或呼叫端的 Task 被取消。
    @MainActor
    static func ensureConnected(_ vpn: PluginActionVPN, timeout: Duration = timeout) async -> Outcome {
        let before = vpn.gateStatus
        if before.connected { vpn.publishToPlugins(); return .ready }
        if Task.isCancelled { return .cancelled }
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = vpn.observeChanges { continuation.yield() }
        let timer = Task { try? await Task.sleep(for: timeout); continuation.finish() }
        defer { observation.cancel(); timer.cancel(); continuation.finish() }

        vpn.connectAuto()
        let ownIntent = vpn.gateStatus.intentGeneration
        func evaluate() -> Verdict { judge(vpn.gateStatus, failuresBefore: before.failureGeneration) }
        // 通知發生在屬性改變之前；下一輪才讀，拿到的是同一批改動完成後的狀態。
        var verdict = evaluate()
        if verdict == .waiting {
            for await _ in changes {
                verdict = evaluate()
                if verdict != .waiting { break }
            }
        }
        let restore = shouldRestoreIntent(wantConnectedBefore: before.wantConnected, ownIntent: ownIntent,
                                          currentIntent: vpn.gateStatus.intentGeneration)
        switch verdict {
        case .connected:
            vpn.publishToPlugins()
            return .ready
        case .failed(let reason):
            if restore { vpn.cancelConnectionIntent() }
            return .failed(failureMessage(reason: reason))
        case .waiting:
            let reason = vpn.gateStatus.lastError
            if restore { vpn.cancelConnectionIntent() }
            if Task.isCancelled { return .cancelled }
            return .failed(failureMessage(reason: reason))
        }
    }
}
