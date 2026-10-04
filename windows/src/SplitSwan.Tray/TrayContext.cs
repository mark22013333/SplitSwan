using Microsoft.Win32;
using SplitSwan.Core;
using SplitSwan.Tray.Controls;

namespace SplitSwan.Tray;

/// <summary>托盤圖示、選單與各視窗的進入點。</summary>
internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly TrayIcons _icons = new();
    private readonly VpnCoordinator _vpn;
    private readonly ContextMenuStrip _menu = new();
    /// <summary>選單最上方的狀態列（狀態＋閘道，下一行虛擬 IP 或說明）。</summary>
    private readonly MenuHeaderItem _header = new();
    private readonly ToolStripMenuItem _connect = new("連線（自動選擇）");
    /// <summary>「連線 VPN1／2／3」：只顯示有設定的；已連線的那台打勾。</summary>
    private readonly ToolStripMenuItem[] _connectGw = [new(), new(), new()];
    private readonly ToolStripMenuItem _iconMenu = new("圖示樣式");
    private readonly ToolStripMenuItem _iconGreen = new("已連線時顯示綠色");
    private readonly Dictionary<TrayIconStyle, ToolStripMenuItem> _iconStyleItems = new();
    private bool _lightTaskbar = TrayIcons.ReadLightTaskbar();
    private readonly ToolStripMenuItem _disconnect = new("斷線");
    private readonly ToolStripMenuItem _settingsItem = new("設定…");
    private readonly ToolStripMenuItem _import = new("匯入 .splitswan…");
    private readonly ToolStripMenuItem _install = new("首次設定精靈…");
    private readonly ToolStripMenuItem _showLog = new("顯示引擎輸出");
    private readonly ToolStripMenuItem _openLogDir = new("開啟記錄資料夾");
    private readonly ToolStripMenuItem _auto = new("自動重連") { CheckOnClick = false };
    private readonly ToolStripMenuItem _exit = new("斷線並結束");
    private bool _exiting;
    private bool _disposed;
    private readonly SynchronizationContext _ui;
    private readonly UiWatchdog _watchdog;
    private LogForm? _logForm;
    private SettingsForm? _settingsForm;
    private WizardForm? _wizardForm;
    /// <summary>左鍵托盤圖示的狀態面板（第一次點才建立，之後重複使用）。</summary>
    private StatusFlyout? _flyout;

    /// <param name="wizardRequested">命令列帶 --wizard（重開機後由 RunOnce 開啟）：直接開精靈並自動繼續。</param>
    public TrayContext(SettingsLoadResult loaded, bool wizardRequested = false)
    {
        _vpn = new VpnCoordinator(loaded.Settings, OnInstallNeeded);
        // VpnCoordinator 已確認 SynchronizationContext.Current 存在（UI 執行緒）
        _ui = SynchronizationContext.Current!;
        _watchdog = new UiWatchdog(_ui);
        _vpn.Changed += Redraw;
        _vpn.Notify += (title, body, isError) => Balloon(title, body, isError);

        _connect.Click += (_, _) => _vpn.Connect();
        for (int i = 0; i < _connectGw.Length; i++)
        {
            var n = i + 1;
            _connectGw[i].Click += (_, _) => _vpn.Connect(n);
        }
        foreach (var style in Enum.GetValues<TrayIconStyle>())
        {
            var item = new ToolStripMenuItem(TrayIconCatalog.Title(style));
            item.Click += (_, _) => SaveQuick(_vpn.Settings with { IconStyle = style }, $"圖示樣式：{TrayIconCatalog.Title(style)}");
            _iconStyleItems[style] = item;
            _iconMenu.DropDownItems.Add(item);
        }
        _iconMenu.DropDownItems.Add(new ToolStripSeparator());
        _iconMenu.DropDownItems.Add(_iconGreen);
        _iconGreen.Click += (_, _) =>
        {
            var on = !_vpn.Settings.GreenWhenConnected;
            SaveQuick(_vpn.Settings with { GreenWhenConnected = on }, on ? "已連線顯示綠色：開啟" : "已連線顯示綠色：關閉");
        };
        // 工作列切換深淺色時重畫（事件在其他執行緒觸發，切回 UI）
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        _disconnect.Click += (_, _) => _vpn.Disconnect();
        _settingsItem.Click += (_, _) => ShowSettings(importOnShow: false);
        _import.Click += (_, _) => ShowSettings(importOnShow: true);
        _install.Click += (_, _) => ShowWizard(autoStart: false);
        _showLog.Click += (_, _) => ShowLog();
        _openLogDir.Click += (_, _) => LogForm.OpenLogFolder();
        _auto.Click += (_, _) => ToggleAuto();
        _exit.Click += (_, _) => Exit();

        _menu.Items.AddRange(
        [
            _header, new ToolStripSeparator(),
            _connect, _connectGw[0], _connectGw[1], _connectGw[2], _disconnect, new ToolStripSeparator(),
            _settingsItem, _import, _install, new ToolStripSeparator(),
            _showLog, _openLogDir, _auto, _iconMenu, new ToolStripSeparator(),
            _exit,
        ]);

        _icons.Update(loaded.Settings.IconStyle, loaded.Settings.GreenWhenConnected, _lightTaskbar);
        _icon = new NotifyIcon
        {
            Icon = _icons[TrayState.Disconnected],
            Text = AppPaths.AppName,
            ContextMenuStrip = _menu,
            Visible = true,
        };
        // 左鍵：狀態面板（原本的雙擊開記錄改由右鍵選單「顯示引擎輸出」開，避免雙擊時面板開了又關）
        _icon.MouseDown += (_, e) => { if (e.Button == MouseButtons.Left) _flyout?.NoteIconMouseDown(); };
        _icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ToggleFlyout(); };
        ApplyMenuTheme();
        Theme.Changed += OnThemeChanged;

        Redraw();
        foreach (var w in loaded.Warnings)
        {
            AppLog.Info("設定檔提示：" + w);
            Balloon("SplitSwan 設定", w, true);
        }
        _vpn.Start();
        Guard(() => OpenWizardIfNeededAsync(wizardRequested, ConfWriter.Validate(loaded.Settings).Count == 0));
    }

    /// <summary>
    /// 啟動時要不要自動開首次設定精靈（契約 6）：重開機後繼續、設定不完整、或設定的發行版不存在。
    /// 發行版查詢（wsl -l -q）在背景跑，不擋住托盤圖示出現。
    /// </summary>
    private async Task OpenWizardIfNeededAsync(bool requested, bool settingsValid)
    {
        var state = WizardStore.Load();
        var resume = requested || state.RebootPending;
        bool? exists = null;
        if (!resume && settingsValid)
        {
            exists = await WizardSteps.DistroExistsAsync(_vpn, _vpn.Settings.Distro);
            if (_disposed) return;
            AppLog.Info(exists switch
            {
                true => $"WSL 發行版 {_vpn.Settings.Distro} 存在",
                false => $"WSL 發行版 {_vpn.Settings.Distro} 不存在，開啟首次設定精靈",
                null => "查不到 WSL 發行版清單（沒有 Store 版 WSL 或查詢失敗），不自動開精靈",
            });
        }
        if (!WizardTrigger.ShouldAutoOpen(resume, settingsValid, exists)) return;
        if (resume) AppLog.Info("繼續首次設定精靈（重新開機後）");
        ShowWizard(autoStart: resume);
    }

    /// <summary>執行非同步工作；例外寫記錄並通知，不讓 App 結束。</summary>
    private async void Guard(Func<Task> work)
    {
        try { await work(); }
        catch (Exception ex)
        {
            AppLog.Error($"未預期的錯誤：{ex.GetType().Name}：{ex.Message}");
            if (!_disposed) Balloon("SplitSwan 發生未預期的錯誤", ex.Message, true);
        }
    }

    private void ShowWizard(bool autoStart)
    {
        if (_wizardForm is { IsDisposed: false })
        {
            if (_wizardForm.WindowState == FormWindowState.Minimized) _wizardForm.WindowState = FormWindowState.Normal;
            _wizardForm.Activate();
            return;
        }
        _wizardForm = new WizardForm(_vpn, ShowSettingsAsync, autoStart);
        _wizardForm.Finished += () => Balloon("SplitSwan 設定完成", "之後從托盤圖示按右鍵就能連線／斷線", false);
        _wizardForm.FormClosed += (_, _) => _wizardForm = null;
        _wizardForm.Show();
        _wizardForm.Activate();
    }

    /// <summary>精靈步驟 5：開設定視窗（可直接開始匯入），等它關閉後回傳已儲存的設定（取消為 null）。</summary>
    private Task<StoredSettings?> ShowSettingsAsync(bool importOnShow)
    {
        var tcs = new TaskCompletionSource<StoredSettings?>();
        var form = ShowSettings(importOnShow);
        // 視窗已經開著（例如使用者先從托盤開了）：等同一個視窗關閉
        form.FormClosed += (_, _) => tcs.TrySetResult(form.Saved);
        return tcs.Task;
    }

    private void Redraw()
    {
        var state = _vpn.State;
        var s = _vpn.Settings;
        _icons.Update(s.IconStyle, s.GreenWhenConnected, _lightTaskbar);
        _icon.Icon = _icons[state];
        _icon.Text = _vpn.Tooltip;
        var model = StatusPanelModel.Build(state, _vpn.Gateway, state == TrayState.Busy ? _vpn.StatusLine : null,
            _vpn.LastError ?? _vpn.RetryNote, _vpn.WantConnected, _vpn.IsBusy);
        // 第二行：已連線顯示虛擬 IP；其他狀態顯示原因或重試提示（同原本的狀態列＋詳細兩行）
        var detail = state == TrayState.Connected
            ? "虛擬 IP " + (_vpn.Vip ?? "未知")
            : model.Detail ?? (state == TrayState.Busy ? "" : _vpn.RetryNote ?? "");
        _header.Set(model.Tone, model.Headline, detail);
        _flyout?.UpdateFromVpn();

        var busy = _vpn.IsBusy;
        _connect.Enabled = !busy;
        _connect.Text = state == TrayState.Connected ? "重新連線（自動選擇）" : "連線（自動選擇）";
        var connected = _vpn.ConnectedGateway;
        for (int i = 0; i < _connectGw.Length; i++)
        {
            var n = i + 1;
            var item = _connectGw[i];
            // 不可讀回 item.Visible：它的 getter 是「父層可見 && Available」（dotnet/winforms ToolStripItem.cs），
            // 選單沒開時一律 false，之前因此每次都 continue、文字從沒設上，選單打開時只剩三列空白
            var configured = GatewayRecorder.IsConfigured(n, s.Gateways);
            item.Available = configured;
            if (!configured) continue;
            // 例：「連線 VPN2（203.0.113.2） · 上次 3.2 秒連上」（同 Mac 版選單）
            item.Text = GatewayRecorder.MenuTitle(n, s.Gateways, _vpn.History);
            item.Checked = state == TrayState.Connected && connected == n;
            item.Enabled = !busy;
        }
        foreach (var (style, item) in _iconStyleItems) item.Checked = style == s.IconStyle;
        _iconGreen.Checked = s.GreenWhenConnected;
        _disconnect.Enabled = state == TrayState.Connected || _vpn.WantConnected || busy;
        // 精靈可隨時開（它自己的步驟遇到忙碌會等使用者重試）
        _auto.Checked = _vpn.Settings.AutoReconnect;
    }

    private void ToggleFlyout()
    {
        _flyout ??= new StatusFlyout(_vpn, () => ShowSettings(importOnShow: false));
        _flyout.Toggle();
    }

    /// <summary>右鍵選單套主題色（深色模式時選單也是深色）。</summary>
    private void ApplyMenuTheme()
    {
        _menu.Renderer = new ThemedMenuRenderer();
        _menu.BackColor = Theme.Surface;
        _menu.ForeColor = Theme.Ink;
        _menu.Font = Theme.Ui(9f);
        _header.Font = Theme.Ui(9f, System.Drawing.FontStyle.Bold);
    }

    private void OnThemeChanged()
    {
        if (_disposed) return;
        ApplyMenuTheme();
        _menu.Invalidate();
    }

    /// <summary>通知：ShowBalloonTip 遇到空標題或空內文會丟例外，先補上預設文字。</summary>
    private void Balloon(string title, string body, bool isError)
    {
        if (string.IsNullOrWhiteSpace(title)) title = AppPaths.AppName;
        if (string.IsNullOrWhiteSpace(body)) body = isError ? "發生錯誤，詳細內容請看「顯示引擎輸出」" : "（沒有內容）";
        _icon?.ShowBalloonTip(8000, title, body, isError ? ToolTipIcon.Warning : ToolTipIcon.Info);
    }

    /// <summary>手動連線時引擎回報 WSL／發行版尚未安裝：問使用者要不要開首次設定精靈。</summary>
    private void OnInstallNeeded(string reason)
    {
        var r = MessageBox.Show(
            $"{reason}。\n\n首次設定精靈會自動安裝 WSL、下載並匯入 SplitSwan 專用的 Ubuntu（不需要建立帳號）、安裝 strongSwan，" +
            "需要重新開機時會提示。\n\n要現在開啟精靈嗎？",
            "SplitSwan － 需要首次設定", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (r == DialogResult.Yes) ShowWizard(autoStart: true);
    }

    private SettingsForm ShowSettings(bool importOnShow)
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.Activate();
            if (importOnShow) _settingsForm.StartImport();
            return _settingsForm;
        }
        // 自動重連取最新值：設定視窗開著時也可能從托盤切換
        _settingsForm = new SettingsForm(_vpn.Settings, () => _vpn.Settings.AutoReconnect, () => _vpn.Settings, importOnShow,
            history: _vpn.History, connectedGateway: () => _vpn.State == TrayState.Connected ? _vpn.ConnectedGateway : null);
        _settingsForm.FormClosed += (_, _) =>
        {
            if (_settingsForm?.Saved is { } saved) _vpn.UpdateSettings(saved);
            _settingsForm = null;
        };
        var form = _settingsForm;
        form.Show();
        form.Activate();
        return form;
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
        SaveQuick(s, s.AutoReconnect ? "自動重連：開啟" : "自動重連：關閉");
    }

    /// <summary>托盤選單直接切換的設定（自動重連、圖示樣式、綠色）：寫入 settings.json 後套用。</summary>
    private void SaveQuick(StoredSettings s, string log)
    {
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
        AppLog.Info(log);
        _vpn.UpdateSettings(s);   // 會觸發 Changed → Redraw 重畫圖示
    }

    private void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        // 切換深淺色時 Category 是 General（也可能是 Color／VisualStyle），一律重讀，值沒變就不重畫
        _ui.Post(_ =>
        {
            if (_disposed) return;
            Theme.Refresh();   // 應用程式深淺色（視窗、面板、選單）；有變才觸發 Theme.Changed
            var light = TrayIcons.ReadLightTaskbar();
            if (light == _lightTaskbar) return;
            _lightTaskbar = light;
            AppLog.Info(light ? "工作列改為淺色，圖示改用黑色" : "工作列改為深色，圖示改用白色");
            Redraw();
        }, null);
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
            _disposed = true;
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            Theme.Changed -= OnThemeChanged;
            _watchdog.Dispose();
            _icon.Visible = false;
            _icon.Dispose();
            _vpn.Dispose();
            _icons.Dispose();
            _menu.Dispose();
            _logForm?.Dispose();
            _settingsForm?.Dispose();
            _wizardForm?.Dispose();
            _flyout?.Dispose();
            Theme.DisposeFonts();
        }
        base.Dispose(disposing);
    }
}
