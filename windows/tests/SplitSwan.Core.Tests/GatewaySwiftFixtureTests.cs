using System.Text.Json.Nodes;

namespace SplitSwan.Core.Tests;

/// <summary>
/// 與 Mac 版逐筆比對：Fixtures/gateway-cases.json 由 Sources/GatewayHistory.swift 實際跑出
/// （產生方式見 Fixtures/README.md），C# 版用同樣的輸入必須得到完全相同的結果。
/// </summary>
public class GatewaySwiftFixtureTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(2_000_000);
    private static readonly JsonObject Root = JsonNode.Parse(Fixture.Text("gateway-cases.json"))!.AsObject();

    private static double? D(JsonNode? n) => n?.GetValue<double>();

    private static (int, string, bool, double?, double)[] Attempts(JsonNode? arr) =>
        [.. arr!.AsArray().Select(a => (a!["gateway"]!.GetValue<int>(), a["address"]!.GetValue<string>(),
            a["success"]!.GetValue<bool>(), D(a["seconds"]), a["ago"]!.GetValue<double>()))];

    private static (int, string, bool, double?, double)[] Snapshot(GatewayHistory h) =>
        [.. h.Attempts.Select(a => (a.Gateway, a.Address!, a.Success, a.Seconds, (Now - a.At).TotalSeconds))];

    public static TheoryData<int> CaseIndexes()
    {
        var d = new TheoryData<int>();
        for (var i = 0; i < Root["cases"]!.AsArray().Count; i++) d.Add(i);
        return d;
    }

    [Fact(DisplayName = "fixture 數量符合預期（防止讀到空檔而假通過）")]
    public void FixtureNotEmpty()
    {
        Assert.Equal(200, Root["cases"]!.AsArray().Count);
        Assert.Equal(276, Root["shouldRecord"]!.AsArray().Count);
        Assert.Equal(22, Root["gatewayFromConnection"]!.AsArray().Count);
        // 案例要真的涵蓋各種情況，不是全部長一樣
        var cases = Root["cases"]!.AsArray();
        Assert.Contains(cases, c => c!["after"]!.AsArray().Count < c["attempts"]!.AsArray().Count);   // 有觸發 10 筆上限
        Assert.Contains(cases, c => c!["pruned"]!.AsArray().Count > 0);                                // Pruned 有保留下來的
        Assert.Contains(cases, c => c!["perGateway"]!.AsArray().Any(g => g!["cooling"]!.GetValue<bool>()));
    }

    [Theory(DisplayName = "與 Swift 逐筆一致：record／查詢／order／pruned／狀態文字")]
    [MemberData(nameof(CaseIndexes))]
    public void MatchesSwift(int index)
    {
        var c = Root["cases"]![index]!;
        var gws = c["gateways"]!.AsArray().Select(x => x!.GetValue<string>()).ToArray();
        var h = new GatewayHistory();
        foreach (var (n, addr, ok, secs, ago) in Attempts(c["attempts"]))
            h.Record(new GatewayAttempt(n, ok, Now.AddSeconds(-ago), secs, addr));

        Assert.Equal(Attempts(c["after"]), Snapshot(h));
        Assert.Equal(c["order"]!.AsArray().Select(x => x!.GetValue<int>()), GatewayHistory.Order(gws, h, Now));
        Assert.Equal(c["lastSuccess"]?.GetValue<int>(), h.LastSuccess);
        foreach (var g in c["perGateway"]!.AsArray())
        {
            var n = g!["n"]!.GetValue<int>();
            Assert.Equal(g["cooling"]!.GetValue<bool>(), h.IsCooling(n, Now));
            Assert.Equal(D(g["successRate"]), h.SuccessRate(n));
            Assert.Equal(D(g["avg"]), h.AverageSuccessSeconds(n));
            Assert.Equal(g["consecutiveFailures"]!.GetValue<int>(), h.ConsecutiveFailures(n));
            Assert.Equal(g["records"]!.GetValue<int>(), h.Records(n).Count);
            Assert.Equal(g["detail"]?.GetValue<string>(), h.Detail(n));
            Assert.Equal(g["statusText"]!.GetValue<string>(), h.StatusText(n));
        }
        var pw = c["pruneWith"]!.AsArray().Select(x => x!.GetValue<string>()).ToArray();
        Assert.Equal(Attempts(c["pruned"]), Snapshot(h.Pruned(pw)));
        // 存檔再讀回，結果不變
        Assert.Equal(Snapshot(h), Snapshot(GatewayHistory.FromJson(h.ToJson())));
    }

    [Fact(DisplayName = "與 Swift 逐筆一致：shouldRecord（276 組）")]
    public void ShouldRecordMatchesSwift()
    {
        foreach (var r in Root["shouldRecord"]!.AsArray())
        {
            var n = r!["n"]!.GetValue<int>();
            var output = r["output"]!.GetValue<string>();
            var success = r["success"]!.GetValue<bool>();
            var interrupted = r["interrupted"]!.GetValue<bool>();
            Assert.True(r["expected"]!.GetValue<bool>() == GatewayHistory.ShouldRecord(n, success, output, interrupted),
                $"n={n} success={success} interrupted={interrupted} output={System.Text.Json.JsonSerializer.Serialize(output)}");
        }
    }

    [Fact(DisplayName = "與 Swift 逐筆一致：gateway(fromConnection:)（22 組）")]
    public void GatewayFromConnectionMatchesSwift()
    {
        foreach (var r in Root["gatewayFromConnection"]!.AsArray())
        {
            var input = r!["input"]?.GetValue<string>();
            Assert.True(r["expected"]?.GetValue<int>() == GatewayHistory.GatewayFromConnection(input), $"input={input}");
        }
    }
}
