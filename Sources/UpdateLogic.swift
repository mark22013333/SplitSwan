// 一鍵更新的純邏輯：解析 GitHub release 的附檔、驗證 Ed25519 簽章、檢查下載的 App、
// 判斷每日自動檢查的時機。不連網、不碰檔案系統，方便單獨測試；實際動作在 UpdateCenter。
import CryptoKit
import Foundation

enum UpdateLogic {
    /// 發版簽章的公鑰（私鑰只在維護者電腦，見 tools/release-sign.swift）。換金鑰會讓舊版無法自動更新
    static let publicKeyBase64 = "URYq9rg4ntHqiWV0ZhSd6dMm1uLrL5fZ/J76pnX048g="

    /// dmg 大小上限，超過視為異常不下載
    static let maxDownloadBytes = 50_000_000

    /// 每日自動檢查的間隔
    static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    struct Assets: Equatable {
        var version: String   // 正規化後的版本號，例：1.6.1
        var dmg: URL
        var sig: URL
    }

    /// 從 /releases/latest 的 JSON 找出 `<App>-<版本>.dmg` 與 `.dmg.sig`。
    /// 下載網址必須是本 repo 的 releases/download 底下，否則一律不採用
    static func parseAssets(_ data: Data, appName: String, owner: String, repo: String) -> Assets? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let v = AboutInfo.parseVersion(tag),
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let version = v.map(String.init).joined(separator: ".")
        let prefix = "https://github.com/\(owner)/\(repo)/releases/download/"
        func url(named name: String) -> URL? {
            for a in assets where (a["name"] as? String) == name {
                guard let s = a["browser_download_url"] as? String, s.hasPrefix(prefix),
                      !s.contains(".."), let u = URL(string: s) else { return nil }
                return u
            }
            return nil
        }
        let dmgName = "\(appName)-\(version).dmg"
        guard let dmg = url(named: dmgName), let sig = url(named: dmgName + ".sig") else { return nil }
        return Assets(version: version, dmg: dmg, sig: sig)
    }

    /// `.sig` 的內容是一行 base64 簽章
    static func verify(data: Data, signatureText: String, publicKeyBase64: String = publicKeyBase64) -> Bool {
        guard let sig = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// 檢查 dmg 裡的 App：bundle id 要相同、版本要等於 release 的版本且比目前新（防止拿舊的已簽版本降級）。
    /// 回傳錯誤訊息，沒問題回 nil
    static func validateBundle(info: [String: Any], expectedID: String, expectedVersion: String, current: String) -> String? {
        guard let id = info["CFBundleIdentifier"] as? String, id == expectedID else {
            return "下載的 App 不是 \(expectedID)"
        }
        guard let raw = info["CFBundleShortVersionString"] as? String, let v = AboutInfo.parseVersion(raw),
              let want = AboutInfo.parseVersion(expectedVersion), let mine = AboutInfo.parseVersion(current) else {
            return "無法辨識下載的 App 版本"
        }
        guard AboutInfo.compare(v, want) == .orderedSame else { return "下載的 App 版本（\(raw)）與發布版本（\(expectedVersion)）不符" }
        guard AboutInfo.compare(v, mine) == .orderedDescending else { return "下載的版本（\(raw)）沒有比目前（\(current)）新" }
        return nil
    }

    /// 每日自動檢查：有勾選、且距離上次檢查超過 24 小時（或從沒檢查過、時鐘被往回調）
    static func shouldAutoCheck(enabled: Bool, last: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= autoCheckInterval || elapsed < 0
    }

    /// 只有放在可寫入的資料夾（通常是「應用程式」）裡才能自動更新；回傳不能更新的原因
    static func installBlocker(bundlePath: String, parentWritable: Bool) -> String? {
        guard bundlePath.hasSuffix(".app") else { return "目前不是從 App 執行" }
        if bundlePath.contains("/AppTranslocation/") || bundlePath.hasPrefix("/Volumes/") {
            return "請先把 App 拖進「應用程式」資料夾再更新"
        }
        guard parentWritable else { return "沒有權限寫入 App 所在的資料夾" }
        return nil
    }

    /// 等目前的程序結束後重新開啟 App 的指令（/bin/sh 參數；路徑與 PID 以參數傳入，不拼進指令字串）
    static func relaunchArguments(pid: Int32, appPath: String) -> [String] {
        ["-c", "for i in $(seq 1 150); do kill -0 \"$1\" 2>/dev/null || break; sleep 0.2; done; /usr/bin/open \"$2\"",
         "relaunch", String(pid), appPath]
    }
}
