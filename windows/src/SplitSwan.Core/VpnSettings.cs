namespace SplitSwan.Core;

/// <summary>
/// VPN 連線設定（對應 Mac 版 VPNSettings ＋ secrets.conf 裡的 PSK 與密碼）。
/// </summary>
/// <param name="Username">EAP 帳號</param>
/// <param name="Password">EAP 密碼（原文，寫入 secrets.conf 時才跳脫）</param>
/// <param name="Psk">預設共享金鑰（原文）</param>
/// <param name="Gateways">閘道，1..3 台；空字串代表該台未設定（連線名稱依位置編號 vpn1..vpn3，與 Mac 版相同）</param>
/// <param name="RemoteSubnets">要走 VPN 的網段，每筆為 a.b.c.d/n（單一主機請寫 /32，與 Mac 版規則相同）</param>
public sealed record VpnSettings(
    string Username, string Password, string Psk,
    IReadOnlyList<string> Gateways,
    IReadOnlyList<string> RemoteSubnets);
