import Foundation
import SystemConfiguration
import Darwin

final class ExternalVPNSystem: ExternalVPNRuntime {
    private enum CommandFailure: LocalizedError {
        case rejected
        var errorDescription: String? { "網路指令失敗，VPN 可能不允許路由變更" }
    }
    static let directory = "/var/run/splitswan-external"
    private let store: SCDynamicStore
    private let owner: UInt32
    private var lockFD: Int32 = -1
    private let journal = directory + "/session.json"

    init(owner: UInt32, lock: Bool = true) throws {
        self.owner = owner
        guard let store = SCDynamicStoreCreate(nil, "SplitSwanExternalVPN" as CFString, nil, nil) else {
            throw ExternalVPNError.invalid("無法讀取 macOS 網路狀態")
        }
        self.store = store
        if lock {
            guard geteuid() == 0 else { throw ExternalVPNError.invalid("外部 VPN 分流需要透過已安裝的系統元件執行") }
            var info = stat()
            if lstat(Self.directory, &info) != 0 {
                guard errno == ENOENT, mkdir(Self.directory, 0o700) == 0 else { throw ExternalVPNError.invalid("無法建立分流狀態目錄") }
            }
            guard lstat(Self.directory, &info) == 0, info.st_uid == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
                throw ExternalVPNError.invalid("分流狀態目錄權限不安全")
            }
            lockFD = open(Self.directory + "/lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            guard lockFD >= 0, fstat(lockFD, &info) == 0, info.st_uid == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_mode & 0o777 == 0o600 else {
                throw ExternalVPNError.invalid("分流鎖權限不安全")
            }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ExternalVPNError.busy }
        }
    }

    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }

    func load() throws -> ExternalVPNSession? {
        var info = stat()
        guard lstat(journal, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ExternalVPNError.invalid("無法讀取分流紀錄")
        }
        guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, info.st_size <= 2_000_000 else {
            throw ExternalVPNError.invalid("分流紀錄權限或大小不正確")
        }
        let fd = open(journal, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ExternalVPNError.invalid("無法開啟分流紀錄") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let session = try ExternalVPNJournal.decode(handle.readToEnd() ?? Data())
        guard session.owner == owner else { throw ExternalVPNError.invalid("分流正在由其他使用者管理") }
        _ = try session.profile.validated()
        return session
    }

    func save(_ session: ExternalVPNSession?) throws {
        guard let session else {
            if unlink(journal) != 0 && errno != ENOENT { throw ExternalVPNError.invalid("無法清除分流紀錄") }
            return
        }
        let data = try ExternalVPNJournal.encode(session)
        let temporary = Self.directory + "/session.tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd < 0 {
            if errno == EEXIST { _ = unlink(temporary); return try save(session) }
            throw ExternalVPNError.invalid("無法儲存分流復原紀錄")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0 else { throw ExternalVPNError.invalid("無法同步分流復原紀錄") }
            try handle.close()
            guard rename(temporary, journal) == 0 else { throw ExternalVPNError.invalid("無法更新分流復原紀錄") }
        } catch { try? handle.close(); unlink(temporary); throw error }
    }

    static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 4) throws -> String {
        let (code, output) = try runCommand(executable, arguments, timeout: timeout)
        guard code == 0 else { throw CommandFailure.rejected }
        return output
    }

    static func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> (Int32, String) {
        guard !RootOperationLifetime.shared.shouldStop else { throw ExternalVPNError.invalid("系統操作已中斷") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let result = ExternalCommandOutput()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while true {
                let part = pipe.fileHandleForReading.availableData
                if part.isEmpty { break }
                result.append(part)
            }
            read.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while exited.wait(timeout: .now() + 0.1) == .timedOut {
            if Date() >= deadline || RootOperationLifetime.shared.shouldStop {
                process.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 1)
                }
                throw ExternalVPNError.invalid("系統操作逾時或呼叫者已離開，保留紀錄供復原")
            }
        }
        guard read.wait(timeout: .now() + 1) == .success else {
            throw ExternalVPNError.invalid("網路指令輸出尚未完整讀取，請重試復原")
        }
        guard !result.overflow else { throw ExternalVPNError.invalid("網路指令輸出超過上限，請重試復原") }
        return (process.terminationStatus, String(data: result.data, encoding: .utf8) ?? "")
    }

    private func dictionary(_ key: String) -> [String: Any]? { SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] }

    private func serviceDNS() throws -> [ExternalDNSEntry] {
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/DNS" as CFString) as? [String] ?? []
        return try keys.sorted().compactMap { key in
            guard let value = dictionary(key) else { return nil }
            let ipv4 = String(key.dropLast(3)) + "IPv4"
            let interface = dictionary(ipv4)?["InterfaceName"] as? String
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            return ExternalDNSEntry(key: key, interface: interface, value: data)
        }
    }

    private func localIPv4(_ interface: String) throws -> (String, ExternalIPv4Network) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { throw ExternalVPNError.invalid("無法讀取實體網卡位址") }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == interface,
                  let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = current.pointee.ifa_netmask else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let maskValue = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let prefix = maskValue.nonzeroBitCount
            guard maskValue == (prefix == 0 ? 0 : UInt32.max << (32 - prefix)) else { continue }
            let ip = ExternalIPv4(value: value)
            return (ip.description, ExternalIPv4Network(address: ip, prefix: prefix))
        }
        throw ExternalVPNError.invalid("原本的實體網卡已離線，請停止後重新開始")
    }

    private func bootID() throws -> String {
        var value = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { throw ExternalVPNError.invalid("無法辨識本次系統啟動") }
        return "\(value.tv_sec).\(value.tv_usec)"
    }

    private func bootSession() throws -> String {
        var session = [CChar](repeating: 0, count: 64); var length = session.count
        guard sysctlbyname("kern.bootsessionuuid", &session, &length, nil, 0) == 0, length > 1 else { throw ExternalVPNError.invalid("無法辨識本次系統啟動") }
        return String(cString: session)
    }

    func snapshot(baseline: ExternalNetworkSnapshot?) throws -> ExternalNetworkSnapshot {
        let routes = ExternalVPNPlanner.parseRoutes(try Self.command("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
        let ipv6 = try Self.command("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
        let ipv6Default = ExternalVPNPlanner.hasIPv6TunnelDefault(ipv6)
        let physical: String
        let gateway: String
        if let baseline {
            physical = baseline.interface
            let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
            gateway = keys.compactMap(dictionary).first(where: { $0["InterfaceName"] as? String == physical })?["Router"] as? String ?? ""
        } else {
            let output = try Self.command("/sbin/route", ["-n", "get", "default"])
            func field(_ name: String) -> String? {
                output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + ":") })?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            }
            guard let name = field("interface"), ExternalVPNPlanner.isPhysical(name), let next = field("gateway"),
                  (try? ExternalIPv4(next)) != nil else { throw ExternalVPNError.invalid("找不到可保留的實體 IPv4 上網出口") }
            physical = name; gateway = next
        }
        let local = try? localIPv4(physical)
        guard let (address, network) = local ?? baseline.map({ ("", $0.localNetwork) }) else { throw ExternalVPNError.invalid("找不到實體 IPv4 位址") }
        let dns = try serviceDNS()
        guard baseline != nil || dns.contains(where: { $0.interface == physical && !$0.servers.isEmpty }) else {
            throw ExternalVPNError.invalid("找不到原本網卡的 DNS，無法安全準備分流")
        }
        return ExternalNetworkSnapshot(bootID: try bootID(), interface: physical, address: address, gateway: gateway,
                                       localNetwork: network, routes: routes, dns: dns, ipv6TunnelDefault: ipv6Default,
                                       interfaceIndex: if_nametoindex(physical),
                                       bootSession: try bootSession(),
                                       defaultDNSServers: dictionary("State:/Network/Global/DNS")?["ServerAddresses"] as? [String] ?? [],
                                       defaultDNSDomains: dictionary("State:/Network/Global/DNS")?["SupplementalMatchDomains"] as? [String] ?? [])
    }

    private func sameRoute(_ a: ExternalRoute, _ b: ExternalRoute) -> Bool {
        a.sameIdentity(as: b)
    }

    static func routeArguments(_ route: ExternalRoute, operation: String) -> [String] {
        var arguments = ["-n", operation, "-net", route.network.description]
        if route.kind == .directInterface { arguments += ["-interface", route.interface] }
        else { arguments += [route.gateway, "-ifp", route.interface] }
        if operation == "add" { arguments.append("-proto1") }
        return arguments
    }

    func add(_ route: ExternalRoute) throws {
        if route.kind == .directInterface {
            let index = if_nametoindex(route.interface)
            guard index > 0, route.gateway == "link#\(index)", ExternalVPNPlanner.isPhysical(route.interface) else {
                throw ExternalVPNRouteError.notAdded("直連介面身分已變更，未新增路由")
            }
        }
        let routes = ExternalVPNPlanner.parseRoutes(try Self.command("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
        guard !routes.contains(where: { $0.network == route.network && !$0.flags.contains("I") }) else {
            throw ExternalVPNRouteError.notAdded("有相同目的地的既有路由，未取代其他程式的設定")
        }
        do {
            _ = try Self.command("/sbin/route", Self.routeArguments(route, operation: "add"))
        } catch is CommandFailure {
            throw ExternalVPNRouteError.notAdded("新增路由遭拒，未取代其他程式的設定")
        }
    }

    func remove(_ route: ExternalRoute) throws {
        let routes = ExternalVPNPlanner.parseRoutes(try Self.command("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
        guard route.isOwned, routes.contains(where: { sameRoute($0, route) }) else { throw ExternalVPNError.invalid("路由已被其他程式變更，未刪除") }
        _ = try Self.command("/sbin/route", Self.routeArguments(route, operation: "delete"))
    }

    func dnsValue(_ key: String) throws -> Data? {
        guard key.range(of: #"^State:/Network/Service/[^/\n]{1,128}/DNS$"#, options: .regularExpression) != nil else { throw ExternalVPNError.invalid("DNS 狀態路徑不正確") }
        guard let value = dictionary(key) else { return nil }
        return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    func setDNS(_ key: String, value: Data) throws {
        _ = try dnsValue(key)
        guard let dictionary = try PropertyListSerialization.propertyList(from: value, format: nil) as? [String: Any],
              SCDynamicStoreSetValue(store, key as CFString, dictionary as CFDictionary) else { throw ExternalVPNError.invalid("無法套用或復原 VPN DNS") }
    }
}

private final class ExternalCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var exceeded = false
    func append(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.count + value.count > 1_000_000 { exceeded = true; return }
        bytes.append(value)
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var overflow: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
}
