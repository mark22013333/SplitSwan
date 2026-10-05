// 檢查更新與一鍵更新：「關於」分頁與狀態列選單共用同一個實例。
// 安裝流程：查 release 附檔 → 下載 dmg 與 .sig → 用內建公鑰驗證簽章 → 掛載 dmg 檢查 App →
// 複製出來、驗證程式碼簽章 → 取代目前的 App → 等本程序結束後重新開啟。VPN 通道由 charon 維持，不會中斷。
import AppKit
import Combine
import Foundation

@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    /// 「每天自動檢查更新」，預設不勾選
    static let autoCheckKey = "AutoCheckUpdates"
    private static let lastCheckKey = "LastUpdateCheck"

    enum CheckState: Equatable {
        case idle, checking
        case done(AboutInfo.Outcome)
    }
    enum InstallState: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published private(set) var check = CheckState.idle
    @Published private(set) var install = InstallState.idle

    /// 目前已知的新版本（狀態列選單用）
    var newerVersion: String? {
        if case .done(.newer(let v, _)) = check { return v }
        return nil
    }
    var isInstalling: Bool { if case .working = install { return true }; return false }

    private var timer: Timer?

    // MARK: 檢查

    /// 啟動後呼叫：有勾選才會連網。每小時看一次是否已滿 24 小時，睡眠喚醒後也會補檢查
    func startAutoCheck() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateCenter.shared.autoCheckIfDue() }
        }
        // 開機登入時網路可能還沒好，晚一分鐘再看
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.autoCheckIfDue() }
    }

    func autoCheckIfDue() {
        let d = UserDefaults.standard
        guard UpdateLogic.shouldAutoCheck(enabled: d.bool(forKey: Self.autoCheckKey),
                                          last: d.object(forKey: Self.lastCheckKey) as? Date, now: Date()),
              check != .checking, !isInstalling else { return }
        checkNow()
    }

    func checkNow() {
        guard check != .checking else { return }
        check = .checking
        Task {
            let outcome = await AboutInfo.fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            check = .done(outcome)
        }
    }

    // MARK: 一鍵更新

    func installLatest() {
        guard !isInstalling else { return }
        let bundlePath = Bundle.main.bundlePath
        let parent = (bundlePath as NSString).deletingLastPathComponent
        if let why = UpdateLogic.installBlocker(bundlePath: bundlePath,
                                                parentWritable: FileManager.default.isWritableFile(atPath: parent)) {
            install = .failed(why); return
        }
        guard let bundleID = Bundle.main.bundleIdentifier else { install = .failed("讀不到 App 的 bundle id"); return }
        install = .working("查詢最新版本…")
        Task {
            do {
                let staged = try await UpdateInstaller.prepare(bundleID: bundleID) { [weak self] text in
                    Task { @MainActor in self?.install = .working(text) }
                }
                install = .working("安裝中…")
                try UpdateInstaller.swap(target: URL(fileURLWithPath: bundlePath), with: staged)
                LogStore.shared.app("已安裝新版，重新開啟 \(AppInfo.name)")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = UpdateLogic.relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, appPath: bundlePath)
                try p.run()
                NSApp.terminate(nil)
            } catch {
                install = .failed(error.localizedDescription)
            }
        }
    }
}
