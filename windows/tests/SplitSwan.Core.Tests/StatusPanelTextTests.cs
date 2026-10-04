using System.Globalization;
using System.Text.Json.Nodes;

namespace SplitSwan.Core.Tests;

/// <summary>狀態面板精簡版（第四階段）：網段摘要、流量、更新時間、BYTES 取值、ShowSubnetList 設定。</summary>
public class StatusPanelTextTests
{
    // ── 網段摘要

    [Fact]
    public void SubnetSummary_Mixed_CountsHostsAndNets()
    {
        var subnets = new List<string> { "192.0.2.0/24" };
        for (int i = 1; i <= 14; i++) subnets.Add($"198.51.100.{i}/32");
        Assert.Equal("15 個網段走 VPN（1 段內網、14 台主機）", StatusPanelText.SubnetSummary(subnets));
    }

    [Fact]
    public void SubnetSummary_Empty_AndBlankOnly()
    {
        Assert.Equal("尚未設定內網網段", StatusPanelText.SubnetSummary([]));
        Assert.Equal("尚未設定內網網段", StatusPanelText.SubnetSummary(["", "  ", "\t"]));
    }

    [Fact]
    public void SubnetSummary_HostsOnly()
    {
        Assert.Equal("2 個網段走 VPN（2 台主機）",
            StatusPanelText.SubnetSummary(["203.0.113.5/32", "203.0.113.6/32"]));
    }

    [Fact]
    public void SubnetSummary_NetsOnly()
    {
        Assert.Equal("3 個網段走 VPN（3 段內網）",
            StatusPanelText.SubnetSummary(["192.0.2.0/24", "198.51.100.0/25", "203.0.113.0/31"]));
    }

    [Fact]
    public void SubnetSummary_DedupesAndTrims_NoPrefixCountsAsHost()
    {
        // 重複與前後空白先去掉（同 chips）；沒有前綴長度的單一位址算主機
        Assert.Equal("2 個網段走 VPN（1 段內網、1 台主機）",
            StatusPanelText.SubnetSummary([" 192.0.2.0/24 ", "192.0.2.0/24", "203.0.113.9"]));
    }

    // ── 位元組格式化

    [Theory]
    [InlineData(0L, "0 B")]
    [InlineData(-5L, "0 B")]
    [InlineData(386L, "386 B")]
    [InlineData(1023L, "1023 B")]
    [InlineData(1024L, "1.0 KB")]
    [InlineData(1280L, "1.3 KB")]
    [InlineData(1258291L, "1.2 MB")]
    [InlineData(8808038L, "8.4 MB")]
    [InlineData(1048575L, "1.0 MB")]           // 1023.999 KB 四捨五入會變 1024.0 KB，改用 MB
    [InlineData(1073741824L, "1.0 GB")]
    [InlineData(5497558138880L, "5120.0 GB")]  // 最大單位是 GB
    public void FormatBytes(long bytes, string expected) =>
        Assert.Equal(expected, StatusPanelText.FormatBytes(bytes));

    [Fact]
    public void FormatBytes_IgnoresCurrentCulture()
    {
        var old = CultureInfo.CurrentCulture;
        try
        {
            // 德文用逗號當小數點：結果仍要是「.」
            CultureInfo.CurrentCulture = new CultureInfo("de-DE");
            Assert.Equal("1.2 MB", StatusPanelText.FormatBytes(1258291));
            Assert.Equal("↑ 送出 1.3 KB　↓ 收到 386 B", StatusPanelText.TrafficLine(386, 1280));
        }
        finally
        {
            CultureInfo.CurrentCulture = old;
        }
    }

    [Fact]
    public void TrafficLine_Formats_AndMissing()
    {
        Assert.Equal("↑ 送出 1.2 MB　↓ 收到 8.4 MB", StatusPanelText.TrafficLine(8808038, 1258291));
        Assert.Null(StatusPanelText.TrafficLine(null, null));
        Assert.Equal("↑ 送出 —　↓ 收到 386 B", StatusPanelText.TrafficLine(386, null));
        Assert.Equal("↑ 送出 0 B　↓ 收到 —", StatusPanelText.TrafficLine(null, 0));
    }

    // ── 狀態更新時間

    private static readonly DateTimeOffset T0 = new(2026, 10, 4, 12, 0, 0, TimeSpan.FromHours(8));

    [Theory]
    [InlineData(0, false, "狀態更新：剛剛")]
    [InlineData(0.5, false, "狀態更新：剛剛")]
    [InlineData(5, false, "狀態更新：5 秒前")]
    [InlineData(59.9, false, "狀態更新：59 秒前")]
    [InlineData(60, false, "狀態更新：1 分鐘前")]
    [InlineData(150, false, "狀態更新：2 分鐘前")]
    [InlineData(3600, false, "狀態更新：1 小時前")]
    [InlineData(30, true, "已 30 秒查不到狀態")]
    [InlineData(60, true, "已 1 分鐘查不到狀態")]
    [InlineData(185, true, "已 3 分鐘查不到狀態")]
    [InlineData(7300, true, "已 2 小時查不到狀態")]
    [InlineData(0.2, true, "查不到狀態")]
    public void Freshness(double ageSeconds, bool unknown, string expected) =>
        Assert.Equal(expected, StatusPanelText.Freshness(T0, T0.AddSeconds(ageSeconds), unknown));

    [Fact]
    public void Freshness_NoSureResultYet()
    {
        Assert.Equal("正在確認狀態…", StatusPanelText.Freshness(null, T0, unknownNow: false));
        Assert.Equal("查不到狀態", StatusPanelText.Freshness(null, T0, unknownNow: true));
    }

    [Fact]
    public void Freshness_ClockWentBackwards_TreatedAsZero()
    {
        Assert.Equal("狀態更新：剛剛", StatusPanelText.Freshness(T0, T0.AddSeconds(-30), unknownNow: false));
    }

    // ── EngineOutput 取 BYTESIN／BYTESOUT

    [Fact]
    public void TrafficBytes_FromBriefOutput()
    {
        var kv = EngineOutput.Parse([
            "@@STATE=up", "@@GATEWAY=vpn1", "@@VIP=198.51.100.7",
            "@@BYTESIN=386\r", "@@BYTESOUT=1280", "@@RESULT=ok",
        ]);
        Assert.Equal((386L, 1280L), TrafficBytes.From(kv));
    }

    [Fact]
    public void TrafficBytes_OldEngine_MissingIsNull()
    {
        var kv = EngineOutput.Parse(["@@STATE=up", "@@GATEWAY=vpn1", "@@RESULT=ok"]);
        Assert.Equal(((long?)null, (long?)null), TrafficBytes.From(kv));
    }

    [Theory]
    [InlineData("")]
    [InlineData("-5")]
    [InlineData(" 12")]
    [InlineData("1,024")]
    [InlineData("１２３")]                    // 全形數字
    [InlineData("99999999999999999999")]      // 超過 long
    [InlineData("12abc")]
    public void TrafficBytes_InvalidValue_IsNull(string value)
    {
        var kv = EngineOutput.Parse([$"@@BYTESIN={value}", "@@BYTESOUT=42"]);
        var (i, o) = TrafficBytes.From(kv);
        Assert.Null(i);
        Assert.Equal(42L, o);
    }

    [Fact]
    public void TrafficBytes_Zero_IsZeroNotNull()
    {
        var kv = EngineOutput.Parse(["@@BYTESIN=0", "@@BYTESOUT=0"]);
        Assert.Equal((0L, 0L), TrafficBytes.From(kv));
    }

    // ── ShowSubnetList 設定

    private static byte[] Same(byte[] b) => b;

    private static readonly StoredSettings Sample = new(
        "alice", "pw", "psk", ["203.0.113.10", "", ""], ["192.0.2.0/24"], "", "", false);

    [Fact]
    public void ShowSubnetList_DefaultFalse()
    {
        Assert.False(StoredSettings.Empty.ShowSubnetList);
        Assert.False(Sample.ShowSubnetList);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void ShowSubnetList_RoundTrip(bool on)
    {
        var json = SettingsDocument.Serialize(Sample with { ShowSubnetList = on }, Same);
        Assert.Contains("\"showSubnetList\"", json);
        var r = SettingsDocument.Deserialize(json, Same);
        Assert.Empty(r.Warnings);
        Assert.Equal(on, r.Settings.ShowSubnetList);
    }

    [Fact]
    public void ShowSubnetList_OldFileWithoutField_IsFalse_OtherFieldsKept()
    {
        var o = JsonNode.Parse(SettingsDocument.Serialize(Sample with { ShowSubnetList = true }, Same))!.AsObject();
        Assert.True(o.Remove("showSubnetList"));
        var r = SettingsDocument.Deserialize(o.ToJsonString(), Same);
        Assert.Empty(r.Warnings);
        Assert.False(r.Settings.ShowSubnetList);
        Assert.Equal("alice", r.Settings.Username);
        Assert.Equal(Sample.RemoteSubnets, r.Settings.RemoteSubnets);
    }

    [Theory]
    [InlineData("\"yes\"")]
    [InlineData("1")]
    [InlineData("null")]
    public void ShowSubnetList_NotBoolean_IsFalse(string raw)
    {
        var o = JsonNode.Parse(SettingsDocument.Serialize(Sample, Same))!.AsObject();
        o["showSubnetList"] = JsonNode.Parse(raw);
        var r = SettingsDocument.Deserialize(o.ToJsonString(), Same);
        Assert.False(r.Settings.ShowSubnetList);
    }

    [Fact]
    public void MergeForSave_ShowSubnetListFromSaved_OtherFieldsFromForm()
    {
        // 完整網段清單切換時已寫入；按儲存時一律取已儲存的值，表單上的（可能是開窗時的舊值）不蓋回去
        var form = Sample with { ShowSubnetList = false, Username = "form" };
        var saved = Sample with { ShowSubnetList = true, Username = "saved" };
        var m = DisplaySettings.MergeForSave(form, saved);
        Assert.True(m.ShowSubnetList);
        Assert.Equal("form", m.Username);
    }

    // ── 三欄數值的文字

    [Fact]
    public void HandshakeCaptionAndTip()
    {
        Assert.Equal("握手耗時", StatusPanelText.HandshakeCaption);
        Assert.Equal("從送出連線請求到 VPN 握手完成的時間", StatusPanelText.HandshakeTip);
    }

    [Fact]
    public void ConnectedSince_ApproximateGetsLowerBoundMark()
    {
        Assert.Equal("≥ 12:34", StatusPanelText.ConnectedSince("12:34", approximate: true));
        Assert.Equal("12:34", StatusPanelText.ConnectedSince("12:34", approximate: false));
        Assert.Equal("SplitSwan 開啟前就已連線，實際時間更長", StatusPanelText.ApproximateSinceTip);
    }
}
