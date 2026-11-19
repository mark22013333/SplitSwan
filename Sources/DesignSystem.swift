// 主視窗各頁共用的介面元件：卡片、區塊標題、狀態卡、狀態徽章、載入按鈕、吐司、搖晃、骨架、交錯出場。
// 動畫一律經 DSMotion 決定，系統開啟「減少動態效果」時改成淡入或不動。
import SwiftUI

enum DSMotion {
    static let duration = 0.25

    /// 一般轉場：減少動態效果時只留短淡入
    static func standard(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.15) : .easeInOut(duration: duration)
    }

    /// 狀態徽章切換用的彈簧；減少動態效果時改成淡入
    static func spring(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7)
    }

    static func transition(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

// MARK: - 語意色調

enum StatusTone: Equatable {
    case ok, working, warning, error, neutral

    var color: Color {
        switch self {
        case .ok: return .green
        case .working: return .orange
        case .warning: return .orange
        case .error: return .red
        case .neutral: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .working: return "clock.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .neutral: return "circle.dashed"
        }
    }
}

// MARK: - 卡片與區塊標題

/// 圓角底的區塊；標題可省略，標題旁可放一個說明
struct DSCard<Content: View>: View {
    let title: String?
    let systemImage: String?
    let subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, systemImage: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.systemImage = systemImage; self.subtitle = subtitle; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionHeader(title, systemImage: systemImage, subtitle: subtitle) }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSSurface())
        }
    }
}

/// 卡片底色：淺色與深色模式都看得出邊界
struct DSSurface: View {
    var tint: Color? = nil
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.map { $0.opacity(0.10) } ?? Color.secondary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((tint ?? Color.secondary).opacity(0.22), lineWidth: 1))
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String?
    let subtitle: String?

    init(_ title: String, systemImage: String? = nil, subtitle: String? = nil) {
        self.title = title; self.systemImage = systemImage; self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(.headline)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 狀態徽章與狀態卡

/// 膠囊狀的狀態標籤；文字或色調改變時以彈簧動畫切換
struct StatusBadge: View {
    let text: String
    let tone: StatusTone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(text, systemImage: tone.symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tone.color.opacity(0.15)))
            .id(text)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            .animation(DSMotion.spring(reduceMotion), value: text)
            .accessibilityElement(children: .combine)
    }
}

/// 每頁頂部的狀態卡：圖示＋大字狀態＋一句說明，右側（或下方）放唯一主要按鈕
struct StatusCard<Icon: View, Detail: View, Actions: View>: View {
    let title: String
    let tone: StatusTone
    let badge: String?
    @ViewBuilder var icon: Icon
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, tone: StatusTone, badge: String? = nil,
         @ViewBuilder icon: () -> Icon, @ViewBuilder detail: () -> Detail, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.tone = tone; self.badge = badge
        self.icon = icon(); self.detail = detail(); self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                icon
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(tone.color.opacity(0.14)))
                    .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(reduceMotion ? .identity : .opacity)
                            .animation(DSMotion.standard(reduceMotion), value: title)
                        Spacer(minLength: 4)
                        if let badge { StatusBadge(text: badge, tone: tone) }
                    }
                    detail
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSSurface(tint: tone == .neutral ? nil : tone.color))
        .animation(DSMotion.standard(reduceMotion), value: tone)
    }
}

/// 錯誤說明：紅色、寫出下一步
struct ErrorBanner: View {
    let message: String
    let nextStep: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(message).font(.callout.weight(.medium)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let nextStep {
                    Text(nextStep).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSSurface(tint: .red))
    }
}

// MARK: - 載入按鈕

/// 按下後在按鈕內轉圈；isLoading 由 true 變回 false 且 succeeded() 為真時短暫顯示打勾
struct LoadingButton: View {
    let title: String
    let systemImage: String?
    let isLoading: Bool
    var prominent = false
    var role: ButtonRole? = nil
    var fillWidth = false
    var succeeded: () -> Bool = { true }
    let action: () -> Void

    @State private var showDone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, systemImage: String? = nil, isLoading: Bool, prominent: Bool = false, role: ButtonRole? = nil,
         fillWidth: Bool = false, succeeded: @escaping () -> Bool = { true }, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.isLoading = isLoading; self.prominent = prominent
        self.role = role; self.fillWidth = fillWidth; self.succeeded = succeeded; self.action = action
    }

    var body: some View {
        let button = Button(role: role, action: action) {
            HStack(spacing: 6) {
                ZStack {
                    if isLoading {
                        ProgressView().controlSize(.small).scaleEffect(0.8)
                            .transition(.opacity)
                    } else if showDone {
                        Image(systemName: "checkmark").fontWeight(.bold)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    } else if let systemImage {
                        Image(systemName: systemImage).transition(.opacity)
                    }
                }
                .frame(width: (isLoading || showDone || systemImage != nil) ? 16 : 0, height: 16)
                Text(title).lineLimit(1)
            }
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .animation(DSMotion.standard(reduceMotion), value: isLoading)
            .animation(DSMotion.standard(reduceMotion), value: showDone)
        }
        .onChange(of: isLoading) { was, now in
            guard was, !now, succeeded() else { return }
            showDone = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                showDone = false
            }
        }
        if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }
}

// MARK: - 吐司

/// 短暫確認訊息（已儲存、已拷貝）；由 MainView 的 toastHost 顯示在視窗底部，數秒後消失
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    @Published private(set) var current: Toast?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, isError: Bool = false, seconds: Double = 2.5) {
        let toast = Toast(text: text, isError: isError)
        current = toast
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    func dismiss() { hideTask?.cancel(); current = nil }
}

private struct ToastHost: ViewModifier {
    @ObservedObject var center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                Label(toast.text, systemImage: toast.isError ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(toast.isError ? Color.red : Color.primary)
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(2)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25)))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    // 浮在設定頁底部儲存列之上，不蓋住「儲存」按鈕
                    .padding(.bottom, 64).padding(.horizontal, 24)
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { center.dismiss() }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(DSMotion.standard(reduceMotion), value: center.current)
    }
}

extension View {
    @MainActor func toastHost(_ center: ToastCenter = .shared) -> some View { modifier(ToastHost(center: center)) }
}

// MARK: - 搖晃

/// 驗證失敗時左右晃動；trigger 每加一就晃一次
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 6
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * shakes * 2), y: 0))
    }
}

private struct Shake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // 減少動態效果時不晃，錯誤文字本身已足夠提示
        content
            .modifier(ShakeEffect(animatableData: reduceMotion ? 0 : CGFloat(trigger)))
            .animation(reduceMotion ? nil : .linear(duration: 0.3), value: trigger)
    }
}

extension View {
    func shake(trigger: Int) -> some View { modifier(Shake(trigger: trigger)) }
}

// MARK: - 骨架畫面

/// 載入中的占位列：灰色圓角塊，減少動態效果時不做閃爍
struct SkeletonRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 12)
                RoundedRectangle(cornerRadius: 4).frame(maxWidth: 260).frame(height: 10)
            }
            Spacer()
        }
        .foregroundStyle(Color.secondary.opacity(dim ? 0.12 : 0.24))
        .padding(.vertical, 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityLabel("載入中")
    }
}

// MARK: - 交錯出場

private struct StaggeredAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .onAppear {
                // 最多延遲 0.25 秒，清單再長也不拖慢操作
                let delay = reduceMotion ? 0 : min(Double(index) * 0.04, 0.25)
                withAnimation(DSMotion.standard(reduceMotion).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}
