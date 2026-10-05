using System.Net;
using System.Net.Sockets;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 「某台公司主機連不上？」一鍵檢查：實際查 DNS、路由與 TCP（同 Mac 版 HostCheckRunner.swift）。
/// 都不改系統設定、不經連線引擎；路由用 PowerShell 的 Find-NetRoute 查詢。
/// </summary>
internal static class HostCheckRunner
{
    private static readonly TimeSpan DnsTimeout = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan RouteTimeout = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan TcpTimeout = TimeSpan.FromSeconds(5);

    /// <summary>用系統解析器查 IPv4（跟一般 App 看到的一致，去重、保留順序）；輸入本身是 IP 就直接回傳。逾時或查不到回空清單。</summary>
    public static async Task<IReadOnlyList<string>> ResolveAsync(string host, CancellationToken ct)
    {
        if (HostCheck.IsIPv4(host)) return [host];
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(DnsTimeout);
        try
        {
            var addrs = await Dns.GetHostAddressesAsync(host, AddressFamily.InterNetwork, cts.Token);
            return addrs.Where(a => a.AddressFamily == AddressFamily.InterNetwork)
                .Select(a => a.ToString()).Where(HostCheck.IsIPv4).Distinct(StringComparer.Ordinal).ToList();
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            AppLog.Info($"一鍵檢查：查詢 {host} 的 IP 逾時");
            return [];
        }
        catch (SocketException ex)
        {
            AppLog.Info($"一鍵檢查：查不到 {host} 的 IP（{ex.SocketErrorCode}）");
            return [];
        }
    }

    /// <summary>這個 IP 目前走哪個介面（Find-NetRoute 的 InterfaceAlias）；查不到為 null。</summary>
    public static async Task<string?> RouteInterfaceAsync(string ip, CancellationToken ct)
    {
        // ip 只會是驗證過的 IPv4（只有半形數字與點），放進指令稿字串不會破壞引號
        if (!HostCheck.IsIPv4(ip)) return null;
        var script =
            "[Console]::OutputEncoding = [Text.Encoding]::UTF8\n" +
            "try {\n" +
            $"  $r = Find-NetRoute -RemoteIPAddress '{ip}' -ErrorAction Stop |\n" +
            "    Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } | Select-Object -First 1\n" +
            $"  if ($r) {{ '{HostCheck.RouteMarker}' + $r.InterfaceAlias + '|' + $r.NextHop }} else {{ '{HostCheck.RouteMarker}' }}\n" +
            $"}} catch {{ '{HostCheck.RouteMarker}' }}\n";
        var r = await CommandRunner.RunAsync(AppPaths.PowerShellExe,
            // -EncodedCommand（UTF-16LE base64）：指令稿不經命令列的引號跳脫，內容原樣送達（同 WizardSteps 的探測）
            ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
             Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(script))],
            RouteTimeout, null, ct, display: $"powershell.exe （查詢 {ip} 的路由）");
        return HostCheck.ParseRoute(string.Join("\n", r.Lines))?.Alias;
    }

    /// <summary>TCP 連線測試，逾時 5 秒。</summary>
    public static async Task<bool> TcpOpenAsync(string ip, int port, CancellationToken ct)
    {
        if (!IPAddress.TryParse(ip, out var addr)) return false;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TcpTimeout);
        using var client = new TcpClient(AddressFamily.InterNetwork);
        try
        {
            await client.ConnectAsync(addr, port, cts.Token);
            return true;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return false; }
        catch (SocketException) { return false; }
    }

    /// <summary>逐一檢查每個 IP 的路由與（有指定時）連接埠。</summary>
    public static async Task<IReadOnlyList<IpResult>> VerifyAsync(IReadOnlyList<string> ips, int? port, CancellationToken ct)
    {
        var results = new List<IpResult>();
        foreach (var ip in ips)
        {
            ct.ThrowIfCancellationRequested();
            var alias = await RouteInterfaceAsync(ip, ct);
            bool? portOk = port is { } p ? await TcpOpenAsync(ip, p, ct) : null;
            results.Add(new IpResult(ip, alias, HostCheck.IsTunnelInterface(alias), portOk));
        }
        return results;
    }
}
