import Foundation
import Darwin

extension ExternalVPNSystem: CompanyVPNRuntime {
    static let worker = "/usr/local/libexec/splitswan-company-backend"
    static let swanctl = "/opt/homebrew/opt/strongswan/bin/swanctl"
    static let charon = "/opt/homebrew/opt/strongswan/libexec/ipsec/charon"
    static let companyConfig = "/opt/homebrew/etc/swanctl/swanctl.conf"
    static let dualPlugins: Set<String> = Set("charon nonce x509 revocation constraints pubkey pkcs1 pgp sshkey pem openssl pkcs8 curve25519 kdf kernel-pfkey kernel-pfroute socket-default vici eap-identity eap-md5 eap-gtc eap-mschapv2 eap-peap xauth-generic counters".split(separator: " ").map(String.init))

    func beginCompanyRecovery() { RootOperationLifetime.shared.beginRecovery() }

    private func companyConfiguration() throws -> Data {
        let fd = open(Self.companyConfig, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CompanyVPNError.admission("無法讀取公司設定") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 262_144, info.st_mode & 0o022 == 0 else {
            throw CompanyVPNError.admission("公司設定權限或大小無法驗證")
        }
        return try handle.readToEnd() ?? Data()
    }

    func companyPolicy(slot: Int, revision: String?) throws -> CompanyPolicy {
        try CompanyVPNText.policy(companyConfiguration(), slot: slot, revision: revision)
    }

    func daemonIdentity() throws -> String? {
        let (code, text) = try Self.runCommand("/usr/bin/pgrep", ["-x", "charon"], timeout: 4)
        if code == 1 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace)
        let ids = fields.compactMap { Int32($0) }
        guard code == 0, ids.count == fields.count, !ids.isEmpty, ids.allSatisfy({ $0 > 1 }) else {
            throw CompanyVPNError.admission("無法確認 strongSwan daemon 清單")
        }
        guard ids.count == 1 else { throw CompanyVPNError.admission("有多個 strongSwan daemon，未變更任何程序") }
        let value = try Self.command("/bin/ps", ["-p", String(ids[0]), "-o", "uid=,lstart=,comm="]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.split(whereSeparator: \.isWhitespace).first == "0", value.hasSuffix(" " + Self.charon), !value.contains("\n") else {
            throw CompanyVPNError.admission("strongSwan daemon 不屬於本 App 的固定 root 程序")
        }
        return "\(ids[0])|\(value)"
    }

    func companyIdle() throws {
        if try daemonIdentity() == nil { return }
        let sas = try Self.command(Self.swanctl, ["--list-sas"])
        guard sas.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompanyVPNError.admission("strongSwan 已有或正在建立 SA，請先停止公司連線")
        }
    }

    func companyPrepare(_ policy: CompanyPolicy) throws -> String {
        try companyIdle()
        let plugins = Self.dualPlugins.subtracting(["charon"]).sorted().joined(separator: " ")
        let config = """
        # Root-owned isolated configuration: no includes and no system DNS writers.
        charon {
            load_modular = no
            load = \(plugins)
            install_routes = no
            retransmit_tries = 2
            retransmit_timeout = 2
            retransmit_base = 1.5
        }
        """
        let path = Self.directory + "/strongswan-dual.conf"
        let temporary = Self.directory + "/strongswan-dual.tmp"
        _ = unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CompanyVPNError.admission("無法建立隔離 DNS 的 daemon 設定") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(config.utf8))
        guard fsync(fd) == 0 else { throw CompanyVPNError.admission("無法同步 daemon 設定") }
        try handle.close()
        guard rename(temporary, path) == 0 else { throw CompanyVPNError.admission("無法儲存 daemon 設定") }
        let source = try companyConfiguration()
        guard CompanyPolicy.digest(source) == policy.revision else { throw CompanyVPNError.admission("公司設定已變更") }
        let connection = try CompanyVPNText.isolatedConfiguration(source)
        let connectionPath = Self.directory + "/swanctl-dual.conf"
        _ = unlink(connectionPath)
        let connectionFD = open(connectionPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard connectionFD >= 0 else { throw CompanyVPNError.admission("無法建立公司設定快照") }
        let connectionFile = FileHandle(fileDescriptor: connectionFD, closeOnDealloc: true)
        try connectionFile.write(contentsOf: connection)
        guard fsync(connectionFD) == 0 else { throw CompanyVPNError.admission("無法同步公司設定快照") }
        try connectionFile.close()
        _ = try Self.command(Self.worker, ["dual-mode"], timeout: 20)
        guard let daemon = try daemonIdentity() else { throw CompanyVPNError.admission("隔離 DNS 的 daemon 未啟動") }
        try verifyPlugins()
        try CompanyVPNText.validateLoaded(Self.command(Self.swanctl, ["--list-conns", "--ike", "vpn\(policy.slot)"]), policy: policy)
        let reread = try companyPolicy(slot: policy.slot, revision: policy.revision)
        guard reread == policy else { throw CompanyVPNError.admission("公司設定在載入期間已變更") }
        try companyIdle()
        return daemon
    }

    func verifyPlugins() throws {
        let plugins = try CompanyVPNText.plugins(Self.command(Self.swanctl, ["--stats"]))
        guard plugins.isSubset(of: Self.dualPlugins), Set(["vici", "kernel-pfkey", "kernel-pfroute", "socket-default"]).isSubset(of: plugins) else {
            throw CompanyVPNError.admission("daemon 載入了未核准或會修改 DNS 的外掛，未允許雙 VPN")
        }
    }

    func companyInitiate(_ policy: CompanyPolicy) throws {
        let (code, output) = try Self.runCommand(Self.worker, ["dual-up", "\(policy.slot)"], timeout: 28)
        guard code == 0 else {
            let reasons = ["auth", "proposal", "ts", "unreachable", "timeout", "unknown"]
            let reason = reasons.first { output.split(separator: "\n").contains(Substring("reason vpn\(policy.slot) \($0)")) } ?? "unknown"
            throw CompanyConnectionFailure(reason: reason)
        }
    }

    func companyIdentity(_ policy: CompanyPolicy) throws -> CompanyIdentity {
        guard let daemon = try daemonIdentity() else { throw CompanyVPNError.admission("公司 daemon 已停止") }
        try verifyPlugins()
        try CompanyVPNText.validateLoaded(Self.command(Self.swanctl, ["--list-conns", "--ike", "vpn\(policy.slot)"]), policy: policy)
        let sas = try Self.command(Self.swanctl, ["--list-sas"])
        var interfaces: [String: [String]] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { throw CompanyVPNError.admission("無法讀取公司通道介面") }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            interfaces[String(cString: current.pointee.ifa_name), default: []].append(ExternalIPv4(value: value).description)
        }
        return try CompanyVPNText.identity(sas, policy: policy, daemon: daemon, interfaces: interfaces)
    }

    func companyAddRoute(_ route: ExternalRoute) throws {
        guard route.isOwned, route.interface.range(of: #"^utun[0-9]{1,4}$"#, options: .regularExpression) != nil, if_nametoindex(route.interface) > 0 else {
            throw CompanyVPNError.admission("公司通道介面已消失，未新增公司路由")
        }
        let routes = ExternalVPNPlanner.parseRoutes(try Self.command("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
        guard !routes.contains(where: { $0.network == route.network && !$0.flags.contains("I") }) else {
            throw CompanyVPNError.admission("公司網段已有相同目的地路由，未取代其他程式的設定")
        }
        // -ifp 的介面名稱要帶冒號，libc link_addr 才會填入名稱；不帶時 IFP 會是空的。
        let target = route.kind == .gateway
            ? ["-host", route.network.address.description, route.gateway, "-ifp", route.interface + ":"]
            : ["-net", route.network.description, "-interface", route.interface]
        _ = try Self.command("/sbin/route", ["-n", "add"] + target + ["-proto1"])
    }

    func companyRoutesAbsent(_ lease: CompanyLease, baseline: ExternalNetworkSnapshot) throws {
        guard let owned = lease.routes, !owned.isEmpty else { return }
        // 結束 SA 後核心隨 utun 退役移除這些路由；這裡只觀察，有限時間內未消失就保留復原紀錄。
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if try CompanyVPNPlanner.remainingRoutes(owned, current: snapshot(baseline: baseline), baseline: baseline).isEmpty { return }
            usleep(200_000)
        } while Date() < deadline
        throw CompanyVPNError.recovery("公司通道已停止，但公司路由仍在；未以目的地刪除。請重試，重新開機也會清除")
    }

    func companyStop(_ lease: CompanyLease) throws {
        guard let daemon = try daemonIdentity() else { return }
        let sas = try Self.command(Self.swanctl, ["--list-sas"])
        if sas.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        guard let expected = lease.daemon, daemon == expected else {
            throw CompanyVPNError.recovery("daemon 身分已變更，未終止不明 SA")
        }
        let headers = sas.split(separator: "\n").filter { !$0.hasPrefix(" ") }
        guard headers.count == 1, headers[0].hasPrefix("vpn\(lease.policy.slot): #") else {
            throw CompanyVPNError.recovery("發現不屬於本次公司的 SA，未終止其他連線")
        }
        if let identity = lease.identity {
            guard headers[0].hasPrefix("vpn\(lease.policy.slot): #\(identity.ikeID),") else { throw CompanyVPNError.recovery("公司 SA 編號已變更") }
        }
        _ = try Self.runCommand(Self.worker, ["dual-down", "\(lease.policy.slot)"], timeout: 8)
        try companyIdle()
    }

    func companyNormalMode() throws {
        try companyIdle()
        _ = try Self.command(Self.worker, ["normal-mode"], timeout: 20)
        try companyIdle()
    }

    func verifyLookup(_ ip: ExternalIPv4, interface: String, gateway: String?) throws {
        let text = try Self.command("/sbin/route", ["-n", "get", ip.description])
        func values(_ key: String) -> [String] {
            text.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return fields.count == 2 && fields[0] == key ? fields[1] : nil
            }
        }
        guard values("interface") == [interface], gateway == nil || values("gateway") == [gateway!] else {
            throw CompanyVPNError.admission("實際路由查詢未通過公司通道或實體出口驗證")
        }
    }

    func releaseCompany(_ session: ExternalVPNSession) throws -> ExternalVPNSession {
        try CompanyVPNEngine(runtime: self).down(session)
    }
}

struct CompanyConnectionFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { "公司 VPN 協商失敗" }
}
