import AppKit
import Foundation
import SwiftUI
// 外掛資訊卡片：card= 解碼與驗證、選單投影順序、資訊列不可點，以及卡片截圖（只用去識別化範例）。
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
typealias Card = PluginMenuCard
typealias M = PluginMenu

final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

func encode(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func history(_ entries: [(String, String, String?, String)]) -> [[String: Any]] {
    entries.map { d in
        var o: [String: Any] = ["date": d.0, "weekday": d.1, "result": d.3]
        if let t = d.2 { o["time"] = t }
        return o
    }
}

let tenDays = history([
    ("2026-10-08", "四", "08:33", "auto"), ("2026-10-12", "一", "08:42", "auto"), ("2026-10-13", "二", "08:31", "auto"),
    ("2026-10-14", "三", "08:52", "manual"), ("2026-10-15", "四", "08:47", "auto"), ("2026-10-16", "五", nil, "leave"),
    ("2026-10-19", "一", "08:39", "auto"), ("2026-10-20", "二", nil, "missed"), ("2026-10-21", "三", "08:44", "auto"),
    ("2026-10-22", "四", "08:35", "auto"),
])

func cardJSON(_ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
    var o: [String: Any] = [
        "version": 1, "headline": "今天上班 · 預定 08:41 打卡", "tone": "ok", "detail": "時段 08:30–09:00（需開著 SplitSwan）", "enabled": true,
        "timeline": ["start": "08:20", "end": "09:05", "check": "08:24", "windowStart": "08:30", "windowEnd": "09:00", "planned": "08:41", "now": "08:35"],
        "conditions": [["label": "App", "value": "開啟", "tone": "ok"], ["label": "電源", "value": "已接上", "tone": "ok"], ["label": "VPN", "value": "已連線", "tone": "ok"]],
        "history": tenDays,
    ]
    change(&o)
    return o
}

// MARK: 解碼
let decoded = Card.decode(encode(cardJSON()))
check("卡片：合法內容解碼成功", decoded?.headline == "今天上班 · 預定 08:41 打卡" && decoded?.tone == .ok && decoded?.enabled == true
      && decoded?.timeline?.planned == Card.Clock("08:41") && decoded?.timeline?.actual == nil
      && decoded?.conditions.map(\.label) == ["App", "電源", "VPN"] && decoded?.history.count == 10
      && decoded?.history[5].time == nil && decoded?.history[5].result == .leave && decoded?.history[0].shortDate == "10/8")
check("卡片：近期統計與圖例", decoded?.historySummary == "自動打卡平均 08:39（7 天） · 人工 1、請假 1、未執行 1"
      && decoded?.legend == [.auto, .manual, .leave, .missed])
let minimal = Card.decode(encode(["version": 1, "headline": "簡短", "tone": "neutral", "enabled": false, "conditions": [], "history": []]))
check("卡片：選填欄位可省略", minimal != nil && minimal?.timeline == nil && minimal?.detail == nil && minimal?.historySummary == nil)
let padded = try! JSONSerialization.data(withJSONObject: cardJSON()).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
check("卡片：接受帶補位的 base64url", Card.decode(padded) == decoded)
let dirty = Card.decode(encode(cardJSON { $0["headline"] = "標題\u{202E}反轉\n換行" + String(repeating: "長", count: 300) }))
check("卡片：文字去控制字元並截斷", dirty.map { !$0.headline.contains("\u{202E}") && !$0.headline.contains("\n") && $0.headline.count <= 61 } == true)

let rejections: [(String, String)] = [
    ("壞 base64", "!!!notbase64"),
    ("非 JSON", encode(["a"]).replacingOccurrences(of: "W", with: "X")),
    ("解碼後超過 8KB", encode(cardJSON { $0["footnote"] = String(repeating: "a", count: 9000) })),
    ("編碼字串過長", String(repeating: "A", count: 11_000)),
    ("未知版本", encode(cardJSON { $0["version"] = 2 })),
    ("未知 tone", encode(cardJSON { $0["tone"] = "purple" })),
    ("未知條件 tone", encode(cardJSON { $0["conditions"] = [["label": "App", "value": "開啟", "tone": "blue"]] })),
    ("未知 result", encode(cardJSON { $0["history"] = history([("2026-10-08", "四", nil, "late")]) })),
    ("時間格式錯（單位數）", encode(cardJSON { $0["timeline"] = ["start": "8:20", "end": "09:05", "check": "08:24", "windowStart": "08:30", "windowEnd": "09:00"] })),
    ("時間格式錯（全形數字）", encode(cardJSON { $0["history"] = history([("2026-10-08", "四", "０8:33", "auto")]) })),
    ("時間超出範圍", encode(cardJSON { $0["timeline"] = ["start": "08:20", "end": "09:05", "check": "08:24", "windowStart": "08:30", "windowEnd": "09:00", "now": "10:00"] })),
    ("時段顛倒", encode(cardJSON { $0["timeline"] = ["start": "08:20", "end": "09:05", "check": "08:24", "windowStart": "09:00", "windowEnd": "08:30"] })),
    ("日期格式錯", encode(cardJSON { $0["history"] = history([("2026/10/08", "四", nil, "leave")]) })),
    ("日期未遞增", encode(cardJSON { $0["history"] = history([("2026-10-09", "五", nil, "leave"), ("2026-10-08", "四", nil, "leave")]) })),
    ("條件超過 4 個", encode(cardJSON { $0["conditions"] = Array(repeating: ["label": "A", "value": "B", "tone": "ok"], count: 5) })),
    ("歷史超過 14 筆", encode(cardJSON { $0["history"] = (1...15).map { ["date": String(format: "2026-09-%02d", $0), "weekday": "一", "result": "auto", "time": "08:40"] } })),
    ("缺少必要欄位", encode(cardJSON { $0["enabled"] = nil })),
    ("型別錯誤", encode(cardJSON { $0["enabled"] = "true" })),
    ("空標題", encode(cardJSON { $0["headline"] = "\u{202E}" })),
]
for (name, raw) in rejections { check("卡片：拒絕\(name)", Card.decode(raw) == nil) }

// MARK: 輸出解析：卡片壞掉時文字列照舊
let goodOutput = PluginLogic.parseOutput("外掛 | settings=true card=\(encode(cardJSON()))\n---\n補充資訊\n立即重新整理 | refresh=true\n")
check("解析：標題行 card 參數成為卡片，不混入標題", goodOutput.card == decoded && goodOutput.title == "外掛" && goodOutput.settingsAvailable
      && goodOutput.items.map(\.text) == ["補充資訊", "立即重新整理"])
for (name, raw) in rejections.prefix(5) {
    let out = PluginLogic.parseOutput("外掛 | settings=true card=\(raw)\n---\n狀態列\n")
    check("解析：\(name)時忽略卡片、文字列照舊", out.card == nil && out.settingsAvailable && out.items.map(\.text) == ["狀態列"])
}

// MARK: 選單投影
let tree = M.project(isActive: true, plugins: [.init(id: "card.sh", title: "卡片外掛",
    output: .init(items: goodOutput.items, settingsAvailable: true, card: goodOutput.card))])
let kids = tree.root.children?.first?.children ?? []
check("投影：卡片在子選單最上方，接著分隔線、輸出、設定入口",
      kids.count == 6 && kids[0].style == .card(pluginID: "card.sh", decoded!) && !kids[0].isEnabled
      && kids[1].style == .separator && kids[2].title == "補充資訊" && kids[3].title == "立即重新整理"
      && kids[4].style == .separator && kids[5].command == .pluginSettings(pluginID: "card.sh"))
check("投影：沒有動作的資訊列不可點但保留顏色", kids[2].style == .info(color: nil) && !kids[2].isEnabled && kids[2].command == nil)
check("投影：有動作的列仍可點", kids[3].isEnabled && kids[3].command == .pluginAction(pluginID: "card.sh", item: goodOutput.items[1]))
let onlyCard = M.project(isActive: true, plugins: [.init(id: "card.sh", title: "卡片外掛", output: .init(items: [], settingsAvailable: true, card: decoded))])
check("投影：只有卡片時不顯示「沒有可顯示的輸出」", (onlyCard.root.children?.first?.children ?? []).map(\.title) == [decoded!.headline, "", "開啟設定…"])
let colored = PluginLogic.parseOutput("外掛\n---\n警告文字 | color=orange\n父項\n--子動作 | href=https://example.com/a\n")
let coloredKids = M.project(isActive: true, plugins: [.init(id: "c.sh", title: "c", output: .init(items: colored.items))]).root.children?.first?.children ?? []
check("投影：資訊列保留 color、含子項目的列維持可展開", coloredKids[0].style == .info(color: "orange") && coloredKids[1].isEnabled
      && coloredKids[1].children?.first?.command != nil)

// MARK: AppKit 轉接與截圖
let app = NSApplication.shared
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
let shots = root.appendingPathComponent("screenshots")
try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    let hosts = M.CardHosts()
    let target = NSObject()
    let first = M.rootItem(tree, target: target, action: Selector(("pluginAction:")), cards: hosts)
    let items = first.submenu?.items.first?.submenu?.items ?? []
    let host = items.first?.view as? NSHostingView<PluginMenuCardView>
    check("AppKit：卡片是固定寬度的 NSHostingView，高度依內容", host != nil && host?.frame.width == PluginMenuCardView.width
          && (host?.frame.height ?? 0) > 200)
    let info = items.count > 2 ? items[2] : nil
    let infoView = info?.view as? M.InfoRowView
    check("AppKit：資訊列以 view 呈現、無 action、文字為一般標籤色", infoView != nil && info?.action == nil && info?.isEnabled == false
          && infoView?.textColor == .labelColor)
    let action = items.count > 3 ? items[3] : nil
    check("AppKit：可點項目仍是可點的按鈕", (action?.view as? M.StickyActionButton)?.isEnabled == true)
    let second = M.rootItem(tree, target: target, action: Selector(("pluginAction:")), cards: hosts)
    let secondHost = second.submenu?.items.first?.submenu?.items.first?.view
    check("AppKit：重建選單沿用同一個 NSHostingView，舊項目釋放 view", secondHost === host && items.first?.view == nil && hosts.count == 1)
    _ = M.rootItem(M.project(isActive: true, plugins: []), target: target, action: Selector(("pluginAction:")), cards: hosts)
    check("AppKit：外掛不再提供卡片時釋放快取", hosts.count == 0)

    let scenarios: [(String, [String: Any])] = [
        ("pending", cardJSON()),
        ("done", cardJSON {
            $0["headline"] = "今天已打卡 · 08:41 自動打卡"
            $0["detail"] = "政府日曆：上班日"
            $0["timeline"] = ["start": "08:20", "end": "09:05", "check": "08:24", "windowStart": "08:30", "windowEnd": "09:00", "planned": "08:41", "actual": "08:41", "now": "08:52"]
        }),
        ("holiday", cardJSON {
            $0["headline"] = "今天不上班"; $0["tone"] = "info"; $0["detail"] = "政府日曆：補假"
            $0["timeline"] = ["start": "08:20", "end": "09:05", "check": "08:24", "windowStart": "08:30", "windowEnd": "09:00", "now": "08:35"]
            $0["conditions"] = [["label": "App", "value": "開啟", "tone": "ok"], ["label": "電源", "value": "使用電池", "tone": "neutral"]]
        }),
        ("no-timeline", cardJSON {
            $0["headline"] = "背景自動上班未啟用"; $0["tone"] = "warn"; $0["enabled"] = false
            $0["timeline"] = nil; $0["conditions"] = []
        }),
        ("unconfirmed", cardJSON {
            $0["headline"] = "打卡結果未確認"; $0["tone"] = "warn"
            $0["detail"] = "已送出打卡，但背景工作沒有回報結果；請到打卡網站檢查，不要重複打卡"
            $0["timeline"] = ["start": "08:20", "end": "09:35", "check": "08:24", "windowStart": "08:30", "windowEnd": "09:00", "planned": "08:41", "now": "09:30"]
        }),
        ("vpn", cardJSON {
            $0["headline"] = "等待 VPN 連線後自動打卡"; $0["tone"] = "warn"
            $0["detail"] = "已過預定時間 08:41；條件恢復後立即打卡"
            $0["timeline"] = ["start": "08:20", "end": "09:05", "check": "08:24", "windowStart": "08:30", "windowEnd": "09:00", "planned": "08:41", "now": "08:50"]
            $0["conditions"] = [["label": "App", "value": "開啟", "tone": "ok"], ["label": "電源", "value": "已接上", "tone": "ok"], ["label": "VPN", "value": "未連線", "tone": "warn"]]
        }),
    ]
    var rendered = 0
    for (name, json) in scenarios {
        guard let card = Card.decode(encode(json)) else { check("截圖情境 \(name) 可解碼", false); continue }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let view = NSHostingView(rootView: PluginMenuCardView(card: card))
            view.frame.size = NSSize(width: PluginMenuCardView.width, height: ceil(view.fittingSize.height))
            // 選單本身有背景；截圖補上近似的選單底色，深色模式的主要文字才看得到。
            let backdrop = Backdrop(frame: NSRect(origin: .zero, size: view.frame.size))
            backdrop.addSubview(view)
            let window = NSWindow(contentRect: backdrop.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = backdrop
            backdrop.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let bitmap = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { continue }
            backdrop.effectiveAppearance.performAsCurrentDrawingAppearance { backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap) }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: shots.appendingPathComponent("card-\(name)-\(suffix).png"))
            rendered += 1
        }
    }
    check("截圖：6 個情境 × 深淺色都已輸出", rendered == 12)

    var rows = 0
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        let backdrop = Backdrop(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        let plain = M.InfoRowView(title: "資訊列：一般文字色", color: nil)
        let orange = M.InfoRowView(title: "資訊列：外掛指定 orange", color: M.nsColor("orange"))
        plain.frame.origin = NSPoint(x: 0, y: 22); backdrop.addSubview(plain); backdrop.addSubview(orange)
        let window = NSWindow(contentRect: backdrop.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = backdrop
        window.displayIfNeeded()
        guard let bitmap = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { continue }
        backdrop.effectiveAppearance.performAsCurrentDrawingAppearance { backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap) }
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: shots.appendingPathComponent("info-rows-\(suffix).png")); rows += 1
        }
    }
    check("截圖：資訊列深淺色都已輸出", rows == 2)
}

print("通過 \(pass)，失敗 \(fail)")
