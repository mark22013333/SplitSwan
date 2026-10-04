using System.Globalization;

namespace SplitSwan.Core;

/// <summary>
/// 托盤 App 的閘道選擇與歷史記錄規則（F4，對應 Mac 版 VPNController 的 connect／recordAttempt／recordLateFailure）。
/// 純邏輯：不讀寫檔案、不碰系統狀態，方便在 macOS 上測試。
/// </summary>
public static class GatewayRecorder
{
    /// <summary>連上不到這麼久就被 brief 確定 down：視為該台失敗（同 Mac 版 60 秒）。</summary>
    public static readonly TimeSpan KickedWithin = TimeSpan.FromSeconds(60);

    /// <summary>
    /// 這次 connect 要嘗試的順序（1 起算）。
    /// target 為 null＝自動選擇：依 <see cref="GatewayHistory.Order"/>；
    /// 指定某台＝只試那一台；那台沒有設定（空白或超出清單）時回空清單（呼叫端改用自動或報錯）。
    /// </summary>
    public static IReadOnlyList<int> ResolveOrder(int? target, IReadOnlyList<string> gateways, GatewayHistory history, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(gateways);
        ArgumentNullException.ThrowIfNull(history);
        if (target is null) return GatewayHistory.Order(gateways, history, now);
        return IsConfigured(target.Value, gateways) ? [target.Value] : [];
    }

    /// <summary>第 n 台（1 起算）有沒有設定位址。</summary>
    public static bool IsConfigured(int n, IReadOnlyList<string> gateways)
    {
        ArgumentNullException.ThrowIfNull(gateways);
        return n >= 1 && n <= gateways.Count && TextRules.TrimWhitespace(gateways[n - 1] ?? "").Length > 0;
    }

    /// <summary>第 n 台的位址（去前後空白）；沒有回傳空字串。</summary>
    public static string AddressOf(int n, IReadOnlyList<string> gateways)
    {
        ArgumentNullException.ThrowIfNull(gateways);
        return n >= 1 && n <= gateways.Count ? TextRules.TrimWhitespace(gateways[n - 1] ?? "") : "";
    }

    /// <summary>
    /// 引擎 connect 逐台回報的 @@ATTEMPT → 要寫進歷史的紀錄（契約「第二階段補充」）：
    /// - ok → 記成功（含秒數）；
    /// - fail → 用合成輸出 "fail vpnN\n摘要" 呼叫 <see cref="GatewayHistory.ShouldRecord"/>（interrupted＝使用者中途斷線等），回 true 才記失敗；
    /// - 沒有任何 @@ATTEMPT（設定錯、WSL 未安裝等整體失敗）→ 不記任何閘道。
    /// 編號超出設定清單或該台沒有位址的行略過（位址是比對紀錄是否過期的依據）。
    /// </summary>
    public static IReadOnlyList<GatewayAttempt> FromEngine(
        IReadOnlyList<EngineAttempts.Attempt> attempts, IReadOnlyList<string> gateways, DateTimeOffset now, bool interrupted)
    {
        ArgumentNullException.ThrowIfNull(attempts);
        ArgumentNullException.ThrowIfNull(gateways);
        var list = new List<GatewayAttempt>();
        foreach (var a in attempts)
        {
            if (!IsConfigured(a.Gateway, gateways)) continue;
            var output = a.Success ? "" : $"fail vpn{a.Gateway.ToString(CultureInfo.InvariantCulture)}\n{a.Summary}";
            if (!GatewayHistory.ShouldRecord(a.Gateway, a.Success, output, interrupted)) continue;
            list.Add(new GatewayAttempt(a.Gateway, a.Success, now, a.Seconds, AddressOf(a.Gateway, gateways)));
        }
        return list;
    }

    /// <summary>
    /// 連上不到 60 秒就被 brief「確定 down」（例：被閘道踢掉）→ 替那台補記一筆失敗（秒數未知），
    /// 否則它會一直是「上次成功」、不進冷卻（同 Mac 版 recordLateFailure）。
    /// 只在網路正常、知道是哪一台（connection 為 vpnN）且該台仍有設定時才記；其餘回 null。
    /// brief 查不到（unknown）不算 down，呼叫端不可用它觸發。
    /// </summary>
    /// <param name="connection">掉線前最後一次知道的連線名稱（@@GATEWAY，例 vpn2）。</param>
    /// <param name="upFor">從連上到確定 down 的時間。</param>
    public static GatewayAttempt? LateFailure(string? connection, IReadOnlyList<string> gateways, DateTimeOffset now,
        TimeSpan upFor, bool networkAvailable)
    {
        ArgumentNullException.ThrowIfNull(gateways);
        if (!networkAvailable || upFor >= KickedWithin || upFor < TimeSpan.Zero) return null;
        if (GatewayHistory.GatewayFromConnection(connection) is not { } n || !IsConfigured(n, gateways)) return null;
        return new GatewayAttempt(n, false, now, null, AddressOf(n, gateways));
    }

    /// <summary>選單上某一台的文字，例：「連線 VPN2（203.0.113.2） · 上次 3.2 秒連上」（同 Mac 版選單）。</summary>
    public static string MenuTitle(int n, IReadOnlyList<string> gateways, GatewayHistory history)
    {
        ArgumentNullException.ThrowIfNull(history);
        var addr = AddressOf(n, gateways);
        var name = "VPN" + n.ToString(CultureInfo.InvariantCulture);
        var head = addr.Length == 0 ? $"連線 {name}（未設定）" : $"連線 {name}（{addr}）";
        return history.Detail(n) is { } d ? $"{head} · {d}" : head;
    }

    /// <summary>log 用的順序文字，例：「VPN2 → VPN1 → VPN3」。</summary>
    public static string DescribeOrder(IReadOnlyList<int> order)
    {
        ArgumentNullException.ThrowIfNull(order);
        return string.Join(" → ", order.Select(n => "VPN" + n.ToString(CultureInfo.InvariantCulture)));
    }
}
