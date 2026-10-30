import Foundation
import Darwin

var pass = 0, fail = 0
func check(_ name: String, _ condition: Bool) { print((condition ? "✅ " : "❌ ") + name); condition ? (pass += 1) : (fail += 1) }
func mode(_ path: String) -> mode_t { var info = stat(); return lstat(path, &info) == 0 ? info.st_mode : 0 }
func logNames(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("external-split-failure-") }.sorted()
}

check("waiting 轉 failed 的 tick 要記錄", ExternalFailureLog.shouldRecord(operation: "tick", previous: .waiting, next: .failed))
check("active 轉 failed 的 tick 要記錄", ExternalFailureLog.shouldRecord(operation: "tick", previous: .active, next: .failed))
check("已是 failed 再收到 failed 不重複記錄", !ExternalFailureLog.shouldRecord(operation: "tick", previous: .failed, next: .failed))
check("啟動時讀到舊的 failed 狀態不記錄", !ExternalFailureLog.shouldRecord(operation: "status", previous: .idle, next: .failed))
check("轉為待復原不屬於分流失敗紀錄", !ExternalFailureLog.shouldRecord(operation: "tick", previous: .active, next: .recoveryRequired))

let suite = "SplitSwan.ExternalFailureLog." + UUID().uuidString
let preferences = UserDefaults(suiteName: suite)!
check("預設資料夾在家目錄的 Library/Logs/SplitSwan", ExternalFailureLog.directory(preferences, home: "/Users/example").path == "/Users/example/Library/Logs/SplitSwan")
preferences.set("relative/logs", forKey: "ExternalFailureLogDir")
check("覆寫資料夾必須是絕對路徑", ExternalFailureLog.directory(preferences, home: "/Users/example").path == "/Users/example/Library/Logs/SplitSwan")
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("splitswan-failure-log-" + UUID().uuidString)
let logs = root.appendingPathComponent("logs")
preferences.set(logs.path, forKey: "ExternalFailureLogDir")
check("啟動參數可覆寫資料夾", ExternalFailureLog.directory(preferences) == URL(fileURLWithPath: logs.path, isDirectory: true))
preferences.removePersistentDomain(forName: suite)

check("家目錄遮蔽不誤傷相似前綴", ExternalFailureLog.maskHome("/Users/example/a /Users/example2/b /Users/example", home: "/Users/example") == "~/a /Users/example2/b ~")
let ifconfig = "en0: flags=8863<UP> mtu 1500\n\tether aa:bb:cc:dd:ee:ff\n\tinet6 fe80::1%en0 prefixlen 64\n\tinet 192.0.2.5 netmask 0xffffff00 broadcast 192.0.2.255\nutun4: flags=8051<UP,POINTOPOINT> mtu 1384\n\tinet 10.0.0.127 --> 1.1.1.1 netmask 0xffffffff\n"
check("ifconfig 只留介面名稱與 inet", ExternalFailureLog.interfaceSummary(ifconfig) == "en0:\n\tinet 192.0.2.5 netmask 0xffffff00 broadcast 192.0.2.255\nutun4:\n\tinet 10.0.0.127 --> 1.1.1.1 netmask 0xffffffff")

let now = Date(timeIntervalSince1970: 1_800_000_000)
let stamp = ExternalFailureLog.stamp(now)
let calls = LockedCalls()
final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
let fakeRun: ExternalFailureLog.Runner = { exe, args in
    calls.add(([exe] + args).joined(separator: " "))
    switch exe {
    case "/usr/sbin/netstat": return "1.1.1.1 10.0.0.127 UHr utun4\nlog /Users/example/Library\n"
    case "/usr/sbin/scutil": return "nameserver[0] : 1.1.1.1\n"
    default: return ifconfig
    }
}
let statusJSON = #"{"phase":"failed","message":"原本的 DNS 1.1.1.1 被 utun4 的 1.1.1.0/24 路由接管，未套用分流"}"#
let first = await ExternalFailureLog.record(statusJSON: statusJSON, directory: logs, home: "/Users/example", now: now, run: fakeRun)
check("寫出一份以時間命名的紀錄", first?.lastPathComponent == "external-split-failure-\(stamp).txt")
check("唯讀查詢路由、DNS 與介面", calls.value == ["/usr/sbin/netstat -rn -f inet", "/usr/sbin/scutil --dns", "/sbin/ifconfig"])
let content = first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
check("紀錄含狀態 JSON、路由與 DNS", content.contains(statusJSON) && content.contains("1.1.1.1 10.0.0.127 UHr utun4") && content.contains("nameserver[0] : 1.1.1.1"))
check("紀錄的家目錄換成 ~、ifconfig 不含 MAC 與 IPv6", content.contains("log ~/Library") && !content.contains("/Users/example") && !content.contains("ether") && !content.contains("inet6"))
check("紀錄檔權限 600", first.map { mode($0.path) & 0o777 } == 0o600)
check("紀錄資料夾權限 700", mode(logs.path) & 0o777 == 0o700)

let outside = root.appendingPathComponent("outside.txt")
try! "原本內容".write(to: outside, atomically: true, encoding: .utf8)
let later = now.addingTimeInterval(1)
let trap = logs.appendingPathComponent("external-split-failure-\(ExternalFailureLog.stamp(later)).txt")
symlink(outside.path, trap.path)
let second = await ExternalFailureLog.record(statusJSON: statusJSON, directory: logs, home: "/Users/example", now: later, run: fakeRun)
check("同名 symlink 不被跟隨，改用新檔名", second?.lastPathComponent == "external-split-failure-\(ExternalFailureLog.stamp(later))-2.txt" && (try? String(contentsOf: outside, encoding: .utf8)) == "原本內容")
check("另存的新檔是一般檔案", second.map { mode($0.path) & S_IFMT } == S_IFREG)

let linkedDir = root.appendingPathComponent("linked")
symlink(logs.path, linkedDir.path)
let viaLink = await ExternalFailureLog.record(statusJSON: statusJSON, directory: linkedDir, home: "/Users/example", now: later.addingTimeInterval(1), run: fakeRun)
check("資料夾本身是 symlink 時拒絕寫入", viaLink == nil)

for index in 0..<12 {
    let old = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
    FileManager.default.createFile(atPath: logs.appendingPathComponent("external-split-failure-\(ExternalFailureLog.stamp(old)).txt").path, contents: Data("舊紀錄".utf8))
}
for other in ["external-split-failure-notes.txt", "unrelated.txt"] {
    FileManager.default.createFile(atPath: logs.appendingPathComponent(other).path, contents: Data())
}
let newest = await ExternalFailureLog.record(statusJSON: statusJSON, directory: logs, home: "/Users/example", now: later.addingTimeInterval(2), run: fakeRun)
let kept = logs.path
let remaining = logNames(logs).filter { $0 != "external-split-failure-notes.txt" }
check("最多保留最近 10 份", remaining.count == 10 && newest.map { remaining.contains($0.lastPathComponent) } == true && remaining.contains(first!.lastPathComponent))
check("只刪自己命名模式的檔案，symlink 也不刪", FileManager.default.fileExists(atPath: kept + "/unrelated.txt") && FileManager.default.fileExists(atPath: kept + "/external-split-failure-notes.txt") && mode(trap.path) & S_IFMT == S_IFLNK)
let oldNames = (0..<12).map { "external-split-failure-\(ExternalFailureLog.stamp(Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))).txt" }
check("刪掉的是最舊的 6 份", oldNames.prefix(6).allSatisfy { !remaining.contains($0) } && oldNames.suffix(6).allSatisfy { remaining.contains($0) })

try? FileManager.default.removeItem(at: root)
print("通過 \(pass)，失敗 \(fail)")
exit(fail == 0 ? 0 : 1)
