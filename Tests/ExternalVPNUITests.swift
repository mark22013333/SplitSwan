import AppKit
import SwiftUI

enum DiagnosticReport {
    struct CommandResult { var code: Int32; var output: String; var timedOut = false; var seconds: TimeInterval }
}

@MainActor
func runExternalUI() async throws -> Int {
    var passed = 0, failed = 0
    func check(_ name: String, _ value: Bool) { print((value ? "✅ " : "❌ ") + name); value ? (passed += 1) : (failed += 1) }
    let suite = "SplitSwan.ExternalVPN.UI." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    var calls: [String] = []
    var recovery = false
    var lockFailure = false
    let model = ExternalVPNController(preferences: preferences, autoRefresh: false) { operation, input in
        calls.append(operation)
        if lockFailure, operation == "tick" {
            let failure = ExternalVPNStatus(phase: .failed, message: "另一個分流操作正在執行", interface: nil, tunnel: nil, routeCount: 0)
            return (1, String(decoding: try! JSONEncoder().encode(failure), as: UTF8.self))
        }
        let status: ExternalVPNStatus
        switch operation {
        case "prepare": status = ExternalVPNStatus(phase: .waiting, message: "已記住原本網路，等待外部 VPN 連線", interface: "en0", tunnel: nil, routeCount: 0)
        case "tick": status = ExternalVPNStatus(phase: .active, message: "IPv4 分流已套用；請確認外網與 VPN 系統皆可使用", interface: "en0", tunnel: "ppp0", routeCount: 75)
        case "restore": status = .idle
        default: status = recovery ? ExternalVPNStatus(phase: .recoveryRequired, message: "部分設定已被變更或復原失敗，保留紀錄供再次復原", interface: "en0", tunnel: "ppp0", routeCount: 1) : .idle
        }
        return (0, String(decoding: try! JSONEncoder().encode(status), as: UTF8.self))
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let host = NSHostingController(rootView: ExternalVPNTab(model: model, helperReady: true, installing: false, fortiBusy: false, install: {})
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentViewController: host)
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 620, height: 740))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); window.orderBack(nil)
    defer { window.orderOut(nil) }
    func settle(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
    check("獨立頁面無需 FortiGate 設定即可呈現", window.contentView != nil && model.status.phase == .idle)
    await model.start()
    await settle { model.status.phase == .active }
    check("開始會自動等待並套用，不需斷網後再按一次", model.status.phase == .active && calls.contains("prepare") && calls.contains("tick"))
    lockFailure = true
    await settle { model.status.phase == .recoveryRequired }
    check("作用中收到鎖定錯誤仍保留復原狀態", model.status.phase == .recoveryRequired && model.isManaging && model.status.routeCount == 75)
    lockFailure = false
    await model.stop()
    check("停止會呼叫復原並允許再次開始", model.status.phase == .idle && calls.last == "restore" && !model.isManaging)
    recovery = true
    await model.refresh()
    check("未完整復原保留管理狀態", model.status.phase == .recoveryRequired && model.isManaging)
    var retryTicks = 0
    let retryModel = ExternalVPNController(preferences: preferences, autoRefresh: false) { operation, _ in
        let status: ExternalVPNStatus
        switch operation {
        case "prepare": status = ExternalVPNStatus(phase: .waiting, message: "沿用原本上網快照", interface: "en0", tunnel: nil, routeCount: 0)
        case "tick":
            retryTicks += 1
            status = ExternalVPNStatus(phase: .failed, message: "保留首次原因的失敗", interface: "en0", tunnel: "ppp0", routeCount: 0, canRetry: true)
        case "restore": status = .idle
        default: status = ExternalVPNStatus(phase: .recoveryRequired, message: "舊版乾淨失敗紀錄", interface: "en0", tunnel: nil, routeCount: 0, canRetry: true)
        }
        return (operation == "tick" ? 1 : 0, String(decoding: try! JSONEncoder().encode(status), as: UTF8.self))
    }
    await retryModel.refresh()
    check("後端確認乾淨的舊版復原狀態可明確重試與修改設定", retryModel.isManaging && retryModel.canRetry && retryModel.canPrepare)
    retryModel.dnsDomains = "internal.example.com"
    await retryModel.start()
    await settle { retryModel.status.phase == .failed }
    check("明確重試失敗不被前端重新鎖成復原狀態", retryModel.status.phase == .failed && retryModel.canRetry && retryModel.canPrepare && retryTicks == 1)
    check("未取得後端重試能力的復原狀態仍鎖定", !model.canRetry && !model.canPrepare)
    await retryModel.stop()
    var keepInput: ExternalVPNProfile?
    let keepModel = ExternalVPNController(preferences: preferences, autoRefresh: false) { operation, data in
        if operation == "prepare", let data { keepInput = try! JSONDecoder().decode(ExternalVPNProfile.self, from: data) }
        let status = operation == "restore" ? ExternalVPNStatus.idle : ExternalVPNStatus(phase: operation == "prepare" ? .waiting : .active, message: "IPv4 路由已套用；DNS 維持 VPN 連線後原設定，外網與內網仍待確認", interface: "en0", tunnel: "ppp0", routeCount: 75, dnsMode: .preserveVPN)
        return (0, String(decoding: try! JSONEncoder().encode(status), as: UTF8.self))
    }
    keepModel.directIPv4 = "203.0.113.8, 198.51.100.8"
    keepModel.dnsMode = .preserveVPN
    keepModel.dnsDomains = "invalid domain kept for later"
    await keepModel.start()
    await settle { keepModel.status.phase == .active }
    check("保留模式傳送明確設定並忽略停用的網域欄", keepInput?.dnsMode == .preserveVPN && keepInput?.dnsDomains == [] && keepModel.status.dnsMode == .preserveVPN)
    let restoredPreferences = ExternalVPNController(preferences: preferences, autoRefresh: false) { _, _ in (0, "") }
    check("指定直連 IP 傳送為單一位址清單", keepInput?.directIPv4 == ["198.51.100.8", "203.0.113.8"])
    check("指定直連 IP 偏好可還原", restoredPreferences.directIPv4 == "203.0.113.8, 198.51.100.8")
    check("DNS 模式與原有網域文字各自保留", restoredPreferences.dnsMode == .preserveVPN && restoredPreferences.dnsDomains == "invalid domain kept for later")
    var menuCalls: [String] = []
    var menuStatus = ExternalVPNStatus.idle
    var menuAvailability = ExternalVPNMenu.Availability(helperReady: true, installing: false, companyBusy: false)
    var openedSettings = 0
    var pausedPrepare: CheckedContinuation<Void, Never>?
    var pausePrepare = false
    let menuModel = ExternalVPNController(preferences: preferences, autoRefresh: false) { operation, _ in
        menuCalls.append(operation)
        if operation == "prepare" {
            if pausePrepare { await withCheckedContinuation { pausedPrepare = $0 } }
            menuStatus = ExternalVPNStatus(phase: .waiting, message: "等待 VPN", interface: "en0", tunnel: nil, routeCount: 0)
        }
        if operation == "restore" { menuStatus = .idle }
        return (0, String(decoding: try! JSONEncoder().encode(menuStatus), as: UTF8.self))
    }
    let splitMenu = ExternalVPNMenu(model: menuModel, availability: { menuAvailability }, openSettings: { openedSettings += 1 })
    let nativeMenu = NSMenu()
    nativeMenu.autoenablesItems = false
    splitMenu.append(to: nativeMenu)
    func click(_ item: NSMenuItem) { if let action = item.action { app.sendAction(action, to: item.target, from: item) } }
    var menuEvidence: [[String: Any]] = []
    func recordMenu(_ state: String) {
        splitMenu.render()
        menuEvidence.append(["state": state, "items": nativeMenu.items.map { ["title": $0.title, "enabled": $0.isEnabled] }])
    }
    recordMenu("idle")
    check("原生選單顯示自動分流狀態與開始、停止及設定", nativeMenu.items.count == 4 && splitMenu.statusItem.title == "VPN 自動分流 · 未啟用" && splitMenu.startItem.isEnabled && !splitMenu.stopItem.isEnabled)
    click(splitMenu.settingsItem)
    check("原生設定選單會開啟自動分流頁籤", openedSettings == 1)
    menuAvailability.helperReady = false
    recordMenu("helper-missing")
    check("系統元件未就緒時停用開始", !splitMenu.startItem.isEnabled)
    click(splitMenu.startItem)
    await Task.yield()
    check("停用的原生開始 selector 不呼叫系統傳輸", menuCalls.isEmpty)
    menuAvailability.helperReady = true
    menuAvailability.installing = true
    recordMenu("installing")
    check("系統元件安裝期間停用開始", !splitMenu.startItem.isEnabled)
    menuAvailability.installing = false
    menuAvailability.companyBusy = true
    recordMenu("company-busy")
    click(splitMenu.startItem)
    await Task.yield()
    check("公司 VPN 使用中時選單與 selector 都維持互斥", !splitMenu.startItem.isEnabled && menuCalls.isEmpty)
    menuAvailability.companyBusy = false
    splitMenu.render()
    menuAvailability.companyBusy = true
    click(splitMenu.startItem)
    await Task.yield()
    check("選單顯示後公司狀態改變仍重新檢查", menuCalls.isEmpty)
    menuAvailability.companyBusy = false
    pausePrepare = true
    click(splitMenu.startItem)
    await settle { pausedPrepare != nil }
    recordMenu("busy")
    check("原生開始 selector 使用 controller 並在傳輸中停用操作", menuModel.busy && !splitMenu.startItem.isEnabled && !splitMenu.stopItem.isEnabled && menuCalls == ["prepare"])
    pausedPrepare?.resume()
    pausedPrepare = nil
    await settle { menuModel.status.phase == .waiting && !menuModel.busy }
    recordMenu("waiting")
    check("等待 VPN 時可以從選單停止，不能重複開始", splitMenu.statusItem.title == "VPN 自動分流 · 等待 VPN 連線" && !splitMenu.startItem.isEnabled && splitMenu.stopItem.isEnabled)
    click(splitMenu.stopItem)
    await settle { menuModel.status.phase == .idle && !menuModel.busy }
    check("原生停止 selector 確實復原同一個 controller", menuCalls.last == "restore" && !menuModel.isManaging)
    menuStatus = ExternalVPNStatus(phase: .active, message: "已套用", interface: "en0", tunnel: "utun7", routeCount: 42, dnsMode: .preserveVPN)
    await menuModel.refresh()
    recordMenu("active")
    check("作用中的原生選單顯示已啟用及復原入口", splitMenu.statusItem.title == "VPN 自動分流 · 已啟用" && !splitMenu.startItem.isEnabled && splitMenu.stopItem.isEnabled)
    await menuModel.stop()
    menuStatus = ExternalVPNStatus(phase: .failed, message: "可重試", interface: "en0", tunnel: nil, routeCount: 0, canRetry: true)
    await menuModel.refresh()
    recordMenu("retry")
    check("後端允許重試時原生選單顯示重新嘗試", splitMenu.startItem.title == "重新嘗試自動分流" && splitMenu.startItem.isEnabled && splitMenu.stopItem.isEnabled)
    menuStatus = ExternalVPNStatus(phase: .recoveryRequired, message: "復原失敗", interface: "en0", tunnel: "utun7", routeCount: 1)
    await menuModel.refresh()
    recordMenu("recovery")
    check("復原失敗時選單只允許復原與查看設定", !splitMenu.startItem.isEnabled && splitMenu.stopItem.isEnabled && splitMenu.settingsItem.isEnabled)
    await menuModel.stop()
    var capability = ExternalVPNStatus(phase: .active, message: "fixture active", interface: "en0", tunnel: "utun7", routeCount: 42, dnsMode: .preserveVPN)
    var stopNotified = false
    var stopAttempts = 0
    let dualModel = ExternalVPNController(preferences: preferences, autoRefresh: false) { operation, _ in
        var response = capability
        if operation == "restore" {
            stopAttempts += 1
            if stopAttempts == 1 { response.busy = true }
            else { response = .idle }
        }
        return (0, String(decoding: try! JSONEncoder().encode(response), as: UTF8.self))
    }
    dualModel.willStop = { stopNotified = true }
    await dualModel.refresh()
    check("舊 helper 無能力欄位時保持阻擋公司連線", !dualModel.canConnectCompany)
    capability.companyCapability = 1
    await dualModel.refresh()
    await settle { !dualModel.busy }
    check("新版 helper 加上 active 與沿用 DNS 才允許公司連線", dualModel.canConnectCompany)
    capability.companyState = .active
    await dualModel.refresh()
    let dualMenu = ExternalVPNMenu(model: dualModel, availability: { .init(helperReady: true, installing: false, companyBusy: true) }, openSettings: {})
    check("雙 VPN 停止選單明示會停止公司", dualMenu.stopItem.title.contains("停止公司 VPN"))
    capability.busy = true
    await dualModel.refresh()
    check("typed busy 保留 active 與路由數且阻擋新連線", dualModel.status.phase == .active && dualModel.status.routeCount == 42 && !dualModel.canConnectCompany)
    check("root 忙碌不撤銷持續性公司政策許可", dualModel.companyPolicyAllowsConnection)
    capability.busy = nil
    capability.dnsMode = .splitDomains
    await dualModel.refresh()
    check("依網域 DNS 模式不開放公司共存", !dualModel.canConnectCompany)
    capability.dnsMode = .preserveVPN
    capability.companyState = .recoveryRequired
    await dualModel.refresh()
    check("未清理的公司 lease 不允許再次連線", !dualModel.canConnectCompany)
    capability.companyState = nil
    capability.phase = .failed
    capability.canRetry = true
    await dualModel.refresh()
    check("分流失敗不視為獨立公司連線許可", !dualModel.companyPolicyAllowsConnection && !dualModel.canConnectCompany)
    await dualModel.stop()
    check("停止先取消重連意圖並等 root busy 後復原", stopNotified && stopAttempts == 2 && dualModel.status.phase == .idle)
    check("明確復原至閒置後恢復獨立公司連線許可", dualModel.companyPolicyAllowsConnection)
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("screenshots")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: menuEvidence, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("external-vpn-menu.json"))
    for (name, appearance) in [("external-vpn-light", NSAppearance.Name.aqua), ("external-vpn-recovery-dark", NSAppearance.Name.darkAqua), ("external-vpn-preserve-dns-dark", NSAppearance.Name.darkAqua)] {
        recovery = name.contains("recovery")
        await model.refresh()
        if name.contains("preserve") {
            window.contentViewController = NSHostingController(rootView: ExternalVPNTab(model: keepModel, helperReady: true, installing: false, fortiBusy: false, install: {})
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(NSSize(width: 620, height: 740))
        window.contentView?.frame = NSRect(x: 0, y: 0, width: 620, height: 740)
        await settle { window.contentView?.bounds.size == NSSize(width: 620, height: 740) }
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { check("原生畫面可擷取", false); continue }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
        check("原生頁面完成排版與截圖 \(name)", bitmap.pixelsWide >= 620 && bitmap.pixelsHigh >= 740)
    }
    await keepModel.stop()
    await model.stop()
    check("UI 測試完全使用假的系統傳輸", calls.allSatisfy { ["prepare", "tick", "restore", "status"].contains($0) })
    print("通過 \(passed)，失敗 \(failed)")
    return failed
}

do { exit(Int32(try await runExternalUI() == 0 ? 0 : 1)) }
catch { print("❌ \(error)"); print("通過 0，失敗 1"); exit(1) }
