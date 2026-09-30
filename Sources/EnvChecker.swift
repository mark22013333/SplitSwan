// 環境檢查與一鍵安裝：strongSwan、root 輔助程式、sudoers 免密碼規則、設定檔、FortiClient 衝突
import AppKit
import Combine

enum CheckLevel { case ok, warn, fail, checking }

enum CheckAction: Equatable {
    case none
    case installStrongSwan      // brew install strongswan（一般使用者權限）
    case installHelper          // 跳出管理員密碼視窗，安裝輔助程式與 sudoers
    case openSettings           // 切到設定頁
}

struct CheckItem: Identifiable {
    let id: String
    let title: String
    var level: CheckLevel
    var detail: String
    var action: CheckAction = .none
    var actionTitle: String = ""
}

@MainActor
final class EnvChecker: ObservableObject {
    @Published private(set) var items: [CheckItem] = []
    @Published private(set) var running = false          // 安裝進行中
    @Published private(set) var runningText = ""
    @Published private(set) var lastMessage: String?

    static let strongSwanPrefix = "/opt/homebrew/opt/strongswan"
    static let brewPath = "/opt/homebrew/bin/brew"

    var allOK: Bool { !items.isEmpty && items.allSatisfy { $0.level == .ok || $0.level == .warn } }

    private var bundledHelper: String? { Bundle.main.path(forResource: "splitswan-helper", ofType: nil) }
    private var bundledInstaller: String? { Bundle.main.path(forResource: "install-root", ofType: "sh") }

    func check() {
        let fm = FileManager.default
        var list: [CheckItem] = []

        // 1. strongSwan
        let ssOK = fm.isExecutableFile(atPath: Self.strongSwanPrefix + "/libexec/ipsec/charon")
                && fm.isExecutableFile(atPath: Self.strongSwanPrefix + "/bin/swanctl")
        if ssOK {
            list.append(CheckItem(id: "ss", title: "strongSwan", level: .ok, detail: "已安裝（Homebrew）"))
        } else if fm.isExecutableFile(atPath: Self.brewPath) {
            list.append(CheckItem(id: "ss", title: "strongSwan", level: .fail, detail: "尚未安裝",
                                  action: .installStrongSwan, actionTitle: "安裝"))
        } else {
            list.append(CheckItem(id: "ss", title: "strongSwan", level: .fail,
                                  detail: "找不到 Homebrew（\(Self.brewPath)），請先安裝 Homebrew：https://brew.sh"))
        }

        // 2. 輔助程式：存在，且與 App 內附的版本一致
        let installed = fm.contents(atPath: helperPath)
        let bundled = bundledHelper.flatMap { fm.contents(atPath: $0) }
        if installed == nil {
            list.append(CheckItem(id: "helper", title: "系統元件（輔助程式）", level: .fail, detail: "尚未安裝",
                                  action: .installHelper, actionTitle: "安裝"))
        } else if let bundled, installed != bundled {
            list.append(CheckItem(id: "helper", title: "系統元件（輔助程式）", level: .fail,
                                  detail: "已安裝的版本與 App 內附的不同，需要更新",
                                  action: .installHelper, actionTitle: "更新"))
        } else {
            list.append(CheckItem(id: "helper", title: "系統元件（輔助程式）", level: .ok, detail: helperPath))
        }

        // 3. 免密碼權限（實際執行一次才算數）
        list.append(CheckItem(id: "sudo", title: "免密碼執行權限", level: .checking, detail: "檢查中…"))

        // 4. 連線設定
        let settings = ConfigStore.load()
        if !fm.fileExists(atPath: ConfigStore.confPath) {
            list.append(CheckItem(id: "conf", title: "連線設定", level: .fail, detail: "尚未建立",
                                  action: .openSettings, actionTitle: "前往設定"))
        } else if settings.gateways.allSatisfy({ $0.isEmpty }) || settings.remoteTS.isEmpty {
            list.append(CheckItem(id: "conf", title: "連線設定", level: .fail,
                                  detail: "尚未設定閘道或通道網段，請到設定頁匯入公司設定檔",
                                  action: .openSettings, actionTitle: "前往設定"))
        } else if (try? ConfigStore.validate(settings)) == nil {
            list.append(CheckItem(id: "conf", title: "連線設定", level: .fail, detail: "帳號、閘道或網段格式不完整",
                                  action: .openSettings, actionTitle: "前往設定"))
        } else if !ConfigStore.confGeneratedByApp {
            list.append(CheckItem(id: "conf", title: "連線設定", level: .warn,
                                  detail: "設定檔是手動建立的，到設定頁按一次「儲存」改由 App 管理",
                                  action: .openSettings, actionTitle: "前往設定"))
        } else {
            let n = settings.gateways.filter { !$0.isEmpty }.count
            list.append(CheckItem(id: "conf", title: "連線設定", level: .ok, detail: "\(n) 台閘道，帳號 \(settings.username)"))
        }

        // 5. PSK 與密碼
        let sec = ConfigStore.secretsStatus()
        if sec.psk && sec.password {
            list.append(CheckItem(id: "secret", title: "預設共享金鑰與密碼", level: .ok, detail: "已設定"))
        } else {
            let missing = [sec.psk ? nil : "預設共享金鑰", sec.password ? nil : "密碼"].compactMap { $0 }.joined(separator: "、")
            list.append(CheckItem(id: "secret", title: "預設共享金鑰與密碼", level: .fail, detail: "尚未設定：\(missing)",
                                  action: .openSettings, actionTitle: "前往設定"))
        }

        // 6. FortiClient 同時連線會衝突
        let forti = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").lowercased().contains("fortinet") || ($0.localizedName ?? "").hasPrefix("FortiClient")
        }
        list.append(CheckItem(id: "forti", title: "FortiClient", level: forti ? .warn : .ok,
                              detail: forti ? "正在執行中；用 \(AppInfo.name) 連線前，請先在 FortiClient 斷線" : "未執行"))

        items = list

        Task {
            let (code, _) = await VPNController.runHelper(["status"])
            update("sudo") {
                if code == 0 { $0.level = .ok; $0.detail = "已設定（/etc/sudoers.d/splitswan）" }
                else { $0.level = .fail; $0.detail = "無法免密碼執行輔助程式"; $0.action = .installHelper; $0.actionTitle = "安裝" }
            }
        }
    }

    private func update(_ id: String, _ change: (inout CheckItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    // MARK: 安裝動作

    func installStrongSwan() {
        guard !running else { return }
        running = true
        runningText = "正在安裝 strongSwan（brew install strongswan），約需 1 分鐘…"
        lastMessage = nil
        Task {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            let (code, out) = await VPNController.run(Self.brewPath, ["install", "strongswan"], env: env)
            running = false
            runningText = ""
            lastMessage = code == 0 ? "strongSwan 安裝完成" : "安裝失敗：\(out.split(separator: "\n").suffix(3).joined(separator: " "))"
            check()
        }
    }

    /// 以管理員權限執行 App 內附的 install-root.sh（macOS 會跳出密碼視窗）
    func installHelper() {
        guard !running else { return }
        guard let installer = bundledInstaller else {
            lastMessage = "App 內找不到安裝腳本，請重新安裝 \(AppInfo.name)"
            return
        }
        let user = NSUserName()
        let cmd = "/bin/bash \(shellQuote(installer)) \(shellQuote(user))"
        let source = "do shell script \(appleScriptString(cmd)) with administrator privileges"
        running = true
        runningText = "等待管理員授權並安裝系統元件…"
        lastMessage = nil
        Task {
            // 在背景執行 osascript，等密碼視窗時 App 不會凍結
            let (code, out) = await VPNController.run("/usr/bin/osascript", ["-e", source])
            running = false
            runningText = ""
            if code == 0 {
                lastMessage = out.contains("已安裝") ? "系統元件安裝完成" : "安裝結果：\(out)"
                // 新版輔助程式才有 reload-settings：裝好後立刻讓 charon 套用重送參數（規格 §2.1），
                // 否則要等 charon 重新啟動（約等於重開機）才生效
                _ = await VPNController.runHelper(["reload"])
                _ = await VPNController.runHelper(["reload-settings"])
            } else {
                lastMessage = out.contains("-128") ? "已取消安裝" : "安裝失敗：\(out)"
            }
            check()
            // 管理員密碼視窗關掉後，焦點會回到前一個 App，狀態列 App 的視窗會被蓋在後面，看起來像被關掉
            NotificationCenter.default.post(name: .splitSwanShowWindow, object: MainTab.environment)
        }
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
