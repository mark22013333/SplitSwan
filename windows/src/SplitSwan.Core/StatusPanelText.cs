using System.Globalization;

namespace SplitSwan.Core;

/// <summary>
/// 狀態面板精簡版（第四階段）的文字：網段摘要、通道流量、狀態更新時間。純函式，方便在 macOS 上測試。
/// </summary>
public static class StatusPanelText
{
    /// <summary>三欄數值第三欄的標題：最近一次成功連線的耗時。</summary>
    public const string HandshakeCaption = "握手耗時";

    /// <summary>「握手耗時」的 tooltip。</summary>
    public const string HandshakeTip = "從送出連線請求到 VPN 握手完成的時間";

    /// <summary>已連線時間只是下限（通道是輪詢時才看到的，例如 SplitSwan 開啟前就連著）時的 tooltip。</summary>
    public const string ApproximateSinceTip = "SplitSwan 開啟前就已連線，實際時間更長";

    /// <summary>已連線時間欄：approximate（只是下限）時前面加「≥ 」。</summary>
    public static string ConnectedSince(string elapsed, bool approximate) =>
        approximate ? "≥ " + elapsed : elapsed;

    /// <summary>
    /// 網段摘要一行，例「15 個網段走 VPN（1 段內網、14 台主機）」。
    /// /32（或沒寫前綴長度的單一位址）算主機，其他算網段；先經 <see cref="StatusPanelModel.VpnLanes"/> 去空白與重複。
    /// 沒有任何網段時回「尚未設定內網網段」。
    /// </summary>
    public static string SubnetSummary(IEnumerable<string> subnets)
    {
        ArgumentNullException.ThrowIfNull(subnets);
        var lanes = StatusPanelModel.VpnLanes(subnets);
        if (lanes.Count == 0) return "尚未設定內網網段";
        var hosts = lanes.Count(IsHost);
        var nets = lanes.Count - hosts;
        var parts = new List<string>(2);
        if (nets > 0) parts.Add(string.Create(CultureInfo.InvariantCulture, $"{nets} 段內網"));
        if (hosts > 0) parts.Add(string.Create(CultureInfo.InvariantCulture, $"{hosts} 台主機"));
        return string.Create(CultureInfo.InvariantCulture, $"{lanes.Count} 個網段走 VPN（{string.Join("、", parts)}）");
    }

    /// <summary>單一主機：前綴長度為 32，或沒有寫前綴長度。</summary>
    private static bool IsHost(string cidr)
    {
        var slash = cidr.IndexOf('/');
        return slash < 0 || cidr[(slash + 1)..].Trim() == "32";
    }

    /// <summary>
    /// 位元組數：小於 1024 為「386 B」，其餘以 1024 進位、一位小數：「1.2 KB」「8.4 MB」「1.0 GB」（最大單位 GB）。
    /// 負值當 0。數字格式固定 InvariantCulture（小數點為「.」）。
    /// </summary>
    public static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return string.Create(CultureInfo.InvariantCulture, $"{Math.Max(0, bytes)} B");
        string[] units = ["KB", "MB", "GB"];
        double v = bytes;
        var i = -1;
        do { v /= 1024; i++; } while (v >= 1024 && i < units.Length - 1);
        // 四捨五入後若進位到 1024.0（例 1048575 B），改用下一個單位
        if (Math.Round(v, 1) >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
        return string.Create(CultureInfo.InvariantCulture, $"{v:0.0} {units[i]}");
    }

    /// <summary>
    /// 通道流量一行：「↑ 送出 1.2 MB　↓ 收到 8.4 MB」。兩個值都沒有回 null（不顯示）；只缺一個時那一邊顯示「—」。
    /// </summary>
    public static string? TrafficLine(long? bytesIn, long? bytesOut)
    {
        if (bytesIn is null && bytesOut is null) return null;
        var sent = bytesOut is { } o ? FormatBytes(o) : "—";
        var recv = bytesIn is { } i ? FormatBytes(i) : "—";
        return $"↑ 送出 {sent}　↓ 收到 {recv}";
    }

    /// <summary>
    /// 狀態更新時間。lastSure＝最後一次拿到確定結果（up／down）的時間；unknownNow＝最近一次查詢查不到。
    /// <list type="bullet">
    /// <item>查得到：「狀態更新：剛剛」（未滿 1 秒）、「狀態更新：N 秒前」「狀態更新：N 分鐘前」「狀態更新：N 小時前」。</item>
    /// <item>查不到：「已 N 秒查不到狀態」「已 N 分鐘查不到狀態」「已 N 小時查不到狀態」（從最後一次確定結果起算）；
    ///   從來沒有確定結果時為「查不到狀態」。</item>
    /// <item>還沒有任何結果、也不是查不到：「正在確認狀態…」。</item>
    /// </list>
    /// 時間倒退（時鐘調整）時當 0 秒。
    /// </summary>
    public static string Freshness(DateTimeOffset? lastSure, DateTimeOffset now, bool unknownNow)
    {
        if (lastSure is not { } at) return unknownNow ? "查不到狀態" : "正在確認狀態…";
        var age = now - at;
        if (age < TimeSpan.Zero) age = TimeSpan.Zero;
        var span = Span(age);
        if (unknownNow) return age < TimeSpan.FromSeconds(1) ? "查不到狀態" : $"已 {span}查不到狀態";
        return age < TimeSpan.FromSeconds(1) ? "狀態更新：剛剛" : $"狀態更新：{span}前";
    }

    /// <summary>「5 秒」「3 分鐘」「2 小時」（無條件捨去），後面帶一個空白方便接字。</summary>
    private static string Span(TimeSpan age)
    {
        if (age < TimeSpan.FromMinutes(1)) return string.Create(CultureInfo.InvariantCulture, $"{(long)age.TotalSeconds} 秒");
        if (age < TimeSpan.FromHours(1)) return string.Create(CultureInfo.InvariantCulture, $"{(long)age.TotalMinutes} 分鐘");
        return string.Create(CultureInfo.InvariantCulture, $"{(long)age.TotalHours} 小時");
    }
}

/// <summary>
/// 從 brief 輸出取通道流量（契約 1 第四階段補充）：@@BYTESIN／@@BYTESOUT，單位位元組。
/// 舊版引擎沒有這兩行；缺值或不是純 ASCII 數字（含全形數字、負號、空白）一律為 null，不以 0 冒充。
/// </summary>
public static class TrafficBytes
{
    public static (long? In, long? Out) From(IReadOnlyDictionary<string, string> kv)
    {
        ArgumentNullException.ThrowIfNull(kv);
        return (Read(kv, "BYTESIN"), Read(kv, "BYTESOUT"));
    }

    private static long? Read(IReadOnlyDictionary<string, string> kv, string key)
    {
        if (!kv.TryGetValue(key, out var s) || s.Length == 0) return null;
        foreach (var c in s)
            if (c is < '0' or > '9') return null;
        return long.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : null;
    }
}
