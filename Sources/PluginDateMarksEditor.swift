import AppKit
import SwiftUI

/// 帶 `dates` 的 stringList 欄位：以月曆編輯正規行。只改 `lines`（＝草稿），不呼叫外掛，儲存、取消與 dirty 仍由設定視窗處理。
struct DateMarksEditor: View {
    typealias P = PluginSettingsProtocol
    let field: P.Field
    let spec: PluginDateSpec
    @Binding var lines: [String]
    /// 視窗忙碌中、背景工作執行中，或外掛宣告 `locked`。
    let locked: Bool
    @State private var month: CalendarDay
    @State private var selection: ClosedRange<CalendarDay>?
    @State private var anchor: CalendarDay?
    @State private var option: String
    @State private var note = ""
    @State private var expanded: Set<CalendarDay> = []
    @State private var showExpired = false
    @State private var repeatWeekly = false
    @State private var weekdays: Set<Int> = []
    @State private var weeklyFrom: CalendarDay
    @State private var weeklyUntil: CalendarDay
    @State private var weeklyNoEnd = false

    init(field: P.Field, spec: PluginDateSpec, lines: Binding<[String]>, locked: Bool) {
        self.field = field
        self.spec = spec
        self._lines = lines
        self.locked = locked
        _month = State(initialValue: spec.today.monthStart)
        _option = State(initialValue: field.options?.first?.id ?? "")
        _weeklyFrom = State(initialValue: spec.today)
        let fourWeeks = spec.today.adding(days: 28)
        _weeklyUntil = State(initialValue: spec.latest.map { min(fourWeeks, $0.adding(days: 1)) } ?? fourWeeks)
    }

    private var options: [P.Option] { field.options ?? [] }
    private var titles: [String: String] { Dictionary(uniqueKeysWithValues: options.map { ($0.id, PluginLogic.sanitize($0.title)) }) }
    private func title(_ id: String) -> String { titles[id] ?? id }
    private static let utc = TimeZone(identifier: "UTC")!
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    /// 「不限」展開到可設定的最後一天；外掛沒宣告 latest 時以兩年為限，避免一次寫入過多筆。
    private var lastAllowed: CalendarDay { spec.latest ?? spec.today.adding(days: 730) }
    private var effectiveUntil: CalendarDay { weeklyNoEnd ? lastAllowed.adding(days: 1) : weeklyUntil }

    var body: some View {
        if let marks = try? DateMarks(lines: lines, optionIDs: options.map(\.id), spec: spec) {
            editor(marks)
        } else {
            Text("日期標記資料不正確，請重新載入。").foregroundStyle(.red)
        }
    }

    private struct Preview { var next: DateMarks; var weekly: DateMarks.WeeklyResult?; var problem: String? }
    private func preview(_ marks: DateMarks) -> Preview {
        var next = marks
        do {
            if repeatWeekly {
                let result = try next.applyWeekly(option: option, note: note, weekdays: weekdays, from: weeklyFrom, until: effectiveUntil)
                return Preview(next: next, weekly: result)
            }
            if let selection { try next.apply(option: option, note: note, to: selection) }
            return Preview(next: next)
        } catch { return Preview(next: marks, problem: error.localizedDescription) }
    }

    private func editor(_ marks: DateMarks) -> some View {
        let preview = preview(marks)
        let highlighted = repeatWeekly ? Set(preview.weekly?.applied ?? []) : Set(selection.map(Array.init) ?? [])
        return VStack(alignment: .leading, spacing: 14) {
            if let reason = spec.locked {
                Label(P.displayText(reason), systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            monthHeader
            HStack(alignment: .top, spacing: 20) {
                MonthGrid(month: month, marks: marks, highlighted: highlighted, optionIDs: options.map(\.id),
                          describe: { describe($0, marks) }, onTap: tap)
                    .frame(maxWidth: 420)
                    .disabled(locked)
                legend
            }
            Divider()
            selectionPanel(marks, preview).disabled(locked)
            Divider()
            list(marks)
        }
        .onChange(of: selection) {
            guard let selection else { return }
            if let suggested = marks.suggestedOption(for: selection) { option = suggested }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            Button { month = month.addingMonths(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(spec.earliest.map { month.addingMonths(-1) < $0.monthStart } ?? false)
                .accessibilityLabel("上個月")
            Text(verbatim: "\(month.year) 年 \(month.month) 月").font(.headline).monospacedDigit().frame(minWidth: 110)
            Button { month = month.addingMonths(1) } label: { Image(systemName: "chevron.right") }
                .disabled(spec.latest.map { month.addingMonths(1) > $0 } ?? false)
                .accessibilityLabel("下個月")
            Spacer()
            Button("今天") { month = spec.today.monthStart }.disabled(month == spec.today.monthStart)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, o in
                HStack(spacing: 6) {
                    MarkSymbol(index: index)
                    Text("\(title(o.id))覆寫")
                }
            }
            if spec.baseline != nil, let first = options.first {
                Text("灰字＝原本不是\(title(first.id))").foregroundStyle(.secondary)
            }
            Text("按住 Shift 點另一天可選連續區間").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func tap(_ day: CalendarDay, extend: Bool) {
        repeatWeekly = false
        if extend, let start = anchor ?? selection?.lowerBound {
            selection = DateMarks.range(from: start, to: day, spec: spec) ?? selection
        } else {
            selection = day...day
            anchor = day
        }
    }

    private func dateLabel(_ day: CalendarDay) -> String {
        let prefix = day.year == spec.today.year ? "" : "\(day.year)/"
        return "\(prefix)\(day.month)/\(day.day)（\(Self.weekdays[day.weekday])）"
    }
    private func rangeLabel(_ days: [CalendarDay]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        return first == last ? dateLabel(first) : "\(dateLabel(first))～\(dateLabel(last))"
    }
    private func runLabel(_ run: DateMarks.Run) -> String {
        run.weekly ? "每週\(Self.weekdays[run.days[0].weekday]) \(rangeLabel(run.days))（\(run.days.count) 天）" : rangeLabel(run.days)
    }
    static func summaryText(_ marks: DateMarks, of days: ClosedRange<CalendarDay>, titles: [String: String]) -> String {
        PluginLogic.sanitize(marks.summary(of: days, titles: titles))
    }
    private func describe(_ day: CalendarDay, _ marks: DateMarks) -> String {
        let r = marks.resolve(day)
        var parts = [dateLabel(day)]
        if let base = r.base { parts.append("原本：\(title(base.option))（\(PluginLogic.sanitize(base.sourceText))）") }
        if let mark = r.mark { parts.append("覆寫：\(title(mark.option))" + (mark.note.isEmpty ? "" : " · \(mark.note)")) }
        return parts.joined(separator: "　")
    }

    // MARK: 選取區

    private func dayBinding(_ end: KeyPath<ClosedRange<CalendarDay>, CalendarDay>, isStart: Bool) -> Binding<Date> {
        Binding(get: { (selection?[keyPath: end] ?? spec.today).date }, set: { date in
            let picked = CalendarDay(date: date)
            let other = selection.map { isStart ? $0.upperBound : $0.lowerBound } ?? picked
            guard let range = DateMarks.range(from: picked, to: other, spec: spec) else { return }
            selection = range
            anchor = range.lowerBound
            month = picked.monthStart
        })
    }
    @ViewBuilder private func dayPicker(_ label: String, _ binding: Binding<Date>, in lower: CalendarDay?, _ upper: CalendarDay?, showsLabel: Bool = true) -> some View {
        let picker: some View = Group {
            switch (lower, upper) {
            case let (e?, l?): DatePicker(label, selection: binding, in: e.date...l.date, displayedComponents: .date)
            case let (e?, nil): DatePicker(label, selection: binding, in: e.date..., displayedComponents: .date)
            case let (nil, l?): DatePicker(label, selection: binding, in: ...l.date, displayedComponents: .date)
            case (nil, nil): DatePicker(label, selection: binding, displayedComponents: .date)
            }
        }
        HStack(spacing: 6) {
            if showsLabel { Text(label) }
            picker.datePickerStyle(.field).labelsHidden().fixedSize()
                .environment(\.timeZone, Self.utc)
                .environment(\.calendar, { var c = Calendar(identifier: .gregorian); c.timeZone = Self.utc; return c }())
                .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
        }
    }

    private func weeklyBinding(_ day: Binding<CalendarDay>, isStart: Bool) -> Binding<Date> {
        Binding(get: { day.wrappedValue.date }, set: { date in
            let picked = CalendarDay(date: date)
            day.wrappedValue = picked
            if isStart, weeklyUntil <= picked { weeklyUntil = picked.adding(days: 1) }
            month = (isStart ? picked : picked.adding(days: -1)).monthStart
        })
    }
    private func dayList(_ days: [CalendarDay]) -> String {
        days.prefix(5).map(dateLabel).joined(separator: "、") + (days.count > 5 ? " 等 \(days.count) 天" : "")
    }

    @ViewBuilder private func weeklyFields(_ result: DateMarks.WeeklyResult?) -> some View {
        HStack(spacing: 6) {
            Text("每週")
            ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { index, name in
                Toggle(name, isOn: Binding(get: { weekdays.contains(index) },
                                           set: { if $0 { weekdays.insert(index) } else { weekdays.remove(index) } }))
                    .toggleStyle(.button)
                    .accessibilityLabel("星期\(name)")
            }
        }
        HStack(spacing: 14) {
            dayPicker("從", weeklyBinding($weeklyFrom, isStart: true), in: spec.earliest, spec.latest)
            Picker("結束", selection: $weeklyNoEnd) {
                Text("指定日期").tag(false)
                Text("不限").tag(true)
            }
            .pickerStyle(.segmented).fixedSize()
            if !weeklyNoEnd {
                dayPicker("結束日期", weeklyBinding($weeklyUntil, isStart: false),
                          in: weeklyFrom.adding(days: 1), spec.latest.map { $0.adding(days: 1) }, showsLabel: false)
            }
        }
        Text(endHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let result, let last = result.applied.last {
            Text("會套用 \(result.applied.count) 天，最後一次是 \(dateLabel(last))").font(.callout).foregroundStyle(.secondary)
            if !result.skipped.isEmpty {
                Text("略過已有覆寫的 \(dayList(result.skipped))，保留原本設定").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var endHelp: String {
        if weeklyNoEnd {
            let reason = spec.latest == nil ? "" : "，這是外掛可接受的最後一天"
            return "一直套用到 \(dateLabel(lastAllowed))\(reason)。之後不會自動延長，需要時再設定一次。"
        }
        return "結束日期當天就停止：設 \(dateLabel(weeklyUntil))，會套用到 \(dateLabel(weeklyUntil.adding(days: -1))) 為止，\(dateLabel(weeklyUntil)) 當天起不套用。"
    }

    private func selectionPanel(_ marks: DateMarks, _ preview: Preview) -> some View {
        let limit = spec.effectiveNoteLimit
        let marked = selection.map { s in marks.marks.contains { s.contains($0.day) } } ?? false
        let count = repeatWeekly ? preview.weekly?.applied.count : selection?.count
        return VStack(alignment: .leading, spacing: 10) {
            Picker("重複", selection: $repeatWeekly) {
                Text("單次").tag(false)
                Text("每週").tag(true)
            }
            .pickerStyle(.segmented).fixedSize()
            if repeatWeekly {
                weeklyFields(preview.weekly)
            } else {
                HStack(spacing: 14) {
                    dayPicker("從", dayBinding(\.lowerBound, isStart: true), in: spec.earliest, spec.latest)
                    dayPicker("到", dayBinding(\.upperBound, isStart: false), in: spec.earliest, spec.latest)
                    Text(selection.map { "共 \($0.count) 天" } ?? "尚未選取日期").foregroundStyle(.secondary)
                }
                if let selection {
                    Text(Self.summaryText(marks, of: selection, titles: titles)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Text("覆寫為")
                Picker("覆寫為", selection: $option) {
                    ForEach(options) { Text(title($0.id)).tag($0.id) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("備註")
                TextField("選填", text: $note).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .accessibilityLabel("備註")
                Text("\(note.unicodeScalars.count)/\(limit)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            // 到上限後無法再輸入：超過就退回上一個值，不截斷貼上的文字。
            .onChange(of: note) { old, new in if new.unicodeScalars.count > limit { note = old } }
            HStack(spacing: 10) {
                if let problem = preview.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !repeatWeekly {
                    Button("清除這幾天的覆寫") {
                        guard let selection else { return }
                        var next = marks
                        next.remove(selection)
                        lines = next.lines
                    }
                    .disabled(!marked)
                }
                Button(count.map { "套用到 \($0) 天" } ?? "套用") { lines = preview.next.lines }
                    .buttonStyle(.borderedProminent)
                    .disabled(count == nil || preview.problem != nil)
            }
        }
    }

    // MARK: 清單

    private func list(_ marks: DateMarks) -> some View {
        let (upcoming, expired) = marks.runs()
        let expiredDays = expired.reduce(0) { $0 + $1.days.count }
        return VStack(alignment: .leading, spacing: 8) {
            Text("即將生效").font(.headline)
            if upcoming.isEmpty { Text("沒有即將生效的覆寫").foregroundStyle(.secondary) }
            ForEach(upcoming, id: \.days) { run in runRow(run, marks) }
            if !expired.isEmpty {
                DisclosureGroup("已過期（\(expiredDays) 筆）", isExpanded: $showExpired) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let help = spec.expiredHelp, !help.isEmpty {
                            Text(P.displayText(help)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(expired, id: \.days) { run in runRow(run, marks) }
                        Button("清除全部已過期（\(expiredDays) 筆）") {
                            var next = marks
                            next.removeExpired()
                            lines = next.lines
                        }
                        .disabled(locked)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func baseText(_ bases: [Resolution.Base?]) -> String? {
        let options = Set(bases.map { $0?.option })
        guard options.count == 1, let only = options.first, let option = only else { return bases.contains { $0 != nil } ? "原本：混合" : nil }
        return "原本：\(title(option))"
    }

    private func runRow(_ run: DateMarks.Run, _ marks: DateMarks) -> some View {
        let open = expanded.contains(run.days[0])
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(runLabel(run)).monospacedDigit()
                Text(title(run.option) + (run.note.isEmpty ? "" : " · \(run.note)")).fontWeight(.medium)
                if let base = baseText(run.base) { Text(base).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if run.days.count > 1 {
                    Button(open ? "收合" : "展開") {
                        if open { expanded.remove(run.days[0]) } else { expanded.insert(run.days[0]) }
                    }
                }
                Button("移除") {
                    var next = marks
                    next.remove(run.days)
                    lines = next.lines
                }
                .disabled(locked)
            }
            if open {
                ForEach(run.days, id: \.self) { day in
                    HStack(spacing: 8) {
                        Text("└ " + dateLabel(day)).monospacedDigit().foregroundStyle(.secondary)
                        Button("移除") {
                            var next = marks
                            next.remove(day)
                            lines = next.lines
                        }
                        .controlSize(.small).disabled(locked)
                    }
                    .padding(.leading, 16)
                }
            }
        }
    }
}

/// 第 0 個選項畫空心圈，其餘畫實心點並以顏色區分。
struct MarkSymbol: View {
    let index: Int
    private static let palette: [Color] = [.accentColor, .orange, .purple, .pink, .teal, .brown, .indigo, .mint]
    var body: some View {
        let color = Self.palette[index % Self.palette.count]
        Group {
            if index == 0 { Circle().strokeBorder(color, lineWidth: 1.5) } else { Circle().fill(color) }
        }
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }
}

/// 7 欄月曆。不用 DatePicker(.graphical)，因為它無法自訂格子內容與區間顯示。
struct MonthGrid: View {
    let month: CalendarDay
    let marks: DateMarks
    let highlighted: Set<CalendarDay>
    let optionIDs: [String]
    let describe: (CalendarDay) -> String
    let onTap: (CalendarDay, _ extend: Bool) -> Void

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        LazyVGrid(columns: columns, spacing: 2) {
            // 同一個 LazyVGrid 內三組 ForEach 的 id 不能重複：標題用 String、週首空格用 Int、日期用 CalendarDay。
            ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { name in
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(0..<month.weekday, id: \.self) { _ in Color.clear.frame(height: 34) }
            ForEach(Array(month...month.adding(days: month.daysInMonth - 1)), id: \.self) { day in cell(day) }
        }
    }

    private func cell(_ day: CalendarDay) -> some View {
        let r = marks.resolve(day)
        let spec = marks.spec
        let selectable = DateMarks.range(from: day, to: day, spec: spec) != nil
        let selected = highlighted.contains(day)
        let isToday = day == spec.today
        let dimmed = r.base.map { $0.option != optionIDs.first } ?? false
        return Button { onTap(day, NSEvent.modifierFlags.contains(.shift)) } label: {
            VStack(spacing: 2) {
                Text(verbatim: "\(day.day)").monospacedDigit()
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(!selectable ? Color.secondary.opacity(0.5) : dimmed ? Color.secondary : Color.primary)
                Group {
                    if let mark = r.mark, let index = optionIDs.firstIndex(of: mark.option) { MarkSymbol(index: index) }
                    else { Color.clear.frame(width: 7, height: 7) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isToday ? Color.accentColor : Color.clear, lineWidth: 1.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .help(describe(day))
        .accessibilityLabel(describe(day))
    }
}
