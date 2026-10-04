using SplitSwan.Core;

namespace SplitSwan.Core.Tests;

/// <summary>第二階段（F4 閘道輪替＋托盤圖示樣式）中由托盤擁有的純邏輯。</summary>
public class EngineCommandOrderTests
{
    private const string Ps1 = @"C:\App\engine\splitswan-wsl.ps1";
    private const string Conf = @"C:\Data\conf";

    [Fact]
    public void Connect_WithOrder_AddsOrderArgument()
    {
        var a = EngineCommand.Arguments(EngineAction.Connect, Ps1, Conf, noInstall: true, order: [2, 1, 3]);
        Assert.Equal(new[]
        {
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Ps1,
            "-Action", "connect", "-ConfDir", Conf, "-NoInstall", "-Order", "2,1,3",
        }, a);
    }

    [Fact]
    public void Connect_SingleGateway()
    {
        var a = EngineCommand.Arguments(EngineAction.Connect, Ps1, Conf, order: [2]);
        Assert.Equal(new[] { "-Order", "2" }, a.Skip(a.Count - 2));
    }

    [Fact]
    public void Connect_WithoutOrder_HasNoOrderArgument() =>
        Assert.DoesNotContain("-Order", EngineCommand.Arguments(EngineAction.Connect, Ps1, Conf));

    [Theory]
    [InlineData(EngineAction.Disconnect)]
    [InlineData(EngineAction.Brief)]
    [InlineData(EngineAction.Status)]
    public void OtherActions_IgnoreOrder(EngineAction action) =>
        Assert.DoesNotContain("-Order", EngineCommand.Arguments(action, Ps1, Conf, order: [1]));

    [Fact]
    public void PauseAtEnd_StaysLast()
    {
        var a = EngineCommand.Arguments(EngineAction.Connect, Ps1, Conf, pauseAtEnd: true, order: [1, 2]);
        Assert.Equal("-PauseAtEnd", a[^1]);
        Assert.Equal("1,2", a[^2]);
    }

    [Theory]
    [InlineData(new int[0])]
    [InlineData(new[] { 0 })]
    [InlineData(new[] { 4 })]
    [InlineData(new[] { -1 })]
    [InlineData(new[] { 1, 1 })]
    public void BadOrder_Throws(int[] order) =>
        Assert.Throws<ArgumentException>(() => EngineCommand.Arguments(EngineAction.Connect, Ps1, Conf, order: order));

    [Fact]
    public void EngineScript_SupportsOrder()
    {
        // 托盤每次 connect 都帶 -Order；引擎不支援時每次都會失敗（build.sh 也有同樣的檢查）
        var ps1 = Path.Combine(RepoRoot(), "tools", "windows", "splitswan-wsl.ps1");
        var text = File.ReadAllText(ps1);
        Assert.Contains("[string]$Order", text);
        Assert.Contains("@@ATTEMPT=", File.ReadAllText(Path.Combine(RepoRoot(), "tools", "windows", "splitswan-wsl.sh")));
    }

    private static string RepoRoot()
    {
        var d = new DirectoryInfo(AppContext.BaseDirectory);
        while (d is not null && !Directory.Exists(Path.Combine(d.FullName, "tools", "windows"))) d = d.Parent;
        return d?.FullName ?? throw new InvalidOperationException("找不到 repo 根目錄");
    }
}

public class GatewayRecorderTests
{
    private static readonly string[] Gws = ["203.0.113.1", "203.0.113.2", ""];
    private static readonly DateTimeOffset Now = new(2026, 10, 4, 9, 0, 0, TimeSpan.Zero);

    private static EngineAttempts.Attempt Ok(int n, double s) => new(n, true, s, "");
    private static EngineAttempts.Attempt Fail(int n, string summary = "establishing CHILD_SA corp failed") => new(n, false, 5.0, summary);

    // ── ResolveOrder ─────────────────────────────

    [Fact]
    public void ResolveOrder_Auto_UsesHistoryOrder()
    {
        var h = new GatewayHistory();
        h.Record(new GatewayAttempt(2, true, Now.AddHours(-1), 2.0, "203.0.113.2"));
        Assert.Equal(new[] { 2, 1 }, GatewayRecorder.ResolveOrder(null, Gws, h, Now));
    }

    [Fact]
    public void ResolveOrder_Specified_OnlyThatGateway() =>
        Assert.Equal(new[] { 2 }, GatewayRecorder.ResolveOrder(2, Gws, new GatewayHistory(), Now));

    [Theory]
    [InlineData(3)]   // 空白
    [InlineData(4)]   // 超出清單
    [InlineData(0)]
    public void ResolveOrder_SpecifiedButNotConfigured_Empty(int n) =>
        Assert.Empty(GatewayRecorder.ResolveOrder(n, Gws, new GatewayHistory(), Now));

    // ── FromEngine（@@ATTEMPT → 歷史）────────────

    [Fact]
    public void FromEngine_OkRecordedWithSecondsAndAddress()
    {
        var r = GatewayRecorder.FromEngine([Ok(2, 3.4)], Gws, Now, interrupted: false);
        var a = Assert.Single(r);
        Assert.Equal(new GatewayAttempt(2, true, Now, 3.4, "203.0.113.2"), a);
    }

    [Fact]
    public void FromEngine_FailThenOk_BothRecordedInOrder()
    {
        var r = GatewayRecorder.FromEngine([Fail(1), Ok(2, 1.5)], Gws, Now, interrupted: false);
        Assert.Equal(2, r.Count);
        Assert.False(r[0].Success);
        Assert.Equal(1, r[0].Gateway);
        Assert.Equal(5.0, r[0].Seconds);
        Assert.True(r[1].Success);
    }

    [Fact]
    public void FromEngine_FailWhileInterrupted_NotRecorded()
    {
        // 使用者中途按斷線：失敗原因不在閘道（ShouldRecord 規則），成功照記
        var r = GatewayRecorder.FromEngine([Fail(1), Ok(2, 1.0)], Gws, Now, interrupted: true);
        var a = Assert.Single(r);
        Assert.True(a.Success);
    }

    [Fact]
    public void FromEngine_SummaryWithPipesOrBlank_StillRecorded()
    {
        // 合成輸出第一行固定是 "fail vpnN"，摘要內容不影響判斷
        Assert.Single(GatewayRecorder.FromEngine([Fail(1, "")], Gws, Now, false));
        Assert.Single(GatewayRecorder.FromEngine([Fail(1, "fail vpn2")], Gws, Now, false));
    }

    [Fact]
    public void FromEngine_NoAttempts_RecordsNothing() =>
        Assert.Empty(GatewayRecorder.FromEngine([], Gws, Now, false));

    [Fact]
    public void FromEngine_UnconfiguredGateway_Skipped() =>
        Assert.Empty(GatewayRecorder.FromEngine([Ok(3, 1.0), Fail(5)], Gws, Now, false));

    [Fact]
    public void FromEngine_EndToEnd_FromEngineLines()
    {
        // 引擎實際輸出 → EngineAttempts.Parse → FromEngine → Record；之後自動排序把成功的那台排第一
        var lines = new[]
        {
            "[..] 連線 vpn1…",
            "@@ATTEMPT=1|fail|12.3|establishing CHILD_SA corp failed",
            "@@ATTEMPT=2|ok|2.1|",
            "@@GATEWAY=vpn2",
            "@@RESULT=ok",
        };
        var h = new GatewayHistory();
        foreach (var a in GatewayRecorder.FromEngine(EngineAttempts.Parse(lines), Gws, Now, false)) h.Record(a);
        Assert.Equal(2, h.Attempts.Count);
        Assert.True(h.IsCooling(1, Now));
        Assert.Equal(new[] { 2, 1 }, GatewayHistory.Order(Gws, h, Now));
        Assert.Equal("連線 VPN2（203.0.113.2） · 上次 2.1 秒連上", GatewayRecorder.MenuTitle(2, Gws, h));
        Assert.Equal("連線 VPN1（203.0.113.1） · 最近 1 次失敗", GatewayRecorder.MenuTitle(1, Gws, h));
    }

    // ── LateFailure（連上不到 60 秒被踢）─────────

    [Fact]
    public void LateFailure_KickedWithin60s_RecordsFailureWithoutSeconds()
    {
        var a = GatewayRecorder.LateFailure("vpn2", Gws, Now, TimeSpan.FromSeconds(20), networkAvailable: true);
        Assert.Equal(new GatewayAttempt(2, false, Now, null, "203.0.113.2"), a);
    }

    [Fact]
    public void LateFailure_After60s_Nothing() =>
        Assert.Null(GatewayRecorder.LateFailure("vpn2", Gws, Now, TimeSpan.FromSeconds(60), true));

    [Fact]
    public void LateFailure_NoNetwork_Nothing() =>
        Assert.Null(GatewayRecorder.LateFailure("vpn2", Gws, Now, TimeSpan.FromSeconds(5), false));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("vpn3")]   // 沒有設定
    [InlineData("corp")]
    public void LateFailure_UnknownOrUnconfiguredGateway_Nothing(string? c) =>
        Assert.Null(GatewayRecorder.LateFailure(c, Gws, Now, TimeSpan.FromSeconds(5), true));

    [Fact]
    public void LateFailure_PutsGatewayIntoCooldown()
    {
        var h = new GatewayHistory();
        h.Record(new GatewayAttempt(1, true, Now.AddSeconds(-30), 2.0, "203.0.113.1"));
        Assert.Equal(new[] { 1, 2 }, GatewayHistory.Order(Gws, h, Now));
        h.Record(GatewayRecorder.LateFailure("VPN1", Gws, Now, TimeSpan.FromSeconds(30), true)!);
        Assert.Equal(new[] { 2, 1 }, GatewayHistory.Order(Gws, h, Now));
    }

    // ── 顯示文字 ─────────────────────────────────

    [Fact]
    public void MenuTitle_NoHistory_AddressOnly() =>
        Assert.Equal("連線 VPN1（203.0.113.1）", GatewayRecorder.MenuTitle(1, Gws, new GatewayHistory()));

    [Fact]
    public void DescribeOrder() =>
        Assert.Equal("VPN2 → VPN1", GatewayRecorder.DescribeOrder([2, 1]));
}

public class TrayIconRulesTests
{
    [Theory]
    [InlineData(TrayState.Disconnected, TrayIconState.Disconnected)]
    [InlineData(TrayState.Busy, TrayIconState.Connecting)]
    [InlineData(TrayState.Connected, TrayIconState.Connected)]
    [InlineData(TrayState.Error, TrayIconState.Error)]
    [InlineData(TrayState.Unknown, TrayIconState.Error)]
    public void ToIconState(TrayState s, TrayIconState expected) => Assert.Equal(expected, TrayIconRules.ToIconState(s));

    [Fact]
    public void OnlyUnknownIsDimmed()
    {
        foreach (var s in Enum.GetValues<TrayState>())
            Assert.Equal(s == TrayState.Unknown, TrayIconRules.IsDimmed(s));
    }

    [Theory]
    [InlineData(TrayIconState.Connected, true, false, TrayIconInk.Green)]
    [InlineData(TrayIconState.Connected, true, true, TrayIconInk.Green)]
    [InlineData(TrayIconState.Connected, false, true, TrayIconInk.Black)]
    [InlineData(TrayIconState.Connected, false, false, TrayIconInk.White)]
    [InlineData(TrayIconState.Disconnected, true, true, TrayIconInk.Black)]
    [InlineData(TrayIconState.Error, true, false, TrayIconInk.White)]
    [InlineData(TrayIconState.Connecting, true, true, TrayIconInk.Black)]
    public void Ink(TrayIconState st, bool green, bool light, TrayIconInk expected) =>
        Assert.Equal(expected, TrayIconRules.Ink(st, green, light));

    [Fact]
    public void IsLightTaskbar_OnlyIntOne()
    {
        Assert.True(TrayIconRules.IsLightTaskbar(1));
        Assert.False(TrayIconRules.IsLightTaskbar(0));
        Assert.False(TrayIconRules.IsLightTaskbar(null));
        Assert.False(TrayIconRules.IsLightTaskbar("1"));
        Assert.False(TrayIconRules.IsLightTaskbar(2));
    }

    [Fact]
    public void TextLabels_MatchMac()
    {
        Assert.Equal("VPN", TrayIconRules.TextLabel(TrayState.Connected));
        Assert.Equal("VPN", TrayIconRules.TextLabel(TrayState.Disconnected));
        Assert.Equal("VPN…", TrayIconRules.TextLabel(TrayState.Busy));
        Assert.Equal("VPN!", TrayIconRules.TextLabel(TrayState.Error));
        Assert.Equal("VPN?", TrayIconRules.TextLabel(TrayState.Unknown));
        Assert.Equal("VPN…", TrayIconRules.TextLabel(TrayIconState.Connecting));
        Assert.True(TrayIconRules.TextFilled(TrayIconState.Connected));
        Assert.False(TrayIconRules.TextFilled(TrayIconState.Disconnected));
    }

    [Fact]
    public void EveryGlyphStyleHasGlyphForEveryMappedState()
    {
        // 托盤依 ToIconState 取字形：所有非 Text 樣式 × 所有 TrayState 都要有字
        foreach (var style in Enum.GetValues<TrayIconStyle>().Where(s => s != TrayIconStyle.Text))
            foreach (var s in Enum.GetValues<TrayState>())
                Assert.False(string.IsNullOrEmpty(TrayIconCatalog.Glyph(style, TrayIconRules.ToIconState(s))));
    }
}

public class SettingsIconFieldsTests
{
    private static byte[] Id(byte[] b) => b;

    [Fact]
    public void OldSettingsJson_WithoutIconFields_LoadsWithDefaults()
    {
        // 第一階段（0.1.0）寫出的 settings.json：沒有 iconStyle／iconGreenWhenConnected
        const string json = """
            {
              "version": 1,
              "username": "alice",
              "passwordProtected": "",
              "pskProtected": "",
              "gateways": ["203.0.113.10", "", ""],
              "remoteSubnets": ["192.0.2.0/24"],
              "domain": "",
              "dnsServer": "",
              "autoReconnect": true
            }
            """;
        var r = SettingsDocument.Deserialize(json, Id);
        Assert.Empty(r.Warnings);
        Assert.Equal("alice", r.Settings.Username);
        Assert.True(r.Settings.AutoReconnect);
        Assert.Equal(TrayIconStyle.Shield, r.Settings.IconStyle);
        Assert.False(r.Settings.GreenWhenConnected);
    }

    [Fact]
    public void IconFields_RoundTrip()
    {
        var s = StoredSettings.Empty with { IconStyle = TrayIconStyle.Nodes, GreenWhenConnected = true };
        var json = SettingsDocument.Serialize(s, Id);
        Assert.Contains("\"iconStyle\": \"Nodes\"", json);
        var r = SettingsDocument.Deserialize(json, Id);
        Assert.Equal(TrayIconStyle.Nodes, r.Settings.IconStyle);
        Assert.True(r.Settings.GreenWhenConnected);
    }

    [Theory]
    [InlineData("\"iconStyle\": \"bogus\"")]
    [InlineData("\"iconStyle\": 3")]
    [InlineData("\"iconStyle\": null")]
    public void UnknownIconStyle_FallsBackToShield(string field)
    {
        var json = "{\"version\":1," + field + ",\"iconGreenWhenConnected\":\"yes\"}";
        var r = SettingsDocument.Deserialize(json, Id);
        Assert.Equal(TrayIconStyle.Shield, r.Settings.IconStyle);
        Assert.False(r.Settings.GreenWhenConnected);   // 型別不對當成關閉
    }

    // 設定視窗開著時從托盤換了樣式／綠色：表單沒動過的欄位不能把托盤的新值蓋回去
    private static readonly StoredSettings FormSnapshot =
        StoredSettings.Empty with { Username = "alice", IconStyle = TrayIconStyle.Shield, GreenWhenConnected = false };
    private static readonly StoredSettings TrayLatest =
        StoredSettings.Empty with { Username = "old", IconStyle = TrayIconStyle.Nodes, GreenWhenConnected = true };

    [Fact]
    public void MergeIconChoice_NotEdited_KeepsTrayValues()
    {
        var m = SettingsInput.MergeIconChoice(FormSnapshot, TrayLatest, styleEdited: false, greenEdited: false);
        Assert.Equal(TrayIconStyle.Nodes, m.IconStyle);
        Assert.True(m.GreenWhenConnected);
        Assert.Equal("alice", m.Username);   // 其他欄位一律用表單的
    }

    [Fact]
    public void MergeIconChoice_Edited_UsesFormValues()
    {
        var m = SettingsInput.MergeIconChoice(FormSnapshot, TrayLatest, styleEdited: true, greenEdited: true);
        Assert.Equal(TrayIconStyle.Shield, m.IconStyle);
        Assert.False(m.GreenWhenConnected);
    }

    [Fact]
    public void MergeIconChoice_EachFieldIndependent()
    {
        var a = SettingsInput.MergeIconChoice(FormSnapshot, TrayLatest, styleEdited: true, greenEdited: false);
        Assert.Equal(TrayIconStyle.Shield, a.IconStyle);
        Assert.True(a.GreenWhenConnected);
        var b = SettingsInput.MergeIconChoice(FormSnapshot, TrayLatest, styleEdited: false, greenEdited: true);
        Assert.Equal(TrayIconStyle.Nodes, b.IconStyle);
        Assert.False(b.GreenWhenConnected);
    }

    [Fact]
    public void ApplyImport_KeepsIconFields()
    {
        var s = StoredSettings.Empty with { IconStyle = TrayIconStyle.Lock, GreenWhenConnected = true };
        var merged = SettingsInput.ApplyImport(s, new ImportedProfile(["203.0.113.5"], ["192.0.2.0/24"], "k"));
        Assert.Equal(TrayIconStyle.Lock, merged.IconStyle);
        Assert.True(merged.GreenWhenConnected);
    }
}
