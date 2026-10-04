namespace SplitSwan.Core;

/// <summary>托盤圖示樣式，對應 Mac 版 MenuBarIconStyle（名稱與順序相同）。</summary>
public enum TrayIconStyle { Shield, ShieldCheck, Lock, Key, Network, Tunnel, Nodes, Text }

/// <summary>托盤圖示狀態，對應 Mac 版 IconState。</summary>
public enum TrayIconState { Disconnected, Connected, Connecting, Error }

/// <summary>
/// 托盤圖示樣式表：8 種樣式 × 4 種狀態 → 字型圖示的字元。
/// 字碼全部取自 Microsoft Learn 的官方對照表，且只用 Segoe Fluent Icons（Windows 11）與
/// Segoe MDL2 Assets（Windows 10）**兩套都有**的字碼，托盤可依系統有哪套字型自由選用：
/// https://learn.microsoft.com/en-us/windows/apps/design/iconography/segoe-fluent-icons-font
/// https://learn.microsoft.com/en-us/windows/apps/design/iconography/segoe-ui-symbol-font
/// 註解中的英文是官方表上的圖示名稱；括號內是 Mac 版對應的 SF Symbol。
/// 注意：同一字碼在兩套字型的造型不一定相同（例：E705 VPN 在 Fluent 是盾牌加鎖，在 MDL2 是另一個 VPN 圖形）。
/// </summary>
public static class TrayIconCatalog
{
    /// <summary>樣式的繁中名稱，同 Mac 版 MenuBarIconStyle.title。</summary>
    public static string Title(TrayIconStyle s) => s switch
    {
        TrayIconStyle.Shield => "盾牌鎖",
        TrayIconStyle.ShieldCheck => "盾牌勾",
        TrayIconStyle.Lock => "鎖頭",
        TrayIconStyle.Key => "鑰匙",
        TrayIconStyle.Network => "網路",
        TrayIconStyle.Tunnel => "通道",
        TrayIconStyle.Nodes => "節點",
        TrayIconStyle.Text => "VPN 字樣",
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };

    /// <summary>狀態的繁中名稱，同 Mac 版 IconState.title。</summary>
    public static string StateTitle(TrayIconState st) => st switch
    {
        TrayIconState.Disconnected => "未連線",
        TrayIconState.Connected => "已連線",
        TrayIconState.Connecting => "連線中",
        TrayIconState.Error => "異常",
        _ => throw new ArgumentOutOfRangeException(nameof(st)),
    };

    /// <summary>
    /// 某樣式某狀態的字型圖示字元（單一 BMP 字元的字串）；「VPN 字樣」沒有對應的圖示，回傳 null（由托盤自己畫字）。
    /// </summary>
    public static string? Glyph(TrayIconStyle s, TrayIconState st) => (s, st) switch
    {
        // 盾牌鎖
        (TrayIconStyle.Shield, TrayIconState.Disconnected) => "\uEA18",   // Shield（lock.shield）
        (TrayIconStyle.Shield, TrayIconState.Connected) => "\uE705",      // VPN（lock.shield.fill；Fluent 造型為盾牌加鎖）
        (TrayIconStyle.Shield, TrayIconState.Connecting) => "\uE895",     // Sync（arrow.triangle.2.circlepath）
        (TrayIconStyle.Shield, TrayIconState.Error) => "\uE7BA",          // Warning（exclamationmark.shield）

        // 盾牌勾
        (TrayIconStyle.ShieldCheck, TrayIconState.Disconnected) => "\uEA18", // Shield（shield）
        (TrayIconStyle.ShieldCheck, TrayIconState.Connected) => "\uF0FB",    // DefenderBadge12（checkmark.shield.fill；實心盾牌，沒有勾）
        (TrayIconStyle.ShieldCheck, TrayIconState.Connecting) => "\uF16A",   // ProgressRingDots（circle.dashed）
        (TrayIconStyle.ShieldCheck, TrayIconState.Error) => "\uEA39",        // ErrorBadge（xmark.shield）

        // 鎖頭
        (TrayIconStyle.Lock, TrayIconState.Disconnected) => "\uE785",     // Unlock（lock.open）
        (TrayIconStyle.Lock, TrayIconState.Connected) => "\uE72E",        // Lock（lock.fill）
        (TrayIconStyle.Lock, TrayIconState.Connecting) => "\uE712",       // More（ellipsis.circle）
        (TrayIconStyle.Lock, TrayIconState.Error) => "\uE783",            // Error（exclamationmark.lock）

        // 鑰匙：兩套字型都沒有「實心鑰匙」，已連線改用鎖頭，才能與未連線區分
        (TrayIconStyle.Key, TrayIconState.Disconnected) => "\uE8D7",      // Permissions（key；造型為鑰匙）
        (TrayIconStyle.Key, TrayIconState.Connected) => "\uE72E",         // Lock（key.fill 的替代）
        (TrayIconStyle.Key, TrayIconState.Connecting) => "\uE712",        // More（ellipsis.circle）
        (TrayIconStyle.Key, TrayIconState.Error) => "\uE783",             // Error（key.slash 的替代）

        // 網路
        (TrayIconStyle.Network, TrayIconState.Disconnected) => "\uF384",  // NetworkOffline（network.slash）
        (TrayIconStyle.Network, TrayIconState.Connected) => "\uF385",     // NetworkConnected（network.badge.shield.half.filled）
        (TrayIconStyle.Network, TrayIconState.Connecting) => "\uE774",    // Globe（network）
        (TrayIconStyle.Network, TrayIconState.Error) => "\uE7BA",         // Warning（exclamationmark.triangle）

        // 通道：沒有圓框上下箭頭，未連線用雙向箭頭、已連線用連結
        (TrayIconStyle.Tunnel, TrayIconState.Disconnected) => "\uE8AB",   // Switch（arrow.up.arrow.down.circle）
        (TrayIconStyle.Tunnel, TrayIconState.Connected) => "\uE71B",      // Link（arrow.up.arrow.down.circle.fill 的替代）
        (TrayIconStyle.Tunnel, TrayIconState.Connecting) => "\uF16A",     // ProgressRingDots（circle.dashed）
        (TrayIconStyle.Tunnel, TrayIconState.Error) => "\uE7BA",          // Warning（exclamationmark.triangle）

        // 節點
        (TrayIconStyle.Nodes, TrayIconState.Disconnected) => "\uEF90",    // Flow（point.3.connected.trianglepath.dotted）
        (TrayIconStyle.Nodes, TrayIconState.Connected) => "\uF0B9",       // Connected（point.3.filled.connected.trianglepath.dotted）
        (TrayIconStyle.Nodes, TrayIconState.Connecting) => "\uE712",      // More（ellipsis.circle）
        (TrayIconStyle.Nodes, TrayIconState.Error) => "\uE7BA",           // Warning（exclamationmark.triangle）

        (TrayIconStyle.Text, _) => null,
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };

    /// <summary>從設定字串還原樣式（接受 Mac 的 rawValue，如 "shieldCheck"，不分大小寫）；不認得 → Shield（同 Mac 預設）。</summary>
    public static TrayIconStyle Parse(string? raw)
    {
        if (raw is null) return TrayIconStyle.Shield;
        foreach (var s in Enum.GetValues<TrayIconStyle>())
            if (string.Equals(s.ToString(), raw, StringComparison.OrdinalIgnoreCase)) return s;
        return TrayIconStyle.Shield;
    }
}
