using System.Net.NetworkInformation;
using Microsoft.Win32;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>使用者對「尚未安裝 WSL／Ubuntu」提示的選擇。</summary>
internal enum InstallChoice { OpenInstaller, ContinueHidden, Cancel }

/// <summary>
/// 唯一的連線協調器（對應 Mac 版 VPNController）：
/// - 同時只跑一個引擎動作（連線、斷線、首次安裝；輪詢 brief 也不會跟它們同時跑）；
/// - 想連線時每 15 秒用 brief 輪詢，App 啟動時跑一次以反映既有通道；
/// - DropDetector（30 秒）判斷掉線並發通知；自動重連開啟時才重連（退避 30s→60s→120s→240s→5 分鐘）；
/// - 網路變化、睡眠喚醒的處理。
/// 所有公開方法與事件都在 UI 執行緒上執行（WinForms Timer、await 回到 UI 的 SynchronizationContext）。
/// </summary>
internal sealed class VpnCoordinator : IDisposable
{
    private static readonly TimeSpan DropThreshold = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan StableAfter = TimeSpan.FromSeconds(60);

    private readonly SynchronizationContext _ui;
    private readonly System.Windows.Forms.Timer _pollTimer = new() { Interval = 15_000 };
    private readonly System.Windows.Forms.Timer _retryTimer = new();
    private readonly DropDetector _drop = new(DropThreshold);
    private readonly Func<string, InstallChoice> _askInstall;

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
    private bool _networkAvailable;
    private bool _disposed;

    /// <summary>狀態改變（重畫圖示與選單）。</summary>
    public event Action? Changed;
    /// <summary>要發的通知（標題、內文、是否為錯誤）。</summary>
    public event Action<string, string, bool>? Notify;

    public VpnCoordinator(StoredSettings settings, Func<string, InstallChoice> askInstall)
    {
        _ui = SynchronizationContext.Current
              ?? throw new InvalidOperationException("VpnCoordinator 必須在 UI 執行緒建立");
        _settings = settings;
        _askInstall = askInstall;
        _networkAvailable = SafeNetworkAvailable();
        AppLog.SetSecrets(settings.Password, settings.Psk);

        _pollTimer.Tick += (_, _) => Guard(OnPollTickAsync);
        _retryTimer.Tick += (_, _) => Guard(OnRetryTickAsync);
        NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }

    // MARK: 給 UI 讀的狀態

    public bool IsBusy => _busy;
    public bool WantConnected => _wantConnected;
    public string? Gateway => _gateway;
    public string? Vip => _vip;
    public string? LastError => _lastError;
    public string? RetryNote => _retryNote;
    public StoredSettings Settings => _settings;

    public TrayState State =>
        _busy ? TrayState.Busy
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
        }
        _pollTimer.Start();
        Guard(async () =>
        {
            await RefreshAsync();
            if (_isUp && !_wantConnected)
            {
                _wantConnected = true;
                _lastUpAt = DateTimeOffset.Now - StableAfter;   // 早就連著，不算「剛連上」
                AppLog.Info($"啟動時偵測到既有通道（{_gateway ?? "?"}），視為想保持連線");
                RaiseChanged();
            }
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
    /// 選單「首次安裝 WSL／Ubuntu」：在可見的 PowerShell 視窗跑 connect（wsl --install 要主控台建立 Ubuntu 帳號）。
    /// 回傳 null＝已開始；否則是不能開始的原因（給 UI 顯示）。
    /// </summary>
    public string? StartFirstInstall()
    {
        if (_busy) return "目前有動作在進行中，請稍候再試";
        // 引擎第一步就檢查 swanctl.conf／secrets.conf，所以設定要先填好
        var errors = SettingsValidator.Validate(_settings.ToVpnSettings())
            .Concat(DnsOptions.Validate(_settings.Domain, _settings.DnsServer)).ToList();
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
        RaiseChanged();
    }

    private async Task RunConnectAsync(bool manual)
    {
        if (_busy) return;
        if (!manual && !_networkAvailable) { _retryNote = "沒有網路，恢復後自動重連"; RaiseChanged(); return; }
        await EnterBusyAsync("檢查 WSL…");
        var openInstaller = false;
        try
        {
            var proceed = true;
            var notInstalled = await EngineRunner.CheckWslInstalledAsync();
            if (notInstalled is not null)
            {
                AppLog.Info(notInstalled);
                if (!manual)
                {
                    // 自動重連時不能跳對話框，也不能在背景觸發互動式安裝
                    proceed = false;
                    _wantConnected = false;
                    CancelRetry();
                    _lastError = notInstalled + "，請用選單的「首次安裝 WSL／Ubuntu…」";
                    Notify?.Invoke("無法自動重連", _lastError, true);
                }
                else
                {
                    switch (_askInstall(notInstalled))
                    {
                        case InstallChoice.OpenInstaller:
                            proceed = false;
                            openInstaller = true;
                            _wantConnected = false;
                            break;
                        case InstallChoice.Cancel:
                            proceed = false;
                            _wantConnected = false;
                            AppLog.Info("使用者取消連線");
                            break;
                        default:
                            AppLog.Info("使用者選擇仍在背景連線");
                            break;
                    }
                }
            }
            if (proceed) await ConnectCoreAsync(manual);
        }
        finally
        {
            LeaveBusy();
        }

        if (openInstaller)
        {
            _pendingDown = false;   // 本來就沒連，不需要補斷線
            var why = StartFirstInstall();
            if (why is not null) { _lastError = why; Notify?.Invoke("無法開始首次安裝", why, true); RaiseChanged(); }
            return;
        }
        await AfterOperationAsync();
    }

    private async Task ConnectCoreAsync(bool manual)
    {
        _busyText = "連線中…（第一次要安裝 strongSwan，可能要幾分鐘）";
        _retryNote = null;
        RaiseChanged();
        AppLog.Info(manual ? "開始連線（手動）" : "開始連線（自動重連）");

        EngineResult r;
        try
        {
            ConfWriter.Write(_settings);
            r = await EngineRunner.RunAsync(EngineAction.Connect);
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            r = new EngineResult(false, ex.Message, new Dictionary<string, string>(), false);
            // 設定本身有問題，重試也沒用
            _wantConnected = false;
            CancelRetry();
        }
        finally
        {
            // 規格：引擎跑完（不論成敗）刪除 secrets.conf
            ConfWriter.DeleteSecrets();
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
            return;
        }

        _lastError = r.Error ?? "連線失敗";
        AppLog.Error("連線失敗：" + _lastError);
        if (EngineCommand.IsInstallStarted(r.Error))
        {
            // 背景沒有主控台可以建立 Ubuntu 帳號：請使用者改用可見視窗
            _wantConnected = false;
            CancelRetry();
            _lastError = "WSL／Ubuntu 尚未安裝完成，請用選單的「首次安裝 WSL／Ubuntu…」";
            Notify?.Invoke("需要首次安裝", _lastError, true);
            return;
        }
        if (EngineCommand.IsNotAdministrator(r.Error))
        {
            _wantConnected = false;
            CancelRetry();
            _lastError = "SplitSwan 沒有以系統管理員身分執行，請結束後重新開啟並允許 UAC";
            Notify?.Invoke("連線失敗", _lastError, true);
            return;
        }
        if (_wantConnected && _settings.AutoReconnect && !_pendingDown)
        {
            ScheduleRetry();
            if (manual) Notify?.Invoke("連線失敗", $"{_lastError}（{_retryNote}）", true);
        }
        else
        {
            _wantConnected = false;
            Notify?.Invoke("連線失敗", _lastError + "。詳細內容請看「顯示引擎輸出」", true);
        }
    }

    private async Task RunDisconnectAsync()
    {
        if (_busy) { _pendingDown = true; return; }
        await EnterBusyAsync("斷線中…");
        try
        {
            AppLog.Info("開始斷線");
            var r = await EngineRunner.RunAsync(EngineAction.Disconnect);
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
        catch (Exception ex) when (ex is InvalidOperationException or IOException or UnauthorizedAccessException
                                       or System.ComponentModel.Win32Exception)
        {
            _lastError = "首次安裝無法開始：" + ex.Message;
            AppLog.Error(_lastError);
            Notify?.Invoke("首次安裝", _lastError, true);
        }
        finally
        {
            ConfWriter.DeleteSecrets();
            LeaveBusy();
        }
        await AfterOperationAsync();
        if (_isUp)
        {
            _wantConnected = true;
            _lastUpAt = DateTimeOffset.Now;
            RaiseChanged();
        }
        else
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
            var r = await EngineRunner.RunAsync(EngineAction.Brief, logOutput: false);
            var up = r.Values.TryGetValue("STATE", out var st) && st == "up";
            ApplyBrief(up, r.Values.GetValueOrDefault("GATEWAY"), r.Values.GetValueOrDefault("VIP"));
        }
        finally
        {
            _pollTask = null;
        }
    }

    private void ApplyBrief(bool up, string? gateway, string? vip)
    {
        var now = DateTimeOffset.Now;
        var wasUp = _isUp;
        _isUp = up;
        if (up)
        {
            _gateway = gateway;
            _vip = vip;
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

        if (_wantConnected && !up && !_busy && _settings.AutoReconnect && _networkAvailable && !_retryTimer.Enabled)
            ScheduleRetry();
        RaiseChanged();
    }

    private async Task OnPollTickAsync()
    {
        if (_wantConnected || _isUp) await RefreshAsync();
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

    private void OnNetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e) =>
        _ui.Post(_ => Guard(() =>
        {
            if (_disposed) return Task.CompletedTask;
            var was = _networkAvailable;
            _networkAvailable = e.IsAvailable;
            if (was == e.IsAvailable) return Task.CompletedTask;
            AppLog.Info(e.IsAvailable ? "網路恢復" : "網路中斷");
            if (!e.IsAvailable)
            {
                CancelRetry();
                if (_wantConnected) _retryNote = "沒有網路，恢復後自動重連";
            }
            else if (_wantConnected && _settings.AutoReconnect && !_busy)
            {
                _backoffStep = 0;
                // 換網路後 WSL 的路由可能失效：重新建立（引擎 connect 會先清掉舊狀態）
                _rebuildOnRetry = true;
                ScheduleRetry(TimeSpan.FromSeconds(5));
            }
            RaiseChanged();
            return Task.CompletedTask;
        }), null);

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
                AppLog.Info("睡眠喚醒");
                _drop.Reset();
                _networkAvailable = SafeNetworkAvailable();
                if (_wantConnected)
                {
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
                }
            }
            RaiseChanged();
            return Task.CompletedTask;
        }), null);

    // MARK: 小工具

    private void RaiseChanged()
    {
        if (!_disposed) Changed?.Invoke();
    }

    /// <summary>執行非同步動作並記錄未預期的例外，不讓它讓 App 當掉。</summary>
    private static async void Guard(Func<Task> action)
    {
        try { await action(); }
        catch (Exception ex)
        {
            // 例外訊息可能含路徑，但不會含密碼（密碼只存在 secrets.conf 內容與設定物件中，不進例外訊息）
            AppLog.Error($"未預期的錯誤：{ex.GetType().Name}：{ex.Message}");
        }
    }

    private static bool SafeNetworkAvailable()
    {
        try { return NetworkInterface.GetIsNetworkAvailable(); }
        catch (NetworkInformationException) { return true; }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        _pollTimer.Dispose();
        _retryTimer.Dispose();
    }
}
