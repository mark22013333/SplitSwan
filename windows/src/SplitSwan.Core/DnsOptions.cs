using System.Text;
using System.Text.RegularExpressions;

namespace SplitSwan.Core;

/// <summary>
/// 選用的 DNS 分流設定（內部網域、內部 DNS），驗證後產生引擎讀的 options.ini。
/// options.ini 由引擎逐行以 key=value 讀取，值會直接交給 Add-DnsClientNrptRule，
/// 所以只接受固定字元白名單，不可含換行、等號、引號等會改變解析結果的字元。
/// </summary>
public static class DnsOptions
{
    /// <summary>網域最多幾筆（NRPT 規則一筆一個網域，避免誤貼大量內容）。</summary>
    public const int MaxDomains = 10;
    /// <summary>DNS 伺服器最多幾台。</summary>
    public const int MaxDnsServers = 3;

    // 每個標籤 1–63 字、英數與連字號、不可以連字號開頭或結尾；用 [0-9] 而非 \d，避免全形數字通過
    private static readonly Regex LabelRe = new(@"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z", RegexOptions.CultureInvariant);
    private static readonly Regex Ipv4Re = new(@"^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\z", RegexOptions.CultureInvariant);

    /// <summary>把逗號、分號、空白、換行分隔的輸入切成清單（去空白、去空項）。</summary>
    public static IReadOnlyList<string> SplitList(string? input) =>
        (input ?? "").Split([',', ';', ' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim()).Where(x => x.Length > 0).ToList();

    /// <summary>驗證內部網域（可空白）；回傳繁中錯誤清單，空清單＝合法。</summary>
    public static IReadOnlyList<string> ValidateDomains(string? input)
    {
        var errors = new List<string>();
        var items = SplitList(input);
        if (items.Count > MaxDomains) errors.Add($"內部網域最多 {MaxDomains} 個");
        foreach (var raw in items)
        {
            var d = raw.TrimStart('.');
            var ok = d.Length is > 0 and <= 253 && d.Split('.').All(l => LabelRe.IsMatch(l));
            if (!ok) errors.Add($"內部網域格式不正確：{Shorten(raw)}（例：corp.example）");
        }
        return errors;
    }

    /// <summary>驗證內部 DNS（可空白，只接受 IPv4）；回傳繁中錯誤清單，空清單＝合法。</summary>
    public static IReadOnlyList<string> ValidateDnsServers(string? input)
    {
        var errors = new List<string>();
        var items = SplitList(input);
        if (items.Count > MaxDnsServers) errors.Add($"內部 DNS 最多 {MaxDnsServers} 台");
        foreach (var ip in items)
        {
            var m = Ipv4Re.Match(ip);
            if (!m.Success || Enumerable.Range(1, 4).Any(i => int.Parse(m.Groups[i].Value) > 255))
                errors.Add($"內部 DNS 格式不正確：{Shorten(ip)}（只接受 IPv4，例：192.0.2.53）");
        }
        return errors;
    }

    /// <summary>兩欄一起驗證。</summary>
    public static IReadOnlyList<string> Validate(string? domains, string? dnsServers) =>
        [.. ValidateDomains(domains), .. ValidateDnsServers(dnsServers)];

    /// <summary>
    /// 產生 options.ini 內容；兩欄都空白時回傳 null（不需要寫檔）。
    /// 不合法時丟 ArgumentException（避免把未驗證的值寫進引擎會讀的檔案）。
    /// </summary>
    public static string? RenderOptionsIni(string? domains, string? dnsServers)
    {
        var errors = Validate(domains, dnsServers);
        if (errors.Count > 0) throw new ArgumentException(string.Join("；", errors));
        var d = SplitList(domains).Select(x => x.TrimStart('.')).ToList();
        var s = SplitList(dnsServers);
        if (d.Count == 0 && s.Count == 0) return null;
        var sb = new StringBuilder();
        sb.Append("# 由 SplitSwan 托盤 App 產生，請用 App 的「設定」修改\r\n");
        if (d.Count > 0) sb.Append("Domain=").Append(string.Join(",", d)).Append("\r\n");
        if (s.Count > 0) sb.Append("DnsServer=").Append(string.Join(",", s)).Append("\r\n");
        return sb.ToString();
    }

    private static string Shorten(string s) => s.Length <= 40 ? s : s[..40] + "…";
}
