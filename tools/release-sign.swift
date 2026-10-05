// 發版用：以 Ed25519 簽署 dmg，App 的「下載並安裝」會用內建公鑰驗證簽章後才安裝。
//   swift tools/release-sign.swift keygen            產生金鑰（只需一次），印出要寫進 UpdateLogic.publicKeyBase64 的公鑰
//   swift tools/release-sign.swift sign <檔案>        產生 <檔案>.sig（base64，一行）
//   swift tools/release-sign.swift verify <檔案>      用私鑰推得的公鑰驗證 <檔案>.sig
//   swift tools/release-sign.swift pubkey            印出公鑰
// 私鑰放在 ~/.config/splitswan-release/update-ed25519.key（600），**不可放進 repo**。
// 私鑰遺失就無法再發出可自動安裝的更新：請另外備份（例如密碼管理器）。
import CryptoKit
import Foundation

let keyDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/splitswan-release")
let keyPath = keyDir.appendingPathComponent("update-ed25519.key")

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("讀不到私鑰：\(keyPath.path)（先執行 keygen，或從備份還原）")
    }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    if FileManager.default.fileExists(atPath: keyPath.path) {
        fail("私鑰已存在：\(keyPath.path)，不覆蓋。換金鑰會讓舊版 App 無法驗證新版，請三思")
    }
    try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    let ok = FileManager.default.createFile(atPath: keyPath.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                            attributes: [.posixPermissions: 0o600])
    guard ok else { fail("無法寫入 \(keyPath.path)") }
    print("已產生私鑰：\(keyPath.path)（600），請另外備份")
    print("公鑰：\(key.publicKey.rawRepresentation.base64EncodedString())")
case "pubkey":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let file = args.dropFirst().first else { fail("用法：sign <檔案>") }
    guard let data = FileManager.default.contents(atPath: file) else { fail("讀不到 \(file)") }
    let sig = try loadKey().signature(for: data)
    let out = file + ".sig"
    guard FileManager.default.createFile(atPath: out, contents: Data((sig.base64EncodedString() + "\n").utf8)) else {
        fail("無法寫入 \(out)")
    }
    print("已簽署：\(out)")
case "verify":
    guard let file = args.dropFirst().first else { fail("用法：verify <檔案>") }
    guard let data = FileManager.default.contents(atPath: file),
          let sigText = try? String(contentsOfFile: file + ".sig", encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("讀不到 \(file) 或 \(file).sig")
    }
    if loadKey().publicKey.isValidSignature(sig, for: data) { print("簽章正確：\(file)") } else { fail("簽章不符：\(file)") }
default:
    fail("用法：swift tools/release-sign.swift keygen|pubkey|sign <檔案>|verify <檔案>")
}
