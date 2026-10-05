using System.IO.Compression;
using System.Text;

namespace SplitSwan.Core.Tests;

/// <summary>一鍵更新的檔案操作：zip slip、內容檢查、在暫存資料夾裡用假檔案實際跑「改名→移入→失敗還原」與清除 *.old。</summary>
public sealed class UpdatePackageTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "splitswan-update-test-" + Guid.NewGuid().ToString("N"));

    public UpdatePackageTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static MemoryStream Zip(params (string Name, string Content)[] entries)
    {
        var ms = new MemoryStream();
        using (var z = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var (name, content) in entries)
            {
                var e = z.CreateEntry(name);
                if (name.EndsWith('/')) continue;
                using var w = new StreamWriter(e.Open(), new UTF8Encoding(false));
                w.Write(content);
            }
        }
        ms.Position = 0;
        return ms;
    }

    private static (string, string)[] GoodPackage(string tag = "new") =>
    [
        ("SplitSwan/", ""),
        ("SplitSwan/SplitSwan.exe", "exe-" + tag),
        ("SplitSwan/README.md", "readme-" + tag),
        ("SplitSwan/engine/", ""),
        ("SplitSwan/engine/splitswan-wsl.ps1", "ps1-" + tag),
        ("SplitSwan/engine/splitswan-wsl.sh", "sh-" + tag),
    ];

    private string Read(params string[] parts) => File.ReadAllText(Path.Combine([_dir, .. parts]));

    // MARK: zip slip

    [Theory]
    [InlineData("SplitSwan/SplitSwan.exe", true)]
    [InlineData("SplitSwan/engine/a.sh", true)]
    [InlineData("SplitSwan/./engine/a.sh", true)]
    [InlineData("../evil.exe", false)]
    [InlineData("SplitSwan/../../evil.exe", false)]
    [InlineData("SplitSwan/engine/../../../evil", false)]
    [InlineData("/etc/passwd", false)]
    [InlineData("\\Windows\\evil.exe", false)]
    [InlineData("C:/Windows/evil.exe", false)]
    [InlineData("C:evil.exe", false)]
    [InlineData("", false)]
    [InlineData(".", false)]
    public void ZipSlipCheck(string entry, bool inside) =>
        Assert.Equal(inside, UpdatePackage.IsInsideDirectory(Path.Combine(_dir, "x"), entry));

    [Fact]
    public void ZipSlipRejectsSiblingWithSamePrefix()
    {
        // 目標 .../x，entry 解到 .../xy/evil：字串前綴相同但不在資料夾內
        Assert.False(UpdatePackage.IsInsideDirectory(Path.Combine(_dir, "x"), "../xy/evil"));
    }

    [Fact]
    public void ExtractRejectsWholeArchiveWhenAnyEntryEscapes()
    {
        var dest = Path.Combine(_dir, "stage");
        using var zip = Zip([.. GoodPackage(), ("SplitSwan/../../escaped.txt", "x")]);
        var ex = Assert.Throws<UpdateException>(() => UpdatePackage.Extract(zip, dest));
        Assert.Contains("不允許的路徑", ex.Message);
        Assert.False(File.Exists(Path.Combine(_dir, "escaped.txt")));
        Assert.False(File.Exists(Path.Combine(dest, "SplitSwan", "SplitSwan.exe")));   // 先檢查再解：不會解出半包
    }

    [Fact]
    public void ExtractRejectsNonZip()
    {
        using var ms = new MemoryStream(Encoding.UTF8.GetBytes("not a zip"));
        Assert.Throws<UpdateException>(() => UpdatePackage.Extract(ms, Path.Combine(_dir, "stage")));
    }

    [Fact]
    public void ExtractGoodPackageAndCheckLayout()
    {
        var dest = Path.Combine(_dir, "stage");
        using var zip = Zip(GoodPackage());
        var files = UpdatePackage.Extract(zip, dest);
        Assert.Equal(["SplitSwan/SplitSwan.exe", "SplitSwan/README.md", "SplitSwan/engine/splitswan-wsl.ps1", "SplitSwan/engine/splitswan-wsl.sh"], files);
        Assert.Null(UpdatePackage.CheckLayout([.. files]));
        Assert.Equal("exe-new", File.ReadAllText(Path.Combine(dest, "SplitSwan", "SplitSwan.exe")));
        Assert.Equal(["SplitSwan.exe", "README.md", "engine/splitswan-wsl.ps1", "engine/splitswan-wsl.sh"], UpdatePackage.InstallItems(files));
    }

    // MARK: 內容檢查

    [Fact]
    public void LayoutMissingExeOrEngine()
    {
        Assert.Contains("SplitSwan/SplitSwan.exe", UpdatePackage.CheckLayout(["SplitSwan/engine/splitswan-wsl.ps1", "SplitSwan/engine/splitswan-wsl.sh"]));
        Assert.Contains("engine", UpdatePackage.CheckLayout(["SplitSwan/SplitSwan.exe", "SplitSwan/README.md"]));
        Assert.Contains("splitswan-wsl.sh", UpdatePackage.CheckLayout(["SplitSwan/SplitSwan.exe", "SplitSwan/engine/splitswan-wsl.ps1"]));
        Assert.NotNull(UpdatePackage.CheckLayout([]));
    }

    [Fact]
    public void LayoutRejectsFilesOutsideRoot()
    {
        Assert.Contains("不在", UpdatePackage.CheckLayout(
            ["SplitSwan/SplitSwan.exe", "SplitSwan/engine/splitswan-wsl.ps1", "SplitSwan/engine/splitswan-wsl.sh", "Other/x.exe"]));
        Assert.Contains("不在", UpdatePackage.CheckLayout(["SplitSwan.exe"]));
    }

    // MARK: 替換

    /// <summary>安裝資料夾（舊版）與解壓後的新版各一份。回傳 (安裝資料夾, 新版 SplitSwan 資料夾, 項目)。</summary>
    private (string Install, string Staged, IReadOnlyList<string> Items) Setup()
    {
        var install = Path.Combine(_dir, "install");
        Directory.CreateDirectory(Path.Combine(install, "engine"));
        File.WriteAllText(Path.Combine(install, "SplitSwan.exe"), "exe-old");
        File.WriteAllText(Path.Combine(install, "README.md"), "readme-old");
        File.WriteAllText(Path.Combine(install, "engine", "splitswan-wsl.ps1"), "ps1-old");
        File.WriteAllText(Path.Combine(install, "engine", "splitswan-wsl.sh"), "sh-old");
        File.WriteAllText(Path.Combine(install, "engine", "user-note.txt"), "keep");   // 不在新版清單裡的檔案：不動
        var stage = Path.Combine(_dir, "stage");
        using var zip = Zip(GoodPackage());
        var files = UpdatePackage.Extract(zip, stage);
        return (install, Path.Combine(stage, "SplitSwan"), UpdatePackage.InstallItems(files));
    }

    [Fact]
    public void SwapReplacesFilesAndKeepsOldCopies()
    {
        var (install, staged, items) = Setup();
        var rec = UpdatePackage.Swap(install, staged, items);
        Assert.Equal(items, rec.Replaced);
        Assert.Equal("exe-new", Read("install", "SplitSwan.exe"));
        Assert.Equal("exe-old", Read("install", "SplitSwan.exe.old"));
        Assert.Equal("ps1-new", Read("install", "engine", "splitswan-wsl.ps1"));
        Assert.Equal("sh-old", Read("install", "engine", "splitswan-wsl.sh.old"));
        Assert.Equal("keep", Read("install", "engine", "user-note.txt"));
        Assert.Empty(Directory.EnumerateFiles(install, "*.new", SearchOption.AllDirectories));
    }

    [Fact]
    public void SwapFailureMidwayRestoresEverything()
    {
        var (install, staged, items) = Setup();
        // 第三個項目（engine/splitswan-wsl.ps1）換進去時失敗：前兩個已換好的也要還原
        var ex = Assert.Throws<UpdateException>(() => UpdatePackage.Swap(install, staged, items,
            rel => { if (rel == "engine/splitswan-wsl.ps1") throw new IOException("模擬：檔案被占用"); }));
        Assert.Contains("已還原", ex.Message);
        Assert.Equal("exe-old", Read("install", "SplitSwan.exe"));
        Assert.Equal("readme-old", Read("install", "README.md"));
        Assert.Equal("ps1-old", Read("install", "engine", "splitswan-wsl.ps1"));
        Assert.Equal("sh-old", Read("install", "engine", "splitswan-wsl.sh"));
        Assert.Empty(Directory.EnumerateFiles(install, "*.old", SearchOption.AllDirectories));
        Assert.Empty(Directory.EnumerateFiles(install, "*.new", SearchOption.AllDirectories));
    }

    [Fact]
    public void SwapFailureOnFirstItemRestores()
    {
        var (install, staged, items) = Setup();
        Assert.Throws<UpdateException>(() => UpdatePackage.Swap(install, staged, items, _ => throw new UnauthorizedAccessException("模擬：沒有權限")));
        Assert.Equal("exe-old", Read("install", "SplitSwan.exe"));
        Assert.Empty(Directory.EnumerateFiles(install, "*.old", SearchOption.AllDirectories));
    }

    [Fact]
    public void SwapFailsCleanlyWhenStagedFileMissing()
    {
        var (install, staged, items) = Setup();
        File.Delete(Path.Combine(staged, "engine", "splitswan-wsl.sh"));
        Assert.Throws<UpdateException>(() => UpdatePackage.Swap(install, staged, items));
        Assert.Equal("exe-old", Read("install", "SplitSwan.exe"));
        Assert.Empty(Directory.EnumerateFiles(install, "*.new", SearchOption.AllDirectories));
    }

    [Fact]
    public void SwapReplacesStaleOldFromPreviousUpdate()
    {
        var (install, staged, items) = Setup();
        File.WriteAllText(Path.Combine(install, "SplitSwan.exe.old"), "exe-older");
        UpdatePackage.Swap(install, staged, items);
        Assert.Equal("exe-new", Read("install", "SplitSwan.exe"));
        Assert.Equal("exe-old", Read("install", "SplitSwan.exe.old"));
    }

    [Fact]
    public void SwapAddsNewFileThatDidNotExistAndRevertRemovesIt()
    {
        var (install, staged, items) = Setup();
        File.Delete(Path.Combine(install, "README.md"));
        var rec = UpdatePackage.Swap(install, staged, items);
        Assert.Equal("readme-new", Read("install", "README.md"));
        // 新版啟動失敗時的還原
        Assert.Empty(UpdatePackage.Revert(rec));
        Assert.False(File.Exists(Path.Combine(install, "README.md")));
        Assert.Equal("exe-old", Read("install", "SplitSwan.exe"));
        Assert.Equal("ps1-old", Read("install", "engine", "splitswan-wsl.ps1"));
        Assert.Empty(Directory.EnumerateFiles(install, "*.old", SearchOption.AllDirectories));
        Assert.Empty(Directory.EnumerateFiles(install, "*.new", SearchOption.AllDirectories));
    }

    // MARK: 清除遺留

    [Fact]
    public void CleanupRemovesOldAndNewLeftoversOnly()
    {
        var (install, staged, items) = Setup();
        UpdatePackage.Swap(install, staged, items);
        File.WriteAllText(Path.Combine(install, "engine", "splitswan-wsl.sh.new"), "half");
        Directory.CreateDirectory(Path.Combine(install, "deeper"));
        File.WriteAllText(Path.Combine(install, "deeper", "x.old"), "not ours");   // 不遞迴
        var (removed, failed) = UpdatePackage.CleanupLeftovers(install);
        Assert.Empty(failed);
        Assert.Equal(5, removed.Count);   // 4 個 .old ＋ 1 個 .new
        Assert.Empty(Directory.EnumerateFiles(install, "*.new"));
        Assert.Empty(Directory.EnumerateFiles(Path.Combine(install, "engine"), "*.old"));
        Assert.Equal("exe-new", Read("install", "SplitSwan.exe"));
        Assert.Equal("keep", Read("install", "engine", "user-note.txt"));
        Assert.True(File.Exists(Path.Combine(install, "deeper", "x.old")));
        // 沒有遺留時不做事
        Assert.Empty(UpdatePackage.CleanupLeftovers(install).Removed);
        Assert.Empty(UpdatePackage.CleanupLeftovers(Path.Combine(_dir, "missing")).Removed);
    }
}
