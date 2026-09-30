// 狀態列圖示：多組樣式可選（設定頁「狀態列圖示」），每組有未連線／已連線／連線中／異常四種狀態。
// SF Symbols 樣式用 template 圖，會跟著狀態列深淺色自動變色；「VPN 字樣」是自己畫的 template 圖。
import AppKit

enum IconState: CaseIterable {
    case disconnected, connected, connecting, error

    var title: String {
        switch self {
        case .disconnected: return "未連線"
        case .connected: return "已連線"
        case .connecting: return "連線中"
        case .error: return "異常"
        }
    }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case shield, shieldCheck, lock, key, network, tunnel, nodes, text
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shield: return "盾牌鎖"
        case .shieldCheck: return "盾牌勾"
        case .lock: return "鎖頭"
        case .key: return "鑰匙"
        case .network: return "網路"
        case .tunnel: return "通道"
        case .nodes: return "節點"
        case .text: return "VPN 字樣"
        }
    }

    /// 各狀態的 SF Symbol 名稱；「VPN 字樣」沒有對應的符號，回傳 nil
    func symbol(_ s: IconState) -> String? {
        let table: [IconState: String]
        switch self {
        case .shield:
            table = [.disconnected: "lock.shield", .connected: "lock.shield.fill",
                     .connecting: "arrow.triangle.2.circlepath", .error: "exclamationmark.shield"]
        case .shieldCheck:
            table = [.disconnected: "shield", .connected: "checkmark.shield.fill",
                     .connecting: "circle.dashed", .error: "xmark.shield"]
        case .lock:
            table = [.disconnected: "lock.open", .connected: "lock.fill",
                     .connecting: "ellipsis.circle", .error: "exclamationmark.lock"]
        case .key:
            table = [.disconnected: "key", .connected: "key.fill",
                     .connecting: "ellipsis.circle", .error: "key.slash"]
        case .network:
            table = [.disconnected: "network.slash", .connected: "network.badge.shield.half.filled",
                     .connecting: "network", .error: "exclamationmark.triangle"]
        case .tunnel:
            table = [.disconnected: "arrow.up.arrow.down.circle", .connected: "arrow.up.arrow.down.circle.fill",
                     .connecting: "circle.dashed", .error: "exclamationmark.triangle"]
        case .nodes:
            table = [.disconnected: "point.3.connected.trianglepath.dotted", .connected: "point.3.filled.connected.trianglepath.dotted",
                     .connecting: "ellipsis.circle", .error: "exclamationmark.triangle"]
        case .text:
            return nil
        }
        return table[s]
    }
}

enum MenuBarIcon {
    /// App 的連線狀態 → 圖示狀態（連線動作進行中也算「連線中」）
    static func state(for s: VPNState, busy: Bool) -> IconState {
        switch s {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnected: return busy ? .connecting : .disconnected
        case .helperMissing: return .error
        }
    }

    static let styleKey = "MenuBarIconStyle"
    static let colorKey = "MenuBarIconColorConnected"

    static var style: MenuBarIconStyle {
        get { MenuBarIconStyle(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .shield }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    /// 已連線時顯示綠色（其他狀態維持跟著狀態列變色）
    static var colorConnected: Bool {
        get { UserDefaults.standard.bool(forKey: colorKey) }
        set { UserDefaults.standard.set(newValue, forKey: colorKey) }
    }

    /// 產生圖示。pointSize 是 SF Symbol 的字級；狀態列用 15，預覽可以放大
    static func image(style: MenuBarIconStyle, state: IconState, colored: Bool, pointSize: CGFloat = 15) -> NSImage? {
        let tint: NSColor? = (colored && state == .connected) ? .systemGreen : nil
        if let name = style.symbol(state) {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: "VPN \(state.title)")?
                .withSymbolConfiguration(config) else { return nil }
            guard let tint else { img.isTemplate = true; return img }
            // 不用 paletteColors：它會把每一層都塗成同色，盾牌裡的鎖、勾、箭頭就看不見了。
            // 改成只替圖形的不透明處上色，挖空的部分維持透明
            return tinted(img, tint)
        }
        return textImage(state: state, height: pointSize * 1.1, tint: tint)
    }

    /// 把 template 圖的不透明處塗成指定顏色（保留挖空的洞）
    static func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        out.accessibilityDescription = img.accessibilityDescription
        return out
    }

    /// 「VPN」字樣：未連線是外框字，已連線是實心底反白字，連線中／異常在後面加「…」／「!」
    static func textImage(state: IconState, height: CGFloat, tint: NSColor?) -> NSImage {
        let label: String
        switch state {
        case .connecting: label = "VPN…"
        case .error: label = "VPN!"
        default: label = "VPN"
        }
        let font = NSFont.systemFont(ofSize: height * 0.62, weight: .bold)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let padX = height * 0.28
        let size = NSSize(width: ceil(textSize.width + padX * 2), height: ceil(height))
        let color = tint ?? .black   // template 圖只看透明度，顏色由系統決定

        let img = NSImage(size: size, flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: height * 0.22, yRadius: height * 0.22)
            let textRect = NSRect(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2,
                                  width: textSize.width, height: textSize.height)
            if state == .connected {
                // 實心底，字挖空
                color.setFill()
                box.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                (label as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: NSColor.black])
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                color.setStroke()
                box.lineWidth = 1.5
                box.stroke()
                (label as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: color])
            }
            return true
        }
        img.isTemplate = (tint == nil)
        img.accessibilityDescription = "VPN \(state.title)"
        return img
    }
}
