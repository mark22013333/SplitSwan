using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace SplitSwan.Core.Tests;

// 第三階段（契約 6）：首次設定精靈的純邏輯、settings.json 的 distro 欄位、引擎 setup／-Distro 參數

public class UbuntuWslImagesTests
{
    // 2026-10-04 實際下載的 https://releases.ubuntu.com/24.04/SHA256SUMS 節錄（含 iso 與四段版號）
    private const string RealSums =
        "faabcf33ae53976d2b8207a001ff32f4e5daae013505ac7188c9ea63988f8328 *ubuntu-24.04.3-desktop-amd64.iso\n" +
        "c74833a55e525b1e99e1541509c566bb3e32bdb53bf27ea3347174364a57f47c *ubuntu-24.04.3-wsl-amd64.wsl\n" +
        "9b2f7730dc68227dd04a9f3e5eab86ad85caf556b8606ad94f1f29ff5c4fd3f5 *ubuntu-24.04.4-wsl-amd64.wsl\n" +
        "97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8 *ubuntu-24.04.5-live-server-amd64.iso\n" +
        "bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e *ubuntu-24.04.5-wsl-amd64.wsl\n" +
        "4da4a0c9035da8e68a59a838674f403f0a54472c78a83b4fb7f78d03588f85a7 *ubuntu-24.04.5.1-desktop-amd64.iso\n";

    [Fact]
    public void Latest_PicksHighestWslAmd64()
    {
        var img = UbuntuWslImages.Latest(RealSums);
        Assert.NotNull(img);
        Assert.Equal("ubuntu-24.04.5-wsl-amd64.wsl", img.FileName);
        Assert.Equal("24.04.5", img.Version);
        Assert.Equal("bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e", img.Sha256);
        Assert.Equal("https://releases.ubuntu.com/24.04/ubuntu-24.04.5-wsl-amd64.wsl", img.Url.ToString());
    }

    [Fact]
    public void Parse_OnlyWslAmd64_SortedDescending()
    {
        var all = UbuntuWslImages.Parse(RealSums);
        Assert.Equal(["24.04.5", "24.04.4", "24.04.3"], all.Select(i => i.Version));
    }

    [Fact]
    public void Versions_CompareNumerically_NotLexically()
    {
        var sums = new string('a', 64) + " *ubuntu-24.04.9-wsl-amd64.wsl\n" +
                   new string('b', 64) + " *ubuntu-24.04.10-wsl-amd64.wsl\n" +
                   new string('c', 64) + " *ubuntu-24.04.10.1-wsl-amd64.wsl\n";
        Assert.Equal("24.04.10.1", UbuntuWslImages.Latest(sums)!.Version);
        Assert.True(UbuntuWslImages.CompareVersions("24.04.10", "24.04.9") > 0);
        Assert.True(UbuntuWslImages.CompareVersions("24.04.5.1", "24.04.5") > 0);
        Assert.Equal(0, UbuntuWslImages.CompareVersions("24.04.5", "24.04.5"));
    }

    [Theory]
    [InlineData("  *ubuntu-24.04.5-wsl-amd64.wsl")]                                        // 沒有雜湊
    [InlineData("bb415d82 *ubuntu-24.04.5-wsl-amd64.wsl")]                                 // 雜湊太短
    [InlineData("zz415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e *ubuntu-24.04.5-wsl-amd64.wsl")] // 非十六進位
    [InlineData("bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e *ubuntu-24.04.5-wsl-arm64.wsl")] // ARM64
    [InlineData("bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e *ubuntu-22.04.5-wsl-amd64.wsl")] // 其他版本
    [InlineData("bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e *../ubuntu-24.04.5-wsl-amd64.wsl")] // 路徑
    [InlineData("bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e *ubuntu-24.04.５-wsl-amd64.wsl")] // 全形數字
    public void Parse_RejectsMalformedLines(string line) => Assert.Empty(UbuntuWslImages.Parse(line));

    [Fact]
    public void Parse_HandlesCrlf_TextMode_AndUppercaseHash()
    {
        var sums = "BB415D824822C4B878125729AF451A5D18FB13D1CF5CBED9A7393AD64AC6039E  ubuntu-24.04.5-wsl-amd64.wsl\r\n";
        var img = Assert.Single(UbuntuWslImages.Parse(sums));
        Assert.Equal("bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e", img.Sha256);
    }

    [Fact]
    public void Parse_ConflictingHashForSameFile_IsDropped()
    {
        var sums = new string('a', 64) + " *ubuntu-24.04.5-wsl-amd64.wsl\n" +
                   new string('b', 64) + " *ubuntu-24.04.5-wsl-amd64.wsl\n" +
                   new string('c', 64) + " *ubuntu-24.04.4-wsl-amd64.wsl\n";
        Assert.Equal("24.04.4", UbuntuWslImages.Latest(sums)!.Version);
    }

    [Fact]
    public void Latest_NullOrEmpty_ReturnsNull()
    {
        Assert.Null(UbuntuWslImages.Latest(null));
        Assert.Null(UbuntuWslImages.Latest("<html>not found</html>"));
    }

    [Fact]
    public void HashMatches_ComparesCaseInsensitive()
    {
        var data = Encoding.ASCII.GetBytes("hello");
        var hash = SHA256.HashData(data);
        var hex = Convert.ToHexString(hash);
        Assert.True(UbuntuWslImages.HashMatches(hex.ToLowerInvariant(), hash));
        Assert.True(UbuntuWslImages.HashMatches(hex, hash));
        hash[0] ^= 1;
        Assert.False(UbuntuWslImages.HashMatches(hex, hash));
        Assert.False(UbuntuWslImages.HashMatches(hex, [1, 2, 3]));
    }

    [Fact]
    public void FormatProgress_ShowsMegabytesAndPercent()
    {
        Assert.Equal("100.0 MB / 400.0 MB（25%）", UbuntuWslImages.FormatProgress(100L << 20, 400L << 20));
        Assert.Equal("1.5 MB", UbuntuWslImages.FormatProgress(3L << 19, null));
    }

    [Fact]
    public void RequiredFreeBytes_AddsRoomForImport() =>
        Assert.Equal((400L << 20) + (3L << 30), UbuntuWslImages.RequiredFreeBytes(400L << 20));
}

public class SystemRequirementsTests
{
    [Fact]
    public void ModernX64WithHypervisor_Passes()
    {
        var items = SystemRequirements.Evaluate(22631, Architecture.X64, true, false);
        Assert.True(SystemRequirements.Passed(items));
        Assert.All(items, i => Assert.Equal(CheckLevel.Ok, i.Level));
    }

    [Fact]
    public void OldBuild_Fails() =>
        Assert.False(SystemRequirements.Passed(SystemRequirements.Evaluate(19041 - 1, Architecture.X64, true, null)));

    [Fact]
    public void MinBuild_Passes() =>
        Assert.True(SystemRequirements.Passed(SystemRequirements.Evaluate(19041, Architecture.X64, null, true)));

    [Fact]
    public void Arm64_FailsWithExplicitMessage()
    {
        var items = SystemRequirements.Evaluate(26100, Architecture.Arm64, true, null);
        Assert.False(SystemRequirements.Passed(items));
        Assert.Contains(items, i => i.Level == CheckLevel.Error && i.Text.Contains("ARM64"));
    }

    [Fact]
    public void VirtualizationOff_Fails() =>
        Assert.False(SystemRequirements.Passed(SystemRequirements.Evaluate(22631, Architecture.X64, false, false)));

    [Fact]
    public void VirtualizationUnknown_IsWarningOnly()
    {
        var items = SystemRequirements.Evaluate(22631, Architecture.X64, null, null);
        Assert.True(SystemRequirements.Passed(items));
        Assert.Contains(items, i => i.Level == CheckLevel.Warning);
    }
}

public class WslInstallStateTests
{
    private const int Win11 = 22631;
    private const int Win10 = 19045;

    private static WslProbe P(bool store = true, string? vmp = "Enabled", string? wslf = "Enabled", bool? hns = true, bool? vmc = true) =>
        new(store, vmp, wslf, hns, vmc, null, null);

    [Fact]
    public void ParseProbe_ReadsAllKeys()
    {
        var p = WslInstallState.ParseProbe(
        [
            "雜訊", "@@STOREWSL=1", "@@VMP=EnablePending", "@@WSLFEATURE=", "@@HNS=0", "@@VMCOMPUTE=1",
            "@@HYPERVISOR=True", "@@VTFW=False", "@@RESULT=ok",
        ]);
        Assert.True(p.StoreWsl);
        Assert.Equal("EnablePending", p.VmpState);
        Assert.Null(p.WslFeatureState);
        Assert.False(p.HnsPresent);
        Assert.True(p.VmcomputePresent);
        Assert.True(p.HypervisorPresent);
        Assert.False(p.VirtualizationFirmwareEnabled);
    }

    [Fact]
    public void ParseProbe_EmptyOutput_AllUnknown()
    {
        var p = WslInstallState.ParseProbe([]);
        Assert.False(p.StoreWsl);
        Assert.Null(p.VmpState);
        Assert.Null(p.HnsPresent);
    }

    [Fact]
    public void AllEnabled_ServicesUp_Ready() => Assert.Equal(WslReadiness.Ready, WslInstallState.Evaluate(P(), Win11));

    [Fact]
    public void NoStoreWsl_NeedsInstall() => Assert.Equal(WslReadiness.NeedInstall, WslInstallState.Evaluate(P(store: false), Win11));

    [Fact]
    public void VmpDisabled_NeedsInstall() => Assert.Equal(WslReadiness.NeedInstall, WslInstallState.Evaluate(P(vmp: "Disabled"), Win11));

    [Fact]
    public void VmpPending_NeedsReboot() => Assert.Equal(WslReadiness.NeedReboot, WslInstallState.Evaluate(P(vmp: "EnablePending"), Win11));

    [Fact]
    public void EnabledButServicesMissing_NeedsReboot() =>
        Assert.Equal(WslReadiness.NeedReboot, WslInstallState.Evaluate(P(hns: false), Win11));

    [Fact]
    public void UnknownState_NeedsReboot_UntilRebootedWithServices()
    {
        Assert.Equal(WslReadiness.NeedReboot, WslInstallState.Evaluate(P(vmp: null), Win11));
        Assert.Equal(WslReadiness.Ready, WslInstallState.Evaluate(P(vmp: null), Win11, rebootedSinceInstall: true));
        Assert.Equal(WslReadiness.NeedReboot, WslInstallState.Evaluate(P(vmp: null, vmc: null), Win11, rebootedSinceInstall: true));
    }

    [Fact]
    public void Windows10_AlsoRequiresWslFeature()
    {
        Assert.Equal(WslReadiness.NeedInstall, WslInstallState.Evaluate(P(wslf: "Disabled"), Win10));
        Assert.Equal(WslReadiness.NeedReboot, WslInstallState.Evaluate(P(wslf: "EnablePending"), Win10));
        // Windows 11 不需要 WSL 選用元件（同 WSL 原始碼）
        Assert.Equal(WslReadiness.Ready, WslInstallState.Evaluate(P(wslf: "Disabled"), Win11));
    }

    [Fact]
    public void ProbeScript_EndsWithResultAndUsesFixedFeatureNames()
    {
        Assert.Contains("VirtualMachinePlatform", WslInstallState.ProbeScript);
        Assert.Contains("Microsoft-Windows-Subsystem-Linux", WslInstallState.ProbeScript);
        Assert.EndsWith("Write-Output '@@RESULT=ok'", WslInstallState.ProbeScript);
    }
}

public class WslDistrosTests
{
    [Theory]
    [InlineData("SplitSwan", true)]
    [InlineData("Ubuntu-24.04", true)]
    [InlineData("a_b.c-d", true)]
    [InlineData("", false)]
    [InlineData("-x", false)]
    [InlineData("--install", false)]
    [InlineData(".hidden", false)]         // 同引擎白名單：首字必須是英數
    [InlineData("_x", false)]
    [InlineData("x_", true)]
    [InlineData("SplitSwan\n", false)]    // .NET 的 $ 會放過結尾換行，所以用 \z
    [InlineData("a/b", false)]
    [InlineData("has space", false)]
    [InlineData("x\"y", false)]
    [InlineData("名稱", false)]
    public void IsValidName(string name, bool ok) => Assert.Equal(ok, WslDistros.IsValidName(name));

    [Fact]
    public void ParseList_StripsNulBomAndBlank()
    {
        var list = WslDistros.ParseList(["\uFEFFS\0p\0l\0i\0t\0S\0w\0a\0n\0", "", "  Ubuntu-24.04  ", "\0"]);
        Assert.Equal(["SplitSwan", "Ubuntu-24.04"], list);
        Assert.True(WslDistros.Contains(list, "splitswan"));
        Assert.False(WslDistros.Contains(list, "Debian"));
    }

    [Fact]
    public void DefaultRootScript_SetsDefaultRootUnderUserSection()
    {
        Assert.Contains("default=root", WslDistros.DefaultRootScript);
        Assert.Contains("/etc/wsl.conf", WslDistros.DefaultRootScript);
    }

    [Theory]
    [InlineData("SplitSwan", new[] { "SplitSwan" }, false, DistroAction.UseConfigured)]
    [InlineData("Ubuntu-24.04", new[] { "Ubuntu-24.04", "SplitSwan" }, false, DistroAction.UseConfigured)]
    [InlineData("Ubuntu-24.04", new[] { "SplitSwan" }, false, DistroAction.UseExistingSplitSwan)]
    [InlineData("SplitSwan", new string[0], true, DistroAction.ImportInPlace)]
    [InlineData("SplitSwan", new[] { "Debian" }, false, DistroAction.DownloadAndImport)]
    [InlineData("Ubuntu-24.04", new string[0], false, DistroAction.DownloadAndImport)]
    public void DistroPlan_Decide(string configured, string[] installed, bool vhdx, DistroAction expected) =>
        Assert.Equal(expected, DistroPlan.Decide(configured, installed, vhdx));

    [Theory]
    [InlineData(false, true, true, false)]
    [InlineData(false, true, null, false)]
    [InlineData(false, false, true, true)]
    [InlineData(false, true, false, true)]
    [InlineData(true, true, true, true)]
    public void WizardTrigger_ShouldAutoOpen(bool resume, bool valid, bool? exists, bool expected) =>
        Assert.Equal(expected, WizardTrigger.ShouldAutoOpen(resume, valid, exists));
}

public class SetupWizardStateTests
{
    private static readonly DateTimeOffset Boot1 = new(2026, 10, 4, 8, 0, 0, TimeSpan.FromHours(8));

    [Fact]
    public void New_StartsAtSystemCheck()
    {
        var s = new SetupWizardState();
        Assert.Equal(WizardStep.SystemCheck, s.Current);
        Assert.False(s.Completed);
        Assert.False(s.CanGoNext);
        Assert.False(s.CanGoBack);
        Assert.Equal("▶", s.Mark(WizardStep.SystemCheck));
        Assert.Equal("○", s.Mark(WizardStep.InstallWsl));
    }

    [Fact]
    public void Complete_ThenNext_Advances()
    {
        var s = new SetupWizardState();
        s.Start(WizardStep.SystemCheck);
        Assert.Equal("▶", s.Mark(WizardStep.SystemCheck));
        Assert.False(s.CanGoNext);
        s.Complete(WizardStep.SystemCheck, skipped: false);
        Assert.Equal("✔", s.Mark(WizardStep.SystemCheck));
        Assert.True(s.GoNext());
        Assert.Equal(WizardStep.InstallWsl, s.Current);
    }

    [Fact]
    public void Fail_ThenReset_AllowsRetry()
    {
        var s = new SetupWizardState();
        s.Start(WizardStep.SystemCheck);
        s.Fail(WizardStep.SystemCheck, "虛擬化沒開");
        Assert.Equal("✖", s.Mark(WizardStep.SystemCheck));
        Assert.Equal("虛擬化沒開", s.ErrorOf(WizardStep.SystemCheck));
        Assert.False(s.GoNext());
        s.Reset(WizardStep.SystemCheck);
        Assert.Null(s.ErrorOf(WizardStep.SystemCheck));
        Assert.Equal(WizardStepStatus.NotStarted, s.StatusOf(WizardStep.SystemCheck));
    }

    [Fact]
    public void PerformingStep_ResetsLaterWslSteps_ButKeepsConfigure()
    {
        var s = new SetupWizardState();
        foreach (var st in SetupWizardState.Steps) s.Complete(st, skipped: false);
        Assert.True(s.Completed);
        s.Complete(WizardStep.ImportDistro, skipped: false);   // 重新匯入
        Assert.Equal(WizardStepStatus.NotStarted, s.StatusOf(WizardStep.SetupStrongSwan));
        Assert.Equal(WizardStepStatus.NotStarted, s.StatusOf(WizardStep.TestConnection));
        Assert.Equal(WizardStepStatus.Done, s.StatusOf(WizardStep.Configure));
        Assert.Equal(WizardStepStatus.Done, s.StatusOf(WizardStep.InstallWsl));
    }

    [Fact]
    public void SkippingStep_KeepsLaterSteps()
    {
        var s = new SetupWizardState();
        s.Complete(WizardStep.SetupStrongSwan, skipped: false);
        s.Complete(WizardStep.ImportDistro, skipped: true);
        Assert.Equal(WizardStepStatus.Done, s.StatusOf(WizardStep.SetupStrongSwan));
        Assert.Equal("✔", s.Mark(WizardStep.ImportDistro));
    }

    [Fact]
    public void Back_MovesToPreviousStep_NotWhileRunning()
    {
        var s = new SetupWizardState();
        s.Complete(WizardStep.SystemCheck, false);
        s.GoNext();
        s.Start(WizardStep.InstallWsl);
        Assert.False(s.GoBack());
        s.Fail(WizardStep.InstallWsl, "x");
        Assert.True(s.GoBack());
        Assert.Equal(WizardStep.SystemCheck, s.Current);
    }

    [Fact]
    public void Reboot_DetectedWhenBootTimeChanges()
    {
        var s = new SetupWizardState();
        s.RequireReboot(Boot1);
        Assert.True(s.RebootPending);
        Assert.Equal(WizardStep.InstallWsl, s.Current);
        Assert.False(s.ObserveBoot(Boot1.AddSeconds(30)));   // 同一次開機（時鐘誤差）
        Assert.True(s.RebootPending);
        Assert.True(s.ObserveBoot(Boot1.AddHours(1)));
        Assert.False(s.RebootPending);
        Assert.True(s.RebootedSinceInstall);
    }

    [Fact]
    public void CompletingInstallWsl_ClearsRebootPending()
    {
        var s = new SetupWizardState();
        s.RequireReboot(Boot1);
        s.Complete(WizardStep.InstallWsl, skipped: true);
        Assert.False(s.RebootPending);
    }

    [Fact]
    public void Json_RoundTrip_ResumesAfterReboot()
    {
        var s = new SetupWizardState();
        s.Complete(WizardStep.SystemCheck, false);
        s.GoNext();
        s.RequireReboot(Boot1);
        s.Fail(WizardStep.ImportDistro, "下載失敗");
        var back = SetupWizardState.FromJson(s.ToJson());
        Assert.Equal(WizardStep.InstallWsl, back.Current);
        Assert.True(back.RebootPending);
        Assert.Equal(Boot1, back.RebootRequestedBootTime);
        Assert.Equal(WizardStepStatus.Done, back.StatusOf(WizardStep.SystemCheck));
        Assert.Equal("下載失敗", back.ErrorOf(WizardStep.ImportDistro));
        Assert.True(back.ObserveBoot(Boot1.AddMinutes(10)));
    }

    [Fact]
    public void Json_RunningStep_ReadsBackAsNotStarted()
    {
        var s = new SetupWizardState();
        s.Start(WizardStep.ImportDistro);
        var back = SetupWizardState.FromJson(s.ToJson());
        Assert.Equal(WizardStepStatus.NotStarted, back.StatusOf(WizardStep.ImportDistro));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("{壞掉")]
    [InlineData("[]")]
    [InlineData("{\"version\":99,\"current\":\"Configure\"}")]
    public void Json_BadInput_FreshState(string? json)
    {
        var s = SetupWizardState.FromJson(json);
        Assert.Equal(WizardStep.SystemCheck, s.Current);
        Assert.All(SetupWizardState.Steps, st => Assert.Equal(WizardStepStatus.NotStarted, s.StatusOf(st)));
    }

    [Fact]
    public void Json_UnknownNamesIgnored_PendingWithoutBootTimeCleared()
    {
        var json = "{\"version\":1,\"current\":\"Nope\",\"steps\":{\"Nope\":\"Done\",\"Configure\":\"Weird\",\"SystemCheck\":\"Skipped\"}," +
                   "\"rebootPending\":true}";
        var s = SetupWizardState.FromJson(json);
        Assert.Equal(WizardStep.SystemCheck, s.Current);
        Assert.Equal(WizardStepStatus.Skipped, s.StatusOf(WizardStep.SystemCheck));
        Assert.Equal(WizardStepStatus.NotStarted, s.StatusOf(WizardStep.Configure));
        Assert.False(s.RebootPending);
    }

    [Fact]
    public void PrepareForOpen_RechecksCheapSteps_KeepsSlowOnes()
    {
        var s = new SetupWizardState();
        foreach (var st in SetupWizardState.Steps) s.Complete(st, skipped: false);
        s.PrepareForOpen();
        Assert.Equal(WizardStep.SystemCheck, s.Current);
        Assert.Equal(WizardStepStatus.NotStarted, s.StatusOf(WizardStep.SystemCheck));
        Assert.Equal(WizardStepStatus.NotStarted, s.StatusOf(WizardStep.InstallWsl));
        Assert.Equal(WizardStepStatus.NotStarted, s.StatusOf(WizardStep.ImportDistro));
        Assert.Equal(WizardStepStatus.NotStarted, s.StatusOf(WizardStep.Configure));
        Assert.Equal(WizardStepStatus.Done, s.StatusOf(WizardStep.SetupStrongSwan));
        Assert.Equal(WizardStepStatus.Done, s.StatusOf(WizardStep.TestConnection));
    }

    [Fact]
    public void Titles_AllSixDefined()
    {
        Assert.Equal(6, SetupWizardState.Steps.Count);
        Assert.All(SetupWizardState.Steps, st => Assert.False(string.IsNullOrEmpty(SetupWizardState.Title(st))));
    }
}

public class DistroSettingTests
{
    private static readonly Func<byte[], byte[]> Id = b => b;

    [Fact]
    public void NewInstall_DefaultsToSplitSwan() => Assert.Equal("SplitSwan", StoredSettings.Empty.Distro);

    [Fact]
    public void OldFile_WithoutDistro_IsUbuntu2404()
    {
        var json = "{\"version\":1,\"username\":\"u\",\"gateways\":[\"203.0.113.10\"],\"remoteSubnets\":[]}";
        var r = SettingsDocument.Deserialize(json, Id);
        Assert.Equal("Ubuntu-24.04", r.Settings.Distro);
        Assert.Empty(r.Warnings);
    }

    [Fact]
    public void Distro_RoundTrips()
    {
        var s = StoredSettings.Empty with { Username = "u", Distro = "SplitSwan" };
        var json = SettingsDocument.Serialize(s, Id);
        Assert.Contains("\"distro\": \"SplitSwan\"", json);
        Assert.Equal("SplitSwan", SettingsDocument.Deserialize(json, Id).Settings.Distro);
        var legacy = SettingsDocument.Deserialize(SettingsDocument.Serialize(s with { Distro = "Ubuntu-24.04" }, Id), Id);
        Assert.Equal("Ubuntu-24.04", legacy.Settings.Distro);
    }

    [Fact]
    public void InvalidDistro_FallsBackToLegacy_WithWarning()
    {
        var json = "{\"version\":1,\"distro\":\"bad name;rm\"}";
        var r = SettingsDocument.Deserialize(json, Id);
        Assert.Equal("Ubuntu-24.04", r.Settings.Distro);
        Assert.Single(r.Warnings);
    }

    [Fact]
    public void SettingsFormSave_KeepsLatestDistro()
    {
        // 設定表單 Collect() 建新物件時 Distro 是預設值；儲存時要沿用托盤當下的（舊版使用者是 Ubuntu-24.04）
        var collected = StoredSettings.Empty with { Username = "new" };
        var latest = StoredSettings.Empty with { Distro = "Ubuntu-24.04" };
        var merged = DisplaySettings.MergeForSave(collected, latest);
        Assert.Equal("Ubuntu-24.04", merged.Distro);
        Assert.Equal("new", merged.Username);
    }
}

public class EngineSetupCommandTests
{
    [Fact]
    public void Setup_ActionNameAndTimeout()
    {
        Assert.Equal("setup", EngineCommand.ActionName(EngineAction.Setup));
        Assert.Equal(TimeSpan.FromMinutes(20), EngineCommand.Timeout(EngineAction.Setup));
    }

    [Fact]
    public void Setup_WithDistro_Arguments()
    {
        var args = EngineCommand.Arguments(EngineAction.Setup, @"C:\a\splitswan-wsl.ps1", @"C:\d\conf", distro: "SplitSwan");
        Assert.Equal(
            ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", @"C:\a\splitswan-wsl.ps1",
             "-Action", "setup", "-ConfDir", @"C:\d\conf", "-Distro", "SplitSwan"], args);
    }

    [Theory]
    [InlineData(EngineAction.Connect)]
    [InlineData(EngineAction.Disconnect)]
    [InlineData(EngineAction.Brief)]
    [InlineData(EngineAction.Status)]
    public void AllActions_CarryDistro(EngineAction a)
    {
        var args = EngineCommand.Arguments(a, "s.ps1", @"C:\d", distro: "Ubuntu-24.04").ToList();
        var i = args.IndexOf("-Distro");
        Assert.True(i > 0);
        Assert.Equal("Ubuntu-24.04", args[i + 1]);
    }

    [Fact]
    public void NoDistro_NotAdded() =>
        Assert.DoesNotContain("-Distro", EngineCommand.Arguments(EngineAction.Brief, "s.ps1", @"C:\d"));

    [Theory]
    [InlineData("a b")]
    [InlineData("x\"y")]
    [InlineData("")]
    public void InvalidDistro_Throws(string d) =>
        Assert.Throws<ArgumentException>(() => EngineCommand.Arguments(EngineAction.Setup, "s.ps1", @"C:\d", distro: d));
}

public class RunOnceCommandTests
{
    [Fact]
    public void Build_QuotesPathAndAddsWizardArgument() =>
        Assert.Equal("\"C:\\Program Files\\SplitSwan\\SplitSwan.exe\" --wizard",
            RunOnceCommand.Build(@"C:\Program Files\SplitSwan\SplitSwan.exe"));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("C:\\a\"b.exe")]
    public void Build_RejectsBadPaths(string? p) => Assert.Null(RunOnceCommand.Build(p));

    [Fact]
    public void Build_RejectsOver260Characters()
    {
        var ok = "C:\\" + new string('a', 260 - 3 - 2 - 9) ;   // 引號 2 個、" --wizard" 9 個
        Assert.NotNull(RunOnceCommand.Build(ok));
        Assert.Equal(260, RunOnceCommand.Build(ok)!.Length);
        Assert.Null(RunOnceCommand.Build(ok + "a"));
    }

    [Fact]
    public void WantsWizard_CaseInsensitive()
    {
        Assert.True(RunOnceCommand.WantsWizard(["--WIZARD"]));
        Assert.False(RunOnceCommand.WantsWizard([]));
        Assert.False(RunOnceCommand.WantsWizard(null));
    }
}

public class SetupWizardReviewFixTests
{
    private static readonly Func<byte[], byte[]> Id = b => b;

    [Theory]
    [InlineData("{壞掉")]
    [InlineData("{\"version\":2}")]
    public void ExistingButUnreadableSettings_KeepLegacyDistro(string json) =>
        // settings.json 存在就是舊版使用者：讀不懂時也不能把發行版換成 SplitSwan（否則會重新下載匯入）
        Assert.Equal("Ubuntu-24.04", SettingsDocument.Deserialize(json, Id).Settings.Distro);

    [Fact]
    public void EnabledButServicesMissing_ReadyAfterReboot()
    {
        var p = new WslProbe(true, "Enabled", "Enabled", false, true, null, null);
        Assert.Equal(WslReadiness.NeedReboot, WslInstallState.Evaluate(p, 22631));
        Assert.Equal(WslReadiness.Ready, WslInstallState.Evaluate(p, 22631, rebootedSinceInstall: true));
    }
}

public class Review3FixTests
{
    private static readonly Func<byte[], byte[]> Id = b => b;

    [Fact]
    public void Decide_NullList_IsQueryFailed_NeverDownload()
    {
        Assert.Equal(DistroAction.QueryFailed, DistroPlan.Decide("Ubuntu-24.04", null, false));
        Assert.Equal(DistroAction.QueryFailed, DistroPlan.Decide("SplitSwan", null, true));
    }

    [Fact]
    public void ResolveInstalled_WslOk_UsesWslList() =>
        Assert.Equal(["Ubuntu-24.04"], DistroPlan.ResolveInstalled(true, ["Ubuntu-24.04"], null)!);

    [Fact]
    public void ResolveInstalled_WslFailed_RegistryEmpty_IsEmptyList()
    {
        var r = DistroPlan.ResolveInstalled(false, [], []);
        Assert.NotNull(r);
        Assert.Empty(r);
        Assert.Equal(DistroAction.DownloadAndImport, DistroPlan.Decide("SplitSwan", r, false));
    }

    [Fact]
    public void ResolveInstalled_WslFailed_RegistryHasDistros_IsFailure()
    {
        // 舊版使用者的 WSL 暫時異常：不可以因此下載並改用 SplitSwan（review3 中）
        var r = DistroPlan.ResolveInstalled(false, [], ["Ubuntu-24.04"]);
        Assert.Null(r);
        Assert.Equal(DistroAction.QueryFailed, DistroPlan.Decide("Ubuntu-24.04", r, false));
    }

    [Fact]
    public void ResolveInstalled_WslFailed_RegistryUnreadable_IsFailure() =>
        Assert.Equal(DistroAction.QueryFailed, DistroPlan.Decide("Ubuntu-24.04", DistroPlan.ResolveInstalled(false, [], null), false));

    [Theory]
    [InlineData(false, false, true)]
    [InlineData(true, false, false)]
    [InlineData(false, true, false)]
    [InlineData(true, true, false)]
    public void CanSwitchDistro_OnlyWhenDisconnected(bool up, bool want, bool expected) =>
        Assert.Equal(expected, DistroPlan.CanSwitchDistro(up, want));

    [Fact]
    public void LegacyCoexistNote_OnlyWhenCreatingSplitSwanBesideUbuntu()
    {
        Assert.Contains("不會被修改或刪除", DistroPlan.LegacyCoexistNote("SplitSwan", ["Ubuntu-24.04"], DistroAction.DownloadAndImport));
        Assert.NotNull(DistroPlan.LegacyCoexistNote("SplitSwan", ["Ubuntu-24.04"], DistroAction.ImportInPlace));
        Assert.Null(DistroPlan.LegacyCoexistNote("SplitSwan", [], DistroAction.DownloadAndImport));
        Assert.Null(DistroPlan.LegacyCoexistNote("Ubuntu-24.04", ["Ubuntu-24.04"], DistroAction.UseConfigured));
    }

    [Theory]
    [InlineData("-x")]
    [InlineData("--install")]
    [InlineData("a b")]
    [InlineData("SplitSwan\n")]
    [InlineData("x\"y")]
    public void SettingsDistro_Invalid_FallsBackToLegacy_WithWarning(string bad)
    {
        var json = SettingsDocument.Serialize(StoredSettings.Empty with { Distro = bad }, Id);
        var r = SettingsDocument.Deserialize(json, Id);
        Assert.Equal("Ubuntu-24.04", r.Settings.Distro);
        Assert.Contains(r.Warnings, w => w.Contains("發行版名稱不正確"));
    }

    [Fact]
    public void SettingsDistro_DotPrefix_RejectedLikeEngine()
    {
        // 引擎 Test-DistroName 要求首字為英數；App 端同規則，不合法退回 Ubuntu-24.04
        var json = SettingsDocument.Serialize(StoredSettings.Empty with { Distro = ".mine" }, Id);
        Assert.Equal(WslDistros.Legacy, SettingsDocument.Deserialize(json, Id).Settings.Distro);
    }

    [Fact]
    public void EngineArguments_RejectLeadingDash() =>
        Assert.Throws<ArgumentException>(() => EngineCommand.Arguments(EngineAction.Brief, "s.ps1", @"C:\d", distro: "--install"));
}
