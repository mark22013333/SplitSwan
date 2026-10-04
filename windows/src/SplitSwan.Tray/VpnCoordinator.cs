using System.Net.NetworkInformation;
using Microsoft.Win32;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 唯一的連線協調器（對應 Mac 版 VPNController）：
/// - 同時只跑一個引擎動作（連線、斷線、首次安裝；輪詢 brief 也不會跟它們同時跑）；
/// - 想連線時每 15 秒用 brief 輪詢，App 啟動時跑一次以反映既有通道；
///   brief 查不到（unknown／失敗／逾時）時沿用上一次狀態，連續 3 次才當成 down（BriefTracker）；
/// - DropDetector（30 秒）判斷掉線並發通知；自動重連開啟時才重連（退避 30s→60s→120s→240s→5 分鐘）；
/// - 網路位址變化、睡眠喚醒的處理（Modern Standby 收不到睡眠事件時，靠輪詢間隔過長偵測喚醒）。
/// 所有公開方法與事件都在 UI 執行緒上執行（WinForms Timer、await 回到 UI 的 SynchronizationContext）。
/// </summary>
internal sealed class VpnCoordinator : IDisposable
{
    private static readonly TimeSpan DropThreshold = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan StableAfter = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(15);
    /// <summary>兩次輪詢間隔超過這個值，視為電腦睡過（Modern Standby 不一定送睡眠事件）。</summary>
    private static readonly TimeSpan WakeGap = TimeSpan.FromSeconds(90);
    /// <summary>位址變化去抖動：連線動作本身、WSL VM 開關都會改變虛擬網卡位址。</summary>
    private static readonly TimeSpan AddressDebounce = TimeSpan.FromSeconds(8);
    /// <summary>引擎動作結束後這段時間內的位址變化不理（是我們自己造成的）。</summary>
    private static readonly TimeSpan IgnoreAddressAfterOp = TimeSpan.FromSeconds(20);

    private readonly SynchronizationContext _ui;
    private readonly System.Windows.Forms.Timer _pollTimer = new() { Interval = (int)PollInterval.TotalMilliseconds };
    private readonly System.Windows.Forms.Timer _retryTimer = new();
    private readonly System.Windows.Forms.Timer _addressTimer = new() { Interval = (int)AddressDebounce.TotalMilliseconds };
    private readonly DropDetector _drop = new(DropThreshold);
    private readonly BriefTracker _brief = new();
    private readonly Func<string, bool> _askOpenInstaller;

    private StoredSettings _settings;
    private bool _busy;
    private string? _busyText;
    private bool _pendingDown;
    private Task? _pollTask;
    private bool _wantConnected;
    private bool _isUp;
    private string? _gateway;
    private string? _vip;
    private string? _lastError;
    private string? _retryNote;
    private bool _rebuildOnRetry;
    private int _backoffStep;
    private DateTimeOffset _lastUpAt = DateTimeOffset.MinValue;
    private DateTimeOffset _lastPollTick = DateTimeOffset.Now;
    private DateTimeOffset _lastResumeHandled = DateTimeOffset.MinValue;
    private DateTimeOffset _ignoreAddressUntil = DateTimeOffset.MinValue;
    private string _networkFingerprint;
    private bool _networkAvailable;
    /// <summary>啟動後是否已拿到確定的 up／down；拿到之前不論想不想連都持續輪詢（契約 1：unknown 不算結果）。</summary>
    private bool _initialStateKnown;
    private bool _disposed;

    /// <summary>狀態改變（重畫圖示與選單）。</summary>
    public event Action? Changed;
    /// <summary>要發的通知（標題、內文、是否為錯誤）。</summary>
    public event Action<string, string, bool>? Notify;

    /// <param name="askOpenInstaller">引擎回報 WSL／Ubuntu 尚未安裝時，問使用者要不要開首次安裝視窗（參數是原因）。</param>
    public VpnCoordinator(StoredSettings settings, Func<string, bool> askOpenInstaller)
    {
        _ui = SynchronizationContext.Current
              ?? throw new InvalidOperationException("VpnCoordinator 必須在 UI 執行緒建立");
        _settings = settings;
        _askOpenInstaller = askOpenInstaller;
        _networkFingerprint = NetworkFingerprint.Current();
        _networkAvailable = NetworkFingerprint.IsAvailable(_networkFingerprint);
        AppLog.SetSecrets(settings.Password, settings.Psk);

        _pollTimer.Tick += (_, _) => Guard(OnPollTickAsync);
        _retryTimer.Tick += (_, _) => Guard(OnRetryTickAsync);
        _addressTimer.Tick += (_, _) => Guard(OnAddressSettledAsync);
        // NetworkAvailabilityChanged 在有 WSL 虛擬網卡時幾乎不會觸發（虛擬網卡一直是 Up），改聽位址變化
        NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }

    // MARK: 給 UI 讀的狀態

    public bool IsBusy => _busy;
    /// <summary>最後一次確定的結果是已連線（狀態不明時沿用）。</summary>
    public bool IsUp => _isUp;
    public bool WantConnected => _wantConnected;
    public string? Gateway => _gateway;
    public string? Vip => _vip;
    public string? LastError => _lastError;
    public string? RetryNote => _retryNote;
    public StoredSettings Settings => _settings;

    public TrayState State =>
        _busy ? TrayState.Busy
        : _brief.IsStateUnknown && (_wantConnected || _isUp || !_initialStateKnown) ? TrayState.Unknown
        : _isUp ? TrayState.Connected
        : _wantConnected || _lastError is not null ? TrayState.Error
        : TrayState.Disconnected;

    public string StatusLine => TrayText.StatusLine(State, _gateway, _vip, _busyText, _lastError ?? _retryNote);
    public string Tooltip => TrayText.Tooltip(AppPaths.AppName, State, _gateway, _vip, _busyText, _lastError ?? _retryNote);

    // MARK: 啟動

    /// <summary>啟動輪詢；先跑一次 brief 反映既有通道（例如上次結束 App 時沒有斷線）。</summary>
    public void Start()
    {
        var missing = AppPaths.MissingEngineFiles();
        if (missing is not null)
        {
            _lastError = $"找不到連線引擎：{missing}";
            AppLog.Error(_lastError);
            Notify?.Invoke("SplitSwan 無法使用", _lastError, true);
        }
        _lastPollTick = DateTimeOffset.Now;
        _pollTimer.Start();
        Guard(async () =>
        {
            await RefreshAsync();
        });
    }

    /// <summary>設定已儲存：之後的連線使用新設定（已建立的通道不受影響）。</summary>
    public void UpdateSettings(StoredSettings s)
    {
        var autoTurnedOn = s.AutoReconnect && !_settings.AutoReconnect;
        _settings = s;
        AppLog.SetSecrets(s.Password, s.Psk);
        if (!s.AutoReconnect) CancelRetry();
        else if (autoTurnedOn && _wantConnected && !_isUp && !_busy) ScheduleRetry(TimeSpan.FromSeconds(5));
        RaiseChanged();
    }

    // MARK: 使用者操作

    /// <summary>選單「連線」：已連線時等於重新建立（引擎 connect 會先清掉上一次的狀態）。</summary>
    public void Connect()
    {
        if (_busy) { Notify?.Invoke(AppPaths.AppName, "目前有動作在進行中，請稍候", false); return; }
        _wantConnected = true;
        _pendingDown = false;
        _drop.Reset();
        _brief.Reset();
        _backoffStep = 0;
        CancelRetry();
        _lastError = null;
        Guard(() => RunConnectAsync(manual: true));
    }

    /// <summary>選單「斷線」：動作進行中時，等它完成後再斷線（不中途砍掉，避免 WSL 內安裝到一半）。</summary>
    public void Disconnect()
    {
        _wantConnected = false;
        _rebuildOnRetry = false;
        CancelRetry();
        _drop.Reset();
        if (_busy)
        {
            _pendingDown = true;
            _busyText = "目前動作完成後會斷線…";
            AppLog.Info("動作進行中按了斷線：完成後斷線");
            RaiseChanged();
            return;
        }
        Guard(RunDisconnectAsync);
    }

    /// <summary>
    /// 結束 App 前要不要先斷線：只有確定沒有通道（最後一次 brief 確定 down、也不想連線）時才略過。
    /// 狀態不明、上次是已連線、或正想連線，都當成可能有通道。
    /// </summary>
    public bool NeedsDisconnectOnExit => State != TrayState.Disconnected;

    /// <summary>
    /// 結束 App 前斷線：停止輪詢與重連，跑引擎 disconnect（清 WSL 內的 SA、Windows 路由、NRPT、保活程序）。
    /// 回傳 (成功, 失敗原因)。呼叫端必須先確認 !IsBusy。
    /// </summary>
    public async Task<(bool Ok, string? Error)> DisconnectForExitAsync()
    {
        _wantConnected = false;
        _rebuildOnRetry = false;
        _pendingDown = false;
        CancelRetry();
        _drop.Reset();
        _pollTimer.Stop();
        await EnterBusyAsync("結束前斷線中…");
        try
        {
            AppLog.Info("結束前斷線");
            EngineResult r;
            try { r = await EngineRunner.RunAsync(EngineAction.Disconnect); }
            catch (Exception ex) { r = EngineResult.Failed($"執行連線引擎時發生錯誤：{ex.GetType().Name}：{ex.Message}"); }
            if (r.Ok)
            {
                _isUp = false;
                _gateway = _vip = null;
                AppLog.Info("已斷線");
                return (true, null);
            }
            AppLog.Error("結束前斷線失敗：" + (r.Error ?? "原因不明"));
            return (false, r.Error ?? "原因不明");
        }
        finally
        {
            LeaveBusy();
        }
    }

    /// <summary>
    /// 選單「首次安裝 WSL／Ubuntu」：在可見的 PowerShell 視窗跑 connect（wsl --install 要主控台建立 Ubuntu 帳號）。
    /// 回傳 null＝已開始；否則是不能開始的原因（給 UI 顯示）。
    /// </summary>
    public string? StartFirstInstall()
    {
        if (_busy) return "目前有動作在進行中，請稍候再試";
        // 引擎第一步就檢查 swanctl.conf／secrets.conf，所以設定要先填好
        var errors = ConfWriter.Validate(_settings);
        if (errors.Count > 0) return "請先到「設定…」填好或匯入設定：\n" + string.Join("\n", errors);
        Guard(RunFirstInstallAsync);
        return null;
    }

    // MARK: 引擎動作

    /// <summary>進入動作：先標記忙碌（之後不會再啟動新的輪詢），再等進行中的輪詢結束，確保同時只有一個引擎程序。</summary>
    private async Task EnterBusyAsync(string text)
    {
        _busy = true;
        _busyText = text;
        RaiseChanged();
        var poll = _pollTask;
        if (poll is not null) await poll;
    }

    private void LeaveBusy()
    {
        _busy = false;
        _busyText = null;
        _ignoreAddressUntil = DateTimeOffset.Now + IgnoreAddressAfterOp;
        _brief.Reset();
        RaiseChanged();
    }

    private async Task RunConnectAsync(bool manual)
    {
        if (_busy) return;
        if (!manual && !_networkAvailable) { _retryNote = "沒有網路，恢復後自動重連"; RaiseChanged(); return; }
        await EnterBusyAsync("連線中…（第一次要安裝 strongSwan，可能要幾分鐘）");
        var openInstaller = false;
        try
        {
            openInstaller = await ConnectCoreAsync(manual);
        }
        finally
        {
            LeaveBusy();
        }

        if (openInstaller)
        {
            _pendingDown = false;   // 本來就沒連上，不需要補斷線
            var why = StartFirstInstall();
            if (why is not null) { _lastError = why; Notify?.Invoke("無法開始首次安裝", why, true); RaiseChanged(); }
            return;
        }
        await AfterOperationAsync();
    }

    /// <summary>執行 connect；回傳 true＝使用者選擇開首次安裝視窗。</summary>
    private async Task<bool> ConnectCoreAsync(bool manual)
    {
        _retryNote = null;
        RaiseChanged();
        AppLog.Info(manual ? "開始連線（手動）" : "開始連線（自動重連）");

        // 1. 產生設定檔：設定本身有問題 → 重試也沒用，停止想連線
        try
        {
            ConfWriter.Write(_settings);
        }
        catch (SettingsInvalidException ex)
        {
            ConfWriter.DeleteSecrets();
            _wantConnected = false;
            CancelRetry();
            _lastError = ex.Message;
            AppLog.Error("設定有誤：" + ex.Message);
            Notify?.Invoke("設定有誤，無法連線", ex.Message, true);
            return false;
        }
        catch (Exception ex)
        {
            // ACL、磁碟、權限等執行期問題：告訴使用者，照一般失敗處理（自動重連開著就照退避重試）
            DeleteSecretsOrWarn();
            HandleConnectFailure(manual, "無法寫入設定檔：" + ex.Message);
            return false;
        }

        // 2. 跑引擎：不論成敗都刪 secrets.conf
        EngineResult r;
        try
        {
            r = await EngineRunner.RunAsync(EngineAction.Connect);
        }
        catch (Exception ex)
        {
            r = EngineResult.Failed($"執行連線引擎時發生錯誤：{ex.GetType().Name}：{ex.Message}");
        }
        finally
        {
            DeleteSecretsOrWarn();
        }

        if (r.Ok)
        {
            _isUp = true;
            _gateway = r.Values.GetValueOrDefault("GATEWAY");
            _vip = r.Values.GetValueOrDefault("VIP");
            _lastUpAt = DateTimeOffset.Now;
            _lastError = null;
            _rebuildOnRetry = false;
            AppLog.Info($"已連線：{_gateway ?? "?"}，虛擬 IP {_vip ?? "?"}");
            return false;
        }

        var error = r.Error ?? "連線失敗";
        AppLog.Error("連線失敗：" + error);
        if (EngineCommand.IsInstallNeeded(r.Error, r.Lines))
        {
            // 背景沒有主控台可以建立 Ubuntu 帳號：請使用者改用可見視窗
            _wantConnected = false;
            CancelRetry();
            _lastError = "WSL／Ubuntu 尚未安裝完成，請用選單的「首次安裝 WSL／Ubuntu…」";
            if (manual && _askOpenInstaller(_lastError)) return true;
            Notify?.Invoke("需要首次安裝", _lastError, true);
            return false;
        }
        if (EngineCommand.IsNotAdministrator(r.Error))
        {
            _wantConnected = false;
            CancelRetry();
            _lastError = "SplitSwan 沒有以系統管理員身分執行，請結束後重新開啟並允許 UAC";
            Notify?.Invoke("連線失敗", _lastError, true);
            return false;
        }
        HandleConnectFailure(manual, error);
        return false;
    }

    /// <summary>一般的連線失敗：自動重連開著就排退避重試，否則停止想連線。都會通知使用者。</summary>
    private void HandleConnectFailure(bool manual, string error)
    {
        _lastError = error;
        if (_wantConnected && _settings.AutoReconnect && !_pendingDown)
        {
            ScheduleRetry();
            // 自動重連的重複失敗不每次都跳通知（掉線通知已經發過），手動連線一定通知
            if (manual) Notify?.Invoke("連線失敗", $"{error}（{_retryNote}）", true);
        }
        else
        {
            _wantConnected = false;
            Notify?.Invoke("連線失敗", error + "。詳細內容請看「顯示引擎輸出」", true);
        }
    }

    private async Task RunDisconnectAsync()
    {
        if (_busy) { _pendingDown = true; return; }
        await EnterBusyAsync("斷線中…");
        try
        {
            AppLog.Info("開始斷線");
            EngineResult r;
            try { r = await EngineRunner.RunAsync(EngineAction.Disconnect); }
            catch (Exception ex) { r = EngineResult.Failed($"執行連線引擎時發生錯誤：{ex.GetType().Name}：{ex.Message}"); }
            if (r.Ok)
            {
                _isUp = false;
                _gateway = _vip = null;
                _lastError = null;
                _retryNote = null;
                AppLog.Info("已斷線");
            }
            else
            {
                _lastError = "斷線失敗：" + (r.Error ?? "原因不明");
                AppLog.Error(_lastError);
                Notify?.Invoke("斷線失敗", _lastError, true);
            }
        }
        finally
        {
            LeaveBusy();
        }
        await AfterOperationAsync();
    }

    private async Task RunFirstInstallAsync()
    {
        if (_busy) return;
        await EnterBusyAsync("首次安裝視窗執行中…（完成後請在視窗按 Enter 關閉）");
        try
        {
            ConfWriter.Write(_settings);
            AppLog.Info("開啟首次安裝視窗（可見的 PowerShell）");
            var code = await EngineRunner.RunVisibleAsync(EngineAction.Connect);
            AppLog.Info($"首次安裝視窗已關閉，結束碼 {code?.ToString() ?? "未知"}");
            _lastError = null;
        }
        catch (Exception ex)
        {
            _lastError = "首次安裝無法開始：" + ex.Message;
            AppLog.Error(_lastError);
            Notify?.Invoke("首次安裝", _lastError, true);
        }
        finally
        {
            DeleteSecretsOrWarn();
            LeaveBusy();
        }
        await AfterOperationAsync();
        if (_isUp)
        {
            _wantConnected = true;
            _lastUpAt = DateTimeOffset.Now;
            RaiseChanged();
        }
        else if (_lastError is null)
        {
            Notify?.Invoke("首次安裝", "如果剛裝好 WSL／Ubuntu（或重開過機），請從托盤選單按「連線」", false);
        }
    }

    /// <summary>動作結束後：處理「進行中按了斷線」，再輪詢一次狀態。</summary>
    private async Task AfterOperationAsync()
    {
        if (_pendingDown)
        {
            _pendingDown = false;
            await RunDisconnectAsync();
            return;   // RunDisconnectAsync 自己會再呼叫 AfterOperationAsync
        }
        await RefreshAsync();
    }

    /// <summary>刪 secrets.conf；刪不掉（例如被 WSL 暫時開著）就通知使用者，5 秒後再試一次。</summary>
    private void DeleteSecretsOrWarn()
    {
        if (ConfWriter.DeleteSecrets()) return;
        Notify?.Invoke("無法刪除密碼檔", $"{AppPaths.SecretsConf} 刪除失敗，5 秒後再試；仍失敗請手動刪除", true);
        Guard(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(5));
            if (!_busy && !ConfWriter.DeleteSecrets())
                Notify?.Invoke("無法刪除密碼檔", $"請手動刪除 {AppPaths.SecretsConf}（含 PSK 與密碼）", true);
        });
    }

    // MARK: 輪詢

    private Task RefreshAsync()
    {
        if (_busy || _disposed) return Task.CompletedTask;
        if (_pollTask is not null) return _pollTask;
        var t = RefreshCoreAsync();
        // 同步完成（例如找不到引擎直接回失敗）時，RefreshCoreAsync 的 finally 已先跑過；不要留下已完成的舊 Task
        _pollTask = t.IsCompleted ? null : t;
        return t;
    }

    private async Task RefreshCoreAsync()
    {
        try
        {
            EngineResult r;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            try { r = await EngineRunner.RunAsync(EngineAction.Brief, logOutput: false); }
            catch (Exception ex) { r = EngineResult.Failed($"{ex.GetType().Name}：{ex.Message}"); }
            ApplyBrief(r, sw.Elapsed);
        }
        finally
        {
            _pollTask = null;
        }
    }

    private void ApplyBrief(EngineResult r, TimeSpan elapsed)
    {
        var kind = BriefTracker.Classify(r.Values, r.TimedOut);
        var now = DateTimeOffset.Now;

        // 輪詢途中開始了引擎動作：結果只更新顯示，不餵 DropDetector、不排重連（動作結束後會再輪詢一次）
        if (_busy)
        {
            if (kind == BriefKind.Up) { _isUp = true; _gateway = r.Values.GetValueOrDefault("GATEWAY"); _vip = r.Values.GetValueOrDefault("VIP"); }
            else if (kind == BriefKind.Down) { _isUp = false; _gateway = _vip = null; }
            RaiseChanged();
            return;
        }

        var reachedLimit = _brief.Observe(kind);
        if (kind == BriefKind.Unknown)
        {
            // 查不到（契約 1 第二次修訂）：沿用上一次狀態，不餵 DropDetector、不判定斷線、不觸發自動重建。
            // 只有引擎明確回 STATE=down 才算斷線。連續達上限時改顯示「狀態不明」並寫一行記錄（含耗時，供實機判斷）。
            var ms = (int)elapsed.TotalMilliseconds;
            if (reachedLimit)
            {
                AppLog.Info($"輪詢連續 {_brief.ConsecutiveUnknown} 次查不到狀態，標為「狀態不明」（不判定斷線）；本次耗時 {ms} ms：{r.Error ?? "沒有 STATE"}");
                // 狀態不明時不會發掉線通知也不會自動重連，所以提醒一次（同一段狀態不明只會走到這裡一次）
                if (_wantConnected || _isUp)
                    Notify?.Invoke(TrayText.StateUnknownTitle, TrayText.StateUnknownBody, true);
            }
            else if (!_brief.IsStateUnknown)
                AppLog.Info($"輪詢查不到狀態（連續第 {_brief.ConsecutiveUnknown} 次，沿用上次狀態），耗時 {ms} ms：{r.Error ?? "沒有 STATE"}");
            RaiseChanged();
            return;
        }
        var up = kind == BriefKind.Up;
        if (!_initialStateKnown)
        {
            _initialStateKnown = true;
            if (up && !_wantConnected)
            {
                // 啟動後第一次確定的結果是 up：既有通道（例如上次結束 App 時沒有斷線），視為想保持連線
                _wantConnected = true;
                _lastUpAt = DateTimeOffset.Now - StableAfter;   // 早就連著，不算「剛連上」
                AppLog.Info($"啟動時偵測到既有通道（{r.Values.GetValueOrDefault("GATEWAY") ?? "?"}），視為想保持連線");
            }
        }
        var gateway = up ? r.Values.GetValueOrDefault("GATEWAY") : null;
        var wasUp = _isUp;
        _isUp = up;
        if (up)
        {
            _gateway = gateway;
            _vip = r.Values.GetValueOrDefault("VIP");
            if (!wasUp) _lastUpAt = now;
            if (now - _lastUpAt >= StableAfter) _backoffStep = 0;   // 連線穩定 60 秒才把退避歸零（同 Mac 版）
            _lastError = null;
            _retryNote = null;
        }
        else
        {
            _gateway = _vip = null;
            if (wasUp && _wantConnected) AppLog.Info("輪詢：通道已不在");
        }

        switch (_drop.Evaluate(now, _wantConnected, up, _networkAvailable))
        {
            case DropAction.NotifyDrop:
                AppLog.Info($"中斷超過 {(int)DropThreshold.TotalSeconds} 秒，發送斷線通知");
                Notify?.Invoke(DropDetector.DropTitle(AppPaths.AppName),
                    TrayText.DropBody(DropThreshold, _settings.AutoReconnect), true);
                break;
            case DropAction.NotifyRestore:
                AppLog.Info("已恢復連線，發送恢復通知");
                Notify?.Invoke(DropDetector.RestoreTitle(AppPaths.AppName), DropDetector.RestoreBody(gateway), false);
                break;
        }

        if (_wantConnected && !up && _settings.AutoReconnect && _networkAvailable && !_retryTimer.Enabled)
            ScheduleRetry();
        RaiseChanged();
    }

    private async Task OnPollTickAsync()
    {
        var now = DateTimeOffset.Now;
        var gap = now - _lastPollTick;
        _lastPollTick = now;
        if (gap > WakeGap)
        {
            // Modern Standby 的電腦常收不到 PowerModeChanged；計時器在睡眠中停住，醒來後間隔會遠大於 15 秒
            HandleResume($"輪詢間隔 {(int)gap.TotalSeconds} 秒，推定剛從睡眠喚醒");
        }
        // 啟動時第一次查不到：繼續輪詢，直到拿到確定的 up／down（才知道有沒有既有通道）
        if (_wantConnected || _isUp || !_initialStateKnown) await RefreshAsync();
    }

    // MARK: 自動重連

    private void ScheduleRetry(TimeSpan? fixedDelay = null)
    {
        if (!_wantConnected || !_settings.AutoReconnect) return;
        var wait = fixedDelay ?? ReconnectBackoff.Delay(_backoffStep++);
        _retryTimer.Stop();
        _retryTimer.Interval = (int)Math.Max(1000, wait.TotalMilliseconds);
        _retryTimer.Start();
        _retryNote = $"{(int)wait.TotalSeconds} 秒後自動重連";
        AppLog.Info(_retryNote);
        RaiseChanged();
    }

    private void CancelRetry()
    {
        _retryTimer.Stop();
        _retryNote = null;
    }

    private async Task OnRetryTickAsync()
    {
        _retryTimer.Stop();
        _retryNote = null;
        if (!_wantConnected || !_settings.AutoReconnect) return;
        if (_busy) { ScheduleRetry(TimeSpan.FromSeconds(30)); return; }
        if (!_networkAvailable) { _retryNote = "沒有網路，恢復後自動重連"; RaiseChanged(); return; }
        if (_isUp && !_rebuildOnRetry) return;
        _rebuildOnRetry = false;
        await RunConnectAsync(manual: false);
    }

    // MARK: 系統事件（在其他執行緒觸發，切回 UI）

    private void OnNetworkAddressChanged(object? sender, EventArgs e) =>
        _ui.Post(_ =>
        {
            if (_disposed) return;
            // 去抖動：同一次換網路會連續觸發好幾次，等 8 秒沒有新變化再比對
            _addressTimer.Stop();
            _addressTimer.Start();
        }, null);

    private Task OnAddressSettledAsync()
    {
        _addressTimer.Stop();
        if (_disposed) return Task.CompletedTask;
        var fp = NetworkFingerprint.Current();
        if (fp == _networkFingerprint) return Task.CompletedTask;   // 只有虛擬網卡（WSL 等）變了
        var wasAvailable = _networkAvailable;
        _networkFingerprint = fp;
        _networkAvailable = NetworkFingerprint.IsAvailable(fp);
        AppLog.Info(_networkAvailable ? (wasAvailable ? "網路改變" : "網路恢復") : "網路中斷");

        if (!_networkAvailable)
        {
            CancelRetry();
            if (_wantConnected) _retryNote = "沒有網路，恢復後自動重連";
        }
        else if (_busy || DateTimeOffset.Now < _ignoreAddressUntil)
        {
            // 動作進行中或剛結束：動作完成後的輪詢會反映新狀態
        }
        else if (_wantConnected && _settings.AutoReconnect)
        {
            _backoffStep = 0;
            // 換網路後 WSL 的路由可能失效：重新建立（引擎 connect 會先清掉舊狀態）
            _rebuildOnRetry = true;
            ScheduleRetry(TimeSpan.FromSeconds(5));
        }
        else if (_wantConnected)
        {
            Notify?.Invoke("網路已改變", "VPN 通道可能已失效；內網連不到時，請從托盤選單按「連線」重新建立", false);
        }
        RaiseChanged();
        return Task.CompletedTask;
    }

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e) =>
        _ui.Post(_ => Guard(() =>
        {
            if (_disposed) return Task.CompletedTask;
            if (e.Mode == PowerModes.Suspend)
            {
                AppLog.Info("系統進入睡眠");
                CancelRetry();
            }
            else if (e.Mode == PowerModes.Resume)
            {
                HandleResume("睡眠喚醒");
            }
            RaiseChanged();
            return Task.CompletedTask;
        }), null);

    /// <summary>睡眠喚醒（系統事件或輪詢間隔推定）。一分鐘內只處理一次，避免兩個來源重複。</summary>
    private void HandleResume(string why)
    {
        var now = DateTimeOffset.Now;
        if (now - _lastResumeHandled < TimeSpan.FromMinutes(1)) return;
        _lastResumeHandled = now;
        AppLog.Info(why);
        _drop.Reset();
        _brief.Reset();
        _networkFingerprint = NetworkFingerprint.Current();
        _networkAvailable = NetworkFingerprint.IsAvailable(_networkFingerprint);
        if (!_wantConnected) return;
        if (_settings.AutoReconnect)
        {
            _backoffStep = 0;
            _rebuildOnRetry = true;   // WSL 的 IP 與 Windows 路由在睡眠後可能已失效，重建
            ScheduleRetry(TimeSpan.FromSeconds(10));
            Notify?.Invoke("睡眠喚醒", "10 秒後重新建立 VPN 通道", false);
        }
        else
        {
            Notify?.Invoke("睡眠喚醒", "睡眠後 VPN 通道可能已失效；內網連不到時，請從托盤選單按「連線」重新建立", false);
        }
        RaiseChanged();
    }

    // MARK: 小工具

    private void RaiseChanged()
    {
        if (!_disposed) Changed?.Invoke();
    }

    /// <summary>執行非同步動作；未預期的例外寫記錄並通知使用者，不讓 App 當掉，也不默默吞掉。</summary>
    private async void Guard(Func<Task> action)
    {
        try { await action(); }
        catch (Exception ex)
        {
            // 例外訊息可能含路徑，但不會含密碼（密碼只存在 secrets.conf 內容與設定物件中，不進例外訊息）
            var msg = $"{ex.GetType().Name}：{ex.Message}";
            AppLog.Error("未預期的錯誤：" + msg);
            if (!_disposed) Notify?.Invoke("SplitSwan 發生未預期的錯誤", msg + "。詳細內容請看「顯示引擎輸出」", true);
            RaiseChanged();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        _pollTimer.Dispose();
        _retryTimer.Dispose();
        _addressTimer.Dispose();
    }
}
