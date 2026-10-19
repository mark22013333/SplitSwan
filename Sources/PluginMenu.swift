// 外掛選單分成兩層：純值型別投影負責所有顯示規則，AppKit Adapter 只負責建立 NSMenuItem。
// 外掛輸出是不受信任的資料；點擊命令只攜帶 PluginLogic 已解析、驗證過的原始項目。
import Foundation

#if canImport(AppKit)
import AppKit
#endif

enum PluginMenu {
    /// 不含 Runner、計時器或其他服務參照的外掛快照。
    struct PluginSnapshot: Equatable, Sendable {
        struct Output: Equatable, Sendable {
            let items: [PluginLogic.Item]
            let truncated: Bool
            let settingsAvailable: Bool

            init(items: [PluginLogic.Item], truncated: Bool = false, settingsAvailable: Bool = false) {
                self.items = items
                self.truncated = truncated
                self.settingsAvailable = settingsAvailable
            }
        }

        let id: String
        let title: String
        let blockingError: String?
        let actionError: String?
        let output: Output?

        init(
            id: String,
            title: String,
            blockingError: String? = nil,
            actionError: String? = nil,
            output: Output? = nil
        ) {
            self.id = id
            self.title = title
            self.blockingError = blockingError
            self.actionError = actionError
            self.output = output
        }
    }

    /// 所有可點擊項目共用的命令 payload；呈現層不執行命令。
    enum Command: Equatable, Sendable {
        case pluginAction(pluginID: String, item: PluginLogic.Item)
        case settings
        case pluginSettings(pluginID: String)
        case refreshAll
    }

    /// 可在沒有 AppKit 的環境直接比對的純選單樹。
    struct Tree: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            enum Style: Equatable, Sendable {
                case text(color: String?)
                case separator
            }

            let title: String
            let isEnabled: Bool
            let style: Style
            let command: Command?
            let children: [Item]?

            init(
                title: String,
                isEnabled: Bool,
                style: Style = .text(color: nil),
                command: Command? = nil,
                children: [Item]? = nil
            ) {
                self.title = title
                self.isEnabled = isEnabled
                self.style = style
                self.command = command
                self.children = children
            }

            static let separator = Item(title: "", isEnabled: false, style: .separator)
        }

        let root: Item
    }

    /// 將執行期狀態投影成固定的「外掛」根選單。
    static func project(isActive: Bool, plugins: [PluginSnapshot]) -> Tree {
        var children: [Tree.Item]
        if !isActive {
            children = [disabled("外掛功能未啟用")]
        } else if plugins.isEmpty {
            children = [disabled("沒有可用的外掛")]
        } else {
            children = plugins.map(pluginItem)
        }

        children.append(.separator)
        children.append(Tree.Item(title: "外掛設定…", isEnabled: true, command: .settings))
        children.append(Tree.Item(title: "全部重新整理", isEnabled: isActive, command: .refreshAll))
        return Tree(root: Tree.Item(title: "外掛", isEnabled: true, children: children))
    }

    private static func pluginItem(_ plugin: PluginSnapshot) -> Tree.Item {
        let hasFailure = plugin.blockingError != nil || plugin.actionError != nil
        let title = plugin.title + (hasFailure ? " ⚠︎" : "")

        if let reason = plugin.blockingError {
            return Tree.Item(title: title, isEnabled: true, children: [disabled(reason)])
        }

        var children: [Tree.Item] = []
        if let reason = plugin.actionError {
            children.append(disabled(reason))
        }

        if let output = plugin.output {
            if plugin.actionError != nil, !output.items.isEmpty || output.truncated {
                children.append(.separator)
            }
            children.append(contentsOf: output.items.filter { $0.params["menu"] != "false" }.map { outputItem($0, pluginID: plugin.id) })
            if output.truncated {
                children.append(disabled("（輸出過長，只顯示前面部分）"))
            } else if output.items.isEmpty, plugin.actionError == nil {
                children.append(disabled("沒有可顯示的輸出"))
            }
        } else {
            if plugin.actionError != nil { children.append(.separator) }
            children.append(disabled("執行中…"))
        }

        if plugin.output?.settingsAvailable == true {
            if !children.isEmpty { children.append(.separator) }
            children.append(Tree.Item(title: "開啟設定…", isEnabled: true, command: .pluginSettings(pluginID: plugin.id)))
        }

        return Tree.Item(title: title, isEnabled: true, children: children)
    }

    private static func outputItem(_ item: PluginLogic.Item, pluginID: String) -> Tree.Item {
        if item.isSeparator { return .separator }
        let command: Command? = item.href != nil || item.bash != nil || item.refresh
            ? .pluginAction(pluginID: pluginID, item: item)
            : nil
        let children = item.children.isEmpty
            ? nil
            : item.children.filter { $0.params["menu"] != "false" }.map { outputItem($0, pluginID: pluginID) }
        return Tree.Item(
            title: item.text,
            isEnabled: true,
            style: .text(color: item.color),
            command: command,
            children: children
        )
    }

    private static func disabled(_ title: String) -> Tree.Item {
        Tree.Item(title: title, isEnabled: false)
    }

    #if canImport(AppKit)
    // MARK: - AppKit Adapter

    /// `NSMenuItem` 的標準 action 會結束整段選單追蹤。外掛腳本改用 view-backed 按鈕，
    /// 點擊後只送出命令並停留在原子選單，直到使用者點選單外或按 Esc。
    @MainActor
    final class StickyActionButton: NSButton {
        static let leadingInset: CGFloat = 28
        static let trailingInset: CGFloat = 12
        static let minimumWidth: CGFloat = 260

        let command: Command
        let normalTitleColor: NSColor
        private var hoverTrackingArea: NSTrackingArea?
        private var isHovered = false {
            didSet { needsDisplay = true }
        }

        init(title: String, color: NSColor?, command: Command, target: AnyObject, action: Selector) {
            self.command = command
            normalTitleColor = color ?? .labelColor
            super.init(frame: .zero)
            self.title = title
            self.target = target
            self.action = action
            isBordered = false
            bezelStyle = .inline
            alignment = .left
            font = .menuFont(ofSize: 0)
            focusRingType = .none
            setButtonType(.momentaryChange)
            toolTip = nil

            let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font!]).width)
            let width = max(Self.minimumWidth,
                            min(520, titleWidth + Self.leadingInset + Self.trailingInset))
            frame.size = NSSize(width: width, height: 24)
        }

        required init?(coder: NSCoder) { nil }

        override func updateTrackingAreas() {
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            hoverTrackingArea = trackingArea
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered = isEnabled
        }

        override func mouseExited(with event: NSEvent) {
            isHovered = false
        }

        override func draw(_ dirtyRect: NSRect) {
            if isHovered && isEnabled {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
            }

            let titleColor: NSColor
            if !isEnabled {
                titleColor = .disabledControlTextColor
            } else if isHovered {
                titleColor = .selectedMenuItemTextColor
            } else {
                titleColor = normalTitleColor
            }
            let titleFont = font ?? .menuFont(ofSize: 0)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributed = NSAttributedString(string: title, attributes: [
                .foregroundColor: titleColor,
                .font: titleFont,
                .paragraphStyle: paragraph,
            ])
            let textHeight = ceil(titleFont.boundingRectForFont.height)
            attributed.draw(in: NSRect(
                x: Self.leadingInset,
                y: floor((bounds.height - textHeight) / 2),
                width: max(0, bounds.width - Self.leadingInset - Self.trailingInset),
                height: textHeight
            ))
        }

        override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
            let sent = super.sendAction(action, to: target)
            if sent {
                title = "✓ 已送出，完成後會通知"
                isEnabled = false
                isHovered = false
                needsDisplay = true
            }
            return sent
        }
    }

    /// Adapter 只把純選單樹轉成 AppKit，不讀取 Runner／UserDefaults，也不執行命令。
    @MainActor
    static func rootItem(_ tree: Tree, target: AnyObject, action: Selector) -> NSMenuItem {
        appKitItem(tree.root, target: target, action: action)
    }

    @MainActor
    private static func appKitItem(_ item: Tree.Item, target: AnyObject, action: Selector) -> NSMenuItem {
        if item.style == .separator { return .separator() }

        let result = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        if case .text(let colorName) = item.style,
           let color = colorName.flatMap(nsColor) {
            result.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .foregroundColor: color,
                .font: NSFont.menuFont(ofSize: 0),
            ])
        }
        if let command = item.command {
            result.representedObject = command
            if item.children == nil, case .pluginAction = command {
                let color: NSColor?
                if case .text(let name) = item.style { color = name.flatMap(nsColor) } else { color = nil }
                result.view = StickyActionButton(title: item.title, color: color, command: command,
                                                 target: target, action: action)
            } else {
                result.action = action
                result.target = target
            }
        }
        if let children = item.children {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in children {
                submenu.addItem(appKitItem(child, target: target, action: action))
            }
            result.submenu = submenu
        }
        result.isEnabled = item.isEnabled
        return result
    }

    static func nsColor(_ name: String) -> NSColor? {
        switch name {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "green": return .systemGreen
        case "gray": return .systemGray
        default:
            guard let (r, g, b) = PluginLogic.rgb(name) else { return nil }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }
    #endif
}
