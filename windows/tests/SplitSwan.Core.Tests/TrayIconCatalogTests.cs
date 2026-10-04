using System.Text.Json.Nodes;

namespace SplitSwan.Core.Tests;

/// <summary>
/// 托盤圖示表。Fixtures/segoe-glyphs-both.json 是從 Microsoft Learn 兩張官方對照表
/// （Segoe Fluent Icons 與 Segoe MDL2 Assets）解析出的「兩套都有」的字碼與名稱（2026-10-04 取得）。
/// </summary>
public class TrayIconCatalogTests
{
    private static readonly JsonObject Official = JsonNode.Parse(Fixture.Text("segoe-glyphs-both.json"))!.AsObject();

    [Fact(DisplayName = "8 種樣式 × 4 種狀態都有定義；只有 VPN 字樣回傳 null")]
    public void TableComplete()
    {
        Assert.Equal(8, Enum.GetValues<TrayIconStyle>().Length);
        Assert.Equal(4, Enum.GetValues<TrayIconState>().Length);
        foreach (var s in Enum.GetValues<TrayIconStyle>())
            foreach (var st in Enum.GetValues<TrayIconState>())
            {
                var g = TrayIconCatalog.Glyph(s, st);
                if (s == TrayIconStyle.Text) Assert.Null(g);
                else
                {
                    Assert.NotNull(g);
                    Assert.Single(g!);   // 單一 BMP 字元
                }
            }
    }

    [Fact(DisplayName = "所有字碼都在官方表中、且兩套字型都有（Segoe Fluent Icons ∩ Segoe MDL2 Assets）")]
    public void GlyphsAreOfficialInBothFonts()
    {
        Assert.True(Official.Count > 1000, "官方字碼表 fixture 讀取失敗");   // 正對照：表本身不是空的
        foreach (var s in Enum.GetValues<TrayIconStyle>())
            foreach (var st in Enum.GetValues<TrayIconState>())
            {
                if (TrayIconCatalog.Glyph(s, st) is not { } g) continue;
                var code = ((int)g[0]).ToString("X4");
                Assert.True(Official.ContainsKey(code), $"{s}/{st} 用了 U+{code}，不在兩套字型共同的官方表中");
                Assert.InRange(g[0], '\uE000', '\uF8FF');   // 私用區（字型圖示）
            }
    }

    [Fact(DisplayName = "每個樣式的四種狀態彼此不同（不靠顏色也分得出狀態）")]
    public void StatesDistinguishable()
    {
        foreach (var s in Enum.GetValues<TrayIconStyle>())
        {
            if (s == TrayIconStyle.Text) continue;
            var glyphs = Enum.GetValues<TrayIconState>().Select(st => TrayIconCatalog.Glyph(s, st)).ToList();
            Assert.Equal(4, glyphs.Distinct().Count());
        }
    }

    [Theory(DisplayName = "繁中名稱同 Mac 版 MenuBarIconStyle.title")]
    [InlineData(TrayIconStyle.Shield, "盾牌鎖")]
    [InlineData(TrayIconStyle.ShieldCheck, "盾牌勾")]
    [InlineData(TrayIconStyle.Lock, "鎖頭")]
    [InlineData(TrayIconStyle.Key, "鑰匙")]
    [InlineData(TrayIconStyle.Network, "網路")]
    [InlineData(TrayIconStyle.Tunnel, "通道")]
    [InlineData(TrayIconStyle.Nodes, "節點")]
    [InlineData(TrayIconStyle.Text, "VPN 字樣")]
    public void Titles(TrayIconStyle s, string title) => Assert.Equal(title, TrayIconCatalog.Title(s));

    [Fact(DisplayName = "狀態名稱同 Mac 版 IconState.title")]
    public void StateTitles()
    {
        Assert.Equal("未連線", TrayIconCatalog.StateTitle(TrayIconState.Disconnected));
        Assert.Equal("已連線", TrayIconCatalog.StateTitle(TrayIconState.Connected));
        Assert.Equal("連線中", TrayIconCatalog.StateTitle(TrayIconState.Connecting));
        Assert.Equal("異常", TrayIconCatalog.StateTitle(TrayIconState.Error));
    }

    [Theory(DisplayName = "Parse：認得列舉名稱與 Mac rawValue（不分大小寫），不認得 → Shield")]
    [InlineData("Shield", TrayIconStyle.Shield)]
    [InlineData("shieldCheck", TrayIconStyle.ShieldCheck)]
    [InlineData("ShieldCheck", TrayIconStyle.ShieldCheck)]
    [InlineData("lock", TrayIconStyle.Lock)]
    [InlineData("KEY", TrayIconStyle.Key)]
    [InlineData("network", TrayIconStyle.Network)]
    [InlineData("tunnel", TrayIconStyle.Tunnel)]
    [InlineData("nodes", TrayIconStyle.Nodes)]
    [InlineData("text", TrayIconStyle.Text)]
    [InlineData(null, TrayIconStyle.Shield)]
    [InlineData("", TrayIconStyle.Shield)]
    [InlineData("bogus", TrayIconStyle.Shield)]
    [InlineData("3", TrayIconStyle.Shield)]          // 數字字串不可被當成列舉值
    [InlineData(" lock ", TrayIconStyle.Shield)]
    public void Parse(string? raw, TrayIconStyle expected) => Assert.Equal(expected, TrayIconCatalog.Parse(raw));

    [Fact(DisplayName = "Parse 與列舉名稱來回一致")]
    public void ParseRoundTrip()
    {
        foreach (var s in Enum.GetValues<TrayIconStyle>()) Assert.Equal(s, TrayIconCatalog.Parse(s.ToString()));
    }
}
