import Combine
import Foundation

// requiresVPN：使用者親手按下需要公司 VPN 的動作時，先連上才執行。VPN 一律用假的，不連線。
typealias P = PluginSettingsProtocol
typealias G = PluginVPNGate
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) {
    if ok { passed += 1 } else { failed += 1; print("❌ \(name)") }
}

@MainActor
final class FakeVPN: PluginActionVPN {
    private let changes = PassthroughSubject<Void, Never>()
    var status: G.Status { willSet { changes.send() } }
    var connects = 0, cancels = 0
    var published: [Bool] = []
    var onConnect: (FakeVPN) -> Void = { _ in }
    init(connected: Bool = false, wantConnected: Bool = false) {
        status = G.Status(connected: connected, busy: false, wantConnected: wantConnected, lastError: nil, retryNote: nil)
    }
    var gateStatus: G.Status { status }
    // 與 VPNController.connect 相同：設定連線意圖、清掉舊錯誤，再由協調器決定要不要開始
    func connectAuto() {
        connects += 1
        status.wantConnected = true
        status.lastError = nil
        onConnect(self)
    }
    func cancelConnectionIntent() {
        cancels += 1
        status.wantConnected = false
        status.retryNote = nil
    }
    func observeChanges(_ onChange: @escaping () -> Void) -> AnyCancellable { changes.sink { _ in onChange() } }
    func publishToPlugins() { published.append(status.connected) }
}

func formData(requiresVPN: Bool?, opensTab: Bool = false) throws -> Data {
    var action: [String: Any] = ["id": "punch", "tab": "general", "title": "立即打卡"]
    if let requiresVPN { action["requiresVPN"] = requiresVPN }
    var tabs: [[String: Any]] = [["id": "general", "title": "設定"]]
    if opensTab {
        action["opensTab"] = "more"
        tabs.append(["id": "more", "title": "更多", "hidden": true])
    }
    return try JSONSerialization.data(withJSONObject: [
        "version": 1, "title": "VPN 動作測試", "revision": "r1", "tabs": tabs,
        "fields": [["id": "note", "tab": "general", "title": "備註", "type": "text"]],
        "values": ["note": ""], "actions": [action]
    ] as [String: Any])
}

@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
func runTests() async throws {
    // 協定
    let omitted = try P.decode(try formData(requiresVPN: nil))
    check("省略 requiresVPN 等於 false", omitted.actions[0].requiresVPN == nil
          && !G.needsConnection(omitted.actions[0], status: FakeVPN().gateStatus))
    let declared = try P.decode(try formData(requiresVPN: true))
    check("requiresVPN: true 可解碼", declared.actions[0].requiresVPN == true)
    check("未連線時宣告的動作需要連線", G.needsConnection(declared.actions[0], status: FakeVPN().gateStatus))
    check("已連線時宣告的動作不需連線", !G.needsConnection(declared.actions[0], status: FakeVPN(connected: true).gateStatus))
    check("requiresVPN: false 不需連線", !G.needsConnection(try P.decode(try formData(requiresVPN: false)).actions[0], status: FakeVPN().gateStatus))
    check("只切換頁籤的動作不能宣告 requiresVPN", (try? P.decode(try formData(requiresVPN: true, opensTab: true))) == nil)
    check("只切換頁籤的動作不宣告時照常可用", (try? P.decode(try formData(requiresVPN: nil, opensTab: true))) != nil)

    // 判斷與訊息
    func s(connected: Bool = false, busy: Bool = false, want: Bool = true, error: String? = nil, note: String? = nil) -> G.Status {
        G.Status(connected: connected, busy: busy, wantConnected: want, lastError: error, retryNote: note)
    }
    check("連上即成功", G.judge(s(connected: true), sawBusy: true) == .connected)
    check("協調器執行中繼續等", G.judge(s(busy: true), sawBusy: true) == .waiting)
    check("排定重試＝這輪失敗，原因取 lastError",
          G.judge(s(error: "三台都連不上", note: "連線中斷，15 秒後重試"), sawBusy: true) == .failed(reason: "三台都連不上"))
    check("沒網路只有 retryNote 時以它為原因", G.judge(s(note: "沒有網路，恢復後自動重連"), sawBusy: false) == .failed(reason: "沒有網路，恢復後自動重連"))
    check("連線意圖被取消即失敗", G.judge(s(want: false, error: "分流尚未允許"), sawBusy: true) == .failed(reason: "分流尚未允許"))
    check("沒執行就有錯誤（未設定閘道）即失敗", G.judge(s(error: "尚未設定閘道"), sawBusy: false) == .failed(reason: "尚未設定閘道"))
    check("連上後的路由提示不當失敗，等狀態更新", G.judge(s(error: "路由仍未走 VPN"), sawBusy: true) == .waiting)
    check("沒有原因寫 60 秒內沒有連上", G.failureMessage(reason: nil) == "公司 VPN 連不上：60 秒內沒有連上，未執行此動作")
    check("原因句尾句號不重複", G.failureMessage(reason: "三台都連不上。") == "公司 VPN 連不上：三台都連不上，未執行此動作")
    check("按下前不想連線才還原意圖", G.shouldRestoreIntent(wantConnectedBefore: false) && !G.shouldRestoreIntent(wantConnectedBefore: true))

    // 設定視窗流程
    let action = declared.actions[0]
    var calls: [G.Status] = []
    var currentVPN = FakeVPN()
    let command: @MainActor (String, P.Request?) async throws -> P.Snapshot = { operation, _ in
        if operation == "action" { calls.append(currentVPN.status) }
        return declared
    }
    func model(_ vpn: FakeVPN?, timeout: Duration = .seconds(5)) async -> PluginConfigurationModel {
        if let vpn { currentVPN = vpn }
        calls = []
        let m = PluginConfigurationModel(pluginID: "vpn-fixture", command: command, vpn: vpn, vpnTimeout: timeout)
        await m.load()
        return m
    }

    let connected = FakeVPN(connected: true, wantConnected: true)
    var m = await model(connected)
    await m.userAction(action)
    check("已連線：直接執行、不發起連線", calls.count == 1 && connected.connects == 0 && connected.published == [true])

    let later = FakeVPN()
    later.onConnect = { vpn in
        vpn.status.busy = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            vpn.status.busy = false
            vpn.status.lastError = "路由提示（成功時也可能出現）"
            try? await Task.sleep(for: .milliseconds(80))
            vpn.status.connected = true
        }
    }
    m = await model(later)
    let running = Task { await m.userAction(action) }
    await waitUntil { m.vpnWaitingAction != nil }
    check("等待中顯示連線中、可取消、其他操作鎖住", m.vpnWaitingAction == "punch" && m.canCancel && m.busy && calls.isEmpty)
    await running.value
    check("未連線：連上後才執行，執行當下已是 connected",
          later.connects == 1 && calls.count == 1 && calls.first?.connected == true && later.published == [true])
    check("成功後不斷線、不還原意圖、清除等待狀態", later.cancels == 0 && later.status.wantConnected && m.vpnWaitingAction == nil && !m.busy && m.error == nil)

    let stuck = FakeVPN()
    stuck.onConnect = { $0.status.busy = true }
    m = await model(stuck, timeout: .milliseconds(150))
    await m.userAction(action)
    check("逾時：不執行並顯示訊息", calls.isEmpty && m.error == "公司 VPN 連不上：60 秒內沒有連上，未執行此動作")
    check("逾時：我們發起的連線要還原意圖", stuck.cancels == 1 && !stuck.status.wantConnected && !m.busy)

    let wanted = FakeVPN(wantConnected: true)
    wanted.onConnect = { vpn in
        vpn.status.busy = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            vpn.status.busy = false
            vpn.status.lastError = "VPN1、VPN2 都連不上"
            vpn.status.retryNote = "連線中斷，15 秒後重試"
        }
    }
    m = await model(wanted)
    await m.userAction(action)
    check("失敗：顯示協調器的原因", calls.isEmpty && m.error == "公司 VPN 連不上：VPN1、VPN2 都連不上，未執行此動作")
    check("按下前已想連線：失敗不還原意圖", wanted.cancels == 0 && wanted.status.wantConnected)

    let noGateway = FakeVPN()
    noGateway.onConnect = { $0.status.lastError = "尚未設定閘道" }
    m = await model(noGateway)
    await m.userAction(action)
    check("協調器當場拒絕：立即失敗並還原", calls.isEmpty && m.error == "公司 VPN 連不上：尚未設定閘道，未執行此動作" && noGateway.cancels == 1)

    let cancelled = FakeVPN()
    cancelled.onConnect = { $0.status.busy = true }
    m = await model(cancelled)
    var closes = 0
    m.requestClose = { closes += 1 }
    let pending = Task { await m.userAction(action) }
    await waitUntil { m.vpnWaitingAction != nil }
    m.cancelAndClose()
    await pending.value
    check("按取消：放棄等待、不執行、關閉視窗", calls.isEmpty && closes == 1 && m.error == nil && m.vpnWaitingAction == nil)
    check("按取消：我們發起的連線要還原意圖", cancelled.cancels == 1)
    cancelled.status.connected = true
    try? await Task.sleep(for: .milliseconds(50))
    check("取消後才連上也不補執行", calls.isEmpty)

    let closed = FakeVPN()
    closed.onConnect = { $0.status.busy = true }
    m = await model(closed)
    let closing = Task { await m.userAction(action) }
    await waitUntil { m.vpnWaitingAction != nil }
    m.stop()
    await closing.value
    check("關閉視窗：放棄等待、不執行並還原意圖", calls.isEmpty && closed.cancels == 1)

    let stopButton = FakeVPN(wantConnected: true)
    stopButton.onConnect = { $0.status.busy = true }
    m = await model(stopButton)
    let stopping = Task { await m.userAction(action) }
    await waitUntil { m.vpnWaitingAction != nil }
    m.cancelVPNWait()
    await stopping.value
    check("停止等待：視窗不關、不執行；按下前已想連線就不還原", calls.isEmpty && stopButton.cancels == 0 && !m.busy)

    let background = FakeVPN()
    m = await model(background)
    await m.action(action)
    check("非使用者觸發的執行不發起連線", background.connects == 0 && calls.count == 1)

    m = await model(nil)
    await m.userAction(action)
    check("沒有注入 VPN 時照舊執行", calls.count == 1)

    print("通過 \(passed)，失敗 \(failed)")
}

try await runTests()
exit(failed == 0 ? 0 : 1)
