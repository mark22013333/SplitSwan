namespace SplitSwan.Core.Tests;

/// <summary>桌面／開始選單捷徑的狀態判斷（ShortcutRules）。</summary>
public class ShortcutRulesTests
{
    private const string Exe = @"C:\Users\user\Downloads\SplitSwan\SplitSwan.exe";
    /// <summary>我們寫入捷徑描述的標記。</summary>
    private const string M = ShortcutRules.Description;

    // ── 四種狀態 ─────────────────────────────────────

    [Fact]
    public void Classify_NotExists_IsMissing_EvenWithTarget()
    {
        Assert.Equal(ShortcutState.Missing, ShortcutRules.Classify(false, null, M, Exe));
        Assert.Equal(ShortcutState.Missing, ShortcutRules.Classify(false, Exe, M, Exe));
    }

    [Fact]
    public void Classify_SamePath_IsOurs() =>
        Assert.Equal(ShortcutState.Ours, ShortcutRules.Classify(true, Exe, M, Exe));

    [Fact]
    public void Classify_SplitSwanExeElsewhere_IsStale() =>
        Assert.Equal(ShortcutState.Stale, ShortcutRules.Classify(true, @"D:\Tools\SplitSwan-old\SplitSwan.exe", M, Exe));

    [Theory]
    [InlineData(@"C:\Program Files\Fortinet\FortiClient\FortiClient.exe")]
    [InlineData(@"C:\Users\user\Downloads\SplitSwan\SplitSwan.exe.bak")]
    [InlineData(@"C:\Users\user\Downloads\SplitSwan\NotSplitSwan.exe")]
    [InlineData(@"C:\Users\user\Downloads\SplitSwan")]
    public void Classify_OtherTarget_IsForeign(string target) =>
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, target, M, Exe));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void Classify_ExistsButUnreadableTarget_IsForeign(string? target) =>
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, target, M, Exe));

    // ── 大小寫與正規化 ───────────────────────────────

    [Theory]
    [InlineData(@"c:\users\USER\downloads\splitswan\splitswan.EXE")]
    [InlineData(@"C:/Users/user/Downloads/SplitSwan/SplitSwan.exe")]
    [InlineData(@"C:\Users\user\\Downloads\\\SplitSwan\SplitSwan.exe")]
    [InlineData(@"C:\Users\user\Downloads\.\SplitSwan\SplitSwan.exe")]
    [InlineData(@"C:\Users\user\Desktop\..\Downloads\SplitSwan\SplitSwan.exe")]
    [InlineData(@"\\?\C:\Users\user\Downloads\SplitSwan\SplitSwan.exe")]
    [InlineData("\"C:\\Users\\user\\Downloads\\SplitSwan\\SplitSwan.exe\"")]
    [InlineData(@"  C:\Users\user\Downloads\SplitSwan\SplitSwan.exe  ")]
    public void Classify_EquivalentPaths_AreOurs(string target) =>
        Assert.Equal(ShortcutState.Ours, ShortcutRules.Classify(true, target, M, Exe));

    [Fact]
    public void Classify_CaseDifferentFileNameElsewhere_IsStale() =>
        Assert.Equal(ShortcutState.Stale, ShortcutRules.Classify(true, @"E:\SPLITSWAN.EXE", M, Exe));

    [Fact]
    public void Classify_ParentEscapeDoesNotMakeDifferentPathEqual()
    {
        // C:\a\..\..\SplitSwan.exe 不可退到 C: 之上；結果是 C:\SplitSwan.exe，與 Exe 不同 → 舊位置
        Assert.Equal(ShortcutState.Stale, ShortcutRules.Classify(true, @"C:\a\..\..\SplitSwan.exe", M, Exe));
        Assert.Equal(@"C:\SplitSwan.exe", ShortcutRules.NormalizePath(@"C:\a\..\..\SplitSwan.exe"));
    }

    [Fact]
    public void Classify_RenamedExe_OnlySplitSwanExeIsStale()
    {
        const string renamed = @"C:\Apps\SplitSwan-0.1\SplitSwan-0.1.exe";
        Assert.Equal(ShortcutState.Ours, ShortcutRules.Classify(true, renamed, M, renamed));
        // 規格變更（review8／Leader 裁決）：Stale 只認 SplitSwan.exe；與改名後 exe 同檔名但路徑不同 → Foreign（原本期望 Stale）
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, @"C:\Old\SplitSwan-0.1.exe", M, renamed));
        Assert.Equal(ShortcutState.Stale, ShortcutRules.Classify(true, @"C:\Old\SplitSwan.exe", M, renamed));
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, @"C:\Old\notepad.exe", M, renamed));
    }

    // ── 標記（描述＝"SplitSwan VPN"）：review8／Leader 裁決 ─────────

    [Fact]
    public void Classify_RenamedExe_OthersSameNameShortcut_IsForeign()
    {
        // exe 改名成通用名稱 vpn.exe；別人的同名 SplitSwan.lnk 指向別處的 vpn.exe
        const string renamed = @"C:\a\vpn.exe";
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, @"D:\tools\vpn.exe", "Other VPN", renamed));
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, @"D:\tools\vpn.exe", null, renamed));
        // 就算有我們的標記，檔名也不是 SplitSwan.exe、路徑也不是目前 exe → 仍是 Foreign
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, @"D:\tools\vpn.exe", M, renamed));
    }

    [Theory]
    [InlineData(@"D:\Tools\SplitSwan-old\SplitSwan.exe")]
    [InlineData(@"C:\Program Files\Other\SplitSwan.exe")]
    [InlineData(@"\\server\share\SplitSwan.exe")]
    public void Classify_MarkedButOtherSplitSwanExe_IsStale(string target) =>
        Assert.Equal(ShortcutState.Stale, ShortcutRules.Classify(true, target, M, Exe));

    [Theory]
    [InlineData("")]
    [InlineData("SplitSwan")]
    [InlineData("splitswan vpn")]
    [InlineData("SPLITSWAN VPN")]
    [InlineData("SplitSwan VPN ")]
    [InlineData(" SplitSwan VPN")]
    [InlineData("SplitSwan  VPN")]
    [InlineData("我的 VPN 捷徑")]
    public void Classify_NoMarkButPointsToThisExe_IsForeign(string description)
    {
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, Exe, description, Exe));
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, @"D:\Old\SplitSwan.exe", description, Exe));
    }

    [Fact]
    public void Classify_DescriptionReadFailed_IsForeign()
    {
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, Exe, null, Exe));
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, @"D:\Old\SplitSwan.exe", null, Exe));
    }

    [Fact]
    public void Classify_MarkPositiveControl()
    {
        // 正對照：同樣的目標加上標記就是 Ours／Stale，證明上面的 Foreign 是標記造成的
        Assert.Equal(ShortcutState.Ours, ShortcutRules.Classify(true, Exe, M, Exe));
        Assert.Equal(ShortcutState.Stale, ShortcutRules.Classify(true, @"D:\Old\SplitSwan.exe", M, Exe));
        Assert.True(ShortcutRules.IsOurMark("SplitSwan VPN"));
        Assert.False(ShortcutRules.IsOurMark(null));
        Assert.False(ShortcutRules.IsOurMark("splitswan vpn"));
    }

    [Fact]
    public void Classify_NotExists_IsMissing_RegardlessOfMark()
    {
        Assert.Equal(ShortcutState.Missing, ShortcutRules.Classify(false, Exe, null, Exe));
        Assert.Equal(ShortcutState.Missing, ShortcutRules.Classify(false, null, "x", Exe));
    }

    // ── 長路徑縮寫 ───────────────────────────────────

    [Fact]
    public void CompactPath_ShortPathUnchanged() =>
        Assert.Equal(Exe, ShortcutRules.CompactPath(Exe, 80));

    [Fact]
    public void CompactPath_LongPath_KeepsDriveAndTail()
    {
        var longPath = @"C:\Users\user\Documents\Some Very Long Folder Name\Another Folder\Deeper\SplitSwan\SplitSwan.exe";
        var c = ShortcutRules.CompactPath(longPath, 40);
        Assert.True(c.Length <= 40, c);
        Assert.StartsWith(@"C:\…\", c);
        Assert.EndsWith(@"\SplitSwan\SplitSwan.exe", c);
    }

    [Fact]
    public void CompactPath_Unc_KeepsServerShare()
    {
        var c = ShortcutRules.CompactPath(@"\\server\share\a very long folder\another long folder\SplitSwan.exe", 36);
        Assert.True(c.Length <= 36, c);
        Assert.StartsWith(@"\\server\share\…\", c);
        Assert.EndsWith(@"\SplitSwan.exe", c);
    }

    [Fact]
    public void CompactPath_HugeFileName_KeepsTailOnly()
    {
        var name = new string('x', 100) + ".exe";
        var c = ShortcutRules.CompactPath(@"C:\" + name, 30);
        Assert.Equal(30, c.Length);
        Assert.StartsWith("…", c);
        Assert.EndsWith(".exe", c);
    }

    [Fact]
    public void Classify_UnknownCurrentExe_FallsBackToFileName()
    {
        Assert.Equal(ShortcutState.Stale, ShortcutRules.Classify(true, Exe, M, null));
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, @"C:\x\other.exe", M, ""));
    }

    [Theory]
    [InlineData(@"\\?\UNC\server\share\SplitSwan\SplitSwan.exe", @"\\server\share\SplitSwan\SplitSwan.exe")]
    [InlineData(@"\\server\share\..\..\SplitSwan.exe", @"\\server\share\SplitSwan.exe")]
    [InlineData(@"c:\", @"C:\")]
    [InlineData(@"c:", @"C:\")]
    [InlineData(@"c:\Tools\", @"C:\Tools")]
    [InlineData(@"c:\Tools\SplitSwan.exe. ", @"C:\Tools\SplitSwan.exe")]
    public void NormalizePath_Cases(string input, string expected) =>
        Assert.Equal(expected, ShortcutRules.NormalizePath(input));

    [Fact]
    public void SamePath_EmptyIsNeverEqual()
    {
        Assert.False(ShortcutRules.SamePath("", ""));
        Assert.False(ShortcutRules.SamePath(null, null));
        Assert.True(ShortcutRules.SamePath(@"C:\A\b.exe", @"c:/a/B.EXE"));
    }

    [Theory]
    [InlineData(@"C:\Users\user\Downloads\SplitSwan\SplitSwan.exe", @"C:\Users\user\Downloads\SplitSwan")]
    [InlineData(@"C:\SplitSwan.exe", @"C:\")]
    [InlineData(@"\\server\share\SplitSwan.exe", @"\\server\share")]
    [InlineData("SplitSwan.exe", "")]
    public void DirectoryOf_Cases(string exe, string dir) => Assert.Equal(dir, ShortcutRules.DirectoryOf(exe));

    // ── 開關動作 ─────────────────────────────────────

    [Theory]
    [InlineData(ShortcutState.Missing, true, ShortcutAction.Create)]
    [InlineData(ShortcutState.Missing, false, ShortcutAction.None)]
    [InlineData(ShortcutState.Ours, true, ShortcutAction.None)]
    [InlineData(ShortcutState.Ours, false, ShortcutAction.Remove)]
    [InlineData(ShortcutState.Stale, true, ShortcutAction.Update)]
    [InlineData(ShortcutState.Stale, false, ShortcutAction.Remove)]
    [InlineData(ShortcutState.Foreign, true, ShortcutAction.Refuse)]
    [InlineData(ShortcutState.Foreign, false, ShortcutAction.Refuse)]
    public void OnToggle_Table(ShortcutState s, bool on, ShortcutAction expected) =>
        Assert.Equal(expected, ShortcutRules.OnToggle(s, on));

    [Fact]
    public void ForeignIsNeverRemovable_AndShowsOff()
    {
        Assert.False(ShortcutRules.CanRemove(ShortcutState.Foreign));
        Assert.False(ShortcutRules.CanRemove(ShortcutState.Missing));
        Assert.True(ShortcutRules.CanRemove(ShortcutState.Ours));
        Assert.True(ShortcutRules.CanRemove(ShortcutState.Stale));
        Assert.False(ShortcutRules.IsOn(ShortcutState.Foreign));
        Assert.False(ShortcutRules.IsOn(ShortcutState.Missing));
        Assert.True(ShortcutRules.IsOn(ShortcutState.Ours));
        Assert.True(ShortcutRules.IsOn(ShortcutState.Stale));
    }

    [Fact]
    public void EveryRemoveDecision_IsRemovable()
    {
        // 正對照：OnToggle 回 Remove 的狀態，一定通過 CanRemove（刪除前的守門與決策表一致）
        foreach (var s in Enum.GetValues<ShortcutState>())
            if (ShortcutRules.OnToggle(s, false) == ShortcutAction.Remove) Assert.True(ShortcutRules.CanRemove(s), s.ToString());
    }

    [Fact]
    public void Texts()
    {
        Assert.Equal("SplitSwan.lnk", ShortcutRules.FileName);
        Assert.Equal("SplitSwan VPN", ShortcutRules.Description);
        Assert.Equal("桌面捷徑", ShortcutRules.Title(ShortcutLocation.Desktop));
        Assert.Equal("開始選單", ShortcutRules.Title(ShortcutLocation.StartMenu));
        Assert.Contains("已有同名捷徑，未變更", ShortcutRules.ResultLine(ShortcutLocation.Desktop, ShortcutAction.Refuse));
        Assert.StartsWith("✖", ShortcutRules.ResultLine(ShortcutLocation.StartMenu, ShortcutAction.Create, "拒絕存取"));
        Assert.StartsWith("✔", ShortcutRules.ResultLine(ShortcutLocation.StartMenu, ShortcutAction.Create));
    }
}
