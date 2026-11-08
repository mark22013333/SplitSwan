import Foundation

/// 無時區的曆日（proleptic Gregorian）。只能由驗證過的文字、`Date` 或日數運算產生，所以 2026-02-30 這種值不存在。
struct CalendarDay: Hashable, Comparable, Strideable, Sendable, CustomStringConvertible, Codable {
    let year: Int, month: Int, day: Int
    /// 自 1970-01-01 起的日數。
    let serial: Int

    private init(serial: Int) {
        // Howard Hinnant 的 civil_from_days，對負數日數也正確。
        let z = serial + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.year = yoe + era * 400 + (m <= 2 ? 1 : 0)
        self.month = m
        self.day = d
        self.serial = serial
    }
    private static func serial(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
    static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }
    static func days(inMonth month: Int, of year: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// 只收 `[0-9]{4}-[0-9]{2}-[0-9]{2}` 且為真實日期；全形數字與其他 Unicode 數字一律不收。
    init?(_ text: String) {
        let b = Array(text.utf8)
        guard b.count == 10, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b[i]) else { return nil }
                value = value * 10 + Int(b[i] - UInt8(ascii: "0"))
            }
            return value
        }
        guard let y = number(0..<4), let m = number(5..<7), let d = number(8..<10), y >= 1,
              (1...12).contains(m), (1...Self.days(inMonth: m, of: y)).contains(d) else { return nil }
        self.init(serial: Self.serial(y, m, d))
    }
    /// 給「從／到」日期欄位用：固定以 UTC 換算，本機時區不會讓日期偏移一天。
    init(date: Date) { self.init(serial: Int((date.timeIntervalSince1970 / 86_400).rounded(.down))) }
    var date: Date { Date(timeIntervalSince1970: Double(serial) * 86_400) }

    /// 0＝週日。1970-01-01 是週四。
    var weekday: Int { ((serial % 7) + 7 + 4) % 7 }
    func adding(days: Int) -> CalendarDay { CalendarDay(serial: serial + days) }
    var monthStart: CalendarDay { CalendarDay(serial: Self.serial(year, month, 1)) }
    /// 回傳 n 個月後那個月的第一天。
    func addingMonths(_ n: Int) -> CalendarDay {
        let index = year * 12 + (month - 1) + n
        return CalendarDay(serial: Self.serial(index / 12, index % 12 + 1, 1))
    }
    var daysInMonth: Int { Self.days(inMonth: month, of: year) }
    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (a: CalendarDay, b: CalendarDay) -> Bool { a.serial < b.serial }
    static func == (a: CalendarDay, b: CalendarDay) -> Bool { a.serial == b.serial }
    func hash(into hasher: inout Hasher) { hasher.combine(serial) }
    func distance(to other: CalendarDay) -> Int { other.serial - serial }
    func advanced(by n: Int) -> CalendarDay { adding(days: n) }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = CalendarDay(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "不是真實日期：\(text)"))
        }
        self = day
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

struct DateMarksError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 外掛在 stringList 欄位上宣告的 `dates`；契約見 docs/plugin-settings.md「日期標記編輯器」。
struct PluginDateSpec: Codable, Equatable, Sendable {
    let today: CalendarDay
    var noteLimit: Int? = nil, maxEntries: Int? = nil
    var earliest: CalendarDay? = nil, latest: CalendarDay? = nil
    var locked: String? = nil, expiredHelp: String? = nil
    var baseline: Baseline? = nil

    struct Baseline: Codable, Equatable, Sendable {
        let title: String, weekly: [String], weeklyTitle: String
        var known: Span? = nil
        let days: [Day]
        struct Day: Codable, Equatable, Sendable { let date: CalendarDay; let option: String; var label: String? = nil }
    }
    struct Span: Codable, Equatable, Sendable { let from: CalendarDay; let to: CalendarDay }

    var effectiveNoteLimit: Int { noteLimit ?? 20 }
    var effectiveMaxEntries: Int { maxEntries ?? 400 }

    static func validOptionID(_ id: String) -> Bool {
        let s = Array(id.utf8)
        guard (1...16).contains(s.count), (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(s[0]) else { return false }
        return s.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: "-") }
    }

    func validate(optionIDs: [String]) throws {
        func text(_ value: String, _ limit: Int) -> Bool { !value.isEmpty && value.count <= limit }
        guard (1...8).contains(optionIDs.count), Set(optionIDs).count == optionIDs.count,
              optionIDs.allSatisfy(Self.validOptionID) else { throw DateMarksError("選項必須是 1～8 個小寫英數識別碼") }
        guard (1...60).contains(effectiveNoteLimit), (1...400).contains(effectiveMaxEntries) else {
            throw DateMarksError("noteLimit 或 maxEntries 超出範圍")
        }
        guard (earliest ?? today) <= today, today <= (latest ?? today) else { throw DateMarksError("earliest、today、latest 順序不正確") }
        guard locked.map({ text($0, 200) }) ?? true, (expiredHelp?.count ?? 0) <= 200 else {
            throw DateMarksError("locked 或 expiredHelp 文字長度不正確")
        }
        guard let b = baseline else { return }
        guard text(b.title, 40), text(b.weeklyTitle, 40), b.weekly.count == 7, b.weekly.allSatisfy(optionIDs.contains),
              b.known.map({ $0.from <= $0.to }) ?? true, b.days.count <= 400,
              Set(b.days.map(\.date)).count == b.days.count,
              b.days.allSatisfy({ optionIDs.contains($0.option) && ($0.label.map { text($0, 40) } ?? true) })
        else { throw DateMarksError("baseline 格式不正確") }
    }
}

struct DateMark: Equatable, Sendable { let day: CalendarDay; let option: String; let note: String }

struct Resolution: Equatable, Sendable {
    enum Source: Equatable, Sendable { case calendar(label: String?), weekly(inferred: Bool) }
    struct Base: Equatable, Sendable {
        let option: String; let sourceTitle: String; let source: Source
        /// 「原本：上班（政府日曆）」括號內的文字。
        var sourceText: String {
            switch source {
            case .calendar(let label): label.map { "\(sourceTitle)：\($0)" } ?? sourceTitle
            case .weekly(let inferred): inferred ? "以\(sourceTitle)推定" : sourceTitle
            }
        }
    }
    let mark: DateMark?; let base: Base?
}

/// 不變式：依日期排序、日期唯一、每筆都是正規行。只能經過驗證的 init 或 mutating 方法產生。
struct DateMarks: Equatable, Sendable {
    private(set) var marks: [DateMark]
    let optionIDs: [String]
    let spec: PluginDateSpec

    /// 正規行：`YYYY-MM-DD <optionId>[ <備註>]`，每個分隔都剛好是一個 ASCII 空白。
    static func parse(line: String, optionIDs: [String], noteLimit: Int) -> DateMark? {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 12, scalars[10] == " ",
              let day = CalendarDay(String(String.UnicodeScalarView(scalars[0..<10]))) else { return nil }
        let rest = scalars[11...]
        let split = rest.firstIndex(of: " ")
        let option = String(String.UnicodeScalarView(rest[..<(split ?? rest.endIndex)]))
        let note = split.map { String(String.UnicodeScalarView(rest[($0 + 1)...])) } ?? ""
        guard optionIDs.contains(option), split == nil || !note.isEmpty, validNote(note, limit: noteLimit) else { return nil }
        return DateMark(day: day, option: option, note: note)
    }
    /// 空字串代表沒有備註；其餘必須是 1～limit 個 scalar，不含 Cc／Cf／Zl／Zp 與「|」，前後沒有空白，也沒有連續空白。
    static func validNote(_ note: String, limit: Int) -> Bool {
        let s = Array(note.unicodeScalars)
        if s.isEmpty { return true }
        guard s.count <= limit, !s[0].properties.isWhitespace, !s[s.count - 1].properties.isWhitespace else { return false }
        for (i, c) in s.enumerated() {
            switch c.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: break
            }
            if c == "|" || (c.properties.isWhitespace && i > 0 && s[i - 1].properties.isWhitespace) { return false }
        }
        return true
    }
    /// 使用者輸入的備註：任何空白都換成一個 ASCII 空白並去頭尾，與外掛寫檔的正規化一致。
    static func normalizedNote(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for c in text.unicodeScalars {
            if c.properties.isWhitespace { pendingSpace = !out.isEmpty; continue }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(c)
        }
        return String(out)
    }

    init(lines: [String], optionIDs: [String], spec: PluginDateSpec) throws {
        var marks: [DateMark] = []
        for (i, line) in lines.enumerated() {
            guard let mark = Self.parse(line: line, optionIDs: optionIDs, noteLimit: spec.effectiveNoteLimit) else {
                throw DateMarksError("第 \(i + 1) 行不是正規的日期標記")
            }
            if let last = marks.last, last.day >= mark.day { throw DateMarksError("第 \(i + 1) 行的日期重複或未依日期排序") }
            marks.append(mark)
        }
        self.marks = marks
        self.optionIDs = optionIDs
        self.spec = spec
    }

    var lines: [String] { marks.map { "\($0.day) \($0.option)" + ($0.note.isEmpty ? "" : " " + $0.note) } }

    /// 同日已有覆寫就取代（最後一次套用為準）。範圍外、選項不存在、備註不合規或超過上限就 throw，內容不變。
    mutating func apply(option: String, note: String, to days: ClosedRange<CalendarDay>) throws {
        let note = try validated(option: option, note: note)
        guard Self.range(from: days.lowerBound, to: days.upperBound, spec: spec) == days else {
            throw DateMarksError("日期超出可設定的範圍")
        }
        try replace(Array(days), option: option, note: note)
    }

    struct WeeklyResult: Equatable { let applied: [CalendarDay]; let skipped: [CalendarDay] }
    /// 從 `from` 起、到 `until` 前一天為止（`until` 當天不套用），把勾選星期的日子設成同一個覆寫；已有覆寫的日子略過。
    @discardableResult
    mutating func applyWeekly(option: String, note: String, weekdays: Set<Int>, from: CalendarDay, until: CalendarDay) throws -> WeeklyResult {
        let note = try validated(option: option, note: note)
        guard !weekdays.isEmpty else { throw DateMarksError("請至少勾選一個星期") }
        guard from < until else { throw DateMarksError("結束日期必須晚於開始日期") }
        guard Self.range(from: from, to: until.adding(days: -1), spec: spec) != nil else { throw DateMarksError("日期超出可設定的範圍") }
        let candidates = (from..<until).filter { weekdays.contains($0.weekday) }
        let marked = Set(marks.map(\.day))
        let result = WeeklyResult(applied: candidates.filter { !marked.contains($0) }, skipped: candidates.filter(marked.contains))
        guard !result.applied.isEmpty else {
            throw DateMarksError(candidates.isEmpty ? "這段期間沒有勾選的星期" : "這段期間勾選的日子都已有覆寫")
        }
        try replace(result.applied, option: option, note: note)
        return result
    }

    private func validated(option: String, note: String) throws -> String {
        guard optionIDs.contains(option) else { throw DateMarksError("沒有這個覆寫類型") }
        let note = Self.normalizedNote(note)
        guard note.unicodeScalars.count <= spec.effectiveNoteLimit else { throw DateMarksError("備註最多 \(spec.effectiveNoteLimit) 個字") }
        guard Self.validNote(note, limit: spec.effectiveNoteLimit) else { throw DateMarksError("備註不能包含「|」或控制字元") }
        return note
    }
    private mutating func replace(_ days: [CalendarDay], option: String, note: String) throws {
        let targets = Set(days)
        let kept = marks.filter { !targets.contains($0.day) }
        guard kept.count + targets.count <= spec.effectiveMaxEntries else {
            throw DateMarksError("套用後會超過 \(spec.effectiveMaxEntries) 筆上限，請先清除已過期或不需要的覆寫")
        }
        marks = (kept + targets.map { DateMark(day: $0, option: option, note: note) }).sorted { $0.day < $1.day }
    }
    mutating func remove<S: Sequence>(_ days: S) where S.Element == CalendarDay {
        let targets = Set(days)
        marks.removeAll { targets.contains($0.day) }
    }
    mutating func remove(_ day: CalendarDay) { marks.removeAll { $0.day == day } }
    mutating func removeExpired() { marks.removeAll { $0.day < spec.today } }

    struct Run: Equatable {
        let days: [CalendarDay]; let option: String; let note: String; let base: [Resolution.Base?]
        /// 每週重複：至少兩天、彼此相隔 7 天。
        var weekly: Bool { days.count > 1 && days[1] == days[0].adding(days: 7) }
    }
    /// 連續日期、同類型、同備註合成一段；剩下的單日若同類型、同備註且剛好相隔 7 天，再合成每週一段。
    /// 跨越「今天」的段落在今天切開，過去的部分歸入已過期。
    func runs() -> (upcoming: [Run], expired: [Run]) {
        typealias Span = (days: [CalendarDay], option: String, note: String)
        func expired(_ day: CalendarDay) -> Bool { day < spec.today }
        var spans: [Span] = []
        for m in marks {
            if let last = spans.last?.days.last, last.adding(days: 1) == m.day, spans[spans.count - 1].option == m.option,
               spans[spans.count - 1].note == m.note, expired(last) == expired(m.day) {
                spans[spans.count - 1].days.append(m.day)
            } else {
                spans.append(([m.day], m.option, m.note))
            }
        }
        var grouped: [Span] = []
        var open: [String: Int] = [:]
        for span in spans {
            guard span.days.count == 1, let day = span.days.first else { grouped.append(span); continue }
            let key = "\(span.option)|\(span.note)|\(day.weekday)|\(expired(day))"
            if let i = open[key], grouped[i].days.last?.adding(days: 7) == day {
                grouped[i].days.append(day)
            } else {
                open[key] = grouped.count
                grouped.append(span)
            }
        }
        let all = grouped.map { Run(days: $0.days, option: $0.option, note: $0.note, base: $0.days.map { resolve($0).base }) }
        return (all.filter { !expired($0.days[0]) }, all.filter { expired($0.days[0]) })
    }

    func mark(on day: CalendarDay) -> DateMark? { marks.first { $0.day == day } }
    func resolve(_ day: CalendarDay) -> Resolution {
        guard let b = spec.baseline else { return Resolution(mark: mark(on: day), base: nil) }
        let base: Resolution.Base
        if let exception = b.days.first(where: { $0.date == day }) {
            base = .init(option: exception.option, sourceTitle: b.title, source: .calendar(label: exception.label))
        } else if let known = b.known, known.from <= day, day <= known.to {
            base = .init(option: b.weekly[day.weekday], sourceTitle: b.title, source: .calendar(label: nil))
        } else {
            base = .init(option: b.weekly[day.weekday], sourceTitle: b.weeklyTitle, source: .weekly(inferred: b.known != nil))
        }
        return Resolution(mark: mark(on: day), base: base)
    }

    /// 選取區下方的說明，例：「原本：上班 4 天（政府日曆）　其中 3 天已覆寫為放假」。
    func summary(of days: ClosedRange<CalendarDay>, titles: [String: String]) -> String {
        let resolved = days.map(resolve)
        func title(_ id: String) -> String { titles[id] ?? id }
        func counts(_ ids: [String]) -> [String] {
            optionIDs.compactMap { id in
                let n = ids.filter { $0 == id }.count
                return n == 0 ? nil : "\(title(id)) \(n) 天"
            }
        }
        var parts: [String] = []
        let bases = resolved.compactMap(\.base)
        if bases.count == resolved.count {
            var sources: [String] = []
            for s in bases.map(\.sourceText) where !sources.contains(s) { sources.append(s) }
            parts.append("原本：" + counts(bases.map(\.option)).joined(separator: "、") + "（\(sources.prefix(3).joined(separator: "、"))）")
        }
        let marked = resolved.compactMap(\.mark?.option)
        if !marked.isEmpty {
            let kinds = Set(marked)
            parts.append(kinds.count == 1 ? "其中 \(marked.count) 天已覆寫為\(title(marked[0]))"
                                          : "其中 \(marked.count) 天已覆寫（\(counts(marked).joined(separator: "、"))）")
        }
        return parts.isEmpty ? "尚無覆寫" : parts.joined(separator: "　")
    }
    /// 選取的日子原本判定都相同時，預設成另一個類型；混合或沒有 baseline 時回 nil，讓畫面沿用上一次的選擇。
    func suggestedOption(for days: ClosedRange<CalendarDay>) -> String? {
        let options = Set(days.map { resolve($0).base?.option })
        guard options.count == 1, let only = options.first, let base = only else { return nil }
        return optionIDs.first { $0 != base }
    }
    /// 「從／到」：起訖顛倒時自動對調；超出 earliest／latest 就回 nil。
    static func range(from: CalendarDay, to: CalendarDay, spec: PluginDateSpec) -> ClosedRange<CalendarDay>? {
        let r = min(from, to)...max(from, to)
        if let e = spec.earliest, r.lowerBound < e { return nil }
        if let l = spec.latest, r.upperBound > l { return nil }
        return r
    }
}
