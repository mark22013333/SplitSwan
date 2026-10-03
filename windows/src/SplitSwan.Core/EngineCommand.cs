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
    /// <summary>brief 的逾時（引擎自己限時約 1.8 秒，這裡多留 powershell 啟動時間）。</summary>
    public static readonly TimeSpan BriefTimeout = TimeSpan.FromSeconds(10);

    /// <summary>引擎預設使用的 WSL 發行版（App 不寫 Distro，沿用引擎預設值）。</summary>
    public const string DefaultDistro = "Ubuntu-24.04";

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
    public static IReadOnlyList<string> Arguments(EngineAction action, string scriptPath, string confDir, bool pauseAtEnd = false)
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
    /// 引擎在 WSL 或 Ubuntu 尚未安裝時，會開始互動式安裝並回 fail「已開始安裝…」。
    /// 背景執行時沒有主控台可以建立 Ubuntu 帳號，App 要改請使用者用「首次安裝」。
    /// </summary>
    public static bool IsInstallStarted(string? error) =>
        error is not null && error.Contains("已開始安裝", StringComparison.Ordinal);

    /// <summary>引擎回報「不是系統管理員」（正常情況下 App 以管理員執行，不會發生）。</summary>
    public static bool IsNotAdministrator(string? error) =>
        error is not null && error.Contains("不是系統管理員", StringComparison.Ordinal);

    /// <summary>
    /// 從 wsl.exe -l -q 的輸出判斷發行版是否已安裝。
    /// wsl -l 沒吃到 WSL_UTF8 時是 UTF-16，先去掉 NUL、BOM 與替代字元再比對（同引擎的 Invoke-WslQuick）。
    /// </summary>
    public static bool ListContainsDistro(string? wslListOutput, string distro)
    {
        if (string.IsNullOrEmpty(wslListOutput)) return false;
        var cleaned = new string([.. wslListOutput.Where(c => c is not ('\0' or '\uFEFF' or '\uFFFD'))]);
        return cleaned.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim().TrimStart('*').Trim())
            .Any(l => string.Equals(l, distro, StringComparison.OrdinalIgnoreCase));
    }
}
