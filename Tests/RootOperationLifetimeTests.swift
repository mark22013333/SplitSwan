import Foundation
import Darwin

var pass = 0, fail = 0
func check(_ name: String, _ value: Bool) { print((value ? "✅ " : "❌ ") + name); value ? (pass += 1) : (fail += 1) }
let app = RootCallerIdentity(pid: 100, parent: 1, startedSeconds: 1000, startedMicroseconds: 1)
let sudo = RootCallerIdentity(pid: 101, parent: 100, startedSeconds: 1001, startedMicroseconds: 1)
var processes = [app.pid: app, sudo.pid: sudo]
let chain = RootCallerChain(parent: sudo.pid, read: { processes[$0] })!
check("正常 App 與 sudo 祖先存活", chain.isAlive { processes[$0] })
processes.removeValue(forKey: app.pid)
check("sudo 仍存活但 App 已離開必須取消", !chain.isAlive { processes[$0] })
processes[app.pid] = RootCallerIdentity(pid: app.pid, parent: app.parent, startedSeconds: 2000, startedMicroseconds: 1)
check("原 PID 被重用不得採納新程序", !chain.isAlive { processes[$0] })
processes[app.pid] = app
processes[sudo.pid] = RootCallerIdentity(pid: sudo.pid, parent: 1, startedSeconds: sudo.startedSeconds, startedMicroseconds: sudo.startedMicroseconds)
check("sudo 被重新收養也必須取消", !chain.isAlive { processes[$0] })
check("祖先讀取失敗拒絕捕捉", RootCallerChain(parent: 101, read: { _ in nil }) == nil)
check("不接受已孤立的 launchd 呼叫者", RootCallerChain(parent: 1, read: { _ in nil }) == nil)
check("祖先循環拒絕", RootCallerChain(parent: 9, read: { RootCallerIdentity(pid: $0, parent: $0, startedSeconds: 1, startedMicroseconds: 1) }) == nil)
check("超過祖先上限拒絕", RootCallerChain(parent: 100, read: { RootCallerIdentity(pid: $0, parent: $0 - 1, startedSeconds: 1, startedMicroseconds: 1) }) == nil)
check("可讀目前程序的 kernel 身分", RootCallerIdentity.read(getpid())?.pid == getpid())
check("不存在的 PID 讀取失敗", RootCallerIdentity.read(Int32.max) == nil)
print("通過 \(pass)，失敗 \(fail)")
exit(fail == 0 ? 0 : 1)
