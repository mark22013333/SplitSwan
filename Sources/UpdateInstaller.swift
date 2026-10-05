// 一鍵更新的實際動作：下載、驗證簽章、掛載 dmg 檢查 App、複製、替換。不依賴 UI，測試可直接呼叫 stage／swap
import Foundation

enum UpdateInstaller {
    struct UpdateError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
        init(_ m: String) { message = m }
    }

    /// 下載、驗證並把新版 App 複製到暫存資料夾，回傳暫存的 .app
    static func prepare(bundleID: String, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 30
            c.timeoutIntervalForResource = 300
            return c
        }())
        defer { session.finishTasksAndInvalidate() }

        func get(_ url: URL, accept: String? = nil) async throws -> Data {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            req.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
            if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
            let (data, resp): (Data, URLResponse)
            do { (data, resp) = try await session.data(for: req) } catch { throw UpdateError(AboutInfo.networkFailure) }
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("下載失敗（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）")
            }
            guard data.count <= UpdateLogic.maxDownloadBytes else { throw UpdateError("下載的檔案大小異常，已停止") }
            return data
        }

        let json = try await get(AppInfo.latestReleaseAPI, accept: "application/vnd.github+json")
        guard let assets = UpdateLogic.parseAssets(json, appName: AppInfo.name, owner: AppInfo.repoOwner, repo: AppInfo.repoName) else {
            throw UpdateError("最新版本沒有附上可自動安裝的檔案，請按「前往下載」手動更新")
        }
        guard let want = AboutInfo.parseVersion(assets.version), let mine = AboutInfo.parseVersion(AppInfo.version),
              AboutInfo.compare(want, mine) == .orderedDescending else {
            throw UpdateError("目前已是最新版本")
        }
        progress("下載 \(assets.version)…")
        let dmg = try await get(assets.dmg)
        let sig = try await get(assets.sig)
        progress("驗證簽章…")
        guard UpdateLogic.verify(data: dmg, signatureText: String(decoding: sig, as: UTF8.self)) else {
            throw UpdateError("簽章驗證失敗，已停止安裝。請到 GitHub 確認發布內容")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppInfo.name)-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmgURL = work.appendingPathComponent("update.dmg")
        try dmg.write(to: dmgURL)
        progress("檢查安裝檔…")
        return try await stage(dmg: dmgURL, work: work, bundleID: bundleID, expectedVersion: assets.version, current: AppInfo.version)
    }

    /// 掛載 dmg、檢查裡面的 App、複製到 work/ 並驗證程式碼簽章。測試也會直接呼叫
    static func stage(dmg: URL, work: URL, bundleID: String, expectedVersion: String, current: String) async throws -> URL {
        let mnt = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let attach = await ProcessRunner.runLimited("/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mnt.path, dmg.path], timeout: 60)
        guard attach.code == 0 else { throw UpdateError("無法開啟安裝檔（hdiutil \(attach.code)）") }
        var detached = false
        func detach() async {
            guard !detached else { return }
            detached = true
            let r = await ProcessRunner.runLimited("/usr/bin/hdiutil", ["detach", mnt.path, "-quiet"], timeout: 30)
            if r.code != 0 { _ = await ProcessRunner.runLimited("/usr/bin/hdiutil", ["detach", mnt.path, "-force", "-quiet"], timeout: 30) }
        }
        do {
            let appName = (try FileManager.default.contentsOfDirectory(atPath: mnt.path)).filter { $0.hasSuffix(".app") }
            guard appName.count == 1 else { throw UpdateError("安裝檔內容異常（找不到唯一的 App）") }
            let src = mnt.appendingPathComponent(appName[0])
            guard let info = NSDictionary(contentsOf: src.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
                throw UpdateError("讀不到安裝檔內 App 的資訊")
            }
            if let why = UpdateLogic.validateBundle(info: info, expectedID: bundleID, expectedVersion: expectedVersion, current: current) {
                throw UpdateError(why)
            }
            let staged = work.appendingPathComponent(appName[0])
            let copy = await ProcessRunner.runLimited("/usr/bin/ditto", [src.path, staged.path], timeout: 120)
            guard copy.code == 0 else { throw UpdateError("複製新版 App 失敗") }
            await detach()
            let cs = await ProcessRunner.runLimited("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], timeout: 60)
            guard cs.code == 0 else { throw UpdateError("新版 App 的程式碼簽章驗證失敗") }
            _ = await ProcessRunner.runLimited("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path], timeout: 30)
            return staged
        } catch {
            await detach()
            throw error
        }
    }

    /// 把 target 換成 staged：舊版先移到暫存資料夾（失敗時搬回），不直接刪除
    static func swap(target: URL, with staged: URL) throws {
        let fm = FileManager.default
        let backup = staged.deletingLastPathComponent().appendingPathComponent("previous-\(target.lastPathComponent)")
        do { try fm.moveItem(at: target, to: backup) } catch {
            throw UpdateError("無法移動目前的 App：\(error.localizedDescription)")
        }
        do { try fm.moveItem(at: staged, to: target) } catch {
            try? fm.moveItem(at: backup, to: target)
            throw UpdateError("無法放入新版 App，已還原：\(error.localizedDescription)")
        }
    }
}
