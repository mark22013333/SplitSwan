import Foundation
// 日期標記：曆日、正規行、套用與移除、分段、原本判定（純邏輯，日期與備註均為虛構）
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
func day(_ s: String) -> CalendarDay { CalendarDay(s)! }
func days(_ a: String, _ b: String) -> ClosedRange<CalendarDay> { day(a)...day(b) }

// MARK: 曆日
check("2026-11-01 是週日", day("2026-11-01").weekday == 0)
check("1970-01-01 是週四、2000-02-29 是週二", day("1970-01-01").weekday == 4 && day("2000-02-29").weekday == 2)
check("閏年：2024-02-29、2000-02-29 存在", CalendarDay("2024-02-29") != nil && CalendarDay("2000-02-29") != nil)
check("非閏年：2026-02-29、1900-02-29 不存在", CalendarDay("2026-02-29") == nil && CalendarDay("1900-02-29") == nil)
for bad in ["2026-02-30", "2026-04-31", "2026-13-01", "2026-00-10", "2026-11-00", "0000-01-01", "2026-1-01",
            "2026/11/01", "２０２６-11-01", "2026-11-01 ", " 2026-11-01", "2026-11-0١", "", "20261101xx"] {
    check("無效日期構造不出來：「\(bad)」", CalendarDay(bad) == nil)
}
let invalidJSON = try? JSONDecoder().decode([CalendarDay].self, from: Data(#"["2026-02-30"]"#.utf8))
check("JSON 解碼也拒絕不存在的日期", invalidJSON == nil)
let decoded = try? JSONDecoder().decode([CalendarDay].self, from: Data(#"["2026-11-06"]"#.utf8))
let encoded = try JSONEncoder().encode(decoded ?? [])
check("JSON 往返", decoded == [day("2026-11-06")] && String(data: encoded, encoding: .utf8) == #"["2026-11-06"]"#)
check("跨月、跨年與閏日加減", day("2026-01-31").adding(days: 1) == day("2026-02-01")
      && day("2025-12-31").adding(days: 1) == day("2026-01-01") && day("2024-03-01").adding(days: -1) == day("2024-02-29"))
check("月份運算回到月初", day("2026-11-17").monthStart == day("2026-11-01") && day("2026-11-17").addingMonths(2) == day("2027-01-01")
      && day("2026-01-31").addingMonths(-1) == day("2025-12-01") && day("2024-02-10").daysInMonth == 29)
check("區間可直接逐日走訪", Array(days("2026-02-27", "2026-03-02")).map(\.description) == ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"])
for zone in ["Asia/Taipei", "UTC", "America/Los_Angeles"] {
    NSTimeZone.default = TimeZone(identifier: zone)!
    let d = day("2026-11-06")
    check("Date 往返在 \(zone) 下不偏移", CalendarDay(date: d.date) == d && CalendarDay(date: d.date.addingTimeInterval(86_399)) == d)
}

// MARK: 規格
let options = ["work", "off"]
var spec = PluginDateSpec(today: day("2026-11-06"), noteLimit: 20, maxEntries: 400,
                          earliest: day("2025-11-06"), latest: day("2028-11-06"),
                          baseline: .init(title: "政府日曆", weekly: ["off", "work", "work", "work", "work", "work", "off"],
                                          weeklyTitle: "週一至週五", known: .init(from: day("2026-01-01"), to: day("2026-12-31")),
                                          days: [.init(date: day("2026-10-09"), option: "off", label: "範例補假"),
                                                 .init(date: day("2026-11-21"), option: "work")]))
check("規格：範例通過驗證", (try? spec.validate(optionIDs: options)) != nil)
func rejects(_ name: String, _ ids: [String] = options, _ edit: (inout PluginDateSpec) -> Void) {
    var s = spec
    edit(&s)
    check("規格：拒絕\(name)", (try? s.validate(optionIDs: ids)) == nil)
}
rejects("noteLimit 0") { $0.noteLimit = 0 }
rejects("noteLimit 61") { $0.noteLimit = 61 }
rejects("maxEntries 401") { $0.maxEntries = 401 }
rejects("today 早於 earliest") { $0.earliest = day("2026-11-07") }
rejects("today 晚於 latest") { $0.latest = day("2026-11-05") }
rejects("空的 locked") { $0.locked = "" }
rejects("過長的 expiredHelp") { $0.expiredHelp = String(repeating: "說", count: 201) }
rejects("weekly 不是 7 筆") { $0.baseline = .init(title: "t", weekly: ["work"], weeklyTitle: "w", days: []) }
rejects("weekly 含未知選項") { $0.baseline = .init(title: "t", weekly: Array(repeating: "half", count: 7), weeklyTitle: "w", days: []) }
rejects("known 起訖顛倒") { $0.baseline?.known = .init(from: day("2026-12-31"), to: day("2026-01-01")) }
rejects("例外日重複") { $0.baseline = .init(title: "t", weekly: Array(repeating: "work", count: 7), weeklyTitle: "w",
                                          days: [.init(date: day("2026-10-09"), option: "off"), .init(date: day("2026-10-09"), option: "work")]) }
rejects("選項 id 不合規", ["Work", "off"]) { _ in }
rejects("選項超過 8 個", (0..<9).map { "o\($0)" }) { _ in }
rejects("沒有選項", []) { _ in }

// MARK: 正規行
func marks(_ lines: [String], _ s: PluginDateSpec = spec) -> DateMarks? { try? DateMarks(lines: lines, optionIDs: options, spec: s) }
let sample = ["2026-11-10 off 員工旅遊", "2026-11-11 off 員工旅遊", "2026-11-21 work 補上班", "2026-11-30 work"]
check("正規行：合規內容可解析且原樣輸出", marks(sample)?.lines == sample)
check("正規行：空陣列可解析", marks([])?.lines == [])
check("正規行：備註 20 個 scalar 可解析（含 emoji）", marks(["2026-11-10 off " + String(repeating: "旅", count: 19) + "🎉"]) != nil)
for (name, line) in [
    ("備註 21 個 scalar", "2026-11-10 off " + String(repeating: "旅", count: 21)),
    ("ZWJ 組合 emoji 超過 scalar 上限", "2026-11-10 off " + String(repeating: "👨‍👩‍👧", count: 5)),
    ("不存在的日期", "2026-02-30 off 旅遊"), ("未知類型", "2026-11-10 half 旅遊"), ("大寫類型", "2026-11-10 OFF"),
    ("多一個空白", "2026-11-10  off"), ("結尾空白", "2026-11-10 off "), ("備註前多空白", "2026-11-10 off  旅遊"),
    ("備註連續空白", "2026-11-10 off 員工  旅遊"), ("tab 分隔", "2026-11-10\toff"), ("備註含 tab", "2026-11-10 off 員工\t旅遊"),
    ("備註含 |", "2026-11-10 off 員工|旅遊"), ("備註含換行", "2026-11-10 off 員工\n旅遊"), ("備註含零寬字元", "2026-11-10 off 員工\u{200B}旅遊"),
    ("備註含雙向控制", "2026-11-10 off 員工\u{202E}旅遊"), ("備註含行分隔", "2026-11-10 off 員工\u{2028}旅遊"),
    ("全形數字日期", "２０２６-11-10 off"), ("CRLF", "2026-11-10 off\r"), ("空行", ""), ("註解", "# 2026-11-10 off"),
] { check("正規行：拒絕\(name)", marks([line]) == nil) }
check("正規行：拒絕同日重複", marks(["2026-11-10 off", "2026-11-10 work"]) == nil)
check("正規行：拒絕未排序", marks(["2026-11-11 off", "2026-11-10 off"]) == nil)
do { _ = try DateMarks(lines: ["2026-11-10 off", "壞掉"], optionIDs: options, spec: spec); check("正規行：錯誤附行號", false) }
catch { check("正規行：錯誤附行號", error.localizedDescription.contains("第 2 行")) }
check("正規行：早於 earliest 的舊覆寫仍可解析（只限制新套用）", marks(["2024-01-02 off 舊資料"]) != nil)

// MARK: 套用與移除
var m = marks([])!
try m.apply(option: "off", note: "  員工\u{3000}旅遊 ", to: days("2026-11-12", "2026-11-12"))
check("套用：逐日展開成正規行並正規化備註空白", m.lines == ["2026-11-12 off 員工 旅遊"])
m = marks([])!
try m.apply(option: "work", note: "補上班", to: days("2026-11-21", "2026-11-21"))
try m.apply(option: "off", note: "員工旅遊", to: days("2026-11-10", "2026-11-12"))
check("套用：結果依日期排序", m.lines == ["2026-11-10 off 員工旅遊", "2026-11-11 off 員工旅遊", "2026-11-12 off 員工旅遊", "2026-11-21 work 補上班"])
let applied = m
try m.apply(option: "off", note: "員工旅遊", to: days("2026-11-10", "2026-11-12"))
check("套用：同內容再套用一次結果不變（冪等）", m == applied)
try m.apply(option: "work", note: "", to: days("2026-11-11", "2026-11-11"))
check("套用：同日取最後一筆、空備註不留尾端空白", m.lines == ["2026-11-10 off 員工旅遊", "2026-11-11 work", "2026-11-12 off 員工旅遊", "2026-11-21 work 補上班"])
let beforeFailures = m
for (name, attempt) in [
    ("備註 21 個 scalar", { (x: inout DateMarks) in try x.apply(option: "off", note: String(repeating: "旅", count: 21), to: days("2026-11-13", "2026-11-13")) }),
    ("備註含 |", { (x: inout DateMarks) in try x.apply(option: "off", note: "a|b", to: days("2026-11-13", "2026-11-13")) }),
    ("未知類型", { (x: inout DateMarks) in try x.apply(option: "half", note: "", to: days("2026-11-13", "2026-11-13")) }),
    ("早於 earliest", { (x: inout DateMarks) in try x.apply(option: "off", note: "", to: days("2025-11-05", "2025-11-07")) }),
    ("晚於 latest", { (x: inout DateMarks) in try x.apply(option: "off", note: "", to: days("2028-11-06", "2028-11-07")) }),
] as [(String, (inout DateMarks) throws -> Void)] {
    var copy = m
    check("套用：拒絕\(name)且內容不變", (try? attempt(&copy)) == nil && copy == beforeFailures)
}
check("套用：備註 20 個 scalar 剛好可以", (try? m.apply(option: "off", note: String(repeating: "旅", count: 20), to: days("2026-11-13", "2026-11-13"))) != nil)
m.remove(day("2026-11-13"))
var small = spec
small.maxEntries = 5
var capped = marks(["2026-11-01 off", "2026-11-02 off"], small)!
check("上限：套用後剛好 5 筆可以", (try? capped.apply(option: "work", note: "", to: days("2026-11-02", "2026-11-04"))) != nil && capped.marks.count == 4)
check("上限：取代既有日期不重複計算", (try? capped.apply(option: "off", note: "", to: days("2026-11-01", "2026-11-05"))) != nil && capped.marks.count == 5)
check("上限：超過 maxEntries 拒絕", (try? capped.apply(option: "off", note: "", to: days("2026-11-06", "2026-11-06"))) == nil && capped.marks.count == 5)
var removed = m
removed.remove(days("2026-11-11", "2026-11-30"))
check("移除：只刪範圍內", removed.lines == ["2026-11-10 off 員工旅遊"])
removed.remove(days("2026-11-11", "2026-11-30"))
check("移除：再刪一次不變（冪等）", removed.lines == ["2026-11-10 off 員工旅遊"])
removed.remove(day("2026-11-10"))
removed.remove(day("2026-11-10"))
check("移除：單日刪除冪等", removed.lines.isEmpty)
var undo = marks(sample)!
let original = undo
try undo.apply(option: "work", note: "暫時", to: days("2026-11-15", "2026-11-16"))
undo.remove(days("2026-11-15", "2026-11-16"))
check("套用後再移除回到原本內容（設定頁不會誤判有變更）", undo == original && undo.lines == sample)

// MARK: 分段與過期
let history = marks(["2026-07-31 work 盤點", "2026-08-01 work 盤點", "2026-10-30 off 颱風假",
                     "2026-11-05 off 連假", "2026-11-06 off 連假", "2026-11-07 off 連假",
                     "2026-11-10 off 員工旅遊", "2026-11-11 off 員工旅遊", "2026-11-12 off 員工旅遊",
                     "2026-11-13 off 其他", "2026-11-14 work 員工旅遊", "2026-11-21 work 補上班"])!
let (upcoming, expired) = history.runs()
check("分段：連續、同類型、同備註合成一段，其他條件不同就切開", upcoming.map { "\($0.days.first!)~\($0.days.last!)" }
      == ["2026-11-06~2026-11-07", "2026-11-10~2026-11-12", "2026-11-13~2026-11-13", "2026-11-14~2026-11-14", "2026-11-21~2026-11-21"])
check("分段：今天以前歸入已過期，跨今天的段落在今天切開", expired.map { "\($0.days.first!)~\($0.days.last!)" }
      == ["2026-07-31~2026-08-01", "2026-10-30~2026-10-30", "2026-11-05~2026-11-05"])
check("分段：每段附逐日原本判定", upcoming[1].base.map { $0?.option } == ["work", "work", "work"] && upcoming[1].base.count == 3)
var cleaned = history
cleaned.removeExpired()
check("清除已過期：只留今天與之後", cleaned.marks.first?.day == day("2026-11-06") && cleaned.marks.count == 8)
cleaned.removeExpired()
check("清除已過期：冪等", cleaned.marks.count == 8 && cleaned.runs().expired.isEmpty)

// MARK: 原本判定、摘要與預設類型
let r = history.resolve(day("2026-10-09"))
check("原本：例外日用政府日曆與標籤", r.base == .init(option: "off", sourceTitle: "政府日曆", source: .calendar(label: "範例補假"))
      && r.base?.sourceText == "政府日曆：範例補假")
check("原本：known 範圍內的一般日子用 weekly、來源是政府日曆", history.resolve(day("2026-12-31")).base == .init(option: "work", sourceTitle: "政府日曆", source: .calendar(label: nil)))
check("原本：known 範圍外以週一至週五推定", history.resolve(day("2027-01-01")).base == .init(option: "work", sourceTitle: "週一至週五", source: .weekly(inferred: true))
      && history.resolve(day("2027-01-02")).base?.option == "off" && history.resolve(day("2027-01-01")).base?.sourceText == "以週一至週五推定")
check("原本：例外日優先於週末", history.resolve(day("2026-11-21")).base?.option == "work")
check("原本：同時帶出覆寫", history.resolve(day("2026-11-21")).mark?.note == "補上班" && history.resolve(day("2026-11-22")).mark == nil)
var noBaseline = spec
noBaseline.baseline = nil
let bare = marks(["2026-11-10 off"], noBaseline)!
check("沒有 baseline：原本為空、預設類型交給畫面", bare.resolve(day("2026-11-10")).base == nil && bare.suggestedOption(for: days("2026-11-09", "2026-11-12")) == nil)
let titles = ["work": "上班", "off": "放假"]
check("摘要：原本與已覆寫天數", history.summary(of: days("2026-11-09", "2026-11-12"), titles: titles) == "原本：上班 4 天（政府日曆）　其中 3 天已覆寫為放假")
check("摘要：混合原本判定", history.summary(of: days("2026-11-20", "2026-11-22"), titles: titles)
      == "原本：上班 2 天、放假 1 天（政府日曆）　其中 1 天已覆寫為上班")
check("摘要：沒有 baseline 也沒有覆寫", bare.summary(of: days("2026-11-11", "2026-11-12"), titles: titles) == "尚無覆寫")
check("預設類型：原本都上班 → 放假", history.suggestedOption(for: days("2026-11-09", "2026-11-12")) == "off")
check("預設類型：原本都放假 → 上班", history.suggestedOption(for: days("2026-11-14", "2026-11-15")) == "work")
check("預設類型：混合 → 沿用上一次", history.suggestedOption(for: days("2026-11-13", "2026-11-15")) == nil)
check("從／到：起訖顛倒自動對調", DateMarks.range(from: day("2026-11-12"), to: day("2026-11-09"), spec: spec) == days("2026-11-09", "2026-11-12"))
check("從／到：超出 earliest／latest 回 nil", DateMarks.range(from: day("2025-11-05"), to: day("2026-11-09"), spec: spec) == nil
      && DateMarks.range(from: day("2026-11-09"), to: day("2028-11-07"), spec: spec) == nil
      && DateMarks.range(from: day("2025-11-06"), to: day("2028-11-06"), spec: spec) != nil)

// MARK: 每週重複
func fridays(_ m: DateMarks) -> [String] { m.marks.filter { $0.note == "讀書會" }.map(\.day.description) }
var weekly = marks(sample)!
let fri = try weekly.applyWeekly(option: "off", note: "讀書會", weekdays: [5], from: day("2026-11-06"), until: day("2026-11-27"))
check("每週：結束日期當天不套用", fridays(weekly) == ["2026-11-06", "2026-11-13", "2026-11-20"] && fri.applied.count == 3 && fri.skipped.isEmpty)
var multi = marks(sample)!
let tt = try multi.applyWeekly(option: "work", note: "支援", weekdays: [2, 4], from: day("2026-11-09"), until: day("2026-11-20"))
check("每週：多個星期，已有覆寫的日子略過並保留原設定", tt.applied.map(\.description) == ["2026-11-12", "2026-11-17", "2026-11-19"]
      && tt.skipped == [day("2026-11-10")] && multi.mark(on: day("2026-11-10"))?.note == "員工旅遊")
var edge = marks([])!
try edge.applyWeekly(option: "off", note: "", weekdays: [1], from: day("2028-10-30"), until: day("2028-11-07"))
check("每週：結束日期可設在 latest 隔天，latest 當天仍套用", edge.lines == ["2028-10-30 off", "2028-11-06 off"])
func weeklyRejects(_ name: String, _ body: (inout DateMarks) throws -> Void) {
    var m = marks(sample)!
    let before = m
    let threw = (try? body(&m)) == nil
    check("每週拒絕：\(name)，內容不變", threw && m == before)
}
weeklyRejects("沒選星期") { try $0.applyWeekly(option: "off", note: "", weekdays: [], from: day("2026-11-06"), until: day("2026-12-06")) }
weeklyRejects("結束日期不晚於開始日期") { try $0.applyWeekly(option: "off", note: "", weekdays: [5], from: day("2026-11-13"), until: day("2026-11-13")) }
weeklyRejects("開始日期早於 earliest") { try $0.applyWeekly(option: "off", note: "", weekdays: [5], from: day("2025-11-05"), until: day("2025-12-06")) }
weeklyRejects("結束日期超過 latest 隔天") { try $0.applyWeekly(option: "off", note: "", weekdays: [5], from: day("2028-10-30"), until: day("2028-11-08")) }
weeklyRejects("期間內每一天都已有覆寫") { try $0.applyWeekly(option: "off", note: "", weekdays: [2, 3], from: day("2026-11-09"), until: day("2026-11-12")) }
weeklyRejects("期間內沒有勾選的星期") { try $0.applyWeekly(option: "off", note: "", weekdays: [0], from: day("2026-11-09"), until: day("2026-11-14")) }
weeklyRejects("備註含「|」") { try $0.applyWeekly(option: "off", note: "a|b", weekdays: [5], from: day("2026-11-06"), until: day("2026-12-06")) }
weeklyRejects("未知類型") { try $0.applyWeekly(option: "half", note: "", weekdays: [5], from: day("2026-11-06"), until: day("2026-12-06")) }
weeklyRejects("超過筆數上限") { try $0.applyWeekly(option: "off", note: "", weekdays: Set(0...6), from: day("2026-11-06"), until: day("2028-11-06")) }

// MARK: 每週分段與整串移除
var series = marks(sample)!
try series.applyWeekly(option: "off", note: "讀書會", weekdays: [5], from: day("2026-11-13"), until: day("2026-12-12"))
try series.apply(option: "off", note: "讀書會", to: days("2027-01-01", "2027-01-01"))
try series.apply(option: "work", note: "讀書會", to: days("2027-01-08", "2027-01-08"))
let seriesRuns = series.runs().upcoming
let fridayRun = seriesRuns.first { $0.weekly }
check("分段：同類型同備註、隔 7 天的單日合成每週一段", fridayRun?.days.map(\.description) == ["2026-11-13", "2026-11-20", "2026-11-27", "2026-12-04", "2026-12-11"])
check("分段：連續區間與單日不受影響，隔超過 7 天或類型不同不合併", seriesRuns.filter { $0.weekly }.count == 1
      && seriesRuns.map { $0.days.count } == [2, 5, 1, 1, 1, 1] && seriesRuns.map { $0.days.first!.description }
      == ["2026-11-10", "2026-11-13", "2026-11-21", "2026-11-30", "2027-01-01", "2027-01-08"])
check("分段：每週段落附逐日原本判定", fridayRun?.base.count == 5)
var removedSeries = series
removedSeries.remove(fridayRun!.days)
check("移除：整串每週覆寫一次刪掉，其他覆寫保留", fridays(removedSeries) == ["2027-01-01", "2027-01-08"] && removedSeries.marks.count == 6)

print("通過 \(pass)，失敗 \(fail)")
exit(fail == 0 ? 0 : 1)
