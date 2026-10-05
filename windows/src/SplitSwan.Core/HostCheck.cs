namespace SplitSwan.Core;

/// <summary>一鍵檢查的目標：主機（已轉小寫）與選填的連接埠。</summary>
public sealed record HostTarget(string Host, int? Port);

/// <summary>一個 IP 的驗證結果。</summary>
/// <param name="Ip">IPv4 位址。</param>
/// <param name="Interface">路由走的介面別名（Find-NetRoute 的 InterfaceAlias）；查不到為 null。</param>
/// <param name="ViaTunnel">路由是否走 VPN（WSL 的 vEthernet 介面）。</param>
/// <param name="PortOk">TCP 連線結果；沒指定連接埠時為 null。</param>
public sealed record IpResult(string Ip, string? Interface, bool ViaTunnel, bool? PortOk);

/// <summary>
/// 「某台公司主機連不上？」一鍵檢查的純邏輯（同 Mac 版 HostCheck.swift）：解析輸入、判斷網段涵蓋、
/// 解析路由查詢輸出、組結果文字。不碰 UI 與外部程序，方便單獨測試；實際執行在托盤 App 的 HostCheckRunner。
/// </summary>
public static class HostCheck
{
    /// <summary>HostCheckRunner 的路由查詢在輸出裡印的標記行：<c>@@ROUTE=介面別名|下一跳</c>（查不到時等號後為空）。</summary>
    public const string RouteMarker = "@@ROUTE=";

    /// <summary>
    /// 接受 <c>host</c>、<c>host:port</c>、網址（<c>https://user@host:8443/path?q</c>）。
    /// host 只接受半形英數、點、連字號，避免換行或特殊字元混進指令參數與設定檔；IPv6 字面值一律拒絕。
    /// </summary>
    public static HostTarget? ParseTarget(string? input)
    {
        var s = (input ?? "").Trim();
        if (s.Length == 0 || s.Any(c => char.IsWhiteSpace(c) || char.IsControl(c))) return null;
        var scheme = s.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0) s = s[(scheme + 3)..];
        var cut = s.IndexOfAny(['/', '?', '#']);
        if (cut >= 0) s = s[..cut];
        var at = s.LastIndexOf('@');
        if (at >= 0) s = s[(at + 1)..];
        int? port = null;
        var parts = s.Split(':');
        if (parts.Length > 2) return null;
        if (parts.Length == 2)
        {
            var p = parts[1];
            if (p.Length == 0 || p.Length > 5 || !p.All(IsAsciiDigit)) return null;
            var n = int.Parse(p, System.Globalization.CultureInfo.InvariantCulture);
            if (n < 1 || n > 65535) return null;
            port = n;
        }
        var host = parts[0].ToLowerInvariant();
        return IsValidHost(host) ? new HostTarget(host, port) : null;
    }

    /// <summary>主機名稱白名單：半形英數、點、連字號；不以 - 或 . 開頭、不以 - 結尾、≤ 253 字；全數字與點時必須是合法 IPv4。</summary>
    public static bool IsValidHost(string h)
    {
        if (string.IsNullOrEmpty(h) || h.Length > 253 || h[0] == '-' || h[0] == '.' || h[^1] == '-') return false;
        if (!h.All(c => c is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '.' or '-')) return false;
        // 全是數字和點的話，必須是合法 IPv4（避免 1.2.3 這種被當成網域）
        if (h.All(c => c == '.' || IsAsciiDigit(c))) return ParseIPv4(h) is not null;
        return true;
    }

    public static bool IsIPv4(string? s) => ParseIPv4(s) is not null;

    /// <summary>a.b.c.d → 32 位元整數；每段只接受 1～3 個半形數字且 ≤ 255（不用 \d，全形數字不算）。</summary>
    public static uint? ParseIPv4(string? s)
    {
        if (s is null) return null;
        var p = s.Split('.');
        if (p.Length != 4) return null;
        uint v = 0;
        foreach (var x in p)
        {
            if (x.Length == 0 || x.Length > 3 || !x.All(IsAsciiDigit)) return null;
            var n = uint.Parse(x, System.Globalization.CultureInfo.InvariantCulture);
            if (n > 255) return null;
            v = (v << 8) | n;
        }
        return v;
    }

    /// <summary>cidr（a.b.c.d/n）是否涵蓋 ip；格式錯誤或 /0 一律回 false。</summary>
    public static bool Contains(string? cidr, string? ip)
    {
        var parts = (cidr ?? "").Trim().Split('/');
        if (parts.Length != 2 || parts[1].Length == 0 || parts[1].Length > 2 || !parts[1].All(IsAsciiDigit)) return false;
        var mask = int.Parse(parts[1], System.Globalization.CultureInfo.InvariantCulture);
        if (mask < 1 || mask > 32) return false;
        if (ParseIPv4(parts[0]) is not { } net || ParseIPv4(ip) is not { } v) return false;
        var m = uint.MaxValue << (32 - mask);
        return (net & m) == (v & m);
    }

    /// <summary>現有網段中第一個涵蓋 ip 的；沒有為 null。</summary>
    public static string? CoveringSubnet(string ip, IEnumerable<string> subnets) =>
        subnets.Select(x => x.Trim()).FirstOrDefault(x => Contains(x, ip));

    /// <summary>RFC 1918 私有位址。</summary>
    public static bool IsPrivate(string ip) =>
        Contains("10.0.0.0/8", ip) || Contains("172.16.0.0/12", ip) || Contains("192.168.0.0/16", ip);

    /// <summary>還沒被涵蓋的 IP → 要新增的 <c>IP/32</c>（保留順序、不重複）。</summary>
    public static IReadOnlyList<string> Proposal(IEnumerable<string> ips, IEnumerable<string> subnets)
    {
        var list = subnets.ToList();
        return ips.Where(ip => CoveringSubnet(ip, list) is null).Select(ip => ip + "/32").Distinct(StringComparer.Ordinal).ToList();
    }

    /// <summary>
    /// 路由走的介面是不是 VPN：引擎把網段路由加在 WSL 的 NAT 介面「vEthernet (WSL…)」上，
    /// 下一跳是 WSL 的 IP（同 NetworkFingerprint 判斷虛擬網卡的方式）。
    /// </summary>
    public static bool IsTunnelInterface(string? alias) =>
        alias is not null && alias.StartsWith("vEthernet", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// 路由查詢的輸出 → (介面別名, 下一跳)：取第一行 <c>@@ROUTE=別名|下一跳</c>；
    /// 沒有標記行、等號後為空或別名為空都回 null。別名可能含空白與括號（例：vEthernet (WSL)），以最後一個 | 分隔。
    /// </summary>
    public static (string Alias, string? NextHop)? ParseRoute(string? output)
    {
        foreach (var raw in (output ?? "").Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = raw.Trim();
            if (!line.StartsWith(RouteMarker, StringComparison.Ordinal)) continue;
            var v = line[RouteMarker.Length..];
            var bar = v.LastIndexOf('|');
            var alias = (bar >= 0 ? v[..bar] : v).Trim();
            var hop = bar >= 0 ? v[(bar + 1)..].Trim() : "";
            if (alias.Length == 0) return null;
            return (alias, hop.Length == 0 ? null : hop);
        }
        return null;
    }

    /// <summary>給管理者的結果文字（可直接貼上），格式同 Mac 版。</summary>
    public static string Report(HostTarget target, IEnumerable<IpResult> results, IEnumerable<string> added, string? vpnIp)
    {
        var lines = new List<string> { $"主機：{target.Host}" + (target.Port is { } p ? $"，連接埠 {p}" : "") };
        if (!string.IsNullOrEmpty(vpnIp)) lines.Add($"我的 VPN 位址：{vpnIp}");
        var add = added.ToList();
        if (add.Count > 0) lines.Add($"本次新增網段：{string.Join(", ", add)}");
        foreach (var r in results)
        {
            var s = $"{r.Ip}：路由 {r.Interface ?? "查不到"}（{(r.ViaTunnel ? "有走 VPN" : "沒走 VPN")}）";
            if (r.PortOk is { } ok && target.Port is { } port) s += $"，TCP {port} {(ok ? "可連線" : "連不上")}";
            lines.Add(s);
        }
        return string.Join("\n", lines);
    }

    private static bool IsAsciiDigit(char c) => c is >= '0' and <= '9';
}
