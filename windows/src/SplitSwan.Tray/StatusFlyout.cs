using System.Drawing;
using System.Runtime.InteropServices;
using SplitSwan.Core;
using SplitSwan.Tray.Controls;

namespace SplitSwan.Tray;

/// <summary>
/// 狀態面板（視覺稿 C）：左鍵托盤圖示彈出，再點一次或失去焦點就關。
/// 無邊框、最上層、不出現在工作列與 Alt+Tab；Windows 11 圓角。位置由 Core 的 FlyoutPlacement 計算。
/// 內容：狀態大字＋狀態點、虛擬 IP／已連線時間／建立耗時、通道流量（已連線且引擎有回報時）、狀態更新時間、
/// 網段摘要一行（設定勾選「顯示完整網段清單」時再加上網段 chips）與「其他所有流量走本機網路」、
/// 按鈕（設定／改連到…／連線或斷線）。已連線時間與狀態更新時間每秒更新，只在面板開著時計時。
/// </summary>
internal sealed class StatusFlyout : ThemedForm
{
    private const int PanelWidth = 320;

    private readonly VpnCoordinator _vpn;
    private readonly Action _openSettings;
    private readonly TableLayoutPanel _hero = UiLayout.Table(1);
    private readonly StatusDot _dot = new(10, halo: true);
    private readonly ThemedLabel _headline = new("", TextRole.HeroInk, Theme.Ui(13.5f, FontStyle.Bold));
    private readonly ThemedLabel _detail = new("", TextRole.HeroMuted);
    private readonly TableLayoutPanel _facts = UiLayout.Table(3, 2);
    private readonly ThemedLabel _vipValue = new("", TextRole.HeroInk, Theme.Mono(9f));
    private readonly ThemedLabel _sinceValue = new("", TextRole.HeroInk, Theme.Mono(9f));
    private readonly ThemedLabel _buildValue = new("", TextRole.HeroInk, Theme.Mono(9f));
    private readonly ThemedLabel _traffic = new("", TextRole.HeroInk, Theme.Mono(9f));
    private readonly ThemedLabel _fresh = new("", TextRole.HeroMuted, Theme.Ui(8.25f));
    private readonly ThemedLabel _summary = new("", TextRole.Ink);
    private readonly ThemedLabel _vpnLaneLabel = LaneLabel("走 VPN");
    private readonly ChipFlow _vpnLane = new();
    private readonly ChipFlow _localLane = new();
    private readonly ThemedButton _settings = new("設定");
    private readonly ThemedButton _gatewayMenu = new("改連到…") { DropDownArrow = true };
    private readonly ThemedButton _primary = new("斷線", primary: true);
    private readonly ContextMenuStrip _gwMenu = new() { ShowImageMargin = false, ShowCheckMargin = true };
    private readonly System.Windows.Forms.Timer _tick = new() { Interval = 1000 };
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

        // ── 頂部深色區：狀態大字、說明、三欄數值
        _hero.Padding = new Padding(16, 14, 16, 14);
        var heroStack = _hero;
        var big = UiLayout.Flow();
        _dot.Margin = new Padding(0, 4, 6, 0);
        _headline.Margin = Padding.Empty;
        big.Controls.Add(_dot);
        big.Controls.Add(_headline);
        heroStack.Controls.Add(big, 0, 0);
        _detail.MaximumSize = new Size(PanelWidth - 32, 0);
        _detail.Margin = new Padding(0, 6, 0, 0);
        heroStack.Controls.Add(_detail, 0, 1);
        for (int i = 0; i < 3; i++) _facts.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, (PanelWidth - 32) / 3f));
        _facts.Margin = new Padding(0, 10, 0, 0);
        AddFact(0, "虛擬 IP", _vipValue);
        AddFact(1, "已連線", _sinceValue);
        AddFact(2, "建立耗時", _buildValue);
        heroStack.Controls.Add(_facts, 0, 2);
        _traffic.MaximumSize = new Size(PanelWidth - 32, 0);
        _traffic.Margin = new Padding(0, 8, 0, 0);
        _traffic.AccessibleName = "通道流量";
        heroStack.Controls.Add(_traffic, 0, 3);
        _fresh.MaximumSize = new Size(PanelWidth - 32, 0);
        _fresh.Margin = new Padding(0, 6, 0, 0);
        _fresh.AccessibleName = "狀態更新時間";
        heroStack.Controls.Add(_fresh, 0, 4);

        // ── 內容：分流說明與按鈕
        var body = UiLayout.Table(1);
        body.Padding = new Padding(16, 14, 16, 14);
        // 每個控制項都指定 (欄, 列)：隱藏的網段 chips 列不會讓後面的控制項往前遞補
        var lanes = UiLayout.Table(2, 3);
        lanes.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 82));
        lanes.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, PanelWidth - 32 - 82));
        _summary.MaximumSize = new Size(PanelWidth - 32, 0);
        _summary.Margin = new Padding(0, 0, 0, 8);
        _summary.AccessibleName = "走 VPN 的網段";
        lanes.Controls.Add(_summary, 0, 0);
        lanes.SetColumnSpan(_summary, 2);
        lanes.Controls.Add(_vpnLaneLabel, 0, 1);
        lanes.Controls.Add(_vpnLane, 1, 1);
        lanes.Controls.Add(LaneLabel("走本機網路"), 0, 2);
        lanes.Controls.Add(_localLane, 1, 2);
        _vpnLane.MaximumSize = new Size(PanelWidth - 32 - 82, 0);
        _localLane.SetChips(["其他所有流量"], ChipKind.Local, mono: false);
        body.Controls.Add(lanes, 0, 0);

        var buttons = UiLayout.Flow(FlowDirection.RightToLeft);
        buttons.Anchor = AnchorStyles.Right;
        buttons.Margin = new Padding(0, 10, 0, 0);
        buttons.Controls.AddRange([_primary, _gatewayMenu, _settings]);
        body.Controls.Add(buttons, 0, 1);

        var root = UiLayout.Table(1, 2);
        root.Controls.Add(_hero, 0, 0);
        root.Controls.Add(body, 0, 1);
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, PanelWidth));
        _hero.Dock = DockStyle.Fill;
        body.Dock = DockStyle.Fill;
        Controls.Add(root);

        _settings.Click += (_, _) => { HideFlyout(deactivated: false); _openSettings(); };
        _gatewayMenu.Click += (_, _) => ShowGatewayMenu();
        _primary.Click += (_, _) => OnPrimary();
        _gwMenu.Renderer = new ThemedMenuRenderer();
        _tick.Tick += (_, _) => UpdateElapsed();
        FinishLayout();
        OnThemeApplied();
    }

    private void AddFact(int col, string caption, ThemedLabel value)
    {
        var cap = new ThemedLabel(caption, TextRole.HeroMuted, Theme.Ui(7.5f)) { Margin = Padding.Empty };
        value.Margin = new Padding(0, 1, 0, 0);
        value.AutoEllipsis = true;
        value.AutoSize = false;
        value.Size = new Size((PanelWidth - 32) / 3 - 4, 18);   // 96 DPI 的邏輯像素，視窗縮放時一起放大
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
        _hero.BackColor = Theme.C(Theme.Palette.Hero);
        BackColor = Theme.Surface;
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
        _dot.Tone = m.Tone;
        _headline.Text = m.Headline;
        _detail.Text = m.Detail ?? "";
        _detail.Visible = m.Detail is not null;
        _facts.Visible = m.ShowFacts;
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
        if (_vpn.ConnectedSince is not { } c) { _sinceValue.Text = "—"; return; }
        var text = StatusPanelModel.FormatElapsed(now - c.Since);
        _sinceValue.Text = c.Approximate ? "≥ " + text : text;
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
            StopOutsideClickWatch();
            _gwMenu.Dispose();
        }
        base.Dispose(disposing);
    }
}
