import Foundation
import Combine

@MainActor
final class ExternalVPNController: ObservableObject {
    typealias Transport = (String, Data?) async -> (Int32, String)
    static let shared = ExternalVPNController()
    @Published private(set) var status = ExternalVPNStatus.idle
    @Published private(set) var busy = false
    @Published var protectedNetworks = ""
    @Published var dnsDomains = ""
    @Published var directIPv4 = ""
    @Published var dnsMode = ExternalVPNDNSMode.splitDomains
    private let transport: Transport
    private let recordFailure: (String) -> Void
    private let preferences: UserDefaults
    private var monitor: Task<Void, Never>?
    private var monitorGeneration: UInt = 0
    private var stopping = false
    var willStop: () -> Void = {}

    var canConnectCompany: Bool { !busy && status.busy != true && companyPolicyAllowsConnection }

    var companyPolicyAllowsConnection: Bool {
        !stopping && (status.phase == .idle ||
            (status.phase == .active && status.dnsMode == .preserveVPN && status.companyCapability == 1 &&
             (status.companyState == nil || status.companyState == .active)))
    }

    init(preferences: UserDefaults = .standard, autoRefresh: Bool = true, transport: Transport? = nil, recordFailure: ((String) -> Void)? = nil) {
        self.preferences = preferences
        // 注入 transport 的是測試，預設不留現場紀錄，免得執行系統指令或寫進真實的 ~/Library/Logs。
        self.recordFailure = recordFailure ?? (transport == nil ? Self.failureRecorder(ExternalFailureLog.directory(preferences)) : { _ in })
        self.transport = transport ?? { operation, data in
            let result = await ProcessRunner.execute("/usr/bin/sudo", ["-n", "/usr/local/libexec/splitswan-helper", "external", operation], timeout: 120, maxBytes: 65_536, input: data)
            return (result.code, result.output)
        }
        protectedNetworks = preferences.string(forKey: "ExternalVPNProtectedNetworks") ?? ""
        directIPv4 = preferences.string(forKey: "ExternalVPNDirectIPv4") ?? ""
        dnsDomains = preferences.string(forKey: "ExternalVPNDNSDomains") ?? ""
        dnsMode = preferences.string(forKey: "ExternalVPNDNSMode").flatMap(ExternalVPNDNSMode.init(rawValue:)) ?? .splitDomains
        if autoRefresh { Task { await refresh() } }
    }

    var isManaging: Bool { [.waiting, .applying, .active, .restoring, .recoveryRequired].contains(status.phase) }
    var canRetry: Bool { status.canRetry == true }
    var canPrepare: Bool { !isManaging || canRetry }

    private func fields(_ value: String) -> [String] { value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) }

    func start() async {
        guard !busy, canPrepare, !stopping else { return }
        do {
            let profile = try ExternalVPNProfile(protectedNetworks: fields(protectedNetworks), dnsDomains: dnsMode == .preserveVPN ? [] : fields(dnsDomains), dnsMode: dnsMode, directIPv4: fields(directIPv4)).validated()
            preferences.set(directIPv4, forKey: "ExternalVPNDirectIPv4")
            preferences.set(protectedNetworks, forKey: "ExternalVPNProtectedNetworks")
            preferences.set(dnsDomains, forKey: "ExternalVPNDNSDomains")
            preferences.set(dnsMode.rawValue, forKey: "ExternalVPNDNSMode")
            await perform("prepare", input: try JSONEncoder().encode(profile))
            startMonitoring()
        } catch { status = ExternalVPNStatus(phase: .failed, message: error.localizedDescription, interface: nil, tunnel: nil, routeCount: 0) }
    }

    func refresh() async {
        guard !busy else { return }
        await perform("status")
        if status.phase == .applying || status.phase == .restoring { await stop() }
        else { startMonitoring() }
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        willStop()
        defer { stopping = false }
        monitorGeneration &+= 1
        let previous = monitor
        previous?.cancel()
        await previous?.value
        monitor = nil
        while busy { try? await Task.sleep(for: .milliseconds(30)) }
        let deadline = Date().addingTimeInterval(135)
        repeat {
            await perform("restore")
            if status.busy != true { break }
            try? await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline && !Task.isCancelled
    }

    private func startMonitoring() {
        guard monitor == nil, [.waiting, .active].contains(status.phase) else { return }
        monitorGeneration &+= 1
        let generation = monitorGeneration
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, [.waiting, .active].contains(self.status.phase) else { break }
                await self.perform("tick")
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(2))
            }
            if self?.monitorGeneration == generation { self?.monitor = nil }
        }
    }

    private static func failureRecorder(_ directory: URL) -> (String) -> Void {
        { statusJSON in
            Task.detached(priority: .utility) {
                _ = await ExternalFailureLog.record(statusJSON: statusJSON, directory: directory) { exe, args in
                    await ProcessRunner.execute(exe, args, timeout: 10, maxBytes: 1_000_000, qos: .utility).output
                }
            }
        }
    }

    private func perform(_ operation: String, input: Data? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let (code, output) = await transport(operation, input)
        if let data = output.data(using: .utf8), var decoded = try? JSONDecoder().decode(ExternalVPNStatus.self, from: data) {
            if decoded.busy == true {
                status.busy = true
                return
            }
            if code != 0, isManaging, decoded.phase == .failed, decoded.canRetry != true {
                decoded.phase = .recoveryRequired
                decoded.interface = status.interface
                decoded.tunnel = status.tunnel
                decoded.routeCount = status.routeCount
            }
            let previous = status.phase
            status = decoded
            if ExternalFailureLog.shouldRecord(operation: operation, previous: previous, next: decoded.phase) { recordFailure(output) }
        }
        else {
            status = ExternalVPNStatus(phase: isManaging ? .recoveryRequired : .failed,
                                       message: code == 0 ? "系統元件回傳無法辨識的狀態，請更新系統元件" : "無法執行分流系統元件，請先安裝或更新；若曾啟用分流，請按停止並復原",
                                       interface: status.interface, tunnel: status.tunnel, routeCount: status.routeCount)
        }
    }
}
