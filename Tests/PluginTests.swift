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
check("短於 10 秒當 10 秒", L.parseFileName("a.1s.sh")?.interval == 10 && L.parseFileName("a.0s.sh")?.interval == 10)
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
var log = L.NotifyLog()
check("今天沒發過 → 發", L.shouldNotify(plugin: "p", key: "in-1", today: "2026-10-09", log: log))
log = L.recordNotify(plugin: "p", key: "in-1", today: "2026-10-09", log: log)
check("同一天同一鍵 → 不發", !L.shouldNotify(plugin: "p", key: "in-1", today: "2026-10-09", log: log))
check("同一天不同鍵 → 發", L.shouldNotify(plugin: "p", key: "in-2", today: "2026-10-09", log: log))
check("同一天同鍵但不同外掛 → 發", L.shouldNotify(plugin: "q", key: "in-1", today: "2026-10-09", log: log))
check("隔天同一鍵 → 發", L.shouldNotify(plugin: "p", key: "in-1", today: "2026-10-10", log: log))
let log2 = L.recordNotify(plugin: "p", key: "off-1", today: "2026-10-10", log: log)
check("換日只保留當天紀錄", log2.day == "2026-10-10" && log2.keys.count == 1)
check("重複記錄不重複累加", L.recordNotify(plugin: "p", key: "in-1", today: "2026-10-09", log: log).keys.count == 1)
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

var sent: [(String, String, URL?)] = []
let runner = PluginRunner(directory: URL(fileURLWithPath: pdir), stateRoot: URL(fileURLWithPath: sdir))
runner.timeout = 2
runner.notifier = { t, b, h in sent.append((t, b, h)) }
let t0 = Date()
await runner.refreshAll()
let elapsed = Date().timeIntervalSince(t0)
@MainActor func plugin(_ id: String) -> PluginRunner.Plugin? { runner.plugins.first { $0.id == id } }

check("掃描：只列可執行一般檔案（略過隱藏、不可執行、子目錄）",
      Set(runner.plugins.map(\.id)) == ["bad.1m.sh", "good.1m.sh", "linked.1m.sh", "slow.10s.sh", "writable.1m.sh"])
let good = plugin("good.1m.sh")
check("正常外掛解析成功", good?.failure == nil && good?.output?.title == "正常外掛")
let texts = good?.output?.items.map(\.text) ?? []
check("SPLITSWAN_PLUGIN_STATE 指向 state/<名稱>", texts.contains("state=" + sdir + "/good"))
check("SPLITSWAN=1 與固定 PATH", texts.contains("flag=1 path=" + PluginRunner.pluginPATH))
check("App 的其他環境變數不會傳給外掛", texts.contains("secret=none"))
check("stderr 不混進輸出", !texts.contains("錯誤輸出"))
check("狀態資料夾權限 700", (try? fm.attributesOfItem(atPath: sdir + "/good")[.posixPermissions] as? Int) == 0o700)
let w = plugin("writable.1m.sh")
check("group 可寫的外掛被拒且沒有執行", w?.problem?.contains("其他使用者寫入") == true && w?.lastRun == nil
      && !fm.fileExists(atPath: sdir + "/writable/ran"))
check("symlink 依解析後目標檢查：所在資料夾 group 可寫被拒", plugin("linked.1m.sh")?.problem?.contains("資料夾") == true)
let slow = plugin("slow.10s.sh")
check("逾時外掛標錯誤", slow?.error?.contains("逾時") == true && slow?.output == nil)
check("逾時不會拖住整體（並行、約 2～4 秒）", elapsed < 6)
check("非 0 結束標錯誤並附 stderr 最後一行", plugin("bad.1m.sh")?.error == "結束碼 3：壞掉的原因")
check("間隔解析：slow 為 10 秒", slow?.interval == 10)
check("notify：發出一則，標題為外掛標題、帶 href", sent.count == 1 && sent.first?.0 == "正常外掛" && sent.first?.1 == "提醒"
      && sent.first?.2?.absoluteString == "https://example.com/punch")
await runner.run("good.1m.sh")
check("同一天再跑一次不重複通知", sent.count == 1)
check("通知紀錄寫成 600 檔案", (try? fm.attributesOfItem(atPath: sdir + "/notified.json")[.posixPermissions] as? Int) == 0o600)
// 換一個新的 runner（模擬 App 重新啟動）：從檔案讀回紀錄，仍不重複
let runner2 = PluginRunner(directory: URL(fileURLWithPath: pdir), stateRoot: URL(fileURLWithPath: sdir))
runner2.timeout = 2
var sent2 = 0
runner2.notifier = { _, _, _ in sent2 += 1 }
runner2.scan()
await runner2.run("good.1m.sh")
check("重新啟動後讀回去重紀錄", sent2 == 0)

// 點擊動作：bash=$0 param1=mark refresh=true → 執行外掛自己並重跑
if let mark = good?.output?.items.first(where: { $0.text == "標記" }) {
    check("bash= 是外掛自己的絕對路徑", mark.bash == PluginRunner.realPath(pdir + "/good.1m.sh") && mark.bashArgs == ["mark"])
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
check("bash= 指向 root 擁有的程式被拒", plugin("good.1m.sh")?.error?.contains("點擊動作被拒") == true)

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
print("整合測試目錄：\(root)")

print("通過 \(pass)，失敗 \(fail)")
