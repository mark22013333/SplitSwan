namespace SplitSwan.Core.Tests;

// 設定「更新」分頁頂端狀態卡（同 Mac 1.9.20「關於」頁）的色調、徽章與下一步

public class UpdateStatusTests
{
    private static UpdateStatus Build(bool installing = false, bool installFailed = false, bool checking = false,
        bool checkFailed = false, bool checkedOnce = false, bool hasRelease = false, string? newer = null) =>
        UpdateStatus.Build(installing, installFailed, checking, checkFailed, checkedOnce, hasRelease, newer);

    [Fact]
    public void NeverChecked_Neutral()
    {
        var s = Build();
        Assert.Equal((StatusTone.Idle, "尚未檢查"), (s.Tone, s.Badge));
        Assert.Contains("「檢查更新」", s.Summary);
    }

    [Fact]
    public void Checking_Working() => Assert.Equal((StatusTone.Working, "檢查中"), (Build(checking: true).Tone, Build(checking: true).Badge));

    [Fact]
    public void UpToDate_Ok()
    {
        var s = Build(checkedOnce: true, hasRelease: true);
        Assert.Equal((StatusTone.Ok, "最新版本"), (s.Tone, s.Badge));
    }

    [Fact]
    public void NoWindowsRelease_Neutral() =>
        Assert.Equal((StatusTone.Idle, "尚無發布"), (Build(checkedOnce: true).Tone, Build(checkedOnce: true).Badge));

    [Fact]
    public void Newer_WarnWithVersion()
    {
        var s = Build(checkedOnce: true, hasRelease: true, newer: "0.2.0");
        Assert.Equal((StatusTone.Warn, "有新版本 0.2.0"), (s.Tone, s.Badge));
    }

    [Fact]
    public void CheckFailed_Error()
    {
        var s = Build(checkFailed: true, checkedOnce: true);
        Assert.Equal((StatusTone.Bad, "檢查失敗"), (s.Tone, s.Badge));
    }

    [Fact]
    public void Install_TakesPriority()
    {
        Assert.Equal("安裝中", Build(installing: true, checkedOnce: true, hasRelease: true, newer: "0.2.0").Badge);
        Assert.Equal(StatusTone.Working, Build(installing: true).Tone);
        var failed = Build(installFailed: true, checkedOnce: true, hasRelease: true, newer: "0.2.0");
        Assert.Equal((StatusTone.Bad, "更新失敗"), (failed.Tone, failed.Badge));
        Assert.Contains("「前往下載」", failed.Summary);
    }

    [Fact]
    public void CheckingWinsOverPreviousResult() =>
        Assert.Equal("檢查中", Build(checking: true, checkFailed: true, checkedOnce: true, newer: "0.2.0").Badge);

    [Fact]
    public void EverySummaryIsOneLine()
    {
        foreach (var installing in new[] { false, true })
        foreach (var installFailed in new[] { false, true })
        foreach (var checking in new[] { false, true })
        foreach (var checkFailed in new[] { false, true })
        foreach (var checkedOnce in new[] { false, true })
        foreach (var newer in new[] { null, "0.2.0" })
        {
            var s = Build(installing, installFailed, checking, checkFailed, checkedOnce, true, newer);
            Assert.False(string.IsNullOrWhiteSpace(s.Summary));
            Assert.DoesNotContain('\n', s.Summary);
            Assert.False(string.IsNullOrWhiteSpace(s.Badge));
        }
    }
}

// 「檢查更新」卡片上「有新版本」那一列的項目（UpdatePanel 依此設定 Visible，不回頭讀子控制項）

public class UpdateActionsTests
{
    [Fact]
    public void NoNewerVersion_RowHidden()
    {
        var a = UpdateActions.For(null, hasAssets: false, installFailed: false);
        Assert.Equal(new UpdateActions(false, false, false), a);
        Assert.False(a.ShowRow);
    }

    [Fact]
    public void NewerWithAssets_ShowsTextInstallAndOpen()
    {
        var a = UpdateActions.For("9.9.9", hasAssets: true, installFailed: false);
        Assert.Equal(new UpdateActions(true, true, true), a);
        Assert.True(a.ShowRow);
    }

    [Fact]
    public void NewerWithoutAssets_NoInstallButtonButStillOpen()
    {
        var a = UpdateActions.For("9.9.9", hasAssets: false, installFailed: false);
        Assert.Equal(new UpdateActions(true, false, true), a);
        Assert.True(a.ShowRow);
    }

    [Fact]
    public void InstallFailedWithoutNewer_OnlyOpen()
    {
        var a = UpdateActions.For(null, hasAssets: false, installFailed: true);
        Assert.Equal(new UpdateActions(false, false, true), a);
        Assert.True(a.ShowRow);
    }

    [Fact]
    public void AssetsWithoutNewer_NeverShowInstall()
    {
        foreach (var failed in new[] { false, true })
            Assert.False(UpdateActions.For(null, hasAssets: true, installFailed: failed).ShowInstall);
    }

    [Theory]
    [InlineData(false, false, false, false)]
    [InlineData(true, false, false, true)]
    [InlineData(false, true, false, true)]
    [InlineData(false, false, true, true)]
    [InlineData(true, true, true, true)]
    public void ShowRow_IsAnyItem(bool newer, bool install, bool open, bool row) =>
        Assert.Equal(row, new UpdateActions(newer, install, open).ShowRow);

    [Fact]
    public void FromHiddenToNewer_RowBecomesVisible()
    {
        // 先前沒有新版本（整列隱藏），這次檢查找到新版：結果只取決於目前狀態，與先前顯示與否無關
        var before = UpdateActions.For(null, hasAssets: false, installFailed: false);
        var after = UpdateActions.For("9.9.9", hasAssets: true, installFailed: false);
        Assert.False(before.ShowRow);
        Assert.True(after.ShowRow && after.ShowInstall && after.ShowNewer);
    }
}
