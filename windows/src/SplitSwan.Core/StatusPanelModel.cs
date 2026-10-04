using System.Globalization;

namespace SplitSwan.Core;

/// <summary>狀態點、chip、成功率條的色調。</summary>
public enum StatusTone { Ok, Warn, Bad, Idle }

/// <summary>狀態面板的主要按鈕。</summary>
public enum PanelPrimary { Connect, Reconnect, Disconnect }

/// <summary>
/// 狀態面板（左鍵托盤圖示）要顯示的內容，純資料。
/// </summary>
/// <param name="Tone">狀態點的色調。</param>
/// <param name="Headline">狀態大字（例「已連線　VPN1」）。</param>
/// <param name="Detail">狀態下方的說明（錯誤原因、重試提示、狀態不明的解釋）；沒有為 null。</param>
/// <param name="ShowFacts">是否顯示「虛擬 IP／已連線／握手耗時」三欄（只有已連線時）。</param>
/// <param name="Primary">主要按鈕的動作。</param>
/// <param name="PrimaryText">主要按鈕文字。</param>
/// <param name="ConnectEnabled">連線類動作（主要按鈕為連線時、閘道子選單的各台）可不可以按：有動作進行中時不行。</param>
/// <param name="DisconnectEnabled">斷線可不可以按（同托盤選單：已連線、想連線或動作進行中）。</param>
/// <param name="DisconnectInMenu">主要按鈕不是斷線、但斷線可用時，把「斷線」放進閘道子選單。</param>
/// <param name="GatewayMenuText">閘道子選單按鈕的文字。</param>
public sealed record StatusPanelModel(
    StatusTone Tone, string Headline, string? Detail, bool ShowFacts,
    PanelPrimary Primary, string PrimaryText, bool ConnectEnabled, bool DisconnectEnabled,
    bool DisconnectInMenu, string GatewayMenuText)
{
    /// <summary>主要按鈕可不可以按。</summary>
    public bool PrimaryEnabled => Primary == PanelPrimary.Disconnect ? DisconnectEnabled : ConnectEnabled;

    /// <param name="gateway">引擎回報的連線名稱（例 vpn1）。</param>
    /// <param name="busyText">動作進行中的文字（例「連線中…」）。</param>
    /// <param name="note">錯誤或重試提示（VpnCoordinator 的 LastError ?? RetryNote）。</param>
    public static StatusPanelModel Build(TrayState state, string? gateway, string? busyText, string? note,
        bool wantConnected, bool busy)
    {
        var disconnectEnabled = state == TrayState.Connected || wantConnected || busy;
        var connectEnabled = !busy;
        var gw = string.IsNullOrWhiteSpace(gateway) ? null : gateway!.Trim().ToUpperInvariant();
        var oneLine = string.IsNullOrWhiteSpace(note) ? null : OneLine(note!);

        (StatusTone tone, string headline, string? detail, PanelPrimary primary) = state switch
        {
            TrayState.Connected => (StatusTone.Ok, gw is null ? "已連線" : "已連線　" + gw, null, PanelPrimary.Disconnect),
            TrayState.Busy => (StatusTone.Warn, string.IsNullOrWhiteSpace(busyText) ? "處理中…" : OneLine(busyText!), null,
                PanelPrimary.Disconnect),
            TrayState.Error => (StatusTone.Bad, "未連上", oneLine, PanelPrimary.Reconnect),
            TrayState.Unknown => (StatusTone.Warn, "狀態不明",
                "暫時查不到 WSL 裡的通道狀態，不代表已斷線。內網連不到時請按「連線」。", PanelPrimary.Connect),
            _ => (StatusTone.Idle, "未連線", null, PanelPrimary.Connect),
        };
        var primaryText = primary switch
        {
            PanelPrimary.Disconnect => "斷線",
            PanelPrimary.Reconnect => "重新連線",
            _ => "連線",
        };
        return new StatusPanelModel(tone, headline, detail, state == TrayState.Connected, primary, primaryText,
            connectEnabled, disconnectEnabled,
            DisconnectInMenu: primary != PanelPrimary.Disconnect && disconnectEnabled,
            GatewayMenuText: state == TrayState.Connected ? "改連到…" : "選擇閘道…");
    }

    private static string OneLine(string s) => s.Replace("\r", " ").Replace("\n", " ").Trim();

    /// <summary>已連線時間：「1:12:08」（時:分:秒，時可超過 24）；負值當 0。</summary>
    public static string FormatElapsed(TimeSpan t)
    {
        if (t < TimeSpan.Zero) t = TimeSpan.Zero;
        var h = (long)t.TotalHours;
        return string.Create(CultureInfo.InvariantCulture, $"{h}:{t.Minutes:00}:{t.Seconds:00}");
    }

    /// <summary>握手耗時：「2.8 秒」；不知道為「—」。</summary>
    public static string FormatSeconds(double? seconds) =>
        seconds is { } s && s >= 0 && !double.IsNaN(s) && !double.IsInfinity(s)
            ? string.Create(CultureInfo.InvariantCulture, $"{s:0.0} 秒")
            : "—";

    /// <summary>某台最近一次成功的耗時（握手耗時欄）；沒有成功紀錄或耗時未知回 null。</summary>
    public static double? LastSuccessSeconds(IReadOnlyList<GatewayAttempt> records)
    {
        ArgumentNullException.ThrowIfNull(records);
        for (var i = records.Count - 1; i >= 0; i--)
            if (records[i].Success) return records[i].Seconds;
        return null;
    }

    /// <summary>
    /// 「走 VPN」的網段 chips：去前後空白、去空白行與重複（保留順序）。
    /// 沒有任何網段時回空清單（呼叫端顯示「尚未設定」）。
    /// </summary>
    public static IReadOnlyList<string> VpnLanes(IEnumerable<string> subnets)
    {
        ArgumentNullException.ThrowIfNull(subnets);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var list = new List<string>();
        foreach (var s in subnets)
        {
            var t = TextRules.TrimWhitespace(s ?? "");
            if (t.Length > 0 && seen.Add(t)) list.Add(t);
        }
        return list;
    }
}

/// <summary>設定頁閘道列的成功率條。</summary>
/// <param name="Ok">成功次數。</param>
/// <param name="Total">紀錄筆數（最多 <see cref="GatewayHistory.KeepPerGateway"/>）。</param>
/// <param name="Fraction">成功率 0～1（沒有紀錄為 0）。</param>
/// <param name="Tone">條的顏色：≥ 80% 為 Ok、其餘 Warn、沒有紀錄 Idle。</param>
/// <param name="Label">「9/10」；沒有紀錄為「—」。</param>
public sealed record GatewayMeter(int Ok, int Total, double Fraction, StatusTone Tone, string Label)
{
    /// <summary>成功率達這個值（含）用綠色。</summary>
    public const double GoodRate = 0.8;

    public static GatewayMeter From(IReadOnlyList<GatewayAttempt> records)
    {
        ArgumentNullException.ThrowIfNull(records);
        var total = records.Count;
        if (total == 0) return new GatewayMeter(0, 0, 0, StatusTone.Idle, "—");
        var ok = records.Count(r => r.Success);
        var f = (double)ok / total;
        return new GatewayMeter(ok, total, f, f >= GoodRate ? StatusTone.Ok : StatusTone.Warn,
            string.Create(CultureInfo.InvariantCulture, $"{ok}/{total}"));
    }

    /// <summary>閘道列前面的狀態點：目前連著這台為 Ok、冷卻中為 Warn、其餘 Idle。</summary>
    public static StatusTone DotTone(bool connectedHere, bool cooling) =>
        connectedHere ? StatusTone.Ok : cooling ? StatusTone.Warn : StatusTone.Idle;
}

/// <summary>首次設定精靈的頁首與「完成／接下來」兩列 chips。</summary>
public static class WizardOverview
{
    /// <summary>大標：「3 / 6　下載 Ubuntu」。</summary>
    public static string Heading(WizardStep current) =>
        string.Create(CultureInfo.InvariantCulture,
            $"{(int)current + 1} / {SetupWizardState.Steps.Count}　{SetupWizardState.Title(current)}");

    /// <summary>
    /// 「完成」＝目前步驟以外已完成（含略過）的步驟；「接下來」＝目前步驟之後尚未完成的步驟。
    /// 目前步驟本身不在任何一列（它在大標）。
    /// </summary>
    public static (IReadOnlyList<WizardStep> Done, IReadOnlyList<WizardStep> Next) Lanes(SetupWizardState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        var cur = state.Current;
        var done = SetupWizardState.Steps.Where(s => s != cur && state.IsFinished(s)).ToList();
        var next = SetupWizardState.Steps.Where(s => s > cur && !state.IsFinished(s)).ToList();
        return (done, next);
    }

    /// <summary>進度條比例：已完成步數 / 總步數（0～1）。</summary>
    public static double Progress(SetupWizardState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        return (double)SetupWizardState.Steps.Count(state.IsFinished) / SetupWizardState.Steps.Count;
    }
}
