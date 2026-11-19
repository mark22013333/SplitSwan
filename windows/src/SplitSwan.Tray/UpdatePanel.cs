using SplitSwan.Core;
using SplitSwan.Tray.Controls;

namespace SplitSwan.Tray;

/// <summary>
/// 設定視窗的「更新」區塊（對應 Mac 1.9.20「關於」頁）：
/// 頂端狀態卡（App 名稱、目前版本、更新狀態徽章與一句下一步，主要按鈕「檢查更新」為載入按鈕），
/// 下方「檢查更新」卡：有新版本時的「下載並安裝」與「前往下載」、安裝進度、檢查或安裝失敗的紅色說明、
/// 「每天自動檢查更新」開關（切換即寫入，不用按「儲存」，寫入後跳吐司）。
/// </summary>
internal sealed class UpdatePanel : TableLayoutPanel
{
    private readonly UpdateCenter _updates;
    private readonly Func<bool> _hasUnsavedChanges;
    private readonly Action<string> _showError;
    private readonly Action<string> _showToast;
    private readonly StatusCard _card;
    private readonly LoadingButton _check = new("檢查更新", primary: true);
    private readonly ThemedButton _install = new("下載並安裝", primary: true);
    private readonly ThemedButton _open = new("前往下載");
    private readonly FlowLayoutPanel _newerRow = UiLayout.Flow();
    private readonly ThemedLabel _newer = new("", TextRole.Warn, Theme.Ui(9f, FontStyle.Bold));
    private readonly ThemedLabel _note = new("", TextRole.Muted, Theme.Ui(8.25f));
    private readonly BusyIndicator _progress = new(BusyStyle.Bar);
    private readonly ErrorBanner _error;
    private readonly ToggleSwitch _auto = new("每天自動檢查更新");
    private bool _syncing;

    /// <param name="hasUnsavedChanges">設定表單有沒有還沒儲存的修改（安裝更新會重新啟動 App，修改會遺失）。</param>
    /// <param name="showError">開關寫入失敗時顯示錯誤（設定視窗的錯誤卡片）。</param>
    /// <param name="showToast">開關寫入成功時的吐司。</param>
    public UpdatePanel(UpdateCenter updates, int width, Func<bool> hasUnsavedChanges, Action<string> showError, Action<string> showToast)
    {
        _updates = updates;
        _hasUnsavedChanges = hasUnsavedChanges;
        _showError = showError;
        _showToast = showToast;
        ColumnCount = 1;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Margin = Padding.Empty;
        Padding = Padding.Empty;
        var inner = width - ToneStyle.CardPadding * 2;

        // ── 狀態卡
        _card = new StatusCard(width) { AccessibleName = "更新狀態" };
        _check.Margin = Padding.Empty;
        _card.AddAction(_check);
        Controls.Add(_card, 0, 0);

        // ── 檢查更新卡（每個控制項都指定列：隱藏的列不會讓後面的往前遞補）
        Controls.Add(new SectionHeader("檢查更新") { Margin = new Padding(0, 16, 0, 6) }, 0, 1);
        var body = UiLayout.Table(1, 5);
        _newer.Anchor = AnchorStyles.Left;
        _newer.Margin = new Padding(0, 0, 10, 0);
        _newerRow.Controls.Add(_newer);
        foreach (var b in new[] { _install, _open })
        {
            b.Margin = new Padding(0, 0, 8, 0);
            _newerRow.Controls.Add(b);
        }
        _newerRow.Margin = new Padding(0, 0, 0, ToneStyle.RowSpacing);
        body.Controls.Add(_newerRow, 0, 0);
        _note.MaximumSize = new Size(inner, 0);
        _note.Margin = new Padding(0, 0, 0, ToneStyle.RowSpacing);
        body.Controls.Add(_note, 0, 1);
        _progress.Width = inner;
        _progress.Margin = new Padding(0, 0, 0, ToneStyle.RowSpacing);
        body.Controls.Add(_progress, 0, 2);
        _error = new ErrorBanner(inner) { Margin = new Padding(0, 0, 0, ToneStyle.RowSpacing) };
        body.Controls.Add(_error, 0, 3);
        var autoBox = UiLayout.Table(1, 2);
        autoBox.Controls.Add(_auto, 0, 0);
        _auto.Margin = Padding.Empty;
        autoBox.Controls.Add(new ThemedLabel(
            "開啟後每天連到 GitHub 查一次；有新版本時托盤選單最上方會顯示，不會自動安裝。" +
            "「下載並安裝」會先驗證發行者簽章，再替換程式並重新開啟 SplitSwan；更新時 VPN 連線不會中斷，新版會沿用既有通道。",
            TextRole.Muted, Theme.Ui(8.25f)) { MaximumSize = new Size(inner - 44, 0), Margin = new Padding(44, 0, 0, 0) }, 0, 1);
        body.Controls.Add(autoBox, 0, 4);
        var card = new SectionCard { MinimumSize = new Size(width, 0), AccessibleName = "檢查更新" };
        card.Controls.Add(body);
        Controls.Add(card, 0, 2);

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
            return;
        }
        _showToast("已儲存");
    }

    /// <summary>依 UpdateCenter 的狀態更新狀態卡、按鈕與訊息。</summary>
    private void Sync()
    {
        if (IsDisposed) return;
        var u = _updates;
        var newer = u.NewerVersion;
        SuspendLayout();
        var status = UpdateStatus.Build(u.IsInstalling, u.InstallFailed, u.IsChecking, u.CheckFailed,
            checkedOnce: u.CheckMessage is not null, hasRelease: u.Latest is not null, newer);
        _card.Set(status.Tone, "SplitSwan", status.Badge, $"目前版本 {UpdateCenter.CurrentVersion}\n{status.Summary}");

        // 檢查中按鈕內轉圈；結束時檢查成功才打勾
        if (u.IsChecking) _check.Begin();
        else _check.Finish(succeeded: !u.CheckFailed);
        _check.Enabled = !u.IsChecking && !u.IsInstalling;

        _newer.Text = newer is null ? "" : $"有新版本 {newer}";
        _newer.Visible = newer is not null;
        _install.Visible = newer is not null && u.Latest?.Assets is not null;
        _install.Enabled = u.CanInstall;
        _install.Text = newer is null ? "下載並安裝" : $"下載並安裝 {newer}";
        _open.Visible = newer is not null || u.InstallFailed;
        _newerRow.Visible = _newer.Visible || _install.Visible || _open.Visible;

        // 進度、失敗原因與其他說明（例：新版本沒有附上可自動安裝的檔案）
        _progress.Visible = u.IsInstalling;
        _progress.Text = u.IsInstalling ? u.InstallMessage ?? "安裝中…" : "";
        var (error, next) =
            u.InstallFailed ? (u.InstallMessage ?? "安裝失敗", "可再按一次「下載並安裝」，或按「前往下載」手動安裝。")
            : u.CheckFailed && !u.IsChecking ? (u.CheckMessage ?? "檢查失敗", "確認網路連線後，再按一次「檢查更新」。")
            : ((string?)null, (string?)null);
        if (error is not null) _error.Set(error, next);
        _error.Visible = error is not null;
        var note = !u.IsChecking && !u.CheckFailed && newer is not null && u.Latest?.Assets is null ? u.CheckMessage : null;
        _note.Text = note ?? "";
        _note.Visible = note is not null;

        _syncing = true;
        try { if (_auto.Checked != u.AutoCheckEnabled) _auto.Checked = u.AutoCheckEnabled; }
        finally { _syncing = false; }
        ResumeLayout(true);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _updates.Changed -= Sync;
        base.Dispose(disposing);
    }
}
