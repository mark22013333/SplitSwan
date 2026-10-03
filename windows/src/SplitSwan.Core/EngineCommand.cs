using System.Text;

namespace SplitSwan.Core;

/// <summary>連線引擎的動作（契約 1）。</summary>
public enum EngineAction { Connect, Disconnect, Status, Brief }

/// <summary>
/// 組出呼叫連線引擎（splitswan-wsl.ps1）的 powershell.exe 命令列，以及引擎回應的判讀小工具。
/// 純字串處理，不啟動任何程序。
/// </summary>
public static class EngineCommand
{
    /// <summary>connect 的逾時：第一次要裝 strongSwan，比較久。</summary>
    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromMinutes(5);
    /// <summary>disconnect 的逾時。</summary>
    public static readonly TimeSpan DisconnectTimeout = TimeSpan.FromMinutes(2);
    /// <summary>
    /// brief 的逾時：引擎內部查詢限時 6 秒（契約 1），加上 Windows PowerShell 冷啟動約 3 秒以上，
    /// 留 12 秒讓引擎自己的逾時訊息先出來；仍小於 15 秒的輪詢間隔。
    /// </summary>
    public static readonly TimeSpan BriefTimeout = TimeSpan.FromSeconds(12);

    public static string ActionName(EngineAction a) => a switch
    {
        EngineAction.Connect => "connect",
        EngineAction.Disconnect => "disconnect",
        EngineAction.Status => "status",
        EngineAction.Brief => "brief",
        _ => throw new ArgumentOutOfRangeException(nameof(a)),
    };

    public static TimeSpan Timeout(EngineAction a) => a switch
    {
        EngineAction.Connect => ConnectTimeout,
        EngineAction.Brief => BriefTimeout,
        _ => DisconnectTimeout,
    };

    /// <summary>
    /// powershell.exe 的參數清單：-NoProfile -ExecutionPolicy Bypass -File &lt;script&gt; -Action &lt;a&gt; -ConfDir &lt;dir&gt; [-PauseAtEnd]。
    /// </summary>
    /// <param name="noInstall">加 -NoInstall：WSL／Ubuntu 未安裝時引擎只回報、不在背景開始安裝（契約 1；只對 connect 有效，其他動作忽略）。</param>
    public static IReadOnlyList<string> Arguments(EngineAction action, string scriptPath, string confDir,
        bool pauseAtEnd = false, bool noInstall = false)
    {
        ArgumentException.ThrowIfNullOrEmpty(scriptPath);
        ArgumentException.ThrowIfNullOrEmpty(confDir);
        // 引擎會把 ConfDir 結尾的 \ 去掉；這裡先去掉，免得 "C:\x\" 的結尾反斜線跳脫掉右引號
        var dir = confDir.Length > 3 ? confDir.TrimEnd('\\', '/') : confDir;
        var list = new List<string>
        {
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath,
            "-Action", ActionName(action), "-ConfDir", dir,
        };
        if (noInstall && action == EngineAction.Connect) list.Add("-NoInstall");
        if (pauseAtEnd) list.Add("-PauseAtEnd");
        return list;
    }

    /// <summary>
    /// 依 Windows CommandLineToArgvW 規則把參數清單接成一條命令列（同 .NET 內部的 PasteArguments）。
    /// 需要可見視窗（UseShellExecute）時只能用字串傳參數，所以自己組。
    /// </summary>
    public static string JoinCommandLine(IEnumerable<string> args)
    {
        var sb = new StringBuilder();
        foreach (var a in args)
        {
            if (sb.Length > 0) sb.Append(' ');
            AppendQuoted(sb, a ?? "");
        }
        return sb.ToString();
    }

    private static void AppendQuoted(StringBuilder sb, string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny([' ', '\t', '\n', '\v', '"']) < 0)
        {
            sb.Append(arg);
            return;
        }
        sb.Append('"');
        int backslashes = 0;
        foreach (var c in arg)
        {
            if (c == '\\') { backslashes++; continue; }
            if (c == '"')
            {
                // 引號前的反斜線要加倍，再加一個跳脫引號
                sb.Append('\\', backslashes * 2 + 1).Append('"');
            }
            else
            {
                sb.Append('\\', backslashes).Append(c);
            }
            backslashes = 0;
        }
        // 結尾的反斜線後面接的是右引號，要加倍
        sb.Append('\\', backslashes * 2).Append('"');
    }

    /// <summary>
    /// 是否需要使用者改用「首次安裝」：WSL 或 Ubuntu 尚未安裝。判斷依據（任一成立）：
    /// - 錯誤訊息含「已開始安裝」（引擎在背景開始了互動式安裝）或「尚未安裝」（引擎帶 -NoInstall 時的回報）；
    /// - 任何一行輸出含「開始安裝」（引擎在安裝前會先印這句；逾時被結束、沒有 @@RESULT 時也抓得到）。
    /// 背景執行時沒有主控台可以建立 Ubuntu 帳號，所以要改用可見視窗。
    /// </summary>
    public static bool IsInstallNeeded(string? error, IEnumerable<string>? outputLines = null)
    {
        if (error is not null && (error.Contains("已開始安裝", StringComparison.Ordinal)
                                  || error.Contains("尚未安裝", StringComparison.Ordinal)))
            return true;
        return outputLines is not null && outputLines.Any(l => l is not null && l.Contains("開始安裝", StringComparison.Ordinal));
    }

    /// <summary>引擎回報「不是系統管理員」（正常情況下 App 以管理員執行，不會發生）。</summary>
    public static bool IsNotAdministrator(string? error) =>
        error is not null && error.Contains("不是系統管理員", StringComparison.Ordinal);

    /// <summary>
    /// 引擎沒有輸出 @@RESULT 時（powershell 被群組原則擋下、語法錯誤、被結束等）給使用者看的訊息：
    /// 附上結束碼與 stderr 的前兩行非空白內容，方便判斷原因。
    /// </summary>
    public static string DescribeMissingResult(int? exitCode, IEnumerable<string>? stderrLines)
    {
        var sb = new StringBuilder("引擎沒有回傳結果");
        sb.Append(exitCode is null ? "（結束碼未知）" : $"（結束碼 {exitCode}）");
        var first = (stderrLines ?? []).Where(l => !string.IsNullOrWhiteSpace(l)).Select(l => l.Trim()).Take(2).ToList();
        if (first.Count > 0) sb.Append('：').Append(string.Join("｜", first));
        return sb.ToString();
    }
}
