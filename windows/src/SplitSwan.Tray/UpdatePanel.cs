using SplitSwan.Tray.Controls;

namespace SplitSwan.Tray;

/// <summary>
/// 設定視窗的「更新」區塊（對應 Mac 版「關於」頁）：目前版本、檢查更新、有新版本時的「下載並安裝」與「前往下載」、
/// 進度與失敗訊息、「每天自動檢查更新」開關（切換即寫入，不用按「儲存」）。
/// </summary>
internal sealed class UpdatePanel : TableLayoutPanel
{
    private readonly UpdateCenter _updates;
    private readonly Func<bool> _hasUnsavedChanges;
    private readonly Action<string> _showError;
    private readonly ThemedButton _check = new("檢查更新");
    private readonly ThemedButton _install = new("下載並安裝", primary: true);
    private readonly ThemedButton _open = new("前往下載");
    private readonly ThemedLabel _status = new("", TextRole.Muted);
    private readonly ToggleSwitch _auto = new("每天自動檢查更新");
    private bool _syncing;

    /// <param name="hasUnsavedChanges">設定表單有沒有還沒儲存的修改（安裝更新會重新啟動 App，修改會遺失）。</param>
    /// <param name="showError">開關寫入失敗時顯示錯誤（設定視窗的錯誤卡片）。</param>
    public UpdatePanel(UpdateCenter updates, int width, Func<bool> hasUnsavedChanges, Action<string> showError)
    {
        _updates = updates;
        _hasUnsavedChanges = hasUnsavedChanges;
        _showError = showError;
        ColumnCount = 1;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Margin = Padding.Empty;
        Padding = Padding.Empty;

        Controls.Add(new ThemedLabel($"目前版本 {UpdateCenter.CurrentVersion}", TextRole.Ink) { Margin = Padding.Empty }, 0, 0);
        var row = UiLayout.Flow();
        row.Margin = new Padding(0, 6, 0, 0);
        foreach (var b in new[] { _check, _install, _open })
        {
            b.Margin = new Padding(0, 0, 8, 0);
            row.Controls.Add(b);
        }
        Controls.Add(row, 0, 1);
        _status.MaximumSize = new Size(width, 0);
        _status.Margin = new Padding(0, 4, 0, 0);
        Controls.Add(_status, 0, 2);
        _auto.Margin = new Padding(0, 8, 0, 0);
        Controls.Add(_auto, 0, 3);
        Controls.Add(new ThemedLabel(
            "勾選後每天連到 GitHub 查一次；有新版本時托盤選單最上方會顯示，不會自動安裝。" +
            "「下載並安裝」會先驗證發行者簽章，再替換程式並重新開啟 SplitSwan；更新時 VPN 連線不會中斷，新版會沿用既有通道。",
            TextRole.Muted, Theme.Ui(8.25f)) { MaximumSize = new Size(width, 0), Margin = new Padding(44, 0, 0, 0) }, 0, 4);

        _check.Click += (_, _) => _updates.CheckNow();
        _install.Click += (_, _) => OnInstall();
        _open.Click += (_, _) => _updates.OpenReleasePage();
        _auto.Checked = _updates.AutoCheckEnabled;
        _auto.CheckedChanged += (_, _) => OnAutoToggled();
        _updates.Changed += Sync;
        Sync();
    }

    private void OnInstall()
    {
        if (_hasUnsavedChanges())
        {
            var r = MessageBox.Show(FindForm(),
                "設定表單有還沒儲存的修改，安裝更新會重新開啟 SplitSwan，這些修改會遺失。\n\n仍要繼續安裝嗎？",
                "SplitSwan 更新", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (r != DialogResult.Yes) return;
        }
        _updates.InstallLatest();
    }

    private void OnAutoToggled()
    {
        if (_syncing || IsDisposed) return;
        if (_updates.SetAutoCheck(_auto.Checked) is { } error)
        {
            _showError(error);
            Sync();
        }
    }

    /// <summary>依 UpdateCenter 的狀態更新按鈕與訊息。</summary>
    private void Sync()
    {
        if (IsDisposed) return;
        var u = _updates;
        var newer = u.NewerVersion;
        _check.Enabled = !u.IsChecking && !u.IsInstalling;
        _install.Visible = newer is not null && u.Latest?.Assets is not null;
        _install.Enabled = u.CanInstall;
        _install.Text = newer is null ? "下載並安裝" : $"下載並安裝 {newer}";
        _open.Visible = newer is not null || u.InstallFailed;

        var (text, role) =
            u.IsInstalling ? (u.InstallMessage ?? "安裝中…", TextRole.Accent)
            : u.InstallFailed ? ("更新失敗：" + u.InstallMessage, TextRole.Bad)
            : u.IsChecking ? ("檢查中…", TextRole.Muted)
            : u.CheckFailed ? (u.CheckMessage ?? "檢查失敗", TextRole.Bad)
            : newer is not null ? (u.CheckMessage ?? $"有新版本 {newer}", TextRole.Accent)
            : (u.CheckMessage ?? "", TextRole.Muted);
        _status.Text = text;
        _status.Role = role;
        _status.Visible = text.Length > 0;

        _syncing = true;
        try { if (_auto.Checked != u.AutoCheckEnabled) _auto.Checked = u.AutoCheckEnabled; }
        finally { _syncing = false; }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _updates.Changed -= Sync;
        base.Dispose(disposing);
    }
}
