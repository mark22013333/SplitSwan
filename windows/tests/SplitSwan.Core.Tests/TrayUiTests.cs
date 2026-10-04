namespace SplitSwan.Core.Tests;

// 介面改版（視覺稿 C）用的純邏輯：主題、狀態面板位置與內容、記錄篩選、閘道成功率條、精靈頁首

public class ThemeRulesTests
{
    [Theory]
    [InlineData(0, true)]
    [InlineData(1, false)]
    [InlineData(2, false)]
    public void IsDarkApps_OnlyZeroIsDark(int value, bool dark) => Assert.Equal(dark, ThemeRules.IsDarkApps(value));

    [Fact]
    public void IsDarkApps_MissingOrWrongType_IsLight()
    {
        Assert.False(ThemeRules.IsDarkApps(null));
        Assert.False(ThemeRules.IsDarkApps("0"));
        Assert.False(ThemeRules.IsDarkApps(0L));
        Assert.False(ThemeRules.IsDarkApps(new byte[] { 0 }));
    }

    [Theory]
    [InlineData(26100, 20)]
    [InlineData(22000, 20)]
    [InlineData(19041, 20)]
    [InlineData(18985, 20)]
    [InlineData(18984, 19)]
    [InlineData(18363, 19)]
    [InlineData(17763, 19)]
    public void DarkModeAttribute_ByBuild(int build, int attr) => Assert.Equal(attr, ThemeRules.DarkModeAttribute(build));

    [Theory]
    [InlineData(17134)]
    [InlineData(0)]
    public void DarkModeAttribute_OldBuild_Null(int build) => Assert.Null(ThemeRules.DarkModeAttribute(build));

    [Theory]
    [InlineData(22000, true)]
    [InlineData(26100, true)]
    [InlineData(19045, false)]
    public void CornerPreference_Win11Only(int build, bool ok) => Assert.Equal(ok, ThemeRules.SupportsCornerPreference(build));

    [Fact]
    public void Palette_MatchesVisualSpecTokens()
    {
        // 視覺稿 .dir-c 的 token（淺／深）
        Assert.Equal(0xFF0E7C86u, ThemePalette.Light.Accent);
        Assert.Equal(0xFFF4F6F6u, ThemePalette.Light.Bg);
        Assert.Equal(0xFF122024u, ThemePalette.Light.Hero);
        Assert.Equal(0xFF3CC3CFu, ThemePalette.Dark.Accent);
        Assert.Equal(0xFF0F1719u, ThemePalette.Dark.Bg);
        Assert.Equal(0xFF0A1113u, ThemePalette.Dark.Hero);
        Assert.False(ThemePalette.Light.IsDark);
        Assert.True(ThemePalette.Dark.IsDark);
        Assert.Same(ThemePalette.Dark, ThemePalette.For(true));
        Assert.Same(ThemePalette.Light, ThemePalette.For(false));
    }

    [Fact]
    public void Mix_Endpoints_AndMidpoint()
    {
        Assert.Equal(0xFFFFFFFFu, ThemePalette.Mix(0xFFFFFFFF, 0xFF000000, 1));
        Assert.Equal(0xFF000000u, ThemePalette.Mix(0xFFFFFFFF, 0xFF000000, 0));
        Assert.Equal(0xFF808080u, ThemePalette.Mix(0xFFFFFFFF, 0xFF000000, 0.5));
        // 超出範圍夾住、結果一律不透明
        Assert.Equal(0xFFFFFFFFu, ThemePalette.Mix(0x00FFFFFF, 0x00000000, 3));
    }
}

public class FlyoutPlacementTests
{
    // 1920×1080，工作列高 48
    private static readonly PxRect Screen = new(0, 0, 1920, 1080);
    private const int W = 320, H = 240, M = 12;

    [Fact]
    public void Bottom_TaskbarAboveCursor_CenteredOnCursor()
    {
        var wa = new PxRect(0, 0, 1920, 1032);
        var cursor = new PxPoint(1700, 1056);
        Assert.Equal(TaskbarEdge.Bottom, FlyoutPlacement.DetectEdge(Screen, wa, cursor));
        var p = FlyoutPlacement.Place(Screen, wa, cursor, W, H, M);
        Assert.Equal(new PxPoint(1700 - W / 2, 1032 - M - H), p);
    }

    [Fact]
    public void Bottom_NearRightEdge_ClampedInside()
    {
        var wa = new PxRect(0, 0, 1920, 1032);
        var p = FlyoutPlacement.Place(Screen, wa, new PxPoint(1910, 1056), W, H, M);
        Assert.Equal(1920 - M - W, p.X);
        Assert.Equal(1032 - M - H, p.Y);
    }

    [Fact]
    public void Top_Taskbar()
    {
        var wa = new PxRect(0, 48, 1920, 1032);
        var cursor = new PxPoint(1800, 20);
        Assert.Equal(TaskbarEdge.Top, FlyoutPlacement.DetectEdge(Screen, wa, cursor));
        var p = FlyoutPlacement.Place(Screen, wa, cursor, W, H, M);
        Assert.Equal(new PxPoint(1920 - M - W, 48 + M), p);
    }

    [Fact]
    public void Left_Taskbar()
    {
        var wa = new PxRect(62, 0, 1858, 1080);
        var cursor = new PxPoint(30, 900);
        Assert.Equal(TaskbarEdge.Left, FlyoutPlacement.DetectEdge(Screen, wa, cursor));
        var p = FlyoutPlacement.Place(Screen, wa, cursor, W, H, M);
        Assert.Equal(new PxPoint(62 + M, 900 - H / 2), p);
    }

    [Fact]
    public void Right_Taskbar_NearBottom_ClampedUp()
    {
        var wa = new PxRect(0, 0, 1858, 1080);
        var cursor = new PxPoint(1890, 1070);
        Assert.Equal(TaskbarEdge.Right, FlyoutPlacement.DetectEdge(Screen, wa, cursor));
        var p = FlyoutPlacement.Place(Screen, wa, cursor, W, H, M);
        Assert.Equal(new PxPoint(1858 - M - W, 1080 - M - H), p);
    }

    [Fact]
    public void SecondaryMonitor_NegativeCoordinates()
    {
        // 主螢幕左側的副螢幕：X 從 -2560 開始，工作列在下
        var bounds = new PxRect(-2560, -360, 2560, 1440);
        var wa = new PxRect(-2560, -360, 2560, 1392);
        var cursor = new PxPoint(-100, 1056);
        Assert.Equal(TaskbarEdge.Bottom, FlyoutPlacement.DetectEdge(bounds, wa, cursor));
        var p = FlyoutPlacement.Place(bounds, wa, cursor, W, H, M);
        Assert.Equal(new PxPoint(-M - W, -360 + 1392 - M - H), p);
        Assert.True(p.X >= wa.X && p.X + W <= wa.Right);
    }

    [Fact]
    public void SecondaryMonitor_AboveWithLeftTaskbar_Negative()
    {
        var bounds = new PxRect(-1920, -1080, 1920, 1080);
        var wa = new PxRect(-1872, -1080, 1872, 1080);
        var cursor = new PxPoint(-1900, -1070);
        Assert.Equal(TaskbarEdge.Left, FlyoutPlacement.DetectEdge(bounds, wa, cursor));
        var p = FlyoutPlacement.Place(bounds, wa, cursor, W, H, M);
        Assert.Equal(new PxPoint(-1872 + M, -1080 + M), p);
    }

    [Fact]
    public void PanelLargerThanWorkingArea_PinnedToTopLeftOfWorkingArea()
    {
        var bounds = new PxRect(0, 0, 800, 600);
        var wa = new PxRect(0, 0, 800, 552);
        var p = FlyoutPlacement.Place(bounds, wa, new PxPoint(780, 580), 1000, 900, M);
        Assert.Equal(new PxPoint(M, M), p);
    }

    [Fact]
    public void PanelWiderOnly_StillInsideVertically()
    {
        var bounds = new PxRect(100, 0, 300, 1080);
        var wa = new PxRect(100, 0, 300, 1032);
        var p = FlyoutPlacement.Place(bounds, wa, new PxPoint(390, 1060), 400, H, M);
        Assert.Equal(100 + M, p.X);
        Assert.Equal(1032 - M - H, p.Y);
    }

    [Theory]
    [InlineData(960, 1075, TaskbarEdge.Bottom)]
    [InlineData(960, 3, TaskbarEdge.Top)]
    [InlineData(2, 500, TaskbarEdge.Left)]
    [InlineData(1918, 500, TaskbarEdge.Right)]
    public void AutoHide_UsesNearestEdgeToCursor(int x, int y, TaskbarEdge edge) =>
        Assert.Equal(edge, FlyoutPlacement.DetectEdge(Screen, Screen, new PxPoint(x, y)));

    [Fact]
    public void NegativeMargin_TreatedAsZero()
    {
        var wa = new PxRect(0, 0, 1920, 1032);
        var p = FlyoutPlacement.Place(Screen, wa, new PxPoint(1919, 1060), W, H, -5);
        Assert.Equal(new PxPoint(1920 - W, 1032 - H), p);
    }
}

public class FlyoutToggleTests
{
    private static readonly DateTimeOffset T0 = new(2026, 10, 4, 10, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Visible_ClickCloses() => Assert.False(FlyoutToggle.ShouldOpen(true, null, T0));

    [Fact]
    public void NeverClosed_Opens() => Assert.True(FlyoutToggle.ShouldOpen(false, null, T0));

    [Fact]
    public void JustClosedByDeactivate_ClickDoesNotReopen() =>
        Assert.False(FlyoutToggle.ShouldOpen(false, T0, T0.AddMilliseconds(150)));

    [Fact]
    public void ClosedLongAgo_Opens() =>
        Assert.True(FlyoutToggle.ShouldOpen(false, T0, T0 + FlyoutToggle.ReopenGuard));

    [Fact]
    public void ClockWentBackwards_Opens() =>
        Assert.True(FlyoutToggle.ShouldOpen(false, T0, T0.AddSeconds(-5)));
}

public class LogViewTests
{
    [Fact]
    public void Parse_Levels()
    {
        var info = LogView.Parse("10:41:02 已連線：vpn1，虛擬 IP 192.0.2.200");
        Assert.Equal(("10:41:02", LogLevel.Info, "已連線：vpn1，虛擬 IP 192.0.2.200"), (info.Time, info.Level, info.Text));
        var eng = LogView.Parse("10:41:05 │ IKE_SA vpn1 established");
        Assert.Equal((LogLevel.Engine, "IKE_SA vpn1 established"), (eng.Level, eng.Text));
        var err = LogView.Parse("11:03:40 錯誤：連線失敗：對方沒有回應");
        Assert.Equal((LogLevel.Error, "連線失敗：對方沒有回應"), (err.Level, err.Text));
        Assert.Equal("11:03:40 錯誤：連線失敗：對方沒有回應", err.Raw);
    }

    [Fact]
    public void Parse_ErrorTextInsideEngineLine_StaysEngine()
    {
        Assert.Equal(LogLevel.Engine, LogView.Parse("10:00:00 │ 錯誤：xyz").Level);
        // 「錯誤：」不在行首（訊息中間）不算錯誤
        Assert.Equal(LogLevel.Info, LogView.Parse("10:00:00 設定檔提示：錯誤：xyz").Level);
    }

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("no time here")]
    [InlineData("１０:00:00 全形數字")]
    [InlineData("10-00-00 x")]
    public void Parse_Malformed_NoTime_Info(string? line)
    {
        var e = LogView.Parse(line);
        Assert.Equal("", e.Time);
        Assert.Equal(LogLevel.Info, e.Level);
        Assert.Equal(line ?? "", e.Text);
    }

    [Fact]
    public void Parse_NoTimeButErrorTag()
    {
        var e = LogView.Parse("錯誤：壞了");
        Assert.Equal(("", LogLevel.Error, "壞了"), (e.Time, e.Level, e.Text));
    }

    private static readonly string[] Sample =
    [
        "10:41:02 依紀錄排序：VPN1 → VPN2 → VPN3",
        "10:41:05 │ vpn1：IKE_SA 已建立",
        "10:41:05 │ 路由 198.51.100.0/24 → WSL",
        "10:41:06 已連線 VPN1",
        "11:03:40 錯誤：VPN3 沒有回應",
    ];

    [Fact]
    public void Filter_And_Count()
    {
        var entries = Sample.Select(LogView.Parse).ToList();
        Assert.Equal((5, 1, 2), LogView.Count(entries));
        Assert.Equal(5, LogView.Filter(entries, LogFilter.All).Count);
        Assert.Single(LogView.Filter(entries, LogFilter.Errors));
        Assert.All(LogView.Filter(entries, LogFilter.Engine), e => Assert.Equal(LogLevel.Engine, e.Level));
        Assert.Equal(2, LogView.Filter(entries, LogFilter.Engine).Count);
    }

    [Fact]
    public void Count_UpdatesWhenLinesAdded()
    {
        var entries = Sample.Select(LogView.Parse).ToList();
        entries.Add(LogView.Parse("11:05:00 錯誤：又失敗"));
        Assert.Equal((6, 2, 2), LogView.Count(entries));
        Assert.Equal("錯誤 2", LogView.SegmentTitle(LogFilter.Errors, LogView.Count(entries).Errors));
    }

    [Fact]
    public void SegmentTitles()
    {
        Assert.Equal("全部", LogView.SegmentTitle(LogFilter.All, 3));
        Assert.Equal("錯誤 0", LogView.SegmentTitle(LogFilter.Errors, 0));
        Assert.Equal("引擎", LogView.SegmentTitle(LogFilter.Engine, 3));
        Assert.Equal("錯誤", LogView.LevelTitle(LogLevel.Error));
        Assert.Equal("引擎", LogView.LevelTitle(LogLevel.Engine));
        Assert.Equal("訊息", LogView.LevelTitle(LogLevel.Info));
    }

    [Fact]
    public void CopyText_IsFilteredRawLines_Crlf()
    {
        var entries = Sample.Select(LogView.Parse).ToList();
        Assert.Equal("10:41:05 │ vpn1：IKE_SA 已建立\r\n10:41:05 │ 路由 198.51.100.0/24 → WSL",
            LogView.CopyText(LogView.Filter(entries, LogFilter.Engine)));
        Assert.Equal("", LogView.CopyText([]));
    }
}

public class StatusPanelModelTests
{
    [Fact]
    public void Connected()
    {
        var m = StatusPanelModel.Build(TrayState.Connected, "vpn1", null, null, wantConnected: true, busy: false);
        Assert.Equal(StatusTone.Ok, m.Tone);
        Assert.Equal("已連線　VPN1", m.Headline);
        Assert.True(m.ShowFacts);
        Assert.Equal(PanelPrimary.Disconnect, m.Primary);
        Assert.Equal("斷線", m.PrimaryText);
        Assert.True(m.PrimaryEnabled);
        Assert.False(m.DisconnectInMenu);
        Assert.Equal("改連到…", m.GatewayMenuText);
    }

    [Fact]
    public void Connected_UnknownGateway() =>
        Assert.Equal("已連線", StatusPanelModel.Build(TrayState.Connected, " ", null, null, true, false).Headline);

    [Fact]
    public void Busy_DisconnectEnabled_ConnectDisabled()
    {
        var m = StatusPanelModel.Build(TrayState.Busy, null, "連線中（VPN1）…", null, true, busy: true);
        Assert.Equal(StatusTone.Warn, m.Tone);
        Assert.Equal("連線中（VPN1）…", m.Headline);
        Assert.False(m.ShowFacts);
        Assert.Equal(PanelPrimary.Disconnect, m.Primary);
        Assert.True(m.PrimaryEnabled);
        Assert.False(m.ConnectEnabled);
    }

    [Fact]
    public void Busy_NoText() =>
        Assert.Equal("處理中…", StatusPanelModel.Build(TrayState.Busy, null, null, null, false, true).Headline);

    [Fact]
    public void Error_ShowsReason_ReconnectPrimary_DisconnectInMenuWhenRetrying()
    {
        var m = StatusPanelModel.Build(TrayState.Error, null, null, "對方沒有回應\r\n第二行", wantConnected: true, busy: false);
        Assert.Equal(StatusTone.Bad, m.Tone);
        Assert.Equal("未連上", m.Headline);
        Assert.Equal("對方沒有回應  第二行", m.Detail);
        Assert.Equal(PanelPrimary.Reconnect, m.Primary);
        Assert.Equal("重新連線", m.PrimaryText);
        Assert.True(m.DisconnectInMenu);
        Assert.Equal("選擇閘道…", m.GatewayMenuText);
    }

    [Fact]
    public void Error_NotWanted_NoDisconnect()
    {
        var m = StatusPanelModel.Build(TrayState.Error, null, null, "x", wantConnected: false, busy: false);
        Assert.False(m.DisconnectEnabled);
        Assert.False(m.DisconnectInMenu);
    }

    [Fact]
    public void Unknown_ExplainsNotDisconnected()
    {
        var m = StatusPanelModel.Build(TrayState.Unknown, "vpn2", null, null, wantConnected: true, busy: false);
        Assert.Equal(StatusTone.Warn, m.Tone);
        Assert.Equal("狀態不明", m.Headline);
        Assert.Contains("不代表已斷線", m.Detail);
        Assert.Equal(PanelPrimary.Connect, m.Primary);
        Assert.True(m.DisconnectInMenu);
    }

    [Fact]
    public void Disconnected()
    {
        var m = StatusPanelModel.Build(TrayState.Disconnected, null, null, null, false, false);
        Assert.Equal(StatusTone.Idle, m.Tone);
        Assert.Equal("未連線", m.Headline);
        Assert.Null(m.Detail);
        Assert.Equal("連線", m.PrimaryText);
        Assert.True(m.PrimaryEnabled);
        Assert.False(m.DisconnectEnabled);
    }

    [Theory]
    [InlineData(0, "0:00:00")]
    [InlineData(65, "0:01:05")]
    [InlineData(4328, "1:12:08")]
    [InlineData(90061, "25:01:01")]
    [InlineData(-3, "0:00:00")]
    public void FormatElapsed(int seconds, string text) =>
        Assert.Equal(text, StatusPanelModel.FormatElapsed(TimeSpan.FromSeconds(seconds)));

    [Fact]
    public void FormatSeconds()
    {
        Assert.Equal("2.8 秒", StatusPanelModel.FormatSeconds(2.84));
        Assert.Equal("—", StatusPanelModel.FormatSeconds(null));
        Assert.Equal("—", StatusPanelModel.FormatSeconds(double.NaN));
        Assert.Equal("—", StatusPanelModel.FormatSeconds(-1));
    }

    private static GatewayAttempt A(bool ok, double? s = null) =>
        new(1, ok, DateTimeOffset.UnixEpoch, s, "203.0.113.10");

    [Fact]
    public void LastSuccessSeconds_NewestSuccess()
    {
        Assert.Equal(3.1, StatusPanelModel.LastSuccessSeconds([A(true, 2.0), A(true, 3.1), A(false)]));
        Assert.Null(StatusPanelModel.LastSuccessSeconds([A(false)]));
        Assert.Null(StatusPanelModel.LastSuccessSeconds([A(true, 2.0), A(true, null)]));
        Assert.Null(StatusPanelModel.LastSuccessSeconds([]));
    }

    [Fact]
    public void VpnLanes_TrimDedupe()
    {
        Assert.Equal(["192.0.2.0/25", "198.51.100.0/24"],
            StatusPanelModel.VpnLanes([" 192.0.2.0/25", "", "198.51.100.0/24", "192.0.2.0/25 "]));
        Assert.Empty(StatusPanelModel.VpnLanes([]));
    }

    [Fact]
    public void GatewayMeter_FromRecords()
    {
        var none = GatewayMeter.From([]);
        Assert.Equal((0, 0, StatusTone.Idle, "—"), (none.Ok, none.Total, none.Tone, none.Label));

        var full = GatewayMeter.From([.. Enumerable.Range(0, 10).Select(_ => A(true))]);
        Assert.Equal(("10/10", StatusTone.Ok, 1.0), (full.Label, full.Tone, full.Fraction));

        var nine = GatewayMeter.From([.. Enumerable.Range(0, 9).Select(_ => A(true)), A(false)]);
        Assert.Equal(("9/10", StatusTone.Ok), (nine.Label, nine.Tone));

        var four = GatewayMeter.From([.. Enumerable.Range(0, 4).Select(_ => A(true)), .. Enumerable.Range(0, 6).Select(_ => A(false))]);
        Assert.Equal(("4/10", StatusTone.Warn, 0.4), (four.Label, four.Tone, four.Fraction));

        var few = GatewayMeter.From([A(true), A(false)]);
        Assert.Equal(("1/2", StatusTone.Warn), (few.Label, few.Tone));
    }

    [Fact]
    public void GatewayMeter_FromRealHistoryRecords()
    {
        var h = new GatewayHistory();
        for (int i = 0; i < 12; i++) h.Record(new GatewayAttempt(2, i % 4 != 0, DateTimeOffset.UnixEpoch.AddMinutes(i), 2.0, "203.0.113.20"));
        var m = GatewayMeter.From(h.Records(2));
        Assert.Equal(10, m.Total);   // 只保留最近 10 筆
        Assert.Equal("8/10", m.Label);
    }

    [Fact]
    public void GatewayDot()
    {
        Assert.Equal(StatusTone.Ok, GatewayMeter.DotTone(connectedHere: true, cooling: true));
        Assert.Equal(StatusTone.Warn, GatewayMeter.DotTone(false, true));
        Assert.Equal(StatusTone.Idle, GatewayMeter.DotTone(false, false));
    }
}

public class WizardOverviewTests
{
    [Fact]
    public void Heading()
    {
        Assert.Equal("1 / 6　系統檢查", WizardOverview.Heading(WizardStep.SystemCheck));
        Assert.Equal("3 / 6　下載並匯入 Ubuntu", WizardOverview.Heading(WizardStep.ImportDistro));
    }

    [Fact]
    public void Lanes_DoneAndNext()
    {
        var s = new SetupWizardState();
        s.Complete(WizardStep.SystemCheck, skipped: false);
        s.GoNext();
        s.Complete(WizardStep.InstallWsl, skipped: true);
        s.GoNext();
        Assert.Equal(WizardStep.ImportDistro, s.Current);
        var (done, next) = WizardOverview.Lanes(s);
        Assert.Equal([WizardStep.SystemCheck, WizardStep.InstallWsl], done);
        Assert.Equal([WizardStep.SetupStrongSwan, WizardStep.Configure, WizardStep.TestConnection], next);
        Assert.Equal(2.0 / 6, WizardOverview.Progress(s), 6);
    }

    [Fact]
    public void Lanes_Fresh()
    {
        var (done, next) = WizardOverview.Lanes(new SetupWizardState());
        Assert.Empty(done);
        Assert.Equal(5, next.Count);
        Assert.Equal(0, WizardOverview.Progress(new SetupWizardState()));
    }

    [Fact]
    public void Lanes_AllDone()
    {
        var s = new SetupWizardState();
        foreach (var st in SetupWizardState.Steps) s.Complete(st, skipped: false);
        while (s.GoNext()) { }
        var (done, next) = WizardOverview.Lanes(s);
        Assert.Equal(5, done.Count);
        Assert.Empty(next);
        Assert.Equal(1.0, WizardOverview.Progress(s));
    }
}

// review4：面板錨點、自動隱藏工作列、按下滑鼠時判斷開關

public class FlyoutAnchorTests
{
    private static readonly PxRect Screen = new(0, 0, 1920, 1080);
    private const int W = 320, M = 12;

    [Fact]
    public void SameAnchor_DifferentHeights_StaysOnSameEdgeAndX()
    {
        var wa = new PxRect(0, 0, 1920, 1032);
        var anchor = FlyoutPlacement.CreateAnchor(Screen, wa, new PxPoint(1700, 1056), null, autoHide: false);
        var tall = FlyoutPlacement.Place(anchor, W, 300, M);
        var shortP = FlyoutPlacement.Place(anchor, W, 200, M);
        Assert.Equal(TaskbarEdge.Bottom, anchor.Edge);
        Assert.Equal(tall.X, shortP.X);
        // 貼齊工作列：下緣不變
        Assert.Equal(tall.Y + 300, shortP.Y + 200);
        Assert.Equal(1032 - M, shortP.Y + 200);
    }

    [Fact]
    public void AutoHide_SameAnchor_DifferentHeights_NeverJumpsToOtherEdge()
    {
        // 自動隱藏（WorkingArea＝Bounds）、取不到工作列：邊由開啟時的游標決定，之後重算不再看游標
        var anchor = FlyoutPlacement.CreateAnchor(Screen, Screen, new PxPoint(1800, 1075), null, autoHide: true);
        Assert.Equal(TaskbarEdge.Bottom, anchor.Edge);
        foreach (var h in new[] { 120, 240, 360 })
        {
            var p = FlyoutPlacement.Place(anchor, W, h, M);
            Assert.Equal(1080 - M, p.Y + h);
            Assert.Equal(1920 - M - W, p.X);
        }
    }

    [Fact]
    public void Place_WithAnchor_EqualsLegacyPlace()
    {
        var wa = new PxRect(62, 0, 1858, 1080);
        var cursor = new PxPoint(30, 900);
        var anchor = FlyoutPlacement.CreateAnchor(Screen, wa, cursor, null, false);
        Assert.Equal(FlyoutPlacement.Place(Screen, wa, cursor, W, 240, M), FlyoutPlacement.Place(anchor, W, 240, M));
    }

    [Fact]
    public void EffectiveWorkingArea_AutoHideBottom_GivesUpThickness()
    {
        // 隱藏中的工作列：只露 2px 在螢幕內
        var tb = new PxRect(0, 1078, 1920, 48);
        Assert.Equal(new PxRect(0, 0, 1920, 1032), FlyoutPlacement.EffectiveWorkingArea(Screen, Screen, tb, autoHide: true));
        // 顯示中的工作列
        Assert.Equal(new PxRect(0, 0, 1920, 1032),
            FlyoutPlacement.EffectiveWorkingArea(Screen, Screen, new PxRect(0, 1032, 1920, 48), autoHide: true));
    }

    [Fact]
    public void EffectiveWorkingArea_AutoHide_TopLeftRight()
    {
        Assert.Equal(new PxRect(0, 48, 1920, 1032),
            FlyoutPlacement.EffectiveWorkingArea(Screen, Screen, new PxRect(0, -46, 1920, 48), true));
        Assert.Equal(new PxRect(62, 0, 1858, 1080),
            FlyoutPlacement.EffectiveWorkingArea(Screen, Screen, new PxRect(-60, 0, 62, 1080), true));
        Assert.Equal(new PxRect(0, 0, 1858, 1080),
            FlyoutPlacement.EffectiveWorkingArea(Screen, Screen, new PxRect(1918, 0, 62, 1080), true));
    }

    [Fact]
    public void EffectiveWorkingArea_FallsBack()
    {
        var tb = new PxRect(0, 1078, 1920, 48);
        var wa = new PxRect(0, 0, 1920, 1032);
        // 不是自動隱藏
        Assert.Equal(Screen, FlyoutPlacement.EffectiveWorkingArea(Screen, Screen, tb, autoHide: false));
        // 取不到工作列
        Assert.Equal(Screen, FlyoutPlacement.EffectiveWorkingArea(Screen, Screen, null, autoHide: true));
        // WorkingArea 已經讓出空間
        Assert.Equal(wa, FlyoutPlacement.EffectiveWorkingArea(Screen, wa, tb, autoHide: true));
        // 工作列在另一個螢幕（主螢幕左側的副螢幕）
        var second = new PxRect(-2560, 0, 2560, 1440);
        Assert.Equal(second, FlyoutPlacement.EffectiveWorkingArea(second, second, tb, autoHide: true));
        // 矩形不合理
        Assert.Equal(Screen, FlyoutPlacement.EffectiveWorkingArea(Screen, Screen, new PxRect(0, 0, 1920, 0), true));
        Assert.Equal(Screen, FlyoutPlacement.EffectiveWorkingArea(Screen, Screen, new PxRect(0, 0, 1920, 800), true));
    }

    [Fact]
    public void CreateAnchor_AutoHide_PanelNotCoveredByTaskbar()
    {
        var tb = new PxRect(0, 1078, 1920, 48);
        var anchor = FlyoutPlacement.CreateAnchor(Screen, Screen, new PxPoint(1800, 1079), tb, autoHide: true);
        Assert.Equal(TaskbarEdge.Bottom, anchor.Edge);
        var p = FlyoutPlacement.Place(anchor, W, 240, M);
        Assert.True(p.Y + 240 <= 1080 - 48, "面板下緣要在工作列（滑出時）上方");
    }

    [Fact]
    public void CreateAnchor_AutoHide_NegativeCoordinates()
    {
        var bounds = new PxRect(-1920, -1080, 1920, 1080);
        var tb = new PxRect(-1920, -1080 - 46, 1920, 48);   // 副螢幕上方的工作列（隱藏中）
        var anchor = FlyoutPlacement.CreateAnchor(bounds, bounds, new PxPoint(-100, -1079), tb, autoHide: true);
        // 讓出整個厚度 48（不是只讓露出來的 2px）
        Assert.Equal(new PxRect(-1920, -1032, 1920, 1032), anchor.WorkingArea);
        Assert.Equal(TaskbarEdge.Top, anchor.Edge);
        Assert.Equal(-1032 + M, FlyoutPlacement.Place(anchor, W, 240, M).Y);
    }
}

public class FlyoutToggleOnClickTests
{
    private static readonly DateTimeOffset T0 = new(2026, 10, 4, 10, 0, 0, TimeSpan.Zero);

    [Fact]
    public void VisibleNow_Closes() => Assert.False(FlyoutToggle.ShouldOpenOnClick(true, false, T0, null, T0));

    [Fact]
    public void VisibleAtMouseDown_DoesNotReopen() =>
        Assert.False(FlyoutToggle.ShouldOpenOnClick(false, true, T0, T0.AddMilliseconds(5), T0.AddMilliseconds(50)));

    [Fact]
    public void LongPress_ClosedAtDown_DoesNotReopenOnRelease()
    {
        // 按住 1.5 秒才放開：失去焦點關閉發生在按下的瞬間
        var down = T0;
        Assert.False(FlyoutToggle.ShouldOpenOnClick(false, false, down, down.AddMilliseconds(10), down.AddMilliseconds(1500)));
    }

    [Fact]
    public void ClosedJustBeforeDown_WithinGuard_DoesNotReopen() =>
        Assert.False(FlyoutToggle.ShouldOpenOnClick(false, false, T0, T0.AddMilliseconds(-100), T0.AddMilliseconds(80)));

    [Fact]
    public void ClosedLongBeforeDown_Opens() =>
        Assert.True(FlyoutToggle.ShouldOpenOnClick(false, false, T0, T0 - TimeSpan.FromSeconds(5), T0.AddMilliseconds(80)));

    [Fact]
    public void NeverClosed_Opens() => Assert.True(FlyoutToggle.ShouldOpenOnClick(false, false, T0, null, T0.AddMilliseconds(80)));

    [Fact]
    public void NoMouseDown_FallsBackToNow()
    {
        Assert.False(FlyoutToggle.ShouldOpenOnClick(false, false, null, T0.AddMilliseconds(-100), T0));
        Assert.True(FlyoutToggle.ShouldOpenOnClick(false, false, null, T0 - TimeSpan.FromSeconds(2), T0));
    }
}
