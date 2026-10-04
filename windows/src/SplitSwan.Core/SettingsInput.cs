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
    /// 設定視窗儲存時決定圖示兩欄用誰的值：使用者在表單裡動過的那一欄用表單的值，
    /// 沒動過的用托盤當下的值（latest）——設定視窗開著時，使用者可能從托盤選單切換過樣式或綠色，
    /// 表單裡的是開窗當時的舊值，不能蓋回去（同「自動重連」取最新值的做法）。其他欄位一律用 collected。
    /// </summary>
    public static StoredSettings MergeIconChoice(StoredSettings collected, StoredSettings latest, bool styleEdited, bool greenEdited)
    {
        ArgumentNullException.ThrowIfNull(collected);
        ArgumentNullException.ThrowIfNull(latest);
        return collected with
        {
            IconStyle = styleEdited ? collected.IconStyle : latest.IconStyle,
            GreenWhenConnected = greenEdited ? collected.GreenWhenConnected : latest.GreenWhenConnected,
        };
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
