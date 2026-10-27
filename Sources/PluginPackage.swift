import Foundation
import CryptoKit
import ZIPFoundation

/// 可分享的程式與本機私人狀態有不同的根目錄。這裡不執行任何套件程式。
enum PluginPackage {
    static let archiveLimit = 20 * 1024 * 1024
    static let expandedLimit = 100 * 1024 * 1024
    static let fileLimit = 20 * 1024 * 1024
    static let manifestLimit = 64 * 1024
    static let entryLimit = 1000
    static let runtimeDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    static let runtimes = ["sh", "bash", "zsh", "python3", "node"]
    struct Problem: LocalizedError { let failure: PluginFailure; let detail: String?; var errorDescription: String? { failure.text(detail) } }
    static func fail(_ failure: PluginFailure, _ detail: String? = nil) -> Problem { Problem(failure: failure, detail: detail) }
    struct File: Codable, Equatable, Sendable {
        let path: String
        let sha256: String
        let executable: Bool
    }
    struct LegacyReplacement: Codable, Equatable, Sendable {
        let fileName: String
        let sha256s: [String]
    }
    struct Manifest: Codable, Equatable, Sendable {
        let formatVersion: Int
        let id: String
        let name: String
        let author: String
        let description: String
        let version: String
        let minimumAppVersion: String
        let entrypoint: String
        let interval: Int
        let runtime: String
        let dependencies: [String]
        let settings: Bool
        let files: [File]
        let legacyReplacement: LegacyReplacement?
    }
    struct Version: Comparable {
        let core: [Int]
        let pre: [String]
        init?(_ text: String) {
            guard text.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#, options: .regularExpression) != nil else { return nil }
            let main = text.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)
            let values = main[0].split(separator: ".").compactMap { Int($0) }
            guard values.count == 3 else { return nil }
            core = values
            pre = main.count == 2 ? main[1].split(separator: ".").map(String.init) : []
            guard !pre.contains(where: { $0.allSatisfy(\.isNumber) && ($0.count > 1 && $0.first == "0" || Int($0) == nil) }) else { return nil }
        }
        static func < (a: Self, b: Self) -> Bool {
            if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
            if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }
            for (x, y) in zip(a.pre, b.pre) where x != y {
                if let xn = Int(x), let yn = Int(y) { return xn < yn }
                if Int(x) != nil { return true }; if Int(y) != nil { return false }
                return x < y
            }
            return a.pre.count < b.pre.count
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validID(_ s: String) -> Bool {
        s.count <= 120 && s.range(of: #"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$"#, options: .regularExpression) != nil
    }
    static func pathKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, PluginLogic.sanitize(path) == path, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(" ") && !$0.hasSuffix(".") }
    }
    static func sensitive(_ path: String) -> Bool {
        path.lowercased().split(separator: "/").contains { p in
            [".git", ".env", "company.env", "credentials.json", "token.json", "tokens.json", "client_secret.json", "id_rsa", "id_ed25519", "plugin-state", "node_modules", "__pycache__"].contains(String(p)) || p.hasPrefix(".env.") || p.hasSuffix(".pem") || p.hasSuffix(".key") || p.hasSuffix(".p12") || p.hasSuffix(".log")
        }
    }
    static func decode(_ data: Data, appVersion: String) throws -> Manifest {
        do { return try decodeValidated(data, appVersion: appVersion) }
        catch let problem as Problem { throw problem }
        catch { throw fail(.manifestInvalidJSON) }
    }
    private static func decodeValidated(_ data: Data, appVersion: String) throws -> Manifest {
        let required: Set<String> = ["formatVersion", "id", "name", "author", "description", "version", "minimumAppVersion", "entrypoint", "interval", "runtime", "dependencies", "settings", "files"]
        guard data.count <= manifestLimit, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(["legacyReplacement"])) else { throw fail(.manifestBadFields) }
        if let replacement = object["legacyReplacement"] {
            guard let fields = replacement as? [String: Any], Set(fields.keys) == ["fileName", "sha256s"] else { throw fail(.manifestLegacyDeclaration) }
        }
        guard let fileObjects = object["files"] as? [[String: Any]], fileObjects.allSatisfy({ Set($0.keys) == Set(["path", "sha256", "executable"]) }) else { throw fail(.manifestFileFields) }
        let m = try JSONDecoder().decode(Manifest.self, from: data)
        guard m.formatVersion == 1, validID(m.id), let v = Version(m.version), let min = Version(m.minimumAppVersion),
              let current = Version(appVersion), current >= min, v.core.count == 3 else { throw fail(.manifestUnsupportedVersion) }
        for s in [m.name, m.author, m.description] {
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.unicodeScalars.count <= 500,
                  PluginLogic.sanitize(s) == s else { throw fail(.manifestBadText) }
        }
        if let legacy = m.legacyReplacement {
            guard validPath(legacy.fileName), !legacy.fileName.contains("/"), !legacy.fileName.hasPrefix("."), !sensitive(legacy.fileName),
                  (1...20).contains(legacy.sha256s.count), Set(legacy.sha256s).count == legacy.sha256s.count,
                  legacy.sha256s.allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else { throw fail(.manifestLegacyList) }
        }
        guard (30...86400).contains(m.interval), runtimes.contains(m.runtime), m.dependencies.count <= 5,
              Set(m.dependencies).count == m.dependencies.count, m.dependencies.allSatisfy(runtimes.contains),
              !m.files.isEmpty, m.files.count < entryLimit else { throw fail(.manifestBadSettings) }
        var seen: Set<String> = ["manifest.json"]
        for f in m.files {
            guard validPath(f.path), !sensitive(f.path), seen.insert(pathKey(f.path)).inserted,
                  f.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw fail(.manifestBadFilePath) }
        }
        guard m.files.contains(where: { $0.path == m.entrypoint && $0.executable }) else { throw fail(.manifestEntrypointNotListed) }
        for f in m.files where m.files.contains(where: { pathKey($0.path).hasPrefix(pathKey(f.path) + "/") }) { throw fail(.manifestPathConflict, f.path) }
        return m
    }
    /// ZIPFoundation 會略過不支援的 entry；先完整讀中央目錄，不能以部分列舉當作驗證成功。
    static func zipPreflight(_ data: Data) throws -> [String: Int] {
        func u16(_ o: Int) throws -> Int { guard o >= 0, o + 2 <= data.count else { throw fail(.archiveCorrupt) }; return Int(data[o]) | Int(data[o+1]) << 8 }
        func u32(_ o: Int) throws -> Int { try u16(o) | u16(o+2) << 16 }
        guard data.count >= 22, data.count <= archiveLimit else { throw fail(.archiveBadSize) }
        var end: Int?
        for o in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try u32(o) == 0x06054b50, o + 22 + (try u16(o+20)) == data.count { end = o; break }
        }
        guard let e = end, try u16(e+4) == 0, try u16(e+6) == 0, try u16(e+8) == u16(e+10),
              (1...entryLimit).contains(try u16(e+10)) else { throw fail(.archiveUnsupported) }
        let count = try u16(e+10), size = try u32(e+12)
        var p = try u32(e+16)
        guard p + size == e else { throw fail(.archiveDirectoryIncomplete) }
        var result: [String: Int] = [:], keys: Set<String> = [], nodes: [String: Bool] = [:], total = 0
        for _ in 0..<count {
            guard try u32(p) == 0x02014b50 else { throw fail(.archiveDirectoryCorrupt) }
            let flags = try u16(p+8), method = try u16(p+10), length = try u16(p+28), extra = try u16(p+30), comment = try u16(p+32)
            let expanded = try u32(p+24), compressed = try u32(p+20), offset = try u32(p+42)
            let mode = try u32(p+38) >> 16, kind = mode & 0xf000
            guard try u16(p+6) <= 20, flags & 0x2041 == 0, [0,8].contains(method), try u16(p+34) == 0,
                  p + 46 + length + extra + comment <= e, expanded <= fileLimit, compressed <= archiveLimit,
                  [0,0x8000,0x4000].contains(kind),
                  let rawPath = String(data: data[(p+46)..<(p+46+length)], encoding: .utf8) else { throw fail(.archiveBadEntry) }
            var extraOffset = p + 46 + length
            let extraEnd = extraOffset + extra
            while extraOffset < extraEnd {
                guard extraOffset + 4 <= extraEnd, try u16(extraOffset) != 1 else { throw fail(.archiveZip64Extra) }
                extraOffset += 4 + (try u16(extraOffset+2))
                guard extraOffset <= extraEnd else { throw fail(.archiveExtraCorrupt) }
            }
            let isDir = rawPath.hasSuffix("/"), path = isDir ? String(rawPath.dropLast()) : rawPath
            guard validPath(path), !sensitive(path), keys.insert(pathKey(path)).inserted,
                  !(kind == 0x4000 && !isDir), !(kind == 0x8000 && isDir), !isDir || expanded == 0 else { throw fail(.archiveUnsafePath) }
            let components = path.split(separator: "/")
            for i in components.indices {
                let key = pathKey(components[...i].joined(separator: "/"))
                let directory = i < components.count - 1 || isDir
                if let previous = nodes[key], previous != directory { throw fail(.archivePathConflict) }
                nodes[key] = directory
                guard nodes.count <= entryLimit else { throw fail(.archiveTooManyEntries) }
            }
            guard try u32(offset) == 0x04034b50, try u16(offset+4) <= 20, try u16(offset+6) == flags, try u16(offset+8) == method,
                  try u16(offset+26) == length else { throw fail(.archiveHeaderMismatch) }
            let start = offset + 30, body = start + length + (try u16(offset+28))
            guard offset >= 0, body + compressed <= (try u32(e+16)), start + length <= data.count,
                  data[start..<(start+length)] == data[(p+46)..<(p+46+length)] else { throw fail(.archiveLocalHeader) }
            total += expanded
            guard total <= expandedLimit else { throw fail(.archiveExpandedTooLarge) }
            result[rawPath] = expanded
            p += 46 + length + extra + comment
        }
        guard p == e else { throw fail(.archiveCountMismatch) }
        return result
    }
    /// 安裝包被系統當成一般 zip 解開再壓回去時，會多一層資料夾或 AppleDouble（._）檔。
    /// 合法套件也可宣告 ._ 檔，所以只在驗證已失敗時用來說明原因。
    static func repackedFailure<S: Sequence>(_ paths: S) -> PluginFailure? where S.Element == String {
        let paths = Array(paths)
        let nested = !paths.contains("manifest.json") && paths.contains { $0.split(separator: "/").count == 2 && $0.hasSuffix("/manifest.json") }
        let appleDouble = paths.contains { $0.split(separator: "/").contains { $0.hasPrefix("._") || $0 == "__MACOSX" } }
        guard nested || appleDouble else { return nil }
        return .archiveRepacked
    }
    struct Prepared: Sendable {
        let staging: URL
        let payload: URL
        let archive: URL
        let manifest: Manifest
        let digest: String
        let quarantine: Data?
        var missingDependencies: [String] { PluginPackage.missingDependencies(manifest) }
        func discard() { try? FileManager.default.removeItem(at: staging) }
    }
    static func missingDependencies(_ m: Manifest, directories: [String] = runtimeDirectories) -> [String] {
        Array(Set([m.runtime] + m.dependencies)).sorted().filter { name in
            !directories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
        }
    }
    static func prepare(_ source: URL, appVersion: String) throws -> Prepared {
        let fm = FileManager.default, staging = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("splitswan-package-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let archiveURL = staging.appendingPathComponent("source.zip"), payload = staging.appendingPathComponent("payload")
            let attrs = try fm.attributesOfItem(atPath: source.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? Int ?? Int.max) <= archiveLimit else { throw fail(.packageSourceInvalid) }
            let sourceQuarantine = readQuarantine(source.path)
            if PluginRunner.hasQuarantine(source.path), sourceQuarantine == nil { throw fail(.packageQuarantineRead) }
            let data = try PluginPackageStore.boundedRead(source, limit: archiveLimit)
            try data.write(to: archiveURL, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
            if let q = sourceQuarantine {
                let result = q.withUnsafeBytes { setxattr(archiveURL.path, "com.apple.quarantine", $0.baseAddress, q.count, 0, 0) }
                guard result == 0 else { throw fail(.packageQuarantineKeep) }
            }
            let expected = try zipPreflight(data)
            let archive = try Archive(url: archiveURL, accessMode: .read)
            let entries = Array(archive)
            guard entries.count == expected.count else { throw fail(.archiveEnumerationIncomplete, "預期 \(expected.count) 項，實際 \(entries.count) 項") }
            // 預檢已驗證原始檔名是 UTF-8；不要再次依 ZIP 旗標改用系統 CP437 解碼。
            guard let manifestEntry = entries.first(where: { $0.path(using: .utf8) == "manifest.json" }), manifestEntry.type == .file else {
                throw fail(repackedFailure(expected.keys) ?? .manifestMissingRoot)
            }
            guard manifestEntry.uncompressedSize <= manifestLimit else { throw fail(.manifestTooLarge) }
            func extract(_ entry: Entry) throws -> Data {
                let path = entry.path(using: .utf8)
                var content = Data()
                let crc = try archive.extract(entry, bufferSize: 32768) { chunk in
                    guard content.count + chunk.count <= (expected[path] ?? 0) else { throw fail(.archiveSizeExceeded) }
                    content.append(chunk)
                }
                guard content.count == expected[path], crc == entry.checksum else { throw fail(.archiveCRCMismatch) }
                return content
            }
            let manifestData = try extract(manifestEntry), manifest = try decode(manifestData, appVersion: appVersion)
            let files = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
            try fm.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for entry in entries {
                let path = entry.path(using: .utf8)
                guard let expectedSize = expected[path], entry.uncompressedSize == UInt64(expectedSize) else { throw fail(.archivePathMismatch) }
                if entry.type == .directory {
                    guard files.keys.contains(where: { $0.hasPrefix(path) }) else { throw fail(.archiveUndeclaredFolder) }
                    continue
                }
                guard entry.type == .file, path == "manifest.json" || files[path] != nil else { throw fail(repackedFailure(expected.keys) ?? .archiveUndeclaredFile) }
                let content = path == "manifest.json" ? manifestData : try extract(entry)
                if let f = files[path], hash(content) != f.sha256 { throw fail(.archiveHashMismatch, path) }
                let target = payload.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try content.write(to: target, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: files[path]?.executable == true ? 0o700 : 0o600], ofItemAtPath: target.path)
            }
            guard files.keys.allSatisfy({ expected[$0] != nil }) else { throw fail(.archiveMissingFile) }
            try validateEntrypoint(manifest, root: payload)
            let quarantine = readQuarantine(archiveURL.path)
            return Prepared(staging: staging, payload: payload, archive: archiveURL, manifest: manifest, digest: hash(manifestData), quarantine: quarantine)
        } catch { try? fm.removeItem(at: staging); throw error }
    }
    static func validateEntrypoint(_ m: Manifest, root: URL) throws {
        let file = try FileHandle(forReadingFrom: root.appendingPathComponent(m.entrypoint)); defer { try? file.close() }
        let line = String(data: try file.read(upToCount: 512) ?? Data(), encoding: .utf8)?.components(separatedBy: "\n").first ?? ""
        let allowed = ["#!/usr/bin/env " + m.runtime, "#!/bin/" + m.runtime, "#!/usr/bin/" + m.runtime]
        guard allowed.contains(line) else { throw fail(.manifestBadShebang) }
    }
    static func readQuarantine(_ path: String) -> Data? {
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size >= 0, size <= 4096 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, "com.apple.quarantine", $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }
}
