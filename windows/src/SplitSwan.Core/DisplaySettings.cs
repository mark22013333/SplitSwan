namespace SplitSwan.Core;

/// <summary>設定頁上「切換即生效」的顯示設定（不用按「儲存」）。</summary>
public enum DisplaySetting
{
    /// <summary>托盤圖示樣式。</summary>
    IconStyle,
    /// <summary>已連線時顯示綠色。</summary>
    GreenWhenConnected,
    /// <summary>在狀態面板顯示完整網段清單。</summary>
    ShowSubnetList,
}

/// <summary>
/// 顯示設定的寫入規則（托盤 App 設定頁用），純邏輯。
/// 顯示設定一切換就寫入 settings.json 並套用；其他欄位（帳密、閘道、網段、DNS…）要按「儲存」才寫入。
/// 兩條路徑各自只動自己負責的欄位，彼此不會把對方的值蓋掉。
/// </summary>
public static class DisplaySettings
{
    /// <summary>
    /// 切換某個顯示設定時要寫入的完整設定：以已儲存的設定（saved）為底，只把 field 那一欄換成表單上的值。
    /// 表單上其他還沒按「儲存」的欄位一律不帶進去。
    /// </summary>
    public static StoredSettings Apply(StoredSettings saved, DisplaySetting field, StoredSettings form)
    {
        ArgumentNullException.ThrowIfNull(saved);
        ArgumentNullException.ThrowIfNull(form);
        return field switch
        {
            DisplaySetting.IconStyle => saved with { IconStyle = form.IconStyle },
            DisplaySetting.GreenWhenConnected => saved with { GreenWhenConnected = form.GreenWhenConnected },
            DisplaySetting.ShowSubnetList => saved with { ShowSubnetList = form.ShowSubnetList },
            _ => throw new ArgumentOutOfRangeException(nameof(field), field, null),
        };
    }

    /// <summary>
    /// 按「儲存」時要寫入的完整設定：表單負責的欄位用表單的值（collected），
    /// 顯示設定三欄與 WSL 發行版（Distro）一律用已儲存的值（saved）——
    /// 顯示設定切換時已經寫入；設定頁開著時也可能從托盤選單切換過，表單上的不一定是最新的。
    /// 表單沒有 Distro 欄位，不沿用的話新建的設定物件會把舊版使用者的 Ubuntu-24.04 換成預設值。
    /// </summary>
    public static StoredSettings MergeForSave(StoredSettings collected, StoredSettings saved)
    {
        ArgumentNullException.ThrowIfNull(collected);
        ArgumentNullException.ThrowIfNull(saved);
        return collected with
        {
            IconStyle = saved.IconStyle,
            GreenWhenConnected = saved.GreenWhenConnected,
            ShowSubnetList = saved.ShowSubnetList,
            Distro = saved.Distro,
        };
    }
}
