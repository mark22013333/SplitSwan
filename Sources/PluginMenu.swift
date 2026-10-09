// 外掛在狀態列選單中的區段：分隔線＋標題＋項目。外掛輸出是不受信任的資料，
// 這裡只負責把 PluginLogic 解析、驗證過的結果畫成 NSMenuItem，點擊交給 PluginRunner.perform。
import AppKit

enum PluginMenu {
    /// 掛在 NSMenuItem.representedObject 上的點擊資訊
    final class Action: NSObject {
        let pluginID: String
        let item: PluginLogic.Item
        init(pluginID: String, item: PluginLogic.Item) { self.pluginID = pluginID; self.item = item }
    }

    /// 每個外掛一個區段；外掛錯誤時標題後加「⚠︎」，子選單顯示一行原因
    @MainActor
    static func sections(_ plugins: [PluginRunner.Plugin], target: AnyObject, action: Selector) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for p in plugins {
            out.append(.separator())
            let header = NSMenuItem(title: p.title, action: nil, keyEquivalent: "")
            if let why = p.failure {
                header.title = p.title + " ⚠︎"
                let sub = NSMenu()
                sub.autoenablesItems = false
                let reason = NSMenuItem(title: why, action: nil, keyEquivalent: "")
                reason.isEnabled = false
                sub.addItem(reason)
                header.submenu = sub
                header.isEnabled = true
                out.append(header)
                continue
            }
            header.isEnabled = false
            out.append(header)
            guard let o = p.output else {
                let wait = NSMenuItem(title: "執行中…", action: nil, keyEquivalent: "")
                wait.isEnabled = false
                out.append(wait)
                continue
            }
            out.append(contentsOf: o.items.map { menuItem($0, pluginID: p.id, target: target, action: action) })
            if o.truncated {
                let t = NSMenuItem(title: "（輸出過長，只顯示前面部分）", action: nil, keyEquivalent: "")
                t.isEnabled = false
                out.append(t)
            }
        }
        return out
    }

    @MainActor
    private static func menuItem(_ item: PluginLogic.Item, pluginID: String, target: AnyObject, action: Selector) -> NSMenuItem {
        if item.isSeparator { return .separator() }
        let m = NSMenuItem(title: item.text, action: nil, keyEquivalent: "")
        if let c = item.color.flatMap(nsColor) {
            m.attributedTitle = NSAttributedString(string: item.text, attributes: [
                .foregroundColor: c, .font: NSFont.menuFont(ofSize: 0),
            ])
        }
        if item.href != nil || item.bash != nil || item.refresh {
            m.action = action
            m.target = target
            m.representedObject = Action(pluginID: pluginID, item: item)
        }
        if !item.children.isEmpty {
            let sub = NSMenu()
            sub.autoenablesItems = false
            for c in item.children { sub.addItem(menuItem(c, pluginID: pluginID, target: target, action: action)) }
            m.submenu = sub
        }
        m.isEnabled = true
        return m
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
}
