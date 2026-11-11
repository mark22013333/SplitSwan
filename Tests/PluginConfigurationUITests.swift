import AppKit
import SwiftUI

// 使用真正的表單與原生控制項，資料與命令皆隔離，不碰使用者外掛或鑰匙圈。
@MainActor
func runConfigurationTests() async throws -> Int {
    typealias P = PluginSettingsProtocol
    var passed = 0, failed = 0
    func check(_ name: String, _ condition: Bool) {
        if condition { passed += 1 } else { failed += 1; print("❌ \(name)") }
    }
    func form(_ revision: String, _ state: String) throws -> P.Snapshot {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "title": "設定介面測試", "revision": revision,
            "tabs": [["id": "general", "title": "設定", "help": "隔離的表單測試。"]],
            "fields": [
                ["id": "url", "tab": "general", "title": "訂閱網址", "type": "secret"],
                ["id": "state", "tab": "general", "title": "狀態", "type": "readonly"],
                ["id": "names", "tab": "general", "title": "別名", "type": "stringList"],
                ["id": "keywords", "tab": "general", "title": "關鍵字", "type": "stringList"],
                ["id": "date", "tab": "general", "title": "日期", "type": "text"],
                ["id": "enabled", "tab": "general", "title": "啟用", "type": "toggle"]
            ],
            "values": ["url": "", "state": state, "names": ["測試使用者"], "keywords": ["休假"], "date": "2026-10-18", "enabled": false] as [String: Any],
            "actions": [["id": "test", "tab": "general", "title": "測試", "afterField": "date"]]
        ])
        return try P.decode(data)
    }
    var saved = try form("r1", "尚未設定")
    var storedSecret = "", testedSecret = "", revision = 1
    var rejectSave = false
    let command: @MainActor (String, P.Request?) async throws -> P.Snapshot = { operation, request in
        if operation == "save" {
            if rejectSave { throw P.Problem(message: "測試用儲存衝突") }
            guard request?.revision == saved.revision else { throw P.Problem(message: "修訂不符") }
            if let value = request?.values?["url"]?.text, !value.isEmpty { storedSecret = value }
            revision += 1
            saved = try form("r\(revision)", "已儲存")
        } else if operation == "action" { testedSecret = storedSecret }
        return saved
    }
    let model = PluginConfigurationModel(pluginID: "fixture", command: command)
    await model.load()
    model.draft["url"] = .text("https://example.com/first.ics")
    await model.save()
    check("首次儲存後清空輸入框，機密仍保留於提供者", !model.dirty && model.draft["url"] == .text("") && storedSecret.hasSuffix("first.ics"))
    model.draft["url"] = .text("https://example.com/cancelled.ics")
    await model.action(saved.actions[0])
    check("未儲存的替換網址不得被測試使用", testedSecret.isEmpty)
    model.error = "測試用舊錯誤"
    model.cancelEdits()
    check("取消替換保留原網址、清除暫存與舊錯誤", !model.dirty && model.draft["url"] == .text("") && storedSecret.hasSuffix("first.ics") && model.error == nil)
    model.draft["url"] = .text("https://example.com/replacement.ics")
    await model.save()
    await model.action(saved.actions[0])
    check("儲存後再次更換網址，測試使用新值", testedSecret.hasSuffix("replacement.ics") && model.draft["url"] == .text("") && !model.dirty)
    let reopened = PluginConfigurationModel(pluginID: "fixture", command: command)
    await reopened.load()
    check("重新開啟保留已儲存設定，機密不回顯且可再次編輯", reopened.snapshot?.revision == saved.revision && reopened.draft["url"] == .text(""))
    rejectSave = true
    model.draft["url"] = .text("https://example.com/rejected.ics")
    await model.save()
    check("儲存失敗保留草稿與既有值", model.dirty && model.error != nil && storedSecret.hasSuffix("replacement.ics"))
    model.cancelEdits()
    rejectSave = false
    var closeRequests = 0, confirmations = 0, discard = false
    model.requestClose = { closeRequests += 1 }
    model.confirmDiscard = { confirmations += 1; return discard }
    check("沒有變更時取消仍可用", model.canCancel)
    model.cancelAndClose()
    check("沒有變更時取消直接關閉視窗，不詢問", closeRequests == 1 && confirmations == 0 && !model.dirty)
    model.draft["url"] = .text("https://example.com/discarded.ics")
    model.cancelAndClose()
    check("有變更時取消先確認；選繼續編輯則保留草稿、不關閉", confirmations == 1 && closeRequests == 1 && model.dirty
          && model.draft["url"] == .text("https://example.com/discarded.ics"))
    discard = true
    model.cancelAndClose()
    check("確認捨棄後才捨棄草稿並關閉", confirmations == 2 && closeRequests == 2 && !model.dirty && storedSecret.hasSuffix("replacement.ics"))

    func guidedForm(job: String? = nil) throws -> P.Snapshot {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        object["tabs"] = [["id": "general", "title": "設定", "guide": [
            "summary": "完成目前步驟後再啟用。", "checkAction": "check", "refreshFields": ["names"], "managementActions": ["external", "import"],
            "steps": [
                ["id": "configure", "title": "填寫設定", "help": "儲存後檢查。", "state": "pending", "fields": ["names", "date"], "actions": ["test"], "primaryAction": "test", "saveTitle": "儲存並檢查"],
                ["id": "enable", "title": "啟用", "help": "最後自行啟用。", "state": "pending", "fields": ["enabled"], "actions": []]
            ]
        ]]]
        var actions = object["actions"] as! [[String: Any]]
        actions += [["id": "check", "tab": "general", "title": "重新檢查"],
                    ["id": "external", "tab": "general", "title": "開啟設定", "opensExternal": true],
                    ["id": "import", "tab": "general", "title": "匯入", "recheckAfter": true]]
        object["actions"] = actions
        if let job { object["job"] = ["id": "fixture", "state": job, "message": "隔離檢查"] }
        return try P.decode(JSONSerialization.data(withJSONObject: object))
    }
    var checks = 0, clock = Date(), checkRunning = false, finishCheck = false, keepRunning = false
    let guided = PluginConfigurationModel(pluginID: "guide-fixture", command: { operation, request in
        if operation == "action", request?.id == "check" { checks += 1; checkRunning = keepRunning }
        if operation == "snapshot", finishCheck { checkRunning = false }
        if operation == "save", let names = request?.values?["names"] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
            var values = object["values"] as! [String: Any]
            values["names"] = names.list
            object["values"] = values
            saved = try P.decode(JSONSerialization.data(withJSONObject: object))
        }
        return try guidedForm(job: checkRunning ? "running" : nil)
    }, now: { clock }, pollInterval: .milliseconds(20))
    await guided.load()
    await guided.enterTab("general")
    await guided.enterTab("general")
    check("精靈進入頁面自動檢查，30 秒內不重複查詢", checks == 1)
    clock = clock.addingTimeInterval(31)
    await guided.enterTab("general")
    check("冷卻結束後重新進入會再次檢查", checks == 2)
    guided.draft["names"] = .list(["尚未儲存"])
    await guided.checkCurrentTab(force: true)
    check("未儲存草稿延後檢查且保留輸入", checks == 2 && guided.checkDeferred && guided.dirty)
    await guided.save()
    check("儲存相關欄位後檢查一次，不被冷卻攔住", checks == 3 && !guided.dirty)
    guided.draft["enabled"] = .flag(true)
    await guided.save()
    check("儲存無關欄位不觸發額外查詢", checks == 3)
    await guided.action(guided.snapshot!.actions.first { $0.id == "external" }!)
    await guided.returnedFromExternal()
    await guided.returnedFromExternal()
    check("由外部設定返回僅檢查一次，一般視窗切換不觸發", checks == 4)
    await guided.action(guided.snapshot!.actions.first { $0.id == "import" }!)
    check("匯入操作後重新檢查", checks == 5)
    keepRunning = true
    await guided.checkCurrentTab(force: true)
    let inFlight = checks
    // 等待進度查詢可觀測條件，不以固定等待推定工作完成。
    let deadline = Date().addingTimeInterval(2)
    finishCheck = true
    while guided.snapshot?.job?.state == "running", Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    check("工作結束停止進度查詢，不會由 snapshot 自我觸發新檢查", guided.snapshot?.job == nil && checks == inFlight)
    guided.stop()
    await guided.checkCurrentTab(force: true)
    check("關閉後不執行自動檢查", checks == inFlight)
    var importStarted = false, failedImportChecks = 0
    let failingImport = PluginConfigurationModel(pluginID: "failed-import", command: { operation, request in
        if operation == "action", request?.id == "import" { importStarted = true; return try guidedForm(job: "running") }
        if operation == "action", request?.id == "check" { failedImportChecks += 1 }
        return try guidedForm(job: importStarted ? "failed" : nil)
    }, pollInterval: .milliseconds(20))
    await failingImport.load()
    failingImport.selectedTabID = "general"
    await failingImport.action(failingImport.snapshot!.actions.first { $0.id == "import" }!)
    let failureDeadline = Date().addingTimeInterval(2)
    while failingImport.snapshot?.job?.state == "running", Date() < failureDeadline { try? await Task.sleep(for: .milliseconds(10)) }
    check("匯入背景失敗保留錯誤，不接續檢查蓋掉原因", failingImport.snapshot?.job?.state == "failed" && failedImportChecks == 0)
    failingImport.stop()

    func layoutForm(job: (id: String, state: String)? = nil) throws -> P.Snapshot {
        var object: [String: Any] = [
            "version": 1, "title": "分組介面測試", "revision": "r1",
            "tabs": [
                ["id": "status", "title": "狀態",
                 "summary": ["eyebrow": "今天", "headline": "今天上班", "tone": "ok", "toggleField": "enabled", "metrics": []]],
                ["id": "settings", "title": "設定",
                 "groups": [["id": "account", "title": "帳號", "help": "隔離的說明。",
                             "rows": [["label": "請假日曆", "value": "已連接", "tone": "ok", "action": "manage"]],
                             "fields": ["user"], "actions": ["run"]],
                            ["id": "hours", "title": "時間", "fields": ["start"], "actions": []]]],
                ["id": "wizard", "title": "精靈", "hidden": true],
            ] as [[String: Any]],
            "fields": [
                ["id": "enabled", "tab": "status", "title": "背景執行", "type": "toggle"],
                ["id": "user", "tab": "settings", "title": "帳號", "type": "text"],
                ["id": "start", "tab": "settings", "title": "最早的開始上班時間", "type": "time"],
                ["id": "name", "tab": "wizard", "title": "名稱", "type": "text"],
            ],
            "values": ["enabled": false, "user": "example", "start": "08:30", "name": ""] as [String: Any],
            "actions": [
                ["id": "manage", "tab": "settings", "title": "管理…", "opensTab": "wizard"],
                ["id": "run", "tab": "settings", "title": "執行測試", "signsIn": true],
            ],
        ]
        if let job { object["job"] = ["id": job.id, "state": job.state, "message": "隔離工作：\(job.state)"] }
        return try P.decode(JSONSerialization.data(withJSONObject: object))
    }
    var layoutCalls: [String] = []
    var layoutJob: (id: String, state: String)?
    let fixedClock = Date(timeIntervalSince1970: 1_800_000_000)
    let layoutModel = PluginConfigurationModel(pluginID: "layout-fixture", command: { operation, request in
        layoutCalls.append(operation + (request?.id.map { ":" + $0 } ?? ""))
        if operation == "action", request?.id == "run" {
            layoutJob = (layoutJob?.id == "job-1" ? "job-2" : "job-1", "succeeded")
        }
        return try layoutForm(job: layoutJob)
    }, now: { fixedClock })
    await layoutModel.load()
    await layoutModel.enterTab("settings")
    layoutModel.draft["user"] = .text("尚未儲存")
    await layoutModel.action(layoutModel.snapshot!.actions.first { $0.id == "manage" }!)
    check("切到隱藏頁籤只在 App 內切換，不呼叫外掛、有草稿也可進入",
          layoutModel.selectedTabID == "wizard" && layoutModel.returnTabID == "settings" && layoutCalls == ["snapshot"] && layoutModel.dirty)
    layoutModel.returnFromHiddenTab()
    check("返回原本的可見頁籤", layoutModel.selectedTabID == "settings" && layoutModel.returnTabID == nil)
    layoutModel.cancelEdits()
    await layoutModel.action(layoutModel.snapshot!.actions.first { $0.id == "run" }!)
    let firstNotice = layoutModel.notice
    check("工作訊息帶觸發動作的標題與時間", firstNotice?.origin?.title == "執行測試" && firstNotice?.origin?.at == fixedClock
          && firstNotice?.job.id == "job-1")
    layoutModel.dismissNotice()
    check("關閉訊息後不再顯示同一工作", layoutModel.notice == nil)
    await layoutModel.action(layoutModel.snapshot!.actions.first { $0.id == "run" }!)
    check("新工作重新顯示訊息", layoutModel.notice?.job.id == "job-2" && layoutModel.notice?.origin?.title == "執行測試")
    await layoutModel.enterTab("status")
    check("切換頁籤時清掉已完成工作的訊息", layoutModel.notice == nil)
    layoutJob = ("job-3", "failed")
    await layoutModel.load()
    await layoutModel.enterTab("settings")
    check("失敗訊息切換頁籤後仍保留，未由此視窗觸發的工作不附標題",
          layoutModel.notice?.job.state == "failed" && layoutModel.notice?.origin == nil)
    layoutModel.stop()

    var openedJob: (id: String, state: String)? = ("earlier", "succeeded")
    let reopenedLayout = PluginConfigurationModel(pluginID: "reopened-fixture", command: { _, _ in try layoutForm(job: openedJob) })
    await reopenedLayout.load()
    await reopenedLayout.enterTab("status")
    check("開窗第一次進入頁籤保留先前成功的工作訊息", reopenedLayout.notice?.job.id == "earlier")
    await reopenedLayout.enterTab("status")
    check("重新進入同一頁籤不收起訊息", reopenedLayout.notice?.job.id == "earlier")
    await reopenedLayout.enterTab("settings")
    check("使用者切換頁籤才收起成功訊息", reopenedLayout.notice == nil)
    openedJob = nil
    reopenedLayout.stop()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentViewController: NSHostingController(rootView: PluginConfigurationView(model: model)))
    window.styleMask = [.titled, .closable, .resizable]
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderBack(nil)
    defer { window.orderOut(nil); model.stop(); reopened.stop() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func inputs() -> [NSTextField] {
        guard let root = window.contentView else { return [] }
        return descendants(root).compactMap { $0 as? NSTextField }.filter(\.isEditable)
    }
    func settle(_ ready: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
    }
    for size in [NSSize(width: 680, height: 560), NSSize(width: 780, height: 680), NSSize(width: 780, height: 886)] {
        window.setContentSize(size)
        await settle { inputs().count == 2 }
        let fields = inputs()
        check("\(Int(size.width))×\(Int(size.height)) 的網址及日期欄位保有可操作高度", fields.count == 2 && fields.allSatisfy { $0.bounds.height >= 22 && ($0.superview?.frame.height ?? 0) >= 22 && !$0.isHiddenOrHasHiddenAncestor })
    }
    model.draft["url"] = .text("https://example.com/after-layout.ics")
    await model.save()
    await settle { inputs().count == 2 && !model.busy }
    check("表單儲存並重新排版後，單行欄位仍可編輯", inputs().count == 2 && inputs().allSatisfy { $0.isEnabled && $0.bounds.height >= 22 && ($0.superview?.frame.height ?? 0) >= 22 })
    layoutJob = nil
    let groupedModel = PluginConfigurationModel(pluginID: "grouped-fixture", command: { _, _ in try layoutForm() })
    let groupedWindow = NSWindow(contentViewController: NSHostingController(rootView: PluginConfigurationView(model: groupedModel)))
    groupedWindow.styleMask = [.titled, .closable, .resizable]
    groupedWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    groupedWindow.setContentSize(NSSize(width: 780, height: 680))
    groupedWindow.orderBack(nil)
    defer { groupedWindow.orderOut(nil); groupedModel.stop() }
    func groupedViews() -> [NSView] { groupedWindow.contentView.map(descendants) ?? [] }
    var segments = 0
    for _ in 0..<150 {
        groupedWindow.contentView?.layoutSubtreeIfNeeded()
        segments = groupedViews().compactMap { $0 as? NSSegmentedControl }.first?.segmentCount ?? 0
        if segments > 0, groupedModel.selectedTabID == "status" { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    check("分段控制只列出可見頁籤", segments == 2)
    groupedModel.selectedTabID = "settings"
    var pickers: [NSDatePicker] = [], textInputs: [NSTextField] = []
    for _ in 0..<150 {
        groupedWindow.contentView?.layoutSubtreeIfNeeded()
        pickers = groupedViews().compactMap { $0 as? NSDatePicker }
        textInputs = groupedViews().compactMap { $0 as? NSTextField }.filter(\.isEditable)
        if !pickers.isEmpty, !textInputs.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    check("分組的時間欄位使用時間選擇器", pickers.count == 1 && pickers[0].bounds.width < 200)
    check("分組的短文字欄位不再全寬", textInputs.count == 1 && textInputs[0].bounds.width <= 330 && textInputs[0].bounds.height >= 22)
    func windowX(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: nil).minX }
    let columnGap = pickers.first.flatMap { p in textInputs.first.map { abs(windowX($0) - windowX(p)) } } ?? .infinity
    check("同一頁籤各分組的第二欄起點一致（差 \(columnGap)）", columnGap < 1)
    // 視窗內距 24、卡片內距 18、欄距 14；第二欄要排在最長標題之後，標題不被擠成兩行。
    let longest = ("最早的開始上班時間" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
    let columnStart = pickers.first.map(windowX) ?? 0
    check("共用欄寬容納同頁籤最長的標題（第二欄 \(columnStart)，需 ≥ \(24 + 18 + longest + 14)）", columnStart >= 24 + 18 + longest + 14 - 1)

    func manyTabsForm() throws -> P.Snapshot {
        let tabs = (1...8).map { ["id": "t\($0)", "title": "很長的頁籤標題第\($0)個"] }
        let fields = tabs.map { ["id": "f" + $0["id"]!, "tab": $0["id"]!, "title": "欄位", "type": "readonly"] }
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0["id"]!, "唯讀") })
        return try P.decode(JSONSerialization.data(withJSONObject: [
            "version": 1, "title": "頁籤過多", "revision": "r1", "tabs": tabs, "fields": fields, "values": values, "actions": [] as [Any]]))
    }
    let manyModel = PluginConfigurationModel(pluginID: "many-tabs", command: { _, _ in try manyTabsForm() })
    let manyWindow = NSWindow(contentViewController: NSHostingController(rootView: PluginConfigurationView(model: manyModel)))
    manyWindow.styleMask = [.titled, .closable, .resizable]
    manyWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    manyWindow.setContentSize(NSSize(width: 680, height: 560))
    manyWindow.orderBack(nil)
    defer { manyWindow.orderOut(nil); manyModel.stop() }
    var menus: [NSPopUpButton] = [], manySegments: [NSSegmentedControl] = []
    for _ in 0..<150 {
        manyWindow.contentView?.layoutSubtreeIfNeeded()
        let views = manyWindow.contentView.map(descendants) ?? []
        menus = views.compactMap { $0 as? NSPopUpButton }
        manySegments = views.compactMap { $0 as? NSSegmentedControl }
        if manyModel.selectedTabID == "t1", !menus.isEmpty || !manySegments.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    let contentWidth = manyWindow.contentView?.bounds.width ?? 0
    check("頁籤超出寬度時改用選單，不超出視窗", manySegments.isEmpty && menus.count == 1 && menus[0].numberOfItems == 8
          && windowX(menus[0]) >= 0 && windowX(menus[0]) + menus[0].bounds.width <= contentWidth)

    let fm = FileManager.default
    let lockedRoot = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("splitswan-locked-" + UUID().uuidString)
    let lockedPlugins = lockedRoot.appendingPathComponent("plugins")
    try fm.createDirectory(at: lockedPlugins, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: lockedRoot) }
    let script = lockedPlugins.appendingPathComponent("locked.1m.sh")
    try Data("#!/bin/bash\necho x\n".utf8).write(to: script)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let lockedRunner = PluginRunner(directory: lockedPlugins, stateRoot: lockedRoot.appendingPathComponent("state"),
                                    preferences: UserDefaults(suiteName: "SplitSwan.ConfigUITests." + UUID().uuidString)!)
    lockedRunner.scan()
    let lockedModel = PluginConfigurationModel(pluginID: "locked.1m.sh", command: { _, _ in try manyTabsForm() })
    let lockedWindow = NSWindow(contentViewController: NSHostingController(rootView: PluginConfigurationView(model: lockedModel, runner: lockedRunner)))
    lockedWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    lockedWindow.setContentSize(NSSize(width: 780, height: 680))
    lockedWindow.orderBack(nil)
    defer { lockedWindow.orderOut(nil); lockedModel.stop() }
    func switches() -> [NSControl] {
        (lockedWindow.contentView.map(descendants) ?? []).compactMap { $0 as? NSControl }
            .filter { String(describing: type(of: $0)).contains("Switch") && !$0.isHiddenOrHasHiddenAncestor }
    }
    for _ in 0..<150 where switches().isEmpty {
        lockedWindow.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
    }
    let lockedSwitch = switches().first
    check("外掛設定視窗顯示「鎖定時持續執行」開關，預設關閉", lockedRunner.plugins.count == 1 && lockedSwitch?.isEnabled == true
          && (lockedSwitch as? NSSwitch)?.state == .off)
    lockedSwitch?.performClick(nil)
    for _ in 0..<50 where lockedRunner.plugins.first?.runWhenLocked != true { try? await Task.sleep(for: .milliseconds(20)) }
    check("切換視窗內的開關立即寫入外掛的鎖定時設定", lockedRunner.plugins.first?.runWhenLocked == true)
    let plainWindow = NSWindow(contentViewController: NSHostingController(rootView: PluginConfigurationView(model: lockedModel)))
    plainWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    plainWindow.orderBack(nil)
    plainWindow.contentView?.layoutSubtreeIfNeeded()
    check("沒有 runner 時不顯示開關", !(plainWindow.contentView.map(descendants) ?? []).contains { String(describing: type(of: $0)).contains("Switch") })
    plainWindow.orderOut(nil)

    // MARK: 日期標記編輯器（日期與備註均為虛構）
    let screenshots = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("screenshots")
    try fm.createDirectory(at: screenshots, withIntermediateDirectories: true)
    func datesForm(_ revision: String, _ lines: [String], locked: String? = nil, dates: Bool = true, calendarTitle: String = "範例日曆") throws -> P.Snapshot {
        var field: [String: Any] = [
            "id": "overrides", "tab": "overrides", "title": "手動覆寫", "type": "stringList", "help": "每行一筆：YYYY-MM-DD work|off 備註。",
            "options": [["id": "work", "title": "上班"], ["id": "off", "title": "放假"]]]
        if dates {
            field["dates"] = [
                "today": "2026-11-06", "noteLimit": 20, "maxEntries": 400, "earliest": "2025-11-06", "latest": "2028-11-06",
                "locked": locked ?? NSNull(), "expiredHelp": "範例：近 45 天內的覆寫仍會影響近期紀錄。",
                "baseline": ["title": calendarTitle, "weekly": ["off", "work", "work", "work", "work", "work", "off"], "weeklyTitle": "週一至週五",
                             "known": ["from": "2026-01-01", "to": "2026-12-31"],
                             "days": [["date": "2026-11-20", "option": "off", "label": "範例節日"]]]] as [String: Any]
        }
        return try P.decode(JSONSerialization.data(withJSONObject: [
            "version": 1, "title": "日期標記測試", "revision": revision,
            "tabs": [["id": "overrides", "title": "手動覆寫", "help": "覆寫優先於範例日曆與週一至週五。"]],
            "fields": [field], "values": ["overrides": lines], "actions": [] as [Any]] as [String: Any]))
    }
    let initialLines = ["2026-10-30 off 颱風假", "2026-11-21 work 補上班", "2026-11-24 off 範例活動", "2026-11-25 off 範例活動"]
    var datesSaved = try datesForm("d1", initialLines)
    var datesSaves: [[String]] = []
    let datesModel = PluginConfigurationModel(pluginID: "dates-fixture", command: { operation, request in
        if operation == "save", let lines = request?.values?["overrides"]?.list {
            datesSaves.append(lines)
            datesSaved = try datesForm("d\(datesSaves.count + 1)", lines)
        }
        return datesSaved
    })
    // 視窗搬移、開關後，WindowServer 會非同步送來 windowMoved 等事件，HIToolbox 收到時會排一個 CFRunLoopStop(main)
    // 去喚醒 nextEvent。這支測試跑在 async main 的 CFRunLoopRun 而不是 NSApp.run，若事件剛好在 Task.sleep 期間到達，
    // 主迴圈會被停掉、程式以 0 離開且不印結果。所以每次動到視窗後，先在 nextEvent 迴圈裡把這些事件收完。
    func drainWindowEvents() {
        var quietUntil = Date().addingTimeInterval(0.5)
        let deadline = Date().addingTimeInterval(2)
        while Date() < quietUntil, Date() < deadline {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
                quietUntil = Date().addingTimeInterval(0.5)
            }
        }
    }
    func openWindow(_ m: PluginConfigurationModel, height: CGFloat = 1000) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: PluginConfigurationView(model: m)))
        w.styleMask = [.titled, .closable, .resizable]
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.setContentSize(NSSize(width: 780, height: height))
        w.orderBack(nil)
        drainWindowEvents()
        return w
    }
    func closeWindow(_ w: NSWindow, _ m: PluginConfigurationModel) {
        w.orderOut(nil)
        m.stop()
        drainWindowEvents()
    }
    func views(_ w: NSWindow) -> [NSView] { w.contentView.map(descendants) ?? [] }
    func datePickers(_ w: NSWindow) -> [NSDatePicker] { views(w).compactMap { $0 as? NSDatePicker }.filter { !$0.isHiddenOrHasHiddenAncestor } }
    func buttons(_ w: NSWindow) -> [NSButton] { views(w).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor } }
    func enabledButtons(_ w: NSWindow) -> Set<ObjectIdentifier> { Set(buttons(w).filter(\.isEnabled).map(ObjectIdentifier.init)) }
    func settleWindow(_ w: NSWindow, _ ready: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            w.contentView?.layoutSubtreeIfNeeded()
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
    }
    // 快取繪製不含視窗底色，深色模式下白字會畫在透明底上看不見，所以截圖固定用淺色外觀。
    func capture(_ w: NSWindow, _ name: String) {
        w.appearance = NSAppearance(named: .aqua)
        w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded()
        guard let content = w.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            print("⚠️ \(name) 截圖無法建立"); return
        }
        content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
        if (try? bitmap.representation(using: .png, properties: [:])?.write(to: screenshots.appendingPathComponent(name + ".png"))) == nil {
            print("⚠️ \(name) 截圖無法寫出")
        }
    }
    func pick(_ picker: NSDatePicker, _ text: String) {
        picker.dateValue = CalendarDay(text)!.date
        picker.sendAction(picker.action, to: picker.target)
    }

    let datesWindow = openWindow(datesModel)
    await settleWindow(datesWindow) { datePickers(datesWindow).count == 2 }
    check("有 dates 時出現月曆編輯器的「從／到」欄位，不是文字框",
          datePickers(datesWindow).count == 2 && !views(datesWindow).contains { $0 is NSTextView })
    check("「從／到」以 UTC 顯示，不受本機時區影響", datePickers(datesWindow).allSatisfy { $0.timeZone?.secondsFromGMT() == 0 })
    let noteFields = views(datesWindow).compactMap { $0 as? NSTextField }.filter(\.isEditable)
    if let noteField = noteFields.first, noteFields.count == 1 {
        datesWindow.makeFirstResponder(noteField)
        (noteField.currentEditor() as? NSTextView)?.insertText("員工旅遊", replacementRange: NSRange(location: 0, length: 0))
        await settleWindow(datesWindow) { noteField.stringValue == "員工旅遊" }
        let before = noteField.stringValue
        (noteField.currentEditor() as? NSTextView)?.insertText(String(repeating: "長", count: 17), replacementRange: NSRange(location: 4, length: 0))
        await settleWindow(datesWindow) { noteField.stringValue == before }
        check("備註到上限後無法再輸入、不截斷（輸入後仍為「\(noteField.stringValue)」）", noteField.stringValue == "員工旅遊")
        datesWindow.makeFirstResponder(nil)
    } else { check("備註欄位只有一個（實際 \(noteFields.count)）", false) }
    let beforeSelection = enabledButtons(datesWindow)
    let existingBeforeSelection = Set(buttons(datesWindow).map(ObjectIdentifier.init))
    let rangePickers = datePickers(datesWindow)
    pick(rangePickers[0], "2026-11-12")
    pick(rangePickers[1], "2026-11-09")
    await settleWindow(datesWindow) { enabledButtons(datesWindow).subtracting(beforeSelection).count == 1 }
    let newlyEnabled = buttons(datesWindow).filter { $0.isEnabled && !beforeSelection.contains(ObjectIdentifier($0)) }
    check("選取 11/09～11/12（起訖顛倒自動對調）後只多出可按的「套用」", newlyEnabled.count == 1 && !datesModel.dirty)
    newlyEnabled.first?.performClick(nil)
    let applied = ["2026-10-30 off 颱風假", "2026-11-09 off 員工旅遊", "2026-11-10 off 員工旅遊", "2026-11-11 off 員工旅遊",
                   "2026-11-12 off 員工旅遊", "2026-11-21 work 補上班", "2026-11-24 off 範例活動", "2026-11-25 off 範例活動"]
    await settleWindow(datesWindow) { datesModel.draft["overrides"]?.list == applied }
    check("套用後草稿是正規行，預設類型取原本判定的反向（上班 → 放假）", datesModel.draft["overrides"]?.list == applied && datesModel.dirty)
    // 套用前就存在、原本停用的按鈕只有「清除這幾天的覆寫」與視窗底部的「儲存」（位置最低）；清單新增的那段另有自己的展開與移除。
    let afterApply = buttons(datesWindow).filter { $0.isEnabled && existingBeforeSelection.contains(ObjectIdentifier($0)) && !beforeSelection.contains(ObjectIdentifier($0)) }
    func windowY(_ v: NSView) -> CGFloat { v.convert(v.bounds, to: nil).minY }
    let saveButton = afterApply.min { windowY($0) < windowY($1) }
    let clearButton = afterApply.first { $0 !== saveButton && $0 !== newlyEnabled.first }
    check("套用後「儲存」與「清除這幾天的覆寫」變成可按（實際 \(afterApply.count) 顆）", afterApply.count == 3 && saveButton != nil && clearButton != nil)
    clearButton?.performClick(nil)
    await settleWindow(datesWindow) { !datesModel.dirty }
    check("清除這幾天的覆寫後回到原本內容，不再有未儲存變更", datesModel.draft["overrides"]?.list == initialLines && !datesModel.dirty)
    newlyEnabled.first?.performClick(nil)
    await settleWindow(datesWindow) { datesModel.dirty && saveButton?.isEnabled == true }
    saveButton?.performClick(nil)
    await settleWindow(datesWindow) { datesSaves.count == 1 && !datesModel.dirty }
    check("按「儲存」送出正規行，草稿換成外掛回傳的值", datesSaves == [applied] && datesModel.snapshot?.revision == "d2"
          && datesModel.draft["overrides"]?.list == applied && !datesModel.dirty)
    capture(datesWindow, "date-marks-editor")
    func ids(_ list: [NSButton]) -> Set<ObjectIdentifier> { Set(list.map(ObjectIdentifier.init)) }
    func added(since before: Set<ObjectIdentifier>) -> [NSButton] { buttons(datesWindow).filter { !before.contains(ObjectIdentifier($0)) } }
    let singleModeButtons = ids(buttons(datesWindow))
    let repeatControl = views(datesWindow).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 && $0.label(forSegment: 1) == "每週" }
    repeatControl?.selectedSegment = 1
    if let repeatControl { repeatControl.sendAction(repeatControl.action, to: repeatControl.target) }
    await settleWindow(datesWindow) { added(since: singleModeButtons).count >= 7 }
    // 星期按鈕是切到每週後新出現、排在同一列的 7 顆，由左到右是日到六。
    let weekdayRow = Dictionary(grouping: added(since: singleModeButtons)) { Int(windowY($0)) }.values.first { $0.count == 7 }?
        .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX } ?? []
    check("切到「每週」後出現一列 7 顆星期按鈕", weekdayRow.count == 7 && datePickers(datesWindow).count == 2)
    if weekdayRow.count == 7 { weekdayRow[1].performClick(nil) }
    let weeklyPickers = datePickers(datesWindow)
    if weeklyPickers.count == 2 {
        pick(weeklyPickers[0], "2026-11-13")
        pick(weeklyPickers[1], "2026-11-30")
    }
    // 「套用」是備註欄正下方最近的那顆按鈕。
    let weeklyNote = views(datesWindow).compactMap { $0 as? NSTextField }.first(where: \.isEditable)
    func weeklyApplyButton() -> NSButton? {
        guard let weeklyNote else { return nil }
        return buttons(datesWindow).filter { windowY($0) < windowY(weeklyNote) }.max { windowY($0) < windowY($1) }
    }
    await settleWindow(datesWindow) { weeklyApplyButton()?.isEnabled == true }
    let weeklyApply = weeklyApplyButton()
    capture(datesWindow, "date-marks-weekly-preview")
    let beforeWeeklyApply = ids(buttons(datesWindow))
    weeklyApply?.performClick(nil)
    let weeklyApplied = (applied + ["2026-11-16 off 員工旅遊", "2026-11-23 off 員工旅遊"]).sorted()
    await settleWindow(datesWindow) { datesModel.draft["overrides"]?.list == weeklyApplied }
    check("每週一、11/13 起、結束日期 11/30：只寫入 11/16、11/23（11/30 當天不套用）",
          datesModel.draft["overrides"]?.list == weeklyApplied && datesModel.dirty)
    capture(datesWindow, "date-marks-weekly-applied")
    // 清單多出的每週列有「展開」與「移除」兩顆，移除在最右邊。
    let seriesButtons = added(since: beforeWeeklyApply).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    check("清單把 11/16、11/23 合成一列每週覆寫（新增按鈕 \(seriesButtons.count) 顆）", seriesButtons.count == 2)
    seriesButtons.last?.performClick(nil)
    await settleWindow(datesWindow) { datesModel.draft["overrides"]?.list == applied }
    check("按每週那列的「移除」一次刪掉整串，其他覆寫保留", datesModel.draft["overrides"]?.list == applied && !datesModel.dirty)
    let endControl = views(datesWindow).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 && $0.label(forSegment: 1) == "不限" }
    endControl?.selectedSegment = 1
    if let endControl { endControl.sendAction(endControl.action, to: endControl.target) }
    await settleWindow(datesWindow) { datePickers(datesWindow).count == 1 }
    check("結束改成「不限」後只剩開始日期", endControl != nil && datePickers(datesWindow).count == 1)
    await settleWindow(datesWindow) { weeklyApplyButton()?.isEnabled == true }
    capture(datesWindow, "date-marks-weekly-no-end")
    weeklyApplyButton()?.performClick(nil)
    await settleWindow(datesWindow) { (datesModel.draft["overrides"]?.list.count ?? 0) > applied.count }
    let noEndAdded = (datesModel.draft["overrides"]?.list ?? []).filter { !applied.contains($0) }
    check("不限：每週一從 11/16 寫到 2028/11/6 共 104 天（實際 \(noEndAdded.count) 天）",
          noEndAdded.count == 104 && noEndAdded.first == "2026-11-16 off 員工旅遊" && noEndAdded.last == "2028-11-06 off 員工旅遊")
    closeWindow(datesWindow, datesModel)

    let legacyDates = PluginConfigurationModel(pluginID: "dates-legacy", command: { _, _ in try datesForm("x1", initialLines, dates: false) })
    let legacyDatesWindow = openWindow(legacyDates, height: 600)
    await settleWindow(legacyDatesWindow) { views(legacyDatesWindow).contains { $0 is NSTextView } }
    let legacyEditor = views(legacyDatesWindow).compactMap { $0 as? NSTextView }.first
    check("沒有 dates 時仍是多行文字框", legacyEditor?.string == initialLines.joined(separator: "\n") && datePickers(legacyDatesWindow).isEmpty)
    capture(legacyDatesWindow, "date-marks-legacy")
    closeWindow(legacyDatesWindow, legacyDates)

    let lockedDates = PluginConfigurationModel(pluginID: "dates-locked", command: { _, _ in
        try datesForm("l1", initialLines, locked: "範例：覆寫檔權限不安全，請在終端機執行 chmod go-w 修正。")
    })
    let lockedDatesWindow = openWindow(lockedDates, height: 760)
    await settleWindow(lockedDatesWindow) { datePickers(lockedDatesWindow).count == 2 }
    check("locked 時「從／到」與備註都不可編輯", datePickers(lockedDatesWindow).count == 2
          && datePickers(lockedDatesWindow).allSatisfy { !$0.isEnabled }
          && views(lockedDatesWindow).compactMap { $0 as? NSTextField }.filter(\.isEditable).allSatisfy { !$0.isEnabled })
    for picker in datePickers(lockedDatesWindow) { pick(picker, "2026-11-10") }
    // 只按編輯器內的按鈕；視窗底部的「重新載入／取消／儲存」屬於視窗流程，不在這裡驗證。
    for button in buttons(lockedDatesWindow) where windowY(button) > 60 { button.performClick(nil) }
    await settleWindow(lockedDatesWindow) { !lockedDates.busy }
    check("locked 時仍可翻月瀏覽（按過上個月、下個月、今天後編輯器仍在）", datePickers(lockedDatesWindow).count == 2)
    check("locked 時按遍所有按鈕草稿仍不變", lockedDates.draft["overrides"]?.list == initialLines && !lockedDates.dirty)
    capture(lockedDatesWindow, "date-marks-locked")
    closeWindow(lockedDatesWindow, lockedDates)

    // 外掛給的 baseline 標題帶 bidi 反轉（U+202E）與控制字元（U+0007），選取區摘要畫出來前要先濾掉。
    let hostileSpec = try datesForm("h1", initialLines, calendarTitle: "範例\u{202E}日曆\u{0007}").fields[0].dates!
    let hostileMarks = try DateMarks(lines: [], optionIDs: ["work", "off"], spec: hostileSpec)
    let tenth = CalendarDay("2026-11-10")!
    let summary = DateMarksEditor.summaryText(hostileMarks, of: tenth...tenth, titles: ["work": "上班", "off": "放假"])
    check("選取區摘要濾掉外掛標題的控制與格式字元（實際 \(summary.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))）",
          summary == "原本：上班 1 天（範例日曆）")

    // MARK: 設定基準（欄位名稱均為虛構）
    var baselineOn = true, baselineConfigured = ["password"]
    func baselineForm() throws -> P.Snapshot {
        try P.decode(JSONSerialization.data(withJSONObject: [
            "version": 1, "title": "基準測試", "revision": "b1",
            "tabs": [["id": "general", "title": "一般"], ["id": "account", "title": "帳號", "hidden": true]],
            "fields": [["id": "enabled", "tab": "general", "title": "自動執行", "type": "toggle"],
                       ["id": "at", "tab": "general", "title": "時間", "type": "time"],
                       ["id": "password", "tab": "account", "title": "密碼", "type": "secret"]],
            "values": ["enabled": baselineOn, "at": "08:30", "password": ""] as [String: Any],
            "actions": [["id": "account-open", "tab": "general", "title": "帳號…", "opensTab": "account"]],
            "configured": baselineConfigured] as [String: Any]))
    }
    var storedBaseline: PluginSettingsBaseline.Record?
    var reported: [[PluginSettingsBaseline.Missing]] = []
    let baselineModel = PluginConfigurationModel(pluginID: "baseline-fixture", command: { _, _ in try baselineForm() },
        baselineStore: .init(load: { storedBaseline }, save: { storedBaseline = $0 }, report: { reported.append($0) }))
    // SwiftUI 按鈕沒有可讀的標題，所以照按鈕呼叫的模型方法操作，畫面以截圖留證。
    let baselineWindow = openWindow(baselineModel, height: 520)
    await settleWindow(baselineWindow) { baselineModel.snapshot != nil && !baselineModel.busy }
    check("沒有基準時不回報缺漏、也不寫檔", baselineModel.baseline == nil && storedBaseline == nil && baselineModel.baselineMissing.isEmpty)
    capture(baselineWindow, "baseline-none")
    await baselineModel.rememberBaseline()
    check("記住目前設定只收已設定的欄位", storedBaseline?.fields == ["enabled", "at", "password"] && reported.last == [])
    capture(baselineWindow, "baseline-remembered")
    baselineOn = false; baselineConfigured = []
    await baselineModel.load()
    check("少了設定時依欄位順序列出缺漏並回報選單（實際 \(baselineModel.baselineMissing.map(\.id))）",
          baselineModel.baselineMissing.map(\.id) == ["enabled", "password"] && reported.last?.map(\.id) == ["enabled", "password"]
          && storedBaseline?.fields == ["enabled", "at", "password"])
    capture(baselineWindow, "baseline-missing")
    if let hidden = baselineModel.baselineMissing.last { baselineModel.showMissing(hidden) }
    check("前往設定切到隱藏頁籤並可返回", baselineModel.selectedTabID == "account" && baselineModel.returnTabID == "general")
    baselineModel.returnFromHiddenTab()
    await baselineModel.acknowledgeMissing("enabled")
    check("這是刻意的：從基準移除該項並立即重算", storedBaseline?.fields == ["at", "password"]
          && baselineModel.baselineMissing.map(\.id) == ["password"] && reported.last?.map(\.id) == ["password"])
    capture(baselineWindow, "baseline-acknowledged")
    baselineOn = true; baselineConfigured = ["password"]
    await baselineModel.load()
    check("重新設定好後缺漏消失，且自動併回基準", baselineModel.baselineMissing.isEmpty && storedBaseline?.fields == ["enabled", "at", "password"])
    await baselineModel.clearBaseline()
    check("清除基準", storedBaseline == nil && baselineModel.baseline == nil && reported.last == [])
    await baselineModel.load()
    check("清除後重新載入不再回報、不再寫檔", storedBaseline == nil && baselineModel.baselineMissing.isEmpty)
    closeWindow(baselineWindow, baselineModel)

    print("通過 \(passed)，失敗 \(failed)")
    return failed
}
exit(Int32(try await runConfigurationTests() == 0 ? 0 : 1))
