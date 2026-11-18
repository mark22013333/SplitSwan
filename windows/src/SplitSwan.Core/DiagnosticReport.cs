using System.Text;
using System.Text.RegularExpressions;

namespace SplitSwan.Core;

/// <summary>診斷報告的一段：一個外部指令（或檔案）的輸出。</summary>
/// <param name="Title">段落標題。</param>
/// <param name="Command">執行的指令（顯示用，不含秘密）；檔案內容時是路徑說明。</param>
/// <param name="Lines">輸出（stdout 與 stderr 合併）。</param>
/// <param name="Status">null＝成功；否則是一行失敗原因（逾時、結束碼、無法執行）。</param>
public sealed record DiagnosticSection(string Title, string Command, IReadOnlyList<string> Lines, string? Status = null);

/// <summary>
/// 診斷報告的遮蔽：報告可以直接傳給維護者，所以公司資訊一律換成標籤。
/// 遮的是「公司的」：密碼、PSK、帳號、閘道、內部 DNS、內部網域、VPN 虛擬 IP、落在設定網段內的位址。
/// 不遮的是診斷需要的：家用網路與 WSL 的位址（判斷網段重疊）、版本號、Windows 介面名稱。
/// 同一個值在整份報告裡換成同一個標籤（例 &lt;內網#2&gt;），讀者仍能對照路由與輸出。
/// </summary>
public sealed class DiagnosticMasker
{
    // 前後只排除「數字」與「數字＋點」（避免切進更長的版本號）；單獨的點要放行：
    // strongSwan 記錄寫成 a[a]...b[b]，句尾也常有句點
    private static readonly Regex IPv4 = new(@"(?<!\d)(?<!\d\.)\d{1,3}(?:\.\d{1,3}){3}(?!\d)(?!\.\d)", RegexOptions.CultureInvariant);

    private readonly string[] _secrets;
    private readonly List<(string Value, string Label)> _literals = [];
    private readonly IReadOnlyList<string> _subnets;
    private readonly Dictionary<string, string> _ipLabels = new(StringComparer.Ordinal);
    private int _internalCount;

    /// <param name="settings">目前的設定（帳密、閘道、網段、DNS、網域）。</param>
    /// <param name="virtualIp">VPN 拿到的虛擬 IP（已連線時），沒有就是 null。</param>
    public DiagnosticMasker(StoredSettings settings, string? virtualIp = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        _secrets = [settings.Password, settings.Psk];
        _subnets = settings.RemoteSubnets;
        for (int i = 0; i < settings.Gateways.Count; i++)
            AddLiteral(settings.Gateways[i], $"<閘道{i + 1}>");
        var dns = DnsOptions.SplitList(settings.DnsServer);
        for (int i = 0; i < dns.Count; i++) AddLiteral(dns[i], $"<內部DNS{i + 1}>");
        var domains = DnsOptions.SplitList(settings.Domain);
        for (int i = 0; i < domains.Count; i++) AddLiteral(domains[i], $"<內部網域{i + 1}>");
        if (HostCheck.IsIPv4(virtualIp)) AddLiteral(virtualIp!, "<虛擬IP>");
        // 帳號放最後：它可能是閘道或網域的一部分，先換掉長的標的
        AddLiteral(settings.Username, "<帳號>");
    }

    private void AddLiteral(string? value, string label)
    {
        var v = value?.Trim() ?? "";
        if (v.Length < 3 || _literals.Any(l => string.Equals(l.Value, v, StringComparison.OrdinalIgnoreCase))) return;
        if (HostCheck.IsIPv4(v)) _ipLabels[v] = label;
        else _literals.Add((v, label));
    }

    /// <summary>遮蔽一行（或多行）文字。</summary>
    public string Mask(string? text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var s = LogHygiene.Redact(text, _secrets);
        foreach (var (value, label) in _literals.OrderByDescending(l => l.Value.Length))
            s = s.Replace(value, label, StringComparison.OrdinalIgnoreCase);
        return IPv4.Replace(s, m => LabelFor(m.Value));
    }

    private string LabelFor(string ip)
    {
        if (_ipLabels.TryGetValue(ip, out var label)) return label;
        if (HostCheck.ParseIPv4(ip) is null || HostCheck.CoveringSubnet(ip, _subnets) is null) return ip;
        label = $"<內網#{++_internalCount}>";
        _ipLabels[ip] = label;
        return label;
    }
}

/// <summary>診斷報告的組字（純函式）。收集在托盤的 DiagnosticRunner。</summary>
public static class DiagnosticReport
{
    /// <summary>報告檔名，例 SplitSwan-診斷-20261118-142530.txt。</summary>
    public static string FileName(DateTime now) => $"SplitSwan-診斷-{now:yyyyMMdd-HHmmss}.txt";

    /// <summary>組出整份報告；每一行（含標題與指令）都經過 masker，這是唯一應該寫進檔案的版本。</summary>
    /// <param name="header">開頭的摘要行（版本、系統、狀態）。</param>
    public static string Build(IEnumerable<string> header, IEnumerable<DiagnosticSection> sections, DiagnosticMasker masker)
    {
        ArgumentNullException.ThrowIfNull(masker);
        var sb = new StringBuilder();
        void Line(string s) => sb.Append(masker.Mask(s)).Append("\r\n");
        Line("SplitSwan for Windows 診斷報告");
        Line("公司位址、帳號、密碼與 PSK 已遮蔽成 <…> 標籤；家用網路、WSL 位址與版本號保留原樣以便判斷問題。");
        Line("");
        foreach (var h in header) Line(h);
        foreach (var sec in sections)
        {
            Line("");
            Line($"===== {sec.Title} =====");
            Line($"> {sec.Command}");
            foreach (var l in sec.Lines) Line(l);
            if (sec.Status is not null) Line($"（{sec.Status}）");
            else if (sec.Lines.Count == 0) Line("（沒有輸出）");
        }
        return sb.ToString();
    }

    /// <summary>只留最後 n 行（記錄檔可能很長）。</summary>
    public static IReadOnlyList<string> Tail(IReadOnlyList<string> lines, int n) =>
        lines.Count <= n ? lines : lines.Skip(lines.Count - n).ToList();
}
