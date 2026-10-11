// 「某台公司主機連不上？」一鍵檢查：實際查 DNS、路由與 TCP，不需要 root。
// 只有「目前通道的網段」要經輔助程式唯讀的 sas 子命令（swanctl --list-sas）。
import Foundation

enum HostCheckRunner {
    /// 用系統解析器查 IPv4（跟一般 App 看到的一致）；輸入本身是 IP 就直接回傳
    static func resolve(_ host: String) async -> [String] {
        if HostCheck.isIPv4(host) { return [host] }
        let r = await DiagnosticRunner.runLimited("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host], timeout: 8)
        return HostCheck.ipv4s(fromDscacheutil: r.output)
    }

    /// 這個 IP 目前走哪個介面
    static func routeInterface(_ ip: String) async -> String? {
        let r = await DiagnosticRunner.runLimited("/sbin/route", ["-n", "get", ip], timeout: 5)
        return DiagnosticReport.interface(fromRoute: r.output)
    }

    /// TCP 連線測試，連線逾時 5 秒
    static func tcpOpen(_ ip: String, port: Int) async -> Bool {
        let r = await DiagnosticRunner.runLimited("/usr/bin/nc", ["-z", "-G", "5", ip, String(port)], timeout: 8)
        return r.code == 0 && !r.timedOut
    }

    /// 目前 CHILD_SA 的遠端網段（逗號分隔）；沒連線、輔助程式失敗或逾時回 nil
    static func activeRemoteTS() async -> String? {
        let (code, out) = await VPNController.runHelper(["sas"])
        guard code == 0 else { return nil }
        return HostCheck.activeRemoteTS(fromListSas: out)
    }

    static func verify(ips: [String], port: Int?) async -> [HostCheck.IPResult] {
        var out: [HostCheck.IPResult] = []
        for ip in ips {
            let ifname = await routeInterface(ip)
            let via = ifname.map(ReconnectPolicy.isTunnelInterface) ?? false
            var portOK: Bool?
            if let port { portOK = await tcpOpen(ip, port: port) }
            out.append(HostCheck.IPResult(ip: ip, interface: ifname, viaTunnel: via, portOK: portOK))
        }
        return out
    }
}
