import Foundation

/// Registry 的原子替換是唯一的版本啟用點；安裝過程不碰私人狀態目錄。
struct PluginPackageStore: Sendable {
    let root: URL
    let appVersion: String
    let runtimeDirectories: [String]
    init(root: URL, appVersion: String, runtimeDirectories: [String] = PluginPackage.runtimeDirectories) {
        self.root = root; self.appVersion = appVersion; self.runtimeDirectories = runtimeDirectories
    }
    struct Record: Codable, Equatable, Sendable {
        let digest: String
        let previous: String?
        let manifest: PluginPackage.Manifest
        var enabled: Bool
        let trusted: Bool
    }
    struct Installed: Equatable, Sendable {
        let store: PluginPackageStore
        let record: Record
        var id: String { "package:" + record.manifest.id }
        var root: URL { store.root.appendingPathComponent(record.manifest.id + "/versions/" + record.digest + "/payload") }
        var entrypoint: String { root.appendingPathComponent(record.manifest.entrypoint).path }
        func availability() throws {
            guard record.trusted, PluginPackage.validID(record.manifest.id),
                  record.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw PluginPackage.fail(.storeUntrusted) }
            // 每次執行重讀 active，排隊的舊版本不能在更新後開始。
            guard try store.read(record.manifest.id).digest == record.digest else { throw PluginPackage.fail(.storeVersionChanged) }
            try PluginPackageStore.securePath(entrypoint, regular: true)
            let missing = PluginPackage.missingDependencies(record.manifest, directories: store.runtimeDirectories)
            guard missing.isEmpty else { throw PluginPackage.fail(.storeMissingRuntime, missing.joined(separator: "、")) }
        }
        func check() throws {
            try availability()
            try store.verifyTree(self)
        }
        var environment: [String: String] {
            ["SPLITSWAN_PLUGIN_ID": record.manifest.id, "SPLITSWAN_PLUGIN_VERSION": record.manifest.version,
             "SPLITSWAN_PLUGIN_ROOT": root.path, "SPLITSWAN_PLUGIN_PACKAGE_FORMAT": "1"]
        }
    }
    static func == (a: Self, b: Self) -> Bool { a.root == b.root && a.appVersion == b.appVersion && a.runtimeDirectories == b.runtimeDirectories }
    private func base(_ id: String) -> URL { root.appendingPathComponent(id) }
    func read(_ id: String) throws -> Record {
        guard PluginPackage.validID(id) else { throw PluginPackage.fail(.storeInvalidID) }
        let url = base(id).appendingPathComponent("active.json")
        try Self.securePath(url.path, regular: true)
        let data = try Self.boundedRead(url, limit: PluginPackage.manifestLimit * 2)
        guard data.count <= PluginPackage.manifestLimit * 2 else { throw PluginPackage.fail(.storeRecordTooLarge) }
        let r = try JSONDecoder().decode(Record.self, from: data)
        guard r.manifest.id == id else { throw PluginPackage.fail(.storeRecordIDMismatch) }
        _ = try PluginPackage.decode(JSONEncoder().encode(r.manifest), appVersion: appVersion)
        return r
    }
    func discover() -> (installed: [Installed], errors: [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return ([], []) }
        var installed: [Installed] = [], errors: [String] = []
        for id in names.sorted() where !id.hasPrefix(".") {
            do { installed.append(Installed(store: self, record: try read(id))) }
            catch { errors.append(PluginLogic.clip(PluginLogic.sanitize(id)) + "：" + error.localizedDescription) }
        }
        return (installed, errors)
    }
    enum Change: Equatable { case install, update(String), identical }
    func change(for p: PluginPackage.Prepared) throws -> Change {
        let active = base(p.manifest.id).appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: active.path) else { return .install }
        let old = try read(p.manifest.id)
        if old.digest == p.digest { return .identical }
        guard let before = PluginPackage.Version(old.manifest.version), let after = PluginPackage.Version(p.manifest.version), after > before else {
            throw PluginPackage.fail(.storeVersionNotNewer)
        }
        return .update(old.manifest.version)
    }
    /// 必須由 UI 確認內容後呼叫；不將「具有雜湊」當作信任來源。
    func install(_ p: PluginPackage.Prepared, confirmed: Bool, pruneOldVersions: Bool = true) throws {
        guard confirmed else { throw PluginPackage.fail(.storeNotConfirmed) }
        let change = try change(for: p)
        if change == .identical {
            try verifyTree(Installed(store: self, record: read(p.manifest.id)))
            return
        }
        let fm = FileManager.default
        try Self.createSecureDirectory(root)
        try Self.createSecureDirectory(base(p.manifest.id))
        let versions = base(p.manifest.id).appendingPathComponent("versions")
        try Self.createSecureDirectory(versions)
        let old = change == .install ? nil : try read(p.manifest.id)
        let destination = versions.appendingPathComponent(p.digest)
        let candidate = versions.appendingPathComponent(".incoming-" + UUID().uuidString)
        try Self.createSecureDirectory(candidate)
        defer { try? fm.removeItem(at: candidate) }
        try fm.copyItem(at: p.payload, to: candidate.appendingPathComponent("payload"))
        try fm.copyItem(at: p.archive, to: candidate.appendingPathComponent("source.zip"))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.appendingPathComponent("source.zip").path)
        // 保留下載來源隔離資訊；信任僅作用於已確認 digest，不移除 xattr。
        if let q = p.quarantine {
            try q.write(to: candidate.appendingPathComponent("quarantine.data"))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.appendingPathComponent("quarantine.data").path)
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: candidate, to: destination)
        let record = Record(digest: p.digest, previous: old?.digest, manifest: p.manifest, enabled: old?.enabled ?? false, trusted: true)
        let installed = Installed(store: self, record: record)
        try verifyTree(installed)
        try write(record)
        // 成功啟用後才回收更舊的版本。上一版與目前版本都保留。
        for name in (try? fm.contentsOfDirectory(atPath: versions.path)) ?? [] where pruneOldVersions && name != record.digest && name != record.previous {
            try? fm.removeItem(at: versions.appendingPathComponent(name))
        }
    }
    /// 升級交易失敗時還原登錄；安裝階段保留所有舊版本，避免復原點被清除。
    func restore(_ record: Record?, id: String) throws {
        guard PluginPackage.validID(id), record == nil || record?.manifest.id == id else { throw PluginPackage.fail(.storeInvalidRollbackID) }
        if let record { try write(record) }
        else if FileManager.default.fileExists(atPath: base(id).path) { try FileManager.default.removeItem(at: base(id)) }
    }
    func setEnabled(_ id: String, _ enabled: Bool) throws {
        var r = try read(id)
        if enabled { try Installed(store: self, record: r).check() }
        r.enabled = enabled
        try write(r)
    }
    typealias TrashOperation = @Sendable (URL) throws -> Void
    static let moveToTrash: TrashOperation = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    /// 只移除同一份安裝內容；私人狀態與鑰匙圈不在套件管理目錄內。
    func remove(_ installed: Installed, trash: TrashOperation = Self.moveToTrash) throws {
        guard installed.store == self,
              try read(installed.record.manifest.id).digest == installed.record.digest else {
            throw PluginPackage.fail(.storeRemoveChanged)
        }
        let target = base(installed.record.manifest.id)
        try Self.securePath(target.path, regular: false)
        // 不要求 payload 完整，損壞的套件也必須能移除；移動本身不跟隨內容中的連結。
        try trash(target)
    }
    private func write(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        let url = base(record.manifest.id).appendingPathComponent("active.json")
        try Self.securePath(url.deletingLastPathComponent().path, regular: false)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".active-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw PluginPackage.fail(.storeActivateFailed) }
    }
    func verifyTree(_ p: Installed) throws {
        let fm = FileManager.default
        try Self.securePath(p.root.path, regular: false)
        let manifestURL = p.root.appendingPathComponent("manifest.json")
        try Self.securePath(manifestURL.path, regular: true)
        let manifestData = try Self.boundedRead(manifestURL, limit: PluginPackage.manifestLimit)
        guard PluginPackage.hash(manifestData) == p.record.digest,
              try PluginPackage.decode(manifestData, appVersion: appVersion) == p.record.manifest else { throw PluginPackage.fail(.storeManifestChanged) }
        guard let physicalRoot = PluginRunner.realPath(p.root.path) else { throw PluginPackage.fail(.storeRootMissing) }
        var actual: Set<String> = []
        guard let enumerator = fm.enumerator(at: p.root, includingPropertiesForKeys: nil, options: []) else { throw PluginPackage.fail(.storeUnreadable) }
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= PluginPackage.entryLimit else { throw PluginPackage.fail(.storeTooManyItems) }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
            try Self.securePath(url.path, regular: !isDir)
            if !isDir {
                guard let physical = PluginRunner.realPath(url.path), physical.hasPrefix(physicalRoot + "/") else { throw PluginPackage.fail(.storeEscapesRoot) }
                actual.insert(String(physical.dropFirst(physicalRoot.count + 1)))
            }
        }
        guard actual == Set(["manifest.json"] + p.record.manifest.files.map(\.path)) else { throw PluginPackage.fail(.storeFileSetChanged) }
        var total = manifestData.count
        for f in p.record.manifest.files {
            let url = p.root.appendingPathComponent(f.path)
            let content = try Self.boundedRead(url, limit: PluginPackage.fileLimit)
            total += content.count
            guard total <= PluginPackage.expandedLimit, PluginPackage.hash(content) == f.sha256,
                  !f.executable || access(url.path, X_OK) == 0 else { throw PluginPackage.fail(.storeContentChanged, f.path) }
        }
        try PluginPackage.validateEntrypoint(p.record.manifest, root: p.root)
    }
    func export(_ installed: Installed, to destination: URL) throws {
        let output = destination.resolvingSymlinksInPath().path
        guard output != root.path, !output.hasPrefix(root.path + "/") else { throw PluginPackage.fail(.storeExportInsideRoot) }
        try verifyTree(installed)
        let source = installed.root.deletingLastPathComponent().appendingPathComponent("source.zip")
        try Self.securePath(source.path, regular: true)
        // 原始 ZIP 也重新驗證；不能只驗證 payload 後匯出遭替換的備份。
        let prepared = try PluginPackage.prepare(source, appVersion: appVersion)
        defer { prepared.discard() }
        guard prepared.digest == installed.record.digest else { throw PluginPackage.fail(.storeExportSourceChanged) }
        let data = try Self.boundedRead(source, limit: PluginPackage.archiveLimit)
        let quarantine = PluginPackage.readQuarantine(source.path) ?? PluginPackage.readQuarantine(destination.path)
        if PluginRunner.hasQuarantine(source.path), quarantine == nil { throw PluginPackage.fail(.packageQuarantineRead) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".splitswan-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if let quarantine {
            let result = quarantine.withUnsafeBytes { setxattr(temporary.path, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, 0) }
            guard result == 0 else { throw PluginPackage.fail(.storeExportQuarantine) }
        }
        guard rename(temporary.path, destination.path) == 0 else { throw PluginPackage.fail(.storeExportWriteFailed) }
    }
    static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.size] as? Int ?? Int.max) <= limit else { throw PluginPackage.fail(.storeFileTooLarge) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(32768, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw PluginPackage.fail(.storeFileTooLarge) }
        }
        return data
    }
    /// lstat 每一層，避免中間資料夾或檔案以 symlink 偷換根目錄。
    static func securePath(_ path: String, regular: Bool) throws {
        var d = path, first = true
        while true {
            var st = stat()
            // Foundation 在 macOS 可能將 /private/var 正規化為 /var。
            // 僅允許系統固定、root 擁有的別名；套件內與自訂路徑的連結仍一律拒絕。
            if !first, let canonical = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"][d],
               lstat(d, &st) == 0, st.st_uid == 0, (st.st_mode & S_IFMT) == S_IFLNK,
               PluginRunner.realPath(d) == canonical {
                d = canonical
                continue
            }
            guard lstat(d, &st) == 0, (st.st_mode & S_IFMT) == (first && regular ? S_IFREG : S_IFDIR),
                  st.st_uid == getuid() || ((!first || !regular) && st.st_uid == 0),
                  (st.st_mode & 0o022) == 0 || (!first && (st.st_mode & S_ISVTX) != 0),
                  PluginRunner.aclProblem(d, uid: getuid()) == nil else { throw PluginPackage.fail(.storeUnsafePath, d) }
            if d == "/" { break }
            first = false; d = (d as NSString).deletingLastPathComponent
        }
    }
    static func createSecureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try createSecureDirectory(url.deletingLastPathComponent())
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try securePath(url.path, regular: false)
    }
}
extension PluginPackageStore: Equatable {}
