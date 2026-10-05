namespace SplitSwan.Core;

/// <summary>設定表單的輸入轉換（托盤 App 用），純邏輯。</summary>
public static class SettingsInput
{
    /// <summary>多行網段輸入 → 清單：換行或逗號分隔，去前後空白、去空項。驗證交給 SettingsValidator。</summary>
    public static IReadOnlyList<string> ParseSubnets(string? text) =>
        (text ?? "").Split([',', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim()).Where(x => x.Length > 0).ToList();

    /// <summary>清單 → 多行文字（表單顯示用，Windows 換行）。</summary>
    public static string FormatSubnets(IEnumerable<string> subnets) => string.Join("\r\n", subnets);

    /// <summary>
    /// 設定表單有沒有還沒按「儲存」的修改（一鍵檢查加入網段前用：它會整份存檔，表單改到一半就要先擋下）。
    /// 只比對要按「儲存」才寫入的欄位：帳號、密碼、PSK、閘道、網段、內部網域、內部 DNS、自動重連；
    /// 顯示設定三欄與 Distro 切換即寫入（DisplaySettings），不算。
    /// 閘道去前後空白並補滿 3 格；網段去空白、空行，逗號與換行視為相同；內部網域與 DNS 去前後空白。
    /// </summary>
    public static bool HasUnsavedChanges(StoredSettings saved, StoredSettings form)
    {
        ArgumentNullException.ThrowIfNull(saved);
        ArgumentNullException.ThrowIfNull(form);
        static List<string> Gateways(IReadOnlyList<string> g)
        {
            var list = g.Take(3).Select(x => (x ?? "").Trim()).ToList();
            while (list.Count < 3) list.Add("");
            return list;
        }
        static IReadOnlyList<string> Subnets(IReadOnlyList<string> s) => ParseSubnets(string.Join("\n", s));
        return form.Username != saved.Username
               || form.Password != saved.Password
               || form.Psk != saved.Psk
               || !Gateways(form.Gateways).SequenceEqual(Gateways(saved.Gateways), StringComparer.Ordinal)
               || !Subnets(form.RemoteSubnets).SequenceEqual(Subnets(saved.RemoteSubnets), StringComparer.Ordinal)
               || form.Domain.Trim() != saved.Domain.Trim()
               || form.DnsServer.Trim() != saved.DnsServer.Trim()
               || form.AutoReconnect != saved.AutoReconnect;
    }

    /// <summary>
    /// 把匯入的公司設定套到目前的設定上（只產生「待確認」的值，呼叫端要讓使用者看過閘道並按儲存才寫入）：
    /// 閘道、網段整組換掉；PSK 有附就換、沒附保留原本的；帳號、密碼、DNS 分流與自動重連不動。
    /// 閘道補滿 3 格（空字串＝未設定）。
    /// </summary>
    public static StoredSettings ApplyImport(StoredSettings current, ImportedProfile imported)
    {
        ArgumentNullException.ThrowIfNull(current);
        ArgumentNullException.ThrowIfNull(imported);
        var gws = imported.Gateways.Take(3).ToList();
        while (gws.Count < 3) gws.Add("");
        return current with
        {
            Gateways = gws,
            RemoteSubnets = imported.RemoteSubnets.ToList(),
            Psk = string.IsNullOrEmpty(imported.Psk) ? current.Psk : imported.Psk,
        };
    }
}
