using System.Drawing;
using System.Runtime.InteropServices;
using SplitSwan.Core;
using SplitSwan.Tray.Controls;

namespace SplitSwan.Tray;

/// <summary>
/// 狀態面板（Mac 1.9.20 連線頁的設計）：左鍵托盤圖示彈出，再點一次或失去焦點就關。
/// 無邊框、最上層、不出現在工作列與 Alt+Tab；Windows 11 圓角。位置由 Core 的 FlyoutPlacement 計算。
/// 內容由上而下：狀態卡（色調圖示、狀態大字＋狀態徽章、一句下一步、唯一的主要按鈕：連線／重新連線／斷線）、
/// 連線失敗時的紅色錯誤說明（原因可選取複製）、「連線資訊」卡（虛擬 IP／已連線時間／握手耗時、通道流量，只在已連線時）、
/// 「分流」卡（網段摘要一行，設定勾選「顯示完整網段清單」時再加上網段 chips，與「其他所有流量走本機網路」）、
/// 最下方狀態更新時間與次要按鈕（改連到…／設定）。已連線時間與狀態更新時間每秒更新，只在面板開著時計時。
/// </summary>
internal sealed class StatusFlyout : ThemedForm
{
    private const int PanelWidth = 320;
    /// <summary>面板四周的留白。</summary>
    private const int Inset = 12;
    /// <summary>卡片寬度。</summary>
    private const int CardWidth = PanelWidth - Inset * 2;
    /// <summary>卡片內容寬度（扣掉卡片內距）。</summary>
    private const int InnerWidth = CardWidth - ToneStyle.CardPadding * 2;
    /// <summary>「虛擬 IP／已連線／握手耗時」三欄的寬度（合計 InnerWidth）。</summary>
    private static readonly int[] FactWidths = [116, 80, InnerWidth - 116 - 80];

    private readonly VpnCoordinator _vpn;
    private readonly Action _openSettings;
    private readonly StatusCard _status = new(CardWidth);
    private readonly ErrorBanner _error = new(CardWidth) { Visible = false };
    private readonly SectionHeader _infoHeader = new("連線資訊");
    private readonly SectionCard _infoCard = new() { MinimumSize = new Size(CardWidth, 0) };
    private readonly TableLayoutPanel _facts = UiLayout.Table(3, 2);
    private readonly ThemedLabel _vipValue = new("", TextRole.Ink, Theme.Mono(9f));
    private readonly ThemedLabel _sinceValue = new("", TextRole.Ink, Theme.Mono(9f));
    private readonly ThemedLabel _buildValue = new("", TextRole.Ink, Theme.Mono(9f));
    private readonly ThemedLabel _traffic = new("", TextRole.Ink, Theme.Mono(9f));
    private readonly ThemedLabel _fresh = new("", TextRole.Muted, Theme.Ui(8.25f));
    private readonly ThemedLabel _summary = new("", TextRole.Ink);
    private readonly ThemedLabel _vpnLaneLabel = LaneLabel("走 VPN");
    private readonly ChipFlow _vpnLane = new();
    private readonly ChipFlow _localLane = new();
    private readonly ThemedButton _settings = new("設定");
    private readonly ThemedButton _gatewayMenu = new("改連到…") { DropDownArrow = true };
    private readonly LoadingButton _primary = new("斷線", primary: true);
    /// <summary>主要按鈕轉圈時是不是在斷線（結束時成功＝已不再連線，才打勾）。</summary>
    private bool _primaryWasBusy;
    private readonly ContextMenuStrip _gwMenu = new() { ShowImageMargin = false, ShowCheckMargin = true };
    private readonly System.Windows.Forms.Timer _tick = new() { Interval = 1000 };
    /// <summary>三欄數值的 tooltip（握手耗時的說明、已連線時間只是下限的說明）。</summary>
    private readonly ToolTip _tips = new();
    /// <summary>已連線時間目前是否顯示為下限（tooltip 只在變化時更新，不每秒重設）。</summary>
    private bool? _sinceApproximateShown;
    private StatusPanelModel? _model;
    private DateTimeOffset? _lastDeactivatedClose;
    private DateTimeOffset? _iconDownAt;
    private bool _visibleAtIconDown;
    private FlyoutAnchor? _anchor;
    /// <summary>拿不到前景時偵測「在面板外按下滑鼠」的計時器；只在那種情況存在，關閉面板時停止並釋放。</summary>
    private System.Windows.Forms.Timer? _outsideWatch;
    private IReadOnlyList<string>? _lanesShown;

    public StatusFlyout(VpnCoordinator vpn, Action openSettings)
    {
        _vpn = vpn;
        _openSettings = openSettings;
        Text = "SplitSwan 狀態";
        AccessibleName = "SplitSwan 狀態面板";
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        KeyPreview = true;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;

        // ── 狀態卡：大字狀態、徽章、一句下一步、唯一的主要按鈕（填滿整列）
        _primary.AutoSize = false;
        _primary.Size = new Size(_status.ActionWidth, 34);
        _status.AddAction(_primary);
        _status.AccessibleName = "連線狀態";
        _error.Margin = new Padding(0, 10, 0, 0);

        // ── 連線資訊卡（只在已連線時）：三欄數值與通道流量
        // 虛擬 IP 欄較寬：完整的 IPv4（15 字元，等寬字）不必省略
        foreach (var w in FactWidths) _facts.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, w));
        AddFact(0, "虛擬 IP", _vipValue);
        AddFact(1, "已連線", _sinceValue);
        AddFact(2, StatusPanelText.HandshakeCaption, _buildValue, StatusPanelText.HandshakeTip);
        var info = UiLayout.Table(1, 2);
        info.Controls.Add(_facts, 0, 0);
        _traffic.MaximumSize = new Size(InnerWidth, 0);
        _traffic.Margin = new Padding(0, ToneStyle.RowSpacing, 0, 0);
        _traffic.AccessibleName = "通道流量";
        info.Controls.Add(_traffic, 0, 1);
        _infoCard.Controls.Add(info);
        _infoCard.AccessibleName = "連線資訊";
        _infoHeader.Margin = new Padding(0, 14, 0, 6);

        // ── 分流卡：網段摘要與 chips
        // 每個控制項都指定 (欄, 列)：隱藏的網段 chips 列不會讓後面的控制項往前遞補
        var lanes = UiLayout.Table(2, 3);
        lanes.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 82));
        lanes.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, InnerWidth - 82));
        _summary.MaximumSize = new Size(InnerWidth, 0);
        _summary.Margin = new Padding(0, 0, 0, 8);
        _summary.AccessibleName = "走 VPN 的網段";
        lanes.Controls.Add(_summary, 0, 0);
        lanes.SetColumnSpan(_summary, 2);
        lanes.Controls.Add(_vpnLaneLabel, 0, 1);
        lanes.Controls.Add(_vpnLane, 1, 1);
        lanes.Controls.Add(LaneLabel("走本機網路"), 0, 2);
        lanes.Controls.Add(_localLane, 1, 2);
        _vpnLane.MaximumSize = new Size(InnerWidth - 82, 0);
        _localLane.SetChips(["其他所有流量"], ChipKind.Local, mono: false);
        var lanesCard = new SectionCard { MinimumSize = new Size(CardWidth, 0) };
        lanesCard.Controls.Add(lanes);
        lanesCard.AccessibleName = "分流";
        var lanesHeader = new SectionHeader("分流") { Margin = new Padding(0, 14, 0, 6) };

        // ── 最下方：狀態更新時間、次要按鈕
        var footer = UiLayout.Table(2, 1);
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, CardWidth - 150));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        footer.Margin = new Padding(0, 12, 0, 0);
        _fresh.MaximumSize = new Size(CardWidth - 150, 0);
        _fresh.Anchor = AnchorStyles.Left;
        _fresh.Margin = Padding.Empty;
        _fresh.AccessibleName = "狀態更新時間";
        footer.Controls.Add(_fresh, 0, 0);
        var buttons = UiLayout.Flow(FlowDirection.RightToLeft);
        buttons.Anchor = AnchorStyles.Right;
        buttons.Controls.AddRange([_settings, _gatewayMenu]);
        footer.Controls.Add(buttons, 1, 0);

        var root = UiLayout.Table(1, 7);
        root.Padding = new Padding(Inset);
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, CardWidth));
        root.Controls.Add(_status, 0, 0);
        root.Controls.Add(_error, 0, 1);
        root.Controls.Add(_infoHeader, 0, 2);
        root.Controls.Add(_infoCard, 0, 3);
        root.Controls.Add(lanesHeader, 0, 4);
        root.Controls.Add(lanesCard, 0, 5);
        root.Controls.Add(footer, 0, 6);
        Controls.Add(root);

        _settings.Click += (_, _) => { HideFlyout(deactivated: false); _openSettings(); };
        _gatewayMenu.Click += (_, _) => ShowGatewayMenu();
        _primary.Click += (_, _) => OnPrimary();
        _gwMenu.Renderer = new ThemedMenuRenderer();
        _tick.Tick += (_, _) => UpdateElapsed();
        FinishLayout();
        OnThemeApplied();
    }

    private void AddFact(int col, string caption, ThemedLabel value, string? tip = null)
    {
        var cap = new ThemedLabel(caption, TextRole.Muted, Theme.Ui(7.5f)) { Margin = Padding.Empty };
        if (tip is not null)
        {
            _tips.SetToolTip(cap, tip);
            _tips.SetToolTip(value, tip);
            value.AccessibleDescription = tip;
        }
        value.Margin = new Padding(0, 1, 0, 0);
        value.AutoEllipsis = true;
        value.AutoSize = false;
        value.Size = new Size(FactWidths[col] - 4, 18);   // 96 DPI 的邏輯像素，視窗縮放時一起放大
        _facts.Controls.Add(cap, col, 0);
        _facts.Controls.Add(value, col, 1);
        value.AccessibleName = caption;
    }

    private static ThemedLabel LaneLabel(string text) =>
        new(text, TextRole.Muted) { Margin = new Padding(0, 2, 6, 6) };

    protected override CreateParams CreateParams
    {
        get
        {
            const int WS_EX_TOOLWINDOW = 0x80;
            const int CS_DROPSHADOW = 0x20000;
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW;   // 不出現在 Alt+Tab
            cp.ClassStyle |= CS_DROPSHADOW;   // Windows 10 沒有 DWM 圓角時至少有陰影
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => false;

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyRoundCorners(this);
    }

    protected override void OnThemeApplied()
    {
        _gwMenu.Renderer = new ThemedMenuRenderer();
        _gwMenu.BackColor = Theme.Surface;
        _gwMenu.ForeColor = Theme.Ink;
    }

    /// <summary>托盤圖示按下滑鼠左鍵時呼叫（TrayContext 的 MouseDown）：記下時間與當下面板是否開著，放開時依此判斷。</summary>
    public void NoteIconMouseDown()
    {
        _iconDownAt = DateTimeOffset.Now;
        _visibleAtIconDown = Visible;
    }

    /// <summary>點托盤圖示（放開）：開著就關、這次點擊造成的失去焦點關閉不重開（FlyoutToggle.ShouldOpenOnClick）、否則開啟。</summary>
    public void Toggle()
    {
        var open = FlyoutToggle.ShouldOpenOnClick(Visible, _visibleAtIconDown, _iconDownAt, _lastDeactivatedClose, DateTimeOffset.Now);
        _iconDownAt = null;
        _visibleAtIconDown = false;
        if (!open)
        {
            if (Visible) HideFlyout(deactivated: false);
            _lastDeactivatedClose = null;
            return;
        }
        ShowFlyout();
    }

    private void ShowFlyout()
    {
        UpdateFromVpn(force: true);
        _anchor = CaptureAnchor();
        Reposition();
        Show();
        Reposition();   // 換到不同 DPI 的螢幕時，顯示後大小會改變，再算一次（同一個錨點）
        Activate();
        // 預設焦點給「設定」：主要按鈕在已連線時是「斷線」，開面板後按 Enter／空白鍵不可直接斷線
        _settings.Focus();
        _tick.Start();
        StartOutsideClickWatchIfNotForeground();
    }

    private void HideFlyout(bool deactivated)
    {
        _tick.Stop();
        StopOutsideClickWatch();
        if (deactivated) _lastDeactivatedClose = DateTimeOffset.Now;
        // 隱藏後 UpdateFromVpn 不再更新：先停掉轉圈，也不在下次開啟時補播打勾（仍在進行中的話開啟時會重新轉圈）
        if (_primaryWasBusy)
        {
            _primaryWasBusy = false;
            _primary.Finish(succeeded: false);
        }
        Hide();
    }

    /// <summary>開啟當下的錨點：游標、游標所在螢幕、（扣掉自動隱藏工作列的）可用區域、工作列所在邊。</summary>
    private static FlyoutAnchor CaptureAnchor()
    {
        var cursor = Cursor.Position;
        var screen = Screen.FromPoint(cursor);
        var (taskbar, autoHide) = Taskbar.Query();
        return FlyoutPlacement.CreateAnchor(ToPx(screen.Bounds), ToPx(screen.WorkingArea), new PxPoint(cursor.X, cursor.Y),
            taskbar, autoHide);
    }

    /// <summary>依開啟時的錨點重算位置（面板大小改變時也用同一個錨點，不讀當下游標）。</summary>
    private void Reposition()
    {
        if (_anchor is not { } a) return;
        var p = FlyoutPlacement.Place(a, Width, Height, LogicalToDeviceUnits(12));
        Location = new Point(p.X, p.Y);
    }

    // ── 拿不到前景時的關閉保險
    // 正常情況點托盤圖示會讓本程序取得前景，失去焦點（Deactivate）就關；但若 Activate() 被前景鎖擋下，
    // 面板開著卻不是作用中視窗，點別處不會觸發 Deactivate。這時每 200ms 檢查一次：滑鼠在面板外按下就關閉。

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    private void StartOutsideClickWatchIfNotForeground()
    {
        StopOutsideClickWatch();
        if (!IsHandleCreated || GetForegroundWindow() == Handle) return;
        AppLog.Info("狀態面板沒有取得前景，改用滑鼠偵測關閉");
        _outsideWatch = new System.Windows.Forms.Timer { Interval = 200 };
        _outsideWatch.Tick += (_, _) => CheckOutsideClick();
        _outsideWatch.Start();
    }

    private void CheckOutsideClick()
    {
        if (!Visible) { StopOutsideClickWatch(); return; }
        // 取得前景後交給 Deactivate 處理
        if (GetForegroundWindow() == Handle) { StopOutsideClickWatch(); return; }
        if (MouseButtons == MouseButtons.None || _gwMenu.Visible) return;
        if (!Bounds.Contains(Cursor.Position)) HideFlyout(deactivated: true);
    }

    private void StopOutsideClickWatch()
    {
        if (_outsideWatch is null) return;
        _outsideWatch.Stop();
        _outsideWatch.Dispose();
        _outsideWatch = null;
    }

    private static PxRect ToPx(Rectangle r) => new(r.X, r.Y, r.Width, r.Height);

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        // 開子選單（閘道清單）也會讓面板失去焦點，那時不關
        if (Visible && !_gwMenu.Visible) HideFlyout(deactivated: true);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) { HideFlyout(deactivated: false); e.Handled = true; }
        base.OnKeyDown(e);
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        if (Visible) Reposition();
    }

    /// <summary>VPN 狀態改變時由 TrayContext 呼叫；面板沒開就不做事（開啟時會重算）。</summary>
    public void UpdateFromVpn(bool force = false)
    {
        if (IsDisposed || (!Visible && !force)) return;
        var state = _vpn.State;
        var m = StatusPanelModel.Build(state, _vpn.Gateway, BusyText(state), _vpn.LastError ?? _vpn.RetryNote,
            _vpn.WantConnected, _vpn.IsBusy);
        _model = m;
        SuspendLayout();
        _status.Set(m.Tone, m.Headline, m.Badge, m.NextStep);
        if (m.ErrorText is { } err) _error.Set(err, StatusPanelModel.ErrorNextStep);
        _error.Visible = m.ErrorText is not null;
        _infoHeader.Visible = _infoCard.Visible = m.ShowFacts;
        _vipValue.Text = _vpn.Vip ?? "—";
        var gw = _vpn.ConnectedGateway;
        _buildValue.Text = gw is { } n ? StatusPanelModel.FormatSeconds(StatusPanelModel.LastSuccessSeconds(_vpn.History.Records(n))) : "—";
        // 通道流量只在已連線且引擎有回報時顯示（舊版引擎沒有 @@BYTESIN／@@BYTESOUT）
        var traffic = m.ShowFacts ? StatusPanelText.TrafficLine(_vpn.BytesIn, _vpn.BytesOut) : null;
        _traffic.Text = traffic ?? "";
        _traffic.Visible = traffic is not null;
        UpdateElapsed();

        _summary.Text = StatusPanelText.SubnetSummary(_vpn.Settings.RemoteSubnets);
        // 完整網段清單預設收起（網段多時面板會被 chips 撐得很高），設定頁勾選才顯示
        var showList = _vpn.Settings.ShowSubnetList;
        _vpnLaneLabel.Visible = _vpnLane.Visible = showList;
        if (showList)
        {
            var lanes = StatusPanelModel.VpnLanes(_vpn.Settings.RemoteSubnets);
            if (_lanesShown is null || !_lanesShown.SequenceEqual(lanes))
            {
                _vpnLane.SetChips(lanes, ChipKind.Soft, mono: true, emptyText: "尚未設定內網網段");
                _lanesShown = lanes;
                Theme.Apply(_vpnLane);
            }
        }

        _primary.Text = m.PrimaryText;
        _primary.Enabled = m.PrimaryEnabled;
        // 連線類是強調色的主要按鈕；斷線用外框樣式（同 Mac 連線頁）
        _primary.Primary = m.Primary != PanelPrimary.Disconnect;
        if (m.PrimaryBusy) { _primary.Begin(); _primaryWasBusy = true; }
        else if (_primaryWasBusy)
        {
            _primaryWasBusy = false;
            _primary.Finish(succeeded: state == TrayState.Disconnected);
        }
        _gatewayMenu.Text = m.GatewayMenuText;
        _gatewayMenu.Enabled = m.ConnectEnabled || m.DisconnectInMenu;
        _primary.AccessibleDescription = m.Headline;
        AccessibleDescription = m.Headline + (m.Detail is null ? "" : "。" + m.Detail);
        ResumeLayout(true);
    }

    /// <summary>動作進行中的文字：StatusLine 在 Busy 時就是 busyText（TrayText.StatusLine）。</summary>
    private string? BusyText(TrayState state) => state == TrayState.Busy ? _vpn.StatusLine : null;

    /// <summary>每秒更新（只在面板開著時）：已連線時間與狀態更新時間。</summary>
    private void UpdateElapsed()
    {
        var now = DateTimeOffset.Now;
        _fresh.Text = StatusPanelText.Freshness(_vpn.LastSureBriefAt, now, _vpn.BriefUnknownNow);
        var c = _vpn.ConnectedSince;
        _sinceValue.Text = c is { } v ? StatusPanelText.ConnectedSince(StatusPanelModel.FormatElapsed(now - v.Since), v.Approximate) : "—";
        var approximate = c is { Approximate: true };
        if (_sinceApproximateShown == approximate) return;
        _sinceApproximateShown = approximate;
        var tip = approximate ? StatusPanelText.ApproximateSinceTip : "";
        _tips.SetToolTip(_sinceValue, tip);
        _sinceValue.AccessibleDescription = approximate ? tip : null;
    }

    private void OnPrimary()
    {
        if (_model is not { } m) return;
        if (m.Primary == PanelPrimary.Disconnect) _vpn.Disconnect();
        else _vpn.Connect();
        UpdateFromVpn();
    }

    private void ShowGatewayMenu()
    {
        if (_model is not { } m) return;
        foreach (ToolStripItem old in _gwMenu.Items.Cast<ToolStripItem>().ToList()) old.Dispose();
        _gwMenu.Items.Clear();
        var auto = new ToolStripMenuItem(_vpn.State == TrayState.Connected ? "重新連線（自動選擇）" : "連線（自動選擇）") { Enabled = m.ConnectEnabled };
        auto.Click += (_, _) => { _vpn.Connect(); UpdateFromVpn(); };
        _gwMenu.Items.Add(auto);
        var s = _vpn.Settings;
        var connected = _vpn.State == TrayState.Connected ? _vpn.ConnectedGateway : null;
        for (int n = 1; n <= 3; n++)
        {
            if (!GatewayRecorder.IsConfigured(n, s.Gateways)) continue;
            var target = n;
            var item = new ToolStripMenuItem(GatewayRecorder.MenuTitle(n, s.Gateways, _vpn.History))
            {
                Enabled = m.ConnectEnabled,
                Checked = connected == n,
            };
            item.Click += (_, _) => { _vpn.Connect(target); UpdateFromVpn(); };
            _gwMenu.Items.Add(item);
        }
        if (m.DisconnectInMenu)
        {
            _gwMenu.Items.Add(new ToolStripSeparator());
            var d = new ToolStripMenuItem("斷線（停止重試）");
            d.Click += (_, _) => { _vpn.Disconnect(); UpdateFromVpn(); };
            _gwMenu.Items.Add(d);
        }
        _gwMenu.Closed += OnGatewayMenuClosed;
        _gwMenu.Show(_gatewayMenu, new Point(0, _gatewayMenu.Height));
    }

    private void OnGatewayMenuClosed(object? sender, ToolStripDropDownClosedEventArgs e)
    {
        _gwMenu.Closed -= OnGatewayMenuClosed;
        // 點了選單外的地方（焦點不在面板）：面板也一起關
        if (Visible && !ContainsFocus && e.CloseReason == ToolStripDropDownCloseReason.AppClicked) HideFlyout(deactivated: true);
        else if (Visible) Activate();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // 使用者以 Alt+F4 關閉時只隱藏（面板會重複使用）；App 結束時照常關閉
        if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; HideFlyout(deactivated: false); }
        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tick.Dispose();
            _tips.Dispose();
            StopOutsideClickWatch();
            _gwMenu.Dispose();
        }
        base.Dispose(disposing);
    }
}
