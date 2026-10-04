using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace SplitSwan.Tray;

/// <summary>一次外部指令的結果。ExitCode 為 null＝沒啟動成功、逾時或被取消。</summary>
internal sealed record CommandResult(int? ExitCode, IReadOnlyList<string> Lines, bool TimedOut, bool Cancelled, string? StartError)
{
    public bool Ok => ExitCode == 0;

    /// <summary>給使用者看的失敗原因（一行）。</summary>
    public string Describe(string what) =>
        StartError is not null ? $"{what}無法執行：{StartError}"
        : Cancelled ? $"{what}已取消"
        : TimedOut ? $"{what}逾時，已中止"
        : $"{what}失敗（結束碼 {ExitCode?.ToString() ?? "未知"}）";
}

/// <summary>
/// 首次設定精靈執行外部指令（wsl.exe、探測用的 PowerShell）：逐行回呼輸出（stdout 與 stderr 合併），
/// 同時寫進 AppLog。逾時或取消時結束整個程序樹。
/// wsl.exe 的輸出設 WSL_UTF8=1 讓它用 UTF-8（否則是 UTF-16，見 WslDistros.ParseList 的說明）。
/// </summary>
internal static class CommandRunner
{
    private static readonly TimeSpan EofGrace = TimeSpan.FromSeconds(3);

    /// <param name="display">印在輸出區「&gt; 指令」那一行的文字（不含任何秘密）。</param>
    public static async Task<CommandResult> RunAsync(string fileName, IReadOnlyList<string> args, TimeSpan timeout,
        Action<string>? onLine, CancellationToken ct = default, string? display = null)
    {
        void Emit(string line)
        {
            AppLog.Engine(line);
            try { onLine?.Invoke(line); } catch (Exception) { /* 視窗已關閉，不影響執行 */ }
        }

        Emit("> " + (display ?? Path.GetFileName(fileName) + " " + string.Join(" ", args)));
        var psi = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
            WorkingDirectory = AppPaths.DataDirOrTemp(),
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["WSL_UTF8"] = "1";

        var lines = new List<string>();
        var outEof = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errEof = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        void OnData(string? data, TaskCompletionSource eof)
        {
            if (data is null) { eof.TrySetResult(); return; }
            // wsl.exe 在 UTF-16 模式時夾帶 NUL；顯示前去掉
            var clean = data.Replace("\0", "");
            lock (lines) lines.Add(clean);
            Emit(clean);
        }
        p.OutputDataReceived += (_, e) => OnData(e.Data, outEof);
        p.ErrorDataReceived += (_, e) => OnData(e.Data, errEof);
        p.Exited += (_, _) => exited.TrySetResult();

        try
        {
            if (!p.Start()) return new(null, [], false, false, "無法啟動程序");
        }
        catch (Win32Exception ex)
        {
            Emit("無法執行：" + ex.Message);
            return new(null, [], false, false, ex.Message);
        }
        try { p.StandardInput.Close(); } catch (IOException) { }
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();

        var timedOut = false;
        var cancelled = false;
        using (var waitCts = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            var delay = Task.Delay(timeout, waitCts.Token);
            var done = await Task.WhenAny(exited.Task, delay).ConfigureAwait(false);
            if (done != exited.Task)
            {
                cancelled = ct.IsCancellationRequested;
                timedOut = !cancelled;
                try { if (!p.HasExited) p.Kill(entireProcessTree: true); }
                catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or NotSupportedException)
                {
                    AppLog.Error($"結束程序失敗：{ex.Message}");
                }
                await Task.WhenAny(exited.Task, Task.Delay(TimeSpan.FromSeconds(5), CancellationToken.None)).ConfigureAwait(false);
            }
            await Task.WhenAny(Task.WhenAll(outEof.Task, errEof.Task), Task.Delay(EofGrace, CancellationToken.None)).ConfigureAwait(false);
            waitCts.Cancel();
        }

        int? code = null;
        try { if (p.HasExited && !timedOut && !cancelled) code = p.ExitCode; } catch (InvalidOperationException) { }
        List<string> snapshot;
        lock (lines) snapshot = [.. lines];
        if (timedOut) Emit($"（逾時 {timeout.TotalMinutes:0} 分鐘，已中止）");
        else if (cancelled) Emit("（已取消）");
        else Emit($"（結束碼 {code?.ToString() ?? "未知"}）");
        return new(code, snapshot, timedOut, cancelled, null);
    }
}
