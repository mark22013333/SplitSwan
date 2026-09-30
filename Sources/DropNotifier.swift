// F2 非預期斷線通知的發送端（docs/SPEC-1.3.md §4）：要不要發由 DropDetector 判定，這裡只負責送出。
// 第一次真的要發通知時才請求權限；App 是 accessory，前景時也要顯示橫幅。
import Foundation
import UserNotifications

@MainActor
final class DropNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DropNotifier()

    /// App 啟動時呼叫：設定 delegate，前景時的通知才會顯示
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func send(title: String, body: String) {
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
            content.body = body
            content.sound = .default
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
}
