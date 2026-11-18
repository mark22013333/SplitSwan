using SplitSwan.Core;
using Xunit;

namespace SplitSwan.Core.Tests;

public class DiagnosticReportTests
{
    private static readonly StoredSettings Settings = new(
        Username: "alice.wang",
        Password: "S3cret-pass!",
        Psk: "group-psk-value",
        Gateways: ["203.0.113.10", "vpn2.corp.example", ""],
        RemoteSubnets: ["198.51.100.0/24", "192.0.2.15/32"],
        Domain: "corp.example",
        DnsServer: "198.51.100.53",
        AutoReconnect: false);

    private static DiagnosticMasker Masker(string? vip = "100.64.7.8") => new(Settings, vip);

    [Fact]
    public void SecretsAndAccount_AreNeverInTheReport()
    {
        var text = DiagnosticReport.Build(
            ["帳號 alice.wang"],
            [new("引擎", "x", ["secret = \"S3cret-pass!\"", "psk group-psk-value", "eap_id = alice.wang"])],
            Masker());
        Assert.DoesNotContain("S3cret-pass!", text);
        Assert.DoesNotContain("group-psk-value", text);
        Assert.DoesNotContain("alice.wang", text);
        Assert.Contains("<帳號>", text);
    }

    [Fact]
    public void Gateways_ByAddressOrName_GetTheirNumber()
    {
        var m = Masker();
        Assert.Equal("connect <閘道1> then <閘道2>", m.Mask("connect 203.0.113.10 then VPN2.corp.example"));
    }

    [Fact]
    public void InternalDomain_DnsAndVirtualIp_AreLabelled()
    {
        var m = Masker();
        Assert.Equal("intranet.<內部網域1> via <內部DNS1>", m.Mask("intranet.corp.example via 198.51.100.53"));
        Assert.Equal("vip <虛擬IP>", m.Mask("vip 100.64.7.8"));
    }

    [Fact]
    public void AddressesInsideConfiguredSubnets_GetStableLabels()
    {
        var m = Masker();
        var a = m.Mask("route 198.51.100.0 mask 255.255.255.0 → 198.51.100.7, host 192.0.2.15");
        Assert.Equal("route <內網#1> mask 255.255.255.0 → <內網#2>, host <內網#3>", a);
        Assert.Equal("again <內網#2>", m.Mask("again 198.51.100.7"));
    }

    [Fact]
    public void HomeNetworkWslAndVersions_StayReadable()
    {
        var m = Masker();
        const string line = "WSL 版本： 2.6.1.0；vEthernet 172.24.80.1；home 192.168.1.20；gw 0.0.0.0；lo 127.0.0.1";
        Assert.Equal(line, m.Mask(line));
    }

    [Fact]
    public void NoVirtualIp_IsFine()
    {
        Assert.Equal("100.64.7.8", Masker(vip: null).Mask("100.64.7.8"));
    }

    [Fact]
    public void ShortOrEmptySettings_DoNotMaskOrdinaryText()
    {
        var m = new DiagnosticMasker(StoredSettings.Empty with { Username = "ab" });
        Assert.Equal("abc 10.0.0.1", m.Mask("abc 10.0.0.1"));
    }

    [Fact]
    public void Sections_ShowCommandAndFailureReason()
    {
        var text = DiagnosticReport.Build([], [new("路由", "route.exe print -4", [], "逾時（20 秒），已中止"), new("空", "x", [])], Masker());
        Assert.Contains("===== 路由 =====", text);
        Assert.Contains("> route.exe print -4", text);
        Assert.Contains("（逾時（20 秒），已中止）", text);
        Assert.Contains("（沒有輸出）", text);
    }

    [Fact]
    public void FileNameAndTail()
    {
        Assert.Equal("SplitSwan-診斷-20261118-142530.txt", DiagnosticReport.FileName(new DateTime(2026, 11, 18, 14, 25, 30)));
        Assert.Equal(["c", "d"], DiagnosticReport.Tail(["a", "b", "c", "d"], 2));
        Assert.Equal(["a"], DiagnosticReport.Tail(["a"], 5));
    }
}
