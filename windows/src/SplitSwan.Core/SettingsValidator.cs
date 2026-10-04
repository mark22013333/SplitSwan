using System.Text.RegularExpressions;

namespace SplitSwan.Core;

/// <summary>
/// 設定檢查，移植自 Mac 版 ConfigStore.validate／validateSecret／save（Sources/ConfigStore.swift:130-179）。
/// 目的：防止換行、大括號等字元破壞 swanctl.conf／secrets.conf 的結構，並拒絕 /0 全流量。
/// </summary>
public static class SettingsValidator
{
    /// <summary>網段格式錯誤時附的範例（Mac 版的範例是私有網段；公開 repo 規定範例只用 RFC 5737 位址）。</summary>
    internal const string SubnetExample = "192.0.2.0/24";

    // 一律用 \z 而不是 $：.NET 的 $ 會吃掉字串結尾的一個 '\n'，"alice\n" 會被誤判為合法
    private static readonly Regex UsernameRe = new(@"^[A-Za-z0-9._@-]+\z", RegexOptions.CultureInvariant);
    private static readonly Regex GatewayRe = new(@"^[A-Za-z0-9.-]+\z", RegexOptions.CultureInvariant);
    // 用 [0-9] 而不是 \d：\d 會吃全形與其他文字的數字，strongSwan 載入時會失敗
    private static readonly Regex CidrRe = new(
        @"^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})\z", RegexOptions.CultureInvariant);

    /// <summary>回傳繁中錯誤訊息清單；空清單＝合法。</summary>
    public static IReadOnlyList<string> Validate(VpnSettings s)
    {
        ArgumentNullException.ThrowIfNull(s);
        var errors = new List<string>();
        errors.AddRange(ValidateConnection(s.Username, s.Gateways, s.RemoteSubnets));
        ValidateSecret(s.Psk, "預設共享金鑰", "請填入預設共享金鑰", errors);
        ValidateSecret(s.Password, "密碼", "請填入密碼", errors);
        return errors;
    }

    /// <summary>只檢查會寫進 swanctl.conf 的欄位（帳號、閘道、網段）。</summary>
    internal static List<string> ValidateConnection(string? username, IReadOnlyList<string>? gateways, IReadOnlyList<string>? subnets)
    {
        var errors = new List<string>();
        var user = TextRules.TrimWhitespace(username ?? "");
        if (!UsernameRe.IsMatch(user))
            errors.Add("帳號只能包含英數字與 . _ @ -");

        var gws = gateways ?? [];
        // Mac 版固定只有 3 個欄位；這裡不默默截斷，第 4 台起有值就拒絕
        if (gws.Skip(3).Any(g => TextRules.TrimWhitespace(g ?? "").Length > 0))
            errors.Add("閘道最多 3 台");
        var filled = gws.Take(3).Select(g => TextRules.TrimWhitespace(g ?? "")).Where(g => g.Length > 0).ToList();
        if (filled.Count == 0)
            errors.Add("至少要填一台閘道");
        foreach (var g in filled.Where(g => !GatewayRe.IsMatch(g)))
            errors.Add($"閘道格式不正確：{g}");

        errors.AddRange(ValidateSubnets(JoinSubnets(subnets)));
        return errors;
    }

    /// <summary>
    /// Mac 版的網段是一個逗號分隔字串；這裡把清單用逗號接起來後走同一套切分規則，
    /// 讓「空項目」「項目內含逗號」的行為與 Mac 版完全一致。
    /// </summary>
    internal static string JoinSubnets(IReadOnlyList<string>? subnets) =>
        TextRules.TrimWhitespace(string.Join(",", subnets ?? []));

    /// <summary>逐筆檢查 CIDR（Sources/ConfigStore.swift:140-153）。</summary>
    internal static List<string> ValidateSubnets(string remoteTS)
    {
        var errors = new List<string>();
        var nets = TextRules.SplitOmitEmpty(remoteTS, ',').Select(TextRules.TrimWhitespace).ToList();
        if (nets.Count == 0)
        {
            errors.Add("通道網段不可空白");
            return errors;
        }
        foreach (var n in nets)
        {
            var m = CidrRe.Match(n);
            if (!m.Success
                || Enumerable.Range(1, 4).Any(i => int.Parse(m.Groups[i].Value) > 255)
                || int.Parse(m.Groups[5].Value) > 32)
            {
                errors.Add($"通道網段格式不正確：{n}（例：{SubnetExample}）");
                continue;
            }
            // 全流量模式在 macOS 會讓外網 DNS 失效，也最容易被拿來把所有流量導去別處
            if (int.Parse(m.Groups[5].Value) < 1)
                errors.Add($"不可使用 {n}（全部流量走 VPN），請只填公司網段");
        }
        return errors;
    }

    /// <summary>密碼與 PSK：不可空白、不可含換行（Sources/ConfigStore.swift:156-158、173-179）。</summary>
    private static void ValidateSecret(string? value, string name, string emptyMessage, List<string> errors)
    {
        if (string.IsNullOrEmpty(value)) { errors.Add(emptyMessage); return; }
        if (value.Contains('\n') || value.Contains('\r')) errors.Add($"{name}不可包含換行");
    }
}
