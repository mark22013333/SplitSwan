// 外掛子選單頂端的資訊卡片：標題行 `card=<base64url JSON>` 的解碼與驗證（純邏輯）。
// 外掛輸出不受信任：任何欄位不合規就整張卡片忽略，選單照舊只顯示文字列。畫面只依本型別繪製（PluginMenuCardView.swift）。
import Foundation

struct PluginMenuCard: Equatable, Sendable {
    static let maxBytes = 8 * 1024
    static let maxConditions = 4
    static let maxHistory = 10
    static let maxTimelineSpan = 6 * 60

    enum Tone: String, Decodable, Sendable { case ok, info, warn, error, neutral }

    /// 某個上班日的處理結果：自動成功、人工處理、請假、未執行、跳過。
    enum Result: String, Decodable, Sendable, CaseIterable {
        case auto, manual, leave, missed, skipped

        var label: String {
            switch self {
            case .auto: return "自動成功"
            case .manual: return "人工處理"
            case .leave: return "請假"
            case .missed: return "未執行"
            case .skipped: return "跳過"
            }
        }
    }

    /// 一天中的時刻，以分鐘計（00:00–23:59）。
    struct Clock: Comparable, Hashable, Sendable {
        let minutes: Int

        init(minutes: Int) { self.minutes = minutes }

        /// 只接受半形數字的 `HH:mm`。
        init?(_ text: String) {
            let s = Array(text.unicodeScalars)
            guard s.count == 5, s[2] == ":",
                  [0, 1, 3, 4].allSatisfy({ ("0"..."9").contains(s[$0]) }),
                  let h = Int(String(text.prefix(2))), let m = Int(String(text.suffix(2))),
                  h < 24, m < 60 else { return nil }
            minutes = h * 60 + m
        }

        var text: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
        static func < (a: Clock, b: Clock) -> Bool { a.minutes < b.minutes }
    }

    /// 今日時間軸：顯示範圍 start…end，其餘時刻都必須落在範圍內。
    struct Timeline: Equatable, Sendable {
        let start: Clock, end: Clock
        let check: Clock
        let windowStart: Clock, windowEnd: Clock
        let planned: Clock?, actual: Clock?, now: Clock?

        /// 時刻在範圍內的比例 0…1。
        func fraction(_ c: Clock) -> Double {
            Double(c.minutes - start.minutes) / Double(end.minutes - start.minutes)
        }
    }

    struct Condition: Equatable, Sendable {
        let label: String
        let value: String
        let tone: Tone
    }

    struct Day: Equatable, Sendable {
        let date: String       // YYYY-MM-DD
        let weekday: String
        let time: Clock?
        let result: Result

        /// 圖上的日期標籤，例：10/8
        var shortDate: String {
            let parts = date.split(separator: "-")
            return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
        }
    }

    let headline: String
    let tone: Tone
    let detail: String?
    let enabled: Bool
    let timeline: Timeline?
    let conditions: [Condition]
    let history: [Day]
    let footnote: String?

    /// 圖例只列出近期出現過的結果，自動成功永遠列出。
    var legend: [Result] {
        Result.allCases.filter { r in r == .auto || history.contains { $0.result == r } }
    }

    /// 今天已打卡時，歷史最後一筆就是今天（時間軸的實際打卡時間與它相同）；圖表用較大的點標出。
    func isToday(index: Int) -> Bool {
        guard index == history.count - 1, let actual = timeline?.actual else { return false }
        return history[index].time == actual
    }

    /// 例：「自動打卡平均 08:41（7 天）· 人工處理 1、請假 1、未執行 1」；沒有歷史回 nil。
    var historySummary: String? {
        guard !history.isEmpty else { return nil }
        let autoTimes = history.filter { $0.result == .auto }.compactMap(\.time)
        var parts: [String] = []
        if let average = Self.average(autoTimes) {
            parts.append("自動打卡平均 \(average.text)（\(autoTimes.count) 天）")
        }
        let others = Result.allCases.filter { $0 != .auto }.compactMap { r -> String? in
            let n = history.filter { $0.result == r }.count
            return n > 0 ? "\(r.label) \(n)" : nil
        }
        if !others.isEmpty { parts.append(others.joined(separator: "、")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func average(_ times: [Clock]) -> Clock? {
        guard !times.isEmpty else { return nil }
        let total = times.reduce(0) { $0 + $1.minutes }
        return Clock(minutes: Int((Double(total) / Double(times.count)).rounded()))
    }

    // MARK: 解碼

    /// 標題行的 card 參數（base64url，可省略補位）→ 卡片；任何不合規回 nil。
    static func decode(_ encoded: String) -> PluginMenuCard? {
        guard !encoded.isEmpty, encoded.count <= (maxBytes + 2) / 3 * 4,
              encoded.unicodeScalars.allSatisfy({ Self.base64URLAlphabet.contains($0) }) else { return nil }
        var b64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if b64.count % 4 == 1 { return nil }
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return decode(json: data)
    }

    static func decode(json data: Data) -> PluginMenuCard? {
        guard data.count <= maxBytes, let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return wire.card
    }

    private static let base64URLAlphabet: Set<Unicode.Scalar> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=".unicodeScalars)

    /// 外掛文字：去掉控制字元後依欄位上限截斷，再套用選單共通的上限。
    private static func text(_ s: String, _ limit: Int) -> String {
        let t = PluginLogic.sanitize(s).trimmingCharacters(in: .whitespaces)
        return PluginLogic.clip(t.count > limit ? String(t.prefix(limit)) + "…" : t)
    }

    private struct Wire: Decodable {
        struct WireTimeline: Decodable {
            let start, end, check, windowStart, windowEnd: String
            let planned, actual, now: String?
        }
        struct WireCondition: Decodable { let label, value: String; let tone: Tone }
        struct WireDay: Decodable { let date, weekday: String; let time: String?; let result: Result }

        let version: Int
        let headline: String
        let tone: Tone
        let detail: String?
        let enabled: Bool
        let timeline: WireTimeline?
        let conditions: [WireCondition]
        let history: [WireDay]
        let footnote: String?

        var card: PluginMenuCard? {
            guard version == 1, conditions.count <= maxConditions, history.count <= maxHistory else { return nil }
            let headline = text(self.headline, 60)
            guard !headline.isEmpty else { return nil }

            var line: Timeline?
            if let t = timeline {
                guard let start = Clock(t.start), let end = Clock(t.end), let check = Clock(t.check),
                      let ws = Clock(t.windowStart), let we = Clock(t.windowEnd),
                      start < end, end.minutes - start.minutes <= maxTimelineSpan, ws < we else { return nil }
                func optional(_ s: String?) -> Clock?? {
                    guard let s else { return .some(nil) }
                    guard let c = Clock(s) else { return nil }
                    return .some(c)
                }
                guard let planned = optional(t.planned), let actual = optional(t.actual), let now = optional(t.now) else { return nil }
                let points = [check, ws, we] + [planned, actual, now].compactMap { $0 }
                guard points.allSatisfy({ start <= $0 && $0 <= end }) else { return nil }
                line = Timeline(start: start, end: end, check: check, windowStart: ws, windowEnd: we,
                                planned: planned, actual: actual, now: now)
            }

            var conds: [Condition] = []
            for c in conditions {
                let label = text(c.label, 12), value = text(c.value, 20)
                guard !label.isEmpty, !value.isEmpty else { return nil }
                conds.append(Condition(label: label, value: value, tone: c.tone))
            }

            var days: [Day] = []
            for d in history {
                guard Self.validDate(d.date), days.last.map({ $0.date < d.date }) ?? true else { return nil }
                var time: Clock?
                if let raw = d.time {
                    guard let c = Clock(raw) else { return nil }
                    time = c
                }
                days.append(Day(date: d.date, weekday: text(d.weekday, 2), time: time, result: d.result))
            }

            return PluginMenuCard(
                headline: headline, tone: tone,
                detail: detail.map { text($0, 80) }.flatMap { $0.isEmpty ? nil : $0 },
                enabled: enabled, timeline: line, conditions: conds, history: days,
                footnote: footnote.map { text($0, 120) }.flatMap { $0.isEmpty ? nil : $0 })
        }

        /// YYYY-MM-DD，半形數字，月 1–12、日 1–31。
        static func validDate(_ s: String) -> Bool {
            let u = Array(s.unicodeScalars)
            guard u.count == 10, u[4] == "-", u[7] == "-",
                  u.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || ("0"..."9").contains($0.element) }),
                  let m = Int(String(s.dropFirst(5).prefix(2))), let d = Int(String(s.suffix(2))) else { return false }
            return (1...12).contains(m) && (1...31).contains(d)
        }
    }
}
