import CryptoKit
import Foundation
// 一鍵更新：release 附檔解析、Ed25519 簽章、App 檢查、每日檢查時機，以及用假 App 實際跑一次掛載、複製、替換（不連網）
let T = URL(fileURLWithPath: CommandLine.arguments[1])
var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool) { print((ok ? "✅ " : "❌ ") + n); ok ? (pass += 1) : (fail += 1) }
func json(_ s: String) -> Data { Data(s.utf8) }
func sh(_ exe: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}

// MARK: release 附檔
let dl = "https://github.com/o/r/releases/download/v1.7.0/"
func release(tag: String = "v1.7.0", dmgURL: String = dl + "SplitSwan-1.7.0.dmg", sigURL: String = dl + "SplitSwan-1.7.0.dmg.sig",
             dmgName: String = "SplitSwan-1.7.0.dmg") -> Data {
    json("""
    {"tag_name":"\(tag)","assets":[
      {"name":"\(dmgName)","browser_download_url":"\(dmgURL)"},
      {"name":"\(dmgName).sig","browser_download_url":"\(sigURL)"},
      {"name":"SplitSwan-1.7.0.dmg.sha256","browser_download_url":"\(dl)SplitSwan-1.7.0.dmg.sha256"}]}
    """)
}
let a = UpdateLogic.parseAssets(release(), appName: "SplitSwan", owner: "o", repo: "r")
check("附檔：找到 dmg 與 sig", a?.version == "1.7.0" && a?.dmg.absoluteString == dl + "SplitSwan-1.7.0.dmg"
      && a?.sig.absoluteString == dl + "SplitSwan-1.7.0.dmg.sig")
check("附檔：缺 .sig → nil", UpdateLogic.parseAssets(json("""
    {"tag_name":"v1.7.0","assets":[{"name":"SplitSwan-1.7.0.dmg","browser_download_url":"\(dl)SplitSwan-1.7.0.dmg"}]}
    """), appName: "SplitSwan", owner: "o", repo: "r") == nil)
check("附檔：別的 repo 的網址 → nil", UpdateLogic.parseAssets(release(dmgURL: "https://github.com/evil/r/releases/download/v1.7.0/SplitSwan-1.7.0.dmg"),
                                                         appName: "SplitSwan", owner: "o", repo: "r") == nil)
check("附檔：非 github.com 網址 → nil", UpdateLogic.parseAssets(release(sigURL: "https://example.com/SplitSwan-1.7.0.dmg.sig"),
                                                          appName: "SplitSwan", owner: "o", repo: "r") == nil)
check("附檔：網址含 .. → nil", UpdateLogic.parseAssets(release(dmgURL: dl + "../../x/SplitSwan-1.7.0.dmg"),
                                                     appName: "SplitSwan", owner: "o", repo: "r") == nil)
check("附檔：檔名版本與 tag 不符 → nil", UpdateLogic.parseAssets(release(dmgName: "SplitSwan-1.6.9.dmg"),
                                                           appName: "SplitSwan", owner: "o", repo: "r") == nil)
check("附檔：Windows 版 tag 不採用", UpdateLogic.parseAssets(release(tag: "windows-v0.1.1"), appName: "SplitSwan", owner: "o", repo: "r") == nil)
check("附檔：壞 JSON → nil", UpdateLogic.parseAssets(json("{"), appName: "SplitSwan", owner: "o", repo: "r") == nil)

// MARK: 簽章
let key = Curve25519.Signing.PrivateKey()
let pub = key.publicKey.rawRepresentation.base64EncodedString()
let payload = Data("dmg-content".utf8)
let sigText = try! key.signature(for: payload).base64EncodedString() + "\n"
check("簽章：正確", UpdateLogic.verify(data: payload, signatureText: sigText, publicKeyBase64: pub))
check("簽章：內容被改 → 失敗", !UpdateLogic.verify(data: Data("dmg-content!".utf8), signatureText: sigText, publicKeyBase64: pub))
check("簽章：別把金鑰簽的 → 失敗", !UpdateLogic.verify(data: payload, signatureText: sigText,
                                                  publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()))
check("簽章：亂碼 → 失敗", !UpdateLogic.verify(data: payload, signatureText: "not-base64!!", publicKeyBase64: pub))
check("內建公鑰格式正確", Data(base64Encoded: UpdateLogic.publicKeyBase64)
      .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } != nil)

// MARK: App 檢查
let okInfo: [String: Any] = ["CFBundleIdentifier": "com.example.splitswan", "CFBundleShortVersionString": "1.7.0"]
check("App：符合", UpdateLogic.validateBundle(info: okInfo, expectedID: "com.example.splitswan", expectedVersion: "1.7.0", current: "1.6.1") == nil)
check("App：bundle id 不同", UpdateLogic.validateBundle(info: okInfo, expectedID: "com.other", expectedVersion: "1.7.0", current: "1.6.1") != nil)
check("App：版本與 release 不符", UpdateLogic.validateBundle(info: okInfo, expectedID: "com.example.splitswan", expectedVersion: "1.7.1", current: "1.6.1") != nil)
check("App：沒有比目前新（防降級）", UpdateLogic.validateBundle(info: okInfo, expectedID: "com.example.splitswan", expectedVersion: "1.7.0", current: "1.7.0") != nil)
check("App：缺版本欄位", UpdateLogic.validateBundle(info: ["CFBundleIdentifier": "com.example.splitswan"], expectedID: "com.example.splitswan",
                                                 expectedVersion: "1.7.0", current: "1.6.1") != nil)

// MARK: 每日檢查
let now = Date(timeIntervalSince1970: 1_800_000_000)
check("每日：沒勾選 → 不檢查", !UpdateLogic.shouldAutoCheck(enabled: false, last: nil, now: now))
check("每日：從沒檢查過 → 檢查", UpdateLogic.shouldAutoCheck(enabled: true, last: nil, now: now))
check("每日：23 小時前 → 不檢查", !UpdateLogic.shouldAutoCheck(enabled: true, last: now.addingTimeInterval(-23 * 3600), now: now))
check("每日：24 小時前 → 檢查", UpdateLogic.shouldAutoCheck(enabled: true, last: now.addingTimeInterval(-24 * 3600), now: now))
check("每日：上次時間在未來（時鐘回調）→ 檢查", UpdateLogic.shouldAutoCheck(enabled: true, last: now.addingTimeInterval(3600), now: now))

// MARK: 安裝位置
check("位置：/Applications 可寫 → 可更新", UpdateLogic.installBlocker(bundlePath: "/Applications/SplitSwan.app", parentWritable: true) == nil)
check("位置：不可寫 → 擋下", UpdateLogic.installBlocker(bundlePath: "/Applications/SplitSwan.app", parentWritable: false) != nil)
check("位置：從 dmg 執行 → 擋下", UpdateLogic.installBlocker(bundlePath: "/Volumes/SplitSwan 1.6.1/SplitSwan.app", parentWritable: true) != nil)
check("位置：App Translocation → 擋下", UpdateLogic.installBlocker(bundlePath: "/private/var/folders/x/AppTranslocation/y/d/SplitSwan.app", parentWritable: true) != nil)
let ra = UpdateLogic.relaunchArguments(pid: 4242, appPath: "/Applications/My \"App\".app")
check("重新開啟：PID 與路徑以參數傳入，不拼進指令", ra.count == 5 && ra[0] == "-c" && ra[3] == "4242" && ra[4] == "/Applications/My \"App\".app" && !ra[1].contains("4242"))

// MARK: 用假 App 實際跑一次掛載、檢查、複製、替換
func makeApp(_ dir: URL, id: String, version: String) -> URL {
    let app = dir.appendingPathComponent("SplitSwan.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    try! FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "SplitSwan",
                               "CFBundleName": "SplitSwan", "CFBundlePackageType": "APPL"]
    (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    try! FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("SplitSwan").path)
    _ = sh("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    return app
}
func makeDMG(_ name: String, id: String, version: String) -> URL {
    let src = T.appendingPathComponent("\(name)-src")
    _ = makeApp(src, id: id, version: version)
    let dmg = T.appendingPathComponent("\(name).dmg")
    _ = sh("/usr/bin/hdiutil", ["create", "-volname", name, "-srcfolder", src.path, "-ov", "-format", "UDZO", "-fs", "HFS+", dmg.path])
    return dmg
}
func mounted(_ mnt: URL) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/sbin/mount"); let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(mnt.path)
}

let id = "com.example.splitswan.test"
let goodDMG = makeDMG("good", id: id, version: "9.9.0")
check("測試用 dmg 建立成功", FileManager.default.fileExists(atPath: goodDMG.path))
let work1 = T.appendingPathComponent("work1")
try! FileManager.default.createDirectory(at: work1, withIntermediateDirectories: true)
do {
    let staged = try await UpdateInstaller.stage(dmg: goodDMG, work: work1, bundleID: id, expectedVersion: "9.9.0", current: "1.0.0")
    let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
    check("stage：複製出新版 App", info?["CFBundleShortVersionString"] as? String == "9.9.0")
    check("stage：完成後已卸載 dmg", !mounted(work1.appendingPathComponent("mnt")))

    // 替換：舊版移到暫存區、新版放到原位置
    let target = makeApp(T.appendingPathComponent("installed"), id: id, version: "1.0.0")
    try UpdateInstaller.swap(target: target, with: staged)
    let after = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
    check("swap：原位置換成新版", after?["CFBundleShortVersionString"] as? String == "9.9.0")
    check("swap：舊版保留在暫存區", FileManager.default.fileExists(atPath: work1.appendingPathComponent("previous-SplitSwan.app/Contents/Info.plist").path))
    check("swap：暫存的新版已移走", !FileManager.default.fileExists(atPath: staged.path))
} catch {
    check("stage／swap 不應失敗：\(error.localizedDescription)", false)
}

let work2 = T.appendingPathComponent("work2")
try! FileManager.default.createDirectory(at: work2, withIntermediateDirectories: true)
do {
    _ = try await UpdateInstaller.stage(dmg: goodDMG, work: work2, bundleID: "com.other.app", expectedVersion: "9.9.0", current: "1.0.0")
    check("stage：bundle id 不同應該失敗", false)
} catch {
    check("stage：bundle id 不同 → 失敗", error.localizedDescription.contains("不是"))
    check("stage：失敗後也有卸載 dmg", !mounted(work2.appendingPathComponent("mnt")))
}

let work3 = T.appendingPathComponent("work3")
try! FileManager.default.createDirectory(at: work3, withIntermediateDirectories: true)
do {
    _ = try await UpdateInstaller.stage(dmg: goodDMG, work: work3, bundleID: id, expectedVersion: "9.9.0", current: "9.9.0")
    check("stage：同版本應該失敗", false)
} catch {
    check("stage：同版本（降級／重放）→ 失敗", error.localizedDescription.contains("沒有比目前"))
}

// swap 失敗時還原：staged 不存在
let target2 = makeApp(T.appendingPathComponent("installed2"), id: id, version: "1.0.0")
try! FileManager.default.createDirectory(at: T.appendingPathComponent("work4"), withIntermediateDirectories: true)   // 舊版先搬得走，第二步才失敗
do {
    try UpdateInstaller.swap(target: target2, with: T.appendingPathComponent("work4/none.app"))
    check("swap：新版不存在應該失敗", false)
} catch {
    check("swap：失敗時舊版還原到原位置", FileManager.default.fileExists(atPath: target2.appendingPathComponent("Contents/Info.plist").path)
          && error.localizedDescription.contains("已還原"))
}

print("通過 \(pass)，失敗 \(fail)")
