using System.Drawing;
using SplitSwan.Core;
using SplitSwan.Tray.Controls;

namespace SplitSwan.Tray;

/// <summary>
/// 設定視窗（視覺稿 C 的設定頁）：閘道清單（狀態點、位址、成功率條與 x/n）、帳號、密碼、PSK、內網網段（多行）、
/// 選用的內部網域／內部 DNS、托盤圖示樣式（四種狀態預覽、已連線顯示綠色）、自動重連。
/// 按「儲存」時用 SettingsValidator 與 DnsOptions 驗證，錯誤逐條列在紅色卡片；通過才寫入 settings.json。
/// 匯入 .splitswan 只把值填進表單，使用者看過閘道並按「儲存」才寫入。
/// </summary>
internal sealed class SettingsForm : ThemedForm
{
    /// <summary>表單內容寬度（96 DPI 的邏輯像素；兩欄各半）。</summary>
    private const int ContentWidth = 520;
    private const int HalfWidth = (ContentWidth - 12) / 2;

    private readonly StoredSettings _original;
    private readonly TextBox _user = new();
    private readonly TextBox _password = new() { UseSystemPasswordChar = true };
    private readonly TextBox _psk = new() { UseSystemPasswordChar = true };
    private readonly ToggleSwitch _show = new("顯示密碼與 PSK");
    private readonly TextBox[] _gw = [new(), new(), new()];
    private readonly InputFrame[] _gwFrames;
    private readonly StatusDot[] _gwDots = [new(8), new(8), new(8)];
    private readonly MeterBar[] _gwMeters = [new(), new(), new()];
    private readonly ThemedLabel[] _gwCounts = [.. Enumerable.Range(0, 3).Select(_ => new ThemedLabel("—", TextRole.Muted, Theme.Mono(8.25f)))];
    private readonly TextBox _subnets = new() { Multiline = true, ScrollBars = ScrollBars.Vertical, AcceptsReturn = true };
    private readonly TextBox _domain = new();
    private readonly TextBox _dns = new();
    private readonly CardPanel _importCard = new() { Tone = StatusTone.Warn, Visible = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
    private readonly ThemedLabel _importNote = new("", TextRole.Ink) { MaximumSize = new Size(ContentWidth - 26, 0) };
    private readonly CardPanel _errorCard = new() { Tone = StatusTone.Bad, Visible = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
    private readonly ThemedLabel _errors = new("", TextRole.Bad) { MaximumSize = new Size(ContentWidth - 26, 0) };
    private readonly bool _importOnShow;
    private readonly Func<bool> _currentAutoReconnect;
    private readonly Func<StoredSettings> _latestSettings;
    private readonly GatewayHistory? _history;
    private readonly Func<int?>? _connectedGateway;
    // 使用者在表單裡動過圖示控制項沒有；沒動過的欄位儲存時取托盤當下的值（SettingsInput.MergeIconChoice）
    private bool _iconStyleEdited;
    private bool _iconGreenEdited;
    private bool _autoEdited;
    /// <summary>程式同步開關時不算「使用者動過」。</summary>
    private bool _syncingAuto;
    private readonly ThemedComboBox _iconStyle = new() { Width = 180 };
    private readonly ToggleSwitch _iconGreen = new("已連線時顯示綠色");
    private readonly ToggleSwitch _auto = new("自動重連");
    private readonly PictureBox[] _previews = [.. Enumerable.Range(0, 4).Select(_ => new PictureBox
    {
        Size = new Size(32, 32), SizeMode = PictureBoxSizeMode.CenterImage, BackColor = Color.FromArgb(0x20, 0x20, 0x20),
    })];
    /// <summary>預覽的四種狀態（同 Mac 設定頁）。</summary>
    private static readonly (TrayState State, TrayIconState IconState)[] PreviewStates =
    [
        (TrayState.Disconnected, TrayIconState.Disconnected),
        (TrayState.Connected, TrayIconState.Connected),
        (TrayState.Busy, TrayIconState.Connecting),
        (TrayState.Error, TrayIconState.Error),
    ];
    private readonly ThemedButton _importBtn = new("匯入 .splitswan…");
    private readonly ThemedButton _saveBtn = new("儲存", primary: true);
    private readonly ThemedButton _cancelBtn = new("取消");
    private bool _importing;

    /// <summary>按下儲存並寫入成功後的設定；取消為 null。</summary>
    public StoredSettings? Saved { get; private set; }

    /// <param name="currentAutoReconnect">儲存時取「自動重連」的最新值（視窗開著時可能從托盤切換過；表單裡動過開關就以表單為準）。</param>
    /// <param name="latestSettings">儲存時取托盤當下的設定：表單裡沒動過的圖示樣式／綠色選項以它為準。</param>
    /// <param name="history">閘道連線紀錄（成功率條）；null 時不顯示紀錄。</param>
    /// <param name="connectedGateway">目前連著哪一台（狀態點）；null 時視為沒有連線。</param>
    public SettingsForm(StoredSettings current, Func<bool> currentAutoReconnect, Func<StoredSettings> latestSettings,
        bool importOnShow = false, GatewayHistory? history = null, Func<int?>? connectedGateway = null)
    {
        _original = current;
        _currentAutoReconnect = currentAutoReconnect;
        _latestSettings = latestSettings;
        _importOnShow = importOnShow;
        _history = history;
        _connectedGateway = connectedGateway;
        _gwFrames = [.. _gw.Select(t => new InputFrame(t, mono: true))];

        Text = "SplitSwan 設定";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(16);
        ShowInTaskbar = true;

        // 每個控制項都指定 (欄, 列)：TableLayoutPanel 自動排列時會跳過 Visible=false 的控制項，
        // 隱藏的匯入提示／錯誤卡片會讓後面全部往前遞補一格（標籤跑到右欄、輸入框錯一列）。
        var grid = UiLayout.Table(2);
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, HalfWidth + 12));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, HalfWidth));
        var row = 0;
        void Span(Control c, int top = 0)
        {
            c.Margin = new Padding(0, top, 0, 0);
            grid.Controls.Add(c, 0, row);
            grid.SetColumnSpan(c, 2);
            row++;
        }
        void Pair(Control left, Control right, int top = 10)
        {
            left.Margin = new Padding(0, top, 12, 0);
            right.Margin = new Padding(0, top, 0, 0);
            grid.Controls.Add(left, 0, row);
            grid.Controls.Add(right, 1, row);
            row++;
        }

        // 閘道
        var gwHead = UiLayout.Table(2);
        gwHead.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        gwHead.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        gwHead.Width = ContentWidth;
        gwHead.Controls.Add(new ThemedLabel("閘道", TextRole.Ink, Theme.Ui(9f, FontStyle.Bold)) { Margin = new Padding(0, 0, 10, 0) }, 0, 0);
        gwHead.Controls.Add(new ThemedLabel("自動選擇會依成功率與耗時排序；閘道 2、3 選填", TextRole.Muted)
        {
            Anchor = AnchorStyles.Right, Margin = Padding.Empty,
        }, 1, 0);
        Span(gwHead);
        Span(BuildGatewayCard(), 6);

        // 匯入提示（隱藏時不佔位但仍佔有自己的列）
        _importCard.Controls.Add(_importNote);
        _importCard.MinimumSize = new Size(ContentWidth, 0);
        Span(_importCard, 8);

        Pair(Field("帳號", _user), Field("密碼", _password));
        var pskRow = UiLayout.Table(1);
        pskRow.Controls.Add(_show, 0, 0);
        _show.Margin = new Padding(0, 22, 0, 0);
        Pair(Field("預設共享金鑰（PSK）", _psk), pskRow);
        Span(Field("內網網段（一行一筆）", _subnets, "格式 a.b.c.d/n（單一主機寫 /32），例：192.0.2.0/24", ContentWidth, mono: true, height: 76), 10);
        Pair(Field("內部網域（選填）", _domain, "逗號分隔，填了才設定 DNS 分流，例：corp.example"),
             Field("內部 DNS（選填）", _dns, "逗號分隔的 IPv4；不填用閘道給的，例：192.0.2.53"));

        Span(new ThemedLabel("托盤圖示", TextRole.Ink, Theme.Ui(9f, FontStyle.Bold)), 14);
        Span(BuildIconPanel(), 4);
        Span(BuildAutoPanel(), 10);

        Span(new ThemedLabel("新設定在下次連線時生效；已建立的通道不受影響。密碼與 PSK 以 Windows 帳號加密（DPAPI）儲存。",
            TextRole.Muted) { MaximumSize = new Size(ContentWidth, 0) }, 12);
        _errorCard.Controls.Add(_errors);
        _errorCard.MinimumSize = new Size(ContentWidth, 0);
        Span(_errorCard, 8);

        var buttons = UiLayout.Flow(FlowDirection.RightToLeft);
        buttons.Controls.AddRange([_saveBtn, _cancelBtn, _importBtn]);
        buttons.Anchor = AnchorStyles.Right;
        Span(buttons, 14);
        Controls.Add(grid);

        _importBtn.Click += (_, _) => StartImport();
        _saveBtn.Click += (_, _) => OnSave();
        // 非模態視窗（Show）時 Button.DialogResult 不會自動關閉視窗，要自己 Close；Esc 透過 CancelButton 觸發同一個 Click
        _cancelBtn.Click += (_, _) => Close();
        AcceptButton = _saveBtn;
        CancelButton = _cancelBtn;

        _show.CheckedChanged += (_, _) =>
        {
            _password.UseSystemPasswordChar = !_show.Checked;
            _psk.UseSystemPasswordChar = !_show.Checked;
        };

        Fill(current);
        _iconStyle.SelectedIndex = (int)current.IconStyle;
        _iconGreen.Checked = current.GreenWhenConnected;
        _auto.Checked = currentAutoReconnect();
        // 選「表單沒動過就取托盤當下的值」而不是「托盤切換時同步更新已開的表單」：
        // 後者要讓托盤反向操作表單，使用者正在表單裡選的值可能被托盤蓋掉；前者只在儲存時合併，兩邊互不干擾。
        // 事件在設好初始值之後才掛上，開窗時的初始設定不算「動過」。
        _iconStyle.SelectedIndexChanged += (_, _) => { _iconStyleEdited = true; UpdatePreviews(); };
        _iconGreen.CheckedChanged += (_, _) => { _iconGreenEdited = true; UpdatePreviews(); };
        _auto.CheckedChanged += (_, _) => { if (!_syncingAuto) _autoEdited = true; };
        // 視窗開著時可能從托盤切換過自動重連：重新取得焦點時，若使用者沒動過開關，就同步顯示托盤的值
        Activated += (_, _) => SyncAutoFromTray();
        foreach (var t in _gw) t.TextChanged += (_, _) => UpdateGatewayRows();
        UpdatePreviews();
        UpdateGatewayRows();
        Shown += (_, _) => { if (_importOnShow) StartImport(); };
        FinishLayout();
    }

    private void SyncAutoFromTray()
    {
        if (_autoEdited || IsDisposed) return;
        var v = _currentAutoReconnect();
        if (_auto.Checked == v) return;
        _syncingAuto = true;
        try { _auto.Checked = v; }
        finally { _syncingAuto = false; }
    }

    /// <summary>標籤＋輸入框＋（選用）說明，直向排列。</summary>
    private static Control Field(string label, TextBox box, string? hint = null, int width = HalfWidth, bool mono = false, int height = 0)
    {
        var t = UiLayout.Table(1);
        t.Controls.Add(new ThemedLabel(label, TextRole.Muted) { Margin = Padding.Empty }, 0, 0);
        var frame = new InputFrame(box, mono) { Width = width };
        if (height > 0) frame.Height = height;
        box.AccessibleName = label;
        t.Controls.Add(frame, 0, 1);
        if (hint is not null)
            t.Controls.Add(new ThemedLabel(hint, TextRole.Muted, Theme.Ui(8.25f))
            {
                MaximumSize = new Size(width, 0), Margin = new Padding(0, 3, 0, 0),
            }, 0, 2);
        return t;
    }

    private Control BuildGatewayCard()
    {
        var card = new CardPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(12, 4, 12, 4) };
        var t = UiLayout.Table(5, 3);
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 18));
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 48));
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, ContentWidth - 24 - 18 - 48 - 80 - 52));
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 80));
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 52));
        for (int i = 0; i < 3; i++)
        {
            var name = $"VPN{i + 1}";
            _gwDots[i].Anchor = AnchorStyles.Left;
            _gwDots[i].Margin = Padding.Empty;
            t.Controls.Add(_gwDots[i], 0, i);
            t.Controls.Add(new ThemedLabel(name, TextRole.Ink, Theme.Ui(9f, FontStyle.Bold)) { Anchor = AnchorStyles.Left, Margin = Padding.Empty }, 1, i);
            _gwFrames[i].Width = ContentWidth - 24 - 18 - 48 - 80 - 52 - 12;
            _gwFrames[i].Margin = new Padding(0, 4, 12, 4);
            _gw[i].AccessibleName = $"閘道 {i + 1}" + (i == 0 ? "" : "（選填）");
            _gw[i].PlaceholderText = i == 0 ? "IP 或主機名稱，例：203.0.113.10" : "選填";
            t.Controls.Add(_gwFrames[i], 2, i);
            _gwMeters[i].Anchor = AnchorStyles.Left | AnchorStyles.Right;
            _gwMeters[i].Margin = new Padding(0, 0, 8, 0);
            t.Controls.Add(_gwMeters[i], 3, i);
            _gwCounts[i].Anchor = AnchorStyles.Right;
            _gwCounts[i].Margin = Padding.Empty;
            t.Controls.Add(_gwCounts[i], 4, i);
        }
        card.Controls.Add(t);
        return card;
    }

    /// <summary>閘道列的狀態點與成功率：依目前表單上的位址比對紀錄（位址改了，舊紀錄就不算，同 GatewayHistory.Pruned）。</summary>
    private void UpdateGatewayRows()
    {
        var addresses = _gw.Select(t => t.Text).ToList();
        var pruned = _history?.Pruned(addresses);
        var connected = _connectedGateway?.Invoke();
        var now = DateTimeOffset.Now;
        for (int i = 0; i < 3; i++)
        {
            var n = i + 1;
            var records = pruned?.Records(n) ?? [];
            var meter = GatewayMeter.From(records);
            // 位址跟開窗時一樣，才把「目前連線中」算在這一列
            var unchanged = GatewayRecorder.AddressOf(n, addresses) is { Length: > 0 } a
                            && string.Equals(a, GatewayRecorder.AddressOf(n, _original.Gateways), StringComparison.OrdinalIgnoreCase);
            _gwDots[i].Tone = GatewayMeter.DotTone(unchanged && connected == n, pruned?.IsCooling(n, now) ?? false);
            _gwDots[i].AccessibleName = _gwDots[i].Tone switch
            {
                StatusTone.Ok => $"VPN{n} 目前連線中",
                StatusTone.Warn => $"VPN{n} 冷卻中",
                _ => $"VPN{n}",
            };
            _gwMeters[i].Set(meter.Fraction, meter.Tone,
                meter.Total == 0 ? $"VPN{n} 沒有連線紀錄" : $"VPN{n} 最近 {meter.Total} 次成功 {meter.Ok} 次");
            _gwCounts[i].Text = meter.Label;
        }
    }

    private Control BuildIconPanel()
    {
        foreach (var style in Enum.GetValues<TrayIconStyle>()) _iconStyle.Items.Add(TrayIconCatalog.Title(style));
        _iconStyle.AccessibleName = "托盤圖示樣式";
        var panel = UiLayout.Table(1);
        panel.Controls.Add(_iconStyle, 0, 0);
        var row = UiLayout.Flow();
        row.Margin = new Padding(0, 6, 0, 0);
        for (int i = 0; i < _previews.Length; i++)
        {
            var cell = UiLayout.Flow(FlowDirection.TopDown);
            cell.Margin = new Padding(0, 0, 12, 0);
            _previews[i].Margin = Padding.Empty;
            _previews[i].AccessibleName = "預覽：" + TrayIconCatalog.StateTitle(PreviewStates[i].IconState);
            cell.Controls.Add(_previews[i]);
            cell.Controls.Add(new ThemedLabel(TrayIconCatalog.StateTitle(PreviewStates[i].IconState), TextRole.Muted, Theme.Ui(8.25f)));
            row.Controls.Add(cell);
        }
        panel.Controls.Add(row, 0, 1);
        panel.Controls.Add(_iconGreen, 0, 2);
        panel.Controls.Add(new ThemedLabel(
            "預覽以深色工作列顯示；實際顏色會跟著工作列深淺色變成白或黑。托盤選單的「圖示樣式」也可以快速切換。",
            TextRole.Muted, Theme.Ui(8.25f)) { MaximumSize = new Size(ContentWidth, 0) }, 0, 3);
        return panel;
    }

    private Control BuildAutoPanel()
    {
        var panel = UiLayout.Table(1);
        panel.Controls.Add(_auto, 0, 0);
        panel.Controls.Add(new ThemedLabel("斷線 30 秒後依紀錄換一台重試（退避 30 秒到 5 分鐘）；托盤選單也可以切換。",
            TextRole.Muted, Theme.Ui(8.25f)) { MaximumSize = new Size(ContentWidth, 0), Margin = new Padding(44, 0, 0, 0) }, 0, 1);
        return panel;
    }

    /// <summary>重畫四種狀態的預覽（背景固定深色，模擬 Windows 預設的深色工作列）。</summary>
    private void UpdatePreviews()
    {
        var style = SelectedIconStyle;
        var size = Math.Max(16, SystemInformation.SmallIconSize.Width);
        for (int i = 0; i < _previews.Length; i++)
        {
            var (state, iconState) = PreviewStates[i];
            var color = TrayIcons.InkColor(TrayIconRules.Ink(iconState, _iconGreen.Checked, lightTaskbar: false));
            var old = _previews[i].Image;
            _previews[i].Image = TrayIcons.Render(style, state, color, size);
            old?.Dispose();
        }
    }

    private TrayIconStyle SelectedIconStyle =>
        _iconStyle.SelectedIndex >= 0 ? (TrayIconStyle)_iconStyle.SelectedIndex : TrayIconStyle.Shield;

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            foreach (var p in _previews)
            {
                p.Image?.Dispose();
                p.Image = null;
            }
        }
        base.Dispose(disposing);
    }

    private void Fill(StoredSettings s)
    {
        _user.Text = s.Username;
        _password.Text = s.Password;
        _psk.Text = s.Psk;
        for (int i = 0; i < 3; i++) _gw[i].Text = i < s.Gateways.Count ? s.Gateways[i] : "";
        _subnets.Text = SettingsInput.FormatSubnets(s.RemoteSubnets);
        _domain.Text = s.Domain;
        _dns.Text = s.DnsServer;
    }

    private StoredSettings Collect() => new(
        _user.Text,
        _password.Text,
        _psk.Text,
        [.. _gw.Select(t => t.Text)],
        SettingsInput.ParseSubnets(_subnets.Text),
        _domain.Text.Trim(),
        _dns.Text.Trim(),
        // 表單裡動過開關以表單為準，否則取托盤當下的值（視窗開著時可能從托盤切換過）
        _autoEdited ? _auto.Checked : _currentAutoReconnect())
    {
        IconStyle = SelectedIconStyle,
        GreenWhenConnected = _iconGreen.Checked,
    };

    /// <summary>開始匯入（已在匯入中就不重複開始）。</summary>
    public async void StartImport()
    {
        if (_importing || IsDisposed) return;
        _importing = true;
        _importBtn.Enabled = _saveBtn.Enabled = false;
        try
        {
            await ImportAsync();
        }
        catch (Exception ex)
        {
            AppLog.Error($"匯入時發生錯誤：{ex.GetType().Name}：{ex.Message}");
            if (!IsDisposed) ShowErrors([$"匯入時發生錯誤：{ex.Message}"]);
        }
        finally
        {
            _importing = false;
            if (!IsDisposed) _importBtn.Enabled = _saveBtn.Enabled = true;
        }
    }

    private async Task ImportAsync()
    {
        var profile = await ImportFlow.RunAsync(this);
        // 解密期間使用者可能已關閉視窗
        if (profile is null || IsDisposed) return;
        UiWatchdog.Mark("匯入：填入表單");
        var merged = SettingsInput.ApplyImport(Collect(), profile);
        Fill(merged);
        UiWatchdog.Mark("匯入：表單已填入，顯示提示");
        var gws = string.Join("、", profile.Gateways);
        _importNote.Text =
            $"已從設定檔填入閘道（{gws}）、{profile.RemoteSubnets.Count} 筆網段" +
            (string.IsNullOrEmpty(profile.Psk) ? "（設定檔沒有附 PSK，保留原本的）" : "與 PSK") +
            "。請確認閘道是公司提供的位址，再按「儲存」；不確定就按「取消」。";
        _importCard.Visible = true;
        ShowErrors([]);
        UiWatchdog.Mark("匯入：完成");
    }

    /// <summary>錯誤卡片：有錯誤時逐條列出並顯示；空清單時隱藏。</summary>
    /// <param name="validation">驗證錯誤：加上「請修正以下問題」並逐條加「・」。</param>
    private void ShowErrors(IReadOnlyList<string> errors, bool validation = false)
    {
        if (errors.Count == 0)
        {
            _errors.Text = "";
            _errorCard.Visible = false;
            return;
        }
        _errors.Text = validation
            ? "請修正以下問題：\n" + string.Join("\n", errors.Select(e => "・" + e))
            : string.Join("\n", errors);
        _errorCard.Visible = true;
        _errorCard.AccessibleName = "錯誤";
        _errorCard.AccessibleDescription = _errors.Text;
        AccessibilityNotifyClients(AccessibleEvents.SystemAlert, -1);
    }

    private void OnSave()
    {
        var s = SettingsInput.MergeIconChoice(Collect(), _latestSettings(), _iconStyleEdited, _iconGreenEdited);
        var errors = SettingsValidator.Validate(s.ToVpnSettings()).Concat(DnsOptions.Validate(s.Domain, s.DnsServer)).ToList();
        if (errors.Count > 0)
        {
            ShowErrors(errors, validation: true);
            return;
        }
        try
        {
            SettingsStore.Save(s);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
                                       or System.Security.Cryptography.CryptographicException)
        {
            ShowErrors([$"儲存失敗：{ex.Message}"]);
            return;
        }
        AppLog.Info("設定已儲存");
        Saved = s;
        DialogResult = DialogResult.OK;
        Close();
    }
}
