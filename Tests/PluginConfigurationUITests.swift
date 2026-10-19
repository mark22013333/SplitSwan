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
    print("通過 \(passed)，失敗 \(failed)")
    return failed
}
exit(Int32(try await runConfigurationTests() == 0 ? 0 : 1))
