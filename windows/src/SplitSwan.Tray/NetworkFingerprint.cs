using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace SplitSwan.Tray;

/// <summary>
/// 「實體網路」的指紋：有預設閘道、狀態為 Up 的非虛擬網卡，與它們的 IPv4 位址。
/// 用來判斷「真的換了網路」：WSL VM 開關、VPN 自己的路由變化只動到 vEthernet／Hyper-V 虛擬網卡，指紋不變。
/// 空字串＝沒有可用的實體網路。
/// </summary>
internal static class NetworkFingerprint
{
    public static string Current()
    {
        try
        {
            var parts = new List<string>();
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
                if (IsVirtual(nic)) continue;
                var props = nic.GetIPProperties();
                // 沒有預設閘道的網卡不是對外的路（例如只連到 VM 的內部網卡）
                if (!props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork
                                                     && !g.Address.Equals(System.Net.IPAddress.Any)))
                    continue;
                var v4 = props.UnicastAddresses
                    .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                    .Select(a => a.Address.ToString())
                    .OrderBy(a => a, StringComparer.Ordinal);
                parts.Add($"{nic.Id}={string.Join(",", v4)}");
            }
            parts.Sort(StringComparer.Ordinal);
            return string.Join(";", parts);
        }
        catch (NetworkInformationException)
        {
            // 查不到時當成「有網路、沒變化」，不觸發任何動作
            return "unknown";
        }
    }

    /// <summary>
    /// 有沒有網路：有實體網卡指紋就算有；沒有時退回系統的判斷。
    /// 寧可誤判成「有網路」（頂多多一次失敗的重連），也不要誤判成「沒網路」（會永遠暫停自動重連與掉線計時）。
    /// </summary>
    public static bool IsAvailable(string fingerprint)
    {
        if (fingerprint.Length > 0) return true;
        try { return NetworkInterface.GetIsNetworkAvailable(); }
        catch (NetworkInformationException) { return true; }
    }

    private static bool IsVirtual(NetworkInterface nic) =>
        nic.Name.StartsWith("vEthernet", StringComparison.OrdinalIgnoreCase)
        || nic.Description.Contains("Hyper-V", StringComparison.OrdinalIgnoreCase)
        || nic.Description.Contains("Virtual", StringComparison.OrdinalIgnoreCase)
        || nic.Description.Contains("WSL", StringComparison.OrdinalIgnoreCase);
}
