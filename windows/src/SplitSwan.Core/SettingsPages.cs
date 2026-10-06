namespace SplitSwan.Core;

/// <summary>設定視窗左側清單的分類（類似 Windows 11 設定 App）。</summary>
public enum SettingsPage
{
    /// <summary>閘道、帳號、密碼、PSK、自動重連。</summary>
    Connection,
    /// <summary>內網網段、完整網段清單、一鍵主機檢查、內部網域／DNS。</summary>
    Subnets,
    /// <summary>托盤圖示樣式、已連線顯示綠色、捷徑。</summary>
    Appearance,
    /// <summary>目前版本、檢查更新、每天自動檢查更新。</summary>
    Updates,
}

/// <summary>設定表單上要按「儲存」才寫入、會被驗證的欄位。</summary>
public enum SettingsField
{
    Gateway,
    Username,
    Password,
    Psk,
    Subnets,
    Domain,
    DnsServer,
}

/// <summary>驗證錯誤對應到的欄位；Index 只對閘道有意義（0～2，第幾台）。</summary>
public readonly record struct SettingsErrorTarget(SettingsField Field, int Index = 0)
{
    /// <summary>這個欄位在哪個分頁。</summary>
    public SettingsPage Page => SettingsPages.PageOf(Field);
}

/// <summary>設定視窗的分頁規則（托盤 App 用），純邏輯。</summary>
public static class SettingsPages
{
    /// <summary>左側清單的文字。</summary>
    public static string Title(SettingsPage page) => page switch
    {
        SettingsPage.Connection => "連線",
        SettingsPage.Subnets => "網段",
        SettingsPage.Appearance => "外觀",
        SettingsPage.Updates => "更新",
        _ => throw new ArgumentOutOfRangeException(nameof(page), page, null),
    };

    /// <summary>左側清單的順序；沒有更新功能（UpdateCenter 為 null）時不列「更新」。</summary>
    public static IReadOnlyList<SettingsPage> Order(bool hasUpdates) =>
        hasUpdates
            ? [SettingsPage.Connection, SettingsPage.Subnets, SettingsPage.Appearance, SettingsPage.Updates]
            : [SettingsPage.Connection, SettingsPage.Subnets, SettingsPage.Appearance];

    /// <summary>要求的分頁不在清單裡（例如沒有更新功能卻要求「更新」）時退回「連線」。</summary>
    public static SettingsPage Resolve(SettingsPage requested, IReadOnlyList<SettingsPage> available)
    {
        ArgumentNullException.ThrowIfNull(available);
        return available.Contains(requested) ? requested : SettingsPage.Connection;
    }

    /// <summary>欄位所在的分頁。</summary>
    public static SettingsPage PageOf(SettingsField field) => field switch
    {
        SettingsField.Gateway or SettingsField.Username or SettingsField.Password or SettingsField.Psk => SettingsPage.Connection,
        SettingsField.Subnets or SettingsField.Domain or SettingsField.DnsServer => SettingsPage.Subnets,
        _ => throw new ArgumentOutOfRangeException(nameof(field), field, null),
    };

    /// <summary>
    /// 一則驗證錯誤（SettingsValidator、DnsOptions 的訊息）對應到哪個欄位；不是驗證錯誤（例如寫檔失敗）回 null。
    /// 依訊息開頭判斷，訊息改字時 SettingsPagesTests 會用實際的驗證輸出抓到。
    /// 閘道格式錯誤時依訊息裡的位址找出是第幾台；找不到（或「至少要填一台閘道」）指向第 1 台。
    /// </summary>
    public static SettingsErrorTarget? Locate(string error, IReadOnlyList<string>? gateways = null)
    {
        ArgumentNullException.ThrowIfNull(error);
        if (error.StartsWith("帳號", StringComparison.Ordinal)) return new(SettingsField.Username);
        if (error.StartsWith("內部網域", StringComparison.Ordinal)) return new(SettingsField.Domain);
        if (error.StartsWith("內部 DNS", StringComparison.Ordinal)) return new(SettingsField.DnsServer);
        if (error.StartsWith("通道網段", StringComparison.Ordinal) || error.StartsWith("不可使用 ", StringComparison.Ordinal))
            return new(SettingsField.Subnets);
        // PSK 的訊息（「請填入預設共享金鑰」「預設共享金鑰不可包含換行」）要比密碼先判斷
        if (error.Contains("預設共享金鑰", StringComparison.Ordinal)) return new(SettingsField.Psk);
        if (error.StartsWith("請填入密碼", StringComparison.Ordinal) || error.StartsWith("密碼", StringComparison.Ordinal))
            return new(SettingsField.Password);
        if (error.Contains("閘道", StringComparison.Ordinal)) return new(SettingsField.Gateway, GatewayIndex(error, gateways));
        return null;
    }

    /// <summary>
    /// 一組驗證錯誤要切到哪裡：依表單由上往下的順序（連線頁的閘道、帳號、密碼、PSK，再來網段頁）取第一個。
    /// 沒有任何可對應的欄位時回 null。
    /// </summary>
    public static SettingsErrorTarget? First(IEnumerable<string> errors, IReadOnlyList<string>? gateways = null)
    {
        ArgumentNullException.ThrowIfNull(errors);
        return errors.Select(e => Locate(e, gateways))
            .Where(t => t is not null)
            .OrderBy(t => (int)t!.Value.Field)
            .ThenBy(t => t!.Value.Index)
            .FirstOrDefault();
    }

    /// <summary>「閘道格式不正確：x」的 x 是第幾台（比對時去前後空白、不分大小寫）；其他閘道錯誤指向第 1 台。</summary>
    private static int GatewayIndex(string error, IReadOnlyList<string>? gateways)
    {
        const string prefix = "閘道格式不正確：";
        if (gateways is null || !error.StartsWith(prefix, StringComparison.Ordinal)) return 0;
        var bad = error[prefix.Length..];
        for (var i = 0; i < Math.Min(3, gateways.Count); i++)
            if (string.Equals(TextRules.TrimWhitespace(gateways[i] ?? ""), bad, StringComparison.OrdinalIgnoreCase)) return i;
        return 0;
    }
}
