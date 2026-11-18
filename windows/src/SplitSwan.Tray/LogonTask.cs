using System.Diagnostics;
using System.Security.Principal;
using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 登入時自動啟動的工作排程器工作（\SplitSwan），經 schtasks.exe 讀寫；工作內容與解析在 Core 的 LogonTaskXml。
/// 歸屬判斷與開關流程跟捷徑共用（Shortcuts.Inspect／Apply 的 ShortcutLocation.Logon）。
/// </summary>
internal static class LogonTask
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(15);
    private static string SchTasks => Path.Combine(Environment.SystemDirectory, "schtasks.exe");

    /// <summary>
    /// 讀取工作。schtasks 查不到時（結束碼非 0）視為不存在：App 以系統管理員執行，查詢本身不會因權限失敗；
    /// 真的是別的錯誤時，接下來的建立會失敗並把原因顯示出來。
    /// </summary>
    public static (bool Exists, string? Command, string? Description) Read()
    {
        var (code, output) = Run("/Query", "/TN", LogonTaskXml.TaskName, "/XML", "ONE");
        if (code != 0) return (false, null, null);
        var (command, description) = LogonTaskXml.Parse(output);
        return (true, command, description);
    }

    /// <summary>建立或覆寫工作：目前登入的帳號登入時，以最高權限執行 exe。</summary>
    /// <exception cref="InvalidOperationException">schtasks 失敗（訊息含它的輸出）。</exception>
    public static void Write(string exe)
    {
        var user = WindowsIdentity.GetCurrent().Name;
        var xml = Path.Combine(Path.GetTempPath(), $"splitswan-logon-{Guid.NewGuid():N}.xml");
        try
        {
            // schtasks /XML 要求檔案編碼與宣告相符；XDocument 宣告的是 UTF-16
            File.WriteAllText(xml, LogonTaskXml.Render(exe, user), Encoding.Unicode);
            var (code, output) = Run("/Create", "/TN", LogonTaskXml.TaskName, "/XML", xml, "/F");
            if (code != 0) throw new InvalidOperationException($"建立排程工作失敗：{FirstLine(output)}");
        }
        finally
        {
            try { File.Delete(xml); } catch (IOException) { /* 暫存檔，留著無害 */ }
        }
    }

    /// <summary>刪除工作。</summary>
    /// <exception cref="InvalidOperationException">schtasks 失敗。</exception>
    public static void Delete()
    {
        var (code, output) = Run("/Delete", "/TN", LogonTaskXml.TaskName, "/F");
        if (code != 0) throw new InvalidOperationException($"刪除排程工作失敗：{FirstLine(output)}");
    }

    private static (int Code, string Output) Run(params string[] args)
    {
        var psi = new ProcessStartInfo(SchTasks)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("無法執行 schtasks.exe");
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(Timeout))
        {
            try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { /* 已結束 */ }
            throw new InvalidOperationException("schtasks.exe 沒有回應");
        }
        return (p.ExitCode, stdout.Result + stderr.Result);
    }

    private static string FirstLine(string s) =>
        s.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault() ?? "（沒有輸出）";
}
