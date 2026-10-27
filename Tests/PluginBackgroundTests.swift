import Foundation
import AppKit
import Darwin

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) { if ok { passed += 1 } else { failed += 1; print("❌ " + name) } }
func reject(_ name: String, _ body: () async throws -> Void) async { do { try await body(); check(name, false) } catch { check(name, true) } }
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
@MainActor
func run() async throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    let agents = root.appendingPathComponent("agents")
    try fm.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let state = root.appendingPathComponent("state").path
    let entry = root.appendingPathComponent("plugin.1m.sh").path
    let code = root.appendingPathComponent("code").path
    let context = PluginBackground.Context(entrypoint: entry, codeRoot: code, state: state)
    check("僅相同外掛入口與專屬資源路徑歸屬", context.owns(entry) && context.owns(code + "/app/main.sh") && !context.owns(code + "-other/main.sh") && !context.owns(code + "/../other/main.sh"))
    check("狀態環境鍵必須完整相同", context.matches(executable: "/bin/sleep", arguments: [], environment: ["SPLITSWAN_PLUGIN_STATE":state]) && !context.matches(executable: "/bin/sleep", arguments: [], environment: ["SPLITSWAN_PLUGIN_STATE":state + "-other"]))
    check("一般直譯器入口可以辨識", context.matches(executable: "/bin/bash", arguments: ["/bin/bash", entry], environment: [:]))
    check("文字編輯器與 shell 文字提到入口不誤停", !context.matches(executable: "/usr/bin/vi", arguments: ["vi", entry], environment: [:]) && !context.matches(executable: "/bin/sh", arguments: ["sh", "-c", entry], environment: [:]))
    let first = PluginBackground.Identity(pid: 90001, seconds: 1, microseconds: 1)
    let child = PluginBackground.Identity(pid: 90002, seconds: 1, microseconds: 2)
    let other = PluginBackground.Identity(pid: 90003, seconds: 1, microseconds: 3)
    let jobs = [PluginBackground.Job(identity: first, parent: 1, executable: "/bin/bash", arguments: ["bash",entry], environment: [:]), PluginBackground.Job(identity: child, parent: first.pid, executable: "/bin/sleep", arguments: ["sleep","30"], environment: [:]), PluginBackground.Job(identity: other, parent: 1, executable: "/bin/sleep", arguments: ["sleep","30"], environment: [:])]
    var monitor = PluginBackground(agents: agents, readJobs: { jobs })
    check("只納入相關根程序與子程序，不碰同名程序", Set(monitor.related(jobs, context: context).map(\.identity)) == [first,child])
    monitor.readJobs = { [] }
    let unrelated = agents.appendingPathComponent("unrelated.plist")
    func plist(_ path: URL, label: String, args: [String], env: [String:String] = [:]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label":label,"ProgramArguments":args,"EnvironmentVariables":env,"KeepAlive":true], format: .xml, options: 0)
        try data.write(to:path);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
    }
    try plist(unrelated,label:"org.example.unrelated",args:["/bin/sleep","30"])
    check("同名無關登入服務不會列入", try monitor.inspect(context).services.isEmpty)
    let related = agents.appendingPathComponent("related.plist")
    try plist(related,label:"org.example.plugin",args:["/bin/bash",entry])
    let before = try monitor.inspect(context)
    check("檢查唯讀，不移走或停用服務", before.services.count == 1 && fm.fileExists(atPath:related.path))
    let calls = Locked<[[String]]>([])
    let loaded = Locked(true)
    monitor.command = { args in
        calls.use { $0.append(args) }
        if args[0] == "print" { return loaded.use { $0 ? 0 : 113 } }
        if args[0] == "bootout" { loaded.use { $0 = false } }
        return 0
    }
    monitor.serviceStatus = { target in
        calls.use { $0.append(["print",target]) }
        return loaded.use { $0 } ? PluginBackground.ServiceStatus(code:0,path:related.path,executable:"/bin/bash",arguments:["bash",entry]) : .init(code:113)
    }
    let trash = root.appendingPathComponent("trash")
    try fm.createDirectory(at: trash,withIntermediateDirectories:true)
    let result = try await monitor.stop(context,trash:{ try FileManager.default.moveItem(at:$0,to:trash.appendingPathComponent($0.lastPathComponent)) })
    check("先停用／卸載，再移出登入服務並複查", result.services == 1 && !fm.fileExists(atPath:related.path) && fm.fileExists(atPath:unrelated.path) && calls.use { $0.map { $0[0] } } == ["print","disable","print","bootout","print"])
    check("只操作目前使用者的明確服務識別碼", calls.use { $0.allSatisfy { $0.last == "gui/\(getuid())/org.example.plugin" } })
    try plist(related,label:"org.example.plugin",args:["/bin/bash",entry])
    monitor.command = { _ in -1 }
    await reject("停用失敗保留服務，不誤報成功") { _ = try await monitor.stop(context,trash:{ _ in fatalError("不可移除") }) }
    check("停止失敗沒有移走原檔", fm.fileExists(atPath:related.path))
    monitor.command = { _ in 0 };monitor.serviceStatus = { _ in .init(code:1) }
    await reject("權限錯誤不當成服務不存在") { _ = try await monitor.stop(context,trash:{ _ in fatalError("不可移除") }) }
    let remainingCalls=Locked(0)
    monitor.serviceStatus = { _ in
        let n=remainingCalls.use { $0 += 1;return $0 }
        return n > 2 ? .init(code:1) : .init(code:0,path:related.path,executable:"/bin/bash",arguments:["bash",entry])
    }
    await reject("卸載未成功不可移走服務") { _ = try await monitor.stop(context,trash:{ _ in fatalError("不可移除") }) }
    let mismatchCalls=Locked(0)
    monitor.command={ _ in mismatchCalls.use { $0 += 1 };return 0 }
    monitor.serviceStatus={ _ in .init(code:0,path:unrelated.path,executable:"/bin/sleep",arguments:["sleep","30"]) }
    await reject("載入標籤同名但路徑與程式不同時不操作") { _ = try await monitor.stop(context,trash:{ _ in fatalError("不可移除") }) }
    check("沒有停用或卸載無關的已載入服務",mismatchCalls.use { $0 } == 0)
    try fm.setAttributes([.posixPermissions:0o666],ofItemAtPath:related.path)
    await reject("相關服務可被他人修改時拒絕操作") { _ = try monitor.inspect(context) }
    try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:related.path)
    let duplicate = agents.appendingPathComponent("duplicate.plist")
    try plist(duplicate,label:"org.example.plugin",args:["/bin/bash",entry])
    await reject("重複識別碼不操作不明確服務") { _ = try monitor.inspect(context) }
    try fm.removeItem(at:duplicate);try fm.removeItem(at:related)
    try plist(related,label:"org.example.plugin",args:["/bin/bash",entry])
    let asyncJobs=Locked(jobs)
    let asyncSignals=Locked<[PluginBackground.Identity]>([])
    let asyncLoaded=Locked(true)
    monitor.readJobs={ asyncJobs.use { $0 } }
    monitor.signal={ id,_ in asyncSignals.use { $0.append(id) };asyncJobs.use { $0.removeAll { $0.identity == id } } }
    monitor.serviceStatus={ _ in asyncLoaded.use { $0 } ? .init(code:0,path:related.path,executable:"/bin/bash",arguments:["bash",entry],identity:first) : .init(code:113) }
    monitor.command={ args in
        if args[0] == "bootout" {
            let until=ContinuousClock.now.advanced(by:.seconds(5))
            while asyncSignals.use({$0.count}) < 2 && ContinuousClock.now < until { try? await Task.sleep(for:.milliseconds(10)) }
            if asyncSignals.use({$0.count}) == 2 { asyncLoaded.use { $0=false };return 0 }
            return 1
        }
        return 0
    }
    let asynchronous=try await monitor.stop(context,trash:{try FileManager.default.moveItem(at:$0,to:trash.appendingPathComponent("asynchronous.plist"))})
    check("非同步 bootout 等待程序收尾，停止與卸載能一起完成",asynchronous.processes==2 && asynchronous.services==1)
    check("卸載單一服務不會終止無關程序",asyncSignals.use { !$0.contains(other) } && asyncJobs.use { $0.map(\.identity) } == [other])
    let table = Locked([jobs[0]])
    let killed = Locked<[PluginBackground.Identity]>([])
    monitor.readJobs = { table.use { $0 } }
    monitor.signal = { id, _ in
        killed.use { $0.append(id) }
        table.use { $0 = [PluginBackground.Job(identity:.init(pid:id.pid,seconds:99,microseconds:0),parent:1,executable:"/bin/sleep",arguments:[],environment:[:])] }
    }
    _ = try await monitor.stop(context,trash:{ _ in fatalError("不應有服務") })
    check("PID 重用後不終止新的無關程序", killed.use { $0 } == [first])
    monitor.readJobs = { throw PluginPackage.fail(.backgroundCheckTimeout, "fixture denied") }
    await reject("程序清單失敗不回報已停止") { _ = try await monitor.stop(context,trash:{ _ in fatalError("不應有服務") }) }

    // 真實原生程序、假外掛與假垃圾桶；拒絕 TERM 的根程序和子程序都須結束。
    let processEntry = root.appendingPathComponent("process.1m.sh")
    let marker = root.appendingPathComponent("started")
    try Data("#!/bin/bash\ntrap '' TERM\necho ready > \"$1\"\nwhile :; do /bin/sleep 30; done\n".utf8).write(to:processEntry)
    let process = Process();process.executableURL=URL(fileURLWithPath:"/bin/bash");process.arguments=[processEntry.path,marker.path];process.environment=["SPLITSWAN_PLUGIN_STATE":state];process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
    let untouched = Process();untouched.executableURL=URL(fileURLWithPath:"/bin/sleep");untouched.arguments=["30"];try untouched.run()
    defer { if untouched.isRunning { untouched.terminate() };if process.isRunning { kill(process.processIdentifier,SIGKILL) } }
    try process.run()
    let native = PluginBackground(agents:agents)
    let nativeContext=PluginBackground.Context(entrypoint:processEntry.path,codeRoot:nil,state:state)
    let deadline=ContinuousClock.now.advanced(by:.seconds(5))
    var discovered:[PluginBackground.Job]=[]
    while ContinuousClock.now < deadline {
        discovered=try native.inspect(nativeContext).jobs
        if discovered.count >= 2 && fm.fileExists(atPath:marker.path) { break }
        try await Task.sleep(for:.milliseconds(20))
    }
    check("原生 argv 與子程序辨識，不依賴程序名稱", discovered.count >= 2 && discovered.contains { $0.identity.pid == process.processIdentifier })
    let stopped=try await native.stop(nativeContext,trash:{ _ in fatalError("沒有獨立服務") })
    check("拒絕 TERM 的假外掛與子程序最終都已停止", stopped.processes >= 2 && discovered.allSatisfy { PluginBackground.identity($0.identity.pid)?.0 != $0.identity })
    check("相同 sleep 執行檔的無關程序仍在執行", untouched.isRunning)
    check("停止後再次檢查無殘留", try native.inspect(nativeContext).jobs.isEmpty)
    print("通過 \(passed)，失敗 \(failed)")
}
Task { @MainActor in do { try await run(); exit(failed == 0 ? 0 : 1) } catch { print("❌ \(error.localizedDescription)"); print("通過 \(passed)，失敗 \(failed+1)");exit(1) } }
RunLoop.main.run()
