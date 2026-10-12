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

            init(items: [PluginLogic.Item], truncated: Bool = false) {
                self.items = items
                self.truncated = truncated
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
            children.append(contentsOf: output.items.map { outputItem($0, pluginID: plugin.id) })
            if output.truncated {
                children.append(disabled("（輸出過長，只顯示前面部分）"))
            } else if output.items.isEmpty, plugin.actionError == nil {
                children.append(disabled("沒有可顯示的輸出"))
            }
        } else {
            if plugin.actionError != nil { children.append(.separator) }
            children.append(disabled("執行中…"))
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
            : item.children.map { outputItem($0, pluginID: pluginID) }
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
            result.action = action
            result.target = target
            result.representedObject = command
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
