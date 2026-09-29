// 加密設定檔的匯出與匯入（.splitswan）
//
// 內容：公司設定（名稱、閘道、通道網段）＋預設共享金鑰（PSK）。**不含**個人帳號密碼。
// 加密：AES-256-GCM；金鑰由使用者自訂的密碼經 PBKDF2-HMAC-SHA256（600,000 次）衍生。
//       每次匯出都用新的隨機 salt 與 nonce；檔頭（格式、版本、KDF 參數）做為 AAD，被竄改就解不開。
// 檔案格式（JSON）：
//   { "format": "splitswan-config", "version": 1, "kdf": "PBKDF2-HMAC-SHA256",
//     "iterations": 600000, "salt": "<base64>", "sealed": "<base64：nonce＋密文＋tag>" }
import Foundation
import CryptoKit
import CommonCrypto
import Security

struct ExportPayload: Codable, Equatable {
    var name: String
    var gateways: [String]
    var remoteTS: String
    var psk: String?
}

enum ConfigExport {
    static let format = "splitswan-config"
    static let version = 1
    static let iterations: UInt32 = 600_000
    static let minPassphraseLength = 8
    static let fileExtension = "splitswan"

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: UInt32
        var salt: String
        var sealed: String
    }

    enum ExportError: LocalizedError {
        case weakPassphrase, notEncryptedFile, unsupportedVersion(Int), wrongPassphraseOrTampered, keyDerivationFailed
        var errorDescription: String? {
            switch self {
            case .weakPassphrase: return "密碼至少要 \(ConfigExport.minPassphraseLength) 個字元"
            case .notEncryptedFile: return "這不是 SplitSwan 的加密設定檔"
            case .unsupportedVersion(let v): return "設定檔版本 \(v) 不支援，請更新 App"
            case .wrongPassphraseOrTampered: return "密碼錯誤，或檔案已損毀／被修改"
            case .keyDerivationFailed: return "產生金鑰失敗"
            }
        }
    }

    // MARK: 加密／解密（純函式，方便測試）

    static func encrypt(_ payload: ExportPayload, passphrase: String, iterations: UInt32 = iterations) throws -> Data {
        guard passphrase.count >= minPassphraseLength else { throw ExportError.weakPassphrase }
        let salt = randomBytes(16)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        var env = Envelope(format: format, version: version, kdf: "PBKDF2-HMAC-SHA256",
                           iterations: iterations, salt: salt.base64EncodedString(), sealed: "")
        let plain = try JSONEncoder().encode(payload)
        let box = try AES.GCM.seal(plain, using: key, authenticating: aad(env))
        guard let combined = box.combined else { throw ExportError.keyDerivationFailed }
        env.sealed = combined.base64EncodedString()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(env)
    }

    static func decrypt(_ data: Data, passphrase: String) throws -> ExportPayload {
        guard data.count <= 1_000_000,
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.format == format else {
            throw ExportError.notEncryptedFile
        }
        guard env.version == version else { throw ExportError.unsupportedVersion(env.version) }
        // 限制 KDF 次數範圍，避免被惡意檔案拖慢（次數過大）或降級（次數過小）
        guard env.kdf == "PBKDF2-HMAC-SHA256", (100_000...2_000_000).contains(env.iterations),
              let salt = Data(base64Encoded: env.salt), (16...64).contains(salt.count),
              let sealed = Data(base64Encoded: env.sealed), (28...64_000).contains(sealed.count)
        else { throw ExportError.notEncryptedFile }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: env.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plain = try AES.GCM.open(box, using: key, authenticating: aad(env))
            return try JSONDecoder().decode(ExportPayload.self, from: plain)
        } catch {
            throw ExportError.wrongPassphraseOrTampered
        }
    }

    /// 檔案內容看起來是不是加密設定檔（用來決定匯入時要不要問密碼）
    static func isEncryptedFile(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let f = obj["format"] as? String else { return false }
        return f == format
    }

    // MARK: 內部

    /// AAD：把檔頭參數綁進 GCM 驗證，改了任何一個欄位都解不開
    private static func aad(_ e: Envelope) -> Data {
        Data("\(e.format)|\(e.version)|\(e.kdf)|\(e.iterations)|\(e.salt)".utf8)
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        // 統一成 NFC：同一個字在不同輸入法可能是組合字或預組字，不正規化會解不開
        let pw = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw.map { Int8(bitPattern: $0) }, pw.count,
                                 saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                 &derived, derived.count)
        }
        guard status == kCCSuccess else { throw ExportError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        precondition(status == errSecSuccess, "系統亂數產生失敗")
        return Data(b)
    }
}
