import Combine
import Foundation
#if canImport(AppKit)
import AppKit
#endif
// 外掛區塊：PluginLogic 純邏輯＋PluginRunner 實跑假外掛的整合測試。
// 整合測試只在 argv[1]（run-tests.sh 給的暫存目錄）底下建立檔案，不碰 ~/.config/splitswan。
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
typealias L = PluginLogic
typealias Item = PluginLogic.Item
typealias M = PluginMenu

// MARK: 選單樹投影（AC-14）
let menuOutput = L.parseOutput("""
甲輸出
---
純文字
---
紅色動作 | color=red href=https://example.com/action
父項
--重新整理子項 | refresh=true
""")
let secondOutput = L.parseOutput("""
乙輸出
---
另一項
""")
let menuPlugins = [
    M.PluginSnapshot(id: "alpha.1m.sh", title: "甲外掛", output: .init(items: menuOutput.items)),
    M.PluginSnapshot(id: "beta.5m.sh", title: "乙外掛", output: .init(items: secondOutput.items)),
]

let menuOff = M.project(isActive: false, plugins: menuPlugins)
let offChildren = menuOff.root.children ?? []
check("選單樹：功能關閉仍只有單一啟用的「外掛」根節點",
      menuOff.root.title == "外掛" && menuOff.root.isEnabled && menuOff.root.command == nil
      && menuOff.root.style == .text(color: nil))
check("選單樹：功能關閉忽略外掛快照並顯示停用空狀態",
      offChildren.map(\.title) == ["外掛功能未啟用", "", "外掛設定…", "全部重新整理"]
      && !offChildren[0].isEnabled && offChildren[0].children == nil)
check("選單樹：功能關閉時底部設定可用、全部重新整理停用且命令 payload 正確",
      offChildren[1].style == .separator
      && offChildren[2].isEnabled && offChildren[2].command == .settings
      && !offChildren[3].isEnabled && offChildren[3].command == .refreshAll)

let menuEmpty = M.project(isActive: true, plugins: [])
let emptyChildren = menuEmpty.root.children ?? []
check("選單樹：功能啟用但零外掛時顯示停用空狀態、全部重新整理可用",
      menuEmpty.root.title == "外掛" && menuEmpty.root.isEnabled
      && emptyChildren.map(\.title) == ["沒有可用的外掛", "", "外掛設定…", "全部重新整理"]
      && !emptyChildren[0].isEnabled && emptyChildren[3].isEnabled && emptyChildren[3].command == .refreshAll)

let menuActive = M.project(isActive: true, plugins: menuPlugins)
let activeChildren = menuActive.root.children ?? []
check("選單樹：多外掛依快照順序各自建立子選單",
      activeChildren.prefix(2).map(\.title) == ["甲外掛", "乙外掛"]
      && activeChildren.prefix(2).allSatisfy { $0.isEnabled && $0.children != nil })
let alphaChildren = activeChildren.first?.children ?? []
check("選單樹：保留文字、分隔線、顏色與原輸出順序",
      alphaChildren.map(\.title) == ["純文字", "", "紅色動作", "父項"]
      && alphaChildren[0].style == .text(color: nil) && alphaChildren[0].command == nil
      && alphaChildren[1].style == .separator
      && alphaChildren[2].style == .text(color: "red"))
check("選單樹：動作與既有子項目保留原外掛 ID／原項目 payload",
      alphaChildren[2].command == .pluginAction(pluginID: "alpha.1m.sh", item: menuOutput.items[2])
      && alphaChildren[3].children?.map(\.title) == ["重新整理子項"]
      && alphaChildren[3].children?.first?.command
          == .pluginAction(pluginID: "alpha.1m.sh", item: menuOutput.items[3].children[0]))
check("選單樹：底部固定為分隔線、外掛設定、全部重新整理且 payload 正確",
      activeChildren.suffix(3).map(\.title) == ["", "外掛設定…", "全部重新整理"]
      && activeChildren[activeChildren.count - 3].style == .separator
      && activeChildren[activeChildren.count - 2].command == .settings
      && activeChildren.last?.command == .refreshAll && activeChildren.last?.isEnabled == true)

#if canImport(AppKit)
let stickyAdapter = MainActor.assumeIsolated {
    let root = M.rootItem(menuActive, target: NSObject(), action: Selector(("pluginAction:")))
    let plugin = root.submenu?.items.first
    let pluginItems = plugin?.submenu?.items ?? []
    let action = pluginItems.count > 2 ? pluginItems[2] : nil
    let settings = root.submenu?.items.dropLast().last
    guard let button = action?.view as? M.StickyActionButton else { return false }
    return action?.action == nil && button.isEnabled && button.toolTip == nil
        && button.frame.width >= M.StickyActionButton.minimumWidth
        && M.StickyActionButton.leadingInset == 28
        && button.normalTitleColor.isEqual(NSColor.systemRed)
        && settings?.view == nil && settings?.action != nil
}
check("AppKit：外掛動作保持選單、使用可點擊色彩與原生縮排且不顯示遮擋提示", stickyAdapter)
#endif

let menuRunning = M.project(isActive: true, plugins: [.init(id: "run.sh", title: "執行外掛")])
let runningChildren = menuRunning.root.children?.first?.children ?? []
check("選單樹：output nil 顯示停用的執行中狀態",
      runningChildren.count == 1 && runningChildren[0].title == "執行中…" && !runningChildren[0].isEnabled)

let menuNoOutput = M.project(isActive: true, plugins: [
    .init(id: "empty.sh", title: "空輸出", output: .init(items: [])),
])
let noOutputChildren = menuNoOutput.root.children?.first?.children ?? []
check("選單樹：已有輸出但無項目時顯示停用空狀態",
      noOutputChildren.count == 1 && noOutputChildren[0].title == "沒有可顯示的輸出"
      && !noOutputChildren[0].isEnabled)

let menuNoOutputAfterError = M.project(isActive: true, plugins: [
    .init(id: "empty-error.sh", title: "空輸出", actionError: "點擊原因", output: .init(items: [])),
])
let noOutputAfterErrorChildren = menuNoOutputAfterError.root.children?.first?.children ?? []
check("選單樹：空輸出已有點擊錯誤時只保留原因、不留孤立分隔線",
      noOutputAfterErrorChildren.count == 1 && noOutputAfterErrorChildren[0].title == "點擊原因"
      && noOutputAfterErrorChildren[0].style != .separator)

let menuEmptyTruncated = M.project(isActive: true, plugins: [
    .init(id: "empty-long.sh", title: "截斷輸出", output: .init(items: [], truncated: true)),
])
let emptyTruncatedChildren = menuEmptyTruncated.root.children?.first?.children ?? []
check("選單樹：無項目但已截斷時只顯示截斷提示",
      emptyTruncatedChildren.count == 1 && emptyTruncatedChildren[0].title == "（輸出過長，只顯示前面部分）")

let menuTruncated = M.project(isActive: true, plugins: [
    .init(id: "long.sh", title: "長輸出", output: .init(items: [L.parseLine("內容")], truncated: true)),
])
let truncatedChildren = menuTruncated.root.children?.first?.children ?? []
check("選單樹：截斷提示固定置於外掛輸出末端且停用",
      truncatedChildren.map(\.title) == ["內容", "（輸出過長，只顯示前面部分）"]
      && truncatedChildren.last?.isEnabled == false)

let menuBlocked = M.project(isActive: true, plugins: [
    .init(id: "alpha.1m.sh", title: "甲外掛", blockingError: "阻擋原因", actionError: "點擊原因",
          output: .init(items: menuOutput.items, truncated: true)),
])
let blockedPlugin = menuBlocked.root.children?.first
check("選單樹：阻擋錯誤優先於點擊錯誤與輸出，只顯示停用原因",
      blockedPlugin?.title == "甲外掛 ⚠︎" && blockedPlugin?.children?.count == 1
      && blockedPlugin?.children?.first?.title == "阻擋原因" && blockedPlugin?.children?.first?.isEnabled == false)

let menuActionFailed = M.project(isActive: true, plugins: [
    .init(id: "alpha.1m.sh", title: "甲外掛", actionError: "點擊原因", output: .init(items: menuOutput.items)),
])
let actionFailedPlugin = menuActionFailed.root.children?.first
let actionFailedChildren = actionFailedPlugin?.children ?? []
check("選單樹：點擊錯誤先顯示停用原因與分隔線，再保留上次成功輸出",
      actionFailedPlugin?.title == "甲外掛 ⚠︎"
      && actionFailedChildren.prefix(2).map(\.title) == ["點擊原因", ""]
      && actionFailedChildren.first?.isEnabled == false && actionFailedChildren[1].style == .separator
      && Array(actionFailedChildren.dropFirst(2)) == alphaChildren)

// MARK: 檔名與間隔
check("名稱.間隔.副檔名", L.parseFileName("punch.1m.sh") == L.FileName(name: "punch", interval: 60))
check("秒／時／天", L.parseFileName("a.30s.sh")?.interval == 30 && L.parseFileName("a.2h.py")?.interval == 7200
      && L.parseFileName("a.1d.rb")?.interval == 86400)
check("短於 30 秒當 30 秒", L.parseFileName("a.1s.sh")?.interval == 30 && L.parseFileName("a.10s.sh")?.interval == 30
      && L.parseFileName("a.0s.sh")?.interval == 30 && L.parseFileName("a.45s.sh")?.interval == 45)
check("timer 容許誤差：間隔 10%、至少 1 秒", L.timerTolerance(60) == 6 && L.timerTolerance(5) == 1 && L.timerTolerance(3600) == 360)
check("沒有間隔段用 5 分鐘", L.parseFileName("a.sh")?.interval == 300 && L.parseFileName("noext")?.interval == 300)
check("間隔格式錯誤用 5 分鐘", L.parseFileName("a.5x.sh")?.interval == 300 && L.parseFileName("a.m.sh")?.interval == 300
      && L.parseFileName("a.-5m.sh")?.interval == 300)
check("全形數字不算間隔", L.parseFileName("a.５m.sh")?.interval == 300)
check("過長數字不算間隔", L.parseFileName("a.9999999m.sh")?.interval == 300)
check("隱藏檔與空名稱回 nil", L.parseFileName(".hidden.1m.sh") == nil && L.parseFileName("") == nil)
check("間隔顯示文字", L.intervalText(60) == "1 分鐘" && L.intervalText(30) == "30 秒" && L.intervalText(7200) == "2 小時")

// MARK: 輸出解析
let sample = """
打卡
第二個 header 行要忽略
---
上班：未打卡 | color=red
開啟頁面 | href=https://example.com/punch
---
---
有子選單
--子項目一 | href="https://example.com/a b"
--子項目二
-----
--子項目三
 | color=red
帶引號 | bash="/Users/me/my plugins/x.sh" param1=mark param2="in now" refresh=true terminal=false

"""
let o = L.parseOutput(sample)
check("標題取第一行", o.title == "打卡")
check("項目數與分隔線（連續分隔線合併）", o.items.map { $0.isSeparator ? "---" : $0.text }
      == ["上班：未打卡", "開啟頁面", "---", "有子選單", "帶引號"])
check("color 參數", o.items[0].color == "red")
check("href 參數", o.items[1].href?.absoluteString == "https://example.com/punch")
check("子選單三項加一條分隔線", o.items[3].children.map { $0.isSeparator ? "---" : $0.text } == ["子項目一", "子項目二", "---", "子項目三"])
check("子選單 href 帶引號含空白（URL 無效則忽略）", o.items[3].children[0].params["href"] == "https://example.com/a b")
check("空字串項目略過", !o.items.contains { !$0.isSeparator && $0.text.isEmpty })
check("引號內含空白的 bash 路徑", o.items[4].bash == "/Users/me/my plugins/x.sh")
check("param1…param9 依序", o.items[4].bashArgs == ["mark", "in now"])
check("refresh=true", o.items[4].refresh)
check("不支援的參數保留但不影響（terminal）", o.items[4].params["terminal"] == "false")
check("沒有 --- 時只有標題", L.parseOutput("只有標題\n第二行").items.isEmpty && L.parseOutput("只有標題\n第二行").title == "只有標題")
check("\\r\\n 行尾", L.parseOutput("T\r\n---\r\nA\r\n").items.map(\.text) == ["A"])
check("沒有上一項的子選單略過", L.parseOutput("T\n---\n--孤兒\nA").items.map(\.text) == ["A"])
check("標題帶參數時只取文字", L.parseOutput("標題 | color=red\n---\nA").title == "標題")
check("參數：沒有 = 的片段與非法鍵略過", L.parseParams(" foo href=https://x.example a-b=1 =v k=") == ["href": "https://x.example", "k": ""])
check("參數：引號沒結尾就吃到行尾", L.parseParams("k=\"a b") == ["k": "a b"])

// 截斷：輸出超過 64 KB
let bigLine = String(repeating: "x", count: 1000)
let big = "T\n---\n" + (0..<100).map { "\($0)-\(bigLine)" }.joined(separator: "\n")
let ob = L.parseOutput(big)
check("超過 64 KB 標記截斷", ob.truncated)
check("超過 30 項只留 30 項", ob.items.count == L.maxItems)
let many = "T\n---\n" + (1...40).map { "第\($0)項" }.joined(separator: "\n")
let om = L.parseOutput(many)
check("40 項 → 30 項且標記截斷", om.items.count == 30 && om.truncated && om.items.last?.text == "第30項")
check("剛好 30 項不算截斷", !L.parseOutput("T\n---\n" + (1...30).map { "第\($0)項" }.joined(separator: "\n") + "\n\n").truncated)
func outputNodeCount(_ items: [Item]) -> Int {
    items.reduce(0) { $0 + 1 + outputNodeCount($1.children) }
}
let childSeparatorOrder = L.parseOutput("""
T
---
---
Parent
-- ---
--A
-- ---
-- ---
--B
-- ---
---
""")
check("子分隔線：忽略開頭、連續與尾端，保留正常順序",
      childSeparatorOrder.items.count == 1
      && childSeparatorOrder.items[0].children.map { $0.isSeparator ? "---" : $0.text } == ["A", "---", "B"]
      && !childSeparatorOrder.truncated)
let manyChildSeparators = "T\n---\nParent\n" + (1...40)
    .flatMap { ["--子\($0)", "-- ---"] }
    .joined(separator: "\n")
let childSeparatorLimit = L.parseOutput(manyChildSeparators)
let childSeparatorNodeCount = outputNodeCount(childSeparatorLimit.items)
check("大量子分隔線：遞迴節點受 30 項上限約束且標記截斷",
      childSeparatorNodeCount <= L.maxItems && childSeparatorLimit.truncated
      && childSeparatorLimit.items.first?.children.last?.isSeparator == false)
let longText = String(repeating: "長", count: 500)
check("單一項目文字過長截短", (L.parseOutput("T\n---\n" + longText).items.first?.text.count ?? 0) <= L.maxTextLength + 1)
// 64 KB 截斷不能切壞多位元組字元：每行 3 bytes 的中文
let cjk = "T\n---\n" + (0..<30000).map { _ in "中" }.joined(separator: "\n")
let oc = L.parseOutput(cjk)
check("多位元組輸出截斷後仍可解析", oc.truncated && oc.items.allSatisfy { $0.text == "中" })

// MARK: href／bash／顏色驗證
check("href：http、https 接受", L.safeURL("http://example.com") != nil && L.safeURL("HTTPS://example.com/x?y=1") != nil)
check("href：javascript、file、自訂 scheme 拒絕", L.safeURL("javascript:alert(1)") == nil && L.safeURL("file:///etc/passwd") == nil
      && L.safeURL("x-apple.systempreferences:foo") == nil && L.safeURL("ssh://host") == nil)
check("href：沒有主機、相對路徑拒絕", L.safeURL("https://") == nil && L.safeURL("/local/path") == nil && L.safeURL("example.com") == nil)
check("Item.href 經過驗證", L.parseLine("x | href=file:///etc/hosts").href == nil)
check("bash：絕對路徑接受", L.absolutePath("/Users/me/a.sh") == "/Users/me/a.sh")
check("bash：相對路徑、~、空字串、根目錄拒絕", L.absolutePath("a.sh") == nil && L.absolutePath("~/a.sh") == nil
      && L.absolutePath("") == nil && L.absolutePath("/") == nil && L.absolutePath("./a.sh") == nil)
check("Item.bash 經過驗證", L.parseLine("x | bash=rm").bash == nil && L.parseLine("x | bash=/bin/echo").bash == "/bin/echo")
check("顏色：具名與 #RRGGBB", L.normalizedColor("RED") == "red" && L.normalizedColor("#FF8800") == "#ff8800" && L.normalizedColor("grey") == "gray")
check("顏色：其他一律忽略", L.normalizedColor("#fff") == nil && L.normalizedColor("purple") == nil && L.normalizedColor("#gg0000") == nil)
check("#RRGGBB 轉 rgb", L.rgb("#ff0000").map { $0.0 == 1 && $0.1 == 0 && $0.2 == 0 } == true)

// MARK: notify
let n1 = L.parseLine("該上班打卡了 | notify=true notify_id=in-1 href=https://example.com/punch")
check("notify=true 與 notify_id", n1.notify && n1.notifyKey == "in-1")
check("沒有 notify_id 用該行文字", L.parseLine("別忘了 | notify=true").notifyKey == "別忘了")
check("notify 不是 true 就不發", !L.parseLine("x | notify=yes").notify)

// MARK: 通知每日去重
func nItem(_ id: String) -> Item { L.parseLine("訊息 \(id) | notify=true notify_id=\(id)") }
var plan = L.planNotifications([nItem("in-1")], today: "2026-10-09", log: L.NotifyLog())
check("今天沒發過 → 發", plan.send.map(\.notifyKey) == ["in-1"] && plan.log.keys == ["in-1"])
var log = plan.log
check("同一天同一鍵 → 不發", L.planNotifications([nItem("in-1")], today: "2026-10-09", log: log).send.isEmpty)
check("同一天不同鍵 → 發", L.planNotifications([nItem("in-2")], today: "2026-10-09", log: log).send.count == 1)
let next = L.planNotifications([nItem("in-1")], today: "2026-10-10", log: log)
check("隔天同一鍵 → 發，紀錄只保留當天", next.send.count == 1 && next.log.day == "2026-10-10" && next.log.keys == ["in-1"])
check("同一次輸出重複的鍵只發一次", L.planNotifications([nItem("a"), nItem("a")], today: "d", log: L.NotifyLog()).send.count == 1)
let five = L.planNotifications((1...5).map { nItem("k\($0)") }, today: "d", log: L.NotifyLog())
check("每次執行最多發 3 則，其餘不記錄（下次再發）", five.send.count == 3 && five.log.keys.count == 3)
check("下次執行補發剩下的", L.planNotifications((1...5).map { nItem("k\($0)") }, today: "d", log: five.log).send.map(\.notifyKey) == ["k4", "k5"])
check("沒有 notify=true 的行不發", L.planNotifications([L.parseLine("x | notify_id=a")], today: "d", log: L.NotifyLog()).send.isEmpty)
// 濫發：每次換 30 個新 id、30 秒一次跑 6 小時（資安探針情境）
var flood = L.NotifyLog(), floodSent = 0, floodCapped = false
for run in 0..<720 {
    let p = L.planNotifications((0..<30).map { nItem("r\(run)-\($0)-" + String(repeating: "x", count: 64)) }, today: "d", log: flood)
    floodSent += p.send.count; flood = p.log; floodCapped = p.capped
}
let floodBytes = (try? JSONEncoder().encode(flood))?.count ?? 0
check("濫發 6 小時：總共只發 \(floodSent) 則（≤ 20）、達上限標記 capped", floodSent == L.maxNotifyKeysPerDay && floodCapped)
check("去重紀錄有界：\(flood.keys.count) 個鍵、\(floodBytes) bytes", flood.keys.count == L.maxNotifyKeysPerDay && floodBytes < 4096)
check("正對照：未達上限時 capped 為 false", !L.planNotifications([nItem("a")], today: "d", log: L.NotifyLog()).capped)
let longKey = L.parseLine("x | notify=true notify_id=" + String(repeating: "k", count: 60000)).notifyKey
check("notify_id 超過 64 字元改用雜湊（長度 \(longKey.count)）", longKey.count <= 64 && longKey.hasPrefix("#"))
check("64 字元以內原樣保留", L.parseLine("x | notify=true notify_id=" + String(repeating: "k", count: 64)).notifyKey.count == 64)
check("不同的長 id 雜湊不同", L.parseLine("x | notify_id=" + String(repeating: "a", count: 100)).notifyKey
      != L.parseLine("x | notify_id=" + String(repeating: "b", count: 100)).notifyKey)

// MARK: 文字過濾與長度上限（L3、L4）
let ctl = L.parseOutput("T\u{202E}x\n---\nA\rB 結束\nX\u{2028}Y\u{2029}Z\u{85}W\nN\u{0}UL\n\u{202E}moc.elppa\u{202C}\n\u{1B}[31mesc\n\u{2066}iso\u{2069}\n")
let allScalars = ([ctl.title] + ctl.items.map(\.text)).flatMap { $0.unicodeScalars }
check("控制／格式／分隔字元全部移除", !allScalars.contains { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) })
check("移除後的文字", ctl.items.map(\.text) == ["AB 結束", "XYZW", "NUL", "moc.elppa", "[31mesc", "iso"] && ctl.title == "Tx")
let zal = L.parseOutput("T\n---\nZ" + String(repeating: "\u{0301}", count: 30000)).items[0].text
check("單一字元帶 3 萬個組合符號：截到 \(zal.utf8.count) bytes", zal.utf8.count <= L.maxTextBytes + 3)
check("組合 emoji（ZWJ）與旗幟（tag 字元）保留", L.sanitize("👨\u{200D}💻") == "👨\u{200D}💻"
      && L.sanitize("🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}") == "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}")
check("U+202E、U+200E、U+2066 仍被濾掉", L.sanitize("a\u{202E}b\u{200E}c\u{2066}d") == "abcd")
check("檔名含控制字元不當外掛", L.parseFileName("a\u{202E}.1m.sh") == nil && L.parseFileName("a\r.1m.sh") == nil)

var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
check("本地日期字串", L.dayString(Date(timeIntervalSince1970: 1_791_475_200), calendar: cal) == "2026-10-09")  // 2026-10-08 16:00 UTC

// MARK: 權限判斷
typealias FS = L.FileStat
let me: UInt32 = 501
let dirOK = FS(uid: me, mode: 0o040700), fileOK = FS(uid: me, mode: 0o100700)
check("自己的 700 資料夾＋700 檔案 → 可執行", L.permissionProblem(file: fileOK, dir: dirOK, uid: me) == nil)
check("755 檔案也可以（group／other 不可寫即可）", L.permissionProblem(file: FS(uid: me, mode: 0o100755), dir: FS(uid: me, mode: 0o040755), uid: me) == nil)
check("檔案 group 可寫 → 拒絕", L.permissionProblem(file: FS(uid: me, mode: 0o100775), dir: dirOK, uid: me)?.contains("其他使用者寫入") == true)
check("檔案 other 可寫 → 拒絕", L.permissionProblem(file: FS(uid: me, mode: 0o100702), dir: dirOK, uid: me) != nil)
check("資料夾 group 可寫 → 拒絕", L.permissionProblem(file: fileOK, dir: FS(uid: me, mode: 0o040770), uid: me)?.contains("資料夾") == true)
check("檔案屬於別人 → 拒絕", L.permissionProblem(file: FS(uid: 0, mode: 0o100755), dir: dirOK, uid: me)?.contains("不屬於") == true)
check("資料夾屬於別人 → 拒絕", L.permissionProblem(file: fileOK, dir: FS(uid: 0, mode: 0o040755), uid: me) != nil)
check("不可執行 → 拒絕", L.permissionProblem(file: FS(uid: me, mode: 0o100600), dir: dirOK, uid: me)?.contains("不可執行") == true)
check("不是一般檔案 → 拒絕", L.permissionProblem(file: FS(uid: me, mode: 0o040700), dir: dirOK, uid: me) != nil)
check("找不到 → 拒絕", L.permissionProblem(file: nil, dir: dirOK, uid: me) != nil && L.permissionProblem(file: fileOK, dir: nil, uid: me) != nil)

// MARK: 正對照：故意餵錯誤的輸入，確認上面的比對方式抓得到差異
let wrong = L.parseOutput("打卡\n上班：未打卡 | color=red\n---")     // --- 放錯位置：項目被當成 header
check("正對照：--- 放錯位置時解析結果與正確輸出不同", wrong.items.map(\.text) != ["上班：未打卡"])
check("正對照：錯誤參數格式得不到 href", L.parseLine("A | href = https://example.com").href == nil)
check("正對照：權限判斷對 777 檔案不會回 nil", L.permissionProblem(file: FS(uid: me, mode: 0o100777), dir: dirOK, uid: me) != nil)

// MARK: href 帳密、bash= 位置限制
check("href：含帳密的網址拒絕", L.safeURL("https://user:pw@example.com/") == nil && L.safeURL("https://user@example.com/") == nil
      && L.safeURL("http://example.com@evil.example/") == nil)
check("href：一般網址（含 @ 在路徑）仍接受", L.safeURL("https://example.com/a@b") != nil)
let pd = "/Users/me/.config/splitswan/plugins"
check("bash=：外掛本身接受", L.bashTargetProblem(resolved: pd + "/a.1m.sh", pluginSelf: pd + "/a.1m.sh") == nil)
check("bash=：外掛資料夾內的其他檔案也拒絕", L.bashTargetProblem(resolved: pd + "/lib/h.sh", pluginSelf: pd + "/a.1m.sh") != nil
      && L.bashTargetProblem(resolved: pd + "/b.1m.sh", pluginSelf: pd + "/a.1m.sh") != nil)
check("bash=：/bin/sh、Homebrew 直譯器拒絕", L.bashTargetProblem(resolved: "/bin/sh", pluginSelf: pd + "/a.sh") != nil
      && L.bashTargetProblem(resolved: "/opt/homebrew/Cellar/python@3.14/3.14.7/bin/python3.14", pluginSelf: pd + "/a.sh") != nil)
check("bash=：不知道外掛本身時一律拒絕", L.bashTargetProblem(resolved: pd + "/a.sh", pluginSelf: nil) != nil)
check("上層資料夾：自己或 root、不可被他人寫入（sticky 例外）",
      L.ancestorProblem(FS(uid: 0, mode: 0o040755), path: "/", uid: me) == nil
      && L.ancestorProblem(FS(uid: 0, mode: 0o041777), path: "/tmp", uid: me) == nil
      && L.ancestorProblem(FS(uid: me, mode: 0o040750), path: "~", uid: me) == nil
      && L.ancestorProblem(FS(uid: me, mode: 0o040775), path: "x", uid: me) != nil
      && L.ancestorProblem(FS(uid: 502, mode: 0o040700), path: "x", uid: me) != nil
      && L.ancestorProblem(nil, path: "x", uid: me) != nil)

// MARK: 整合測試：實跑假外掛
// 時序原則（本機常有防毒掃描新執行檔、Spotlight 索引，負載平均可達上百）：
// - 「某事應該發生」一律用 eventually 輪詢到成立為止，期限寬鬆；正常負載下條件一成立就往下走，不增加耗時。
// - 「某事不應該發生」只能固定觀察一段時間，但取樣前要先確認進行中的事已經開始（或已經結束）。
// - 外掛 timeout 一律遠大於腳本實際執行時間；只有專門驗證逾時的測試用短 timeout，且腳本確實會卡住。
/// 每 50ms 檢查一次條件，成立立刻回 true；超過 timeout 秒仍不成立回 false（呼叫端照常斷言，不會卡死）
@MainActor func eventually(_ timeout: Double = 15, _ cond: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}
/// 足夠讓高負載下的短腳本跑完的外掛 timeout（不是驗證逾時用）
let roomyTimeout: TimeInterval = 60
let base = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
let root = base + "/plugin-it-\(getpid())"
let fm = FileManager.default
let pdir = root + "/plugins", sdir = root + "/state"
try! fm.createDirectory(atPath: pdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
func put(_ name: String, _ body: String, mode: Int = 0o700, dir: String = pdir) {
    let p = dir + "/" + name
    try! body.write(toFile: p, atomically: false, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: mode], ofItemAtPath: p)
}
// 測試程序自己的環境變數不可傳給外掛
setenv("SPLITSWAN_TEST_SECRET", "should-not-leak", 1)
put("good.1m.sh", """
#!/bin/bash
echo "正常外掛"
echo "---"
echo "state=$SPLITSWAN_PLUGIN_STATE"
echo "flag=$SPLITSWAN path=$PATH"
echo "secret=${SPLITSWAN_TEST_SECRET:-none}"
echo "提醒 | notify=true notify_id=r1 href=https://example.com/punch"
[ -f "$SPLITSWAN_PLUGIN_STATE/marked" ] && echo "已標記"
echo "標記 | bash=$0 param1=mark refresh=true"
if [ "$1" = mark ]; then date > "$SPLITSWAN_PLUGIN_STATE/marked"; fi
echo "錯誤輸出" >&2
""")
put("writable.1m.sh", "#!/bin/bash\necho 不應該執行\ntouch \"$SPLITSWAN_PLUGIN_STATE/ran\"\n", mode: 0o770)
put("bad.1m.sh", "#!/bin/bash\necho 壞掉的原因 >&2\nexit 3\n")
put("notexec.1m.sh", "#!/bin/bash\necho x\n", mode: 0o600)
put(".hidden.1m.sh", "#!/bin/bash\necho x\n")
try! fm.createDirectory(atPath: pdir + "/subdir.1m.sh", withIntermediateDirectories: false)
// symlink 指向 group 可寫資料夾裡的腳本 → 依解析後的目標判斷，要被拒
let loose = root + "/loose"
try! fm.createDirectory(atPath: loose, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o770])
try! fm.setAttributes([.posixPermissions: 0o770], ofItemAtPath: loose)
put("target.sh", "#!/bin/bash\necho x\n", dir: loose)
try! fm.createSymbolicLink(atPath: pdir + "/linked.1m.sh", withDestinationPath: loose + "/target.sh")

var sent: [(String, String?, String, URL?)] = []
let runner = PluginRunner(directory: URL(fileURLWithPath: pdir), stateRoot: URL(fileURLWithPath: sdir),
                          allowInactiveExecution: true)
// 一般外掛用寬鬆 timeout（高負載下 bash 啟動加防毒掃描可能就要好幾秒）；逾時另外用 slowRunner 驗
runner.timeout = roomyTimeout
runner.notifier = { t, st, b, h in sent.append((t, st, b, h)) }
await runner.refreshAll()
@MainActor func plugin(_ id: String) -> PluginRunner.Plugin? { runner.plugins.first { $0.id == id } }

check("掃描：只列可執行一般檔案（略過隱藏、不可執行、子目錄）",
      Set(runner.plugins.map(\.id)) == ["bad.1m.sh", "good.1m.sh", "linked.1m.sh", "writable.1m.sh"])
let good = plugin("good.1m.sh")
check("正常外掛解析成功", good?.failure == nil && good?.output?.title == "正常外掛")
let texts = good?.output?.items.map(\.text) ?? []
check("SPLITSWAN_PLUGIN_STATE 指向 state/<完整檔名>", texts.contains("state=" + sdir + "/good.1m.sh"))
check("SPLITSWAN=1 與固定 PATH", texts.contains("flag=1 path=" + PluginRunner.pluginPATH))
check("App 的其他環境變數不會傳給外掛", texts.contains("secret=none"))
check("stderr 不混進輸出", !texts.contains("錯誤輸出"))
check("狀態資料夾權限 700", (try? fm.attributesOfItem(atPath: sdir + "/good.1m.sh")[.posixPermissions] as? Int) == 0o700)
let w = plugin("writable.1m.sh")
check("group 可寫的外掛被拒且沒有執行", w?.problem?.contains("其他使用者寫入") == true && runner.lastRuns["writable.1m.sh"] == nil
      && !fm.fileExists(atPath: sdir + "/writable.1m.sh/ran"))
check("symlink 依解析後目標檢查：所在資料夾 group 可寫被拒", plugin("linked.1m.sh")?.problem?.contains("資料夾") == true)
check("非 0 結束標錯誤並附 stderr 最後一行", plugin("bad.1m.sh")?.error == "結束碼 3：壞掉的原因")
// 逾時：腳本 sleep 30 一定會卡住，timeout 2 秒；整體耗時遠小於 30 秒即代表沒有等腳本自己結束
let slowDir = root + "/slowdir"
try! fm.createDirectory(atPath: slowDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
put("slow.10s.sh", "#!/bin/bash\necho 慢\nsleep 30\n", dir: slowDir)
let slowRunner = PluginRunner(directory: URL(fileURLWithPath: slowDir), stateRoot: URL(fileURLWithPath: sdir),
                              allowInactiveExecution: true)
slowRunner.timeout = 2
let t0 = Date()
await slowRunner.refreshAll()
let elapsed = Date().timeIntervalSince(t0)
let slow = slowRunner.plugins.first { $0.id == "slow.10s.sh" }
check("逾時外掛標錯誤（\(slow?.error ?? "nil")）", slow?.error?.contains("逾時") == true && slow?.output == nil)
check("逾時不會拖住整體（沒等 sleep 30 結束，實際 \(String(format: "%.1f", elapsed)) 秒）", elapsed < 20)
check("間隔解析：slow.10s 拉高到 30 秒", slow?.interval == 30)
check("notify：發出一則，標題固定「外掛：good」、輸出標題只放副標題、帶 href", sent.count == 1 && sent.first?.0 == "外掛：good"
      && sent.first?.1 == "正常外掛" && sent.first?.2 == "提醒" && sent.first?.3?.absoluteString == "https://example.com/punch")
await runner.run("good.1m.sh")
check("同一天再跑一次不重複通知", sent.count == 1)
let notifiedFile = sdir + "/.notified/good.1m.sh.json"
// 紀錄檔在背景寫入（先寫暫存檔再改名、最後改權限），等到權限也到位
_ = await eventually { (try? fm.attributesOfItem(atPath: notifiedFile)[.posixPermissions] as? Int) == 0o600 }
check("每個外掛一份通知紀錄，600", (try? fm.attributesOfItem(atPath: notifiedFile)[.posixPermissions] as? Int) == 0o600)
// 換一個新的 runner（模擬 App 重新啟動）：從檔案讀回紀錄，仍不重複
let runner2 = PluginRunner(directory: URL(fileURLWithPath: pdir), stateRoot: URL(fileURLWithPath: sdir),
                           allowInactiveExecution: true)
runner2.timeout = roomyTimeout
var sent2 = 0
runner2.notifier = { _, _, _, _ in sent2 += 1 }
runner2.scan()
await runner2.run("good.1m.sh")
check("重新啟動後讀回去重紀錄", sent2 == 0)

// 點擊動作：bash=$0 param1=mark refresh=true → 執行外掛自己並重跑
if let mark = good?.output?.items.first(where: { $0.text == "標記" }) {
    check("bash= 是外掛自己的絕對路徑（\(mark.bash ?? "nil")｜\(mark.bashArgs)）", mark.bash.flatMap(PluginRunner.realPath) == PluginRunner.realPath(pdir + "/good.1m.sh") && mark.bashArgs == ["mark"])
    runner.perform(pluginID: "good.1m.sh", item: mark)
    let ok = await eventually { plugin("good.1m.sh")?.output?.items.contains(where: { $0.text == "已標記" }) == true }
    check("點擊 bash= 動作後 refresh 重跑，看得到新狀態", ok)
} else {
    check("找到「標記」項目", false)
}
// bash= 指向不屬於自己的程式 → 拒絕
runner.perform(pluginID: "good.1m.sh", item: L.parseLine("x | bash=/bin/echo param1=hi"))
check("bash= 指向 root 擁有的程式被拒", plugin("good.1m.sh")?.actionError?.contains("點擊動作被拒") == true)
check("點擊失敗：保留上次項目、只標 ⚠︎", plugin("good.1m.sh")?.output != nil && plugin("good.1m.sh")?.blocking == nil
      && plugin("good.1m.sh")?.failure != nil)

// bash= 位置限制（實際走 perform）：外部直譯器、資料夾外本人檔案、../ 跳脫、symlink 指出去都拒絕
let pwn = root + "/pwned"
/// 預期被拒的點擊：perform 當下就同步拒絕，再固定觀察 1.5 秒確認沒有執行（不應該發生的事只能固定等）
@MainActor func tryClick(_ line: String) async -> String? {
    runner.perform(pluginID: "good.1m.sh", item: L.parseLine(line))
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    return plugin("good.1m.sh")?.actionError
}
/// 預期會執行的點擊：等到動作跑完（上一個被拒的錯誤被清掉）為止
@MainActor func clickAndWait(_ line: String) async -> String? {
    runner.perform(pluginID: "good.1m.sh", item: L.parseLine(line))
    _ = await eventually { plugin("good.1m.sh")?.actionError == nil }
    return plugin("good.1m.sh")?.actionError
}
if fm.isExecutableFile(atPath: "/opt/homebrew/bin/python3") {
    let e = await tryClick("x | bash=/opt/homebrew/bin/python3 param1=-c param2=\"open('\(pwn)','w').write('x')\"")
    check("bash=/opt/homebrew/bin/python3 被拒且沒有執行", e?.contains("外掛本身") == true && !fm.fileExists(atPath: pwn))
} else {
    print("⚠️ 本機沒有 /opt/homebrew/bin/python3，略過")
}
let e1 = await tryClick("x | bash=/bin/sh param1=-c param2=\"echo x > \(pwn)\"")
check("bash=/bin/sh 被拒且沒有執行", e1?.contains("外掛本身") == true && !fm.fileExists(atPath: pwn))
put("outside.sh", "#!/bin/bash\necho x > \"\(pwn)\"\n", dir: root)
let e2 = await tryClick("x | bash=\(root)/outside.sh")
check("外掛資料夾外的本人檔案被拒", e2?.contains("外掛本身") == true && !fm.fileExists(atPath: pwn))
let e3 = await tryClick("x | bash=\(pdir)/../outside.sh")
check("../ 跳脫被拒", e3?.contains("外掛本身") == true && !fm.fileExists(atPath: pwn))
try! fm.createDirectory(atPath: pdir + "/lib", withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
try! fm.createSymbolicLink(atPath: pdir + "/lib/out.sh", withDestinationPath: root + "/outside.sh")
let e4 = await tryClick("x | bash=\(pdir)/lib/out.sh")
check("資料夾內的 symlink 指出資料夾被拒", e4?.contains("外掛本身") == true && !fm.fileExists(atPath: pwn))
let okMark = root + "/helper-ran"
put("helper.sh", "#!/bin/bash\necho ok > \"\(okMark)\"\n", dir: pdir + "/lib")
let e5 = await tryClick("x | bash=\(pdir)/lib/helper.sh")
check("外掛資料夾內的其他程式也被拒（只准外掛本身）", e5?.contains("外掛本身") == true && !fm.fileExists(atPath: okMark))
let e6 = await clickAndWait("x | bash=\(pdir)/good.1m.sh param1=mark")
check("正對照：bash= 指向外掛本身可執行（\(e6 ?? "nil")）", e6 == nil)

// 輸出上限在讀取時生效：大量輸出不會讓記憶體暴增，仍會逾時／正常結束
func maxRSS() -> Int { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Int(u.ru_maxrss) }
let big2 = root + "/big"
try! fm.createDirectory(atPath: big2, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
put("yes.1m.sh", "#!/bin/bash\necho Y\necho ---\nexec /usr/bin/yes\n", dir: big2)
put("burst.1m.sh", "#!/bin/bash\necho B\necho ---\n/usr/bin/yes 0123456789 | head -c 3000000\nexit 0\n", dir: big2)
let runner5 = PluginRunner(directory: URL(fileURLWithPath: big2), stateRoot: URL(fileURLWithPath: sdir),
                           allowInactiveExecution: true)
runner5.timeout = 2
runner5.scan()
let rss0 = maxRSS()
await runner5.run("yes.1m.sh")
let rss1 = maxRSS()
// 3 MB 要能在時限內讀完：高負載下 2 秒不夠，這裡驗的是截斷不是逾時
runner5.timeout = roomyTimeout
await runner5.run("burst.1m.sh")
let y5 = runner5.plugins.first { $0.id == "yes.1m.sh" }, b5 = runner5.plugins.first { $0.id == "burst.1m.sh" }
check("無止盡輸出：仍正常逾時", y5?.error?.contains("逾時") == true)
check("無止盡輸出：峰值記憶體增加 < 64 MB（實際 \((rss1 - rss0) / 1_048_576) MB）", rss1 - rss0 < 64 * 1_048_576)
check("3 MB 輸出後正常結束：成功解析並標記截斷、項目 ≤ 30", b5?.error == nil && b5?.output?.truncated == true
      && (b5?.output?.items.count ?? 99) <= L.maxItems)
let lim = await ProcessRunner.runLimited("/usr/bin/yes", [], timeout: 1, maxBytes: 1000)
check("ProcessRunner maxBytes：收到的輸出 ≤ 上限且逾時", lim.output.utf8.count <= 1000 && lim.timedOut)
let full = await ProcessRunner.execute("/bin/sh", ["-c", "/usr/bin/yes 0123456789 | head -c 200000"], timeout: roomyTimeout)
check("ProcessRunner 預設不限：200 KB 完整收到、未截斷", full.output.utf8.count == 200000 && !full.truncated && full.code == 0)
let cut = await ProcessRunner.execute("/bin/sh", ["-c", "/usr/bin/yes 0123456789 | head -c 200000"], timeout: roomyTimeout, maxBytes: 5000)
check("ProcessRunner maxBytes：超過標 truncated、程式照常結束", cut.output.utf8.count == 5000 && cut.truncated && cut.code == 0)

// 選單只在內容變化時重建：內容沒變時 scan() 不發布
var publishes = 0
let sub = runner.$plugins.dropFirst().sink { _ in publishes += 1 }
runner.scan(); runner.scan()
check("內容沒變時 scan() 不發布新值", publishes == 0)
put("new.1m.sh", "#!/bin/bash\necho n\n")
runner.scan()
check("正對照：新增外掛時會發布", publishes == 1)
sub.cancel()

// 不重疊：關閉後立刻重開、點擊與排程同時發生
let ov = root + "/ov"
try! fm.createDirectory(atPath: ov, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let slowLog = root + "/slow.log"
put("slow.1m.sh", "#!/bin/bash\necho \"start $$\" >> \"\(slowLog)\"\nif [ -f \"$SPLITSWAN_PLUGIN_STATE/hold\" ] && [ \"$1\" != x ]; then while [ ! -f \"$SPLITSWAN_PLUGIN_STATE/release\" ]; do sleep 0.02; done; fi\nsleep 1\necho \"end $$\" >> \"\(slowLog)\"\necho S\necho ---\necho \"點 | bash=$0 param1=x\"\n", dir: ov)
let runner6 = PluginRunner(directory: URL(fileURLWithPath: ov), stateRoot: URL(fileURLWithPath: sdir))
runner6.timeout = roomyTimeout   // 高負載下 sleep 1 的腳本也可能超過好幾秒
func maxDepth() -> (Int, Int) {
    let lines = ((try? String(contentsOfFile: slowLog, encoding: .utf8)) ?? "").split(separator: "\n")
    var d = 0, m = 0
    for l in lines { d += l.hasPrefix("start") ? 1 : -1; m = max(m, d) }
    return (m, lines.filter { $0.hasPrefix("start") }.count)
}
/// slow.log 的開始／結束次數
func slowCounts() -> (starts: Int, ends: Int) {
    let lines = ((try? String(contentsOfFile: slowLog, encoding: .utf8)) ?? "").split(separator: "\n")
    return (lines.filter { $0.hasPrefix("start") }.count, lines.filter { $0.hasPrefix("end") }.count)
}
runner6.setEnabled(true)
_ = await eventually { runner6.runningIDs.contains("slow.1m.sh") }   // 確定第一次已在執行中，再關閉重開
runner6.setEnabled(false)
runner6.setEnabled(true)
// 重開後的補跑要等它真的跑完（開始＝結束），否則下面清空紀錄後才寫入的 end 會讓深度計算錯位
_ = await eventually { let c = slowCounts(); return c.starts >= 2 && c.starts == c.ends }
runner6.setEnabled(false)
let (d1, cnt1) = maxDepth()
check("關閉後立刻重開不重疊執行（最大同時 \(d1)，共 \(cnt1) 次）", d1 == 1 && cnt1 >= 1)
try? "".write(toFile: slowLog, atomically: false, encoding: .utf8)
// 點擊動作測試改用從未啟用過的 runner，保留 direct-test seam；
// 已啟用過又關閉的 runner 依生命週期規則不得再直接 run。
let actionRunner = PluginRunner(directory: URL(fileURLWithPath: ov), stateRoot: URL(fileURLWithPath: sdir),
                                allowInactiveExecution: true)
actionRunner.timeout = roomyTimeout
actionRunner.scan()
await actionRunner.run("slow.1m.sh")
try? "".write(toFile: slowLog, atomically: false, encoding: .utf8)
let actionState = sdir + "/slow.1m.sh"
try? fm.removeItem(atPath: actionState + "/release")
try! "hold".write(toFile: actionState + "/hold", atomically: false, encoding: .utf8)
let t7 = Task { await actionRunner.run("slow.1m.sh") }
_ = await eventually { actionRunner.runningIDs.contains("slow.1m.sh") }   // 確定排程那次已在執行中，再點擊
if let click = actionRunner.plugins.first(where: { $0.id == "slow.1m.sh" })?.output?.items.first(where: { $0.text == "點" }) {
    actionRunner.perform(pluginID: "slow.1m.sh", item: click)
    actionRunner.perform(pluginID: "slow.1m.sh", item: click)
} else { check("找到「點」項目", false) }
let bothActionsQueued = await eventually { actionRunner.pendingIdleWaiterCount == 2 }
try! "release".write(toFile: actionState + "/release", atomically: false, encoding: .utf8)
_ = await t7.value
_ = await eventually {
    let c = slowCounts()
    // 腳本寫入結束紀錄時，runner 仍可能尚未釋放執行槽與序列 waiter。
    return c.starts >= 3 && c.starts == c.ends && actionRunner.runningIDs.isEmpty && actionRunner.pendingIdleWaiterCount == 0
}
let (d2, cnt2) = maxDepth()
check("同一外掛在 run 中連排兩個 perform：全部完成且不重疊（最大同時 \(d2)，共 \(cnt2) 次）",
      bothActionsQueued && d2 == 1 && cnt2 == 3 && actionRunner.pendingIdleWaiterCount == 0)
await actionRunner.run("slow.1m.sh")
let (d3, cnt3) = maxDepth()
check("序列 waiter 清空後仍可再執行", d3 == 1 && cnt3 == 4 && actionRunner.pendingIdleWaiterCount == 0)

// 數量上限：11 個外掛只取前 10 個
let many2 = root + "/many"
try! fm.createDirectory(atPath: many2, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
for i in 1...11 { put(String(format: "p%02d.1m.sh", i), "#!/bin/bash\necho p\n", dir: many2) }
let runner3 = PluginRunner(directory: URL(fileURLWithPath: many2), stateRoot: URL(fileURLWithPath: sdir))
runner3.scan()
check("超過 10 個依檔名排序後略過", runner3.plugins.count == 10 && runner3.skipped == ["p11.1m.sh"])
let runner4 = PluginRunner(directory: URL(fileURLWithPath: root + "/nope"), stateRoot: URL(fileURLWithPath: sdir))
runner4.scan()
check("外掛資料夾不存在：不建立、標記 folderMissing", runner4.folderMissing && !fm.fileExists(atPath: root + "/nope"))
// MARK: 效能：關閉時零開銷、監看資料夾、每個外掛一個 timer、暫停／恢復、同時執行上限
let perfDir = root + "/perf", perfState = root + "/perf-state"
try! fm.createDirectory(atPath: perfDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
put("a.1m.sh", "#!/bin/bash\necho A\necho ---\necho $(date +%s%N)\n", dir: perfDir)
put("b.5m.sh", "#!/bin/bash\necho B\n", dir: perfDir)
let pr = PluginRunner(directory: URL(fileURLWithPath: perfDir), stateRoot: URL(fileURLWithPath: perfState))
pr.timeout = roomyTimeout
pr.setEnabled(false)
let r0 = pr.resources
check("關閉（從未開啟）：0 個 timer、不監看、0 個事件訂閱", r0.timers == 0 && !r0.watching && r0.observers == 0)
check("關閉：沒有掃描（plugins 空）、沒有建立 plugin-state", pr.plugins.isEmpty && !fm.fileExists(atPath: perfState))
pr.refreshIfEnabled()
try? await Task.sleep(nanoseconds: 300_000_000)
check("關閉時 refreshIfEnabled 不做事", pr.plugins.isEmpty && !fm.fileExists(atPath: perfState))
pr.setEnabled(true)
_ = await eventually { pr.lastRuns.count >= 2 }
let r1 = pr.resources
check("開啟：每個外掛一個 timer、監看資料夾、訂閱 8 個睡眠／鎖定事件", r1.timers == 2 && r1.watching && r1.observers == 8)
check("開啟後各跑一次", pr.lastRuns.count == 2)
check("timer 容許誤差：1m → 6 秒、5m → 30 秒", pr.timerTolerance("a.1m.sh") == 6 && pr.timerTolerance("b.5m.sh") == 30)
// 監看：新增外掛 → 約 1 秒後自動出現並執行（不靠輪詢）
put("c.1m.sh", "#!/bin/bash\necho C\n", dir: perfDir)
_ = await eventually { pr.lastRuns["c.1m.sh"] != nil && pr.resources.timers == 3 }
check("資料夾新增外掛：自動掃描、建立 timer 並執行", pr.plugins.contains { $0.id == "c.1m.sh" } && pr.lastRuns["c.1m.sh"] != nil
      && pr.resources.timers == 3)
// 暫停：鎖定＋睡眠，兩個都解除才恢復
pr.pause(.sleep); pr.pause(.locked)
check("暫停中：沒有 timer", pr.resources.timers == 0)
let ranA = pr.lastRuns["a.1m.sh"]
pr.resume(.sleep)
try? await Task.sleep(nanoseconds: 500_000_000)
check("只解除睡眠、仍鎖定：維持暫停、不執行", pr.resources.timers == 0 && pr.lastRuns["a.1m.sh"] == ranA)
pr.resume(.locked)
_ = await eventually { pr.lastRuns["a.1m.sh"] != ranA }
check("解鎖後各跑一次並恢復排程", pr.lastRuns["a.1m.sh"] != ranA && pr.resources.timers == 3)
pr.resume(.screenSaver)
check("沒暫停過的原因解除不會多跑", pr.resources.timers == 3)
pr.setEnabled(false)
let r2 = pr.resources
check("再關閉：timer、監看、事件訂閱全部釋放", r2.timers == 0 && !r2.watching && r2.observers == 0 && pr.plugins.isEmpty)

let backgroundDir = root + "/locked-background", backgroundState = root + "/locked-background-state"
let backgroundLog = root + "/locked-background.log", foregroundLog = root + "/locked-foreground.log"
try! fm.createDirectory(atPath: backgroundDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
put("background.1m.sh", "#!/bin/bash\necho background >> \"\(backgroundLog)\"\necho Background\n", dir: backgroundDir)
put("foreground.1m.sh", "#!/bin/bash\necho foreground >> \"\(foregroundLog)\"\necho Foreground\n", dir: backgroundDir)
let backgroundSuite = "SplitSwan.BackgroundPluginTests.\(getpid())"
let backgroundPreferences = UserDefaults(suiteName: backgroundSuite)!
backgroundPreferences.removePersistentDomain(forName: backgroundSuite)
backgroundPreferences.set(["background.1m.sh"], forKey: "BackgroundPlugins")
let backgroundRunner = PluginRunner(directory: URL(fileURLWithPath: backgroundDir),
                                    stateRoot: URL(fileURLWithPath: backgroundState),
                                    preferences: backgroundPreferences)
backgroundRunner.timeout = roomyTimeout
backgroundRunner.setEnabled(true)
_ = await eventually { logLines(backgroundLog) == 1 && logLines(foregroundLog) == 1 && backgroundRunner.runningIDs.isEmpty }
check("背景外掛：啟動時背景與普通外掛都執行", logLines(backgroundLog) == 1 && logLines(foregroundLog) == 1)
for (reason, name) in [(PluginRunner.PauseReason.locked, "鎖定"), (.screenSleep, "螢幕關閉"), (.screenSaver, "螢幕保護程式")] {
    backgroundRunner.pause(reason)
    let beforeBackground = logLines(backgroundLog), beforeForeground = logLines(foregroundLog)
    await backgroundRunner.run("background.1m.sh")
    await backgroundRunner.run("foreground.1m.sh")
    check("背景外掛：\(name)仍執行，預期 \(beforeBackground + 1) 次，實際 \(logLines(backgroundLog)) 次",
          logLines(backgroundLog) == beforeBackground + 1)
    check("普通外掛：\(name)仍暫停", logLines(foregroundLog) == beforeForeground)
    check("背景外掛：\(name)只保留背景 timer", backgroundRunner.resources.timers == 1)
}
backgroundRunner.pause(.sleep)
let sleepingBackground = logLines(backgroundLog), sleepingForeground = logLines(foregroundLog)
await backgroundRunner.run("background.1m.sh")
await backgroundRunner.run("foreground.1m.sh")
check("背景外掛：真正睡眠時全部停止", logLines(backgroundLog) == sleepingBackground
      && logLines(foregroundLog) == sleepingForeground && backgroundRunner.resources.timers == 0)
backgroundRunner.resume(.sleep)
_ = await eventually { logLines(backgroundLog) > sleepingBackground && backgroundRunner.runningIDs.isEmpty }
check("背景外掛：喚醒後未解鎖也立即執行，預期大於 \(sleepingBackground) 次，實際 \(logLines(backgroundLog)) 次",
      logLines(backgroundLog) > sleepingBackground)
check("普通外掛：喚醒但仍鎖定時維持暫停", logLines(foregroundLog) == sleepingForeground
      && backgroundRunner.resources.timers == 1)
backgroundRunner.resume(.screenSleep)
backgroundRunner.resume(.screenSaver)
backgroundRunner.resume(.locked)
_ = await eventually { logLines(foregroundLog) > sleepingForeground && backgroundRunner.runningIDs.isEmpty }
check("背景外掛：全部解除後普通外掛恢復", logLines(foregroundLog) > sleepingForeground
      && backgroundRunner.resources.timers == 2)
let backgroundNotifications = NSMutableArray()
backgroundRunner.notifier = { _, _, body, _ in backgroundNotifications.add(body) }
let heldStart = backgroundState + "/background.1m.sh/started"
let heldRelease = backgroundState + "/background.1m.sh/release"
let manualMarker = backgroundState + "/background.1m.sh/manual"
put("background.1m.sh", "#!/bin/bash\nif [ \"${1:-}\" = action ]; then touch \"$SPLITSWAN_PLUGIN_STATE/manual\"; exit; fi\ntouch \"$SPLITSWAN_PLUGIN_STATE/started\"\nwhile [ ! -f \"$SPLITSWAN_PLUGIN_STATE/release\" ]; do sleep 0.02; done\necho 背景完成\necho ---\necho '背景通知 | notify=true notify_id=background-done'\n", dir: backgroundDir)
let heldBackground = Task { await backgroundRunner.run("background.1m.sh") }
_ = await eventually { fm.fileExists(atPath: heldStart) }
backgroundRunner.pause(.locked)
backgroundRunner.pause(.screenSleep)
try! Data().write(to: URL(fileURLWithPath: heldRelease))
await heldBackground.value
check("背景外掛：執行中鎖定仍發布結果與通知", backgroundRunner.plugins.first(where: { $0.id == "background.1m.sh" })?.output?.title == "背景完成"
      && backgroundNotifications.count == 1)
backgroundRunner.setRunWhenLocked("background.1m.sh", false)
await backgroundRunner.run("background.1m.sh")
check("背景外掛：撤回背景授權即停止鎖定排程", backgroundRunner.resources.timers == 0
      && backgroundRunner.plugins.first(where: { $0.id == "background.1m.sh" })?.runWhenLocked == false)
let beforeBackgroundGrant = backgroundRunner.lastRuns["background.1m.sh"]
backgroundRunner.setRunWhenLocked("background.1m.sh", true)
_ = await eventually { backgroundRunner.lastRuns["background.1m.sh"] != beforeBackgroundGrant && backgroundRunner.runningIDs.isEmpty }
let backgroundReloaded = PluginRunner(directory: URL(fileURLWithPath: backgroundDir),
                                      stateRoot: URL(fileURLWithPath: backgroundState), preferences: backgroundPreferences)
backgroundReloaded.scan()
check("背景外掛：背景授權重新讀取後保留，普通外掛預設關閉", backgroundReloaded.plugins.first(where: { $0.id == "background.1m.sh" })?.runWhenLocked == true
      && backgroundReloaded.plugins.first(where: { $0.id == "foreground.1m.sh" })?.runWhenLocked == false)
backgroundRunner.setPluginEnabled("background.1m.sh", false)
await backgroundRunner.run("background.1m.sh")
check("背景外掛：個別停用仍停止全部排程", backgroundRunner.resources.timers == 0)
let beforeBackgroundEnable = backgroundRunner.lastRuns["background.1m.sh"]
backgroundRunner.setPluginEnabled("background.1m.sh", true)
_ = await eventually { backgroundRunner.lastRuns["background.1m.sh"] != beforeBackgroundEnable && backgroundRunner.runningIDs.isEmpty }
let beforeBackgroundResume = backgroundRunner.lastRuns["background.1m.sh"]
backgroundRunner.resume(.screenSleep)
backgroundRunner.resume(.locked)
_ = await eventually { backgroundRunner.lastRuns["background.1m.sh"] != beforeBackgroundResume && backgroundRunner.runningIDs.isEmpty }
try! fm.removeItem(atPath: heldStart)
try! fm.removeItem(atPath: heldRelease)
let manualBlocker = Task { await backgroundRunner.run("background.1m.sh") }
_ = await eventually { fm.fileExists(atPath: heldStart) }
backgroundRunner.perform(pluginID: "background.1m.sh", item: L.parseLine("手動 | bash=\(backgroundDir)/background.1m.sh param1=action"))
_ = await eventually { backgroundRunner.pendingIdleWaiterCount > 0 }
backgroundRunner.pause(.locked)
backgroundRunner.resume(.locked)
try! Data().write(to: URL(fileURLWithPath: heldRelease))
await manualBlocker.value
_ = await eventually { backgroundRunner.pendingIdleWaiterCount == 0 && backgroundRunner.runningIDs.isEmpty }
check("背景外掛：鎖定前排隊的手動動作在解鎖後仍失效", !fm.fileExists(atPath: manualMarker))
backgroundRunner.setEnabled(false)
check("背景外掛：全域關閉仍釋放全部資源", backgroundRunner.resources.timers == 0
      && !backgroundRunner.resources.watching && backgroundRunner.resources.observers == 0)
backgroundPreferences.removePersistentDomain(forName: backgroundSuite)

for wakesFromSleep in [false, true] {
    let name = wakesFromSleep ? "wake-before-scan" : "screen-sleep-before-scan"
    let dir = root + "/" + name + "/plugins", state = root + "/" + name + "/state"
    let backgroundLog = root + "/" + name + "/background.log"
    let foregroundLog = root + "/" + name + "/foreground.log"
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    put("background.1m.sh", "#!/bin/bash\necho ran >> \"\(backgroundLog)\"\necho Background\n", dir: dir)
    put("foreground.1m.sh", "#!/bin/bash\necho ran >> \"\(foregroundLog)\"\necho Foreground\n", dir: dir)
    let suite = "SplitSwan.Startup.\(name).\(getpid())"
    let preferences = UserDefaults(suiteName: suite)!
    preferences.set(["background.1m.sh"], forKey: PluginRunner.backgroundPluginsKey)
    let runner = PluginRunner(directory: URL(fileURLWithPath: dir), stateRoot: URL(fileURLWithPath: state),
                              preferences: preferences)
    runner.timeout = roomyTimeout
    runner.setEnabled(true)
    runner.pause(.locked)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    if wakesFromSleep {
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()
        check("啟動競態：首次掃描前真正睡眠仍零掃描、零執行", runner.plugins.isEmpty
              && runner.resources.timers == 0 && logLines(backgroundLog) == 0 && !fm.fileExists(atPath: state))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    }
    _ = await eventually(3) { logLines(backgroundLog) > 0 && runner.runningIDs.isEmpty }
    check("啟動競態：\(name)仍載入背景外掛，預期 2 支，實際 \(runner.plugins.count) 支", runner.plugins.count == 2)
    check("啟動競態：\(name)未解鎖仍執行背景外掛，預期至少 1 次，實際 \(logLines(backgroundLog)) 次",
          logLines(backgroundLog) > 0 && runner.resources.timers == 1)
    check("啟動競態：\(name)普通外掛保持暫停", logLines(foregroundLog) == 0)
    runner.setEnabled(false)
    preferences.removePersistentDomain(forName: suite)
}

let startupPausedDir = root + "/startup-without-grant/plugins"
let startupPausedState = root + "/startup-without-grant/state"
try! fm.createDirectory(atPath: startupPausedDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
put("foreground.1m.sh", "#!/bin/bash\necho Foreground\n", dir: startupPausedDir)
let startupPaused = PluginRunner(directory: URL(fileURLWithPath: startupPausedDir),
                                 stateRoot: URL(fileURLWithPath: startupPausedState))
startupPaused.setEnabled(true)
startupPaused.pause(.locked)
await Task.yield()
await startupPaused.refreshAll()
check("啟動競態：沒有背景授權時鎖定仍不掃描、不建立狀態", startupPaused.plugins.isEmpty
      && startupPaused.resources.timers == 0 && !fm.fileExists(atPath: startupPausedState))
startupPaused.setEnabled(false)

let startupOffSuite = "SplitSwan.StartupOff.\(getpid())"
let startupOffPreferences = UserDefaults(suiteName: startupOffSuite)!
startupOffPreferences.set(["foreground.1m.sh"], forKey: PluginRunner.backgroundPluginsKey)
let startupOff = PluginRunner(directory: URL(fileURLWithPath: startupPausedDir),
                              stateRoot: URL(fileURLWithPath: startupPausedState), preferences: startupOffPreferences)
startupOff.setEnabled(true)
startupOff.pause(.locked)
startupOff.setEnabled(false)
await Task.yield()
await startupOff.refreshAll()
check("啟動競態：背景初始請求在全域關閉後不能掃描或執行", startupOff.plugins.isEmpty
      && startupOff.resources.timers == 0 && !startupOff.resources.watching && startupOff.resources.observers == 0
      && !fm.fileExists(atPath: startupPausedState))
startupOffPreferences.removePersistentDomain(forName: startupOffSuite)

let startupEpochDir = root + "/startup-epoch/plugins", startupEpochState = root + "/startup-epoch/state"
let startupEpochLog = root + "/startup-epoch/foreground.log"
try! fm.createDirectory(atPath: startupEpochDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
put("background.1m.sh", "#!/bin/bash\necho Background\n", dir: startupEpochDir)
put("foreground.1m.sh", "#!/bin/bash\necho ran >> \"\(startupEpochLog)\"\necho Foreground\n", dir: startupEpochDir)
let startupEpochSuite = "SplitSwan.StartupEpoch.\(getpid())"
let startupEpochPreferences = UserDefaults(suiteName: startupEpochSuite)!
startupEpochPreferences.set(["background.1m.sh"], forKey: PluginRunner.backgroundPluginsKey)
let startupEpochRunner = PluginRunner(directory: URL(fileURLWithPath: startupEpochDir),
                                      stateRoot: URL(fileURLWithPath: startupEpochState), preferences: startupEpochPreferences)
startupEpochRunner.timeout = roomyTimeout
startupEpochRunner.setEnabled(true)
startupEpochRunner.pause(.locked)
startupEpochRunner.resume(.locked)
_ = await eventually { logLines(startupEpochLog) > 0 && startupEpochRunner.runningIDs.isEmpty }
let resurrectedStartupRequest = await eventually(3) { logLines(startupEpochLog) > 1 }
check("啟動競態：鎖定再解鎖只執行新請求的普通外掛，預期 1 次，實際 \(logLines(startupEpochLog)) 次",
      !resurrectedStartupRequest && logLines(startupEpochLog) == 1)
startupEpochRunner.setEnabled(false)
startupEpochPreferences.removePersistentDomain(forName: startupEpochSuite)

// 個別外掛開關：設定需持久化；停用後不排程、不接受點擊，其他外掛不受影響。
let individualDir = root + "/individual", individualState = root + "/individual-state"
let individualALog = root + "/individual-a.log", individualBLog = root + "/individual-b.log"
try! fm.createDirectory(atPath: individualDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
put("a.1m.sh", "#!/bin/bash\necho a >> \"\(individualALog)\"\necho A\n", dir: individualDir)
put("b.1m.sh", "#!/bin/bash\necho b >> \"\(individualBLog)\"\necho B\n", dir: individualDir)
let individualSuite = "SplitSwan.PluginTests.\(getpid())"
let individualPreferences = UserDefaults(suiteName: individualSuite)!
individualPreferences.removePersistentDomain(forName: individualSuite)
let individual = PluginRunner(directory: URL(fileURLWithPath: individualDir),
                              stateRoot: URL(fileURLWithPath: individualState),
                              preferences: individualPreferences)
individual.timeout = roomyTimeout
individual.setEnabled(true)
_ = await eventually { logLines(individualALog) == 1 && logLines(individualBLog) == 1 }
individual.setPluginEnabled("a.1m.sh", false)
let aBefore = logLines(individualALog), bBefore = logLines(individualBLog)
await individual.refreshAll()
_ = await eventually { logLines(individualBLog) >= bBefore + 1 && !individual.runningIDs.contains("b.1m.sh") }
check("個別停用：該外掛不執行、其他外掛照常執行，且只保留一個 timer",
      logLines(individualALog) == aBefore && logLines(individualBLog) >= bBefore + 1
      && individual.resources.timers == 1
      && individual.plugins.first { $0.id == "a.1m.sh" }?.isEnabled == false)
var individualOpenedURLs = 0
individual.urlOpener = { _ in individualOpenedURLs += 1 }
individual.perform(pluginID: "a.1m.sh", item: L.parseLine("x | href=https://example.com"))
await Task.yield()
check("個別停用：拒絕點擊動作", individualOpenedURLs == 0)
individual.setEnabled(false)
let persisted = PluginRunner(directory: URL(fileURLWithPath: individualDir),
                             stateRoot: URL(fileURLWithPath: individualState + "-persisted"),
                             allowInactiveExecution: true,
                             preferences: individualPreferences)
persisted.scan()
check("個別停用：重新建立 Runner 後仍記得停用清單",
      persisted.plugins.first { $0.id == "a.1m.sh" }?.isEnabled == false
      && persisted.plugins.first { $0.id == "b.1m.sh" }?.isEnabled == true)
persisted.setPluginEnabled("a.1m.sh", true)
await persisted.run("a.1m.sh")
check("個別重新啟用：立即可再次執行且清除持久化停用值",
      logLines(individualALog) == aBefore + 1
      && !(individualPreferences.stringArray(forKey: PluginRunner.disabledPluginsKey) ?? []).contains("a.1m.sh"))
individualPreferences.removePersistentDomain(forName: individualSuite)

// direct-test seam 必須由建構式明確開啟，不再從「是否啟用過」猜測測試意圖。
let directPolicyDir = root + "/direct-policy", directPolicyLog = root + "/direct-policy.log"
try! fm.createDirectory(atPath: directPolicyDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
put("direct.1m.sh", "#!/bin/bash\necho direct >> \"\(directPolicyLog)\"\necho D\n", dir: directPolicyDir)
let defaultInactive = PluginRunner(directory: URL(fileURLWithPath: directPolicyDir),
                                   stateRoot: URL(fileURLWithPath: root + "/direct-policy-default-state"))
await defaultInactive.refreshAll()
check("預設 runner 在 inactive 時直接 refreshAll 不掃描、不執行",
      defaultInactive.plugins.isEmpty && !fm.fileExists(atPath: directPolicyLog))
defaultInactive.scan()
await defaultInactive.run("direct.1m.sh")
check("預設 runner 在 inactive 時直接 run 不執行", !fm.fileExists(atPath: directPolicyLog))
let explicitDirect = PluginRunner(directory: URL(fileURLWithPath: directPolicyDir),
                                  stateRoot: URL(fileURLWithPath: root + "/direct-policy-explicit-state"),
                                  allowInactiveExecution: true)
await explicitDirect.refreshAll()
check("明確開啟測試旗標後仍可 direct refreshAll/run",
      explicitDirect.plugins.first?.output?.title == "D" && logLines(directPolicyLog) == 1)

// 重新整理請求的生命週期競速：請求排入後立刻關閉，下一輪 MainActor 不得掃描或執行。
func logLines(_ path: String) -> Int {
    ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").count
}
let disableRaceDir = root + "/refresh-disable", disableRaceState = root + "/refresh-disable-state"
let disableRaceLog = root + "/refresh-disable.log"
try! fm.createDirectory(atPath: disableRaceDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
put("race.1m.sh", "#!/bin/bash\necho run >> \"\(disableRaceLog)\"\necho R\n", dir: disableRaceDir)
let disableRace = PluginRunner(directory: URL(fileURLWithPath: disableRaceDir),
                               stateRoot: URL(fileURLWithPath: disableRaceState))
disableRace.timeout = roomyTimeout
disableRace.setEnabled(true)
_ = await eventually { disableRace.lastRuns["race.1m.sh"] != nil }
let runsBeforeDisableRequest = logLines(disableRaceLog)
disableRace.requestRefresh()
disableRace.setEnabled(false)
await Task.yield()
await Task.yield()
check("重新整理後立即關閉：不掃描、不執行、不重新建立資源",
      disableRace.plugins.isEmpty && logLines(disableRaceLog) == runsBeforeDisableRequest
      && disableRace.resources.timers == 0 && !disableRace.resources.watching)
disableRace.scan()
await disableRace.run("race.1m.sh")
check("已啟用過的 runner 關閉後直接 run 也不會啟動",
      logLines(disableRaceLog) == runsBeforeDisableRequest)
var disabledOpenedURLs = 0
disableRace.urlOpener = { _ in disabledOpenedURLs += 1 }
let disabledAction = L.parseLine("x | href=https://example.com bash=\(disableRaceDir)/race.1m.sh refresh=true")
disableRace.perform(pluginID: "race.1m.sh", item: disabledAction)
await Task.yield()
check("關閉時 perform 不開網址、不執行 bash、不 refresh",
      disabledOpenedURLs == 0 && logLines(disableRaceLog) == runsBeforeDisableRequest)

// 同一競速改為立即暫停；新檔案若被掃到，就代表已進入 refresh 主體。
let pauseRaceDir = root + "/refresh-pause", pauseRaceState = root + "/refresh-pause-state"
let pauseRaceLog = root + "/refresh-pause.log"
try! fm.createDirectory(atPath: pauseRaceDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
put("base.1m.sh", "#!/bin/bash\necho base >> \"\(pauseRaceLog)\"\necho B\n", dir: pauseRaceDir)
let pauseRace = PluginRunner(directory: URL(fileURLWithPath: pauseRaceDir),
                             stateRoot: URL(fileURLWithPath: pauseRaceState))
pauseRace.timeout = roomyTimeout
pauseRace.setEnabled(true)
_ = await eventually { pauseRace.lastRuns["base.1m.sh"] != nil }
var missingPluginOpenedURLs = 0
pauseRace.urlOpener = { _ in missingPluginOpenedURLs += 1 }
pauseRace.perform(pluginID: "missing.1m.sh", item: L.parseLine("x | href=https://example.com"))
check("perform 在外掛不存在時不先開啟 href", missingPluginOpenedURLs == 0)
let pauseIDs = pauseRace.plugins.map(\.id)
let runsBeforePauseRequest = logLines(pauseRaceLog)
put("late.1m.sh", "#!/bin/bash\necho late >> \"\(pauseRaceLog)\"\necho L\n", dir: pauseRaceDir)
let queuedPauseAction = L.parseLine("x | bash=\(pauseRaceDir)/base.1m.sh refresh=true")
pauseRace.perform(pluginID: "base.1m.sh", item: queuedPauseAction)
pauseRace.requestRefresh()
pauseRace.pause(.locked)
await Task.yield()
await Task.yield()
check("perform／重新整理排入後立即暫停：不掃描、不執行、不重新載入",
      pauseRace.plugins.map(\.id) == pauseIDs && logLines(pauseRaceLog) == runsBeforePauseRequest
      && pauseRace.resources.timers == 0)
await pauseRace.run("base.1m.sh")
check("暫停時直接 run 也不會啟動", logLines(pauseRaceLog) == runsBeforePauseRequest)
var pausedOpenedURLs = 0
pauseRace.urlOpener = { _ in pausedOpenedURLs += 1 }
let pausedAction = L.parseLine("x | href=https://example.com bash=\(pauseRaceDir)/base.1m.sh refresh=true")
pauseRace.perform(pluginID: "base.1m.sh", item: pausedAction)
await Task.yield()
check("暫停時 perform 不開網址、不執行 bash、不 refresh",
      pausedOpenedURLs == 0 && logLines(pauseRaceLog) == runsBeforePauseRequest)
pauseRace.setEnabled(false)

// 同時執行上限 2
let cc = root + "/cc", ccLog = root + "/cc.log"
try! fm.createDirectory(atPath: cc, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
// 每支先寫 start，再等到紀錄裡至少有 2 個 start（最多 20 秒）才 sleep：高負載下啟動時間會錯開，
// 不等的話前兩支可能根本沒同時執行，峰值變 1。上限若失效（4 支同時跑），峰值仍會超過 2
for i in 1...4 {
    put("c\(i).1m.sh", "#!/bin/bash\necho \"start\" >> \"\(ccLog)\"\nfor _ in {1..200}; do [ \"$(grep -c start \"\(ccLog)\")\" -ge 2 ] && break; sleep 0.1; done\nsleep 0.8\necho \"end\" >> \"\(ccLog)\"\necho C\n", dir: cc)
}
let ccr = PluginRunner(directory: URL(fileURLWithPath: cc), stateRoot: URL(fileURLWithPath: perfState),
                       allowInactiveExecution: true)
ccr.timeout = roomyTimeout
let tc = Date()
await ccr.refreshAll()
let ccSec = Date().timeIntervalSince(tc)
var depth = 0, peak = 0
for l in ((try? String(contentsOfFile: ccLog, encoding: .utf8)) ?? "").split(separator: "\n") { depth += l == "start" ? 1 : -1; peak = max(peak, depth) }
check("4 個外掛同時到期：最多 2 個同時執行（峰值 \(peak)，耗時 \(String(format: "%.1f", ccSec)) 秒）", peak == 2 && ccSec >= 1.5 && ccr.lastRuns.count == 4)

// MARK: 資安第二輪：ACL、上層資料夾、symlink 位置、隔離標記、檔名識別、stderr 上限、關閉／暫停的完整性
func sh(_ exe: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}
func mkPluginDir(_ name: String) -> String {
    let d = root + "/sec-" + name + "/plugins"
    try! fm.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root + "/sec-" + name)
    return d
}
@MainActor func check1(_ dir: String, _ file: String) -> String? { PluginRunner.fullCheck(path: dir + "/" + file, pluginDir: dir, uid: getuid()).problem }
let okDir = mkPluginDir("ok")
put("ok.1m.sh", "#!/bin/bash\necho ok\n", dir: okDir)
check("正對照：乾淨的外掛通過完整檢查（含上層資料夾直到 /）", check1(okDir, "ok.1m.sh") == nil)
let aclDir = mkPluginDir("acldir")
put("a.1m.sh", "#!/bin/bash\necho ACLRAN\n", dir: aclDir)
check("外掛資料夾有 everyone 可新增／刪除檔案的 ACL → 拒絕", sh("/bin/chmod", ["+a", "everyone allow add_file,delete_child", aclDir]) == 0
      && check1(aclDir, "a.1m.sh")?.contains("ACL") == true)
let aclFileDir = mkPluginDir("aclfile")
put("b.1m.sh", "#!/bin/bash\necho x\n", dir: aclFileDir)
check("外掛檔有 everyone 可寫的 ACL → 拒絕", sh("/bin/chmod", ["+a", "everyone allow write,append", aclFileDir + "/b.1m.sh"]) == 0
      && check1(aclFileDir, "b.1m.sh")?.contains("ACL") == true)
let denyDir = mkPluginDir("aclde")
put("c.1m.sh", "#!/bin/bash\necho x\n", dir: denyDir)
check("只有 deny 的 ACL 不影響", sh("/bin/chmod", ["+a", "everyone deny chown", denyDir + "/c.1m.sh"]) == 0 && check1(denyDir, "c.1m.sh") == nil)
let selfDir = mkPluginDir("aclself")
put("d.1m.sh", "#!/bin/bash\necho x\n", dir: selfDir)
check("給自己的 allow ACL 不影響", sh("/bin/chmod", ["+a", "user:\(NSUserName()) allow write", selfDir + "/d.1m.sh"]) == 0 && check1(selfDir, "d.1m.sh") == nil)
// 上層資料夾可被他人寫入
let gw = root + "/sec-gw"
try! fm.createDirectory(atPath: gw + "/mid/plugins", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
put("e.1m.sh", "#!/bin/bash\necho x\n", dir: gw + "/mid/plugins")
try! fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: gw + "/mid")
check("上層資料夾 777（無 sticky）→ 拒絕", check1(gw + "/mid/plugins", "e.1m.sh")?.contains("上層資料夾") == true)
try! fm.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: gw + "/mid")
check("上層資料夾 1777（sticky，如 /tmp）→ 接受", check1(gw + "/mid/plugins", "e.1m.sh") == nil)
try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gw + "/mid")
check("上層資料夾有他人可寫 ACL → 拒絕", sh("/bin/chmod", ["+a", "everyone allow add_file", gw]) == 0
      && check1(gw + "/mid/plugins", "e.1m.sh")?.contains("ACL") == true)
// symlink 指到外掛資料夾外（例：python3）
let lnDir = mkPluginDir("symlink")
if fm.isExecutableFile(atPath: "/opt/homebrew/bin/python3") {
    try! fm.createSymbolicLink(atPath: lnDir + "/py.1m.sh", withDestinationPath: "/opt/homebrew/bin/python3")
    check("外掛本身是指向 python3 的 symlink → 拒絕", check1(lnDir, "py.1m.sh")?.contains("不在外掛資料夾內") == true)
}
put("real.sh", "#!/bin/bash\necho x\n", dir: lnDir)
try! fm.createSymbolicLink(atPath: lnDir + "/alias.1m.sh", withDestinationPath: lnDir + "/real.sh")
check("symlink 指向同一層的檔案 → 接受", check1(lnDir, "alias.1m.sh") == nil)
// 隔離標記
let qDir = mkPluginDir("quarantine")
put("q.1m.sh", "#!/bin/bash\necho QRAN\n", dir: qDir)
check("正對照：加隔離標記前可執行", check1(qDir, "q.1m.sh") == nil)
check("帶 com.apple.quarantine → 拒絕", sh("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000000;Safari;", qDir + "/q.1m.sh"]) == 0
      && check1(qDir, "q.1m.sh")?.contains("隔離") == true)
// 同名不同檔名：狀態資料夾與通知分開
let dupDir = mkPluginDir("dup"), dupState = root + "/sec-dup/state"
put("a.1m.sh", "#!/bin/bash\necho \"$SPLITSWAN_PLUGIN_STATE\"\n", dir: dupDir)
put("a.5m.py", "#!/bin/bash\necho \"$SPLITSWAN_PLUGIN_STATE\"\n", dir: dupDir)
let dupR = PluginRunner(directory: URL(fileURLWithPath: dupDir), stateRoot: URL(fileURLWithPath: dupState),
                        allowInactiveExecution: true)
dupR.timeout = roomyTimeout
await dupR.refreshAll()
check("a.1m.sh 與 a.5m.py 各自的狀態資料夾", dupR.plugins.first { $0.id == "a.1m.sh" }?.output?.title == dupState + "/a.1m.sh"
      && dupR.plugins.first { $0.id == "a.5m.py" }?.output?.title == dupState + "/a.5m.py")
// stderr 有上限、不寫檔
let errDir = mkPluginDir("stderr"), errState = root + "/sec-stderr/state"
put("e.1m.sh", "#!/bin/bash\nhead -c 3000000 /dev/zero | tr '\\0' 'e' >&2\necho >&2\necho 最後一行 >&2\nexit 2\n", dir: errDir)
let errR = PluginRunner(directory: URL(fileURLWithPath: errDir), stateRoot: URL(fileURLWithPath: errState),
                        allowInactiveExecution: true)
errR.timeout = roomyTimeout
await errR.refreshAll()
let errMsg = errR.plugins.first?.error ?? ""
check("大量 stderr：錯誤訊息有上限（\(errMsg.utf8.count) bytes）", errMsg.hasPrefix("結束碼 2") && errMsg.utf8.count < 700)
check("大量 stderr 之後的最後一行仍顯示（保留最後 4 KB）", errMsg == "結束碼 2：最後一行")
check("stderr 不再寫進狀態資料夾", !fm.fileExists(atPath: errState + "/e.1m.sh/.stderr"))
let rawErr = await ProcessRunner.execute("/bin/sh", ["-c", "head -c 100000 /dev/zero >&2; echo out"], timeout: roomyTimeout, stderrLimit: 4096)
check("ProcessRunner stderrLimit：stderr 分開且 ≤ 4 KB、stdout 不混入", rawErr.errorOutput.utf8.count == 4096 && rawErr.output == "out\n")
let tailErr = await ProcessRunner.execute("/bin/sh", ["-c", "echo FIRST >&2; head -c 100000 /dev/zero | tr '\\0' x >&2; echo; echo LAST >&2"], timeout: roomyTimeout, stderrLimit: 4096)
check("stderr 保留最後 4 KB：有 LAST、沒有 FIRST", tailErr.errorOutput.hasSuffix("LAST\n") && !tailErr.errorOutput.contains("FIRST")
      && tailErr.errorOutput.utf8.count == 4096)
// 關閉／暫停的完整性（M1）
let m1Dir = mkPluginDir("m1"), m1Log = root + "/sec-m1/ran.log"
for n in ["s1", "s2", "s3"] {
    put("\(n).1m.sh", "#!/bin/bash\necho \(n) >> \"\(m1Log)\"\nsleep 2\necho \(n) >> \"\(m1Log).done\"\necho T\necho ---\necho \"hi | notify=true notify_id=\(n)\"\n", dir: m1Dir)
}
let m1 = PluginRunner(directory: URL(fileURLWithPath: m1Dir), stateRoot: URL(fileURLWithPath: root + "/sec-m1/state"))
m1.timeout = roomyTimeout
var m1Sent = 0
m1.notifier = { _, _, _, _ in m1Sent += 1 }
func m1Runs() -> Int { ((try? String(contentsOfFile: m1Log, encoding: .utf8)) ?? "").split(separator: "\n").count }
/// 已經跑完 sleep 的次數（腳本結束前寫在 .done）
func m1Done() -> Int { ((try? String(contentsOfFile: m1Log + ".done", encoding: .utf8)) ?? "").split(separator: "\n").count }
/// 等到外掛真的寫下開始紀錄；固定等待在高負載時會在程序已啟動、還沒寫紀錄的瞬間取樣
func waitRuns(_ n: Int) async { _ = await eventually(20) { m1Runs() >= n } }
/// 「不該開始」的觀察：先等進行中的都跑完、釋出執行名額（排隊者若有 bug 會在這之後才開始），再多看 1 秒
func waitSettled(_ n: Int) async {
    _ = await eventually(20) { m1Done() >= n }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
m1.setEnabled(true)
await waitRuns(2)
m1.setEnabled(false)
await waitSettled(2)
check("關閉後：排隊中的第 3 個不開始（實際 \(m1Runs()) 個）", m1Runs() == 2)
check("關閉後：進行中的完成也不發通知、不寫紀錄、不更新選單", m1Sent == 0 && m1.plugins.isEmpty
      && !fm.fileExists(atPath: root + "/sec-m1/state/.notified"))
m1.setEnabled(true)
await waitRuns(4)   // 前一輪 2 個＋這一輪佔滿 2 個執行名額
let runsBeforePause = m1Runs()
m1.pause(.locked)
await waitSettled(4)
check("暫停後：排隊中的不開始、進行中的不發通知、不更新輸出（暫停前 \(runsBeforePause)、之後 \(m1Runs())、通知 \(m1Sent)）", m1Runs() == runsBeforePause && m1Sent == 0
      && m1.plugins.allSatisfy { $0.output == nil })
m1.resume(.locked)
_ = await eventually(30) { m1Sent >= 3 && m1.plugins.allSatisfy { $0.output != nil } }
check("正對照：解除暫停後照常執行並發通知（\(m1Sent) 則）", m1Sent == 3 && m1.plugins.allSatisfy { $0.output != nil })
m1.setEnabled(false)

// 關閉後立刻重開、暫停中途恢復：舊的那次結果丟棄後要補跑，不可等到下一個間隔
/// 同一支外掛的最大同時執行數
func m1Depth() -> Int {
    var d: [String: Int] = [:], mx = 0
    for l in ((try? String(contentsOfFile: m1Log + ".depth", encoding: .utf8)) ?? "").split(separator: "\n") {
        let name = String(l.dropFirst()); d[name, default: 0] += l.hasPrefix("+") ? 1 : -1; mx = max(mx, d[name]!)
    }
    return mx
}
let rDir = mkPluginDir("rerun"), rState = root + "/sec-rerun/state"
for n in ["r1", "r2"] {
    put("\(n).1m.sh", "#!/bin/bash\necho +\(n) >> \"\(m1Log).depth\"\nsleep 1\necho -\(n) >> \"\(m1Log).depth\"\necho T\(n)\necho ---\necho \"hi | notify=true notify_id=\(n)\"\n", dir: rDir)
}
let rr = PluginRunner(directory: URL(fileURLWithPath: rDir), stateRoot: URL(fileURLWithPath: rState))
rr.timeout = roomyTimeout
var rrSent = 0
rr.notifier = { _, _, _, _ in rrSent += 1 }
rr.setEnabled(true)
_ = await eventually { rr.runningIDs.count == 2 }   // 確定兩支都已在執行中，再關閉重開
rr.setEnabled(false); rr.setEnabled(true)
// 輸出先更新、通知在讀完去重紀錄後才發，兩者都要等到
_ = await eventually(30) { rr.plugins.count == 2 && rr.plugins.allSatisfy { $0.output != nil } && rrSent >= 2 }
check("關閉後立刻重開：舊的結束後補跑，兩支都有輸出並發通知（\(rr.plugins.map { $0.output?.title ?? "nil" })，通知 \(rrSent)）", rr.plugins.count == 2 && rr.plugins.allSatisfy { $0.output != nil } && rrSent == 2)
rr.setEnabled(false)
let rr2 = PluginRunner(directory: URL(fileURLWithPath: rDir), stateRoot: URL(fileURLWithPath: rState + "2"))
rr2.timeout = roomyTimeout
var rr2Sent = 0
rr2.notifier = { _, _, _, _ in rr2Sent += 1 }
rr2.setEnabled(true)
_ = await eventually { rr2.runningIDs.count == 2 }   // 確定兩支都已在執行中，再暫停
rr2.pause(.locked)
try? await Task.sleep(nanoseconds: 200_000_000)
rr2.resume(.locked)                                   // 舊的那次還在跑
check("暫停中途恢復：舊的那次結果不採用（M1）", rr2.plugins.allSatisfy { $0.output == nil } && rr2Sent == 0)
_ = await eventually(30) { rr2.plugins.count == 2 && rr2.plugins.allSatisfy { $0.output != nil } && rr2Sent >= 2 }
check("暫停中途恢復：舊的結束後補跑並發通知", rr2.plugins.count == 2 && rr2.plugins.allSatisfy { $0.output != nil } && rr2Sent == 2)
rr2.setEnabled(false)
check("補跑期間同一外掛不重疊（同一支最大同時 \(m1Depth())）", m1Depth() == 1)


// MARK: 原生設定協定與標準輸入
let settingsRaw = """
{"version":1,"title":"測試外掛","revision":"r1","tabs":[{"id":"general","title":"一般"}],"fields":[{"id":"name","tab":"general","title":"名稱","type":"text"}],"values":{"name":"範例"},"actions":[{"id":"import","tab":"general","title":"匯入","input":"jsonFile","afterField":"name"}]}
"""
let settingsData = Data(settingsRaw.utf8)
check("設定協定：正常表單可解析", (try? PluginSettingsProtocol.decode(settingsData))?.tabs.count == 1)
check("設定說明保留換行並過濾控制與雙向字元", PluginSettingsProtocol.displayText("第一步\n第二步\u{202E}\u{0007}") == "第一步\n第二步")
var guideObject = try JSONSerialization.jsonObject(with: settingsData) as! [String: Any]
guideObject["actions"] = [["id": "check", "tab": "general", "title": "重新檢查"]]
let guideStep: [String: Any] = ["id": "first", "title": "設定", "help": "下一步", "state": "pending", "fields": ["name"], "actions": []]
let guideDefinition: [String: Any] = ["summary": "尚未完成", "steps": [guideStep], "checkAction": "check", "refreshFields": ["name"], "managementActions": []]
func guideData(_ definition: [String: Any], actions: [[String: Any]]? = nil) throws -> Data {
    var value = guideObject
    value["tabs"] = [["id": "general", "title": "一般", "guide": definition]]
    if let actions { value["actions"] = actions }
    return try JSONSerialization.data(withJSONObject: value)
}
check("設定精靈：正常描述可解析並定位未完成步驟", try PluginSettingsProtocol.decode(guideData(guideDefinition)).tabs[0].guide?.currentStep == "first")
for (name, replacement) in [
    ("未知狀態", ["state": "approved"]),
    ("不存在欄位", ["fields": ["missing"]]),
    ("不存在動作", ["actions": ["missing"]]),
    ("主要按鈕不屬於步驟", ["primaryAction": "check"]),
] as [(String, [String: Any])] {
    var invalid = guideDefinition
    invalid["steps"] = [guideStep.merging(replacement) { _, new in new }]
    check("設定精靈：拒絕\(name)", (try? PluginSettingsProtocol.decode(guideData(invalid))) == nil)
}
for count in [0, 11] {
    var invalid = guideDefinition
    invalid["steps"] = Array(repeating: guideStep, count: count)
    check("設定精靈：拒絕步驟數量 \(count)", (try? PluginSettingsProtocol.decode(guideData(invalid))) == nil)
}
for unsafe in [["destructive": true], ["opensExternal": true], ["recheckAfter": true], ["input": "jsonFile"]] as [[String: Any]] {
    let action = ["id": "check", "tab": "general", "title": "檢查"].merging(unsafe) { _, new in new }
    check("設定精靈：自動檢查不能開啟外部頁面、確認、匯入或自我觸發", (try? PluginSettingsProtocol.decode(guideData(guideDefinition, actions: [action]))) == nil)
}
var duplicateGuide = guideDefinition
duplicateGuide["steps"] = [guideStep, guideStep.merging(["id": "second"]) { _, new in new }]
check("設定精靈：欄位不能重複歸屬", (try? PluginSettingsProtocol.decode(guideData(duplicateGuide))) == nil)
for (name, raw) in [
    ("動作參照不存在欄位", settingsRaw.replacingOccurrences(of: "\"afterField\":\"name\"", with: "\"afterField\":\"missing\"")),
    ("未知版本", settingsRaw.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")),
    ("未知欄位型別", settingsRaw.replacingOccurrences(of: "\"type\":\"text\"", with: "\"type\":\"html\"")),
    ("錯誤值型別", settingsRaw.replacingOccurrences(of: "\"name\":\"範例\"", with: "\"name\":true")),
    ("不存在頁籤", settingsRaw.replacingOccurrences(of: "\"tab\":\"general\"", with: "\"tab\":\"missing\"")),
    ("重複頁籤", settingsRaw.replacingOccurrences(of: "[{\"id\":\"general\",\"title\":\"一般\"}]", with: "[{\"id\":\"general\",\"title\":\"一般\"},{\"id\":\"general\",\"title\":\"重複\"}]")),
    ("損壞 JSON", "{"),
    ("超過上限", String(repeating: " ", count: PluginSettingsProtocol.maxBytes + 1)),
] { check("設定協定：拒絕\(name)", (try? PluginSettingsProtocol.decode(Data(raw.utf8))) == nil) }
let supported = L.parseOutput("測試 | settings=true\n---\n今日狀態\n隱藏通知 | notify=true menu=false\n")
check("設定標頭：能力旗標不混入標題", supported.title == "測試" && supported.settingsAvailable)
let secretForm = settingsRaw.replacingOccurrences(of: "\"type\":\"text\"", with: "\"type\":\"secret\"")
    .replacingOccurrences(of: "\"name\":\"範例\"", with: "\"name\":\"\"")
check("機密欄位：只接受空的 snapshot 值", (try? PluginSettingsProtocol.decode(Data(secretForm.utf8))) != nil)
let leakingForm = secretForm.replacingOccurrences(of: "\"name\":\"\"", with: "\"name\":\"must-not-echo\"")
check("機密欄位：拒絕回傳既有機密的 snapshot", (try? PluginSettingsProtocol.decode(Data(leakingForm.utf8))) == nil)
check("舊外掛不會自動啟用設定協定", !L.parseOutput("舊外掛\n---\n內容").settingsAvailable)
let settingsTree = M.project(isActive: true, plugins: [.init(id: "test.sh", title: "測試", output: .init(items: supported.items, settingsAvailable: true))])
let settingsChildren = settingsTree.root.children?.first?.children ?? []
check("設定選單：設定入口命令正確、隱藏通知仍保留解析", settingsChildren.last?.command == .pluginSettings(pluginID: "test.sh")
      && !settingsChildren.contains { $0.title == "隱藏通知" } && supported.items.last?.notify == true)
let stdinPayload = Data(String(repeating: "設定資料\n", count: 3000).utf8)
let echoInput = await ProcessRunner.execute("/bin/cat", [], timeout: 5, maxBytes: stdinPayload.count + 1, input: stdinPayload)
check("標準輸入：完整傳遞大於 pipe 容量的內容並送出 EOF", echoInput.code == 0 && Data(echoInput.output.utf8) == stdinPayload)
let ignoredInput = await ProcessRunner.execute("/usr/bin/true", [], timeout: 2, input: stdinPayload)
check("標準輸入：子程序不讀取仍正常結束", ignoredInput.code == 0 && !ignoredInput.timedOut)
let inputTimeout = await ProcessRunner.execute("/bin/sleep", ["10"], timeout: 0.1, input: stdinPayload)
check("標準輸入：子程序不讀取時逾時仍能停止", inputTimeout.timedOut)
let settingsDir = mkPluginDir("settings-protocol")
put("settings.1m.sh", """
#!/bin/bash
if [ "$1" = --splitswan-settings ]; then
  if [ "$2" = save ]; then cat > "$SPLITSWAN_PLUGIN_STATE/received"; fi
  cat <<'SETTINGS_JSON'
\(settingsRaw)
SETTINGS_JSON
else
  echo '設定外掛 | settings=true'
  echo ---
  echo "protocol=$SPLITSWAN_PLUGIN_SETTINGS_PROTOCOL"
fi
""", dir: settingsDir)
let settingsRunner = PluginRunner(directory: URL(fileURLWithPath: settingsDir), stateRoot: URL(fileURLWithPath: root + "/settings-state"))
settingsRunner.scan()
do {
    let first = try await settingsRunner.settingsCommand(pluginID: "settings.1m.sh", operation: "snapshot")
    let marker = root + "/must-not-execute"
    let request = PluginSettingsProtocol.Request(revision: first.revision, values: ["name": .text("$(touch \(marker)) `echo secret`")])
    _ = try await settingsRunner.settingsCommand(pluginID: "settings.1m.sh", operation: "save", request: request)
    let saved = try Data(contentsOf: URL(fileURLWithPath: root + "/settings-state/settings.1m.sh/received"))
    check("停用時可明確管理設定，不啟用一般排程", !settingsRunner.isActive && first.version == 1)
    // JSON object 的鍵順序不屬於協定；比對完整內容，不能以兩次編碼的位元組順序判定失敗。
    let savedJSON = try JSONSerialization.jsonObject(with: saved) as? NSDictionary
    let expectedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary
    check("設定值經 stdin 傳遞，不執行 shell 內容", savedJSON?.isEqual(expectedJSON) == true && !fm.fileExists(atPath: marker))
    try fm.setAttributes([.posixPermissions: 0o770], ofItemAtPath: settingsDir + "/settings.1m.sh")
    do {
        _ = try await settingsRunner.settingsCommand(pluginID: "settings.1m.sh", operation: "snapshot")
        check("設定命令重新驗證檔案權限", false)
    } catch { check("設定命令重新驗證檔案權限", true) }
} catch { check("設定命令完整往返：\(error)", false) }

print("整合測試目錄：\(root)")

print("通過 \(pass)，失敗 \(fail)")
