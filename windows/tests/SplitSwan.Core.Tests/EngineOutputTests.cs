namespace SplitSwan.Core.Tests;

public class EngineOutputTests
{
    [Fact]
    public void Parse_ConnectOutput()
    {
        var kv = EngineOutput.Parse(
        [
            "正在啟動 WSL…",
            "@@GATEWAY=vpn2",
            "@@VIP=198.51.100.7",
            "@@RESULT=ok",
        ]);
        Assert.Equal("vpn2", kv["GATEWAY"]);
        Assert.Equal("198.51.100.7", kv["VIP"]);
        Assert.Equal((true, (string?)null), EngineOutput.Result(kv));
        Assert.Equal(3, kv.Count);   // 進度行不會被收進來
    }

    [Fact]
    public void Parse_SameKeyTakesLast()
    {
        var kv = EngineOutput.Parse(["@@STATE=down", "@@STATE=up"]);
        Assert.Equal("up", kv["STATE"]);
    }

    [Fact]
    public void Parse_IgnoresNonMarkerLines()
    {
        var kv = EngineOutput.Parse(["", "STATE=up", " @@STATE=up", "@STATE=up", "@@", "@@NOEQUALS", "@@=x", "記錄 @@RESULT=ok"]);
        Assert.Empty(kv);
    }

    [Fact]
    public void Parse_ValueMayContainEquals() =>
        Assert.Equal("fail:a=b", EngineOutput.Parse(["@@RESULT=fail:a=b"])["RESULT"]);

    [Fact]
    public void Parse_StripsCarriageReturn()
    {
        var kv = EngineOutput.Parse(["@@STATE=up\r", "@@RESULT=ok\r"]);
        Assert.Equal("up", kv["STATE"]);
        Assert.True(EngineOutput.Result(kv).Ok);
    }

    [Fact]
    public void Parse_EmptyValueKept() => Assert.Equal("", EngineOutput.Parse(["@@VIP="])["VIP"]);

    [Fact]
    public void Parse_NullLineIgnored() => Assert.Empty(EngineOutput.Parse([null!]));

    [Fact]
    public void Result_Fail_ReturnsMessage() =>
        Assert.Equal((false, "三台閘道都連不上"), EngineOutput.Result(EngineOutput.Parse(["@@RESULT=fail:三台閘道都連不上"])));

    [Fact]
    public void Result_Missing() =>
        Assert.Equal((false, "引擎沒有回傳結果"), EngineOutput.Result(EngineOutput.Parse(["@@STATE=up"])));

    [Fact]
    public void Result_FailWithoutReason_HasFallbackMessage()
    {
        var (ok, err) = EngineOutput.Result(EngineOutput.Parse(["@@RESULT=fail:"]));
        Assert.False(ok);
        Assert.False(string.IsNullOrWhiteSpace(err));
    }

    [Theory]
    [InlineData("OK")]
    [InlineData("okay")]
    [InlineData("failed")]
    public void Result_UnknownValue_IsFailure(string v)
    {
        var (ok, err) = EngineOutput.Result(EngineOutput.Parse([$"@@RESULT={v}"]));
        Assert.False(ok);
        Assert.Contains(v, err);
    }

    [Fact]
    public void Parse_BriefDown()
    {
        var kv = EngineOutput.Parse(["@@STATE=down", "@@RESULT=ok"]);
        Assert.Equal("down", kv["STATE"]);
        Assert.False(kv.ContainsKey("GATEWAY"));
    }
}
