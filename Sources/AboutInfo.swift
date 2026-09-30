// 「關於」分頁的邏輯：版本字串、版本比較、GitHub 最新版回應解析（純函式，有 Tests/AboutTests.swift），
// 以及實際連網的 fetchLatest（只有使用者按「檢查更新」時才會呼叫）
import Foundation

enum AboutInfo {
    /// 「版本 1.6.0（13）」
    static func versionText(version: String, build: String) -> String { "版本 \(version)（\(build)）" }

    /// 拷貝用的一行版本資訊：「SplitSwan 1.6.0（13）· macOS 15.5 · Apple M2」
    static func copyText(app: String, version: String, build: String, macOS: String, chip: String) -> String {
        "\(app) \(version)（\(build)）· macOS \(macOS) · \(chip)"
    }

    /// 目前的 macOS 版本，例：15.5、14.6.1
    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// 晶片名稱，例：Apple M2；讀不到時退回架構名稱（arm64）
    static var chip: String {
        if let brand = sysctlString("machdep.cpu.brand_string"), !brand.isEmpty { return brand }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    // MARK: 版本比較

    /// 「v1.10.0」→ [1, 10, 0]。可帶 v／V 前綴；每段只接受 ASCII 數字（不接受全形、空段、-beta 之類的後綴），
    /// 無法解析回傳 nil（呼叫端當成失敗，不可誤判成有新版）
    static func parseVersion(_ raw: String) -> [Int]? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(p) else { return nil }
            nums.append(n)
        }
        return nums
    }

    /// 逐段數字比較，段數不同時補 0（1.6 == 1.6.0；1.10.0 > 1.9.0）
    static func compare(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: GitHub 回應

    struct Release: Equatable {
        var tag: String
        var url: URL
    }

    /// 從 /releases/latest 的 JSON 取出 tag_name 與 html_url；缺欄位、型別不對、
    /// 網址不是 https://github.com/ 開頭（之後會拿去開瀏覽器）都回 nil
    static func parseRelease(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty,
              let html = obj["html_url"] as? String, html.hasPrefix("https://github.com/"),
              let url = URL(string: html) else { return nil }
        return Release(tag: tag, url: url)
    }

    enum Outcome: Equatable {
        case newer(version: String, url: URL)   // 有新版本
        case upToDate(version: String)           // 已是最新（或 GitHub 上的比較舊）；version 是目前 App 的版本
        case failed(String)                      // 簡短原因，畫面另外提供「開啟 Releases 頁」
    }

    static let networkFailure = "無法連線到 GitHub，請稍後再試"

    /// 依 HTTP 狀態與內容判斷結果；status 為 nil 表示連線本身失敗（逾時、沒網路）
    static func evaluate(status: Int?, data: Data?, current: String) -> Outcome {
        guard let status else { return .failed(networkFailure) }
        switch status {
        case 200: break
        case 403, 429: return .failed("GitHub 查詢次數暫時達到上限，請稍後再試")
        case 404: return .failed("GitHub 上找不到已發布的版本")
        default: return .failed("GitHub 回應異常（HTTP \(status)），請稍後再試")
        }
        guard let data, let release = parseRelease(data) else { return .failed("無法解讀 GitHub 的回應") }
        guard let latest = parseVersion(release.tag) else { return .failed("無法辨識最新版本號（\(release.tag)）") }
        guard let mine = parseVersion(current) else { return .failed("無法辨識目前的版本號（\(current)）") }
        let shown = latest.map(String.init).joined(separator: ".")
        // 已是最新時顯示目前 App 的版本：GitHub 上可能比較舊（例如新版尚未發布），顯示它會讓人以為自己是舊版
        let current = mine.map(String.init).joined(separator: ".")
        return compare(latest, mine) == .orderedDescending ? .newer(version: shown, url: release.url) : .upToDate(version: current)
    }

    // MARK: 連網（只在按下「檢查更新」時呼叫）

    static func fetchLatest(current: String = AppInfo.version) async -> Outcome {
        var req = URLRequest(url: AppInfo.latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("\(AppInfo.name)/\(current)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 10
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            return evaluate(status: (resp as? HTTPURLResponse)?.statusCode, data: data, current: current)
        } catch {
            return .failed(networkFailure)
        }
    }
}
