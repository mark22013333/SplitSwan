namespace SplitSwan.Core.Tests;

/// <summary>
/// 逐條移植 Mac 版 Tests/ReconnectTests.swift 第 22–147 行的 F4 測試（每個測試的顯示名稱就是 Swift check 的名稱）。
/// Swift 的 migrated（舊版 LastGoodGateway 遷移）Windows 沒有舊資料可遷移，不移植（第 127–138 行）。
/// </summary>
public class GatewayHistoryTests
{
    private static readonly string[] G = ["a", "b", "c"];
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(2_000_000);

    /// <summary>依序加入 (閘道, 成功, 耗時, 幾秒前)。</summary>
    private static GatewayHistory Hist((int N, bool Ok, double Secs, double Ago)[] items, string[]? gateways = null)
    {
        gateways ??= G;
        var h = new GatewayHistory();
        foreach (var (n, ok, secs, ago) in items)
            h.Record(new GatewayAttempt(n, ok, Now.AddSeconds(-ago), secs, gateways[n - 1]));
        return h;
    }

    private static GatewayHistory Adding(GatewayHistory h, GatewayAttempt a)
    {
        var c = GatewayHistory.FromJson(h.ToJson());
        c.Record(a);
        return c;
    }

    private static int[] Order(GatewayHistory h, string[]? gws = null) =>
        [.. GatewayHistory.Order(gws ?? G, h, Now)];

    private static readonly GatewayHistory Empty = new();

    // ── 閘道順序（ReconnectTests.swift 38–71）──────────────

    [Fact(DisplayName = "沒有紀錄：1→2→3")]
    public void NoRecords() => Assert.Equal([1, 2, 3], Order(Empty));

    [Fact(DisplayName = "上次連上 VPN3 → 先試 VPN3")]
    public void LastSuccessFirst() => Assert.Equal(3, Order(Hist([(1, true, 2, 3000), (3, true, 5, 2000)]))[0]);

    [Fact(DisplayName = "上次成功 VPN3（其他台無紀錄）：3→1→2")]
    public void LastSuccessThenConfigOrder() => Assert.Equal([3, 1, 2], Order(Hist([(3, true, 5, 2000)])));

    [Fact(DisplayName = "上次成功的閘道優先於成功率更高的閘道")]
    public void LastSuccessBeatsRate() =>
        Assert.Equal([3, 1, 2], Order(Hist([(1, true, 1, 5000), (1, true, 1, 4000), (3, false, 16, 3000), (3, true, 9, 2000)])));

    [Fact(DisplayName = "VPN3 剛失敗（冷卻中）→ 排最後")]
    public void CoolingLast() => Assert.Equal([1, 2, 3], Order(Hist([(3, true, 3, 3000), (3, false, 16, 60)])));

    [Fact(DisplayName = "冷卻中仍會嘗試，不跳過")]
    public void CoolingStillTried() =>
        Assert.Equal(3, Order(Hist([(1, false, 16, 10), (2, false, 16, 10), (3, false, 16, 10)])).Length);

    [Fact(DisplayName = "失敗超過 10 分鐘就不算冷卻")]
    public void CooldownBoundary()
    {
        Assert.False(Hist([(2, false, 16, 601)]).IsCooling(2, Now));
        Assert.True(Hist([(2, false, 16, 599)]).IsCooling(2, Now));
        // 補充：剛好 600 秒不算（Swift 用「< cooldown」）
        Assert.False(Hist([(2, false, 16, 600)]).IsCooling(2, Now));
        Assert.Equal(TimeSpan.FromSeconds(600), GatewayHistory.Cooldown);
    }

    [Fact(DisplayName = "某台連續失敗（已過冷卻）→ 排在其他有紀錄的後面")]
    public void RepeatedFailuresPastCooldown() =>
        Assert.Equal([2, 3, 1], Order(Hist([(1, false, 16, 5000), (1, false, 16, 4000), (1, false, 16, 3000),
            (2, true, 4, 2500), (3, true, 6, 2400), (2, true, 4, 2300)])));

    [Fact(DisplayName = "某台連續失敗（冷卻中）→ 排最後")]
    public void RepeatedFailuresCooling() =>
        Assert.Equal([2, 3, 1], Order(Hist([(2, true, 4, 5000), (1, false, 16, 300), (1, false, 16, 200), (1, false, 16, 100)])));

    [Fact(DisplayName = "成功率高的在前（VPN3 是上次成功，排第一）")]
    public void HigherRateFirst() =>
        Assert.Equal([3, 2, 1], Order(Hist([(1, true, 3, 5000), (1, false, 16, 4900), (2, true, 3, 4800), (2, true, 3, 4700),
            (3, false, 16, 4600), (3, false, 16, 4500), (3, true, 3, 4400)])));

    [Fact(DisplayName = "成功率同分比平均耗時（只算成功的）")]
    public void TieBrokenByAverage() =>
        Assert.Equal([3, 2, 1], Order(Hist([(1, true, 8, 5000), (1, false, 1, 4900), (2, true, 3, 4800), (2, false, 16, 4700),
            (3, false, 16, 4600), (3, false, 16, 4500), (3, false, 16, 4400), (3, true, 9, 4300)])));

    [Fact(DisplayName = "無紀錄的排在有成功紀錄的後面")]
    public void UnknownAfterSucceeded() =>
        Assert.Equal([2, 3, 1], Order(Hist([(3, true, 4, 5000), (3, false, 16, 4000), (2, true, 4, 3000)])));

    [Fact(DisplayName = "成功率 0（全部失敗）排在無紀錄的後面")]
    public void AllFailedAfterUnknown()
    {
        Assert.Equal([2, 3, 1], Order(Hist([(1, false, 16, 5000)])));
        Assert.Equal([2, 1, 3], Order(Hist([(2, true, 4, 5000), (3, false, 16, 4000)])));
    }

    [Fact(DisplayName = "多台成功率 0：彼此照設定順序、都在無紀錄之後")]
    public void ManyAllFailed() => Assert.Equal([2, 1, 3], Order(Hist([(3, false, 16, 5000), (1, false, 16, 4000)])));

    [Fact(DisplayName = "無紀錄的閘道彼此照設定順序")]
    public void UnknownInConfigOrder()
    {
        Assert.Equal([3, 1, 2], Order(Hist([(3, true, 4, 5000)])));
        Assert.Equal([2, 1, 3], Order(Hist([(2, true, 4, 5000)])));
    }

    [Fact(DisplayName = "多台冷卻中：彼此照成功率排")]
    public void CoolingByRate() =>
        Assert.Equal([2, 3, 1], Order(Hist([(1, true, 3, 5000), (1, false, 16, 100), (3, true, 3, 4000), (3, true, 3, 3900),
            (3, false, 16, 90), (2, true, 5, 3000)])));

    [Fact(DisplayName = "多台冷卻中：同分照平均耗時、再照設定順序")]
    public void CoolingTieBreak()
    {
        Assert.Equal([3, 1, 2], Order(Hist([(3, true, 2, 5000), (3, false, 16, 50), (1, true, 7, 4000), (1, false, 16, 40), (2, false, 16, 30)])));
        Assert.Equal([3, 1, 2], Order(Hist([(2, false, 16, 50), (1, false, 16, 40)])));
    }

    [Fact(DisplayName = "上次成功但冷卻中：不排第一")]
    public void LastSuccessButCooling() =>
        Assert.Equal([2, 3, 1], Order(Hist([(2, true, 3, 5000), (1, true, 3, 3000), (1, false, 16, 20)])));

    [Fact(DisplayName = "略過未設定的閘道")]
    public void SkipUnconfigured() => Assert.Equal([1, 3], Order(Empty, ["a", " ", "c"]));

    [Fact(DisplayName = "上次成功的閘道被清空：照設定順序")]
    public void LastSuccessCleared() => Assert.Equal([1, 3], Order(Hist([(2, true, 3, 100)]), ["a", "", "c"]));

    [Fact(DisplayName = "全部未設定：空")]
    public void AllUnconfigured() => Assert.Empty(Order(Empty, ["", "", ""]));

    // ── 清除紀錄（73–83）─────────────────────────────────

    [Fact(DisplayName = "清除前：3 優先、1 冷卻；清除紀錄 → 恢復設定順序")]
    public void ClearedHistory()
    {
        var cleared = Hist([(3, true, 3, 3000), (1, false, 16, 60)]);
        Assert.Equal([3, 2, 1], Order(cleared));
        cleared = new GatewayHistory();
        Assert.Equal([1, 2, 3], Order(cleared));
        Assert.Null(cleared.LastSuccess);
    }

    [Fact(DisplayName = "removeAll → 排序回到設定順序")]
    public void RemoveAll()
    {
        var all = Hist([(3, true, 3, 3000), (1, false, 16, 60), (2, true, 2, 50)]);
        all.RemoveAll();
        Assert.Empty(all.Attempts);
        Assert.Equal([1, 2, 3], Order(all));
    }

    [Fact(DisplayName = "清除單台：上次成功也跟著消失")]
    public void ClearOne()
    {
        var one = Hist([(3, true, 3, 3000), (1, false, 16, 3000)]);
        one.Clear(3);
        Assert.Null(one.LastSuccess);
        Assert.Empty(one.Records(3));
        Assert.Single(one.Records(1));
    }

    // ── 每台只保留最近 10 筆（85–91）──────────────────────

    private static GatewayHistory Many()
    {
        var many = new GatewayHistory();
        for (var k = 0; k < 15; k++) many.Record(new GatewayAttempt(1, k >= 5, Now.AddSeconds(k), k, "a"));
        many.Record(new GatewayAttempt(2, false, Now, 1, "b"));
        return many;
    }

    [Fact(DisplayName = "每台只留 10 筆")]
    public void KeepTen()
    {
        var many = Many();
        Assert.Equal(GatewayHistory.KeepPerGateway, many.Records(1).Count);
        Assert.Single(many.Records(2));
        Assert.Equal(10, GatewayHistory.KeepPerGateway);
    }

    [Fact(DisplayName = "丟掉的是最舊的")]
    public void DropOldest()
    {
        var r = Many().Records(1);
        Assert.Equal(5, r[0].Seconds);
        Assert.Equal(14, r[^1].Seconds);
    }

    [Fact(DisplayName = "成功率只算最近 10 次")]
    public void RateOnlyLastTen() => Assert.Equal(1.0, Many().SuccessRate(1));

    [Fact(DisplayName = "補充：保留上限只丟同一台、其他台的相對順序不變")]
    public void KeepTenPreservesOthers()
    {
        var h = new GatewayHistory();
        h.Record(new GatewayAttempt(2, true, Now, 1, "b"));
        for (var k = 0; k < 11; k++) h.Record(new GatewayAttempt(1, true, Now, k, "a"));
        h.Record(new GatewayAttempt(3, true, Now, 9, "c"));
        Assert.Equal([2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3], h.Attempts.Select(a => a.Gateway));
        Assert.Equal(1, h.Records(1)[0].Seconds);
    }

    // ── 位址變更（93–99）─────────────────────────────────

    [Fact(DisplayName = "位址改了：該台紀錄清除，其他台保留")]
    public void PrunedMoved()
    {
        var moved = Hist([(1, true, 3, 100), (2, true, 4, 90)]).Pruned(["a", "b2", "c"]);
        Assert.Empty(moved.Records(2));
        Assert.Single(moved.Records(1));
    }

    [Fact(DisplayName = "閘道被清空：該台紀錄清除")]
    public void PrunedEmptied() => Assert.Empty(Hist([(3, true, 3, 100)]).Pruned(["a", "b", ""]).Attempts);

    [Fact(DisplayName = "位址只差大小寫與空白：保留")]
    public void PrunedCaseAndSpace() =>
        Assert.Single(Hist([(1, true, 3, 100)], ["VPN.Example.com", "b", "c"]).Pruned([" vpn.example.COM ", "b", "c"]).Records(1));

    [Fact(DisplayName = "位址沒變：原樣保留")]
    public void PrunedSame() => Assert.Single(Hist([(1, true, 3, 100)]).Pruned([" a ", "b", "c"]).Records(1));

    [Fact(DisplayName = "補充：Pruned 不改原物件；編號超出設定清單的紀錄丟掉")]
    public void PrunedIsPure()
    {
        var h = Hist([(1, true, 3, 100), (3, true, 3, 90)]);
        var p = h.Pruned(["a", "b"]);
        Assert.Equal(2, h.Attempts.Count);
        Assert.Equal([1], p.Attempts.Select(a => a.Gateway));
    }

    // ── 存檔格式（101–107；Windows 自己的格式）─────────────

    [Fact(DisplayName = "JSON 來回不變")]
    public void JsonRoundTrip()
    {
        var saved = Hist([(1, true, 3.2, 100), (2, false, 16, 50)]);
        saved.Record(new GatewayAttempt(3, false, Now, null, null));
        var back = GatewayHistory.FromJson(saved.ToJson());
        Assert.Equal(saved.Attempts, back.Attempts);
    }

    [Theory(DisplayName = "壞掉的資料 → 空紀錄")]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("x")]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("{\"attempts\":null}")]
    [InlineData("{\"attempts\":[null]}")]
    [InlineData("{\"attempts\":\"x\"}")]
    [InlineData("{\"attempts\":[{\"gateway\":\"1\",\"success\":true,\"time\":\"2026-10-04T00:00:00+00:00\"}]}")]
    [InlineData("{\"attempts\":[{\"gateway\":1,\"success\":true,\"time\":\"不是時間\"}]}")]
    [InlineData("{\"attempts\":[{\"gateway\":1,\"success\":true,\"seconds\":-1,\"time\":\"2026-10-04T00:00:00+00:00\"}]}")]
    [InlineData("{\"attempts\":[{\"gateway\":1,\"success\":true,\"seconds\":1e999,\"time\":\"2026-10-04T00:00:00+00:00\"}]}")]
    [InlineData("{\"attempts\":[{\"gateway\":99999999999,\"success\":true,\"time\":\"2026-10-04T00:00:00+00:00\"}]}")]
    [InlineData("{\"attempts\":[{\"gateway\":1,\"success\":true,\"time\":\"2026-10-04T00:00:00+00:00\"}")]
    public void BrokenJson(string? json)
    {
        var h = GatewayHistory.FromJson(json);
        Assert.Empty(h.Attempts);
    }

    [Fact(DisplayName = "壞掉的資料：極深巢狀也不丟例外")]
    public void DeeplyNestedJson()
    {
        var json = "{\"attempts\":" + new string('[', 5000) + new string(']', 5000) + "}";
        Assert.Empty(GatewayHistory.FromJson(json).Attempts);
    }

    [Fact(DisplayName = "JSON 欄位可讀")]
    public void JsonFieldsReadable()
    {
        var json = Hist([(1, true, 3.2, 100), (2, false, 16, 50)]).ToJson();
        foreach (var k in new[] { "\"attempts\"", "\"gateway\"", "\"success\"", "\"seconds\"", "\"time\"", "\"address\"" })
            Assert.Contains(k, json);
    }

    [Fact(DisplayName = "補充：讀檔時每台超過 10 筆會被截到 10 筆")]
    public void FromJsonEnforcesKeep()
    {
        var items = string.Join(",", Enumerable.Range(0, 25).Select(i =>
            $"{{\"gateway\":1,\"address\":\"a\",\"success\":true,\"seconds\":{i},\"time\":\"2026-10-04T00:00:00+00:00\"}}"));
        var h = GatewayHistory.FromJson($"{{\"attempts\":[{items}]}}");
        Assert.Equal(10, h.Records(1).Count);
        Assert.Equal(15, h.Records(1)[0].Seconds);
    }

    // ── 要不要記錄（109–120）───────────────────────────────

    [Fact(DisplayName = "成功一律記")]
    public void RecordSuccess() => Assert.True(GatewayHistory.ShouldRecord(2, true, "ok vpn2", true));

    [Fact(DisplayName = "helper 印 fail vpnN：記")]
    public void RecordFailVpnN() => Assert.True(GatewayHistory.ShouldRecord(2, false, "initiate failed\nfail vpn2", false));

    [Fact(DisplayName = "sudo 失敗（沒有 fail vpnN）：不記")]
    public void NoRecordSudo() => Assert.False(GatewayHistory.ShouldRecord(1, false, "sudo: a password is required", false));

    [Fact(DisplayName = "輔助程式不存在：不記")]
    public void NoRecordHelperMissing() =>
        Assert.False(GatewayHistory.ShouldRecord(1, false, "sudo: /usr/local/libexec/splitswan-helper: command not found", false));

    [Fact(DisplayName = "台號不符：不記")]
    public void NoRecordWrongNumber() => Assert.False(GatewayHistory.ShouldRecord(1, false, "fail vpn2", false));

    [Fact(DisplayName = "fail all 不算單台：不記")]
    public void NoRecordFailAll() => Assert.False(GatewayHistory.ShouldRecord(1, false, "fail all", false));

    [Fact(DisplayName = "被斷線搶先或網路中斷：不記")]
    public void NoRecordInterrupted() => Assert.False(GatewayHistory.ShouldRecord(3, false, "fail vpn3", true));

    [Fact(DisplayName = "連線名稱 → 台號")]
    public void ConnectionToNumber()
    {
        Assert.Equal(2, GatewayHistory.GatewayFromConnection("vpn2"));
        Assert.Equal(3, GatewayHistory.GatewayFromConnection("VPN3"));
    }

    [Theory(DisplayName = "連線名稱認不出來 → nil")]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("vpn")]
    [InlineData("vpn4")]
    [InlineData("corp")]
    [InlineData("vpnx")]
    public void ConnectionUnknown(string? c) => Assert.Null(GatewayHistory.GatewayFromConnection(c));

    // ── 補記失敗（122–125）─────────────────────────────────

    [Fact(DisplayName = "補記失敗後進冷卻、排最後；不影響平均耗時")]
    public void KickedFailure()
    {
        var kicked = Adding(Hist([(3, true, 3, 100)]), new GatewayAttempt(3, false, Now, null, "c"));
        Assert.True(kicked.IsCooling(3, Now));
        Assert.Equal([1, 2, 3], Order(kicked));
        Assert.Equal(3, kicked.AverageSuccessSeconds(3));
    }

    [Fact(DisplayName = "耗時不明的成功：不算進平均；之後的成功只算有耗時的")]
    public void UnknownSecondsSuccess()
    {
        var h = new GatewayHistory();
        h.Record(new GatewayAttempt(3, true, Now, null, "c"));
        Assert.Null(h.AverageSuccessSeconds(3));
        Assert.Equal("VPN3 · 上次連上", h.StatusText(3));
        h.Record(new GatewayAttempt(3, true, Now, 4, "c"));
        Assert.Equal(4, h.AverageSuccessSeconds(3));
    }

    // ── 狀態文字（141–147）────────────────────────────────

    private static GatewayHistory St() =>
        Hist([(2, true, 3.24, 100), (1, true, 3, 900), (1, false, 16, 800), (1, false, 16, 700), (1, false, 16, 600)]);

    [Fact(DisplayName = "狀態文字：上次 3.2 秒連上")]
    public void StatusSeconds() => Assert.Equal("VPN2 · 上次 3.2 秒連上", St().StatusText(2));

    [Fact(DisplayName = "狀態文字：最近 3 次失敗（連續失敗次數）")]
    public void StatusFailures()
    {
        Assert.Equal("VPN1 · 最近 3 次失敗", St().StatusText(1));
        Assert.Equal(3, St().ConsecutiveFailures(1));
    }

    [Fact(DisplayName = "狀態文字：無紀錄只顯示 VPNn")]
    public void StatusNone()
    {
        Assert.Equal("VPN3", St().StatusText(3));
        Assert.Null(St().Detail(3));
    }

    [Fact(DisplayName = "狀態文字：失敗後又成功，顯示成功")]
    public void StatusRecovered() => Assert.Equal("上次 4.0 秒連上", Hist([(1, false, 16, 200), (1, true, 4, 100)]).Detail(1));

    [Fact(DisplayName = "狀態文字：失敗 1 次")]
    public void StatusOneFailure() => Assert.Equal("VPN1 · 最近 1 次失敗", Hist([(1, true, 4, 200), (1, false, 16, 100)]).StatusText(1));

    [Fact(DisplayName = "補充：沒有紀錄時成功率與平均為 null、連續失敗 0")]
    public void QueriesOnEmpty()
    {
        Assert.Null(Empty.SuccessRate(1));
        Assert.Null(Empty.AverageSuccessSeconds(1));
        Assert.Equal(0, Empty.ConsecutiveFailures(1));
        Assert.False(Empty.IsCooling(1, Now));
    }
}
