using System.Text.Json.Nodes;

namespace SplitSwan.Core.Tests;

public class SettingsValidatorTests
{
    private static VpnSettings Make(string user = "alice", string[]? gws = null, string[]? ts = null,
                                    string psk = "fake-psk", string pwd = "secret") =>
        new(user, pwd, psk, gws ?? ["203.0.113.10"], ts ?? ["192.0.2.0/24"]);

    public static TheoryData<string> MacCases()
    {
        var d = new TheoryData<string>();
        foreach (var c in Fixture.Json("validate-cases.json")) d.Add(c!["name"]!.GetValue<string>());
        return d;
    }

    // 對照 Mac 版：validate-cases.json 由 Swift 跑 ConfigStore.validate(normalized(s)) 實際產生，
    // 記錄 Mac 版丟出的第一個錯誤（null＝合法）。C# 的第一個錯誤必須逐字相同。
    // （唯一替換：Mac 訊息裡的私有網段範例改成 RFC 5737 的「192.0.2.0/24」，公開 repo 規定）
    [Theory]
    [MemberData(nameof(MacCases))]
    public void FirstError_MatchesMacValidate(string name)
    {
        var c = Fixture.Json("validate-cases.json").First(x => x!["name"]!.GetValue<string>() == name)!;
        var s = Make(user: c["user"]!.GetValue<string>(),
                     gws: c["gateways"]!.AsArray().Select(g => g!.GetValue<string>()).ToArray(),
                     ts: [c["ts"]!.GetValue<string>()]);
        var errors = SettingsValidator.Validate(s);
        var expected = c["macError"]?.GetValue<string>();
        if (expected is null) Assert.Empty(errors);
        else Assert.Equal(expected, Assert.Single(errors.Take(1)));
    }

    [Fact]
    public void MacCaseFixture_HasExpectedCount()
    {
        // 防呆：fixture 讀不到時 Theory 會變成 0 筆而「全綠」
        Assert.Equal(40, Fixture.Json("validate-cases.json").Count);
    }

    [Fact]
    public void ValidSettings_NoErrors() => Assert.Empty(SettingsValidator.Validate(Make()));

    [Fact]
    public void ThreeGateways_Allowed() =>
        Assert.Empty(SettingsValidator.Validate(Make(gws: ["203.0.113.10", "203.0.113.20", "203.0.113.30"])));

    // 對應 SecurityTests「閘道超過 3 筆 → 整份拒絕」
    [Fact]
    public void FourGateways_Rejected() =>
        Assert.Contains("閘道最多 3 台",
            SettingsValidator.Validate(Make(gws: ["203.0.113.10", "203.0.113.20", "203.0.113.30", "203.0.113.40"])));

    [Fact]
    public void FourthSlotEmpty_Allowed() =>
        Assert.Empty(SettingsValidator.Validate(Make(gws: ["203.0.113.10", "", "", ""])));

    // 對應 SecurityTests「閘道含換行 → 拒絕」：單筆閘道夾帶換行重新定義變數
    [Fact]
    public void GatewayWithNewlineInjection_Rejected() =>
        Assert.NotEmpty(SettingsValidator.Validate(Make(gws: ["203.0.113.10\nSPLITSWAN_GATEWAYS=\"203.0.113.10\""])));

    [Fact]
    public void AllErrorsReported_NotOnlyFirst()
    {
        var errors = SettingsValidator.Validate(new VpnSettings("a b", "", "", ["bad gw"], ["203.0.113.0/0"]));
        Assert.Equal(
        [
            "帳號只能包含英數字與 . _ @ -",
            "閘道格式不正確：bad gw",
            "不可使用 203.0.113.0/0（全部流量走 VPN），請只填公司網段",
            "請填入預設共享金鑰",
            "請填入密碼",
        ], errors);
    }

    [Theory]
    [InlineData("a\nb")]
    [InlineData("a\rb")]
    [InlineData("ab\n")]
    public void PskWithNewline_Rejected(string psk) =>
        Assert.Equal(["預設共享金鑰不可包含換行"], SettingsValidator.Validate(Make(psk: psk)));

    [Theory]
    [InlineData("a\nb")]
    [InlineData("a\r\nb")]
    public void PasswordWithNewline_Rejected(string pwd) =>
        Assert.Equal(["密碼不可包含換行"], SettingsValidator.Validate(Make(pwd: pwd)));

    [Fact]
    public void EmptySecrets_Rejected()
    {
        Assert.Equal(["請填入預設共享金鑰"], SettingsValidator.Validate(Make(psk: "")));
        Assert.Equal(["請填入密碼"], SettingsValidator.Validate(Make(pwd: "")));
    }

    // 引號、反斜線、大括號在密碼裡是合法的（寫檔時跳脫），不應被驗證擋下
    [Fact]
    public void SecretsWithQuotesAndBraces_Allowed() =>
        Assert.Empty(SettingsValidator.Validate(Make(psk: "p\"s\\k {}", pwd: "\"}{\\")));

    [Fact]
    public void SubnetsAsSeparateItems_EquivalentToCommaString()
    {
        Assert.Empty(SettingsValidator.Validate(Make(ts: ["192.0.2.0/24", " 198.51.100.0/24 "])));
        Assert.Empty(SettingsValidator.Validate(Make(ts: ["192.0.2.0/24", ""])));   // 空項目略過（同 Mac 版 ",,"）
        // 夾在中間、只有空白的項目被拒（同 Mac 版 "a, ,b"）；在結尾的會先被整串去空白吃掉而放行（同 Mac 版 "a,  "）
        Assert.NotEmpty(SettingsValidator.Validate(Make(ts: ["192.0.2.0/24", "  ", "198.51.100.0/24"])));
        Assert.Empty(SettingsValidator.Validate(Make(ts: ["192.0.2.0/24", "  "])));
        Assert.Equal(["通道網段不可空白"], SettingsValidator.Validate(Make(ts: [])));
    }

    // 對應 SecurityTests「網段 0.0.0.0/0 → 拒絕」（同時確認典型寫法本身也被擋）
    [Fact]
    public void DefaultRoute_Rejected() =>
        Assert.Contains("不可使用 0.0.0.0/0（全部流量走 VPN），請只填公司網段",
            SettingsValidator.Validate(Make(ts: ["0.0.0.0/0"])));
}
