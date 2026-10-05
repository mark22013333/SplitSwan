using System.IO.Compression;

namespace SplitSwan.Core;

/// <summary>更新過程中給使用者看的錯誤（訊息為繁中、一行）。</summary>
public sealed class UpdateException(string message) : Exception(message);

/// <summary>
/// 一鍵更新的檔案操作（不依賴 Windows API，測試可在 macOS 上用暫存資料夾實際跑）：
/// 解壓 zip（防 zip slip、限制總大小）、檢查內容、把新檔換進安裝資料夾（失敗就還原）、清掉上次留下的 *.old。
/// </summary>
public static class UpdatePackage
{
    /// <summary>zip 內的根資料夾；安裝資料夾裡對應的是 exe 所在資料夾本身。</summary>
    public const string Root = "SplitSwan";
    public const string ExeName = "SplitSwan.exe";
    public static readonly string[] RequiredFiles = [$"{Root}/{ExeName}", $"{Root}/engine/splitswan-wsl.ps1", $"{Root}/engine/splitswan-wsl.sh"];

    /// <summary>解壓後的總大小上限（防 zip bomb）。</summary>
    public const long MaxExtractedBytes = 400_000_000;
    public const int MaxEntries = 200;

    /// <summary>替換時舊檔改名的副檔名、新檔先複製進來時的副檔名。</summary>
    public const string OldSuffix = ".old";
    public const string NewSuffix = ".new";

    /// <summary>
    /// zip entry 解出來的完整路徑是否在目標資料夾內（防 zip slip）。絕對路徑、磁碟代號、「..」跳出去都回 false。
    /// </summary>
    public static bool IsInsideDirectory(string destination, string entryName)
    {
        if (string.IsNullOrEmpty(entryName) || entryName.Contains(':') || entryName.Contains('\0')) return false;
        if (entryName.StartsWith('/') || entryName.StartsWith('\\')) return false;
        var root = Path.GetFullPath(destination);
        if (!root.EndsWith(Path.DirectorySeparatorChar)) root += Path.DirectorySeparatorChar;
        var full = Path.GetFullPath(Path.Combine(root, entryName));
        return full.StartsWith(root, StringComparison.Ordinal) && full.Length > root.Length;
    }

    /// <summary>
    /// 把 zip 解到 destination（必須是空的新資料夾）。任何 entry 跳出資料夾、數量或總大小超過上限都丟 UpdateException，
    /// 不會寫出任何資料夾外的檔案。回傳解出的檔案相對路徑（以 / 分隔）。
    /// </summary>
    public static IReadOnlyList<string> Extract(Stream zip, string destination)
    {
        ArgumentNullException.ThrowIfNull(zip);
        Directory.CreateDirectory(destination);
        ZipArchive archive;
        try { archive = new ZipArchive(zip, ZipArchiveMode.Read, leaveOpen: true); }
        catch (InvalidDataException) { throw new UpdateException("安裝檔不是有效的 zip"); }
        using (archive)
        {
            if (archive.Entries.Count > MaxEntries) throw new UpdateException("安裝檔內容異常（檔案數量過多）");
            // 先全部檢查一遍，有任何可疑的 entry 就整包拒絕，不解出半包
            long declared = 0;
            foreach (var e in archive.Entries)
            {
                if (!IsInsideDirectory(destination, e.FullName))
                    throw new UpdateException($"安裝檔含有不允許的路徑：{e.FullName}");
                declared += e.Length;
                if (e.Length < 0 || declared > MaxExtractedBytes) throw new UpdateException("安裝檔內容異常（解壓後過大）");
            }
            var files = new List<string>();
            long written = 0;
            var root = Path.GetFullPath(destination);
            foreach (var e in archive.Entries)
            {
                var full = Path.GetFullPath(Path.Combine(root, e.FullName));
                if (e.FullName.EndsWith('/') || e.FullName.EndsWith('\\'))
                {
                    Directory.CreateDirectory(full);
                    continue;
                }
                Directory.CreateDirectory(Path.GetDirectoryName(full)!);
                using (var src = e.Open())
                using (var dst = new FileStream(full, FileMode.CreateNew, FileAccess.Write))
                {
                    // 宣告的大小可能是假的：實際寫出的量也要算
                    var buf = new byte[81920];
                    int n;
                    while ((n = src.Read(buf, 0, buf.Length)) > 0)
                    {
                        written += n;
                        if (written > MaxExtractedBytes) throw new UpdateException("安裝檔內容異常（解壓後過大）");
                        dst.Write(buf, 0, n);
                    }
                }
                files.Add(e.FullName.Replace('\\', '/'));
            }
            return files;
        }
    }

    /// <summary>
    /// 檢查解出的內容：每個檔案都在 SplitSwan/ 底下，且有 SplitSwan.exe 與 engine 的兩支腳本。
    /// 回傳錯誤訊息，沒問題回 null。
    /// </summary>
    public static string? CheckLayout(IReadOnlyCollection<string> files)
    {
        ArgumentNullException.ThrowIfNull(files);
        if (files.Any(f => !f.StartsWith(Root + "/", StringComparison.Ordinal)))
            return $"安裝檔內容異常（有檔案不在 {Root} 資料夾內）";
        var missing = RequiredFiles.Where(r => !files.Contains(r)).ToList();
        return missing.Count == 0 ? null : $"安裝檔缺少 {string.Join("、", missing)}";
    }

    /// <summary>SplitSwan/ 底下的檔案，轉成相對於安裝資料夾的路徑（例：engine/splitswan-wsl.ps1）。</summary>
    public static IReadOnlyList<string> InstallItems(IEnumerable<string> files) =>
        [.. files.Where(f => f.StartsWith(Root + "/", StringComparison.Ordinal)).Select(f => f[(Root.Length + 1)..]).Where(f => f.Length > 0)];

    /// <summary>一次替換的紀錄，給 Revert 還原用。</summary>
    public sealed class SwapRecord
    {
        internal string InstallDir { get; init; } = "";
        /// <summary>已換進新檔的項目（相對路徑, 原本是否有舊檔）。</summary>
        internal List<(string Rel, bool HadOld)> Done { get; } = [];
        public IReadOnlyList<string> Replaced => [.. Done.Select(d => d.Rel)];
    }

    /// <summary>
    /// 把 stagedRoot（解壓後的 SplitSwan 資料夾）裡的 items 換進 installDir：
    /// 1. 每個新檔先複製成「目標.new」（跨磁碟也能複製，且先確認安裝資料夾可寫入）；
    /// 2. 逐一把舊檔改名成「目標.old」（執行中的 exe 不能覆寫但可以改名），再把「目標.new」改名成目標。
    /// 任一步失敗就還原已完成的步驟並丟 UpdateException。不改名整個資料夾：連線中 engine 資料夾是保活程序的工作目錄，
    /// 資料夾改不了名，但裡面的檔案可以。
    /// </summary>
    /// <param name="beforeMoveIn">測試用：每個項目換進去之前呼叫（丟例外可模擬失敗）。</param>
    public static SwapRecord Swap(string installDir, string stagedRoot, IReadOnlyList<string> items, Action<string>? beforeMoveIn = null)
    {
        ArgumentNullException.ThrowIfNull(items);
        var record = new SwapRecord { InstallDir = installDir };
        var copied = new List<string>();
        try
        {
            foreach (var rel in items)
            {
                var target = Path.Combine(installDir, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.Copy(Path.Combine(stagedRoot, rel), target + NewSuffix, overwrite: true);
                copied.Add(target + NewSuffix);
            }
            foreach (var rel in items)
            {
                var target = Path.Combine(installDir, rel);
                var hadOld = File.Exists(target);
                if (hadOld)
                {
                    // 上次更新留下、還沒清掉的 .old：先刪，刪不掉就停（不覆蓋它，避免把還原用的檔案弄丟）
                    if (File.Exists(target + OldSuffix)) File.Delete(target + OldSuffix);
                    File.Move(target, target + OldSuffix);
                }
                try
                {
                    beforeMoveIn?.Invoke(rel);
                    File.Move(target + NewSuffix, target);
                }
                catch
                {
                    if (hadOld) TryMove(target + OldSuffix, target);
                    throw;
                }
                record.Done.Add((rel, hadOld));
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or UpdateException)
        {
            var rollback = Revert(record);
            foreach (var c in copied) TryDelete(c);
            throw new UpdateException(rollback.Count == 0
                ? $"無法替換檔案，已還原：{ex.Message}"
                : $"無法替換檔案（{ex.Message}），且還原失敗：{string.Join("、", rollback)}。請到 GitHub 下載完整版本手動覆蓋");
        }
        return record;
    }

    /// <summary>還原 Swap 已完成的步驟（例如新版啟動失敗時）。回傳還原失敗的項目。</summary>
    public static IReadOnlyList<string> Revert(SwapRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        var failed = new List<string>();
        for (int i = record.Done.Count - 1; i >= 0; i--)
        {
            var (rel, hadOld) = record.Done[i];
            var target = Path.Combine(record.InstallDir, rel);
            try
            {
                if (hadOld)
                {
                    // 新檔先改名成 .new（不直接刪，萬一 .old 搬不回來至少還有一份能用的）
                    File.Move(target, target + NewSuffix, overwrite: true);
                    File.Move(target + OldSuffix, target);
                    TryDelete(target + NewSuffix);
                }
                else
                {
                    File.Delete(target);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                failed.Add(rel);
            }
        }
        record.Done.Clear();
        return failed;
    }

    /// <summary>
    /// 新版啟動時清掉上次更新留下的 *.old 與 *.new（只看安裝資料夾與 engine 子資料夾，不遞迴）。
    /// 回傳 (已刪除, 刪除失敗) 的檔名；失敗只記錄，不影響啟動。
    /// </summary>
    public static (IReadOnlyList<string> Removed, IReadOnlyList<string> Failed) CleanupLeftovers(string installDir)
    {
        var removed = new List<string>();
        var failed = new List<string>();
        foreach (var dir in new[] { installDir, Path.Combine(installDir, "engine") })
        {
            if (!Directory.Exists(dir)) continue;
            foreach (var f in Directory.EnumerateFiles(dir))
            {
                if (!f.EndsWith(OldSuffix, StringComparison.OrdinalIgnoreCase) && !f.EndsWith(NewSuffix, StringComparison.OrdinalIgnoreCase)) continue;
                try { File.Delete(f); removed.Add(Path.GetRelativePath(installDir, f)); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { failed.Add(Path.GetRelativePath(installDir, f)); }
            }
        }
        return (removed, failed);
    }

    private static void TryMove(string from, string to)
    {
        try { File.Move(from, to); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}
