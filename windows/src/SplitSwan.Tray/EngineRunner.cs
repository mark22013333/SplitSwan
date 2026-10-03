using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>一次引擎呼叫的結果。</summary>
internal sealed record EngineResult(bool Ok, string? Error, IReadOnlyDictionary<string, string> Values, bool TimedOut);

/// <summary>
/// 執行連線引擎 splitswan-wsl.ps1（契約 1）。輸出逐行寫進 AppLog（「顯示引擎輸出」視窗看得到），
/// 結果用 Core 的 EngineOutput 判讀。逾時會結束整個程序樹（powershell 與它叫起來的 wsl.exe）。
/// </summary>
internal static class EngineRunner
{
    public static async Task<EngineResult> RunAsync(EngineAction action, bool logOutput = true)
    {
        var missing = AppPaths.MissingEngineFiles();
        if (missing is not null)
            return Fail($"找不到連線引擎：{missing}。請確認 engine 資料夾跟 SplitSwan.exe 放在一起");
        if (!File.Exists(AppPaths.PowerShellExe))
            return Fail($"找不到 Windows PowerShell：{AppPaths.PowerShellExe}");

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
        foreach (var a in EngineCommand.Arguments(action, AppPaths.EnginePs1, AppPaths.ConfDir))
            psi.ArgumentList.Add(a);

        var lines = new List<string>();
        var name = EngineCommand.ActionName(action);
        void OnLine(string? l, bool isErr)
        {
            if (l is null) return;
            lock (lines) lines.Add(l);
            // brief 每 15 秒一次，只在失敗時才把輸出寫進記錄
            if (logOutput) AppLog.Engine(isErr ? "[stderr] " + l : l);
        }

        using var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) => OnLine(e.Data, false);
        p.ErrorDataReceived += (_, e) => OnLine(e.Data, true);

        try
        {
            if (!p.Start()) return Fail("無法啟動 PowerShell");
        }
        catch (Win32Exception ex)
        {
            return Fail($"無法啟動 PowerShell：{ex.Message}");
        }
        // 不給 stdin：引擎若意外進入互動提示，會讀到 EOF 而不是卡住
        try { p.StandardInput.Close(); } catch (IOException) { }
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();

        var timeout = EngineCommand.Timeout(action);
        var timedOut = false;
        using (var cts = new CancellationTokenSource(timeout))
        {
            try
            {
                await p.WaitForExitAsync(cts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                timedOut = true;
                KillTree(p, name);
            }
        }
        // 等非同步讀取把最後幾行送完
        try { p.WaitForExit(5000); } catch (InvalidOperationException) { }

        List<string> snapshot;
        lock (lines) snapshot = [.. lines];
        var kv = EngineOutput.Parse(snapshot);
        if (timedOut)
        {
            if (!logOutput) foreach (var l in snapshot) AppLog.Engine(l);
            return new EngineResult(false, $"引擎執行 {name} 超過 {FormatSpan(timeout)} 沒有回應，已中止", kv, true);
        }
        var (ok, err) = EngineOutput.Result(kv);
        if (!ok && !logOutput) foreach (var l in snapshot) AppLog.Engine(l);
        return new EngineResult(ok, err, kv, false);
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
        await p.WaitForExitAsync().ConfigureAwait(false);
        try { return p.ExitCode; } catch (InvalidOperationException) { return null; }
    }

    /// <summary>
    /// 快速確認 WSL 與預設發行版是否已安裝（背景連線前用，避免在沒有主控台的情況下觸發互動式安裝）。
    /// 回傳 null＝確定已安裝；否則回傳給使用者看的原因。判斷不了（逾時等）時保守地回傳 null，交給引擎處理。
    /// </summary>
    public static async Task<string?> CheckWslInstalledAsync()
    {
        if (!File.Exists(AppPaths.StoreWslExe))
            return "這台電腦看起來還沒有安裝 WSL（找不到 " + AppPaths.StoreWslExe + "）";
        var psi = new ProcessStartInfo(AppPaths.StoreWslExe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
        };
        psi.ArgumentList.Add("-l");
        psi.ArgumentList.Add("-q");
        psi.Environment["WSL_UTF8"] = "1";
        try
        {
            using var p = Process.Start(psi);
            if (p is null) return null;
            try { p.StandardInput.Close(); } catch (IOException) { }
            var outTask = p.StandardOutput.ReadToEndAsync();
            _ = p.StandardError.ReadToEndAsync();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            try { await p.WaitForExitAsync(cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException)
            {
                try { p.Kill(entireProcessTree: true); } catch (Exception ex) when (ex is InvalidOperationException or Win32Exception) { }
                return null;
            }
            var output = await outTask.ConfigureAwait(false);
            return EngineCommand.ListContainsDistro(output, EngineCommand.DefaultDistro)
                ? null
                : $"這台電腦還沒有安裝 {EngineCommand.DefaultDistro}";
        }
        catch (Win32Exception)
        {
            return null;
        }
    }

    private static EngineResult Fail(string msg) =>
        new(false, msg, new Dictionary<string, string>(), false);

    private static string FormatSpan(TimeSpan t) =>
        t.TotalMinutes >= 1 ? $"{(int)t.TotalMinutes} 分鐘" : $"{(int)t.TotalSeconds} 秒";
}
