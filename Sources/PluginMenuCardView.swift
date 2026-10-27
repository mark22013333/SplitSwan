// 外掛子選單頂端的資訊卡片畫面（SwiftUI，放在 NSMenuItem.view 的 NSHostingView 裡）。
// 只依 PluginMenuCard 繪製；圖表用 Shape 手繪，不依賴 Swift Charts。卡片不可點。
import AppKit
import SwiftUI

struct PluginMenuCardView: View {
    static let width: CGFloat = 340
    static let inset: CGFloat = 14
    static let contentWidth = width - inset * 2

    let card: PluginMenuCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let timeline = card.timeline {
                TimelineStrip(timeline: timeline)
            }
            if !card.conditions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(card.conditions.enumerated()), id: \.offset) { _, condition in
                        ConditionChip(condition: condition)
                    }
                }
            }
            if !card.history.isEmpty {
                Divider()
                HistorySection(card: card)
            }
            if let footnote = card.footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(card.tone.color).frame(width: 7, height: 7)
                Text(card.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(card.tone.color.opacity(0.18)))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let detail = card.detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text("背景自動執行").foregroundStyle(.secondary)
                    Text(card.enabled ? "開啟" : "關閉")
                        .fontWeight(.semibold)
                        .foregroundStyle(card.enabled ? PluginMenuCard.Tone.ok.color : .secondary)
                }
                .fixedSize()
            }
            .font(.system(size: 11))
        }
        .accessibilityElement(children: .combine)
    }
}

extension PluginMenuCard.Tone {
    var color: Color {
        switch self {
        case .ok: return Color(nsColor: .systemGreen)
        case .info: return Color(nsColor: .systemBlue)
        case .warn: return Color(nsColor: .systemOrange)
        case .error: return Color(nsColor: .systemRed)
        case .neutral: return Color(nsColor: .systemGray)
        }
    }
}

extension PluginMenuCard.Result {
    var color: Color {
        switch self {
        case .auto: return Color(nsColor: .systemGreen)
        case .manual: return Color(nsColor: .systemOrange)
        case .leave: return Color(nsColor: .systemPurple)
        case .missed: return Color(nsColor: .systemRed)
        case .skipped: return Color(nsColor: .systemGray)
        }
    }
}

/// 今日時間軸：檢查點、時段區間、預定（空心）、實際（實心）與現在時間線。
private struct TimelineStrip: View {
    let timeline: PluginMenuCard.Timeline
    private let width = PluginMenuCardView.contentWidth
    private let pad: CGFloat = 16
    private let lineY: CGFloat = 25

    private func x(_ c: PluginMenuCard.Clock) -> CGFloat {
        pad + CGFloat(timeline.fraction(c)) * (width - pad * 2)
    }

    /// 刻度：範圍起點、時段起點、時段中點、時段終點，太近的略過。
    private var ticks: [PluginMenuCard.Clock] {
        let w = timeline.windowStart.minutes, e = timeline.windowEnd.minutes
        var kept: [PluginMenuCard.Clock] = []
        for c in [timeline.start, timeline.windowStart, .init(minutes: (w + e) / 2), timeline.windowEnd]
        where kept.allSatisfy({ abs(x($0) - x(c)) >= 36 }) {
            kept.append(c)
        }
        return kept
    }

    var body: some View {
        let accent = Color(nsColor: .systemBlue)
        let ok = PluginMenuCard.Tone.ok.color
        let red = Color(nsColor: .systemRed)
        let topLabel = timeline.actual.map { ($0, $0.text, ok) } ?? timeline.planned.map { ($0, "預定 \($0.text)", accent) }
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.secondary.opacity(0.45))
                .frame(width: width - pad * 2, height: 1.5)
                .position(x: width / 2, y: lineY)
            RoundedRectangle(cornerRadius: 4)
                .fill(accent.opacity(0.2))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(0.6), lineWidth: 1))
                .frame(width: x(timeline.windowEnd) - x(timeline.windowStart), height: 14)
                .position(x: (x(timeline.windowStart) + x(timeline.windowEnd)) / 2, y: lineY)
            Rectangle().fill(Color.secondary)
                .frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
                .position(x: x(timeline.check), y: lineY)
            if topLabel.map({ abs(x($0.0) - x(timeline.check)) >= 44 }) ?? true {
                label("檢查", color: .secondary).position(x: x(timeline.check), y: 8)
            }
            if let now = timeline.now {
                Rectangle().fill(red).frame(width: 1.5, height: 22).position(x: x(now), y: lineY)
                label("現在 \(now.text)", color: red)
                    .position(x: min(max(x(now), 32), width - 32), y: 55)
            }
            if let planned = timeline.planned {
                Circle().fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(Circle().stroke(accent, lineWidth: 2))
                    .frame(width: 11, height: 11)
                    .position(x: x(planned), y: lineY)
            }
            if let actual = timeline.actual {
                Circle().fill(ok).frame(width: 11, height: 11).position(x: x(actual), y: lineY)
            }
            if let top = topLabel {
                label(top.1, color: top.2, weight: .semibold)
                    .position(x: min(max(x(top.0), 30), width - 30), y: 8)
            }
            ForEach(ticks, id: \.minutes) { tick in
                label(tick.text, color: .secondary).position(x: x(tick), y: 41)
            }
        }
        .frame(width: width, height: timeline.now == nil ? 48 : 62, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["時段 \(timeline.windowStart.text) 到 \(timeline.windowEnd.text)"]
        if let p = timeline.planned { parts.append("預定 \(p.text)") }
        if let a = timeline.actual { parts.append("實際 \(a.text)") }
        if let n = timeline.now { parts.append("現在 \(n.text)") }
        return parts.joined(separator: "，")
    }

    private func label(_ text: String, color: Color, weight: Font.Weight = .regular) -> some View {
        Text(text).font(.system(size: 10, weight: weight)).foregroundStyle(color).fixedSize()
    }
}

struct ConditionChip: View {
    let condition: PluginMenuCard.Condition

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(condition.tone.color).frame(width: 6, height: 6)
            Text(condition.label).foregroundStyle(.secondary)
            Text(condition.value).foregroundStyle(.primary)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(maxWidth: PluginMenuCardView.contentWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
    }
}

/// 近期上班日散點圖：縱軸是打卡時間在時段內的位置，沒有時間的放「無」列。
private struct HistorySection: View {
    let card: PluginMenuCard
    private let width = PluginMenuCardView.contentWidth
    private let axis: CGFloat = 36
    private let top: CGFloat = 12
    private let bottom: CGFloat = 58
    private let noneY: CGFloat = 76
    private let dateY: CGFloat = 92

    /// 縱軸範圍：有今日時間軸用設定的時段，否則取歷史時間前後對齊到 15 分鐘（至少 30 分鐘）。
    private var range: (lo: Int, hi: Int) {
        if let t = card.timeline { return (t.windowStart.minutes, t.windowEnd.minutes) }
        let times = card.history.compactMap(\.time?.minutes)
        let lo = (times.min() ?? 0) / 15 * 15
        return (lo, max(((times.max() ?? lo) + 14) / 15 * 15, lo + 30))
    }

    private func y(_ minutes: Int) -> CGFloat {
        let (lo, hi) = range
        let f = min(max(Double(minutes - lo) / Double(hi - lo), 0), 1)
        return top + CGFloat(f) * (bottom - top)
    }

    private func x(_ index: Int) -> CGFloat {
        let step = (width - axis) / CGFloat(max(card.history.count, 1))
        return axis + step * (CGFloat(index) + 0.5)
    }

    var body: some View {
        let (lo, hi) = range
        let grid = [lo, (lo + hi) / 2, hi]
        VStack(alignment: .leading, spacing: 6) {
            Text("近 \(card.history.count) 個上班日")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                ForEach(grid, id: \.self) { m in
                    Rectangle().fill(Color.secondary.opacity(0.25))
                        .frame(width: width - axis, height: 1)
                        .position(x: axis + (width - axis) / 2, y: y(m))
                    axisLabel(PluginMenuCard.Clock(minutes: m).text).position(x: axis / 2 - 2, y: y(m))
                }
                axisLabel("無").position(x: axis / 2 - 2, y: noneY)
                if let average = PluginMenuCard.average(card.history.filter { $0.result == .auto }.compactMap(\.time)) {
                    Path { p in
                        p.move(to: CGPoint(x: axis, y: y(average.minutes)))
                        p.addLine(to: CGPoint(x: width, y: y(average.minutes)))
                    }
                    .stroke(PluginMenuCard.Result.auto.color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(Array(card.history.enumerated()), id: \.offset) { i, day in
                    if let time = day.time {
                        if card.isToday(index: i) {
                            Circle().fill(day.result.color).frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.primary.opacity(0.85), lineWidth: 1.5).frame(width: 16, height: 16))
                                .position(x: x(i), y: y(time.minutes))
                        } else {
                            Circle().fill(day.result.color).frame(width: 8, height: 8).position(x: x(i), y: y(time.minutes))
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 2).stroke(day.result.color, lineWidth: 1.5)
                            .frame(width: 8, height: 8).position(x: x(i), y: noneY)
                    }
                    Text(day.shortDate)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: x(i), y: dateY)
                }
            }
            .frame(width: width, height: dateY + 8, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.history.map { "\($0.shortDate)（\($0.weekday)）\($0.result.label)\($0.time.map { " \($0.text)" } ?? "")" }.joined(separator: "，"))

            HStack(spacing: 10) {
                ForEach(card.legend, id: \.self) { r in
                    HStack(spacing: 4) {
                        Circle().fill(r.color).frame(width: 7, height: 7)
                        Text(r.label)
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            if let summary = card.historySummary {
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
    }
}

/// 條件標籤放不下一列時換行。
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? PluginMenuCardView.contentWidth, subviews: subviews)
        return CGSize(width: proposal.width ?? PluginMenuCardView.contentWidth, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(y: CGFloat, height: CGFloat, items: [(Int, CGFloat)])] {
        var rows: [(y: CGFloat, height: CGFloat, items: [(Int, CGFloat)])] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        var items: [(Int, CGFloat)] = []
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !items.isEmpty, x + size.width > width {
                rows.append((y, height, items))
                y += height + spacing
                x = 0; height = 0; items = []
            }
            items.append((index, x))
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !items.isEmpty { rows.append((y, height, items)) }
        return rows
    }
}
