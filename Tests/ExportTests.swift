import Foundation
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
func throwsErr(_ f: () throws -> Any) -> Error? { do { _ = try f(); return nil } catch { return error } }

let p = ExportPayload(name: "Demo", gateways: ["203.0.113.10", "203.0.113.20", ""], remoteTS: "10.0.0.0/24, 198.51.100.5/32", psk: #"p"s\k 密鑰 !@#"#)
let pw = "correct horse"
let t0 = Date()
let enc = try! ConfigExport.encrypt(p, passphrase: pw)
print(String(format: "   加密耗時 %.2f 秒（600,000 次 PBKDF2）", Date().timeIntervalSince(t0)))
let json = String(data: enc, encoding: .utf8)!
check("檔案是加密格式", ConfigExport.isEncryptedFile(enc))
check("檔案裡看不到 PSK、閘道、網段、名稱明文", !["p\"s", "203.0.113", "10.0.0.0", "198.51.100", "Demo", "密鑰"].contains { json.contains($0) })
check("正確密碼解得開、內容一致（含引號、反斜線、中文）", (try? ConfigExport.decrypt(enc, passphrase: pw)) == p)
check("錯誤密碼 → wrongPassphraseOrTampered", { if case ConfigExport.ExportError.wrongPassphraseOrTampered? = throwsErr({ try ConfigExport.decrypt(enc, passphrase: "wrong pass") }) as? ConfigExport.ExportError { return true }; return false }())
check("密碼太短被拒", throwsErr({ try ConfigExport.encrypt(p, passphrase: "short") }) != nil)

// 竄改：改密文一個字元、改檔頭的 iterations、改 salt
var obj = try! JSONSerialization.jsonObject(with: enc) as! [String: Any]
func reenc(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
var t = obj; var sealed = Array((t["sealed"] as! String)); let i = sealed.count / 2; sealed[i] = sealed[i] == "A" ? "B" : "A"; t["sealed"] = String(sealed)
check("竄改密文 → 解不開", throwsErr({ try ConfigExport.decrypt(reenc(t), passphrase: pw) }) != nil)
t = obj; t["iterations"] = 600_001
check("竄改檔頭 iterations → 解不開", throwsErr({ try ConfigExport.decrypt(reenc(t), passphrase: pw) }) != nil)
t = obj; t["iterations"] = 1_000
check("過低的 iterations（降級攻擊）被拒", throwsErr({ try ConfigExport.decrypt(reenc(t), passphrase: pw) }) != nil)
t = obj; t["version"] = 2
check("未知版本被拒", { if case ConfigExport.ExportError.unsupportedVersion(2)? = throwsErr({ try ConfigExport.decrypt(reenc(t), passphrase: pw) }) as? ConfigExport.ExportError { return true }; return false }())
check("一般 company.env 不會被當成加密檔", !ConfigExport.isEncryptedFile(Data("SPLITSWAN_GATEWAYS=\"1.2.3.4\"".utf8)))

// 兩次加密結果不同（隨機 salt／nonce）
let enc2 = try! ConfigExport.encrypt(p, passphrase: pw)
check("同內容同密碼，兩次加密結果不同", enc != enc2)

// PSK 跳脫來回
let raw = #"a"b\c"#
check("quote → unquote 還原", ConfigStore.unquote(ConfigStore.quote(raw)) == raw)
// 位元組層級竄改：真正測到 GCM 驗證（base64 仍合法）
var t2 = obj; var raw2 = [UInt8](Data(base64Encoded: t2["sealed"] as! String)!); raw2[raw2.count / 2] ^= 0x01
t2["sealed"] = Data(raw2).base64EncodedString()
check("位元組竄改 → wrongPassphraseOrTampered", { if case ConfigExport.ExportError.wrongPassphraseOrTampered? = throwsErr({ try ConfigExport.decrypt(reenc(t2), passphrase: pw) }) as? ConfigExport.ExportError { return true }; return false }())

// 解出的值轉存成 company.env 再讀回
let envText = CompanyPresetStore.renderEnv(name: "My \"Co\"\nX", gateways: p.gateways, remoteTS: p.remoteTS)
let back = CompanyPresetStore.preset(from: CompanyPresetStore.parse(envText), source: "t")
check("company.env 讀回閘道一致", back?.gateways == p.gateways)
check("company.env 讀回網段一致", back?.remoteTS == p.remoteTS)
check("名稱的引號與換行被清掉，不破壞格式", !(back?.name ?? "\"").contains("\"") && !(back?.name ?? "\n").contains("\n") && envText.components(separatedBy: "\n").filter { $0.hasPrefix("SPLITSWAN_") }.count == 3)
check("company.env 不含 PSK", !envText.contains("p\"s") && !envText.contains("密鑰"))
print("\n通過 \(pass)，失敗 \(fail)")
