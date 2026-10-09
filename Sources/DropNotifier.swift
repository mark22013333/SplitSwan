// F2 非預期斷線通知的發送端（docs/SPEC-1.3.md §4）：要不要發由 DropDetector 判定，這裡只負責送出。
// 第一次真的要發通知時才請求權限；App 是 accessory，前景時也要顯示橫幅。
// 外掛通知（PluginRunner）也從這裡送出：userInfo 標記 kind=plugin，點擊時若帶 href 就開啟。
import AppKit
import Foundation
import UserNotifications

@MainActor
final class DropNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DropNotifier()

    /// App 啟動時呼叫：設定 delegate，前景時的通知才會顯示
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated static let kindKey = "kind"
    nonisolated static let hrefKey = "href"

    /// VPN 斷線／恢復通知
    func send(title: String, body: String) {
        deliver(title: title, subtitle: nil, body: body, userInfo: [Self.kindKey: "vpn"], thread: "vpn")
    }

    /// 外掛通知：與 VPN 通知分開歸類。標題由 PluginRunner 固定為「外掛：<名稱>」，外掛輸出的標題只放副標題；
    /// href 只接受 http／https（PluginLogic 已驗證，點擊時再驗一次）
    func sendPlugin(plugin: String, title: String, subtitle: String?, body: String, href: URL?) {
        var info: [String: String] = [Self.kindKey: "plugin"]
        if let href { info[Self.hrefKey] = href.absoluteString }
        deliver(title: title, subtitle: subtitle, body: body, userInfo: info, thread: "plugin-" + plugin)
    }

    /// 點擊外掛通知要開的網址；不是外掛通知或不是 http／https 回 nil
    nonisolated static func pluginHref(_ userInfo: [AnyHashable: Any]) -> URL? {
        guard userInfo[kindKey] as? String == "plugin", let s = userInfo[hrefKey] as? String,
              let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              u.host?.isEmpty == false else { return nil }
        return u
    }

    private func deliver(title: String, subtitle: String?, body: String, userInfo: [String: String], thread: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .notDetermined:
                // 第一次要發：先請求權限，同意後再送出這則
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                    LogStore.shared.app("使用者未允許通知，略過")
                    return
                }
            case .denied:
                LogStore.shared.app("macOS 未允許通知，略過")
                return
            default:
                break
            }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            content.body = body
            content.sound = .default
            content.userInfo = userInfo
            content.threadIdentifier = thread
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do { try await center.add(req) } catch { LogStore.shared.app("通知送出失敗：\(error.localizedDescription)") }
        }
    }

    /// 設定頁用：通知權限是不是被拒絕（未決定或已允許都回 false）
    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    // 前景（例：主視窗開著）時也顯示橫幅與聲音
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // 點擊通知：外掛通知帶 href 就開啟；VPN 通知維持原本行為（不做事）
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let url = Self.pluginHref(response.notification.request.content.userInfo) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
