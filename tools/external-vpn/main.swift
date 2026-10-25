import Foundation
import Darwin

func emit(_ status: ExternalVPNStatus) {
    if let data = try? JSONEncoder().encode(status) { FileHandle.standardOutput.write(data); print("") }
}

var activeSystem: ExternalVPNSystem?
var owner: UInt32?
var operation = ""
var failureStage = ExternalVPNFailure.Stage.observing
RootOperationLifetime.shared.start()
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw ExternalVPNError.invalid("缺少系統操作") }
    operation = command
    let external = ["prepare", "tick", "restore", "status", "inspect"]
    let company = ["company-up", "company-down", "company-reload", "company-reload-settings", "company-log-ready"]
    guard (external + company).contains(command),
          command == "company-up" ? (2...3).contains(arguments.count) : arguments.count == 1 else {
        throw ExternalVPNError.invalid("無法辨識系統操作或參數")
    }
    if command == "inspect" {
        let system = try ExternalVPNSystem(owner: getuid(), lock: false)
        let snapshot = try system.snapshot(baseline: nil)
        emit(ExternalVPNStatus(phase: .idle, message: "可讀取原本的 IPv4 出口與 DNS；未變更網路", interface: snapshot.interface, tunnel: try ExternalVPNPlanner.tunnel(in: snapshot), routeCount: snapshot.routes.count))
        exit(0)
    }
    guard let text = ProcessInfo.processInfo.environment["SUDO_UID"], let uid = UInt32(text), uid > 0 else {
        throw ExternalVPNError.invalid("請由 SplitSwan 透過 sudo 執行已安裝的系統元件")
    }
    owner = uid
    let system = try ExternalVPNSystem(owner: uid)
    activeSystem = system
    let engine = ExternalVPNEngine(runtime: system)
    let companyEngine = CompanyVPNEngine(runtime: system)
    var existing = try system.load()
    if command.hasPrefix("company-") {
        let action = String(command.dropFirst("company-".count))
        let managing = existing.map { $0.hasPendingMutations || [.waiting, .applying, .active, .restoring, .failed, .recoveryRequired].contains($0.phase) } ?? false
        if managing {
            guard var session = existing else { throw CompanyVPNError.admission("分流紀錄無法讀取") }
            switch action {
            case "up":
                guard session.phase == .active else { throw CompanyVPNError.admission("自動分流尚未啟用，請先停止並復原或重新嘗試分流") }
                let target = arguments[1]
                guard let slot = Int(target), (1...3).contains(slot) else { throw CompanyVPNError.admission("雙 VPN 請明確指定一台公司閘道") }
                let revision = arguments.count == 3 && !arguments[2].isEmpty ? arguments[2] : nil
                session = try companyEngine.up(session, slot: slot, revision: revision)
                print("ok vpn\(slot)")
            case "down":
                if session.company == nil { try system.companyIdle() }
                _ = try companyEngine.down(session)
                print("ok down")
            case "log-ready":
                if session.company != nil { try system.verifyPlugins() }
                print("ok log-ready")
            default:
                throw CompanyVPNError.admission("自動分流期間不允許重載公司 daemon；請先停止並復原")
            }
        } else {
            var args = [action]
            if action == "up" {
                guard ["auto", "1", "2", "3"].contains(arguments[1]) else { throw CompanyVPNError.admission("公司閘道參數錯誤") }
                args.append(arguments[1])
            }
            let (code, output) = try ExternalVPNSystem.runCommand(ExternalVPNSystem.worker, args, timeout: action == "up" ? 100 : 28)
            print(output, terminator: "")
            exit(code)
        }
    } else {
        switch command {
        case "prepare":
            failureStage = .preparing
            try system.companyIdle()
            let data = FileHandle.standardInput.readData(ofLength: 32_769)
            guard data.count <= 32_768 else { throw ExternalVPNError.invalid("分流設定超過大小限制") }
            let profile = try JSONDecoder().decode(ExternalVPNProfile.self, from: data)
            emit(ExternalVPNStatus(session: try engine.prepare(owner: uid, profile: profile, previous: existing)))
        case "tick":
            if let session = existing { existing = try companyEngine.tick(session) }
            if let session = existing { emit(ExternalVPNStatus(session: try engine.tick(session))) } else { emit(.idle) }
        case "restore":
            failureStage = .restoring
            if let session = existing { emit(ExternalVPNStatus(session: try engine.restore(session))) } else { emit(.idle) }
        default:
            if let session = existing { emit(ExternalVPNStatus(session: session)) } else { emit(.idle) }
        }
    }
} catch {
    if operation.hasPrefix("company-") {
        if let failure = error as? CompanyConnectionFailure {
            let slot = CommandLine.arguments.dropFirst(2).first ?? "1"
            print("reason vpn\(slot) \(failure.reason)")
            print("fail vpn\(slot)")
        } else {
            let code = (error as? CompanyVPNError)?.code ?? ((error as? ExternalVPNError).map { if case .busy = $0 { return "busy" }; return "unsupported" } ?? "unsupported")
            print("admission \(code) \(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
        }
        exit(1)
    }
    if case ExternalVPNError.busy = error, let owner {
        // Read the atomically replaced journal without acquiring the busy writer's lock.
        // Old Apps ignore the new busy field, so preserve the persisted active phase.
        let snapshot = try? ExternalVPNSystem(owner: owner, lock: false).load()
        var status = snapshot.map(ExternalVPNStatus.init(session:)) ?? .idle
        status.busy = true
        status.message = "另一個 VPN 操作正在執行，保留目前狀態"
        emit(status)
        exit(0)
    }
    RootOperationLifetime.shared.beginRecovery()
    if let system = activeSystem, let session = try? system.load(),
       let failed = try? ExternalVPNEngine(runtime: system).failed(session, error: error, stage: failureStage) {
        emit(ExternalVPNStatus(session: failed))
    } else {
        emit(ExternalVPNStatus(phase: activeSystem == nil ? .failed : .recoveryRequired,
                               message: error.localizedDescription, interface: nil, tunnel: nil, routeCount: 0))
    }
    exit(1)
}
