// App 名稱與版本：從 Info.plist 讀取（由 build.sh 依 app.env 寫入），改名、改版不用改程式
import Foundation

enum AppInfo {
    static let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "SplitSwan"
    /// 例：1.6.0（CFBundleShortVersionString）
    static let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    /// 例：13（CFBundleVersion）
    static let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"

    /// 專案頁：只在這裡定義一次，owner／repo 名稱與其他連結都由它推得
    static let repoURL = URL(string: "https://github.com/mark22013333/SplitSwan")!
    static var repoOwner: String { repoURL.pathComponents.dropFirst().first ?? "" }
    static var repoName: String { repoURL.pathComponents.dropFirst(2).first ?? "" }
    static var readmeURL: URL { URL(string: repoURL.absoluteString + "#readme")! }
    static var releasesURL: URL { repoURL.appendingPathComponent("releases") }
    static var licenseURL: URL { repoURL.appendingPathComponent("blob/main/LICENSE") }
    /// GitHub API：最新正式版（draft／prerelease 由端點本身排除）
    static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }
}

extension Notification.Name {
    /// 要求把主視窗帶到最前面；object 可帶要切換到的 MainTab
    static let splitSwanShowWindow = Notification.Name("SplitSwanShowWindow")
}
