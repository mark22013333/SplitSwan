using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 檢查更新與一鍵更新（對應 Mac 版 UpdateCenter）：設定頁的「更新」區塊與托盤選單共用同一個實例。
/// 安裝流程：查 release 列表 → 下載 zip 與 .sig → 用內建公鑰驗證 Ed25519 簽章 → 解壓到 %TEMP% 專屬資料夾（防 zip slip）→
/// 檢查內容與 exe 版本（必須等於 release 版本且比目前新）→ 逐檔把舊檔改名為 *.old、移入新檔（失敗就還原）→
/// 啟動新版並結束自己。為更新而結束時不斷線：新版啟動後由 VpnCoordinator 接手既有通道。
/// 所有公開方法與事件都在 UI 執行緒上執行。
/// </summary>
internal sealed class UpdateCenter : IDisposable
{
    /// <summary>目前版本（X.Y.Z）。要宣告在 Http 之前：靜態初始化依原始碼順序執行，CreateHttp 會用到它。</summary>
    public static string CurrentVersion { get; } =
        UpdateRules.NormalizeVersion(Application.ProductVersion) ?? Application.ProductVersion.Split('+')[0];

    private static readonly HttpClient Http = CreateHttp();

    private readonly VpnCoordinator _vpn;
    private readonly Action<StoredSettings> _applySettings;
    private readonly Action _exitForUpdate;
    private readonly System.Windows.Forms.Timer _hourly = new() { Interval = 60 * 60 * 1000 };
    private readonly System.Windows.Forms.Timer _first = new() { Interval = 60 * 1000 };
    private bool _disposed;

    /// <summary>狀態改變（設定頁與托盤選單重畫）。</summary>
    public event Action? Changed;
    /// <summary>自動檢查發現新版本（每個版本只通知一次）：托盤顯示氣泡。</summary>
    public event Action<string>? NewVersionNotice;

    /// <param name="applySettings">「每天自動檢查更新」寫入 settings.json 後套用到 VpnCoordinator。</param>
    /// <param name="exitForUpdate">新版已啟動：結束目前的 App（不斷線）。</param>
    public UpdateCenter(VpnCoordinator vpn, Action<StoredSettings> applySettings, Action exitForUpdate)
    {
        _vpn = vpn;
        _applySettings = applySettings;
        _exitForUpdate = exitForUpdate;
        _hourly.Tick += (_, _) => AutoCheckIfDue();
        _first.Tick += (_, _) => { _first.Stop(); AutoCheckIfDue(); };
    }

    public bool IsChecking { get; private set; }
    public bool IsInstalling { get; private set; }
    /// <summary>最近一次檢查找到的版本最高的 Windows release；還沒檢查或檢查失敗為 null。</summary>
    public UpdateRelease? Latest { get; private set; }
    /// <summary>最近一次檢查的結果文字（例：目前已是最新版本）；失敗時是原因。</summary>
    public string? CheckMessage { get; private set; }
    public bool CheckFailed { get; private set; }
    /// <summary>安裝進度或失敗原因；沒有在安裝也沒有失敗為 null。</summary>
    public string? InstallMessage { get; private set; }
    public bool InstallFailed { get; private set; }

    /// <summary>有比目前新的版本（托盤選單最上方顯示）。</summary>
    public string? NewerVersion => Latest is { } r && UpdateRules.IsNewer(r.Version, CurrentVersion) ? r.Version : null;
    /// <summary>新版本附有可自動安裝的檔案。</summary>
    public bool CanInstall => NewerVersion is not null && Latest?.Assets is not null && !IsInstalling;

    public bool AutoCheckEnabled => _vpn.Settings.AutoCheckUpdates;

    // MARK: 每日自動檢查

    /// <summary>啟動後呼叫：有勾選才會連網。每小時看一次是否已滿 24 小時；開機登入時網路可能還沒好，第一次晚一分鐘。</summary>
    public void StartAutoCheck()
    {
        _hourly.Start();
        _first.Start();
    }

    public void AutoCheckIfDue()
    {
        if (_disposed || IsChecking || IsInstalling) return;
        if (!UpdateRules.ShouldAutoCheck(AutoCheckEnabled, UpdateCheckStore.Load().LastCheck, DateTimeOffset.Now)) return;
        _ = CheckAsync(auto: true);
    }

    /// <summary>切換「每天自動檢查更新」：立即寫入 settings.json（不用按「儲存」）。回傳錯誤訊息，成功回 null。</summary>
    public string? SetAutoCheck(bool on)
    {
        var s = _vpn.Settings with { AutoCheckUpdates = on };
        if (s == _vpn.Settings) return null;
        try
        {
            SettingsStore.Save(s);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
                                       or System.Security.Cryptography.CryptographicException)
        {
            AppLog.Error($"「每天自動檢查更新」寫入失敗：{ex.GetType().Name}：{ex.Message}");
            return $"無法儲存設定：{ex.Message}";
        }
        AppLog.Info(on ? "每天自動檢查更新：開啟" : "每天自動檢查更新：關閉");
        _applySettings(s);
        if (on) AutoCheckIfDue();
        RaiseChanged();
        return null;
    }

    // MARK: 檢查

    public void CheckNow()
    {
        if (IsChecking || IsInstalling) return;
        _ = CheckAsync(auto: false);
    }

    private async Task CheckAsync(bool auto)
    {
        IsChecking = true;
        CheckMessage = "檢查中…";
        CheckFailed = false;
        RaiseChanged();
        try
        {
            var release = await FetchLatestAsync();
            if (_disposed) return;
            UpdateCheckStore.SaveLastCheck(DateTimeOffset.Now);
            Latest = release;
            if (release is null)
            {
                CheckMessage = "GitHub 上還沒有 Windows 版的發布";
            }
            else if (UpdateRules.IsNewer(release.Version, CurrentVersion))
            {
                CheckMessage = release.Assets is null
                    ? $"有新版本 {release.Version}，但沒有附上可自動安裝的檔案，請按「前往下載」手動更新"
                    : $"有新版本 {release.Version}";
                AppLog.Info($"檢查更新：有新版本 {release.Version}（目前 {CurrentVersion}）" + (auto ? "（自動檢查）" : ""));
                if (auto && UpdateCheckStore.Load().NotifiedVersion != release.Version)
                {
                    UpdateCheckStore.SaveNotified(release.Version);
                    NewVersionNotice?.Invoke(release.Version);
                }
            }
            else
            {
                CheckMessage = $"目前已是最新版本（{CurrentVersion}）";
                if (!auto) AppLog.Info("檢查更新：已是最新版本");
            }
        }
        catch (UpdateException ex)
        {
            if (_disposed) return;
            CheckFailed = true;
            CheckMessage = ex.Message;
            AppLog.Info("檢查更新失敗：" + ex.Message);
        }
        catch (Exception ex)
        {
            // 呼叫端不 await（fire-and-forget）：未預期的例外在這裡記錄，不默默消失
            AppLog.Error($"檢查更新發生未預期的錯誤：{ex.GetType().Name}：{ex.Message}");
            if (_disposed) return;
            CheckFailed = true;
            CheckMessage = $"檢查更新時發生錯誤：{ex.Message}";
        }
        finally
        {
            IsChecking = false;
            RaiseChanged();
        }
    }

    private static async Task<UpdateRelease?> FetchLatestAsync()
    {
        var json = await GetBytesAsync(new Uri(UpdateRules.ReleasesApi), UpdateRules.MaxReleaseListBytes,
            accept: "application/vnd.github+json", timeout: TimeSpan.FromSeconds(30));
        return UpdateRules.PickLatest(Encoding.UTF8.GetString(json));
    }

    // MARK: 一鍵更新

    /// <summary>開啟 release 頁面（前往下載）。</summary>
    public void OpenReleasePage()
    {
        var url = Latest is { } r ? r.PageUrl : UpdateRules.ReleasesPage;
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException)
        {
            AppLog.Error($"無法開啟瀏覽器：{ex.Message}");
            InstallFailed = true;
            InstallMessage = $"無法開啟瀏覽器，請手動前往 {url}";
            RaiseChanged();
        }
    }

    /// <summary>安裝資料夾不能更新的原因；可以更新回 null。</summary>
    private static string? InstallBlocker(string installDir)
    {
        var exe = Environment.ProcessPath;
        if (exe is null || !string.Equals(Path.GetFileName(exe), UpdatePackage.ExeName, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(Path.GetFullPath(Path.GetDirectoryName(exe)!).TrimEnd(Path.DirectorySeparatorChar),
                              Path.GetFullPath(installDir).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
            return "目前不是從 SplitSwan.exe 執行，請到 GitHub 下載後手動更新";
        if (!Directory.Exists(AppPaths.EngineDir)) return "安裝資料夾裡找不到 engine 資料夾，請到 GitHub 下載完整版本手動更新";
        try
        {
            // 實際建一個檔案確認可寫入（ACL、唯讀媒體、OneDrive 等情況都能涵蓋）；關閉時自動刪除
            using var probe = new FileStream(Path.Combine(installDir, $".splitswan-write-test-{Guid.NewGuid():N}"),
                FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return $"沒有權限寫入安裝資料夾（{installDir}），請到 GitHub 下載後手動覆蓋";
        }
        return null;
    }

    /// <summary>下載並安裝最新版本；成功時啟動新版並結束目前的 App。</summary>
    public async void InstallLatest()
    {
        if (IsInstalling || _disposed) return;
        IsInstalling = true;
        InstallFailed = false;
        try
        {
            var installDir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            if (InstallBlocker(installDir) is { } why) throw new UpdateException(why);

            Progress("查詢最新版本…");
            var release = await FetchLatestAsync() ?? throw new UpdateException("GitHub 上找不到 Windows 版的發布");
            Latest = release;
            if (!UpdateRules.IsNewer(release.Version, CurrentVersion)) throw new UpdateException($"目前已是最新版本（{CurrentVersion}）");
            if (release.Assets is not { } assets)
                throw new UpdateException("最新版本沒有附上可自動安裝的檔案，請按「前往下載」手動更新");

            Progress($"下載 {release.Version}…");
            var zip = await GetBytesAsync(assets.Zip, UpdateRules.MaxDownloadBytes, timeout: TimeSpan.FromMinutes(10));
            var sig = await GetBytesAsync(assets.Sig, 4096, timeout: TimeSpan.FromSeconds(60));
            Progress("驗證簽章…");
            if (!UpdateRules.VerifySignature(zip, Encoding.UTF8.GetString(sig)))
                throw new UpdateException("簽章驗證失敗，已停止安裝。請到 GitHub 確認發布內容");

            Progress("檢查安裝檔…");
            var work = Path.Combine(Path.GetTempPath(), $"SplitSwan-update-{Guid.NewGuid():N}");
            var stage = Path.Combine(work, "stage");
            var files = await Task.Run(() =>
            {
                using var ms = new MemoryStream(zip, writable: false);
                return UpdatePackage.Extract(ms, stage);
            });
            if (UpdatePackage.CheckLayout([.. files]) is { } layoutError) throw new UpdateException(layoutError);
            var stagedRoot = Path.Combine(stage, UpdatePackage.Root);
            var newExe = Path.Combine(stagedRoot, UpdatePackage.ExeName);
            var info = FileVersionInfo.GetVersionInfo(newExe);
            if (UpdateRules.ValidateExeVersion(info.FileVersion, info.ProductVersion, release.Version, CurrentVersion) is { } versionError)
                throw new UpdateException(versionError);
            if (_disposed) return;

            // 替換與啟動新版期間不能有引擎程序在跑（輪詢、連線、精靈都讓路）
            var items = UpdatePackage.InstallItems(files);
            var (started, error) = await _vpn.RunExclusiveAsync("安裝更新中…", () => Task.FromResult(SwapAndLaunch(installDir, stagedRoot, items, release.Version)));
            if (!started) throw new UpdateException("目前有連線／斷線或首次設定的動作在進行中，請等它完成再更新");
            if (error is not null) throw new UpdateException(error);

            AppLog.Info($"已安裝 {release.Version} 並啟動新版，結束目前的 App（VPN 通道保留，由新版接手）");
            Progress("重新啟動中…");
            _exitForUpdate();
        }
        catch (Exception ex) when (ex is UpdateException or IOException or UnauthorizedAccessException)
        {
            if (_disposed) return;
            AppLog.Error("一鍵更新失敗：" + ex.Message);
            InstallFailed = true;
            InstallMessage = ex.Message;
            IsInstalling = false;
            RaiseChanged();
        }
        catch (Exception ex)
        {
            // async void：不讓未預期的例外結束 App
            AppLog.Error($"一鍵更新發生未預期的錯誤：{ex.GetType().Name}：{ex.Message}");
            if (_disposed) return;
            InstallFailed = true;
            InstallMessage = $"更新時發生錯誤：{ex.Message}";
            IsInstalling = false;
            RaiseChanged();
        }
    }

    /// <summary>逐檔替換並啟動新版；新版啟動失敗就還原。回傳錯誤訊息，成功回 null。</summary>
    private static string? SwapAndLaunch(string installDir, string stagedRoot, IReadOnlyList<string> items, string version)
    {
        UpdatePackage.SwapRecord record;
        try { record = UpdatePackage.Swap(installDir, stagedRoot, items); }
        catch (UpdateException ex) { return ex.Message; }
        AppLog.Info($"已替換 {record.Replaced.Count} 個檔案為 {version}");
        try
        {
            var exe = Path.Combine(installDir, UpdatePackage.ExeName);
            // UseShellExecute：新版的 manifest 要求系統管理員；目前已是系統管理員，不會再跳 UAC
            using var p = Process.Start(new ProcessStartInfo(exe)
            {
                UseShellExecute = true,
                WorkingDirectory = installDir,
                Arguments = UpdateRules.AfterUpdateArgument,
            });
            if (p is null) throw new InvalidOperationException("沒有啟動任何程序");
            return null;
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or IOException)
        {
            var failed = UpdatePackage.Revert(record);
            AppLog.Error($"新版啟動失敗：{ex.Message}" + (failed.Count > 0 ? $"；還原失敗：{string.Join("、", failed)}" : "，已還原"));
            return failed.Count == 0
                ? $"無法啟動新版（{ex.Message}），已還原為目前版本"
                : $"無法啟動新版（{ex.Message}），且還原失敗：{string.Join("、", failed)}。請到 GitHub 下載完整版本手動覆蓋";
        }
    }

    private void Progress(string text)
    {
        InstallMessage = text;
        RaiseChanged();
    }

    // MARK: 連網

    private static HttpClient CreateHttp()
    {
        var h = new HttpClient(new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.All })
        {
            Timeout = Timeout.InfiniteTimeSpan,   // 每個請求自己限時
        };
        h.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("SplitSwan-Windows", CurrentVersion));
        return h;
    }

    /// <summary>GET 並限制大小；任何網路錯誤都轉成繁中的 UpdateException。</summary>
    private static async Task<byte[]> GetBytesAsync(Uri url, long maxBytes, TimeSpan timeout, string? accept = null)
    {
        using var cts = new CancellationTokenSource(timeout);
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        if (accept is not null) req.Headers.Accept.ParseAdd(accept);
        req.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        try
        {
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            if (resp.StatusCode != HttpStatusCode.OK)
                throw new UpdateException(resp.StatusCode == HttpStatusCode.Forbidden
                    ? "GitHub 暫時拒絕查詢（HTTP 403，可能是查詢次數過多），請稍後再試"
                    : $"下載失敗（HTTP {(int)resp.StatusCode}）");
            if (resp.Content.Headers.ContentLength is { } len && len > maxBytes)
                throw new UpdateException("下載的檔案大小異常，已停止");
            await using var stream = await resp.Content.ReadAsStreamAsync(cts.Token);
            using var ms = new MemoryStream();
            var buf = new byte[81920];
            int n;
            while ((n = await stream.ReadAsync(buf, cts.Token)) > 0)
            {
                if (ms.Length + n > maxBytes) throw new UpdateException("下載的檔案大小異常，已停止");
                ms.Write(buf, 0, n);
            }
            return ms.ToArray();
        }
        catch (OperationCanceledException) { throw new UpdateException("連線 GitHub 逾時，請稍後再試"); }
        catch (HttpRequestException) { throw new UpdateException("無法連線到 GitHub，請確認網路後再試"); }
        catch (IOException) { throw new UpdateException("下載中斷，請稍後再試"); }
    }

    private void RaiseChanged()
    {
        if (!_disposed) Changed?.Invoke();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _hourly.Dispose();
        _first.Dispose();
    }
}

/// <summary>
/// 檢查更新的紀錄（%LOCALAPPDATA%\SplitSwan\update-check.json，非機密）：上次檢查時間與已通知過的版本。
/// 不放進 settings.json：每次檢查都重寫 settings.json 會連帶重寫加密的密碼欄位。
/// </summary>
internal static class UpdateCheckStore
{
    public sealed record State(DateTimeOffset? LastCheck, string? NotifiedVersion);

    public static State Load()
    {
        try
        {
            if (!File.Exists(AppPaths.UpdateCheckFile)) return new(null, null);
            if (JsonNode.Parse(File.ReadAllText(AppPaths.UpdateCheckFile, Encoding.UTF8)) is not JsonObject o) return new(null, null);
            DateTimeOffset? last = o["lastCheck"] is JsonValue v && v.TryGetValue<string>(out var s)
                && DateTimeOffset.TryParse(s, System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.RoundtripKind, out var d) ? d : null;
            var notified = o["notifiedVersion"] is JsonValue n && n.TryGetValue<string>(out var ns) ? ns : null;
            return new(last, notified);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            return new(null, null);
        }
    }

    public static void SaveLastCheck(DateTimeOffset when) => Save(Load() with { LastCheck = when });

    public static void SaveNotified(string version) => Save(Load() with { NotifiedVersion = version });

    private static void Save(State st)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            var o = new JsonObject
            {
                ["lastCheck"] = st.LastCheck?.ToString("O", System.Globalization.CultureInfo.InvariantCulture),
                ["notifiedVersion"] = st.NotifiedVersion,
            };
            var tmp = AppPaths.UpdateCheckFile + ".tmp";
            File.WriteAllText(tmp, o.ToJsonString(), new UTF8Encoding(false));
            File.Move(tmp, AppPaths.UpdateCheckFile, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 寫不進去只影響「多久檢查一次」，記錄後照常運作
            AppLog.Info($"檢查更新紀錄寫入失敗：{ex.Message}");
        }
    }
}
