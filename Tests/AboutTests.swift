import Foundation
// 「關於」分頁：版本比較、GitHub 回應解析、結果判斷、連結位址（全部離線，不連網）
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
func json(_ s: String) -> Data { Data(s.utf8) }
func cmp(_ a: String, _ b: String) -> ComparisonResult? {
    guard let x = AboutInfo.parseVersion(a), let y = AboutInfo.parseVersion(b) else { return nil }
    return AboutInfo.compare(x, y)
}

// MARK: 版本解析
check("解析：1.6.0", AboutInfo.parseVersion("1.6.0") == [1, 6, 0])
check("解析：v 前綴", AboutInfo.parseVersion("v1.6.0") == [1, 6, 0])
check("解析：大寫 V 前綴", AboutInfo.parseVersion("V2.0") == [2, 0])
check("解析：前後空白", AboutInfo.parseVersion(" v1.2.3 ") == [1, 2, 3])
check("解析：單段", AboutInfo.parseVersion("2") == [2])
check("無法解析：空字串", AboutInfo.parseVersion("") == nil)
check("無法解析：只有 v", AboutInfo.parseVersion("v") == nil)
check("無法解析：-beta 後綴", AboutInfo.parseVersion("v1.7.0-beta") == nil)
check("無法解析：空段", AboutInfo.parseVersion("1..0") == nil && AboutInfo.parseVersion("1.6.") == nil)
check("無法解析：文字 tag", AboutInfo.parseVersion("latest") == nil && AboutInfo.parseVersion("release-1.6") == nil)
check("無法解析：全形數字", AboutInfo.parseVersion("１.6.0") == nil)
check("無法解析：負號", AboutInfo.parseVersion("1.-6.0") == nil)
check("無法解析：段數過多", AboutInfo.parseVersion("1.2.3.4.5") == nil)

// MARK: 版本比較
check("1.10.0 > 1.9.0（逐段數字，不是字串）", cmp("1.10.0", "1.9.0") == .orderedDescending)
check("1.9.0 < 1.10.0", cmp("1.9.0", "1.10.0") == .orderedAscending)
check("1.6 == 1.6.0（段數不同補 0）", cmp("1.6", "1.6.0") == .orderedSame)
check("1.6.0 == 1.6", cmp("1.6.0", "1.6") == .orderedSame)
check("1.6.1 > 1.6", cmp("1.6.1", "1.6") == .orderedDescending)
check("v1.6.0 == 1.6.0（v 前綴不影響）", cmp("v1.6.0", "1.6.0") == .orderedSame)
check("較舊：1.5.2 < 1.6.0", cmp("1.5.2", "1.6.0") == .orderedAscending)
check("2.0 > 1.99.99", cmp("2.0", "1.99.99") == .orderedDescending)

// MARK: JSON 解析
let okJSON = json(#"{"tag_name":"v1.7.0","html_url":"https://github.com/example/App/releases/tag/v1.7.0","draft":false}"#)
let r = AboutInfo.parseRelease(okJSON)
check("正常 JSON：取出 tag", r?.tag == "v1.7.0")
check("正常 JSON：取出 html_url", r?.url.absoluteString == "https://github.com/example/App/releases/tag/v1.7.0")
check("缺 tag_name → nil", AboutInfo.parseRelease(json(#"{"html_url":"https://github.com/example/App/releases/tag/v1"}"#)) == nil)
check("缺 html_url → nil", AboutInfo.parseRelease(json(#"{"tag_name":"v1.7.0"}"#)) == nil)
check("tag_name 型別錯誤 → nil", AboutInfo.parseRelease(json(#"{"tag_name":170,"html_url":"https://github.com/x/y"}"#)) == nil)
check("tag_name 空字串 → nil", AboutInfo.parseRelease(json(#"{"tag_name":"","html_url":"https://github.com/x/y"}"#)) == nil)
check("html_url 不是 GitHub → nil", AboutInfo.parseRelease(json(#"{"tag_name":"v9.0.0","html_url":"https://example.com/evil"}"#)) == nil)
check("html_url 是 http → nil", AboutInfo.parseRelease(json(#"{"tag_name":"v9.0.0","html_url":"http://github.com/x/y"}"#)) == nil)
check("不是 JSON → nil", AboutInfo.parseRelease(json("<html>rate limited</html>")) == nil)
check("JSON 是陣列 → nil", AboutInfo.parseRelease(json("[]")) == nil)

// MARK: 結果判斷
let url170 = URL(string: "https://github.com/example/App/releases/tag/v1.7.0")!
check("有新版：1.7.0 > 1.6.0", AboutInfo.evaluate(status: 200, data: okJSON, current: "1.6.0") == .newer(version: "1.7.0", url: url170))
check("有新版：1.10.0 > 1.9.0", AboutInfo.evaluate(status: 200,
      data: json(#"{"tag_name":"v1.10.0","html_url":"https://github.com/x/y/releases/tag/v1.10.0"}"#), current: "1.9.0")
      == .newer(version: "1.10.0", url: URL(string: "https://github.com/x/y/releases/tag/v1.10.0")!))
check("相同版本 → 已是最新", AboutInfo.evaluate(status: 200, data: okJSON, current: "1.7.0") == .upToDate(version: "1.7.0"))
check("相同版本（1.7 vs 1.7.0）→ 已是最新", AboutInfo.evaluate(status: 200, data: okJSON, current: "1.7") == .upToDate(version: "1.7"))
check("GitHub 上的較舊 → 已是最新，顯示目前版本", AboutInfo.evaluate(status: 200, data: okJSON, current: "1.8.0") == .upToDate(version: "1.8.0"))
func isFailed(_ o: AboutInfo.Outcome) -> Bool { if case .failed = o { return true }; return false }
check("無法解析的 tag → 失敗（不是有新版）", isFailed(AboutInfo.evaluate(status: 200,
      data: json(#"{"tag_name":"nightly","html_url":"https://github.com/x/y/releases/tag/nightly"}"#), current: "1.6.0")))
check("目前版本無法解析 → 失敗", isFailed(AboutInfo.evaluate(status: 200, data: okJSON, current: "dev")))
check("JSON 缺欄位 → 失敗", isFailed(AboutInfo.evaluate(status: 200, data: json(#"{"tag_name":"v2.0.0"}"#), current: "1.6.0")))
check("JSON 解析失敗 → 失敗", isFailed(AboutInfo.evaluate(status: 200, data: json("not json"), current: "1.6.0")))
check("沒有內容 → 失敗", isFailed(AboutInfo.evaluate(status: 200, data: nil, current: "1.6.0")))
check("網路錯誤 → 無法連線到 GitHub", AboutInfo.evaluate(status: nil, data: nil, current: "1.6.0") == .failed(AboutInfo.networkFailure)
      && AboutInfo.networkFailure.contains("無法連線到 GitHub"))
if case .failed(let m) = AboutInfo.evaluate(status: 403, data: okJSON, current: "1.6.0") {
    check("403（速率限制）→ 失敗並說明上限，即使內容看起來正常", m.contains("上限"))
} else { check("403（速率限制）→ 失敗並說明上限，即使內容看起來正常", false) }
check("404 → 失敗", isFailed(AboutInfo.evaluate(status: 404, data: nil, current: "1.6.0")))
if case .failed(let m) = AboutInfo.evaluate(status: 500, data: okJSON, current: "1.6.0") {
    check("500 → 失敗並帶 HTTP 狀態碼", m.contains("500"))
} else { check("500 → 失敗並帶 HTTP 狀態碼", false) }

// MARK: 版本字串
check("版本字串：版本 1.6.0（13）", AboutInfo.versionText(version: "1.6.0", build: "13") == "版本 1.6.0（13）")
check("拷貝內容格式", AboutInfo.copyText(app: "TestApp", version: "1.6.0", build: "13", macOS: "15.5", chip: "Apple M2")
      == "TestApp 1.6.0（13）· macOS 15.5 · Apple M2")
check("macOS 版本：數字與點", AboutInfo.macOSVersion.range(of: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil)
check("晶片：非空", !AboutInfo.chip.isEmpty)

// MARK: 連結（由 repoURL 一處推得）
check("owner／repo 由 repoURL 推得", AppInfo.repoOwner == AppInfo.repoURL.pathComponents[1] && AppInfo.repoName == AppInfo.repoURL.pathComponents[2]
      && !AppInfo.repoOwner.isEmpty && !AppInfo.repoName.isEmpty)
let base = AppInfo.repoURL.absoluteString
check("README 連結：專案頁 #readme", AppInfo.readmeURL.absoluteString == base + "#readme")
check("Releases 連結", AppInfo.releasesURL.absoluteString == base + "/releases")
check("授權連結：LICENSE 檔頁面", AppInfo.licenseURL.absoluteString == base + "/blob/main/LICENSE")
check("API：/repos/<owner>/<repo>/releases/latest", AppInfo.latestReleaseAPI.absoluteString
      == "https://api.github.com/repos/\(AppInfo.repoOwner)/\(AppInfo.repoName)/releases/latest")

print("通過 \(pass)，失敗 \(fail)")
