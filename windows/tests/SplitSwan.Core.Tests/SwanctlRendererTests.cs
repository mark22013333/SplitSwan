namespace SplitSwan.Core.Tests;

public class SwanctlRendererTests
{
    public static TheoryData<string> RenderCases() => ["three", "one", "gap", "padded"];

    private static VpnSettings FromCase(string name)
    {
        var c = Fixture.Json("render-cases.json").First(x => x!["name"]!.GetValue<string>() == name)!;
        return new VpnSettings(
            c["user"]!.GetValue<string>(), c["pwd"]!.GetValue<string>(), c["psk"]!.GetValue<string>(),
            c["gateways"]!.AsArray().Select(g => g!.GetValue<string>()).ToList(),
            [c["ts"]!.GetValue<string>()]);
    }

    // 與 Mac 版 ConfigStore.renderConf(normalized(s)) 逐字一致（fixture 由 Swift 實際產生）
    [Theory]
    [MemberData(nameof(RenderCases))]
    public void RenderConf_MatchesSwiftOutputByteForByte(string name) =>
        Assert.Equal(Fixture.Text($"render-{name}.conf"), SwanctlRenderer.RenderConf(FromCase(name)));

    // 與 Mac 版 renderSecrets(username:, psk: quote(psk), password: quote(pwd)) 逐字一致（含跳脫）
    [Theory]
    [MemberData(nameof(RenderCases))]
    public void RenderSecrets_MatchesSwiftOutputByteForByte(string name) =>
        Assert.Equal(Fixture.Text($"render-{name}.secrets"), SwanctlRenderer.RenderSecrets(FromCase(name)));

    [Fact]
    public void RenderFixtures_AreLfOnly()
    {
        // 防呆：git 在 Windows 若把 fixture 轉成 CRLF，逐字比對會失真（Fixtures/.gitattributes 已設 -text）
        foreach (var n in new[] { "three", "one", "gap", "padded" })
        {
            Assert.DoesNotContain('\r', Fixture.Text($"render-{n}.conf"));
            Assert.DoesNotContain('\r', Fixture.Text($"render-{n}.secrets"));
        }
    }

    // 以下對應 Mac 版 ReconnectTests.swift:158-161 的設定檔檢查
    [Fact]
    public void RenderConf_UsesDpdDelay10s()
    {
        var conf = SwanctlRenderer.RenderConf(FromCase("three"));
        Assert.Contains("dpd_delay = 10s", conf);
        Assert.DoesNotContain("dpd_delay = 20s", conf);
    }

    [Fact]
    public void RenderConf_UsesDpdActionClear()
    {
        var conf = SwanctlRenderer.RenderConf(FromCase("three"));
        Assert.Contains("dpd_action = clear", conf);
        Assert.DoesNotContain("dpd_action = restart", conf);
    }

    [Theory]
    [MemberData(nameof(RenderCases))]
    public void RenderConf_BracesBalanced(string name)
    {
        var conf = SwanctlRenderer.RenderConf(FromCase(name));
        Assert.Equal(conf.Count(c => c == '{'), conf.Count(c => c == '}'));
    }

    [Fact]
    public void RenderConf_NamesConnectionsByPosition_ChildCorp()
    {
        var conf = SwanctlRenderer.RenderConf(FromCase("gap"));   // 第 1 台空白
        Assert.DoesNotContain("vpn1 {", conf);
        Assert.Contains("    vpn2 {", conf);
        Assert.Contains("    vpn3 {", conf);
        Assert.Equal(2, conf.Split("corp {").Length - 1);
    }

    [Fact]
    public void RenderSecrets_EscapesQuotesAndBackslashes()
    {
        var s = new VpnSettings("bob", "pa\"ss\\word", "k\\\"ey", ["203.0.113.10"], ["192.0.2.0/24"]);
        var text = SwanctlRenderer.RenderSecrets(s);
        Assert.Contains("secret = \"k\\\\\\\"ey\"", text);
        Assert.Contains("secret = \"pa\\\"ss\\\\word\"", text);
    }

    // 未驗證的值不可寫進設定檔：大括號、換行會破壞 swanctl.conf 結構
    [Theory]
    [InlineData("bob}\n    vpn9 {")]
    [InlineData("bob\n")]
    public void RenderConf_RejectsInjectionInUsername(string user) =>
        Assert.Throws<ArgumentException>(() =>
            SwanctlRenderer.RenderConf(new VpnSettings(user, "p", "k", ["203.0.113.10"], ["192.0.2.0/24"])));

    [Fact]
    public void RenderConf_RejectsInjectionInSubnets() =>
        Assert.Throws<ArgumentException>(() =>
            SwanctlRenderer.RenderConf(new VpnSettings("bob", "p", "k", ["203.0.113.10"], ["192.0.2.0/24 }"])));

    [Fact]
    public void RenderSecrets_RejectsNewlineInPassword() =>
        Assert.Throws<ArgumentException>(() =>
            SwanctlRenderer.RenderSecrets(new VpnSettings("bob", "p\n}", "k", ["203.0.113.10"], ["192.0.2.0/24"])));

    // 對應 ExportTests「quote → unquote 還原」：跳脫後用 strongSwan 的規則還原應得原文
    [Theory]
    [InlineData("a\"b\\c")]
    [InlineData("\\\\\"\"")]
    [InlineData("密鑰 !@#$%")]
    public void Quote_RoundTrips(string raw)
    {
        var text = SwanctlRenderer.RenderSecrets(new VpnSettings("bob", "pw", raw, ["203.0.113.10"], ["192.0.2.0/24"]));
        var line = text.Split('\n').First(l => l.Contains("secret = ") && !l.Contains("\"pw\""));
        var quoted = line[(line.IndexOf('"') + 1)..line.LastIndexOf('"')];
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < quoted.Length; i++)
        {
            if (quoted[i] == '\\') i++;
            sb.Append(quoted[i]);
        }
        Assert.Equal(raw, sb.ToString());
    }
}
