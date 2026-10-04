using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SplitSwan.Core;

/// <summary>一次「嘗試連某一台閘道」的結果（移植 Mac 版 GatewayAttempt）。</summary>
/// <param name="Gateway">閘道編號，1 起算（VPN1 = 1）。</param>
/// <param name="Success">是否連上。</param>
/// <param name="At">嘗試的時間。</param>
/// <param name="Seconds">耗時；不知道時為 null（連上後被踢、卡在連線中補記的失敗），不算進平均耗時。</param>
/// <param name="Address">當時的閘道位址；位址改了，舊紀錄就沒有參考價值（見 <see cref="GatewayHistory.Pruned"/>）。null 視同空字串。</param>
public sealed record GatewayAttempt(int Gateway, bool Success, DateTimeOffset At, double? Seconds, string? Address);

/// <summary>
/// F4 依連線紀錄選閘道：逐條移植 Mac 版 Sources/GatewayHistory.swift。
/// 記錄每次逐台嘗試的結果，自動輪替依過去的實際連線結果排序。純資料與純邏輯，不碰系統狀態。
/// 非執行緒安全：呼叫端（托盤）要在同一條執行緒上使用。
/// </summary>
public sealed class GatewayHistory
{
    /// <summary>每台只保留最近幾筆。</summary>
    public const int KeepPerGateway = 10;

    /// <summary>失敗後多久內算「冷卻中」（600 秒）。</summary>
    public static readonly TimeSpan Cooldown = TimeSpan.FromSeconds(600);

    // 依加入先後排列（新的在後），同 Swift 的 attempts
    private readonly List<GatewayAttempt> _attempts = [];

    /// <summary>全部紀錄，依加入先後排列（新的在後）。</summary>
    public IReadOnlyList<GatewayAttempt> Attempts => _attempts.AsReadOnly();

    // ── 讀寫 ──────────────────────────────────────────────

    /// <summary>加入一筆；同一台超過 <see cref="KeepPerGateway"/> 筆時，從該台最舊的開始丟。</summary>
    public void Record(GatewayAttempt a)
    {
        ArgumentNullException.ThrowIfNull(a);
        _attempts.Add(a);
        var mine = _attempts.Count(x => x.Gateway == a.Gateway);
        if (mine <= KeepPerGateway) return;
        var drop = mine - KeepPerGateway;
        _attempts.RemoveAll(x =>
        {
            if (drop <= 0 || x.Gateway != a.Gateway) return false;
            drop--;
            return true;
        });
    }

    /// <summary>清除某一台的紀錄。</summary>
    public void Clear(int gateway) => _attempts.RemoveAll(x => x.Gateway == gateway);

    /// <summary>清除全部紀錄（設定頁「清除閘道連線紀錄」）。</summary>
    public void RemoveAll() => _attempts.Clear();

    /// <summary>
    /// 回傳新的歷史，移除「位址跟目前設定不同」的紀錄（位址被修改、或閘道被清空、或編號超出設定清單）。
    /// gateways 為 0 起算的設定清單；比對時去掉前後空白並忽略大小寫（同 Swift）。
    /// </summary>
    public GatewayHistory Pruned(IReadOnlyList<string> gateways)
    {
        ArgumentNullException.ThrowIfNull(gateways);
        var h = new GatewayHistory();
        foreach (var a in _attempts)
        {
            var i = a.Gateway - 1;
            if (i < 0 || i >= gateways.Count) continue;
            if (Norm(gateways[i]) != Norm(a.Address)) continue;
            h._attempts.Add(a);
        }
        return h;
    }

    private static string Norm(string? s) => TextRules.TrimWhitespace(s ?? "").ToLowerInvariant();

    // ── 查詢 ──────────────────────────────────────────────

    /// <summary>某一台的紀錄（舊的在前）。</summary>
    public IReadOnlyList<GatewayAttempt> Records(int n) => _attempts.Where(x => x.Gateway == n).ToList();

    /// <summary>上次成功連上的閘道（所有紀錄中最新的一筆成功）；沒有回傳 null。</summary>
    public int? LastSuccess
    {
        get
        {
            for (var i = _attempts.Count - 1; i >= 0; i--)
                if (_attempts[i].Success) return _attempts[i].Gateway;
            return null;
        }
    }

    /// <summary>冷卻中：該台有任何一筆失敗發生在 now 之前不到 <see cref="Cooldown"/>（時間在未來的失敗也算，同 Swift）。</summary>
    public bool IsCooling(int n, DateTimeOffset now) =>
        _attempts.Any(x => x.Gateway == n && !x.Success && now - x.At < Cooldown);

    /// <summary>成功率（0～1）；沒有紀錄回傳 null。</summary>
    public double? SuccessRate(int n)
    {
        int total = 0, ok = 0;
        foreach (var x in _attempts)
        {
            if (x.Gateway != n) continue;
            total++;
            if (x.Success) ok++;
        }
        return total == 0 ? null : (double)ok / total;
    }

    /// <summary>平均耗時，只算成功且知道耗時的那幾筆；沒有這種紀錄回傳 null。</summary>
    public double? AverageSuccessSeconds(int n)
    {
        double sum = 0;
        var count = 0;
        foreach (var x in _attempts)
        {
            if (x.Gateway != n || !x.Success || x.Seconds is not { } s) continue;
            sum += s;   // 依加入先後累加，與 Swift 的 reduce 順序相同
            count++;
        }
        return count == 0 ? null : sum / count;
    }

    /// <summary>從最新一筆往回數的連續失敗次數。</summary>
    public int ConsecutiveFailures(int n)
    {
        var c = 0;
        for (var i = _attempts.Count - 1; i >= 0; i--)
        {
            if (_attempts[i].Gateway != n) continue;
            if (_attempts[i].Success) break;
            c++;
        }
        return c;
    }

    // ── 要不要記錄 ────────────────────────────────────────

    /// <summary>連線名稱（例：vpn2）→ 閘道編號 2；不分大小寫；認不出來或不在 1～3 回傳 null。</summary>
    public static int? GatewayFromConnection(string? c)
    {
        if (c is null) return null;
        var s = c.ToLowerInvariant();
        if (!s.StartsWith("vpn", StringComparison.Ordinal)) return null;
        var n = ParseSwiftInt(s[3..]);
        return n is >= 1 and <= 3 ? n : null;
    }

    /// <summary>等同 Swift 的 Int(String)：可有一個 + 或 - 號，之後只能是 ASCII 數字；溢位或空字串回傳 null。</summary>
    private static int? ParseSwiftInt(string t)
    {
        var i = 0;
        var neg = false;
        if (t.Length > 0 && (t[0] == '+' || t[0] == '-')) { neg = t[0] == '-'; i = 1; }
        if (i >= t.Length) return null;
        long v = 0;
        for (; i < t.Length; i++)
        {
            var ch = t[i];
            if (ch < '0' || ch > '9') return null;
            v = v * 10 + (ch - '0');
            if (v > (long)int.MaxValue + 1) return null;   // 超出範圍：反正不是 1～3
        }
        v = neg ? -v : v;
        return v is < int.MinValue or > int.MaxValue ? null : (int)v;
    }

    /// <summary>
    /// 一次嘗試的結果要不要記錄（同 Swift）。成功一律記；失敗只在「原因確定在閘道」時才記：
    /// interrupted（執行中按了斷線、或網路中途斷掉）→ 不記；
    /// 輸出沒有獨立一行「fail vpnN」（前後空白不計）→ 不記（例：權限或輔助程式問題，不是閘道的問題）。
    /// </summary>
    public static bool ShouldRecord(int n, bool success, string output, bool interrupted)
    {
        if (success) return true;
        if (interrupted) return false;
        var want = "fail vpn" + n.ToString(CultureInfo.InvariantCulture);
        foreach (var line in TextRules.SplitOmitEmpty(output ?? "", NewlineChars))
            if (TextRules.TrimWhitespace(line) == want) return true;
        return false;
    }

    // Swift Character.isNewline 涵蓋的字元
    private static readonly char[] NewlineChars = ['\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];

    // ── 排序 ──────────────────────────────────────────────

    /// <summary>
    /// 自動輪替的嘗試順序（回傳 1 起算的閘道編號），前面的規則優先（同 Swift）：
    /// a. 冷卻中（10 分鐘內失敗過）的排到最後，仍會嘗試；冷卻中的彼此之間照 c、d 排；
    /// b. 上次成功連上的閘道排第一（不在冷卻中才算）；
    /// c. 其餘依最近 10 次的成功率由高到低，同分時成功那幾筆的平均耗時短的在前（沒成功過視為最慢），再照設定順序；
    /// d. 沒有紀錄的排在有成功紀錄的後面，照設定順序；成功率為 0（有紀錄、全部失敗）的排在沒有紀錄的後面；
    /// e. 未設定（空白）的閘道略過。
    /// </summary>
    public static IReadOnlyList<int> Order(IReadOnlyList<string> gateways, GatewayHistory h, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(gateways);
        ArgumentNullException.ThrowIfNull(h);
        var configured = new List<int>();
        for (var i = 0; i < gateways.Count; i++)
            if (TextRules.TrimWhitespace(gateways[i] ?? "").Length > 0) configured.Add(i + 1);
        var last = h.LastSuccess;

        // c、d：成功率高 → 平均耗時短（沒成功過視為最慢）→ 設定順序
        bool ByRecord(int x, int y)
        {
            var rx = h.SuccessRate(x);
            var ry = h.SuccessRate(y);
            if (rx is null && ry is null) return x < y;
            if (rx is null) return false;
            if (ry is null) return true;
            if (rx.Value != ry.Value) return rx.Value > ry.Value;
            var tx = h.AverageSuccessSeconds(x) ?? double.PositiveInfinity;
            var ty = h.AverageSuccessSeconds(y) ?? double.PositiveInfinity;
            if (tx != ty) return tx < ty;
            return x < y;
        }
        List<int> Sorted(IEnumerable<int> xs)
        {
            var l = xs.ToList();
            // ByRecord 是全序（最後以編號分勝負），排序結果唯一，與 Swift sorted(by:) 相同
            l.Sort((x, y) => ByRecord(x, y) ? -1 : ByRecord(y, x) ? 1 : 0);
            return l;
        }

        var cooling = configured.Where(n => h.IsCooling(n, now)).ToList();
        var normal = configured.Where(n => !cooling.Contains(n)).ToList();
        var first = normal.Where(n => n == last);
        var rest = normal.Where(n => n != last).ToList();
        var succeeded = Sorted(rest.Where(n => (h.SuccessRate(n) ?? 0) > 0));
        var unknown = rest.Where(n => h.SuccessRate(n) is null);
        var allFailed = Sorted(rest.Where(n => h.SuccessRate(n) == 0));
        return [.. first, .. succeeded, .. unknown, .. allFailed, .. Sorted(cooling)];
    }

    // ── 顯示文字 ──────────────────────────────────────────

    /// <summary>最近狀態，例：「上次 3.2 秒連上」、「最近 3 次失敗」；沒有紀錄回傳 null。</summary>
    public string? Detail(int n)
    {
        GatewayAttempt? latest = null;
        for (var i = _attempts.Count - 1; i >= 0 && latest is null; i--)
            if (_attempts[i].Gateway == n) latest = _attempts[i];
        if (latest is null) return null;
        if (latest.Success)
            return latest.Seconds is { } secs
                ? $"上次 {secs.ToString("F1", CultureInfo.InvariantCulture)} 秒連上"
                : "上次連上";
        return $"最近 {ConsecutiveFailures(n)} 次失敗";
    }

    /// <summary>例：「VPN2 · 上次 3.2 秒連上」、「VPN1 · 最近 3 次失敗」；沒有紀錄時只有「VPN1」。</summary>
    public string StatusText(int n)
    {
        var d = Detail(n);
        var name = "VPN" + n.ToString(CultureInfo.InvariantCulture);
        return d is null ? name : $"{name} · {d}";
    }

    // ── 存檔（Windows 自己的格式，不需與 Mac 相容）─────────

    private sealed class Dto
    {
        [JsonPropertyName("attempts")] public List<AttemptDto?>? Attempts { get; set; }
    }

    private sealed class AttemptDto
    {
        [JsonPropertyName("gateway")] public int Gateway { get; set; }
        [JsonPropertyName("address")] public string? Address { get; set; }
        [JsonPropertyName("success")] public bool Success { get; set; }
        [JsonPropertyName("seconds")] public double? Seconds { get; set; }
        [JsonPropertyName("time")] public DateTimeOffset Time { get; set; }
    }

    /// <summary>序列化成 JSON（存 %LOCALAPPDATA%\SplitSwan\gateway-history.json 用）。</summary>
    public string ToJson() => JsonSerializer.Serialize(new Dto
    {
        Attempts = _attempts.Select(a => (AttemptDto?)new AttemptDto
        {
            Gateway = a.Gateway, Address = a.Address, Success = a.Success, Seconds = a.Seconds, Time = a.At,
        }).ToList(),
    });

    /// <summary>
    /// 從 JSON 還原；null、空字串、格式錯、任何一筆壞掉（null 項目、型別不符、秒數為負或非有限數）都回傳空歷史，
    /// 不丟例外（同 Swift decode 失敗回空紀錄）。還原時逐筆經過 <see cref="Record"/>，所以每台最多保留 10 筆。
    /// </summary>
    public static GatewayHistory FromJson(string? json)
    {
        var h = new GatewayHistory();
        if (string.IsNullOrWhiteSpace(json)) return h;
        try
        {
            var dto = JsonSerializer.Deserialize<Dto>(json);
            if (dto?.Attempts is null) return new GatewayHistory();
            foreach (var a in dto.Attempts)
            {
                if (a is null) return new GatewayHistory();
                if (a.Seconds is { } s && (!double.IsFinite(s) || s < 0)) return new GatewayHistory();
                h.Record(new GatewayAttempt(a.Gateway, a.Success, a.Time, a.Seconds, a.Address));
            }
            return h;
        }
        catch (Exception e) when (e is JsonException or NotSupportedException or ArgumentException or InvalidOperationException)
        {
            return new GatewayHistory();
        }
    }
}
