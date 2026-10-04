namespace SplitSwan.Core;

/// <summary>記錄檔的保留與遮蔽（托盤 App 用），純邏輯。</summary>
public static class LogHygiene
{
    /// <summary>遮蔽後的替代字串。</summary>
    public const string Mask = "***";

    /// <summary>
    /// 把一行文字裡出現的密碼／PSK 原文換成 ***（最後一道防線：App 本來就不記錄密碼，
    /// 但引擎或外部程式的輸出萬一帶出來，也不會寫進記錄檔）。
    /// 空字串與少於 3 個字的秘密不遮（太短會把一般文字也遮掉；設定驗證本來就不鼓勵這種密碼）。
    /// 長的先遮，避免短秘密是長秘密的一部分時遮不完整。
    /// </summary>
    public static string Redact(string line, IEnumerable<string?> secrets)
    {
        ArgumentNullException.ThrowIfNull(secrets);
        if (string.IsNullOrEmpty(line)) return line ?? "";
        foreach (var s in secrets.Where(x => x is { Length: >= 3 }).Distinct().OrderByDescending(x => x!.Length))
            line = line.Replace(s!, Mask, StringComparison.Ordinal);
        return line;
    }

    /// <summary>
    /// 要刪掉哪些舊記錄檔：檔名依字典序排序（檔名內含 yyyyMMdd-HHmmss，字典序即時間序），保留最新的 keep 份。
    /// 只考慮符合 prefix 開頭、.log 結尾的檔名，其他檔案一律不動。
    /// </summary>
    public static IReadOnlyList<string> SelectForDeletion(IEnumerable<string> fileNames, string prefix, int keep)
    {
        ArgumentNullException.ThrowIfNull(fileNames);
        if (keep < 1) keep = 1;
        var mine = fileNames
            .Where(n => n.StartsWith(prefix, StringComparison.Ordinal) && n.EndsWith(".log", StringComparison.OrdinalIgnoreCase))
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToList();
        return mine.Count <= keep ? [] : mine.Take(mine.Count - keep).ToList();
    }
}
