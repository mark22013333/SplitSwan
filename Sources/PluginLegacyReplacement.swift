import Foundation

/// 只處理 App 管理的入口與收據；不執行外掛、不讀取其帳密，也不猜測獨立服務。
enum PluginLegacyReplacement {
    struct Match: Equatable, Sendable {
        let fileName: String
        let sha256: String
        let enabled: Bool
    }
    struct Receipt: Codable {
        let version: Int
        let packageID: String
        let fileName: String
        let sha256: String
        let backup: String
    }
    static let receiptName = ".legacy-replacement.json"
    static func inspect(_ manifest: PluginPackage.Manifest, directory: URL, enabled: Bool) throws -> Match? {
        guard let legacy = manifest.legacyReplacement else { return nil }
        let url = directory.appendingPathComponent(legacy.fileName)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw PluginPackage.fail("無法檢查舊腳本")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw PluginPackage.fail("舊腳本必須是一般檔案，不能是連結") }
        let check = PluginRunner.fullCheck(path: url.path, pluginDir: directory.path, uid: getuid())
        guard check.problem == nil else { throw PluginPackage.fail(check.problem!) }
        let hash = PluginPackage.hash(try PluginPackageStore.boundedRead(url, limit: PluginPackage.fileLimit))
        guard legacy.sha256s.contains(hash) else { throw PluginPackage.fail("找到同名舊腳本，但內容不符合開發者宣告的版本，未取代任何檔案") }
        return Match(fileName: legacy.fileName, sha256: hash, enabled: enabled)
    }
    /// 原子移開入口後才切換套件；失敗恢復收據、登錄與入口。獨立後端資料原地保留。
    static func commit(_ prepared: PluginPackage.Prepared, match: Match, store: PluginPackageStore, directory: URL, stateRoot: URL) throws -> URL {
        guard try inspect(prepared.manifest, directory: directory, enabled: match.enabled) == match else { throw PluginPackage.fail("舊腳本已變更，請重新匯入安裝包") }
        let fm = FileManager.default
        let id = prepared.manifest.id
        let active = store.root.appendingPathComponent(id + "/active.json")
        let previous = fm.fileExists(atPath: active.path) ? try store.read(id) : nil
        let state = stateRoot.appendingPathComponent("packages/" + id)
        try PluginPackageStore.createSecureDirectory(state)
        let receipt = state.appendingPathComponent(receiptName)
        var oldReceipt: Data?
        if fm.fileExists(atPath: receipt.path) {
            try PluginPackageStore.securePath(receipt.path, regular: true)
            oldReceipt = try PluginPackageStore.boundedRead(receipt, limit: PluginPackage.manifestLimit)
        }
        let backupRoot = directory.appendingPathComponent(".splitswan-backups/" + UUID().uuidString)
        try PluginPackageStore.createSecureDirectory(backupRoot)
        let source = directory.appendingPathComponent(match.fileName)
        let backup = backupRoot.appendingPathComponent(match.fileName)
        guard rename(source.path, backup.path) == 0 else { throw PluginPackage.fail("無法備份舊腳本；尚未安裝或取代") }
        var installAttempted = false
        var receiptWritten = false
        do {
            // 移動後再驗證一次，避免等待背景工作時或 rename 前內容被換掉。
            try PluginPackageStore.securePath(backup.path, regular: true)
            guard PluginPackage.hash(try PluginPackageStore.boundedRead(backup, limit: PluginPackage.fileLimit)) == match.sha256 else { throw PluginPackage.fail("舊腳本內容已變更，取消升級") }
            let record = Receipt(version: 1, packageID: id, fileName: match.fileName, sha256: match.sha256, backup: backup.path)
            try write(try JSONEncoder().encode(record), to: receipt)
            receiptWritten = true
            installAttempted = true
            try store.install(prepared, confirmed: true, pruneOldVersions: false)
            try store.setEnabled(id, match.enabled)
            return backup
        } catch {
            var failures: [String] = []
            if installAttempted { do { try store.restore(previous, id: id) } catch { failures.append(error.localizedDescription) } }
            if receiptWritten {
                do {
                    if let oldReceipt { try write(oldReceipt, to: receipt) }
                    else if fm.fileExists(atPath: receipt.path) { try fm.removeItem(at: receipt) }
                } catch { failures.append(error.localizedDescription) }
            }
            var current = stat()
            if lstat(source.path, &current) == 0 || errno != ENOENT || rename(backup.path, source.path) != 0 {
                failures.append("舊入口無法恢復，未覆寫其他程序新建的檔案")
            } else { try? fm.removeItem(at: backupRoot) }
            if !failures.isEmpty { throw PluginPackage.fail("升級與復原未完成，請保留備份 \(backup.path)：\(failures.joined(separator: "；"))") }
            throw error
        }
    }
    private static func write(_ data: Data, to target: URL) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".receipt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, target.path) == 0 else { throw PluginPackage.fail("無法寫入升級收據") }
    }
}
