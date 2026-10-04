using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>托盤圖示、選單與各視窗的進入點。</summary>
internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly TrayIcons _icons = new();
    private readonly VpnCoordinator _vpn;
    private readonly ContextMenuStrip _menu = new();
    private readonly ToolStripMenuItem _status = new() { Enabled = false };
    private readonly ToolStripMenuItem _detail = new() { Enabled = false, Visible = false };
    private readonly ToolStripMenuItem _connect = new("連線");
    private readonly ToolStripMenuItem _disconnect = new("斷線");
    private readonly ToolStripMenuItem _settingsItem = new("設定…");
    private readonly ToolStripMenuItem _import = new("匯入 .splitswan…");
    private readonly ToolStripMenuItem _install = new("首次安裝 WSL／Ubuntu…");
    private readonly ToolStripMenuItem _showLog = new("顯示引擎輸出");
    private readonly ToolStripMenuItem _openLogDir = new("開啟記錄資料夾");
    private readonly ToolStripMenuItem _auto = new("自動重連") { CheckOnClick = false };
    private readonly ToolStripMenuItem _exit = new("斷線並結束");
    private bool _exiting;
    private readonly UiWatchdog _watchdog;
    private LogForm? _logForm;
    private SettingsForm? _settingsForm;

    public TrayContext(SettingsLoadResult loaded)
    {
        _vpn = new VpnCoordinator(loaded.Settings, AskOpenInstaller);
        // VpnCoordinator 已確認 SynchronizationContext.Current 存在（UI 執行緒）
        _watchdog = new UiWatchdog(SynchronizationContext.Current!);
        _vpn.Changed += Redraw;
        _vpn.Notify += (title, body, isError) => Balloon(title, body, isError);

        _connect.Click += (_, _) => _vpn.Connect();
        _disconnect.Click += (_, _) => _vpn.Disconnect();
        _settingsItem.Click += (_, _) => ShowSettings(importOnShow: false);
        _import.Click += (_, _) => ShowSettings(importOnShow: true);
        _install.Click += (_, _) => FirstInstall();
        _showLog.Click += (_, _) => ShowLog();
        _openLogDir.Click += (_, _) => LogForm.OpenLogFolder();
        _auto.Click += (_, _) => ToggleAuto();
        _exit.Click += (_, _) => Exit();

        _menu.Items.AddRange(
        [
            _status, _detail, new ToolStripSeparator(),
            _connect, _disconnect, new ToolStripSeparator(),
            _settingsItem, _import, _install, new ToolStripSeparator(),
            _showLog, _openLogDir, _auto, new ToolStripSeparator(),
            _exit,
        ]);

        _icon = new NotifyIcon
        {
            Icon = _icons[TrayState.Disconnected],
            Text = AppPaths.AppName,
            ContextMenuStrip = _menu,
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => ShowLog();

        Redraw();
        foreach (var w in loaded.Warnings)
        {
            AppLog.Info("設定檔提示：" + w);
            Balloon("SplitSwan 設定", w, true);
        }
        if (SettingsValidator.Validate(loaded.Settings.ToVpnSettings()).Count > 0)
            Balloon("SplitSwan", "尚未設定：請在托盤圖示按右鍵 →「設定…」或「匯入 .splitswan…」", false);

        _vpn.Start();
    }

    private void Redraw()
    {
        var state = _vpn.State;
        _icon.Icon = _icons[state];
        _icon.Text = _vpn.Tooltip;
        _status.Text = "狀態：" + _vpn.StatusLine;

        var parts = new List<string>();
        if (state == TrayState.Connected)
        {
            parts.Add("閘道：" + (_vpn.Gateway?.ToUpperInvariant() ?? "未知"));
            parts.Add("虛擬 IP：" + (_vpn.Vip ?? "未知"));
        }
        if (_vpn.RetryNote is { } note && state != TrayState.Connected) parts.Add(note);
        _detail.Text = string.Join("　", parts);
        _detail.Visible = parts.Count > 0;

        var busy = _vpn.IsBusy;
        _connect.Enabled = !busy;
        _connect.Text = state == TrayState.Connected ? "重新連線" : "連線";
        _disconnect.Enabled = state == TrayState.Connected || _vpn.WantConnected || busy;
        _install.Enabled = !busy;
        _auto.Checked = _vpn.Settings.AutoReconnect;
    }

    /// <summary>通知：ShowBalloonTip 遇到空標題或空內文會丟例外，先補上預設文字。</summary>
    private void Balloon(string title, string body, bool isError)
    {
        if (string.IsNullOrWhiteSpace(title)) title = AppPaths.AppName;
        if (string.IsNullOrWhiteSpace(body)) body = isError ? "發生錯誤，詳細內容請看「顯示引擎輸出」" : "（沒有內容）";
        _icon?.ShowBalloonTip(8000, title, body, isError ? ToolTipIcon.Warning : ToolTipIcon.Info);
    }

    private bool AskOpenInstaller(string reason)
    {
        var r = MessageBox.Show(
            $"{reason}。\n\n第一次使用要在可見的視窗安裝 WSL 與 Ubuntu（要建立 Ubuntu 帳號，可能要重開機）。\n\n" +
            "要現在開啟首次安裝視窗嗎？",
            "SplitSwan － 需要首次安裝", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        return r == DialogResult.Yes;
    }

    private void FirstInstall()
    {
        var ok = MessageBox.Show(
            "會開一個 PowerShell 視窗執行連線引擎：\n\n" +
            "1. 沒有 WSL 或 Ubuntu 時會開始安裝，請照畫面建立 Ubuntu 帳號（帳號密碼自訂，跟公司帳號無關）。\n" +
            "2. 要求重開機就重開，重開後開啟 SplitSwan 按「連線」。\n" +
            "3. 已安裝過時會直接連線。視窗最後會停住，看完按 Enter 關閉。\n\n" +
            "用內建 Administrator 帳號時，安裝會改從網路下載（--web-download），不經 Microsoft Store。\n\n要開始嗎？",
            "SplitSwan － 首次安裝", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
        if (ok != DialogResult.OK) return;
        var why = _vpn.StartFirstInstall();
        if (why is not null)
            MessageBox.Show(why, "SplitSwan － 首次安裝", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }

    private void ShowSettings(bool importOnShow)
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.Activate();
            if (importOnShow) _settingsForm.StartImport();
            return;
        }
        // 自動重連取最新值：設定視窗開著時也可能從托盤切換
        _settingsForm = new SettingsForm(_vpn.Settings, () => _vpn.Settings.AutoReconnect, importOnShow);
        _settingsForm.FormClosed += (_, _) =>
        {
            if (_settingsForm?.Saved is { } saved) _vpn.UpdateSettings(saved);
            _settingsForm = null;
        };
        _settingsForm.Show();
        _settingsForm.Activate();
    }

    private void ShowLog()
    {
        if (_logForm is { IsDisposed: false })
        {
            _logForm.Activate();
            return;
        }
        _logForm = new LogForm();
        _logForm.FormClosed += (_, _) => _logForm = null;
        _logForm.Show();
        _logForm.Activate();
    }

    private void ToggleAuto()
    {
        var s = _vpn.Settings with { AutoReconnect = !_vpn.Settings.AutoReconnect };
        try
        {
            SettingsStore.Save(s);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
                                       or System.Security.Cryptography.CryptographicException)
        {
            MessageBox.Show($"無法儲存設定：{ex.Message}", "SplitSwan", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        AppLog.Info(s.AutoReconnect ? "自動重連：開啟" : "自動重連：關閉");
        _vpn.UpdateSettings(s);
    }

    /// <summary>
    /// 結束：先斷線（清 WSL 內的 SA、Windows 路由、NRPT、保活程序）再關閉 App，
    /// 不把通道留在背景——App 關掉後托盤沒有圖示，使用者無從得知通道還在。
    /// </summary>
    private async void Exit()
    {
        if (_exiting) return;
        if (_vpn.IsBusy)
        {
            MessageBox.Show("目前有連線／斷線動作在進行中，請等它完成再結束（中途結束可能留下一半的設定）。",
                "SplitSwan", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        _exiting = true;
        try
        {
            if (_vpn.NeedsDisconnectOnExit)
            {
                _menu.Enabled = false;
                var (ok, error) = await _vpn.DisconnectForExitAsync();
                if (!ok)
                {
                    var r = MessageBox.Show(
                        $"斷線失敗：{error}\n\nVPN 通道與 Windows 路由可能還在。仍要結束 SplitSwan 嗎？\n" +
                        "（選「否」可回到 App，從「顯示引擎輸出」查看原因後再按「斷線」）",
                        "SplitSwan", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                    if (r != DialogResult.Yes)
                    {
                        _menu.Enabled = true;
                        _exiting = false;
                        return;
                    }
                    AppLog.Info("斷線失敗，使用者仍選擇結束");
                }
            }
            AppLog.Info("結束 App");
            ConfWriter.DeleteSecrets();
            ExitThread();
        }
        catch (Exception ex)
        {
            // async void 的例外沒人接會直接結束 App，這裡攔下讓使用者知道
            AppLog.Error($"結束時發生錯誤：{ex.GetType().Name}：{ex.Message}");
            _menu.Enabled = true;
            _exiting = false;
            Balloon("結束失敗", ex.Message, true);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _watchdog.Dispose();
            _icon.Visible = false;
            _icon.Dispose();
            _vpn.Dispose();
            _icons.Dispose();
            _menu.Dispose();
            _logForm?.Dispose();
            _settingsForm?.Dispose();
        }
        base.Dispose(disposing);
    }
}
