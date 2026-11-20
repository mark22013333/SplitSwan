namespace SplitSwan.Core;

/// <summary>
/// 設定「更新」分頁頂端狀態卡的內容（同 Mac 1.9.20「關於」頁的 updateTone／updateBadge／updateSummary）：
/// 色調、狀態徽章與一句下一步。優先序：安裝中 → 安裝失敗 → 檢查中 → 檢查失敗 → 有新版本 → 已是最新 → 沒有發布 → 尚未檢查。
/// </summary>
/// <param name="Tone">色調。</param>
/// <param name="Badge">狀態徽章文字。</param>
/// <param name="Summary">狀態卡的一句下一步說明。</param>
public sealed record UpdateStatus(StatusTone Tone, string Badge, string Summary)
{
    /// <param name="installing">正在下載或安裝。</param>
    /// <param name="installFailed">上一次安裝失敗。</param>
    /// <param name="checking">正在檢查。</param>
    /// <param name="checkFailed">上一次檢查失敗。</param>
    /// <param name="checkedOnce">這次開 App 以來檢查過（有結果文字）。</param>
    /// <param name="hasRelease">檢查結果有找到 Windows 版的發布。</param>
    /// <param name="newerVersion">比目前新的版本；沒有為 null。</param>
    public static UpdateStatus Build(bool installing, bool installFailed, bool checking, bool checkFailed,
        bool checkedOnce, bool hasRelease, string? newerVersion)
    {
        if (installing) return new(StatusTone.Working, "安裝中", "正在下載並安裝新版本，完成後會重新開啟 SplitSwan；VPN 連線不會中斷。");
        if (installFailed) return new(StatusTone.Bad, "更新失敗", "下方有失敗原因；可再按一次「下載並安裝」，或按「前往下載」手動安裝。");
        if (checking) return new(StatusTone.Working, "檢查中", "正在連到 GitHub 查詢最新版本…");
        if (checkFailed) return new(StatusTone.Bad, "檢查失敗", "檢查更新失敗，下方有原因與下一步。");
        if (newerVersion is not null) return new(StatusTone.Warn, $"有新版本 {newerVersion}", "下方可直接下載並安裝新版本。");
        if (checkedOnce && hasRelease) return new(StatusTone.Ok, "最新版本", "目前已是最新版本。");
        if (checkedOnce) return new(StatusTone.Idle, "尚無發布", "GitHub 上還沒有 Windows 版的發布。");
        return new(StatusTone.Idle, "尚未檢查", "按「檢查更新」確認是否有新版本。");
    }
}

/// <summary>
/// 「檢查更新」卡片上「有新版本」那一列要顯示哪些項目。整列是否顯示由這三項推得，
/// 不可回頭讀子控制項的 Visible：WinForms 的 Visible 讀取值含父層，整列隱藏時子項一律讀到 false，整列就再也打不開。
/// </summary>
/// <param name="ShowNewer">「有新版本 X」文字。</param>
/// <param name="ShowInstall">「下載並安裝 X」按鈕。</param>
/// <param name="ShowOpen">「前往下載」按鈕。</param>
public sealed record UpdateActions(bool ShowNewer, bool ShowInstall, bool ShowOpen)
{
    /// <summary>整列是否顯示：任一項要顯示就顯示。</summary>
    public bool ShowRow => ShowNewer || ShowInstall || ShowOpen;

    /// <param name="newerVersion">比目前新的版本；沒有為 null。</param>
    /// <param name="hasAssets">新版本附有可自動安裝的檔案（zip 與簽章）。</param>
    /// <param name="installFailed">上一次安裝失敗（可改用「前往下載」手動安裝）。</param>
    public static UpdateActions For(string? newerVersion, bool hasAssets, bool installFailed) =>
        new(newerVersion is not null, newerVersion is not null && hasAssets, newerVersion is not null || installFailed);
}
