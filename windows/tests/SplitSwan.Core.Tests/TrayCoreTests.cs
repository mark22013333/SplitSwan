using System.Text;

namespace SplitSwan.Core.Tests;

// 托盤 App 用的純邏輯（ReconnectBackoff、DnsOptions、SettingsDocument、TrayText、EngineCommand、LogHygiene、SettingsInput）

public class ReconnectBackoffTests
{
    [Theory]
    [InlineData(-1, 30)]
    [InlineData(0, 30)]
    [InlineData(1, 60)]
    [InlineData(2, 120)]
    [InlineData(3, 240)]
    [InlineData(4, 300)]
    [InlineData(100, 300)]
    public void Delay_Steps(int step, int seconds) =>
        Assert.Equal(TimeSpan.FromSeconds(seconds), ReconnectBackoff.Delay(step));

    [Fact]
    public void Delay_NeverExceedsMax()
    {
        for (int i = 0; i < 50; i++) Assert.True(ReconnectBackoff.Delay(i) <= ReconnectBackoff.Max);
    }
}

public class DnsOptionsTests
{
    [Fact]
    public void Empty_IsValid_AndRendersNothing()
    {
        Assert.Empty(DnsOptions.Validate("", "  "));
        Assert.Null(DnsOptions.RenderOptionsIni("", null));
    }

    [Fact]
    public void Render_DomainsAndDns()
    {
        var ini = DnsOptions.RenderOptionsIni(" corp.example, .ad.corp.example ", "192.0.2.53;198.51.100.53");
        Assert.NotNull(ini);
        Assert.Contains("Domain=corp.example,ad.corp.example\r\n", ini);
        Assert.Contains("DnsServer=192.0.2.53,198.51.100.53\r\n", ini);
    }

    [Fact]
    public void Render_OnlyDomain_HasNoDnsLine()
    {
        var ini = DnsOptions.RenderOptionsIni("corp.example", "")!;
        Assert.DoesNotContain("DnsServer=", ini);
    }

    [Theory]
    [InlineData("corp.example\nDnsServer=203.0.113.1")]   // 換行注入（切開後第二項含 =）
    [InlineData("corp=example")]
    [InlineData("-corp.example")]
    [InlineData("corp..example")]
    [InlineData("corp.example\"")]
    [InlineData("ｃｏｒｐ.example")]                        // 全形字母
    public void BadDomain_Rejected(string d)
    {
        Assert.NotEmpty(DnsOptions.ValidateDomains(d));
        Assert.Throws<ArgumentException>(() => DnsOptions.RenderOptionsIni(d, ""));
    }

    [Theory]
    [InlineData("256.0.0.1")]
    [InlineData("192.0.2")]
    [InlineData("１９２.0.2.53")]   // 全形數字
    [InlineData("2001:db8::1")]
    [InlineData("dns.corp.example")]
    public void BadDns_Rejected(string ip) => Assert.NotEmpty(DnsOptions.ValidateDnsServers(ip));

    [Fact]
    public void TooManyEntries_Rejected()
    {
        Assert.NotEmpty(DnsOptions.ValidateDnsServers("192.0.2.1,192.0.2.2,192.0.2.3,192.0.2.4"));
        Assert.NotEmpty(DnsOptions.ValidateDomains(string.Join(",", Enumerable.Range(1, 11).Select(i => $"d{i}.example"))));
    }

    [Fact]
    public void Render_NoNewlineInsideValues()
    {
        var ini = DnsOptions.RenderOptionsIni("a.example b.example", "192.0.2.53")!;
        var lines = ini.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(3, lines.Length);   // 註解、Domain、DnsServer
    }
}

public class SettingsDocumentTests
{
    // 假的 DPAPI：每個 byte XOR 0x5A 再加一個標頭，確認 JSON 裡看不到原文
    private static byte[] FakeProtect(byte[] b) => [0xEE, .. b.Select(x => (byte)(x ^ 0x5A))];
    private static byte[] FakeUnprotect(byte[] b)
    {
        if (b.Length == 0 || b[0] != 0xEE) throw new System.Security.Cryptography.CryptographicException("bad");
        return [.. b.Skip(1).Select(x => (byte)(x ^ 0x5A))];
    }

    private static readonly StoredSettings Sample = new(
        "alice", "hun\"ter\\2-密碼", "psk-秘密-123",
        ["203.0.113.10", "vpn.corp.example", ""], ["192.0.2.0/24", "198.51.100.7/32"],
        "corp.example", "192.0.2.53", true);

    [Fact]
    public void RoundTrip()
    {
        var json = SettingsDocument.Serialize(Sample, FakeProtect);
        var r = SettingsDocument.Deserialize(json, FakeUnprotect);
        Assert.Empty(r.Warnings);
        Assert.Equal(Sample.Username, r.Settings.Username);
        Assert.Equal(Sample.Password, r.Settings.Password);
        Assert.Equal(Sample.Psk, r.Settings.Psk);
        Assert.Equal(Sample.Gateways, r.Settings.Gateways);
        Assert.Equal(Sample.RemoteSubnets, r.Settings.RemoteSubnets);
        Assert.Equal(Sample.Domain, r.Settings.Domain);
        Assert.Equal(Sample.DnsServer, r.Settings.DnsServer);
        Assert.True(r.Settings.AutoReconnect);
    }

    [Fact]
    public void Json_DoesNotContainPlainSecrets()
    {
        var json = SettingsDocument.Serialize(Sample, FakeProtect);
        Assert.DoesNotContain("hun", json);
        Assert.DoesNotContain("密碼", json);
        Assert.DoesNotContain("psk-", json);
        Assert.DoesNotContain("秘密", json);
        Assert.DoesNotContain("\"password\"", json);
        Assert.Contains("passwordProtected", json);
    }

    [Fact]
    public void UnprotectFails_SecretBlank_OtherFieldsKept_WarningHasNoSecret()
    {
        var json = SettingsDocument.Serialize(Sample, FakeProtect);
        var r = SettingsDocument.Deserialize(json, _ => throw new System.Security.Cryptography.CryptographicException("key gone"));
        Assert.Equal("", r.Settings.Password);
        Assert.Equal("", r.Settings.Psk);
        Assert.Equal("alice", r.Settings.Username);
        Assert.Equal(Sample.Gateways, r.Settings.Gateways);
        Assert.Equal(2, r.Warnings.Count);
        Assert.All(r.Warnings, w => Assert.DoesNotContain("key gone", w));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[1,2]")]
    [InlineData("{\"version\":99}")]
    public void Broken_ReturnsEmptyWithWarning(string json)
    {
        var r = SettingsDocument.Deserialize(json, FakeUnprotect);
        Assert.Equal(StoredSettings.Empty, r.Settings);
        Assert.Single(r.Warnings);
    }

    [Fact]
    public void EmptySecrets_NotPassedToProtect()
    {
        var called = 0;
        var json = SettingsDocument.Serialize(StoredSettings.Empty, b => { called++; return b; });
        Assert.Equal(0, called);
        var r = SettingsDocument.Deserialize(json, FakeUnprotect);
        Assert.Equal(3, r.Settings.Gateways.Count);
        Assert.False(r.Settings.AutoReconnect);
    }
}

public class TrayTextTests
{
    [Fact]
    public void DropBody_AutoReconnectOn_UsesMacText()
    {
        var t = TimeSpan.FromSeconds(30);
        Assert.Equal(DropDetector.DropBody(t), TrayText.DropBody(t, true));
        Assert.Contains("自動重連", TrayText.DropBody(t, true));
    }

    [Fact]
    public void DropBody_AutoReconnectOff_DoesNotClaimReconnecting()
    {
        var body = TrayText.DropBody(TimeSpan.FromSeconds(30), false);
        Assert.DoesNotContain("自動重連", body);
        Assert.Contains("30 秒", body);
    }

    [Fact]
    public void StatusLine_Connected_ShowsGatewayAndVip()
    {
        var s = TrayText.StatusLine(TrayState.Connected, "vpn2", "198.51.100.7", null, null);
        Assert.Equal("已連線（VPN2，虛擬 IP 198.51.100.7）", s);
        Assert.Equal("已連線", TrayText.StatusLine(TrayState.Connected, null, null, null, null));
    }

    [Fact]
    public void StatusLine_Unknown_SaysNotDisconnected()
    {
        var s = TrayText.StatusLine(TrayState.Unknown, "vpn1", "198.51.100.7", null, null);
        Assert.Contains("狀態不明", s);
        Assert.Contains("不代表已斷線", s);
    }

    [Fact]
    public void StatusLine_ErrorIsOneLine()
    {
        var s = TrayText.StatusLine(TrayState.Error, null, null, null, "第一行\r\n第二行");
        Assert.DoesNotContain("\n", s);
    }

    [Fact]
    public void Tooltip_TruncatedTo127()
    {
        var t = TrayText.Tooltip("SplitSwan", TrayState.Error, null, null, null, new string('錯', 300));
        Assert.True(t.Length <= TrayText.TooltipMax);
        Assert.StartsWith("SplitSwan：", t);
    }
}

public class EngineCommandTests
{
    [Fact]
    public void Arguments_Connect()
    {
        var a = EngineCommand.Arguments(EngineAction.Connect, @"C:\App\engine\splitswan-wsl.ps1", @"C:\Users\a b\AppData\Local\SplitSwan\conf\");
        Assert.Equal(new[]
        {
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", @"C:\App\engine\splitswan-wsl.ps1",
            "-Action", "connect", "-ConfDir", @"C:\Users\a b\AppData\Local\SplitSwan\conf",
        }, a);
    }

    [Fact]
    public void Arguments_PauseAtEnd()
    {
        var a = EngineCommand.Arguments(EngineAction.Brief, "x.ps1", @"C:\c", pauseAtEnd: true);
        Assert.Equal("-PauseAtEnd", a[^1]);
        Assert.Contains("brief", a);
    }

    [Theory]
    [InlineData(new[] { "a", "b c" }, "a \"b c\"")]
    [InlineData(new[] { "" }, "\"\"")]
    [InlineData(new[] { @"C:\a b\" }, "\"C:\\a b\\\\\"")]
    [InlineData(new[] { "say \"hi\"" }, "\"say \\\"hi\\\"\"")]
    [InlineData(new[] { @"a\\b" }, @"a\\b")]
    [InlineData(new[] { "a\\\"b" }, "\"a\\\\\\\"b\"")]
    public void JoinCommandLine_WindowsRules(string[] args, string expected) =>
        Assert.Equal(expected, EngineCommand.JoinCommandLine(args));

    [Fact]
    public void Timeouts()
    {
        Assert.Equal(TimeSpan.FromMinutes(5), EngineCommand.Timeout(EngineAction.Connect));
        Assert.Equal(TimeSpan.FromSeconds(12), EngineCommand.Timeout(EngineAction.Brief));
        // 托盤逾時要比引擎內部的 6 秒長、又要比 15 秒的輪詢間隔短
        Assert.True(EngineCommand.Timeout(EngineAction.Brief) > TimeSpan.FromSeconds(6));
        Assert.True(EngineCommand.Timeout(EngineAction.Brief) < TimeSpan.FromSeconds(15));
    }

    [Fact]
    public void IsInstallNeeded_MatchesEngineMessages()
    {
        // 引擎 splitswan-wsl.ps1 的兩種安裝訊息，以及 -NoInstall 時的「尚未安裝」
        Assert.True(EngineCommand.IsInstallNeeded("已開始安裝 WSL 與 Ubuntu-24.04，完成（必要時重開機）後請再連線一次"));
        Assert.True(EngineCommand.IsInstallNeeded("已開始安裝 Ubuntu-24.04，完成後請再連線一次"));
        Assert.True(EngineCommand.IsInstallNeeded("尚未安裝 WSL 或 Ubuntu-24.04，請用首次安裝"));
        Assert.False(EngineCommand.IsInstallNeeded("WSL 內連線失敗（結束碼 1）"));
        Assert.False(EngineCommand.IsInstallNeeded(null));
    }

    [Fact]
    public void IsInstallNeeded_FromOutputLines_WhenNoResult()
    {
        // 逾時被結束、沒有 @@RESULT：靠引擎在安裝前印的進度行判斷
        string[] lines = ["== 2/6 檢查 WSL 與 Ubuntu-24.04", "  !!  尚未安裝 Ubuntu-24.04，開始安裝。請照畫面建立 Ubuntu 帳號"];
        Assert.True(EngineCommand.IsInstallNeeded("引擎執行 connect 超過 5 分鐘沒有回應，已中止", lines));
        Assert.False(EngineCommand.IsInstallNeeded("逾時", ["== 4/6 連線 FortiGate"]));
    }

    [Fact]
    public void IsInstallNeeded_EngineScriptStillUsesThePhrase()
    {
        // 這個判斷依賴引擎的訊息文字；引擎改字時這裡會先紅
        var ps1 = FindRepoFile(Path.Combine("tools", "windows", "splitswan-wsl.ps1"));
        if (ps1 is null) Assert.Fail("找不到 tools/windows/splitswan-wsl.ps1：測試要在 repo 內執行（不可用 --artifacts-path 把輸出移出 repo）");
        var text = File.ReadAllText(ps1);
        Assert.Contains("已開始安裝", text);
        Assert.Contains("開始安裝。", text);
        Assert.Contains("不是系統管理員", text);
    }

    [Fact]
    public void EngineScript_SupportsNoInstall()
    {
        // 托盤背景 connect 一律帶 -NoInstall；引擎不認得這個參數時 PowerShell 會直接失敗，所以兩邊必須同步
        var ps1 = FindRepoFile(Path.Combine("tools", "windows", "splitswan-wsl.ps1"));
        if (ps1 is null) Assert.Fail("找不到 tools/windows/splitswan-wsl.ps1：測試要在 repo 內執行（不可用 --artifacts-path 把輸出移出 repo）");
        var text = File.ReadAllText(ps1);
        Assert.Contains("[switch]$NoInstall", text);
        Assert.Contains("FailReason = \"尚未安裝", text);
        // 引擎的 -NoInstall 失敗訊息要能被 IsInstallNeeded 認出來
        Assert.True(EngineCommand.IsInstallNeeded("尚未安裝 WSL 與 Ubuntu-24.04，請用托盤選單「首次安裝 WSL／Ubuntu…」"));
    }

    [Fact]
    public void Arguments_NoInstall_OnlyForConnect()
    {
        Assert.Contains("-NoInstall", EngineCommand.Arguments(EngineAction.Connect, "x.ps1", @"C:\c", noInstall: true));
        Assert.DoesNotContain("-NoInstall", EngineCommand.Arguments(EngineAction.Brief, "x.ps1", @"C:\c", noInstall: true));
        Assert.DoesNotContain("-NoInstall", EngineCommand.Arguments(EngineAction.Connect, "x.ps1", @"C:\c"));
    }

    [Fact]
    public void DescribeMissingResult_IncludesExitCodeAndStderr()
    {
        var m = EngineCommand.DescribeMissingResult(1, ["", "  無法載入檔案 x.ps1，因為這個系統已停用指令碼執行。 ", "第二行", "第三行"]);
        Assert.Equal("引擎沒有回傳結果（結束碼 1）：無法載入檔案 x.ps1，因為這個系統已停用指令碼執行。｜第二行", m);
        Assert.Equal("引擎沒有回傳結果（結束碼未知）", EngineCommand.DescribeMissingResult(null, null));
    }

    private static string? FindRepoFile(string relative)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var p = Path.Combine(dir.FullName, relative);
            if (File.Exists(p)) return p;
            dir = dir.Parent;
        }
        return null;
    }
}

public class LogHygieneTests
{
    [Fact]
    public void Redact_ReplacesSecrets()
    {
        var line = LogHygiene.Redact("password=hunter2 psk=abc-secret", ["hunter2", "abc-secret"]);
        Assert.Equal("password=*** psk=***", line);
    }

    [Fact]
    public void Redact_LongerFirst()
    {
        Assert.Equal("x *** y", LogHygiene.Redact("x secret123 y", ["secret", "secret123"]));
    }

    [Fact]
    public void Redact_IgnoresEmptyAndShort()
    {
        Assert.Equal("a b c", LogHygiene.Redact("a b c", ["", null, "a", "ab"]));
    }

    [Fact]
    public void SelectForDeletion_KeepsNewest()
    {
        var names = new[]
        {
            "tray-20261001-010000.log", "tray-20261003-010000.log", "tray-20261002-010000.log",
            "other.txt", "tray-notes.txt",
        };
        var del = LogHygiene.SelectForDeletion(names, "tray-", 2);
        Assert.Equal(new[] { "tray-20261001-010000.log" }, del);
    }

    [Fact]
    public void SelectForDeletion_FewerThanKeep_Nothing()
    {
        Assert.Empty(LogHygiene.SelectForDeletion(["tray-1.log"], "tray-", 10));
        Assert.Empty(LogHygiene.SelectForDeletion([], "tray-", 0));
    }
}

public class SettingsInputTests
{
    [Fact]
    public void ParseSubnets_LinesAndCommas()
    {
        var l = SettingsInput.ParseSubnets(" 192.0.2.0/24\r\n\r\n198.51.100.0/24, 203.0.113.5/32 \n");
        Assert.Equal(new[] { "192.0.2.0/24", "198.51.100.0/24", "203.0.113.5/32" }, l);
        Assert.Empty(SettingsInput.ParseSubnets(null));
    }

    [Fact]
    public void FormatSubnets_RoundTrip()
    {
        var l = new[] { "192.0.2.0/24", "198.51.100.0/24" };
        Assert.Equal(l, SettingsInput.ParseSubnets(SettingsInput.FormatSubnets(l)));
    }

    [Fact]
    public void ApplyImport_ReplacesCompanyFields_KeepsPersonal()
    {
        var cur = new StoredSettings("alice", "pw", "old-psk", ["203.0.113.1", "203.0.113.2", "203.0.113.3"],
            ["192.0.2.0/24"], "corp.example", "192.0.2.53", true);
        var imp = new ImportedProfile(["198.51.100.1"], ["198.51.100.0/24"], "new-psk");
        var r = SettingsInput.ApplyImport(cur, imp);
        Assert.Equal(new[] { "198.51.100.1", "", "" }, r.Gateways);
        Assert.Equal(new[] { "198.51.100.0/24" }, r.RemoteSubnets);
        Assert.Equal("new-psk", r.Psk);
        Assert.Equal("alice", r.Username);
        Assert.Equal("pw", r.Password);
        Assert.Equal("corp.example", r.Domain);
        Assert.True(r.AutoReconnect);
    }

    [Fact]
    public void ApplyImport_NoPsk_KeepsExisting()
    {
        var cur = StoredSettings.Empty with { Psk = "keep" };
        var r = SettingsInput.ApplyImport(cur, new ImportedProfile(["198.51.100.1"], ["198.51.100.0/24"], ""));
        Assert.Equal("keep", r.Psk);
    }
}

public class BriefTrackerTests
{
    private static IReadOnlyDictionary<string, string> Kv(params string[] lines) => EngineOutput.Parse(lines);

    [Fact]
    public void Classify()
    {
        Assert.Equal(BriefKind.Up, BriefTracker.Classify(Kv("@@STATE=up", "@@GATEWAY=vpn1", "@@RESULT=ok")));
        Assert.Equal(BriefKind.Down, BriefTracker.Classify(Kv("@@STATE=down", "@@RESULT=ok")));
        Assert.Equal(BriefKind.Unknown, BriefTracker.Classify(Kv("@@STATE=unknown", "@@RESULT=fail:查詢 WSL 逾時")));
        // 舊版引擎：失敗時輸出 down＋fail → 仍當成查不到
        Assert.Equal(BriefKind.Unknown, BriefTracker.Classify(Kv("@@STATE=down", "@@RESULT=fail:查詢 WSL 逾時")));
        Assert.Equal(BriefKind.Unknown, BriefTracker.Classify(Kv("@@RESULT=ok")));
        Assert.Equal(BriefKind.Unknown, BriefTracker.Classify(Kv()));
        Assert.Equal(BriefKind.Unknown, BriefTracker.Classify(Kv("@@STATE=up", "@@RESULT=ok"), timedOut: true));
    }

    [Fact]
    public void Unknown_NeverBecomesDown_OnlyMarksStateUnknown()
    {
        var t = new BriefTracker();
        Assert.False(t.Observe(BriefKind.Unknown));
        Assert.False(t.Observe(BriefKind.Unknown));
        Assert.False(t.IsStateUnknown);
        Assert.True(t.Observe(BriefKind.Unknown));    // 第 3 次：剛達上限，回 true 一次
        Assert.True(t.IsStateUnknown);
        for (int i = 0; i < 20; i++) Assert.False(t.Observe(BriefKind.Unknown));   // 之後不再重複回報
        Assert.True(t.IsStateUnknown);
        Assert.Equal(23, t.ConsecutiveUnknown);
        // Observe 沒有任何回傳 Down 的路徑：查不到多少次都不算斷線
    }

    [Fact]
    public void StateUnknownNotice_OncePerEpisode()
    {
        // 托盤在 Observe 回 true 時發通知：同一段狀態不明只通知一次，確定結果之後的新一段再通知一次
        var t = new BriefTracker();
        var notices = 0;
        void Feed(BriefKind k) { if (t.Observe(k)) notices++; }
        for (int i = 0; i < 50; i++) Feed(BriefKind.Unknown);
        Assert.Equal(1, notices);
        Feed(BriefKind.Up);
        for (int i = 0; i < 2; i++) Feed(BriefKind.Unknown);
        Assert.Equal(1, notices);            // 新一段還沒滿 3 次
        for (int i = 0; i < 10; i++) Feed(BriefKind.Unknown);
        Assert.Equal(2, notices);
        Assert.Contains("請按「連線」", TrayText.StateUnknownBody);
    }

    [Fact]
    public void DefiniteResult_ResetsCount()
    {
        var t = new BriefTracker();
        t.Observe(BriefKind.Unknown);
        t.Observe(BriefKind.Unknown);
        t.Observe(BriefKind.Unknown);
        Assert.True(t.IsStateUnknown);
        Assert.False(t.Observe(BriefKind.Down));
        Assert.Equal(0, t.ConsecutiveUnknown);
        Assert.False(t.IsStateUnknown);
        t.Observe(BriefKind.Unknown);
        t.Reset();
        Assert.Equal(0, t.ConsecutiveUnknown);
        Assert.False(t.Observe(BriefKind.Unknown));
        Assert.False(t.Observe(BriefKind.Unknown));
        Assert.True(t.Observe(BriefKind.Unknown));     // Reset 後重新數到 3 才會再回報
    }
}
