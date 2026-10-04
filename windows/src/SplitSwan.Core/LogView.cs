namespace SplitSwan.Core;

/// <summary>記錄行的等級（從 AppLog 的行格式解析）。</summary>
public enum LogLevel
{
    /// <summary>App 自己的訊息（AppLog.Info）。</summary>
    Info,
    /// <summary>引擎輸出（AppLog.Engine，行首「│ 」）。</summary>
    Engine,
    /// <summary>錯誤（AppLog.Error，行首「錯誤：」）。</summary>
    Error,
}

/// <summary>記錄視窗的篩選。</summary>
public enum LogFilter { All, Errors, Engine }

/// <summary>解析後的一行記錄。</summary>
/// <param name="Time">時間欄（HH:mm:ss）；格式不符時為空字串。</param>
/// <param name="Level">等級。</param>
/// <param name="Text">去掉時間與等級標記後的內容。</param>
/// <param name="Raw">原始整行（複製時用原文）。</param>
public sealed record LogEntry(string Time, LogLevel Level, string Text, string Raw);

/// <summary>
/// 記錄視窗的純邏輯：解析 AppLog 的行（「HH:mm:ss 」＋標記＋內容）、篩選、計數、複製文字。
/// 標記對應 AppLog.Info（無標記）、AppLog.Engine（「│ 」）、AppLog.Error（「錯誤：」）。
/// </summary>
public static class LogView
{
    public const string EngineTag = "│ ";
    public const string ErrorTag = "錯誤：";

    /// <summary>解析一行；不是「HH:mm:ss 」開頭的行（理論上不會有）時間欄留空、整行當訊息。</summary>
    /// <remarks>已知限制：AppLog 的時間格式依文化而定，時間分隔符不是冒號的地區（例 fi-FI 用「.」）解析不到時間與等級，錯誤／引擎計數會失準。</remarks>
    public static LogEntry Parse(string? line)
    {
        var raw = line ?? "";
        string time = "", rest = raw;
        if (raw.Length >= 9 && raw[8] == ' ' && IsTime(raw.AsSpan(0, 8)))
        {
            time = raw[..8];
            rest = raw[9..];
        }
        if (rest.StartsWith(EngineTag, StringComparison.Ordinal))
            return new LogEntry(time, LogLevel.Engine, rest[EngineTag.Length..], raw);
        if (rest.StartsWith(ErrorTag, StringComparison.Ordinal))
            return new LogEntry(time, LogLevel.Error, rest[ErrorTag.Length..], raw);
        return new LogEntry(time, LogLevel.Info, rest, raw);
    }

    private static bool IsTime(ReadOnlySpan<char> s) =>
        s[2] == ':' && s[5] == ':'
        && IsDigits(s[..2]) && IsDigits(s.Slice(3, 2)) && IsDigits(s.Slice(6, 2));

    // 只認 ASCII 數字（char.IsDigit 會接受全形數字）
    private static bool IsDigits(ReadOnlySpan<char> s)
    {
        foreach (var c in s) if (c is < '0' or > '9') return false;
        return true;
    }

    /// <summary>這一行是否符合篩選。</summary>
    public static bool Matches(LogEntry e, LogFilter f) => f switch
    {
        LogFilter.Errors => e.Level == LogLevel.Error,
        LogFilter.Engine => e.Level == LogLevel.Engine,
        _ => true,
    };

    public static IReadOnlyList<LogEntry> Filter(IEnumerable<LogEntry> entries, LogFilter f) =>
        [.. entries.Where(e => Matches(e, f))];

    /// <summary>各篩選的行數（分段按鈕上的計數）。</summary>
    public static (int All, int Errors, int Engine) Count(IEnumerable<LogEntry> entries)
    {
        int all = 0, err = 0, eng = 0;
        foreach (var e in entries)
        {
            all++;
            if (e.Level == LogLevel.Error) err++;
            else if (e.Level == LogLevel.Engine) eng++;
        }
        return (all, err, eng);
    }

    /// <summary>分段按鈕的文字：「全部」「錯誤 N」「引擎」（錯誤數 0 也顯示，讓使用者知道沒有錯誤）。</summary>
    public static string SegmentTitle(LogFilter f, int errors) => f switch
    {
        LogFilter.Errors => $"錯誤 {errors}",
        LogFilter.Engine => "引擎",
        _ => "全部",
    };

    /// <summary>等級欄的文字。</summary>
    public static string LevelTitle(LogLevel l) => l switch
    {
        LogLevel.Error => "錯誤",
        LogLevel.Engine => "引擎",
        _ => "訊息",
    };

    /// <summary>「複製」的內容：目前篩選結果的原始行，以 CRLF 分隔（Windows 剪貼簿慣例）。</summary>
    public static string CopyText(IEnumerable<LogEntry> filtered) =>
        string.Join("\r\n", filtered.Select(e => e.Raw));
}
