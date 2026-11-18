using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 一鍵診斷報告：收集 WSL、連線引擎、路由、DNS（NRPT）、Hyper-V 防火牆、網卡與記錄檔，
/// 經 DiagnosticMasker 遮蔽後寫到 %LOCALAPPDATA%\SplitSwan\reports\。全部唯讀：不連線、不斷線、不改設定。
/// 每個指令各自限時，某一項失敗只在報告裡註明，不影響其他項。
/// </summary>
internal static class DiagnosticRunner
{
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(20);
    private const int LogTailLines = 300;
    private const int EngineLogTailLines = 150;

    public static string ReportDir => Path.Combine(AppPaths.DataDir, "reports");
    private static string EngineLogDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SplitSwan-WSL", "logs");
    private static string Wsl => Path.Combine(Environment.SystemDirectory, "wsl.exe");

    /// <summary>收集並寫出報告，回傳檔案路徑。</summary>
    public static async Task<string> WriteAsync(StoredSettings settings, string? virtualIp)
    {
        var sections = new List<DiagnosticSection>
        {
            await RunAsync("WSL 版本", Wsl, "--version"),
            await RunAsync("WSL 發行版", Wsl, "-l", "-v"),
            ReadFile(".wslconfig", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".wslconfig")),
            await EngineStatusAsync(settings.Distro),
            await RunAsync("IPv4 路由表", Path.Combine(Environment.SystemDirectory, "route.exe"), "print", "-4"),
            await RunAsync("網路介面位址", Path.Combine(Environment.SystemDirectory, "ipconfig.exe")),
            await PowerShellAsync("網卡", "Get-NetAdapter | Sort-Object Name | Format-Table Name, InterfaceDescription, Status -AutoSize | Out-String -Width 200"),
            await PowerShellAsync("DNS 分流規則（NRPT）", "Get-DnsClientNrptRule | Format-Table Namespace, NameServers, Comment -AutoSize | Out-String -Width 200"),
            await PowerShellAsync("Hyper-V 防火牆（WSL）", "Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore | Format-List | Out-String -Width 200"),
            ReadFile("首次設定精靈進度", AppPaths.WizardFile),
            ReadFile("閘道連線紀錄", AppPaths.GatewayHistoryFile),
            NewestEngineLog(),
            new("App 記錄（最近 " + LogTailLines + " 行）", "記憶體中的 App 記錄", DiagnosticReport.Tail(AppLog.Snapshot(), LogTailLines)),
        };

        var masker = new DiagnosticMasker(settings, virtualIp);
        var text = DiagnosticReport.Build(Header(settings), sections, masker);
        Directory.CreateDirectory(ReportDir);
        var path = Path.Combine(ReportDir, DiagnosticReport.FileName(DateTime.Now));
        await File.WriteAllTextAsync(path, text, new UTF8Encoding(true));
        AppLog.Info($"已產生診斷報告：{path}");
        return path;
    }

    /// <summary>在檔案總管裡選取報告檔。</summary>
    public static void Reveal(string path)
    {
        var explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
        Process.Start(new ProcessStartInfo(explorer) { ArgumentList = { "/select," + path }, UseShellExecute = false });
    }

    private static IEnumerable<string> Header(StoredSettings s)
    {
        bool admin;
        using (var id = WindowsIdentity.GetCurrent()) admin = new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        yield return $"產生時間：{DateTime.Now:yyyy-MM-dd HH:mm:ss zzz}";
        yield return $"SplitSwan：{UpdateCenter.CurrentVersion}（{Environment.ProcessPath}）";
        yield return $"Windows：{Environment.OSVersion.Version}，{RuntimeInformation.OSArchitecture}，系統管理員：{(admin ? "是" : "否")}";
        yield return $"WSL 發行版：{s.Distro}";
        yield return $"設定：閘道 {s.Gateways.Count(g => g.Length > 0)} 台、網段 {s.RemoteSubnets.Count} 個、自動重連 {(s.AutoReconnect ? "開" : "關")}、" +
                     $"內部網域 {(s.Domain.Length > 0 ? "有" : "無")}、內部 DNS {(s.DnsServer.Length > 0 ? "有" : "無")}";
        // 網段本身會被遮成 <內網#n>，但前綴長度留著：判斷與 WSL 的 172.16–31.x 是否重疊時要用
        yield return "網段：" + string.Join("、", s.RemoteSubnets);
    }

    private static async Task<DiagnosticSection> EngineStatusAsync(string distro)
    {
        if (AppPaths.MissingEngineFiles() is { } missing) return new("連線引擎狀態", "splitswan-wsl.ps1 -Action status", [], missing);
        var args = EngineCommand.Arguments(EngineAction.Status, AppPaths.EnginePs1, AppPaths.ConfDir, distro: distro);
        return await RunAsync("連線引擎狀態", AppPaths.PowerShellExe, EngineCommand.Timeout(EngineAction.Status), args.ToArray());
    }

    private static Task<DiagnosticSection> PowerShellAsync(string title, string script) =>
        RunAsync(title, AppPaths.PowerShellExe, CommandTimeout, "-NoProfile", "-NonInteractive", "-Command",
            "[Console]::OutputEncoding = [Text.Encoding]::UTF8; " + script);

    private static Task<DiagnosticSection> RunAsync(string title, string file, params string[] args) =>
        RunAsync(title, file, CommandTimeout, args);

    private static async Task<DiagnosticSection> RunAsync(string title, string file, TimeSpan timeout, params string[] args)
    {
        var display = Path.GetFileName(file) + " " + EngineCommand.JoinCommandLine(args);
        var psi = new ProcessStartInfo(file)
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
        Process p;
        try { p = Process.Start(psi) ?? throw new InvalidOperationException("沒有啟動"); }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return new(title, display, [], $"無法執行：{ex.Message}");
        }
        using (p)
        {
            p.StandardInput.Close();
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            using var cts = new CancellationTokenSource(timeout);
            try { await p.WaitForExitAsync(cts.Token); }
            catch (OperationCanceledException)
            {
                try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { /* 已結束 */ }
                return new(title, display, [], $"逾時（{timeout.TotalSeconds:0} 秒），已中止");
            }
            var lines = (await stdout + await stderr).Replace("\0", "")
                .Split('\n').Select(l => l.TrimEnd('\r')).ToList();
            while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
            return new(title, display, lines, p.ExitCode == 0 ? null : $"結束碼 {p.ExitCode}");
        }
    }

    private static DiagnosticSection ReadFile(string title, string path)
    {
        try
        {
            return File.Exists(path)
                ? new(title, path, File.ReadAllLines(path, Encoding.UTF8))
                : new(title, path, [], "檔案不存在");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new(title, path, [], $"讀不到：{ex.Message}");
        }
    }

    private static DiagnosticSection NewestEngineLog()
    {
        const string title = "連線引擎最近一次記錄";
        try
        {
            var newest = Directory.Exists(EngineLogDir)
                ? new DirectoryInfo(EngineLogDir).GetFiles("*.log").OrderByDescending(f => f.LastWriteTimeUtc).FirstOrDefault()
                : null;
            if (newest is null) return new(title, EngineLogDir, [], "沒有記錄檔");
            var lines = File.ReadAllLines(newest.FullName, Encoding.UTF8);
            return new($"{title}（最後 {EngineLogTailLines} 行）", newest.FullName, DiagnosticReport.Tail(lines, EngineLogTailLines));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new(title, EngineLogDir, [], $"讀不到：{ex.Message}");
        }
    }
}
