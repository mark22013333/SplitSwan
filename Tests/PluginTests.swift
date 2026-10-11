import Combine
import Foundation
// 外掛區塊：PluginLogic 純邏輯＋PluginRunner 實跑假外掛的整合測試。
// 整合測試只在 argv[1]（run-tests.sh 給的暫存目錄）底下建立檔案，不碰 ~/.config/splitswan。
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
typealias L = PluginLogic
typealias Item = PluginLogic.Item

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
put("slow.10s.sh", "#!/bin/bash\necho 慢\nsleep 30\n")
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
let runner = PluginRunner(directory: URL(fileURLWithPath: pdir), stateRoot: URL(fileURLWithPath: sdir))
runner.timeout = 2
runner.notifier = { t, st, b, h in sent.append((t, st, b, h)) }
let t0 = Date()
await runner.refreshAll()
let elapsed = Date().timeIntervalSince(t0)
@MainActor func plugin(_ id: String) -> PluginRunner.Plugin? { runner.plugins.first { $0.id == id } }

check("掃描：只列可執行一般檔案（略過隱藏、不可執行、子目錄）",
      Set(runner.plugins.map(\.id)) == ["bad.1m.sh", "good.1m.sh", "linked.1m.sh", "slow.10s.sh", "writable.1m.sh"])
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
let slow = plugin("slow.10s.sh")
check("逾時外掛標錯誤", slow?.error?.contains("逾時") == true && slow?.output == nil)
check("逾時不會拖住整體（並行、約 2～4 秒）", elapsed < 6)
check("非 0 結束標錯誤並附 stderr 最後一行", plugin("bad.1m.sh")?.error == "結束碼 3：壞掉的原因")
check("間隔解析：slow.10s 拉高到 30 秒", slow?.interval == 30)
check("notify：發出一則，標題固定「外掛：good」、輸出標題只放副標題、帶 href", sent.count == 1 && sent.first?.0 == "外掛：good"
      && sent.first?.1 == "正常外掛" && sent.first?.2 == "提醒" && sent.first?.3?.absoluteString == "https://example.com/punch")
await runner.run("good.1m.sh")
check("同一天再跑一次不重複通知", sent.count == 1)
let notifiedFile = sdir + "/.notified/good.1m.sh.json"
for _ in 0..<20 where !fm.fileExists(atPath: notifiedFile) { try? await Task.sleep(nanoseconds: 100_000_000) }
check("每個外掛一份通知紀錄，600", (try? fm.attributesOfItem(atPath: notifiedFile)[.posixPermissions] as? Int) == 0o600)
// 換一個新的 runner（模擬 App 重新啟動）：從檔案讀回紀錄，仍不重複
let runner2 = PluginRunner(directory: URL(fileURLWithPath: pdir), stateRoot: URL(fileURLWithPath: sdir))
runner2.timeout = 2
var sent2 = 0
runner2.notifier = { _, _, _, _ in sent2 += 1 }
runner2.scan()
await runner2.run("good.1m.sh")
check("重新啟動後讀回去重紀錄", sent2 == 0)

// 點擊動作：bash=$0 param1=mark refresh=true → 執行外掛自己並重跑
if let mark = good?.output?.items.first(where: { $0.text == "標記" }) {
    check("bash= 是外掛自己的絕對路徑（\(mark.bash ?? "nil")｜\(mark.bashArgs)）", mark.bash.flatMap(PluginRunner.realPath) == PluginRunner.realPath(pdir + "/good.1m.sh") && mark.bashArgs == ["mark"])
    runner.perform(pluginID: "good.1m.sh", item: mark)
    var ok = false
    for _ in 0..<40 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        if plugin("good.1m.sh")?.output?.items.contains(where: { $0.text == "已標記" }) == true { ok = true; break }
    }
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
@MainActor func tryClick(_ line: String) async -> String? {
    runner.perform(pluginID: "good.1m.sh", item: L.parseLine(line))
    try? await Task.sleep(nanoseconds: 1_500_000_000)
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
let e6 = await tryClick("x | bash=\(pdir)/good.1m.sh param1=mark")
check("正對照：bash= 指向外掛本身可執行", e6 == nil)

// 輸出上限在讀取時生效：大量輸出不會讓記憶體暴增，仍會逾時／正常結束
func maxRSS() -> Int { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Int(u.ru_maxrss) }
let big2 = root + "/big"
try! fm.createDirectory(atPath: big2, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
put("yes.1m.sh", "#!/bin/bash\necho Y\necho ---\nexec /usr/bin/yes\n", dir: big2)
put("burst.1m.sh", "#!/bin/bash\necho B\necho ---\n/usr/bin/yes 0123456789 | head -c 3000000\nexit 0\n", dir: big2)
let runner5 = PluginRunner(directory: URL(fileURLWithPath: big2), stateRoot: URL(fileURLWithPath: sdir))
runner5.timeout = 2
runner5.scan()
let rss0 = maxRSS()
await runner5.run("yes.1m.sh")
let rss1 = maxRSS()
// 3 MB 要能在時限內讀完：高負載下 2 秒不夠，這裡驗的是截斷不是逾時
runner5.timeout = 10
await runner5.run("burst.1m.sh")
let y5 = runner5.plugins.first { $0.id == "yes.1m.sh" }, b5 = runner5.plugins.first { $0.id == "burst.1m.sh" }
check("無止盡輸出：仍正常逾時", y5?.error?.contains("逾時") == true)
check("無止盡輸出：峰值記憶體增加 < 64 MB（實際 \((rss1 - rss0) / 1_048_576) MB）", rss1 - rss0 < 64 * 1_048_576)
check("3 MB 輸出後正常結束：成功解析並標記截斷、項目 ≤ 30", b5?.error == nil && b5?.output?.truncated == true
      && (b5?.output?.items.count ?? 99) <= L.maxItems)
let lim = await ProcessRunner.runLimited("/usr/bin/yes", [], timeout: 1, maxBytes: 1000)
check("ProcessRunner maxBytes：收到的輸出 ≤ 上限且逾時", lim.output.utf8.count <= 1000 && lim.timedOut)
let full = await ProcessRunner.execute("/bin/sh", ["-c", "/usr/bin/yes 0123456789 | head -c 200000"], timeout: 5)
check("ProcessRunner 預設不限：200 KB 完整收到、未截斷", full.output.utf8.count == 200000 && !full.truncated && full.code == 0)
let cut = await ProcessRunner.execute("/bin/sh", ["-c", "/usr/bin/yes 0123456789 | head -c 200000"], timeout: 5, maxBytes: 5000)
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
put("slow.1m.sh", "#!/bin/bash\necho \"start $$\" >> \"\(slowLog)\"\nsleep 1\necho \"end $$\" >> \"\(slowLog)\"\necho S\necho ---\necho \"點 | bash=$0 param1=x\"\n", dir: ov)
let runner6 = PluginRunner(directory: URL(fileURLWithPath: ov), stateRoot: URL(fileURLWithPath: sdir))
runner6.timeout = 10   // 高負載下 sleep 1 的腳本也可能超過 3 秒
func maxDepth() -> (Int, Int) {
    let lines = ((try? String(contentsOfFile: slowLog, encoding: .utf8)) ?? "").split(separator: "\n")
    var d = 0, m = 0
    for l in lines { d += l.hasPrefix("start") ? 1 : -1; m = max(m, d) }
    return (m, lines.filter { $0.hasPrefix("start") }.count)
}
runner6.scan()
let t6 = Task { await runner6.run("slow.1m.sh") }
try? await Task.sleep(nanoseconds: 300_000_000)
runner6.setEnabled(false)
runner6.setEnabled(true)
try? await Task.sleep(nanoseconds: 2_500_000_000)
_ = await t6.value
runner6.setEnabled(false)
let (d1, cnt1) = maxDepth()
check("關閉後立刻重開不重疊執行（最大同時 \(d1)，共 \(cnt1) 次）", d1 == 1 && cnt1 >= 1)
try? "".write(toFile: slowLog, atomically: false, encoding: .utf8)
runner6.scan()
await runner6.run("slow.1m.sh")
try? "".write(toFile: slowLog, atomically: false, encoding: .utf8)
let t7 = Task { await runner6.run("slow.1m.sh") }
try? await Task.sleep(nanoseconds: 300_000_000)
if let click = runner6.plugins.first(where: { $0.id == "slow.1m.sh" })?.output?.items.first(where: { $0.text == "點" }) {
    runner6.perform(pluginID: "slow.1m.sh", item: click)
} else { check("找到「點」項目", false) }
_ = await t7.value
try? await Task.sleep(nanoseconds: 3_000_000_000)
let (d2, cnt2) = maxDepth()
check("點擊 bash= 與排程執行不重疊（最大同時 \(d2)，共 \(cnt2) 次）", d2 == 1 && cnt2 == 2)

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
pr.timeout = 3
pr.setEnabled(false)
let r0 = pr.resources
check("關閉（從未開啟）：0 個 timer、不監看、0 個事件訂閱", r0.timers == 0 && !r0.watching && r0.observers == 0)
check("關閉：沒有掃描（plugins 空）、沒有建立 plugin-state", pr.plugins.isEmpty && !fm.fileExists(atPath: perfState))
pr.refreshIfEnabled()
try? await Task.sleep(nanoseconds: 300_000_000)
check("關閉時 refreshIfEnabled 不做事", pr.plugins.isEmpty && !fm.fileExists(atPath: perfState))
pr.setEnabled(true)
for _ in 0..<30 where pr.lastRuns.count < 2 { try? await Task.sleep(nanoseconds: 100_000_000) }
let r1 = pr.resources
check("開啟：每個外掛一個 timer、監看資料夾、訂閱 8 個睡眠／鎖定事件", r1.timers == 2 && r1.watching && r1.observers == 8)
check("開啟後各跑一次", pr.lastRuns.count == 2)
check("timer 容許誤差：1m → 6 秒、5m → 30 秒", pr.timerTolerance("a.1m.sh") == 6 && pr.timerTolerance("b.5m.sh") == 30)
// 監看：新增外掛 → 約 1 秒後自動出現並執行（不靠輪詢）
put("c.1m.sh", "#!/bin/bash\necho C\n", dir: perfDir)
for _ in 0..<40 where pr.lastRuns["c.1m.sh"] == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
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
for _ in 0..<30 where pr.lastRuns["a.1m.sh"] == ranA { try? await Task.sleep(nanoseconds: 100_000_000) }
check("解鎖後各跑一次並恢復排程", pr.lastRuns["a.1m.sh"] != ranA && pr.resources.timers == 3)
pr.resume(.screenSaver)
check("沒暫停過的原因解除不會多跑", pr.resources.timers == 3)
pr.setEnabled(false)
let r2 = pr.resources
check("再關閉：timer、監看、事件訂閱全部釋放", r2.timers == 0 && !r2.watching && r2.observers == 0 && pr.plugins.isEmpty)
// 同時執行上限 2
let cc = root + "/cc", ccLog = root + "/cc.log"
try! fm.createDirectory(atPath: cc, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
for i in 1...4 { put("c\(i).1m.sh", "#!/bin/bash\necho \"start\" >> \"\(ccLog)\"\nsleep 0.8\necho \"end\" >> \"\(ccLog)\"\necho C\n", dir: cc) }
let ccr = PluginRunner(directory: URL(fileURLWithPath: cc), stateRoot: URL(fileURLWithPath: perfState))
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
let dupR = PluginRunner(directory: URL(fileURLWithPath: dupDir), stateRoot: URL(fileURLWithPath: dupState))
await dupR.refreshAll()
check("a.1m.sh 與 a.5m.py 各自的狀態資料夾", dupR.plugins.first { $0.id == "a.1m.sh" }?.output?.title == dupState + "/a.1m.sh"
      && dupR.plugins.first { $0.id == "a.5m.py" }?.output?.title == dupState + "/a.5m.py")
// stderr 有上限、不寫檔
let errDir = mkPluginDir("stderr"), errState = root + "/sec-stderr/state"
put("e.1m.sh", "#!/bin/bash\nhead -c 3000000 /dev/zero | tr '\\0' 'e' >&2\necho >&2\necho 最後一行 >&2\nexit 2\n", dir: errDir)
let errR = PluginRunner(directory: URL(fileURLWithPath: errDir), stateRoot: URL(fileURLWithPath: errState))
errR.timeout = 5
await errR.refreshAll()
let errMsg = errR.plugins.first?.error ?? ""
check("大量 stderr：錯誤訊息有上限（\(errMsg.utf8.count) bytes）", errMsg.hasPrefix("結束碼 2") && errMsg.utf8.count < 700)
check("大量 stderr 之後的最後一行仍顯示（保留最後 4 KB）", errMsg == "結束碼 2：最後一行")
check("stderr 不再寫進狀態資料夾", !fm.fileExists(atPath: errState + "/e.1m.sh/.stderr"))
let rawErr = await ProcessRunner.execute("/bin/sh", ["-c", "head -c 100000 /dev/zero >&2; echo out"], timeout: 5, stderrLimit: 4096)
check("ProcessRunner stderrLimit：stderr 分開且 ≤ 4 KB、stdout 不混入", rawErr.errorOutput.utf8.count == 4096 && rawErr.output == "out\n")
let tailErr = await ProcessRunner.execute("/bin/sh", ["-c", "echo FIRST >&2; head -c 100000 /dev/zero | tr '\\0' x >&2; echo; echo LAST >&2"], timeout: 5, stderrLimit: 4096)
check("stderr 保留最後 4 KB：有 LAST、沒有 FIRST", tailErr.errorOutput.hasSuffix("LAST\n") && !tailErr.errorOutput.contains("FIRST")
      && tailErr.errorOutput.utf8.count == 4096)
// 關閉／暫停的完整性（M1）
let m1Dir = mkPluginDir("m1"), m1Log = root + "/sec-m1/ran.log"
for n in ["s1", "s2", "s3"] {
    put("\(n).1m.sh", "#!/bin/bash\necho \(n) >> \"\(m1Log)\"\nsleep 2\necho T\necho ---\necho \"hi | notify=true notify_id=\(n)\"\n", dir: m1Dir)
}
let m1 = PluginRunner(directory: URL(fileURLWithPath: m1Dir), stateRoot: URL(fileURLWithPath: root + "/sec-m1/state"))
m1.timeout = 5
var m1Sent = 0
m1.notifier = { _, _, _, _ in m1Sent += 1 }
func m1Runs() -> Int { ((try? String(contentsOfFile: m1Log, encoding: .utf8)) ?? "").split(separator: "\n").count }
/// 等到外掛真的寫下開始紀錄（最多 5 秒）；固定等待在高負載時會在程序已啟動、還沒寫紀錄的瞬間取樣
func waitRuns(_ n: Int) async { for _ in 0..<250 where m1Runs() < n { try? await Task.sleep(nanoseconds: 20_000_000) } }
m1.setEnabled(true)
await waitRuns(2)
m1.setEnabled(false)
try? await Task.sleep(nanoseconds: 3_500_000_000)
check("關閉後：排隊中的第 3 個不開始（實際 \(m1Runs()) 個）", m1Runs() == 2)
check("關閉後：進行中的完成也不發通知、不寫紀錄、不更新選單", m1Sent == 0 && m1.plugins.isEmpty
      && !fm.fileExists(atPath: root + "/sec-m1/state/.notified"))
m1.setEnabled(true)
await waitRuns(4)   // 前一輪 2 個＋這一輪佔滿 2 個執行名額
let runsBeforePause = m1Runs()
m1.pause(.locked)
try? await Task.sleep(nanoseconds: 3_500_000_000)
check("暫停後：排隊中的不開始、進行中的不發通知、不更新輸出（暫停前 \(runsBeforePause)、之後 \(m1Runs())、通知 \(m1Sent)）", m1Runs() == runsBeforePause && m1Sent == 0
      && m1.plugins.allSatisfy { $0.output == nil })
m1.resume(.locked)
for _ in 0..<150 where m1Sent < 3 { try? await Task.sleep(nanoseconds: 100_000_000) }
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
rr.timeout = 5
var rrSent = 0
rr.notifier = { _, _, _, _ in rrSent += 1 }
rr.setEnabled(true)
try? await Task.sleep(nanoseconds: 400_000_000)
rr.setEnabled(false); rr.setEnabled(true)
for _ in 0..<40 where !(rr.plugins.count == 2 && rr.plugins.allSatisfy({ $0.output != nil })) { try? await Task.sleep(nanoseconds: 100_000_000) }
check("關閉後立刻重開：舊的結束後補跑，約 2 秒內都有輸出（\(rr.plugins.map { $0.output?.title ?? "nil" })，通知 \(rrSent)）", rr.plugins.count == 2 && rr.plugins.allSatisfy { $0.output != nil } && rrSent == 2)
rr.setEnabled(false)
let rr2 = PluginRunner(directory: URL(fileURLWithPath: rDir), stateRoot: URL(fileURLWithPath: rState + "2"))
rr2.timeout = 5
var rr2Sent = 0
rr2.notifier = { _, _, _, _ in rr2Sent += 1 }
rr2.setEnabled(true)
try? await Task.sleep(nanoseconds: 400_000_000)
rr2.pause(.locked)
try? await Task.sleep(nanoseconds: 200_000_000)
rr2.resume(.locked)                                   // 舊的那次還在跑
check("暫停中途恢復：舊的那次結果不採用（M1）", rr2.plugins.allSatisfy { $0.output == nil } && rr2Sent == 0)
for _ in 0..<40 where !(rr2.plugins.count == 2 && rr2.plugins.allSatisfy({ $0.output != nil })) { try? await Task.sleep(nanoseconds: 100_000_000) }
check("暫停中途恢復：舊的結束後補跑並發通知", rr2.plugins.count == 2 && rr2.plugins.allSatisfy { $0.output != nil } && rr2Sent == 2)
rr2.setEnabled(false)
check("補跑期間同一外掛不重疊（同一支最大同時 \(m1Depth())）", m1Depth() == 1)

print("整合測試目錄：\(root)")

print("通過 \(pass)，失敗 \(fail)")
