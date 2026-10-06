using System.Drawing;
using SplitSwan.Core;
using SplitSwan.Tray.Controls;

namespace SplitSwan.Tray;

/// <summary>
/// 設定視窗（視覺稿 C 的設定頁）：左側分類清單（NavList）＋右側分頁（ScrollPage）＋底部固定的「匯入／取消／儲存」，
/// 類似 Windows 11 設定 App。分頁（SettingsPages）：
/// 「連線」閘道清單（狀態點、位址、成功率條與 x/n）、帳號、密碼、PSK、自動重連；
/// 「網段」內網網段（多行）、「在狀態面板顯示完整網段清單」開關、選用的內部網域／內部 DNS、一鍵檢查；
/// 「外觀」托盤圖示樣式（四種狀態預覽、已連線顯示綠色）、捷徑；「更新」檢查更新與自動檢查（UpdatePanel）。
/// 按「儲存」時用 SettingsValidator 與 DnsOptions 驗證，錯誤逐條列在底部的紅色卡片，並切到第一個錯誤欄位所在的分頁、
/// 把焦點放到該欄位（SettingsPages.First）；通過才寫入 settings.json。
/// 匯入 .splitswan 只把值填進表單，使用者看過閘道並按「儲存」才寫入。
/// 「某台公司主機連不上？」一鍵檢查：查 IP → 使用者確認 → 加入網段、存檔（不關閉視窗）並重新連線 → 驗證路由與連接埠。
/// </summary>
internal sealed class SettingsForm : ThemedForm
{
    /// <summary>表單內容寬度（96 DPI 的邏輯像素；兩欄各半）。</summary>
    private const int ContentWidth = 520;
    private const int HalfWidth = (ContentWidth - 12) / 2;
    /// <summary>左側分類清單的寬度。</summary>
    private const int NavWidth = 168;
    /// <summary>分頁內容離分頁左上角的距離。</summary>
    private static readonly Size PageInset = new(24, 18);
    /// <summary>右側分頁的寬度：內容＋左右留白＋垂直捲軸的位置（捲軸出現時不必再出水平捲軸）。</summary>
    private const int PageWidth = 24 + ContentWidth + 24 + 18;
    /// <summary>視窗工作區高度：最長的「連線」「網段」兩頁在一般情況下不需捲動。</summary>
    private const int WindowHeight = 510;
    /// <summary>底部列（錯誤卡片）的內容寬度：整個視窗寬度扣掉左右 16。</summary>
    private const int FooterContentWidth = NavWidth + PageWidth - 32;

    /// <summary>左側分類清單與各分頁。</summary>
    private readonly NavList _nav = new();
    private readonly IReadOnlyList<SettingsPage> _pageOrder;
    private readonly Dictionary<SettingsPage, ScrollPage> _pages = new();
    /// <summary>目前顯示的分頁（建構前為 null）。</summary>
    private SettingsPage? _currentPage;

    /// <summary>已儲存的設定（開窗時的值；一鍵檢查加入網段並存檔後更新）。</summary>
    private StoredSettings _original;
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
    private readonly ThemedLabel _errors = new("", TextRole.Bad) { MaximumSize = new Size(FooterContentWidth - 26, 0) };
    private readonly bool _importOnShow;
    private readonly Func<bool> _currentAutoReconnect;
    private readonly Func<StoredSettings> _latestSettings;
    private readonly GatewayHistory? _history;
    private readonly Func<int?>? _connectedGateway;
    private bool _autoEdited;
    // 顯示設定（圖示樣式、綠色、完整網段清單）切換即寫入 settings.json 並套用，不經「儲存」（DisplaySettings）
    private readonly Action<StoredSettings>? _displayApplied;
    /// <summary>程式同步顯示設定控制項（取托盤當下的值）時不觸發寫入。</summary>
    private bool _syncingDisplay;
    /// <summary>錯誤卡片目前顯示的是顯示設定寫入失敗的錯誤（之後寫入成功時才清掉）。</summary>
    private bool _displayErrorShown;
    private readonly ToggleSwitch _subnetList = new("在狀態面板顯示完整網段清單");
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
    // 捷徑（桌面、開始選單）：狀態以檔案系統為準，開關切換時立即建立／移除，不經「儲存」、不寫 settings.json
    private static readonly ShortcutLocation[] ShortcutLocations = [ShortcutLocation.Desktop, ShortcutLocation.StartMenu];
    private readonly ToggleSwitch[] _shortcut = [.. ShortcutLocations.Select(l => new ToggleSwitch(ShortcutRules.Title(l)))];
    private readonly ThemedLabel[] _shortcutNote = [.. ShortcutLocations.Select(_ => new ThemedLabel("", TextRole.Warn, Theme.Ui(8.25f)))];
    private readonly ThemedButton[] _shortcutUpdate = [.. ShortcutLocations.Select(_ => new ThemedButton("更新"))];
    private readonly FlowLayoutPanel[] _shortcutNoteRow = [.. ShortcutLocations.Select(_ => UiLayout.Flow())];
    /// <summary>程式同步開關（重新讀取實際狀態）時不觸發建立／移除。</summary>
    private bool _syncingShortcuts;
    /// <summary>錯誤卡片目前顯示的是捷徑的錯誤（捷徑操作成功時才清掉，不清掉儲存的驗證錯誤）。</summary>
    private bool _shortcutErrorShown;
    /// <summary>捷徑提示的 tooltip（舊位置的完整路徑）。</summary>
    private readonly ToolTip _shortcutTips = new();
    /// <summary>提示裡的路徑最多幾個字元（超過就省略中段；提示寬度約 386 邏輯像素、8.25pt 字）。</summary>
    private const int ShortcutPathChars = 56;
    private readonly ThemedButton _importBtn = new("匯入 .splitswan…");
    private readonly ThemedButton _saveBtn = new("儲存", primary: true);
    private readonly ThemedButton _cancelBtn = new("取消");
    private bool _importing;
    // 「某台公司主機連不上？」一鍵檢查（同 Mac 版 HostCheckPanel）；沒有 VpnCoordinator 時不顯示
    private readonly VpnCoordinator? _vpn;
    private readonly TextBox _hcInput = new() { PlaceholderText = "主機網域或網址，例：intranet.example.com:8443" };
    private readonly ThemedButton _hcCheck = new("檢查");
    private readonly CardPanel _hcCard = new() { Visible = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
    private readonly TableLayoutPanel _hcBody = UiLayout.Table(1);
    /// <summary>視窗關閉時取消進行中的檢查（DNS、路由查詢、TCP、等待連線）。</summary>
    private readonly CancellationTokenSource _hcCts = new();
    private bool _hcWorking;

    /// <summary>按下儲存並寫入成功後的設定；取消為 null。</summary>
    public StoredSettings? Saved { get; private set; }

    /// <param name="currentAutoReconnect">儲存時取「自動重連」的最新值（視窗開著時可能從托盤切換過；表單裡動過開關就以表單為準）。</param>
    /// <param name="latestSettings">托盤當下（已儲存）的設定：顯示設定切換時以它為底只改一欄；按儲存時顯示設定三欄與 Distro 取它的值。</param>
    /// <param name="displayApplied">顯示設定切換並寫入 settings.json 後呼叫（套用到 VpnCoordinator，讓托盤圖示與面板立即更新）。</param>
    /// <param name="history">閘道連線紀錄（成功率條）；null 時不顯示紀錄。</param>
    /// <param name="connectedGateway">目前連著哪一台（狀態點）；null 時視為沒有連線。</param>
    /// <param name="vpn">一鍵檢查加入網段後套用設定並重新連線用；null 時不顯示一鍵檢查。</param>
    /// <param name="updates">檢查更新與一鍵更新；null 時不顯示「更新」分頁。</param>
    /// <param name="initialPage">開窗時顯示的分頁（例：托盤選單「有新版本…」直接開「更新」）；不存在的分頁退回「連線」。</param>
    public SettingsForm(StoredSettings current, Func<bool> currentAutoReconnect, Func<StoredSettings> latestSettings,
        bool importOnShow = false, GatewayHistory? history = null, Func<int?>? connectedGateway = null,
        Action<StoredSettings>? displayApplied = null, VpnCoordinator? vpn = null, UpdateCenter? updates = null,
        SettingsPage initialPage = SettingsPage.Connection)
    {
        _displayApplied = displayApplied;
        _vpn = vpn;
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
        // 固定大小（96 DPI 的邏輯像素，隨 DPI 縮放）：左側分類清單＋右側分頁＋底部固定的按鈕列。
        // 每頁在這個大小下不需捲動；一鍵檢查結果、匯入提示等臨時內容較多時由該頁自己捲動，底部按鈕不跟著捲。
        ClientSize = new Size(NavWidth + PageWidth, WindowHeight);
        ShowInTaskbar = true;

        _pageOrder = SettingsPages.Order(updates is not null);

        // 連線：閘道、帳號、密碼、PSK、自動重連
        var conn = new PageGrid(SettingsPages.Title(SettingsPage.Connection));
        var gwHead = UiLayout.Table(2);
        gwHead.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        gwHead.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        gwHead.Width = ContentWidth;
        gwHead.Controls.Add(new ThemedLabel("閘道", TextRole.Ink, Theme.Ui(9f, FontStyle.Bold)) { Margin = new Padding(0, 0, 10, 0) }, 0, 0);
        gwHead.Controls.Add(new ThemedLabel("自動選擇會依成功率與耗時排序；閘道 2、3 選填", TextRole.Muted)
        {
            Anchor = AnchorStyles.Right, Margin = Padding.Empty,
        }, 1, 0);
        conn.Span(gwHead, 10);
        conn.Span(BuildGatewayCard(), 6);
        // 匯入提示（隱藏時不佔位但仍佔有自己的列）
        _importCard.Controls.Add(_importNote);
        _importCard.MinimumSize = new Size(ContentWidth, 0);
        conn.Span(_importCard, 8);
        conn.Pair(Field("帳號", _user), Field("密碼", _password));
        var pskRow = UiLayout.Table(1);
        pskRow.Controls.Add(_show, 0, 0);
        _show.Margin = new Padding(0, 22, 0, 0);
        conn.Pair(Field("預設共享金鑰（PSK）", _psk), pskRow);
        conn.Span(BuildAutoPanel(), 10);
        conn.Span(PageNote("「自動重連」以外的欄位要按「儲存」，新設定在下次連線時生效，已建立的通道不受影響。" +
            "密碼與 PSK 以 Windows 帳號加密（DPAPI）儲存。"), 12);

        // 網段：內網網段、完整網段清單、內部網域／DNS、一鍵檢查（結果可能很長，放最後，展開時只往下長）
        var nets = new PageGrid(SettingsPages.Title(SettingsPage.Subnets));
        nets.Span(Field("內網網段（一行一筆）", _subnets, "格式 a.b.c.d/n（單一主機寫 /32），例：192.0.2.0/24", ContentWidth, mono: true, height: 76), 6);
        nets.Span(BuildSubnetListPanel(), 6);
        nets.Pair(Field("內部網域（選填）", _domain, "逗號分隔，填了才設定 DNS 分流，例：corp.example"),
                  Field("內部 DNS（選填）", _dns, "逗號分隔的 IPv4；不填用閘道給的，例：192.0.2.53"), 12);
        nets.Span(PageNote("網段與 DNS 分流要按「儲存」，下次連線時生效；完整網段清單的開關切換後立即生效。"), 8);
        if (_vpn is not null) nets.Span(BuildHostCheckPanel(), 14);

        // 外觀：托盤圖示、捷徑（全部切換即生效）
        var look = new PageGrid(SettingsPages.Title(SettingsPage.Appearance));
        look.Span(new ThemedLabel("托盤圖示", TextRole.Ink, Theme.Ui(9f, FontStyle.Bold)), 10);
        look.Span(BuildIconPanel(), 4);
        look.Span(new ThemedLabel("捷徑", TextRole.Ink, Theme.Ui(9f, FontStyle.Bold)), 14);
        look.Span(BuildShortcutPanel(), 4);
        look.Span(PageNote("這一頁的設定切換後立即生效，不必按「儲存」。"), 12);

        _pages[SettingsPage.Connection] = new ScrollPage(conn.Grid, PageInset);
        _pages[SettingsPage.Subnets] = new ScrollPage(nets.Grid, PageInset);
        _pages[SettingsPage.Appearance] = new ScrollPage(look.Grid, PageInset);
        if (updates is not null)
        {
            // 更新：目前版本、檢查更新、下載並安裝、每天自動檢查更新（切換即寫入）
            var upd = new PageGrid(SettingsPages.Title(SettingsPage.Updates));
            upd.Span(new UpdatePanel(updates, ContentWidth, HasUnsavedChanges, e => ShowErrors([e])), 10);
            _pages[SettingsPage.Updates] = new ScrollPage(upd.Grid, PageInset);
        }

        // 右側：所有分頁疊在同一個容器，一次只顯示一頁
        var host = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty, BackColor = Color.Transparent, TabIndex = 1 };
        var tab = 0;
        foreach (var p in _pageOrder)
        {
            _pages[p].Visible = false;
            _pages[p].TabIndex = tab++;
            host.Controls.Add(_pages[p]);
        }

        // 左側：分類清單
        _nav.Items = [.. _pageOrder.Select(SettingsPages.Title)];
        _nav.Dock = DockStyle.Left;
        _nav.Width = NavWidth;
        _nav.TabIndex = 0;
        _nav.SelectedIndexChanged += (_, _) =>
        {
            if (_nav.SelectedIndex >= 0 && _nav.SelectedIndex < _pageOrder.Count) ShowPage(_pageOrder[_nav.SelectedIndex]);
        };

        // 底部（固定，任何分頁都看得到）：錯誤卡片、匯入／取消／儲存
        var footer = UiLayout.Table(2);
        footer.Dock = DockStyle.Bottom;
        footer.Padding = new Padding(16, 10, 16, 12);
        footer.TabIndex = 2;
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        // 上緣一條分隔線（與左側清單的分隔線同色）
        footer.Paint += (_, e) =>
        {
            using var pen = new Pen(Theme.Line);
            e.Graphics.DrawLine(pen, 0, 0, footer.Width, 0);
        };
        _errorCard.Controls.Add(_errors);
        _errorCard.MinimumSize = new Size(FooterContentWidth, 0);
        _errorCard.Margin = new Padding(0, 0, 0, 10);
        footer.Controls.Add(_errorCard, 0, 0);
        footer.SetColumnSpan(_errorCard, 2);
        _importBtn.Anchor = AnchorStyles.Left;
        _importBtn.Margin = Padding.Empty;
        _importBtn.TabIndex = 0;
        footer.Controls.Add(_importBtn, 0, 1);
        var buttons = UiLayout.Flow(FlowDirection.RightToLeft);
        buttons.Controls.AddRange([_saveBtn, _cancelBtn]);
        _saveBtn.Margin = Padding.Empty;
        _cancelBtn.Margin = new Padding(0, 0, 8, 0);
        _cancelBtn.TabIndex = 0;
        _saveBtn.TabIndex = 1;
        buttons.Anchor = AnchorStyles.Right;
        buttons.TabIndex = 1;
        footer.Controls.Add(buttons, 1, 1);

        // 停駐順序：最後加入的最先停駐——底部列先佔滿整個寬度，左側清單再佔左邊，剩下的給分頁
        Controls.Add(host);
        Controls.Add(_nav);
        Controls.Add(footer);
        ActiveControl = _nav;
        ShowPage(SettingsPages.Resolve(initialPage, _pageOrder));

        _importBtn.Click += (_, _) => StartImport();
        _saveBtn.Click += (_, _) => OnSave();
        // 非模態視窗（Show）時 Button.DialogResult 不會自動關閉視窗，要自己 Close；Esc 透過 CancelButton 觸發同一個 Click
        _cancelBtn.Click += (_, _) => Close();
        AcceptButton = _saveBtn;
        CancelButton = _cancelBtn;

        // 驗證錯誤時框線變紅；改了內容就恢復
        foreach (var box in ValidatedBoxes)
            box.TextChanged += (_, _) => { if (box.Parent is InputFrame { Invalid: true } f) f.Invalid = false; };

        _show.CheckedChanged += (_, _) =>
        {
            _password.UseSystemPasswordChar = !_show.Checked;
            _psk.UseSystemPasswordChar = !_show.Checked;
        };

        Fill(current);
        _iconStyle.SelectedIndex = (int)current.IconStyle;
        _iconGreen.Checked = current.GreenWhenConnected;
        _subnetList.Checked = current.ShowSubnetList;
        _auto.Checked = currentAutoReconnect();
        // 顯示設定切換即寫入並套用（同捷徑）。事件在設好初始值之後才掛上，開窗時的初始設定不會觸發寫入。
        _iconStyle.SelectedIndexChanged += (_, _) => { UpdatePreviews(); ApplyDisplay(DisplaySetting.IconStyle); };
        _iconGreen.CheckedChanged += (_, _) => { UpdatePreviews(); ApplyDisplay(DisplaySetting.GreenWhenConnected); };
        _subnetList.CheckedChanged += (_, _) => ApplyDisplay(DisplaySetting.ShowSubnetList);
        _auto.CheckedChanged += (_, _) => { if (!_syncingAuto) _autoEdited = true; };
        // 視窗開著時可能從托盤切換過自動重連：重新取得焦點時，若使用者沒動過開關，就同步顯示托盤的值
        Activated += (_, _) => SyncAutoFromTray();
        // 視窗開著時也可能從托盤選單切換過圖示樣式／綠色：重新取得焦點時同步顯示托盤當下的值
        Activated += (_, _) => SyncDisplayFromTray();
        // 捷徑可能在視窗外被刪掉或搬動：打開時與每次重新取得焦點時重新讀取
        Activated += (_, _) => RefreshShortcuts();
        for (int i = 0; i < ShortcutLocations.Length; i++)
        {
            var idx = i;
            _shortcut[i].CheckedChanged += (_, _) => { if (!_syncingShortcuts) OnShortcutToggled(idx); };
            _shortcutUpdate[i].Click += (_, _) => OnShortcutUpdate(idx);
        }
        RefreshShortcuts();
        foreach (var t in _gw) t.TextChanged += (_, _) => UpdateGatewayRows();
        UpdatePreviews();
        UpdateGatewayRows();
        Shown += (_, _) => { if (_importOnShow) StartImport(); };
        FormClosed += (_, _) => _hcCts.Cancel();
        FinishLayout();
    }

    /// <summary>
    /// 某個顯示設定切換了：以托盤當下（已儲存）的設定為底只改這一欄，寫入 settings.json 後套用。
    /// 表單上其他還沒儲存的欄位不帶進去（DisplaySettings.Apply）。寫入失敗時顯示錯誤，控制項回到托盤當下的值。
    /// </summary>
    private void ApplyDisplay(DisplaySetting field)
    {
        if (_syncingDisplay || IsDisposed) return;
        var saved = _latestSettings();
        var s = DisplaySettings.Apply(saved, field, Collect());
        if (s == saved) return;
        try
        {
            SettingsStore.Save(s);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
                                       or System.Security.Cryptography.CryptographicException)
        {
            AppLog.Error($"顯示設定寫入失敗（{field}）：{ex.GetType().Name}：{ex.Message}");
            ShowErrors([$"無法儲存設定：{ex.Message}"]);
            _displayErrorShown = true;
            SyncDisplayFromTray();
            return;
        }
        if (_displayErrorShown) ShowErrors([]);
        AppLog.Info(field switch
        {
            DisplaySetting.IconStyle => $"圖示樣式：{TrayIconCatalog.Title(s.IconStyle)}",
            DisplaySetting.GreenWhenConnected => s.GreenWhenConnected ? "已連線顯示綠色：開啟" : "已連線顯示綠色：關閉",
            _ => s.ShowSubnetList ? "狀態面板顯示完整網段清單：開啟" : "狀態面板顯示完整網段清單：關閉",
        });
        _displayApplied?.Invoke(s);
    }

    /// <summary>顯示設定控制項改成托盤當下的值（不觸發寫入）。</summary>
    private void SyncDisplayFromTray()
    {
        if (IsDisposed) return;
        var latest = _latestSettings();
        _syncingDisplay = true;
        try
        {
            if (SelectedIconStyle != latest.IconStyle) _iconStyle.SelectedIndex = (int)latest.IconStyle;
            if (_iconGreen.Checked != latest.GreenWhenConnected) _iconGreen.Checked = latest.GreenWhenConnected;
            if (_subnetList.Checked != latest.ShowSubnetList) _subnetList.Checked = latest.ShowSubnetList;
        }
        finally { _syncingDisplay = false; }
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

    // MARK: 分頁

    /// <summary>
    /// 一個分頁的內容表格（兩欄各半）：頁首標題，之後逐列加入。
    /// 每個控制項都指定 (欄, 列)：TableLayoutPanel 自動排列時會跳過 Visible=false 的控制項，
    /// 隱藏的匯入提示會讓後面全部往前遞補一格（標籤跑到右欄、輸入框錯一列）。
    /// </summary>
    private sealed class PageGrid
    {
        private int _row;

        public PageGrid(string title)
        {
            Grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, HalfWidth + 12));
            Grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, HalfWidth));
            Span(new ThemedLabel(title, TextRole.Ink, Theme.Ui(12f, FontStyle.Bold)) { AccessibleRole = AccessibleRole.StaticText });
        }

        public TableLayoutPanel Grid { get; } = UiLayout.Table(2);

        public void Span(Control c, int top = 0)
        {
            c.Margin = new Padding(0, top, 0, 0);
            Grid.Controls.Add(c, 0, _row);
            Grid.SetColumnSpan(c, 2);
            _row++;
        }

        public void Pair(Control left, Control right, int top = 10)
        {
            left.Margin = new Padding(0, top, 12, 0);
            right.Margin = new Padding(0, top, 0, 0);
            Grid.Controls.Add(left, 0, _row);
            Grid.Controls.Add(right, 1, _row);
            _row++;
        }
    }

    /// <summary>分頁底部的一行說明（哪些即時生效、哪些要按「儲存」）。</summary>
    private static ThemedLabel PageNote(string text) =>
        new(text, TextRole.Muted, Theme.Ui(8.25f)) { MaximumSize = new Size(ContentWidth, 0) };

    /// <summary>
    /// 切到指定分頁（左側清單同步選取）。沒有的分頁（例如沒有更新功能時的「更新」）退回「連線」。
    /// 托盤選單「有新版本…」等入口在視窗已開著時也呼叫這裡。
    /// </summary>
    public void ShowPage(SettingsPage page)
    {
        if (IsDisposed) return;
        page = SettingsPages.Resolve(page, _pageOrder);
        if (_currentPage == page) return;
        _currentPage = page;
        // 一鍵檢查的輸入框在「網段」頁：離開時 Enter 一律回到「儲存」（輸入框隱藏時不一定收到 Leave）
        if (page != SettingsPage.Subnets) AcceptButton = _saveBtn;
        var host = _pages[page].Parent;
        host?.SuspendLayout();
        foreach (var (p, c) in _pages) c.Visible = p == page;
        host?.ResumeLayout(true);
        _nav.SelectedIndex = _pageOrder.ToList().IndexOf(page);
        _nav.AccessibleDescription = SettingsPages.Title(page);
    }

    /// <summary>Ctrl+Tab／Ctrl+PageDown 下一頁，Ctrl+Shift+Tab／Ctrl+PageUp 上一頁（同 Windows 的分頁慣例）。</summary>
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        var step = keyData switch
        {
            Keys.Control | Keys.Tab or Keys.Control | Keys.PageDown => 1,
            Keys.Control | Keys.Shift | Keys.Tab or Keys.Control | Keys.PageUp => -1,
            _ => 0,
        };
        if (step != 0 && _currentPage is { } cur && _pageOrder.Count > 0)
        {
            var list = _pageOrder.ToList();
            ShowPage(list[(list.IndexOf(cur) + step + list.Count) % list.Count]);
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    /// <summary>會被驗證的輸入框（驗證錯誤時框線變紅）。</summary>
    private IEnumerable<TextBox> ValidatedBoxes => [.. _gw, _user, _password, _psk, _subnets, _domain, _dns];

    private TextBox BoxOf(SettingsErrorTarget t) => t.Field switch
    {
        SettingsField.Gateway => _gw[Math.Clamp(t.Index, 0, _gw.Length - 1)],
        SettingsField.Username => _user,
        SettingsField.Password => _password,
        SettingsField.Psk => _psk,
        SettingsField.Subnets => _subnets,
        SettingsField.Domain => _domain,
        _ => _dns,
    };

    /// <summary>
    /// 驗證錯誤：有錯的欄位框線變紅，切到第一個錯誤欄位（依表單由上往下）所在的分頁並把焦點放上去。
    /// 錯誤清單本身顯示在底部的錯誤卡片（任何分頁都看得到）。
    /// </summary>
    private void FocusValidationErrors(IReadOnlyList<string> errors)
    {
        var gws = _gw.Select(t => t.Text).ToList();
        foreach (var box in ValidatedBoxes)
            if (box.Parent is InputFrame f) f.Invalid = false;
        foreach (var e in errors)
            if (SettingsPages.Locate(e, gws) is { } t && BoxOf(t).Parent is InputFrame f) f.Invalid = true;
        if (SettingsPages.First(errors, gws) is not { } first) return;
        ShowPage(first.Page);
        var target = BoxOf(first);
        if (!target.CanFocus) return;
        target.Focus();
        if (!target.Multiline) target.SelectAll();
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

    private Control BuildSubnetListPanel()
    {
        _subnetList.AccessibleName = "在狀態面板顯示完整網段清單";
        var panel = UiLayout.Table(1);
        panel.Controls.Add(_subnetList, 0, 0);
        panel.Controls.Add(new ThemedLabel("關閉時狀態面板只顯示網段摘要一行（例：15 個網段走 VPN）。",
            TextRole.Muted, Theme.Ui(8.25f)) { MaximumSize = new Size(ContentWidth, 0), Margin = new Padding(44, 0, 0, 0) }, 0, 1);
        return panel;
    }

    // MARK: 某台公司主機連不上？（一鍵檢查）

    private Control BuildHostCheckPanel()
    {
        var panel = UiLayout.Table(1);
        panel.Controls.Add(new ThemedLabel("某台公司主機連不上？", TextRole.Ink, Theme.Ui(9f, FontStyle.Bold)) { Margin = Padding.Empty }, 0, 0);
        var row = UiLayout.Flow();
        row.Margin = new Padding(0, 4, 0, 0);
        var frame = new InputFrame(_hcInput, mono: true) { Width = ContentWidth - 76, Margin = new Padding(0, 0, 8, 0) };
        _hcInput.AccessibleName = "要檢查的主機";
        _hcCheck.Margin = Padding.Empty;
        _hcCheck.Anchor = AnchorStyles.Left;
        row.Controls.Add(frame);
        row.Controls.Add(_hcCheck);
        panel.Controls.Add(row, 0, 1);
        panel.Controls.Add(new ThemedLabel(
            "會查出主機的 IP，確認後自動加入內網網段、儲存並重新連線，再檢查是否走 VPN；有填連接埠會一併測試能否連線。",
            TextRole.Muted, Theme.Ui(8.25f)) { MaximumSize = new Size(ContentWidth, 0), Margin = new Padding(0, 3, 0, 0) }, 0, 2);
        _hcBody.Margin = Padding.Empty;
        _hcCard.Controls.Add(_hcBody);
        _hcCard.MinimumSize = new Size(ContentWidth, 0);
        _hcCard.Margin = new Padding(0, 6, 0, 0);
        panel.Controls.Add(_hcCard, 0, 3);

        _hcCheck.Click += (_, _) => HcStart();
        _hcInput.TextChanged += (_, _) => UpdateHcCheckEnabled();
        // 輸入框裡按 Enter 是「檢查」，不是「儲存」：取得焦點時暫時把 AcceptButton 換成「檢查」
        _hcInput.Enter += (_, _) => AcceptButton = _hcCheck;
        _hcInput.Leave += (_, _) => AcceptButton = _saveBtn;
        UpdateHcCheckEnabled();
        return panel;
    }

    private void UpdateHcCheckEnabled() => _hcCheck.Enabled = !_hcWorking && _hcInput.Text.Trim().Length > 0;

    /// <summary>目前是否已連線（未連線時加入網段只存檔，等使用者按「連線並驗證」）。</summary>
    private bool HcConnected => _vpn?.State == TrayState.Connected;

    /// <summary>已儲存的內網網段（判斷涵蓋用；表單上還沒儲存的修改不算）。</summary>
    private IReadOnlyList<string> HcSavedSubnets => _latestSettings().RemoteSubnets;

    /// <summary>表單有沒有還沒按「儲存」的修改。自動重連沒動過時取托盤當下的值，兩邊一致。</summary>
    private bool HasUnsavedChanges() =>
        SettingsInput.HasUnsavedChanges(_original with { AutoReconnect = _currentAutoReconnect() }, Collect());

    /// <summary>執行一段檢查工作：期間停用「檢查」與結果區的按鈕；視窗關閉時取消；例外寫記錄並顯示。</summary>
    private async Task HcRunAsync(Func<CancellationToken, Task> work)
    {
        if (_hcWorking || IsDisposed) return;
        _hcWorking = true;
        UpdateHcCheckEnabled();
        try
        {
            await work(_hcCts.Token);
        }
        catch (OperationCanceledException) when (_hcCts.IsCancellationRequested)
        {
            // 視窗已關閉
        }
        catch (Exception ex)
        {
            AppLog.Error($"一鍵檢查發生錯誤：{ex.GetType().Name}：{ex.Message}");
            HcFailed($"檢查時發生錯誤：{ex.Message}");
        }
        finally
        {
            _hcWorking = false;
            if (!IsDisposed) UpdateHcCheckEnabled();
        }
    }

    private async void HcStart()
    {
        if (_hcWorking || IsDisposed) return;
        if (HostCheck.ParseTarget(_hcInput.Text) is not { } target)
        {
            HcFailed("格式不正確：請輸入主機網域、IP、主機:連接埠或網址");
            return;
        }
        await HcRunAsync(async ct =>
        {
            HcWorking($"查詢 {target.Host} 的 IP…");
            var ips = await HostCheckRunner.ResolveAsync(target.Host, ct);
            ct.ThrowIfCancellationRequested();
            if (ips.Count == 0)
            {
                HcFailed($"查不到 {target.Host} 的 IPv4 位址。若這是公司內部網域，可能要先連上 VPN，或請管理者提供 IP。");
                return;
            }
            var add = HostCheck.Proposal(ips, HcSavedSubnets);
            if (add.Count > 0) { HcConfirm(target, ips, add); return; }
            if (HcConnected) await HcVerifyAsync(target, ips, [], ct);
            else HcNeedConnect(target, ips, []);
        });
    }

    /// <summary>確認後：表單沒有未儲存的修改才加入網段並存檔（不關閉視窗），已連線時重新連線並驗證。</summary>
    private async void HcAddAndApply(HostTarget target, IReadOnlyList<string> ips, IReadOnlyList<string> add)
    {
        if (_hcWorking || IsDisposed || _vpn is null) return;
        // 一鍵加入會整份存檔，表單有改到一半的內容就先擋下
        if (HasUnsavedChanges())
        {
            HcFailed("設定表單有還沒儲存的修改：請先按「儲存」，或按「取消」放棄修改後重新開啟設定，再試一次。");
            return;
        }
        var current = Collect();
        var subnets = current.RemoteSubnets.Concat(add.Where(a => !current.RemoteSubnets.Contains(a, StringComparer.Ordinal))).ToList();
        var (errors, _) = SaveSettings(current with { RemoteSubnets = subnets }, out var saved);
        if (errors.Count > 0)
        {
            HcFailed("無法加入網段：" + string.Join("；", errors));
            return;
        }
        _original = saved;
        _subnets.Text = SettingsInput.FormatSubnets(saved.RemoteSubnets);
        AppLog.Info($"一鍵檢查：已加入網段 {string.Join(", ", add)} 並儲存設定");
        // 之後的連線使用新設定；關窗時 TrayContext 只在按「儲存」（Saved）時才再套用一次，不會重複重連
        _vpn.UpdateSettings(saved);
        if (!HcConnected)
        {
            HcNeedConnect(target, ips, add);
            return;
        }
        await HcRunAsync(ct => HcConnectAndVerifyAsync(target, ips, add, "重新連線中…", ct));
    }

    private async void HcConnectThenVerify(HostTarget target, IReadOnlyList<string> ips, IReadOnlyList<string> added) =>
        await HcRunAsync(ct => HcConnectAndVerifyAsync(target, ips, added, "連線中…", ct));

    /// <summary>
    /// 用新設定連線（已連線時引擎 connect 會先清掉上一次的狀態，等於重建通道），最多等 60 秒，再驗證。
    /// 用 ConnectForWizardAsync：可 await 到連線動作結束，且跟選單的連線共用「一次一個」的機制。
    /// </summary>
    private async Task HcConnectAndVerifyAsync(HostTarget target, IReadOnlyList<string> ips, IReadOnlyList<string> added,
        string text, CancellationToken ct)
    {
        if (_vpn is null) return;
        HcWorking(text);
        var connect = _vpn.ConnectForWizardAsync();
        // 等太久放棄等待時，連線動作仍在背景完成；例外由這裡觀察掉，不讓它變成未觀察的例外
        _ = connect.ContinueWith(t => AppLog.Error($"一鍵檢查的連線發生錯誤：{t.Exception?.GetBaseException().Message}"),
            CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
        var done = await Task.WhenAny(connect, Task.Delay(TimeSpan.FromSeconds(60), ct));
        ct.ThrowIfCancellationRequested();
        if (done != connect)
        {
            HcFailed("60 秒內沒有連上 VPN，請看狀態面板或托盤選單的「顯示引擎輸出」。");
            return;
        }
        var (ok, _, _, error) = await connect;
        if (!ok)
        {
            HcFailed((added.Count > 0 ? "已加入網段，但" : "") + $"連線失敗：{error ?? "原因不明"}");
            return;
        }
        await HcVerifyAsync(target, ips, added, ct);
    }

    private async Task HcVerifyAsync(HostTarget target, IReadOnlyList<string> ips, IReadOnlyList<string> added, CancellationToken ct)
    {
        if (!HcConnected)
        {
            HcFailed("目前沒有連上 VPN，請看狀態面板或托盤選單的「顯示引擎輸出」。");
            return;
        }
        HcWorking("檢查路由" + (target.Port is { } p ? $"與連接埠 {p}" : "") + "…");
        var results = await HostCheckRunner.VerifyAsync(ips, target.Port, ct);
        ct.ThrowIfCancellationRequested();
        HcDone(target, results, added);
    }

    // 結果區的各種畫面（同 Mac 版 HostCheckPanel.Phase）

    private void HcWorking(string text)
    {
        if (!HcBegin(StatusTone.Idle)) return;
        HcText(text, TextRole.Muted);
        HcEnd();
    }

    private void HcFailed(string text)
    {
        if (!HcBegin(StatusTone.Warn)) return;
        HcText(text, TextRole.Warn);
        HcEnd();
    }

    private void HcConfirm(HostTarget target, IReadOnlyList<string> ips, IReadOnlyList<string> add)
    {
        var publicIps = ips.Where(ip => !HostCheck.IsPrivate(ip)).ToList();
        if (!HcBegin(publicIps.Count > 0 ? StatusTone.Warn : StatusTone.Idle)) return;
        var saved = HcSavedSubnets;
        HcText($"{target.Host} 解析到：", TextRole.Ink);
        foreach (var ip in ips)
        {
            var cover = HostCheck.CoveringSubnet(ip, saved);
            HcText($"• {ip}　" + (cover is null ? $"將新增 {ip}/32" : $"已在網段 {cover} 內"), TextRole.Ink, mono: true);
        }
        if (publicIps.Count > 0)
            HcText($"{string.Join(", ", publicIps)} 是公網位址，可能是 DNS 沒有走公司端。加入後，連到這個位址的流量都會改走 VPN。", TextRole.Warn);
        var connected = HcConnected;
        HcText(connected ? "按下後會儲存設定並重新連線，目前的 VPN 連線會中斷約數秒。"
                         : "按下後會儲存設定；目前沒有連線，連線後新網段才會生效。", TextRole.Muted);
        HcButtons((connected ? "加入並重新連線" : "加入網段", true, () => HcAddAndApply(target, ips, add)),
                  ("取消", false, HcHide));
        HcEnd();
    }

    private void HcNeedConnect(HostTarget target, IReadOnlyList<string> ips, IReadOnlyList<string> added)
    {
        if (!HcBegin(StatusTone.Idle)) return;
        HcText(added.Count == 0 ? "這台主機已在內網網段內。目前沒有連線，連線後即可驗證。"
                                : $"已加入 {string.Join(", ", added)} 並儲存。目前沒有連線，連線後新網段才會生效。", TextRole.Ink);
        HcButtons(("連線並驗證", true, () => HcConnectThenVerify(target, ips, added)));
        HcEnd();
    }

    private void HcDone(HostTarget target, IReadOnlyList<IpResult> results, IReadOnlyList<string> added)
    {
        var routeOk = results.All(r => r.ViaTunnel);
        var portOk = results.All(r => r.PortOk ?? true);
        if (!HcBegin(routeOk && portOk ? StatusTone.Idle : StatusTone.Warn)) return;
        var report = HostCheck.Report(target, results, added, HcConnected ? _vpn?.Vip : null);
        foreach (var r in results)
        {
            HcRow(r.ViaTunnel, $"{r.Ip} 路由：{r.Interface ?? "查不到"}（{(r.ViaTunnel ? "有走 VPN" : "沒走 VPN")}）");
            if (r.PortOk is { } ok && target.Port is { } p) HcRow(ok, $"{r.Ip} 連接埠 {p}：{(ok ? "可連線" : "連不上")}");
        }
        HcText(!routeOk ? "還沒走 VPN：確認網段已儲存且已重新連線；若剛重連，稍等幾秒再按一次「再檢查一次」。"
               : !portOk ? "已走 VPN 但連不上，可能是公司端沒有開放。請按「複製結果」交給管理者。"
               : target.Port is null ? "已走 VPN。若仍連不上，可填上連接埠（例：主機:443）再檢查一次。"
               : "已走 VPN，連接埠也能連線。", TextRole.Muted);
        HcButtons(("複製結果", false, () => HcCopy(report)), ("再檢查一次", false, HcStart));
        HcEnd();
    }

    private void HcCopy(string report)
    {
        try
        {
            Clipboard.SetText(report);
        }
        catch (System.Runtime.InteropServices.ExternalException ex)
        {
            // 剪貼簿被其他程式占用
            AppLog.Error($"一鍵檢查：複製結果失敗：{ex.Message}");
            ShowErrors([$"無法複製到剪貼簿：{ex.Message}"]);
        }
    }

    private void HcHide()
    {
        if (IsDisposed) return;
        _hcCard.Visible = false;
        HcClear();
    }

    /// <summary>開始重畫結果區（清空舊內容、設定色調）；視窗已關閉回 false。</summary>
    private bool HcBegin(StatusTone tone)
    {
        if (IsDisposed) return false;
        _hcCard.SuspendLayout();
        HcClear();
        _hcCard.Tone = tone;
        return true;
    }

    private void HcEnd()
    {
        _hcCard.Visible = true;
        _hcCard.ResumeLayout(true);
        _hcCard.AccessibleName = "檢查結果";
        _hcCard.AccessibleDescription = string.Join("\n", _hcBody.Controls.OfType<ThemedLabel>().Select(l => l.Text));
    }

    private void HcClear()
    {
        var old = _hcBody.Controls.Cast<Control>().ToList();
        _hcBody.Controls.Clear();
        _hcBody.RowCount = 0;
        foreach (var c in old) c.Dispose();
    }

    private void HcAdd(Control c)
    {
        _hcBody.Controls.Add(c, 0, _hcBody.Controls.Count);
    }

    /// <summary>結果區的一段文字。執行期新增的控制項不會被表單的 DPI 縮放，尺寸一律用 Px 換算。</summary>
    private void HcText(string text, TextRole role, bool mono = false) =>
        HcAdd(new ThemedLabel(text, role, mono ? Theme.Mono(8.25f) : Theme.Ui(9f))
        {
            MaximumSize = new Size(Px(ContentWidth - 26), 0),
            Margin = new Padding(0, _hcBody.Controls.Count == 0 ? 0 : Px(4), 0, 0),
        });

    /// <summary>✓／✗ 一列（可選取複製的文字在「複製結果」，這裡只顯示）。</summary>
    private void HcRow(bool ok, string text) =>
        HcAdd(new ThemedLabel((ok ? "✓ " : "✗ ") + text, ok ? TextRole.Ok : TextRole.Bad, Theme.Mono(8.25f))
        {
            MaximumSize = new Size(Px(ContentWidth - 26), 0),
            Margin = new Padding(0, _hcBody.Controls.Count == 0 ? 0 : Px(2), 0, 0),
        });

    private void HcButtons(params (string Text, bool Primary, Action Click)[] buttons)
    {
        var row = UiLayout.Flow();
        row.Margin = new Padding(0, Px(8), 0, 0);
        foreach (var (text, primary, click) in buttons)
        {
            var b = new ThemedButton(text, primary) { Margin = new Padding(0, 0, Px(8), 0) };
            // 延到 Click 處理完才執行：動作會重畫結果區、把這顆按鈕本身 Dispose 掉。
            // 檢查進行中不接受第二次操作（HcRunAsync 期間 _hcWorking 為 true）
            b.Click += (_, _) => BeginInvoke(new Action(() => { if (!_hcWorking && !IsDisposed) click(); }));
            row.Controls.Add(b);
        }
        HcAdd(row);
    }

    private Control BuildShortcutPanel()
    {
        // 每個控制項都指定 (欄, 列)：提示列隱藏時，TableLayoutPanel 自動排列會跳過它、讓後面的列往前遞補
        var panel = UiLayout.Table(1, 5);
        for (int i = 0; i < ShortcutLocations.Length; i++)
        {
            _shortcut[i].AccessibleName = ShortcutRules.Title(ShortcutLocations[i]);
            panel.Controls.Add(_shortcut[i], 0, i * 2);
            _shortcutNote[i].Anchor = AnchorStyles.Left;
            _shortcutNote[i].Margin = new Padding(0, 0, 8, 0);
            _shortcutNote[i].MaximumSize = new Size(ContentWidth - 44 - 90, 0);
            _shortcutUpdate[i].Anchor = AnchorStyles.Left;
            _shortcutUpdate[i].Margin = Padding.Empty;
            _shortcutUpdate[i].AccessibleName = $"更新{ShortcutRules.Title(ShortcutLocations[i])}為目前位置";
            _shortcutNoteRow[i].Controls.Add(_shortcutNote[i]);
            _shortcutNoteRow[i].Controls.Add(_shortcutUpdate[i]);
            _shortcutNoteRow[i].Margin = new Padding(44, 0, 0, 4);
            _shortcutNoteRow[i].Visible = false;
            panel.Controls.Add(_shortcutNoteRow[i], 0, i * 2 + 1);
        }
        panel.Controls.Add(new ThemedLabel("開關切換後立即建立或移除，不必按「儲存」。從捷徑啟動一樣會跳出 UAC（App 需要系統管理員權限）。",
            TextRole.Muted, Theme.Ui(8.25f)) { MaximumSize = new Size(ContentWidth, 0), Margin = new Padding(0, 2, 0, 0) }, 0, 4);
        return panel;
    }

    /// <summary>重新讀取兩個捷徑的實際狀態，同步開關與提示（不觸發建立／移除）。</summary>
    private void RefreshShortcuts()
    {
        if (IsDisposed) return;
        for (int i = 0; i < ShortcutLocations.Length; i++) ShowShortcutState(i);
    }

    private void ShowShortcutState(int i)
    {
        var loc = ShortcutLocations[i];
        ShortcutState state;
        string? target;
        try
        {
            (state, target) = Shortcuts.Inspect(loc);
        }
        catch (Exception ex)
        {
            // Inspect 本身已把讀取失敗當成「不是我們的」；這裡只剩找不到資料夾等狀況
            AppLog.Error($"{ShortcutRules.Title(loc)}：讀取狀態失敗：{ex.GetType().Name}：{ex.Message}");
            SetShortcutSwitch(i, false);
            SetShortcutNote(i, ex.Message, update: false);
            return;
        }
        SetShortcutSwitch(i, ShortcutRules.IsOn(state));
        switch (state)
        {
            case ShortcutState.Stale:
                // 路徑另起一行並省略中段（長路徑沒有空白可斷行，整段會被截掉）；完整路徑放 tooltip
                SetShortcutNote(i, "捷徑指向舊位置：\n" + ShortcutRules.CompactPath(target, ShortcutPathChars), update: true,
                    tooltip: target);
                break;
            case ShortcutState.Foreign:
                SetShortcutNote(i, $"{ShortcutRules.RefuseMessage}：已有同名的 {ShortcutRules.FileName}，但不是 SplitSwan 建立的（沒有 SplitSwan 標記），不會變更或刪除。", update: false);
                break;
            default:
                SetShortcutNote(i, "", update: false);
                break;
        }
    }

    private void SetShortcutSwitch(int i, bool on)
    {
        if (_shortcut[i].Checked == on) return;
        _syncingShortcuts = true;
        try { _shortcut[i].Checked = on; }
        finally { _syncingShortcuts = false; }
    }

    private void SetShortcutNote(int i, string text, bool update, string? tooltip = null)
    {
        _shortcutNote[i].Text = text;
        _shortcutTips.SetToolTip(_shortcutNote[i], tooltip);
        _shortcutUpdate[i].Visible = update;
        _shortcutNoteRow[i].Visible = text.Length > 0;
    }

    private void OnShortcutToggled(int i) => RunShortcutAction(i, () => Shortcuts.Apply(ShortcutLocations[i], _shortcut[i].Checked));

    private void OnShortcutUpdate(int i) => RunShortcutAction(i, () => Shortcuts.UpdateStale(ShortcutLocations[i]));

    /// <summary>執行建立／移除／更新；失敗時用錯誤卡片顯示，最後一律重新讀取實際狀態（失敗時開關回到實際狀態）。</summary>
    private void RunShortcutAction(int i, Func<ShortcutAction> action)
    {
        var loc = ShortcutLocations[i];
        try
        {
            action();
            if (_shortcutErrorShown) { ShowErrors([]); _shortcutErrorShown = false; }
            // Refuse（同名但不是我們的）：ShowShortcutState 會依重新讀取的狀態顯示「已有同名捷徑，未變更」
            ShowShortcutState(i);
            return;
        }
        catch (Exception ex)
        {
            // 任何例外都攔下來（含 COM 轉型失敗、參數錯誤），寫記錄後重新讀取，讓開關回到實際狀態
            AppLog.Error($"{ShortcutRules.Title(loc)}操作失敗：{ex.GetType().Name}：{ex.Message}");
            ShowErrors([$"{ShortcutRules.Title(loc)}：{ex.Message}"]);
            _shortcutErrorShown = true;
        }
        ShowShortcutState(i);
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
            _shortcutTips.Dispose();
            _hcCts.Dispose();
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
        ShowSubnetList = _subnetList.Checked,
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
        // 匯入的閘道、PSK 在「連線」頁：停在那裡讓使用者確認閘道
        ShowPage(SettingsPage.Connection);
        UiWatchdog.Mark("匯入：完成");
    }

    /// <summary>錯誤卡片：有錯誤時逐條列出並顯示；空清單時隱藏。</summary>
    /// <param name="validation">驗證錯誤：加上「請修正以下問題」並逐條加「・」。</param>
    private void ShowErrors(IReadOnlyList<string> errors, bool validation = false)
    {
        _shortcutErrorShown = false;   // 捷徑的錯誤由 RunShortcutAction 在呼叫後自己標記
        _displayErrorShown = false;    // 顯示設定的錯誤由 ApplyDisplay 在呼叫後自己標記
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
        var (errors, validation) = SaveSettings(Collect(), out var s);
        if (errors.Count > 0)
        {
            ShowErrors(errors, validation);
            if (validation) FocusValidationErrors(errors);
            return;
        }
        AppLog.Info("設定已儲存");
        Saved = s;
        DialogResult = DialogResult.OK;
        Close();
    }

    /// <summary>
    /// 「儲存」與一鍵檢查共用的存檔路徑：驗證（SettingsValidator、DnsOptions）通過才寫入 settings.json。
    /// 顯示設定三欄切換時已寫入，這裡取托盤當下的值，不用表單上的（DisplaySettings.MergeForSave）。
    /// 回傳錯誤清單（空＝已寫入）與是否為驗證錯誤。
    /// </summary>
    private (IReadOnlyList<string> Errors, bool Validation) SaveSettings(StoredSettings collected, out StoredSettings saved)
    {
        saved = DisplaySettings.MergeForSave(collected, _latestSettings());
        var errors = SettingsValidator.Validate(saved.ToVpnSettings()).Concat(DnsOptions.Validate(saved.Domain, saved.DnsServer)).ToList();
        if (errors.Count > 0) return (errors, true);
        try
        {
            SettingsStore.Save(saved);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
                                       or System.Security.Cryptography.CryptographicException)
        {
            return ([$"儲存失敗：{ex.Message}"], false);
        }
        return ([], false);
    }
}
