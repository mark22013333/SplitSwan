namespace SplitSwan.Core;

/// <summary>托盤 App 的顯示狀態。</summary>
public enum TrayState
{
    /// <summary>未連線（使用者沒有要連）</summary>
    Disconnected,
    /// <summary>連線中／斷線中（有引擎動作在跑）</summary>
    Busy,
    /// <summary>已連線</summary>
    Connected,
    /// <summary>想連線但沒連上，或上一次動作失敗</summary>
    Error,
    /// <summary>連續查不到通道狀態（brief 失敗／逾時）；不代表斷線，沿用上次狀態</summary>
    Unknown,
}

/// <summary>托盤 App 的文字（tooltip、狀態列、通知），純函式方便測試。</summary>
public static class TrayText
{
    /// <summary>NotifyIcon.Text 的上限（超過會丟 ArgumentOutOfRangeException）。</summary>
    public const int TooltipMax = 127;

    /// <summary>
    /// 斷線通知內文：自動重連開啟時沿用 Mac 版文字（DropDetector.DropBody，「正在自動重連」）；
    /// 關閉時改成請使用者手動重新連線，不可宣稱正在重連。
    /// </summary>
    public static string DropBody(TimeSpan threshold, bool autoReconnect) =>
        autoReconnect
            ? DropDetector.DropBody(threshold)
            : $"VPN 中斷超過 {(int)threshold.TotalSeconds} 秒，請從托盤選單按「連線」重新連線";

    /// <summary>連續查不到狀態、剛標成「狀態不明」時的通知（每段狀態不明只發一次）。</summary>
    public const string StateUnknownTitle = "暫時查不到 VPN 狀態";
    public const string StateUnknownBody = "暫時查不到 VPN 狀態，如果內網連不到，請按「連線」";

    /// <summary>狀態列（選單第一行）的文字。</summary>
    public static string StatusLine(TrayState state, string? gateway, string? vip, string? busyText, string? error)
    {
        return state switch
        {
            TrayState.Connected => "已連線" + Detail(gateway, vip),
            TrayState.Busy => string.IsNullOrWhiteSpace(busyText) ? "處理中…" : busyText!,
            TrayState.Error => string.IsNullOrWhiteSpace(error) ? "未連上" : "未連上：" + OneLine(error!),
            TrayState.Unknown => "狀態不明（暫時查不到 WSL 裡的通道狀態，不代表已斷線）",
            _ => "未連線",
        };
    }

    /// <summary>tooltip：App 名稱＋狀態，截到 127 字以內。結束 App 不會斷線，所以不另外提示。</summary>
    public static string Tooltip(string app, TrayState state, string? gateway, string? vip, string? busyText, string? error)
    {
        var text = $"{app}：{StatusLine(state, gateway, vip, busyText, error)}";
        return text.Length <= TooltipMax ? text : text[..(TooltipMax - 1)] + "…";
    }

    private static string Detail(string? gateway, string? vip)
    {
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(gateway)) parts.Add(gateway!.ToUpperInvariant());
        if (!string.IsNullOrWhiteSpace(vip)) parts.Add("虛擬 IP " + vip);
        return parts.Count == 0 ? "" : $"（{string.Join("，", parts)}）";
    }

    private static string OneLine(string s) => s.Replace("\r", " ").Replace("\n", " ").Trim();
}
