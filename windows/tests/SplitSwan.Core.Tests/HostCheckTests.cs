namespace SplitSwan.Core.Tests;

/// <summary>「某台公司主機連不上？」一鍵檢查的純邏輯（對應 Mac 版 Tests/HostCheckTests.swift）＋ Windows 的路由解析與表單修改判斷。</summary>
public class HostCheckTests
{
    private static HostTarget T(string host, int? port = null) => new(host, port);

    // ── 輸入解析 ─────────────────────────────────────

    [Fact]
    public void Parse_PlainDomain() =>
        Assert.Equal(T("intranet.example.com"), HostCheck.ParseTarget("intranet.example.com"));

    [Fact]
    public void Parse_TrimsAndLowercases() =>
        Assert.Equal(T("intranet.example.com"), HostCheck.ParseTarget("  Intranet.Example.COM \n"));

    [Fact]
    public void Parse_HostPort() =>
        Assert.Equal(T("db.example.com", 3306), HostCheck.ParseTarget("db.example.com:3306"));

    [Fact]
    public void Parse_Url_StripsSchemeUserPathQueryFragment() =>
        Assert.Equal(T("git.example.com", 8443), HostCheck.ParseTarget("https://user:pw@git.example.com:8443/a/b?x=1#y"));

    [Fact]
    public void Parse_UrlWithoutPort() =>
        Assert.Equal(T("wiki.example.com"), HostCheck.ParseTarget("http://wiki.example.com/page"));

    [Fact]
    public void Parse_Ip() => Assert.Equal(T("198.51.100.7"), HostCheck.ParseTarget("198.51.100.7"));

    [Fact]
    public void Parse_IpPort() => Assert.Equal(T("198.51.100.7", 22), HostCheck.ParseTarget("198.51.100.7:22"));

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    [InlineData("a b.example.com")]          // 中間有空白
    [InlineData("a.example.com\n}")]         // 換行注入
    [InlineData("a.exa\tmple.com")]           // 中間有定位字元
    [InlineData("a{.example.com")]           // 大括號
    [InlineData("a.com;ls")]                 // 分號
    [InlineData("a`x`.com")]                 // 反引號
    [InlineData("a.com|calc")]               // 管線
    [InlineData("a.com'")]                   // 單引號（會被放進 PowerShell 字串）
    [InlineData("a.com$(x)")]                // 指令替換
    [InlineData("１98.51.100.7")]            // 全形數字 IP
    [InlineData("198.51.100")]               // 不完整的 IP
    [InlineData("198.51.100.256")]           // 超過 255
    [InlineData("198.51.100.7.1")]           // 五段
    [InlineData("a.com:0")]                  // 連接埠 0
    [InlineData("a.com:70000")]              // 連接埠超過 65535
    [InlineData("a.com:http")]               // 非數字
    [InlineData("a.com:４43")]               // 全形數字連接埠
    [InlineData("a.com:")]                   // 冒號後空白
    [InlineData("[2001:db8::1]:443")]        // IPv6 字面值
    [InlineData("2001:db8::1")]              // IPv6 不帶括號
    [InlineData("-oProxy.example.com")]      // 開頭是連字號（不能被當成指令選項）
    [InlineData(".example.com")]             // 開頭是點
    [InlineData("example-")]                 // 結尾是連字號
    [InlineData("intranet.例子.com")]         // 非 ASCII
    public void Parse_Rejects(string? input) => Assert.Null(HostCheck.ParseTarget(input));

    [Fact]
    public void Parse_RejectsTooLongHost()
    {
        var label = new string('a', 63);
        var ok = string.Join(".", label, label, label, new string('a', 61));   // 253 字
        Assert.Equal(253, ok.Length);
        Assert.NotNull(HostCheck.ParseTarget(ok));
        Assert.Null(HostCheck.ParseTarget(ok + "a"));
    }

    [Fact]
    public void Parse_PortBounds()
    {
        Assert.Equal(T("a.com", 1), HostCheck.ParseTarget("a.com:1"));
        Assert.Equal(T("a.com", 65535), HostCheck.ParseTarget("a.com:65535"));
        Assert.Null(HostCheck.ParseTarget("a.com:65536"));
    }

    // ── 網段涵蓋 ─────────────────────────────────────

    [Fact]
    public void Contains_Slash24() => Assert.True(HostCheck.Contains("203.0.113.0/24", "203.0.113.254"));

    [Fact]
    public void Contains_Slash24_NotNeighbour() => Assert.False(HostCheck.Contains("203.0.113.0/24", "203.0.114.1"));

    [Fact]
    public void Contains_Slash32_OnlyItself()
    {
        Assert.True(HostCheck.Contains("198.51.100.7/32", "198.51.100.7"));
        Assert.False(HostCheck.Contains("198.51.100.7/32", "198.51.100.8"));
    }

    [Fact]
    public void Contains_Slash26_Boundary()
    {
        Assert.True(HostCheck.Contains("203.0.113.64/26", "203.0.113.64"));
        Assert.True(HostCheck.Contains("203.0.113.64/26", "203.0.113.127"));
        Assert.False(HostCheck.Contains("203.0.113.64/26", "203.0.113.63"));
        Assert.False(HostCheck.Contains("203.0.113.64/26", "203.0.113.128"));
    }

    [Theory]
    [InlineData("0.0.0.0/0")]
    [InlineData("abc")]
    [InlineData("198.51.100.0/33")]
    [InlineData("198.51.100.0/")]
    [InlineData("198.51.100.0")]
    [InlineData("198.51.100.0/２４")]
    [InlineData("198.51.100/24")]
    public void Contains_ZeroOrMalformed_IsFalse(string cidr) => Assert.False(HostCheck.Contains(cidr, "198.51.100.7"));

    [Fact]
    public void Contains_MalformedIp_IsFalse() => Assert.False(HostCheck.Contains("198.51.100.0/24", "198.51.100"));

    [Fact]
    public void CoveringSubnet_FindsFirst() =>
        Assert.Equal("203.0.113.64/26", HostCheck.CoveringSubnet("203.0.113.70", ["198.51.100.7/32", " 203.0.113.64/26 "]));

    [Fact]
    public void CoveringSubnet_None() => Assert.Null(HostCheck.CoveringSubnet("198.51.100.9", ["198.51.100.7/32"]));

    // ── 公網判斷 ─────────────────────────────────────

    [Theory]
    [InlineData("10.1.2.3")]
    [InlineData("172.16.0.1")]
    [InlineData("172.31.255.1")]
    [InlineData("192.168.0.1")]
    public void IsPrivate_Rfc1918(string ip) => Assert.True(HostCheck.IsPrivate(ip));

    [Theory]
    [InlineData("172.32.0.1")]
    [InlineData("172.15.255.255")]
    [InlineData("198.51.100.7")]
    [InlineData("203.0.113.7")]
    public void IsPrivate_Others(string ip) => Assert.False(HostCheck.IsPrivate(ip));

    // ── 提議 ─────────────────────────────────────────

    [Fact]
    public void Proposal_SkipsCovered() =>
        Assert.Equal(["198.51.100.7/32"], HostCheck.Proposal(["203.0.113.70", "198.51.100.7"], ["203.0.113.64/26"]));

    [Fact]
    public void Proposal_AllCovered_IsEmpty() =>
        Assert.Empty(HostCheck.Proposal(["203.0.113.70"], ["203.0.113.64/26"]));

    [Fact]
    public void Proposal_Dedupes() =>
        Assert.Equal(["198.51.100.7/32", "198.51.100.8/32"],
            HostCheck.Proposal(["198.51.100.7", "198.51.100.8", "198.51.100.7"], []));

    // ── 路由與 VPN 介面 ──────────────────────────────

    [Theory]
    [InlineData("vEthernet (WSL)")]
    [InlineData("vEthernet (WSL (Hyper-V firewall))")]
    [InlineData("VETHERNET (Default Switch)")]
    public void IsTunnelInterface_VEthernet(string alias) => Assert.True(HostCheck.IsTunnelInterface(alias));

    [Theory]
    [InlineData("Wi-Fi")]
    [InlineData("乙太網路")]
    [InlineData("Ethernet 2")]
    [InlineData("")]
    [InlineData(null)]
    public void IsTunnelInterface_Others(string? alias) => Assert.False(HostCheck.IsTunnelInterface(alias));

    [Fact]
    public void ParseRoute_AliasAndNextHop()
    {
        var r = HostCheck.ParseRoute("> powershell.exe\r\n@@ROUTE=vEthernet (WSL)|172.20.0.2\r\n");
        Assert.Equal(("vEthernet (WSL)", (string?)"172.20.0.2"), r);
    }

    [Fact]
    public void ParseRoute_IgnoresOtherLines_TakesFirstMarker()
    {
        var r = HostCheck.ParseRoute("警告：something\n@@ROUTE=Wi-Fi|192.168.1.1\n@@ROUTE=vEthernet (WSL)|172.20.0.2");
        Assert.Equal(("Wi-Fi", (string?)"192.168.1.1"), r);
    }

    [Fact]
    public void ParseRoute_OnLink_KeepsZeroNextHop() =>
        Assert.Equal(("乙太網路", (string?)"0.0.0.0"), HostCheck.ParseRoute("@@ROUTE=乙太網路|0.0.0.0"));

    [Fact]
    public void ParseRoute_NoNextHop() =>
        Assert.Equal(("Wi-Fi", (string?)null), HostCheck.ParseRoute("@@ROUTE=Wi-Fi|"));

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("@@ROUTE=")]
    [InlineData("@@ROUTE=|172.20.0.2")]
    [InlineData("Find-NetRoute : 找不到路由")]
    public void ParseRoute_Nothing_IsNull(string? output) => Assert.Null(HostCheck.ParseRoute(output));

    // ── 結果文字 ─────────────────────────────────────

    [Fact]
    public void Report_ContainsEverything()
    {
        var rep = HostCheck.Report(T("git.example.com", 443),
            [new IpResult("198.51.100.7", "vEthernet (WSL)", true, false)], ["198.51.100.7/32"], "203.0.113.200");
        Assert.Contains("git.example.com", rep);
        Assert.Contains("連接埠 443", rep);
        Assert.Contains("vEthernet (WSL)", rep);
        Assert.Contains("有走 VPN", rep);
        Assert.Contains("TCP 443 連不上", rep);
        Assert.Contains("198.51.100.7/32", rep);
        Assert.Contains("203.0.113.200", rep);
    }

    [Fact]
    public void Report_ExactFormat_SameAsMac()
    {
        var rep = HostCheck.Report(T("git.example.com", 443),
            [new IpResult("198.51.100.7", "vEthernet (WSL)", true, true), new IpResult("198.51.100.8", null, false, false)],
            ["198.51.100.7/32", "198.51.100.8/32"], "203.0.113.200");
        Assert.Equal(
            "主機：git.example.com，連接埠 443\n" +
            "我的 VPN 位址：203.0.113.200\n" +
            "本次新增網段：198.51.100.7/32, 198.51.100.8/32\n" +
            "198.51.100.7：路由 vEthernet (WSL)（有走 VPN），TCP 443 可連線\n" +
            "198.51.100.8：路由 查不到（沒走 VPN），TCP 443 連不上", rep);
    }

    [Fact]
    public void Report_NoPortNoVpnNoAdded()
    {
        var rep = HostCheck.Report(T("wiki.example.com"), [new IpResult("198.51.100.7", "Wi-Fi", false, null)], [], null);
        Assert.Equal("主機：wiki.example.com\n198.51.100.7：路由 Wi-Fi（沒走 VPN）", rep);
    }

    // ── 表單有沒有未儲存的修改 ──────────────────────

    private static readonly StoredSettings Saved = new("alice", "pw", "psk", ["203.0.113.10", "", ""],
        ["198.51.100.0/24", "203.0.113.64/26"], "corp.example", "198.51.100.53", false);

    [Fact]
    public void Dirty_Identical_IsFalse() => Assert.False(SettingsInput.HasUnsavedChanges(Saved, Saved));

    [Fact]
    public void Dirty_SubnetFormattingOnly_IsFalse()
    {
        // 表單的網段文字經 ParseSubnets：空白、空行、逗號與換行的差異都不算修改
        var form = Saved with { RemoteSubnets = SettingsInput.ParseSubnets(" 198.51.100.0/24 ,\r\n\r\n203.0.113.64/26 \n") };
        Assert.False(SettingsInput.HasUnsavedChanges(Saved, form));
        var raw = Saved with { RemoteSubnets = [" 198.51.100.0/24", "", "203.0.113.64/26 "] };
        Assert.False(SettingsInput.HasUnsavedChanges(Saved, raw));
    }

    [Fact]
    public void Dirty_GatewayPaddingAndSpaces_IsFalse()
    {
        var saved = Saved with { Gateways = ["203.0.113.10"] };
        var form = Saved with { Gateways = [" 203.0.113.10 ", "", ""] };
        Assert.False(SettingsInput.HasUnsavedChanges(saved, form));
    }

    [Fact]
    public void Dirty_DisplaySettingsAndDistro_AreIgnored()
    {
        var form = Saved with { IconStyle = TrayIconStyle.Shield + 1, GreenWhenConnected = true, ShowSubnetList = true, Distro = "Other" };
        Assert.False(SettingsInput.HasUnsavedChanges(Saved, form));
    }

    public static TheoryData<StoredSettings> DirtyForms => new()
    {
        Saved with { Username = "bob" },
        Saved with { Password = "pw2" },
        Saved with { Psk = "psk2" },
        Saved with { Gateways = ["203.0.113.10", "203.0.113.11", ""] },
        Saved with { Gateways = ["", "203.0.113.10", ""] },
        Saved with { RemoteSubnets = ["198.51.100.0/24"] },
        Saved with { RemoteSubnets = ["203.0.113.64/26", "198.51.100.0/24"] },
        Saved with { RemoteSubnets = ["198.51.100.0/24", "203.0.113.64/26", "198.51.100.7/32"] },
        Saved with { Domain = "other.example" },
        Saved with { DnsServer = "" },
        Saved with { AutoReconnect = true },
    };

    [Theory]
    [MemberData(nameof(DirtyForms))]
    public void Dirty_FormFieldChanged_IsTrue(StoredSettings form) => Assert.True(SettingsInput.HasUnsavedChanges(Saved, form));
}
