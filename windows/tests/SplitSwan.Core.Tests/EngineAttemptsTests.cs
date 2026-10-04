namespace SplitSwan.Core.Tests;

public class EngineAttemptsTests
{
    [Fact(DisplayName = "逐行讀出每一台的嘗試，順序與出現順序相同")]
    public void ParsesAllInOrder()
    {
        var list = EngineAttempts.Parse(
        [
            "正在嘗試 VPN2…",
            "@@ATTEMPT=2|fail|16.0|establishing CHILD_SA corp failed",
            "@@ATTEMPT=1|ok|3.2|",
            "@@GATEWAY=vpn1",
            "@@VIP=198.51.100.7",
            "@@RESULT=ok",
        ]);
        Assert.Equal(
        [
            new EngineAttempts.Attempt(2, false, 16.0, "establishing CHILD_SA corp failed"),
            new EngineAttempts.Attempt(1, true, 3.2, ""),
        ], list);
    }

    [Fact(DisplayName = "同一台出現兩次都保留（不是取最後一次）")]
    public void KeepsDuplicates()
    {
        var list = EngineAttempts.Parse(["@@ATTEMPT=1|fail|1.0|x", "@@ATTEMPT=1|ok|2.0|"]);
        Assert.Equal(2, list.Count);
    }

    [Fact(DisplayName = "行尾的 CR 與空白去掉")]
    public void TrimsTrailingCr()
    {
        var a = Assert.Single(EngineAttempts.Parse(["@@ATTEMPT=3|fail|0.5|timeout\r"]));
        Assert.Equal("timeout", a.Summary);
    }

    [Fact(DisplayName = "摘要裡萬一還有 |，原樣保留在摘要")]
    public void SummaryKeepsExtraPipes()
    {
        var a = Assert.Single(EngineAttempts.Parse(["@@ATTEMPT=1|fail|1.5|a|b"]));
        Assert.Equal("a|b", a.Summary);
    }

    [Fact(DisplayName = "秒數用 InvariantCulture：小數點是「.」，不受系統地區設定影響")]
    public void SecondsInvariant()
    {
        var old = Thread.CurrentThread.CurrentCulture;
        try
        {
            Thread.CurrentThread.CurrentCulture = new System.Globalization.CultureInfo("de-DE");   // 小數點是「,」
            Assert.Equal(12.5, Assert.Single(EngineAttempts.Parse(["@@ATTEMPT=1|ok|12.5|"])).Seconds);
            Assert.Empty(EngineAttempts.Parse(["@@ATTEMPT=1|ok|12,5|"]));
        }
        finally { Thread.CurrentThread.CurrentCulture = old; }
    }

    [Theory(DisplayName = "格式錯的行忽略")]
    [InlineData("@@ATTEMPT=")]
    [InlineData("@@ATTEMPT=1|ok|3.2")]              // 少一欄
    [InlineData("@@ATTEMPT=x|ok|3.2|")]             // 編號不是數字
    [InlineData("@@ATTEMPT=0|ok|3.2|")]             // 編號從 1 起算
    [InlineData("@@ATTEMPT=-1|ok|3.2|")]
    [InlineData("@@ATTEMPT=+1|ok|3.2|")]
    [InlineData("@@ATTEMPT= 1|ok|3.2|")]
    [InlineData("@@ATTEMPT=１|ok|3.2|")]            // 全形數字
    [InlineData("@@ATTEMPT=99999999999|ok|3.2|")]   // 溢位
    [InlineData("@@ATTEMPT=1|OK|3.2|")]             // 結果大小寫不符
    [InlineData("@@ATTEMPT=1|success|3.2|")]
    [InlineData("@@ATTEMPT=1|ok||")]                // 秒數空白
    [InlineData("@@ATTEMPT=1|ok|abc|")]
    [InlineData("@@ATTEMPT=1|ok|-1.0|")]            // 負數
    [InlineData("@@ATTEMPT=1|ok|NaN|")]
    [InlineData("@@ATTEMPT=1|ok|Infinity|")]
    [InlineData("@@ATTEMPT=1|ok|1e3|")]             // 只接受一般小數
    [InlineData(" @@ATTEMPT=1|ok|3.2|")]            // 行首有空白：不是標記行（同 EngineOutput）
    [InlineData("@@attempt=1|ok|3.2|")]
    [InlineData("ATTEMPT=1|ok|3.2|")]
    public void IgnoresMalformed(string line) => Assert.Empty(EngineAttempts.Parse([line]));

    [Fact(DisplayName = "null 行略過；沒有任何 @@ATTEMPT 回傳空清單")]
    public void NullAndEmpty()
    {
        Assert.Empty(EngineAttempts.Parse([null!, "@@RESULT=fail:連線失敗"]));
        Assert.Empty(EngineAttempts.Parse([]));
        Assert.Throws<ArgumentNullException>(() => EngineAttempts.Parse(null!));
    }

    [Fact(DisplayName = "秒數沒有小數也可以")]
    public void IntegerSeconds() => Assert.Equal(7, Assert.Single(EngineAttempts.Parse(["@@ATTEMPT=2|ok|7|"])).Seconds);
}
