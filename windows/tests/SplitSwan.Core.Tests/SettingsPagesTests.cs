namespace SplitSwan.Core.Tests;

// 設定視窗改成「左側分類清單＋右側內容」：分頁順序、要求分頁的退回、驗證錯誤 → 欄位 → 分頁

public class SettingsPagesTests
{
    private static VpnSettings Make(string user = "alice", string[]? gws = null, string[]? ts = null,
                                    string psk = "fake-psk", string pwd = "secret") =>
        new(user, pwd, psk, gws ?? ["203.0.113.10"], ts ?? ["192.0.2.0/24"]);

    [Fact]
    public void Order_WithUpdates_HasFourPages()
    {
        Assert.Equal([SettingsPage.Connection, SettingsPage.Subnets, SettingsPage.Appearance, SettingsPage.Updates],
            SettingsPages.Order(hasUpdates: true));
    }

    [Fact]
    public void Order_WithoutUpdates_OmitsUpdates()
    {
        Assert.DoesNotContain(SettingsPage.Updates, SettingsPages.Order(hasUpdates: false));
        Assert.Equal(3, SettingsPages.Order(hasUpdates: false).Count);
    }

    [Fact]
    public void Order_NeverMoreThanFivePages()
    {
        Assert.True(SettingsPages.Order(true).Count <= 5);
        Assert.Equal(Enum.GetValues<SettingsPage>().Length, SettingsPages.Order(true).Count);
    }

    [Fact]
    public void Titles_AreDistinctAndNonEmpty()
    {
        var titles = Enum.GetValues<SettingsPage>().Select(SettingsPages.Title).ToList();
        Assert.All(titles, t => Assert.False(string.IsNullOrWhiteSpace(t)));
        Assert.Equal(titles.Count, titles.Distinct().Count());
        Assert.Equal("更新", SettingsPages.Title(SettingsPage.Updates));
    }

    [Fact]
    public void Resolve_UnavailablePage_FallsBackToConnection()
    {
        Assert.Equal(SettingsPage.Connection, SettingsPages.Resolve(SettingsPage.Updates, SettingsPages.Order(false)));
        Assert.Equal(SettingsPage.Updates, SettingsPages.Resolve(SettingsPage.Updates, SettingsPages.Order(true)));
        Assert.Equal(SettingsPage.Appearance, SettingsPages.Resolve(SettingsPage.Appearance, SettingsPages.Order(false)));
    }

    [Theory]
    [InlineData(SettingsField.Gateway, SettingsPage.Connection)]
    [InlineData(SettingsField.Username, SettingsPage.Connection)]
    [InlineData(SettingsField.Password, SettingsPage.Connection)]
    [InlineData(SettingsField.Psk, SettingsPage.Connection)]
    [InlineData(SettingsField.Subnets, SettingsPage.Subnets)]
    [InlineData(SettingsField.Domain, SettingsPage.Subnets)]
    [InlineData(SettingsField.DnsServer, SettingsPage.Subnets)]
    public void PageOf_Field(SettingsField field, SettingsPage page) => Assert.Equal(page, SettingsPages.PageOf(field));

    [Fact]
    public void PageOf_EveryFieldHasAPage()
    {
        foreach (var f in Enum.GetValues<SettingsField>()) Assert.Contains(SettingsPages.PageOf(f), SettingsPages.Order(false));
    }

    // 以下用實際的驗證輸出（不是手抄的字串），訊息改字時這裡會失敗

    private static SettingsErrorTarget Only(IReadOnlyList<string> errors, IReadOnlyList<string>? gws = null)
    {
        var e = Assert.Single(errors);
        var t = SettingsPages.Locate(e, gws);
        Assert.NotNull(t);
        return t.Value;
    }

    [Theory]
    [InlineData("bad user")]
    [InlineData("alice\n")]
    [InlineData("")]
    public void Locate_Username(string user) =>
        Assert.Equal(SettingsField.Username, Only(SettingsValidator.Validate(Make(user: user))).Field);

    [Fact]
    public void Locate_EmptyPassword() =>
        Assert.Equal(SettingsField.Password, Only(SettingsValidator.Validate(Make(pwd: ""))).Field);

    [Fact]
    public void Locate_PasswordWithNewline() =>
        Assert.Equal(SettingsField.Password, Only(SettingsValidator.Validate(Make(pwd: "a\nb"))).Field);

    [Fact]
    public void Locate_EmptyPsk() =>
        Assert.Equal(SettingsField.Psk, Only(SettingsValidator.Validate(Make(psk: ""))).Field);

    [Fact]
    public void Locate_PskWithNewline() =>
        Assert.Equal(SettingsField.Psk, Only(SettingsValidator.Validate(Make(psk: "a\r\nb"))).Field);

    [Fact]
    public void Locate_NoGateway_PointsToFirst()
    {
        var t = Only(SettingsValidator.Validate(Make(gws: ["", "", ""])));
        Assert.Equal(new SettingsErrorTarget(SettingsField.Gateway, 0), t);
        Assert.Equal(SettingsPage.Connection, t.Page);
    }

    [Fact]
    public void Locate_BadGateway_FindsWhichOne()
    {
        string[] gws = ["203.0.113.10", "", " bad{gw} "];
        var t = Only(SettingsValidator.Validate(Make(gws: gws)), gws);
        Assert.Equal(new SettingsErrorTarget(SettingsField.Gateway, 2), t);
    }

    [Fact]
    public void Locate_BadGateway_WithoutAddresses_PointsToFirst()
    {
        var t = Only(SettingsValidator.Validate(Make(gws: ["203.0.113.10", "x y"])));
        Assert.Equal(new SettingsErrorTarget(SettingsField.Gateway, 0), t);
    }

    [Fact]
    public void Locate_TooManyGateways() =>
        Assert.Equal(SettingsField.Gateway,
            Only(SettingsValidator.Validate(Make(gws: ["203.0.113.1", "203.0.113.2", "203.0.113.3", "203.0.113.4"]))).Field);

    [Theory]
    [InlineData("")]
    [InlineData("192.0.2.0/33")]
    [InlineData("0.0.0.0/0")]
    [InlineData("１92.0.2.0/24")]
    public void Locate_Subnets(string ts)
    {
        var t = Only(SettingsValidator.Validate(Make(ts: [ts])));
        Assert.Equal(SettingsField.Subnets, t.Field);
        Assert.Equal(SettingsPage.Subnets, t.Page);
    }

    [Theory]
    [InlineData("bad_domain!")]
    [InlineData("a,b,c,d,e,f,g,h,i,j,k")]
    public void Locate_Domain(string domain)
    {
        var errors = DnsOptions.Validate(domain, "");
        Assert.NotEmpty(errors);
        Assert.All(errors, e => Assert.Equal(SettingsField.Domain, SettingsPages.Locate(e)?.Field));
    }

    [Theory]
    [InlineData("192.0.2.300")]
    [InlineData("fe80::1")]
    [InlineData("192.0.2.1,192.0.2.2,192.0.2.3,192.0.2.4")]
    public void Locate_Dns(string dns)
    {
        var errors = DnsOptions.Validate("", dns);
        Assert.NotEmpty(errors);
        Assert.All(errors, e => Assert.Equal(SettingsField.DnsServer, SettingsPages.Locate(e)?.Field));
    }

    [Fact]
    public void Locate_EveryValidationErrorMapsToAField()
    {
        // 全部欄位都錯：每一則訊息都要能對應到欄位（漏一則就表示訊息改了字、對照沒跟上）
        var s = Make(user: "bad user", gws: ["", "", "", "203.0.113.4"], ts: ["0.0.0.0/0", "x"], psk: "", pwd: "");
        var errors = SettingsValidator.Validate(s).Concat(DnsOptions.Validate("bad_domain!", "999.0.0.1")).ToList();
        Assert.True(errors.Count >= 7);
        Assert.All(errors, e => Assert.NotNull(SettingsPages.Locate(e)));
    }

    [Theory]
    [InlineData("儲存失敗：存取被拒")]
    [InlineData("無法儲存設定：磁碟已滿")]
    [InlineData("匯入時發生錯誤：x")]
    public void Locate_NonValidationError_IsNull(string error) => Assert.Null(SettingsPages.Locate(error));

    [Fact]
    public void First_PicksTopMostFieldInFormOrder()
    {
        // DNS（網段頁）錯在前、PSK（連線頁）錯在後：仍先切到連線頁的 PSK
        var errors = DnsOptions.Validate("", "999.0.0.1").Concat(SettingsValidator.Validate(Make(psk: ""))).ToList();
        Assert.Equal(new SettingsErrorTarget(SettingsField.Psk), SettingsPages.First(errors));
    }

    [Fact]
    public void First_OnlySubnetPageErrors_GoesToSubnetsPage()
    {
        var errors = SettingsValidator.Validate(Make(ts: ["0.0.0.0/0"])).Concat(DnsOptions.Validate("bad_domain!", "")).ToList();
        var t = SettingsPages.First(errors);
        Assert.Equal(SettingsField.Subnets, t?.Field);
        Assert.Equal(SettingsPage.Subnets, t?.Page);
    }

    [Fact]
    public void First_NoMappableError_IsNull()
    {
        Assert.Null(SettingsPages.First([]));
        Assert.Null(SettingsPages.First(["儲存失敗：x"]));
    }

    [Fact]
    public void First_TwoBadGateways_PicksLowerIndex()
    {
        string[] gws = ["203.0.113.10", "bad gw", "x{y}"];
        var errors = SettingsValidator.Validate(Make(gws: gws));
        Assert.Equal(2, errors.Count);
        Assert.Equal(new SettingsErrorTarget(SettingsField.Gateway, 1), SettingsPages.First(errors, gws));
    }
}
