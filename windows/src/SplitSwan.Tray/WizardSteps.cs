using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using SplitSwan.Core;

namespace SplitSwan.Tray;

internal enum StepOutcome { Done, Skipped, Failed, WaitingReboot, WaitingUser }

internal sealed record StepResult(StepOutcome Outcome, string? Error = null)
{
    public static StepResult Fail(string error) => new(StepOutcome.Failed, error);
}

/// <summary>精靈各步驟需要的 UI 回呼與共用物件。回呼可從任何執行緒呼叫（WizardForm 自己切回 UI 執行緒）。</summary>
internal sealed class WizardContext
{
    public required Action<string> Output { get; init; }
    /// <summary>下載進度（已下載、總長）；null＝隱藏進度數字、改成不定進度。</summary>
    public required Action<long, long?>? Progress { get; init; }
    /// <summary>進入／離開下載階段（只有下載可以取消；匯入與安裝不中途中止）。</summary>
    public Action<bool>? Downloading { get; init; }
    public required VpnCoordinator Vpn { get; init; }
    public required SetupWizardState State { get; init; }
}

/// <summary>
/// 首次設定精靈 6 個步驟的實際動作（Windows 專用：外部指令、下載、登錄）。判斷規則都在 Core（可在 macOS 測試），
/// 這裡只負責執行與把輸出接到精靈畫面。所有 wsl.exe／引擎呼叫都透過 VpnCoordinator.RunExclusiveAsync，
/// 跟輪詢、連線共用「一次一個」的機制。
/// </summary>
internal static class WizardSteps
{
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan InstallTimeout = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan ImportTimeout = TimeSpan.FromMinutes(20);
    private static readonly TimeSpan WslQuickTimeout = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan ReadIdleTimeout = TimeSpan.FromSeconds(60);
    private const string Busy = "首次設定精靈執行中…";

    private static int Build => Environment.OSVersion.Version.Build;

    /// <summary>精靈要用的 wsl.exe：Store 版優先；沒有時用 System32 的（較舊的 MSIX 版 Store WSL 經由它轉送）。</summary>
    private static string WslExe => File.Exists(AppPaths.StoreWslExe) ? AppPaths.StoreWslExe : AppPaths.SystemWslExe;

    // MARK: 探測

    private static async Task<WslProbe?> ProbeAsync(WizardContext c, CancellationToken ct)
    {
        var r = await CommandRunner.RunAsync(AppPaths.PowerShellExe,
            // -EncodedCommand（UTF-16LE base64）：指令稿不經命令列的引號跳脫，內容原樣送達
            ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
             Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(WslInstallState.ProbeScript))],
            ProbeTimeout, c.Output, ct, display: "powershell.exe （查詢 Windows 版本、虛擬化、WSL 元件與服務）");
        if (!EngineOutput.Parse(r.Lines).ContainsKey("RESULT"))
        {
            c.Output(r.Describe("查詢系統狀態"));
            return null;
        }
        return WslInstallState.ParseProbe(r.Lines);
    }

    // MARK: 1 系統檢查

    public static async Task<StepResult> SystemCheckAsync(WizardContext c, CancellationToken ct)
    {
        var probe = await ProbeAsync(c, ct);
        var items = SystemRequirements.Evaluate(Build, RuntimeInformation.OSArchitecture,
            probe?.HypervisorPresent, probe?.VirtualizationFirmwareEnabled);
        foreach (var i in items)
            c.Output((i.Level switch { CheckLevel.Ok => "✔ ", CheckLevel.Warning => "⚠ ", _ => "✖ " }) + i.Text);
        if (!SystemRequirements.Passed(items))
            return StepResult.Fail(string.Join("\n", items.Where(i => i.Level == CheckLevel.Error).Select(i => i.Text)));
        // 純檢查，沒有改變環境：記為略過（不會讓後面的步驟重做）
        return new(StepOutcome.Skipped);
    }

    // MARK: 2 安裝 WSL

    public static async Task<StepResult> InstallWslAsync(WizardContext c, CancellationToken ct)
    {
        var probe = await ProbeAsync(c, ct);
        if (probe is null) return StepResult.Fail("查不到 WSL 狀態（詳見輸出區），請按「重試」");
        c.Output(WslInstallState.Describe(probe));
        var readiness = WslInstallState.Evaluate(probe, Build, c.State.RebootedSinceInstall);
        if (readiness == WslReadiness.Ready)
        {
            c.Output("WSL 已安裝且可以使用，略過");
            return new(StepOutcome.Skipped);
        }
        if (readiness == WslReadiness.NeedReboot)
        {
            c.Output("WSL 需要的 Windows 元件已啟用，要重新開機才會生效");
            return new(StepOutcome.WaitingReboot);
        }

        // 只用 --no-distribution：發行版由下一步自己匯入（不需要建立帳號）；--web-download 從 GitHub 下載、不經 Microsoft Store
        // （內建 Administrator 帳號用 Store 會卡住）。不自動 --update。
        var (started, r) = await c.Vpn.RunExclusiveAsync(Busy + "安裝 WSL", () =>
            CommandRunner.RunAsync(AppPaths.SystemWslExe, ["--install", "--no-distribution", "--web-download"],
                InstallTimeout, c.Output, CancellationToken.None));
        if (!started) return StepResult.Fail("目前有連線／斷線動作在進行中，請稍候按「重試」");
        // 3010＝ERROR_SUCCESS_REBOOT_REQUIRED；WSL 目前需要重開機時結束碼仍是 0（見 tray3-research.md），
        // 所以結束碼只用來判斷「明確失敗」，要不要重開機一律看安裝後的元件狀態
        if (r!.ExitCode is not (0 or 3010)) return StepResult.Fail(r.Describe("wsl --install"));

        var after = await ProbeAsync(c, ct);
        if (after is null)
        {
            c.Output("安裝後查不到元件狀態：保守起見請重新開機");
            return new(StepOutcome.WaitingReboot);
        }
        c.Output(WslInstallState.Describe(after));
        return WslInstallState.Evaluate(after, Build, rebootedSinceInstall: false) switch
        {
            WslReadiness.Ready => new(StepOutcome.Done),
            WslReadiness.NeedReboot => new(StepOutcome.WaitingReboot),
            _ => StepResult.Fail("wsl --install 執行完了，但仍偵測不到 WSL（詳見輸出區）。可以按「重試」，或手動執行 wsl --install --no-distribution"),
        };
    }

    // MARK: 3 下載並匯入發行版

    /// <summary>
    /// wsl -l -q：回傳已安裝的發行版；查不到時回 null（規則見 DistroPlan.ResolveInstalled：
    /// wsl 回非 0 時只有登錄確認一個發行版都沒有，才當成空清單）。
    /// </summary>
    private static async Task<IReadOnlyList<string>?> ListDistrosAsync(WizardContext c, CancellationToken ct)
    {
        var r = await CommandRunner.RunAsync(WslExe, ["-l", "-q"], WslQuickTimeout, c.Output, ct);
        if (r.Ok) return WslDistros.ParseList(r.Lines);
        var reg = ReadRegisteredDistros();
        c.Output(reg switch
        {
            null => "wsl -l -q 失敗，登錄也讀不到發行版清單",
            { Count: 0 } => "wsl -l -q 回非 0，登錄確認沒有任何發行版",
            _ => $"wsl -l -q 失敗，但登錄裡有 {reg.Count} 個發行版（WSL 可能暫時異常）",
        });
        return DistroPlan.ResolveInstalled(false, [], reg);
    }

    /// <summary>
    /// 登錄 HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss 底下每個發行版一個子機碼、值 DistributionName
    /// （WSL 原始碼 registry::OpenLxssUserKey 讀的同一個位置）。機碼不存在＝從沒註冊過發行版；讀取失敗回 null。
    /// </summary>
    private static IReadOnlyList<string>? ReadRegisteredDistros()
    {
        try
        {
            using var lxss = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss");
            if (lxss is null) return [];
            var names = new List<string>();
            foreach (var sub in lxss.GetSubKeyNames())
            {
                using var k = lxss.OpenSubKey(sub);
                if (k?.GetValue("DistributionName") is string n && n.Length > 0) names.Add(n);
            }
            return names;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            AppLog.Error($"讀取 WSL 登錄失敗：{ex.Message}");
            return null;
        }
    }

    private const string SwitchBlocked =
        "VPN 目前已連線（或正在自動重連），不能切換 WSL 發行版：之後的斷線會找不到原本的通道。請先從托盤選單按「斷線」，再按「重試」";

    /// <summary>
    /// App 啟動時用：設定的發行版是否存在。沒有 Store 版 wsl.exe、有動作進行中、或 wsl -l 回非 0 時為 null（不據此開精靈）：
    /// 非 0 可能是「沒有任何發行版」，也可能是 WSL 服務暫時異常，分不出來就不自動開（設定不完整時另有條件會開）。
    /// 透過 RunExclusiveAsync 執行，不跟啟動時的第一次輪詢同時跑 wsl.exe。
    /// </summary>
    public static async Task<bool?> DistroExistsAsync(VpnCoordinator vpn, string distro)
    {
        if (!File.Exists(AppPaths.StoreWslExe)) return null;
        var (started, r) = await vpn.RunExclusiveAsync("檢查 WSL 發行版…", () =>
            CommandRunner.RunAsync(AppPaths.StoreWslExe, ["-l", "-q"], WslQuickTimeout, null));
        if (!started || !r!.Ok) return null;
        return WslDistros.Contains(WslDistros.ParseList(r.Lines), distro);
    }

    public static async Task<StepResult> ImportDistroAsync(WizardContext c, CancellationToken ct)
    {
        var configured = c.Vpn.Settings.Distro;
        var vhdx = Path.Combine(AppPaths.WslDir, "ext4.vhdx");
        var (started, installed) = await c.Vpn.RunExclusiveAsync(Busy + "查詢 WSL 發行版", () => ListDistrosAsync(c, CancellationToken.None));
        if (!started) return StepResult.Fail("目前有連線／斷線動作在進行中，請稍候按「重試」");
        var plan = DistroPlan.Decide(configured, installed, File.Exists(vhdx));
        if (plan == DistroAction.QueryFailed)
            return StepResult.Fail("查不到已安裝的 WSL 發行版清單（詳見輸出區）。為避免誤判，不會下載或改用新的發行版；請稍候按「重試」");
        if (plan != DistroAction.UseConfigured && !DistroPlan.CanSwitchDistro(c.Vpn.IsUp, c.Vpn.WantConnected))
            return StepResult.Fail(SwitchBlocked);
        if (DistroPlan.LegacyCoexistNote(configured, installed!, plan) is { } note) c.Output(note);
        switch (plan)
        {
            case DistroAction.UseConfigured:
                c.Output($"發行版 {configured} 已存在，略過");
                return new(StepOutcome.Skipped);
            case DistroAction.UseExistingSplitSwan:
                c.Output($"設定的 {configured} 不存在，改用已存在的 {WslDistros.SplitSwan}");
                return SaveDistro(c, WslDistros.SplitSwan) ?? new(StepOutcome.Done);
            case DistroAction.ImportInPlace:
            {
                c.Output($"{vhdx} 已存在（之前匯入過），直接重新註冊，不覆蓋資料");
                var (s2, r) = await c.Vpn.RunExclusiveAsync(Busy + "匯入發行版", () =>
                    CommandRunner.RunAsync(WslExe, ["--import-in-place", WslDistros.SplitSwan, vhdx], ImportTimeout, c.Output, CancellationToken.None));
                if (!s2) return StepResult.Fail("目前有連線／斷線動作在進行中，請稍候按「重試」");
                if (!r!.Ok) return StepResult.Fail(r.Describe("wsl --import-in-place") + $"。若不需要舊資料，可先把 {vhdx} 移走再重試");
                return await FinishImportAsync(c, ct);
            }
        }

        // 下載並匯入
        if (RuntimeInformation.OSArchitecture != Architecture.X64)
            return StepResult.Fail("只支援 x64 Windows（ARM64 沒有對應的映像）");
        c.Downloading?.Invoke(true);
        DownloadedFile file;
        try { file = await DownloadImageAsync(c, ct); }
        finally { c.Downloading?.Invoke(false); }
        if (file.Error is not null) return StepResult.Fail(file.Error);
        // 下載剛結束、按鈕還沒隱藏前使用者可能按了取消或關閉視窗：不再往下匯入
        if (ct.IsCancellationRequested) return StepResult.Fail("已取消");

        Directory.CreateDirectory(AppPaths.WslDir);
        var (s3, imp) = await c.Vpn.RunExclusiveAsync(Busy + "匯入發行版", () =>
            CommandRunner.RunAsync(WslExe, ["--import", WslDistros.SplitSwan, AppPaths.WslDir, file.Path!, "--version", "2"],
                ImportTimeout, c.Output, CancellationToken.None));
        if (!s3) return StepResult.Fail("目前有連線／斷線動作在進行中，請稍候按「重試」");
        if (!imp!.Ok)
            return StepResult.Fail(imp.Describe("wsl --import") + "（下載檔保留在 " + file.Path + "，重試時不必重新下載）");
        // 匯入成功才刪下載檔（契約 6）
        TryDelete(file.Path!, c);
        return await FinishImportAsync(c, ct);
    }

    /// <summary>匯入後：預設使用者設為 root（保險，見 tray3-research.md）、重啟發行版、確認清單裡有它、存進設定。</summary>
    private static async Task<StepResult> FinishImportAsync(WizardContext c, CancellationToken ct)
    {
        var name = WslDistros.SplitSwan;
        var (started, ok) = await c.Vpn.RunExclusiveAsync(Busy + "設定發行版", async () =>
        {
            var r = await CommandRunner.RunAsync(WslExe, ["-d", name, "-u", "root", "--exec", "sh", "-c", WslDistros.DefaultRootScript],
                WslQuickTimeout, c.Output, CancellationToken.None, display: $"wsl.exe -d {name} -u root --exec sh -c （/etc/wsl.conf 寫入 [user] default=root）");
            if (!r.Ok) return r.Describe("設定預設使用者");
            await CommandRunner.RunAsync(WslExe, ["--terminate", name], WslQuickTimeout, c.Output, CancellationToken.None);
            var list = await ListDistrosAsync(c, CancellationToken.None);
            if (list is null) return "匯入後查不到發行版清單，請按「重試」確認";
            return WslDistros.Contains(list, name) ? null : $"匯入後的清單裡找不到 {name}";
        });
        if (!started) return StepResult.Fail("目前有連線／斷線動作在進行中，請稍候按「重試」");
        if (ok is not null) return StepResult.Fail(ok);
        c.Output($"發行版 {name} 已就緒（預設使用者 root）");
        return SaveDistro(c, name) ?? new(StepOutcome.Done);
    }

    private static StepResult? SaveDistro(WizardContext c, string distro)
    {
        // 匯入期間使用者可能從托盤連上了：再檢查一次
        if (!string.Equals(c.Vpn.Settings.Distro, distro, StringComparison.OrdinalIgnoreCase)
            && !DistroPlan.CanSwitchDistro(c.Vpn.IsUp, c.Vpn.WantConnected))
            return StepResult.Fail(SwitchBlocked);
        var s = c.Vpn.Settings with { Distro = distro };
        try
        {
            SettingsStore.Save(s);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException)
        {
            return StepResult.Fail($"無法儲存設定（發行版名稱）：{ex.Message}");
        }
        c.Vpn.UpdateSettings(s);
        AppLog.Info($"設定的 WSL 發行版改為 {distro}");
        return null;
    }

    private sealed record DownloadedFile(string? Path, string? Error);

    /// <summary>讀 SHA256SUMS → 挑最新的 24.04.N → 下載（邊下載邊算 SHA256）→ 比對；不符就刪檔報錯。</summary>
    private static async Task<DownloadedFile> DownloadImageAsync(WizardContext c, CancellationToken ct)
    {
        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("SplitSwan", Application.ProductVersion.Split('+')[0]));

        string sums;
        c.Output("> GET " + UbuntuWslImages.SumsUrl);
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(60));
            using var resp = await http.GetAsync(UbuntuWslImages.SumsUrl, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false);
            resp.EnsureSuccessStatusCode();
            if (resp.Content.Headers.ContentLength > UbuntuWslImages.MaxSumsBytes) return new(null, "SHA256SUMS 大小異常，已停止");
            await using var s = await resp.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
            var buf = new byte[UbuntuWslImages.MaxSumsBytes + 1];
            int n = 0, read;
            while (n < buf.Length && (read = await s.ReadAsync(buf.AsMemory(n), cts.Token).ConfigureAwait(false)) > 0) n += read;
            if (n > UbuntuWslImages.MaxSumsBytes) return new(null, "SHA256SUMS 大小異常，已停止");
            sums = System.Text.Encoding.UTF8.GetString(buf, 0, n);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { return new(null, "已取消下載"); }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or IOException)
        {
            return new(null, $"無法取得 {UbuntuWslImages.SumsUrl}：{ex.Message}");
        }
        var img = UbuntuWslImages.Latest(sums);
        if (img is null) return new(null, "SHA256SUMS 裡找不到 ubuntu-24.04.N-wsl-amd64.wsl");
        c.Output($"最新的 WSL 映像：{img.FileName}（SHA256 {img.Sha256}）");

        Directory.CreateDirectory(AppPaths.DownloadDir);
        var final = Path.Combine(AppPaths.DownloadDir, img.FileName);
        var part = final + ".part";

        c.Output("> GET " + img.Url);
        try
        {
            // 上次下載完但匯入失敗留下的檔：雜湊對就直接用，不對就刪掉重抓
            if (File.Exists(final))
            {
                c.Output($"找到先前下載的 {img.FileName}，檢查 SHA256…");
                byte[] h;
                await using (var fs = File.OpenRead(final)) h = await SHA256.HashDataAsync(fs, ct).ConfigureAwait(false);
                if (UbuntuWslImages.HashMatches(img.Sha256, h)) { c.Output("SHA256 相符，沿用（不重新下載）"); return new(final, null); }
                c.Output("SHA256 不符，刪除後重新下載");
                TryDelete(final, c);
            }

            // 閒置逾時：每次讀取前重設，60 秒收不到任何資料就中止（網路半斷時不會永遠等下去）
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(ct);
            idle.CancelAfter(ReadIdleTimeout);
            using var resp = await http.GetAsync(img.Url, HttpCompletionOption.ResponseHeadersRead, idle.Token).ConfigureAwait(false);
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength;
            var drive = new DriveInfo(Path.GetPathRoot(AppPaths.DataDir)!);
            var need = UbuntuWslImages.RequiredFreeBytes(total ?? 400L * 1024 * 1024);
            if (drive.AvailableFreeSpace < need)
                return new(null, $"磁碟 {drive.Name} 空間不足：需要約 {need / 1024 / 1024 / 1024 + 1} GB，剩 {drive.AvailableFreeSpace / 1024 / 1024} MB");

            using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var src = await resp.Content.ReadAsStreamAsync(idle.Token).ConfigureAwait(false))
            await using (var dst = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
            {
                var buf = new byte[1 << 16];
                long done = 0;
                var lastReport = DateTime.MinValue;
                int read;
                while (true)
                {
                    idle.CancelAfter(ReadIdleTimeout);
                    read = await src.ReadAsync(buf, idle.Token).ConfigureAwait(false);
                    if (read <= 0) break;
                    await dst.WriteAsync(buf.AsMemory(0, read), ct).ConfigureAwait(false);
                    hasher.AppendData(buf, 0, read);
                    done += read;
                    if (DateTime.UtcNow - lastReport > TimeSpan.FromMilliseconds(250))
                    {
                        lastReport = DateTime.UtcNow;
                        c.Progress?.Invoke(done, total);
                    }
                }
                c.Progress?.Invoke(done, total);
                if (total is { } t && done != t) throw new IOException($"下載不完整（{done} / {t} bytes）");
            }
            var hash = hasher.GetHashAndReset();
            if (!UbuntuWslImages.HashMatches(img.Sha256, hash))
            {
                TryDelete(part, c);
                return new(null, $"下載檔的 SHA256（{Convert.ToHexString(hash).ToLowerInvariant()}）與 SHA256SUMS 不符，已刪除。請按「重試」重新下載");
            }
            File.Move(part, final, overwrite: true);
            c.Output("下載完成，SHA256 相符");
            return new(final, null);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            TryDelete(part, c);
            return new(null, "已取消下載");
        }
        catch (OperationCanceledException)
        {
            TryDelete(part, c);
            return new(null, $"下載失敗：{(int)ReadIdleTimeout.TotalSeconds} 秒沒有收到資料，請檢查網路後按「重試」");
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or UnauthorizedAccessException)
        {
            TryDelete(part, c);
            return new(null, $"下載失敗：{ex.Message}");
        }
    }

    /// <summary>只刪精靈自己下載的檔（download\ 底下的映像與 .part）。</summary>
    private static void TryDelete(string path, WizardContext c)
    {
        try
        {
            if (!File.Exists(path)) return;
            File.Delete(path);
            c.Output("已刪除 " + path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            c.Output($"刪除 {path} 失敗：{ex.Message}");
        }
    }

    // MARK: 4 安裝 strongSwan

    public static async Task<StepResult> SetupStrongSwanAsync(WizardContext c, CancellationToken ct)
    {
        var distro = c.Vpn.Settings.Distro;
        var (started, r) = await c.Vpn.RunExclusiveAsync(Busy + "安裝 strongSwan", () =>
            EngineRunner.RunAsync(EngineAction.Setup, distro, onLine: c.Output));
        if (!started) return StepResult.Fail("目前有連線／斷線動作在進行中，請稍候按「重試」");
        if (r!.Ok) return new(StepOutcome.Done);
        if (EngineCommand.IsInstallNeeded(r.Error, r.Lines))
            return StepResult.Fail($"發行版 {distro} 不存在：請按「上一步」重新執行「下載並匯入 Ubuntu」");
        return StepResult.Fail(r.Error ?? "安裝 strongSwan 失敗");
    }

    // MARK: 5 設定

    public static StepResult CheckConfigured(WizardContext c)
    {
        var errors = ConfWriter.Validate(c.Vpn.Settings);
        if (errors.Count == 0)
        {
            c.Output("VPN 設定已填好，略過");
            return new(StepOutcome.Skipped);
        }
        c.Output("尚未設定：" + string.Join("；", errors));
        return new(StepOutcome.WaitingUser);
    }

    // MARK: 6 測試連線

    public static async Task<StepResult> TestConnectionAsync(WizardContext c)
    {
        // 連線經過 VpnCoordinator（跟選單「連線（自動選擇）」同一條路），輸出從 App 記錄轉到精靈畫面
        void OnLine(string line) => c.Output(line);
        AppLog.LineAdded += OnLine;
        try
        {
            var (ok, gw, vip, error) = await c.Vpn.ConnectForWizardAsync();
            if (!ok) return StepResult.Fail(error ?? "連線失敗");
            c.Output($"✔ 已連線：閘道 {gw?.ToUpperInvariant() ?? "?"}，虛擬 IP {vip ?? "?"}");
            return new(StepOutcome.Done);
        }
        finally
        {
            AppLog.LineAdded -= OnLine;
        }
    }
}
