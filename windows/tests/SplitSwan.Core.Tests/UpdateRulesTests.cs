using System.Text;

namespace SplitSwan.Core.Tests;

/// <summary>一鍵更新的純邏輯：release 列表解析、Ed25519 簽章、版本比較與防降級、每日檢查時機（對應 Mac 版 Tests/UpdateTests.swift）。</summary>
public class UpdateRulesTests
{
    private const string Dl = "https://github.com/mark22013333/SplitSwan/releases/download/";

    private static string Asset(string name, string? url = null) =>
        $$"""{"name":"{{name}}","browser_download_url":"{{url ?? Dl + "windows-v0/" + name}}"}""";

    private static string Release(string tag, bool draft = false, bool prerelease = true, params string[] assets) =>
        $$"""{"tag_name":"{{tag}}","draft":{{(draft ? "true" : "false")}},"prerelease":{{(prerelease ? "true" : "false")}},"assets":[{{string.Join(",", assets)}}]}""";

    private static string WinRelease(string version, bool draft = false) =>
        Release("windows-v" + version, draft, true,
            Asset($"SplitSwan-Windows-{version}.zip", $"{Dl}windows-v{version}/SplitSwan-Windows-{version}.zip"),
            Asset($"SplitSwan-Windows-{version}.zip.sha256", $"{Dl}windows-v{version}/SplitSwan-Windows-{version}.zip.sha256"),
            Asset($"SplitSwan-Windows-{version}.zip.sig", $"{Dl}windows-v{version}/SplitSwan-Windows-{version}.zip.sig"));

    private static string List(params string[] releases) => "[" + string.Join(",", releases) + "]";

    // MARK: release 列表

    [Fact]
    public void PicksHighestWindowsReleaseIgnoringMacTagsAndDrafts()
    {
        var json = List(
            Release("v9.9.9", prerelease: false, assets: Asset("SplitSwan-9.9.9.dmg", Dl + "v9.9.9/SplitSwan-9.9.9.dmg")),   // Mac 版：忽略
            WinRelease("0.1.10"),
            WinRelease("0.3.0", draft: true),          // draft：忽略
            WinRelease("0.2.1"),
            WinRelease("0.2.0"),
            Release("windows-test", assets: []));      // 不是版本號的 tag：忽略
        var r = UpdateRules.PickLatest(json);
        Assert.NotNull(r);
        Assert.Equal("0.2.1", r.Version);
        Assert.NotNull(r.Assets);
        Assert.Equal($"{Dl}windows-v0.2.1/SplitSwan-Windows-0.2.1.zip", r.Assets.Zip.ToString());
        Assert.Equal($"{Dl}windows-v0.2.1/SplitSwan-Windows-0.2.1.zip.sig", r.Assets.Sig.ToString());
        Assert.Equal("https://github.com/mark22013333/SplitSwan/releases/tag/windows-v0.2.1", r.PageUrl);
    }

    [Fact]
    public void ComparesVersionsNumericallyNotAlphabetically()
    {
        var r = UpdateRules.PickLatest(List(WinRelease("0.1.9"), WinRelease("0.1.10"), WinRelease("0.1.2")));
        Assert.Equal("0.1.10", r!.Version);
    }

    [Fact]
    public void PrereleaseAndNonPrereleaseBothAccepted()
    {
        var json = List(Release("windows-v0.4.0", prerelease: false,
            assets: [Asset("SplitSwan-Windows-0.4.0.zip", Dl + "windows-v0.4.0/SplitSwan-Windows-0.4.0.zip"),
                     Asset("SplitSwan-Windows-0.4.0.zip.sig", Dl + "windows-v0.4.0/SplitSwan-Windows-0.4.0.zip.sig")]),
            WinRelease("0.3.0"));
        Assert.Equal("0.4.0", UpdateRules.PickLatest(json)!.Version);
        Assert.NotNull(UpdateRules.PickLatest(json)!.Assets);
    }

    [Fact]
    public void NoWindowsReleaseOrBadJsonReturnsNull()
    {
        Assert.Null(UpdateRules.PickLatest(List(Release("v1.7.0", prerelease: false))));
        Assert.Null(UpdateRules.PickLatest("[]"));
        Assert.Null(UpdateRules.PickLatest("{\"tag_name\":\"windows-v1.0.0\"}"));   // /releases/latest 的單一物件格式不是列表
        Assert.Null(UpdateRules.PickLatest("not json"));
        Assert.Null(UpdateRules.PickLatest(List(WinRelease("1.0.0", draft: true))));
    }

    [Fact]
    public void HighestReleaseWithoutSigHasNoAssetsAndDoesNotFallBack()
    {
        var json = List(
            Release("windows-v0.5.0", assets: Asset("SplitSwan-Windows-0.5.0.zip", Dl + "windows-v0.5.0/SplitSwan-Windows-0.5.0.zip")),
            WinRelease("0.4.0"));
        var r = UpdateRules.PickLatest(json);
        Assert.Equal("0.5.0", r!.Version);   // 仍回報有新版本（可前往下載）
        Assert.Null(r.Assets);              // 但不能自動安裝，也不退回裝 0.4.0
    }

    [Theory]
    [InlineData("https://example.com/mark22013333/SplitSwan/releases/download/windows-v0.5.0/SplitSwan-Windows-0.5.0.zip")]
    [InlineData("https://github.com/someone/SplitSwan/releases/download/windows-v0.5.0/SplitSwan-Windows-0.5.0.zip")]
    [InlineData("https://github.com/mark22013333/SplitSwan/releases/download/../../evil/SplitSwan-Windows-0.5.0.zip")]
    [InlineData("http://github.com/mark22013333/SplitSwan/releases/download/windows-v0.5.0/SplitSwan-Windows-0.5.0.zip")]
    [InlineData("https://github.com/mark22013333/SplitSwan/releases/download/windows-v0.5.0/other.zip")]
    [InlineData("https://github.com/mark22013333/SplitSwan/releases/download/windows-v0.5.0/SplitSwan-Windows-0.5.0.zip?x=1")]
    public void RejectsZipUrlOutsideRepoDownloads(string zipUrl)
    {
        var json = List(Release("windows-v0.5.0",
            assets: [Asset("SplitSwan-Windows-0.5.0.zip", zipUrl),
                     Asset("SplitSwan-Windows-0.5.0.zip.sig", Dl + "windows-v0.5.0/SplitSwan-Windows-0.5.0.zip.sig")]));
        var r = UpdateRules.PickLatest(json);
        Assert.Equal("0.5.0", r!.Version);
        Assert.Null(r.Assets);
    }

    [Fact]
    public void AssetFileNameVersionMustEqualTagVersion()
    {
        // tag 是 0.5.0，附檔是 0.4.0 的（例如上傳錯檔）：不採用
        var json = List(Release("windows-v0.5.0",
            assets: [Asset("SplitSwan-Windows-0.4.0.zip", Dl + "windows-v0.5.0/SplitSwan-Windows-0.4.0.zip"),
                     Asset("SplitSwan-Windows-0.4.0.zip.sig", Dl + "windows-v0.5.0/SplitSwan-Windows-0.4.0.zip.sig")]));
        Assert.Null(UpdateRules.PickLatest(json)!.Assets);
    }

    [Theory]
    [InlineData("windows-v1.2.3", "1.2.3")]
    [InlineData("windows-v01.2.3", null)]
    [InlineData("v1.2.3", null)]
    [InlineData("windows-1.2.3", null)]
    [InlineData("windows-v1.2", null)]
    [InlineData("windows-v1.2.3.0", null)]
    [InlineData("windows-v1.2.3-beta", null)]
    [InlineData("windows-v１.2.3", null)]   // 全形數字
    [InlineData("windows-v1.2.3+abc", null)]
    public void VersionFromTag(string tag, string? expected) => Assert.Equal(expected, UpdateRules.VersionFromTag(tag));

    // MARK: 簽章

    private static byte[] Hex(string h) => Convert.FromHexString(h);

    [Fact]
    public void Rfc8032Test1EmptyMessage()
    {
        var pub = Convert.ToBase64String(Hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"));
        var sig = Convert.ToBase64String(Hex(
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"));
        Assert.True(UpdateRules.VerifySignature([], sig, pub));
        Assert.False(UpdateRules.VerifySignature([0x00], sig, pub));
    }

    [Fact]
    public void Rfc8032Test2OneByte()
    {
        var pub = Convert.ToBase64String(Hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"));
        var sig = Convert.ToBase64String(Hex(
            "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"));
        Assert.True(UpdateRules.VerifySignature([0x72], sig, pub));
        Assert.False(UpdateRules.VerifySignature([0x73], sig, pub));
    }

    // CryptoKit（Mac 版用來簽發版檔的同一套）產生的跨平台向量；一次性測試金鑰，不是發版金鑰
    private const string CkPub = "8XaRMEosLPYaSsA/Ok+DNgCNMUtmbvRW+lFvUuIz5W0=";
    private const string CkMsg = "U3BsaXRTd2FuIGNyb3NzLXBsYXRmb3JtIHRlc3QgdmVjdG9yCg==";
    private const string CkSig = "cm/QisytjyI/eiuWtsK/yj2DEYQLFUbYxEelFQGKh7tzCkJyMo0ruj/LSCx4bOWsz2+numOiE5uEB1/Sb49iBA==";

    [Fact]
    public void CryptoKitCrossPlatformVector()
    {
        var msg = Convert.FromBase64String(CkMsg);
        Assert.Equal("SplitSwan cross-platform test vector\n", Encoding.UTF8.GetString(msg));
        Assert.True(UpdateRules.VerifySignature(msg, CkSig, CkPub));
        // .sig 檔的格式是一行 base64 加換行：前後空白要能容忍
        Assert.True(UpdateRules.VerifySignature(msg, CkSig + "\n", CkPub));
        Assert.True(UpdateRules.VerifySignature(msg, "  " + CkSig + "\r\n", CkPub));
    }

    [Fact]
    public void TamperedContentFails()
    {
        var msg = Convert.FromBase64String(CkMsg);
        for (int i = 0; i < msg.Length; i += 7)
        {
            var m = (byte[])msg.Clone();
            m[i] ^= 0x01;
            Assert.False(UpdateRules.VerifySignature(m, CkSig, CkPub));
        }
        Assert.False(UpdateRules.VerifySignature([.. msg, 0x00], CkSig, CkPub));   // 多一個 byte
        Assert.False(UpdateRules.VerifySignature(msg[..^1], CkSig, CkPub));       // 少一個 byte
    }

    [Fact]
    public void TamperedSignatureFails()
    {
        var msg = Convert.FromBase64String(CkMsg);
        var sig = Convert.FromBase64String(CkSig);
        foreach (var i in new[] { 0, 1, 31, 32, 33, 63 })
        {
            var s = (byte[])sig.Clone();
            s[i] ^= 0x80;
            Assert.False(UpdateRules.VerifySignature(msg, Convert.ToBase64String(s), CkPub));
        }
        // S 加上群階 L（非正規化的 S，簽章可塑性）必須拒絕
        var l = Hex("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010");
        var mall = (byte[])sig.Clone();
        var carry = 0;
        for (int i = 0; i < 32; i++)
        {
            var sum = mall[32 + i] + l[i] + carry;
            mall[32 + i] = (byte)sum;
            carry = sum >> 8;
        }
        Assert.False(UpdateRules.VerifySignature(msg, Convert.ToBase64String(mall), CkPub));
        Assert.False(UpdateRules.VerifySignature(msg, "", CkPub));
        Assert.False(UpdateRules.VerifySignature(msg, "不是 base64", CkPub));
        Assert.False(UpdateRules.VerifySignature(msg, Convert.ToBase64String(sig[..63]), CkPub));
    }

    [Fact]
    public void WrongPublicKeyFails()
    {
        var msg = Convert.FromBase64String(CkMsg);
        Assert.False(UpdateRules.VerifySignature(msg, CkSig));   // 發版公鑰
        Assert.False(UpdateRules.VerifySignature(msg, CkSig, Convert.ToBase64String(Hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))));
        Assert.False(UpdateRules.VerifySignature(msg, CkSig, Convert.ToBase64String(new byte[31])));
        Assert.False(UpdateRules.VerifySignature(msg, CkSig, "不是 base64"));
    }

    [Fact]
    public void ReleasePublicKeyIsTheSharedMacKey()
    {
        Assert.Equal("URYq9rg4ntHqiWV0ZhSd6dMm1uLrL5fZ/J76pnX048g=", UpdateRules.PublicKeyBase64);
        Assert.Equal(32, Convert.FromBase64String(UpdateRules.PublicKeyBase64).Length);
    }

    // MARK: 版本比較與防降級

    [Theory]
    [InlineData("0.1.1", "0.1.1")]
    [InlineData("0.1.1.0", "0.1.1")]
    [InlineData("0.1.1+abcdef", "0.1.1")]
    [InlineData("0.1.1.1", null)]
    [InlineData("0.1", null)]
    [InlineData("0.1.x", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void NormalizeVersion(string? input, string? expected) => Assert.Equal(expected, UpdateRules.NormalizeVersion(input));

    [Fact]
    public void IsNewer()
    {
        Assert.True(UpdateRules.IsNewer("0.1.2", "0.1.1"));
        Assert.True(UpdateRules.IsNewer("0.10.0", "0.9.9"));
        Assert.False(UpdateRules.IsNewer("0.1.1", "0.1.1"));
        Assert.False(UpdateRules.IsNewer("0.1.0", "0.1.1"));
        Assert.False(UpdateRules.IsNewer("abc", "0.1.1"));
    }

    [Fact]
    public void ExeVersionChecks()
    {
        Assert.Null(UpdateRules.ValidateExeVersion("0.1.2.0", "0.1.2+3f2a", "0.1.2", "0.1.1"));
        Assert.Null(UpdateRules.ValidateExeVersion("0.1.2", "0.1.2", "0.1.2", "0.1.1"));
        // zip 裡的 exe 與 release 版本不符（例如把舊版的已簽 zip 重新上傳成新 tag）
        Assert.Contains("不符", UpdateRules.ValidateExeVersion("0.1.1.0", "0.1.1", "0.1.2", "0.1.1"));
        Assert.Contains("不符", UpdateRules.ValidateExeVersion("0.1.2.0", "0.1.3", "0.1.2", "0.1.1"));
        // 降級／重放：release 版本沒有比目前新
        Assert.Contains("沒有比目前", UpdateRules.ValidateExeVersion("0.1.1.0", "0.1.1", "0.1.1", "0.1.1"));
        Assert.Contains("沒有比目前", UpdateRules.ValidateExeVersion("0.1.0.0", "0.1.0", "0.1.0", "0.1.1"));
        // 讀不到版本
        Assert.NotNull(UpdateRules.ValidateExeVersion(null, "0.1.2", "0.1.2", "0.1.1"));
        Assert.NotNull(UpdateRules.ValidateExeVersion("0.1.2.0", "", "0.1.2", "0.1.1"));
        Assert.NotNull(UpdateRules.ValidateExeVersion("0.1.2.0", "0.1.2", "0.1.2", "unknown"));
    }

    // MARK: 設定檔與啟動參數

    private static byte[] Id(byte[] b) => b;

    [Fact]
    public void AutoCheckSettingDefaultsOffAndRoundTrips()
    {
        Assert.False(StoredSettings.Empty.AutoCheckUpdates);
        // 舊版 settings.json 沒有 autoCheckUpdates：關閉（預設不連網）
        var legacy = """{"version":1,"username":"u","gateways":["203.0.113.1","",""],"remoteSubnets":[],"autoReconnect":true}""";
        var r = SettingsDocument.Deserialize(legacy, Id);
        Assert.Empty(r.Warnings);
        Assert.False(r.Settings.AutoCheckUpdates);
        Assert.True(r.Settings.AutoReconnect);
        // 不是布林：關閉
        Assert.False(SettingsDocument.Deserialize(legacy.Replace("}", ",\"autoCheckUpdates\":\"yes\"}"), Id).Settings.AutoCheckUpdates);
        var on = StoredSettings.Empty with { AutoCheckUpdates = true };
        var json = SettingsDocument.Serialize(on, Id);
        Assert.Contains("\"autoCheckUpdates\": true", json);
        Assert.True(SettingsDocument.Deserialize(json, Id).Settings.AutoCheckUpdates);
    }

    [Fact]
    public void SaveButtonKeepsStoredAutoCheckValue()
    {
        // 表單（Collect）沒有這欄，按「儲存」時沿用已儲存的值，不會被重設成關閉
        var saved = StoredSettings.Empty with { AutoCheckUpdates = true };
        var collected = StoredSettings.Empty with { Username = "new" };
        var merged = DisplaySettings.MergeForSave(collected, saved);
        Assert.True(merged.AutoCheckUpdates);
        Assert.Equal("new", merged.Username);
    }

    [Fact]
    public void AfterUpdateArgument()
    {
        Assert.True(UpdateRules.IsAfterUpdate(["--after-update"]));
        Assert.True(UpdateRules.IsAfterUpdate(["--wizard", "--AFTER-UPDATE"]));
        Assert.False(UpdateRules.IsAfterUpdate(["--wizard"]));
        Assert.False(UpdateRules.IsAfterUpdate([]));
        Assert.False(UpdateRules.IsAfterUpdate(null));
        Assert.False(RunOnceCommand.WantsWizard(["--after-update"]));   // 不會誤開精靈
    }

    // MARK: 每日檢查時機

    [Fact]
    public void AutoCheckTiming()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
        Assert.False(UpdateRules.ShouldAutoCheck(false, null, now));                         // 沒勾選：絕不連網
        Assert.False(UpdateRules.ShouldAutoCheck(false, now.AddDays(-30), now));
        Assert.True(UpdateRules.ShouldAutoCheck(true, null, now));                           // 從沒檢查過
        Assert.False(UpdateRules.ShouldAutoCheck(true, now.AddHours(-23).AddMinutes(-59), now));
        Assert.True(UpdateRules.ShouldAutoCheck(true, now.AddHours(-24), now));              // 滿 24 小時
        Assert.True(UpdateRules.ShouldAutoCheck(true, now.AddDays(-3), now));
        Assert.True(UpdateRules.ShouldAutoCheck(true, now.AddMinutes(5), now));              // 時鐘被往回調
        Assert.False(UpdateRules.ShouldAutoCheck(true, now, now));
    }
}
