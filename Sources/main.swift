// SplitSwan — 公司 VPN 狀態列 App（strongSwan 前端）
// 從「應用程式」點開時顯示主視窗；登入時自動啟動則只常駐狀態列。
import AppKit
import SwiftUI
import Combine


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let vpn = VPNController()
    private let env = EnvChecker()
    private let windowModel = WindowModel()
    private var window: NSWindow?
    private var bag = Set<AnyCancellable>()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "檢查中…", action: nil, keyEquivalent: "")
    private var connectItems: [NSMenuItem] = []
    private var disconnectItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildMenu()
        vpn.$state.combineLatest(vpn.$busy, vpn.$settings, vpn.$retryNote)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.renderMenu() }
            .store(in: &bag)
        vpn.$wantConnected.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderMenu() }
            .store(in: &bag)
        vpn.$history.receive(on: RunLoop.main)          // F4 閘道最近狀態
            .sink { [weak self] _ in self?.renderMenu() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .splitSwanShowWindow)
            .receive(on: RunLoop.main)
            .sink { [weak self] n in
                if let tab = n.object as? MainTab { self?.windowModel.tab = tab }
                self?.showWindow()
            }
            .store(in: &bag)
        // 連線紀錄在 App 內顯示（連線頁），啟動時就開始收，才看得到之前發生的事
        LogStore.shared.startStreaming()
        // 設定頁換了圖示樣式 → 立刻更新狀態列
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderMenu() }
            .store(in: &bag)
        // 升級時把既有設定檔換成目前版本的參數（例：縮短 DPD），有變更就讓 charon 重新載入
        if ConfigStore.migrateIfNeeded() { vpn.reloadConfig() }
        vpn.start()
        env.check()

        // 登入時自動啟動不跳視窗，其他情況（手動點開）跳視窗
        if !launchedAsLoginItem() { showWindow() }
    }

    /// 已在執行中又從 Finder／Launchpad 點一次 → 顯示視窗
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        LogStore.shared.stop()
    }

    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: 視窗

    @objc func showWindow() {
        if window == nil {
            let host = NSHostingController(rootView: MainView(vpn: vpn, env: env, window: windowModel))
            let w = NSWindow(contentViewController: host)
            w.title = AppInfo.name
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 600, height: 720))
            w.center()
            w.setFrameAutosaveName("SplitSwanMainWindow")   // 記住使用者調整過的大小與位置
            window = w
        }
        env.check()
        // 環境沒準備好就直接開環境檢查頁
        if vpn.state == .helperMissing { windowModel.tab = .environment }
        // 開發用：open SplitSwan.app --args -InitialTab settings|environment [-ShowLog YES] 直接開指定分頁（截圖檢查排版用）
        switch UserDefaults.standard.string(forKey: "InitialTab") {
        case "settings": windowModel.tab = .settings
        case "environment": windowModel.tab = .environment
        default: break
        }
        if UserDefaults.standard.bool(forKey: "ShowLog") { windowModel.showLog = true }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: 主選單

    /// 狀態列 App 沒有主選單，⌘C／⌘V／⌘A 等快捷鍵就送不到輸入框（快捷鍵是靠「編輯」選單派送的）。
    /// 這裡補一份不會顯示出來的主選單，視窗在前景時快捷鍵就能用
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "關閉視窗", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "結束 \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編輯")
        edit.addItem(NSMenuItem(title: "還原", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: 狀態列選單

    private func buildMenu() {
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let auto = NSMenuItem(title: "連線（自動輪替）", action: #selector(connect(_:)), keyEquivalent: "c")
        auto.representedObject = "auto"
        connectItems.append(auto)
        menu.addItem(auto)
        for i in 0..<3 {
            let item = NSMenuItem(title: "", action: #selector(connect(_:)), keyEquivalent: "")
            item.representedObject = "\(i + 1)"
            connectItems.append(item)
            menu.addItem(item)
        }
        disconnectItem = NSMenuItem(title: "斷線", action: #selector(disconnect), keyEquivalent: "d")
        menu.addItem(disconnectItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "開啟 \(AppInfo.name) 視窗…", action: #selector(showWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "查看連線紀錄…", action: #selector(openLog), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "結束 \(AppInfo.name)", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    private func renderMenu() {
        switch vpn.state {
        case .connected(let c, let ip):
            statusLine.title = "已連線：\(c.uppercased())  \(ip)"
        case .connecting(let c):
            statusLine.title = "連線中：\(c.uppercased())…"
        case .disconnected:
            statusLine.title = vpn.busy ? vpn.busyText : (vpn.retryNote ?? "未連線")
        case .helperMissing:
            statusLine.title = "系統元件未就緒，請開啟視窗檢查"
        }
        // 圖示樣式在設定頁選擇（MenuBarIcon）
        statusItem.button?.image = MenuBarIcon.image(style: MenuBarIcon.style,
                                                     state: MenuBarIcon.state(for: vpn.state, busy: vpn.busy),
                                                     colored: MenuBarIcon.colorConnected)

        let ready = !vpn.busy && vpn.state != .helperMissing
        let active = vpn.state.isConnected || vpn.state.isConnecting
        connectItems[0].isEnabled = ready && !active
        for i in 0..<3 {
            let item = connectItems[i + 1]
            // 附上最近狀態，例：「連線 VPN2（203.0.113.2） · 上次 3.2 秒連上」（F4）
            item.title = "連線 " + vpn.gatewayTitle(i) + (vpn.history.detail(i + 1).map { " · \($0)" } ?? "")
            item.isEnabled = ready && !active && !vpn.settings.gateways[i].isEmpty
        }
        // 斷線可以搶先執行中的連線（規格 §3.3）
        disconnectItem.title = vpn.state.isConnected ? "斷線" : "停止連線"
        disconnectItem.isEnabled = (active || vpn.wantConnected) && vpn.busyText != "斷線中…"
    }

    @objc private func connect(_ sender: NSMenuItem) {
        if let t = sender.representedObject as? String { vpn.connect(t) }
    }
    @objc private func disconnect() { vpn.disconnect() }
    @objc private func openLog() {
        windowModel.tab = .connection
        windowModel.showLog = true
        showWindow()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

// 程式進入點本來就在主執行緒，明確宣告給編譯器
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 只在狀態列，不出現在 Dock
    app.run()
}
