using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>一次引擎呼叫的結果。Lines 是 stdout 的所有行（判斷「需要首次安裝」等用）。</summary>
internal sealed record EngineResult(
    bool Ok, string? Error, IReadOnlyDictionary<string, string> Values, bool TimedOut, IReadOnlyList<string> Lines)
{
    public static EngineResult Failed(string error) =>
        new(false, error, new Dictionary<string, string>(), false, []);
}

/// <summary>
/// 執行連線引擎 splitswan-wsl.ps1（契約 1）。輸出逐行寫進 AppLog（「顯示引擎輸出」視窗看得到），
/// 結果用 Core 的 EngineOutput 判讀（只解析 stdout）。逾時會結束整個程序樹（powershell 與它叫起來的 wsl.exe）。
/// </summary>
internal static class EngineRunner
{
    /// <summary>程序結束後，最多再等多久讀到 stdout／stderr 的 EOF。</summary>
    private static readonly TimeSpan EofGrace = TimeSpan.FromSeconds(3);

    /// <param name="order">connect 的閘道嘗試順序（契約 3 的 -Order）；null＝不帶。其他動作忽略。</param>
    public static async Task<EngineResult> RunAsync(EngineAction action, bool logOutput = true, IReadOnlyList<int>? order = null)
    {
        var missing = AppPaths.MissingEngineFiles();
        if (missing is not null)
            return EngineResult.Failed($"找不到連線引擎：{missing}。請確認 engine 資料夾跟 SplitSwan.exe 放在一起");
        if (!File.Exists(AppPaths.PowerShellExe))
            return EngineResult.Failed($"找不到 Windows PowerShell：{AppPaths.PowerShellExe}");

        var psi = new ProcessStartInfo(AppPaths.PowerShellExe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
            WorkingDirectory = AppPaths.EngineDir,
        };
        // 背景執行一律帶 -NoInstall（契約 1）：WSL／Ubuntu 未安裝時引擎只回報「尚未安裝」，
        // 不在沒有主控台的情況下開始互動式安裝；安裝只走「首次安裝」的可見視窗（RunVisibleAsync）
        var args = EngineCommand.Arguments(action, AppPaths.EnginePs1, AppPaths.ConfDir, noInstall: true, order: order);
        foreach (var a in args) psi.ArgumentList.Add(a);

        var stdout = new List<string>();
        var stderr = new List<string>();
        var outEof = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errEof = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var name = EngineCommand.ActionName(action);

        using var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) { outEof.TrySetResult(); return; }
            lock (stdout) stdout.Add(e.Data);
            // brief 每 15 秒一次，只在失敗時才把輸出寫進記錄
            if (logOutput) AppLog.Engine(e.Data);
        };
        p.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) { errEof.TrySetResult(); return; }
            lock (stderr) stderr.Add(e.Data);
            if (logOutput) AppLog.Engine("[stderr] " + e.Data);
        };
        p.Exited += (_, _) => exited.TrySetResult();

        try
        {
            if (!p.Start()) return EngineResult.Failed("無法啟動 PowerShell");
        }
        catch (Win32Exception ex)
        {
            return EngineResult.Failed($"無法啟動 PowerShell：{ex.Message}");
        }
        // 不給 stdin：引擎若意外進入互動提示，會讀到 EOF 而不是卡住
        try { p.StandardInput.Close(); } catch (IOException) { }
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();

        // 只等「程序結束」，不用 WaitForExitAsync：它在程序結束後還會等管線 EOF，
        // 而引擎啟動的常駐子孫程序（例如保活用的 wsl.exe）若繼承了管線寫入端，EOF 永遠不會來，
        // 會讓已經成功的 connect 被誤判成逾時。
        var timeout = EngineCommand.Timeout(action);
        var timedOut = false;
        // 等待用的計時器在等到之後取消，不讓每次 connect 都留一個 5 分鐘的計時器
        using (var waitCts = new CancellationTokenSource())
        {
            if (await Task.WhenAny(exited.Task, Task.Delay(timeout, waitCts.Token)).ConfigureAwait(false) != exited.Task)
            {
                timedOut = true;
                KillTree(p, name);
                // 殺掉後給一點時間讓 Exited 觸發，不無限等
                await Task.WhenAny(exited.Task, Task.Delay(TimeSpan.FromSeconds(5), waitCts.Token)).ConfigureAwait(false);
            }
            // 程序已結束：最多再等 3 秒把剩下的輸出讀完，逾時就用已收到的行判讀
            await Task.WhenAny(Task.WhenAll(outEof.Task, errEof.Task), Task.Delay(EofGrace, waitCts.Token)).ConfigureAwait(false);
            waitCts.Cancel();
        }

        int? exitCode = null;
        try { if (p.HasExited) exitCode = p.ExitCode; } catch (InvalidOperationException) { }

        List<string> outLines, errLines;
        lock (stdout) outLines = [.. stdout];
        lock (stderr) errLines = [.. stderr];
        var kv = EngineOutput.Parse(outLines);

        if (timedOut)
        {
            if (!logOutput) DumpToLog(outLines, errLines);
            return new EngineResult(false, $"引擎執行 {name} 超過 {FormatSpan(timeout)} 沒有回應，已中止", kv, true, outLines);
        }
        string? error;
        bool ok;
        if (!kv.ContainsKey("RESULT"))
        {
            ok = false;
            error = EngineCommand.DescribeMissingResult(exitCode, errLines);
        }
        else
        {
            (ok, error) = EngineOutput.Result(kv);
        }
        if (!ok && !logOutput) DumpToLog(outLines, errLines);
        return new EngineResult(ok, error, kv, false, outLines);
    }

    private static void DumpToLog(List<string> outLines, List<string> errLines)
    {
        foreach (var l in outLines) AppLog.Engine(l);
        foreach (var l in errLines) AppLog.Engine("[stderr] " + l);
    }

    private static void KillTree(Process p, string name)
    {
        try
        {
            if (!p.HasExited)
            {
                p.Kill(entireProcessTree: true);
                AppLog.Error($"引擎 {name} 逾時，已結束 PowerShell 與其子程序");
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or NotSupportedException)
        {
            AppLog.Error($"結束逾時的引擎程序失敗：{ex.Message}");
        }
    }

    /// <summary>
    /// 在可見的 PowerShell 視窗執行引擎（首次安裝用：wsl --install 需要主控台建立 Ubuntu 帳號）。
    /// 視窗結束時（使用者按 Enter 關閉）才完成；不設逾時，但重開機時程序會被結束，呼叫端要處理殘留的 secrets.conf。
    /// 不帶 -NoInstall：這條路徑就是要讓引擎安裝。
    /// </summary>
    public static async Task<int?> RunVisibleAsync(EngineAction action)
    {
        var missing = AppPaths.MissingEngineFiles();
        if (missing is not null) throw new InvalidOperationException($"找不到連線引擎：{missing}");
        var psi = new ProcessStartInfo(AppPaths.PowerShellExe)
        {
            // UseShellExecute 才會開新的主控台視窗；App 已是管理員，子程序繼承權限，不會再跳 UAC
            UseShellExecute = true,
            WorkingDirectory = AppPaths.EngineDir,
            Arguments = EngineCommand.JoinCommandLine(
                EngineCommand.Arguments(action, AppPaths.EnginePs1, AppPaths.ConfDir, pauseAtEnd: true)),
        };
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("無法開啟 PowerShell 視窗");
        // 沒有重導向輸出，WaitForExitAsync 不會等管線
        await p.WaitForExitAsync().ConfigureAwait(false);
        try { return p.ExitCode; } catch (InvalidOperationException) { return null; }
    }

    private static string FormatSpan(TimeSpan t) =>
        t.TotalMinutes >= 1 ? $"{(int)t.TotalMinutes} 分鐘" : $"{(int)t.TotalSeconds} 秒";
}
