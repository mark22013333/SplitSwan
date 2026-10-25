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
    print("通過 \(passed)，失敗 \(failed)")
    return failed
}
exit(Int32(try await runConfigurationTests() == 0 ? 0 : 1))
