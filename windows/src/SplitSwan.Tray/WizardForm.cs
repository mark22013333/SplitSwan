using System.Diagnostics;
using System.Drawing;
using SplitSwan.Core;
using SplitSwan.Tray.Controls;

namespace SplitSwan.Tray;

/// <summary>
/// 首次設定精靈（契約 6；介面為視覺稿 C）：頁首「3 / 6　步驟名稱」大標與進度條，「完成／接下來」兩列 chips，
/// 說明、錯誤卡片、動作按鈕、深色等寬的輸出區與下方按鈕。
/// 步驟規則在 Core 的 SetupWizardState，各步驟的動作在 WizardSteps；這裡只處理畫面與流程控制：
/// - 按「開始」後自動一路執行；遇到失敗、要重開機、要使用者填設定時停下來。
/// - 已完成的步驟偵測到就自動略過；狀態每一步都存 wizard.json，重開機後從中斷處繼續。
/// </summary>
internal sealed class WizardForm : ThemedForm
{
    private readonly VpnCoordinator _vpn;
    private readonly Func<bool, Task<StoredSettings?>> _openSettings;
    private readonly SetupWizardState _state;
    private readonly StatusDot _stepDot = new(10);
    private readonly ThemedLabel _title = new("", TextRole.Ink, Theme.Ui(11.5f, FontStyle.Bold));
    private readonly ThemedLabel _progressText = new("", TextRole.Muted, Theme.Mono(8.25f));
    private readonly ProgressStrip _progress = new();
    private readonly ChipFlow _doneLane = new();
    private readonly ChipFlow _nextLane = new();
    private readonly ThemedLabel _desc = new("", TextRole.Muted) { MaximumSize = new Size(640, 0) };
    private readonly CardPanel _errorCard = new() { Tone = StatusTone.Bad, Visible = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
    private readonly ThemedLabel _error = new("", TextRole.Bad) { MaximumSize = new Size(620, 0) };
    private readonly TerminalBox _output = new(MaxOutputChars) { Dock = DockStyle.Fill };
    private readonly FlowLayoutPanel _actions = UiLayout.Flow();
    private readonly ThemedButton _back = new("上一步");
    private readonly ThemedButton _retry = new("重試");
    private readonly ThemedButton _next = new("開始", primary: true);
    private readonly ThemedButton _close = new("關閉");
    private readonly ThemedButton _cancelDownload = new("取消下載") { Visible = false };

    // 完成畫面的捷徑選項（預設勾選）；按「完成」時建立，結果寫在輸出區
    private ToggleSwitch? _wizDesktop;
    private ToggleSwitch? _wizStartMenu;
    private bool _shortcutsApplied;

    private CancellationTokenSource? _cts;
    private bool _running;
    private bool _started;
    private const int MaxOutputChars = 400_000;

    /// <summary>6 步全部完成後觸發（TrayContext 用來更新提示）。</summary>
    public event Action? Finished;

    /// <param name="openSettings">開設定視窗（參數＝是否直接開始匯入 .splitswan），回傳儲存後的設定；取消為 null。</param>
    /// <param name="autoStart">開窗就自動執行（重開機後繼續、命令列 --wizard）；否則等使用者按「開始」。</param>
    public WizardForm(VpnCoordinator vpn, Func<bool, Task<StoredSettings?>> openSettings, bool autoStart)
    {
        _vpn = vpn;
        _openSettings = openSettings;
        _state = WizardStore.Load();
        var rebooted = _state.ObserveBoot(WizardStore.CurrentBootTime());
        if (rebooted)
        {
            AppLog.Info("精靈：偵測到已重新開機，從中斷處繼續");
            WizardStore.ClearRunOnce();
        }
        _state.PrepareForOpen();
        WizardStore.Save(_state);

        Text = "SplitSwan 首次設定";
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(780, 620);
        MinimumSize = new Size(640, 500);
        ShowInTaskbar = true;
        Padding = new Padding(16, 14, 16, 12);

        // 列：頁首、進度條、完成／接下來、說明、錯誤、動作按鈕、輸出區（填滿）、下方按鈕
        var main = UiLayout.Table(1, 8);
        main.Dock = DockStyle.Fill;
        main.AutoSize = false;
        main.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int i = 0; i < 6; i++) main.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        main.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        main.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var head = UiLayout.Table(3, 1);
        head.Dock = DockStyle.Fill;
        head.AutoSize = true;
        head.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        head.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        head.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _stepDot.Anchor = AnchorStyles.Left;
        _stepDot.Margin = new Padding(0, 0, 8, 0);
        _title.Anchor = AnchorStyles.Left;
        _title.Margin = Padding.Empty;
        _progressText.Anchor = AnchorStyles.Right;
        _progressText.Margin = Padding.Empty;
        head.Controls.Add(_stepDot, 0, 0);
        head.Controls.Add(_title, 1, 0);
        head.Controls.Add(_progressText, 2, 0);
        main.Controls.Add(head, 0, 0);

        _progress.Dock = DockStyle.Fill;
        _progress.Height = 6;
        _progress.Margin = new Padding(0, 10, 0, 10);
        main.Controls.Add(_progress, 0, 1);

        var lanes = UiLayout.Table(2, 2);
        lanes.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 64));
        lanes.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        lanes.Controls.Add(new ThemedLabel("完成", TextRole.Muted) { Margin = new Padding(0, 2, 6, 4) }, 0, 0);
        lanes.Controls.Add(_doneLane, 1, 0);
        lanes.Controls.Add(new ThemedLabel("接下來", TextRole.Muted) { Margin = new Padding(0, 2, 6, 4) }, 0, 1);
        lanes.Controls.Add(_nextLane, 1, 1);
        _doneLane.MaximumSize = _nextLane.MaximumSize = new Size(640, 0);
        main.Controls.Add(lanes, 0, 2);

        _desc.Margin = new Padding(0, 6, 0, 0);
        main.Controls.Add(_desc, 0, 3);
        _errorCard.Controls.Add(_error);
        _errorCard.Margin = new Padding(0, 8, 0, 0);
        main.Controls.Add(_errorCard, 0, 4);
        _actions.Margin = new Padding(0, 6, 0, 6);
        main.Controls.Add(_actions, 0, 5);

        // 輸出區：兩種主題都是深色底（視覺稿 .term）
        var term = new Panel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(10, 8, 6, 6),
            Margin = new Padding(0, 4, 0, 0),
            BackColor = Theme.C(Theme.Palette.TermBg),
        };
        term.Controls.Add(_output);
        main.Controls.Add(term, 0, 6);

        var buttons = UiLayout.Flow(FlowDirection.RightToLeft);
        buttons.Dock = DockStyle.Fill;
        buttons.Margin = new Padding(0, 10, 0, 0);
        buttons.Controls.AddRange([_close, _next, _retry, _back, _cancelDownload]);
        main.Controls.Add(buttons, 0, 7);
        Controls.Add(main);

        _back.Click += (_, _) => OnBack();
        _retry.Click += (_, _) => OnRetry();
        _next.Click += (_, _) => OnNext();
        _close.Click += (_, _) => Close();
        _cancelDownload.Click += (_, _) => _cts?.Cancel();
        FormClosing += OnFormClosing;
        Shown += (_, _) => { if (autoStart) Begin(); };

        Render();
        if (!autoStart)
            Out("按「開始」後會依序檢查並安裝；已完成的步驟會自動略過。每一步執行的指令與輸出都會顯示在這裡。");
        FinishLayout();
    }

    // MARK: 畫面

    private void Render()
    {
        if (IsDisposed) return;
        var cur = _state.Current;
        _title.Text = WizardOverview.Heading(cur);
        var status = _state.StatusOf(cur);
        _stepDot.Tone = status switch
        {
            WizardStepStatus.Done or WizardStepStatus.Skipped => StatusTone.Ok,
            WizardStepStatus.Failed => StatusTone.Bad,
            WizardStepStatus.Running => StatusTone.Warn,
            _ => _running ? StatusTone.Warn : StatusTone.Idle,
        };
        var (done, next) = WizardOverview.Lanes(_state);
        _doneLane.SetChips(done.Select(SetupWizardState.Title), ChipKind.Soft, mono: false, emptyText: "（還沒有）");
        _nextLane.SetChips(next.Select(SetupWizardState.Title), ChipKind.Local, mono: false, emptyText: "（沒有了）");
        _desc.Text = Describe(cur);
        SetError(_state.ErrorOf(cur) is { } e ? "✖ " + e : "");
        _back.Enabled = !_running && _started && _state.CanGoBack;
        _retry.Enabled = !_running && _started && status != WizardStepStatus.NotStarted;
        _retry.Text = status == WizardStepStatus.Failed ? "重試" : "重新執行";
        _next.Enabled = !_running && (!_started || _state.CanGoNext || (_state.Completed && cur == WizardStep.TestConnection));
        _next.Text = !_started ? "開始" : _state.Completed && cur == WizardStep.TestConnection ? "完成" : "下一步";
        _close.Enabled = !_running || _cancelDownload.Visible;
        if (!_running)
        {
            // 沒在執行：進度條顯示整體進度（已完成步數）
            _progress.Indeterminate = false;
            _progress.Value = WizardOverview.Progress(_state);
            _progressText.Text = $"已完成 {SetupWizardState.Steps.Count(_state.IsFinished)} / {SetupWizardState.Steps.Count}";
        }
    }

    private void SetError(string text)
    {
        _error.Text = text;
        _errorCard.Visible = text.Length > 0;
        _errorCard.AccessibleName = text.Length > 0 ? "錯誤：" + text : null;
    }

    private static string Describe(WizardStep s) => s switch
    {
        WizardStep.SystemCheck => "確認 Windows 版本（10 2004／組建 19041 以上或 Windows 11）、64 位元 x64、以及 BIOS／UEFI 已開啟虛擬化。",
        WizardStep.InstallWsl => "沒有 WSL 時執行 wsl --install --no-distribution --web-download（從 GitHub 下載，不經 Microsoft Store）。" +
                                 "需要重新開機時會提示；重開後登入時會嘗試自動開啟 SplitSwan（需要系統管理員權限，可能跳出 UAC，也可能被 Windows 略過），" +
                                 "沒有自動開啟時請手動開 SplitSwan，會從這一步繼續。",
        WizardStep.ImportDistro => "從 releases.ubuntu.com 下載最新的 Ubuntu 24.04 WSL 映像（約 370 MB），比對 SHA256 後以 wsl --import 匯入成 " +
                                   "SplitSwan 專用的發行版（位置 %LOCALAPPDATA%\\SplitSwan\\wsl），不需要建立 Ubuntu 帳號。",
        WizardStep.SetupStrongSwan => "在發行版內開啟 systemd、用 apt 安裝 strongSwan 與核心模組（第一次要幾分鐘）。不會連線、不改 Windows 路由。",
        WizardStep.Configure => "填入 VPN 設定：匯入公司提供的 .splitswan 設定檔，或手動填寫帳號、密碼、PSK、閘道與內網網段。",
        WizardStep.TestConnection => "用剛才的設定實際連線一次（自動選擇閘道），確認可以連上。",
        _ => "",
    };

    /// <summary>輸出區加一行（任何執行緒）。</summary>
    private void Out(string line)
    {
        if (IsDisposed || Disposing) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(() => Out(line)); } catch (InvalidOperationException) { }
            return;
        }
        _output.AppendLine(line);   // 太長時從頭砍一半；AppendText 會自動捲到最後
    }

    private void OnProgress(long done, long? total)
    {
        if (IsDisposed || Disposing) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(() => OnProgress(done, total)); } catch (InvalidOperationException) { }
            return;
        }
        if (total is { } t && t > 0)
        {
            _progress.Indeterminate = false;
            _progress.Value = Math.Clamp((double)done / t, 0, 1);
        }
        else
        {
            _progress.Indeterminate = true;
        }
        _progressText.Text = "下載中：" + UbuntuWslImages.FormatProgress(done, total);
    }

    /// <summary>下載階段才能取消／關閉視窗（匯入、安裝進行中不中途中止）。</summary>
    private void OnDownloading(bool on)
    {
        if (IsDisposed || Disposing) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(() => OnDownloading(on)); } catch (InvalidOperationException) { }
            return;
        }
        _cancelDownload.Visible = on;
        _close.Enabled = on;
    }

    private void ClearActions()
    {
        foreach (Control c in _actions.Controls.Cast<Control>().ToList()) c.Dispose();
        _actions.Controls.Clear();
        _wizDesktop = _wizStartMenu = null;   // 捷徑選項也放在 _actions 裡，已一起釋放
    }

    private void AddAction(string text, Action onClick)
    {
        var b = new ThemedButton(text) { Margin = new Padding(0, 0, 6, 0) };
        b.Click += (_, _) => onClick();
        _actions.Controls.Add(b);
    }

    // MARK: 按鈕

    private void Begin()
    {
        _started = true;
        _ = RunAsync(force: false);
    }

    private void OnNext()
    {
        if (!_started) { Begin(); return; }
        if (_state.Completed && _state.Current == WizardStep.TestConnection)
        {
            // 第一次按「完成」：建立勾選的捷徑並把結果留在輸出區；再按一次才關閉
            if (!_shortcutsApplied && _wizDesktop is not null && _wizStartMenu is not null) { ApplyWizardShortcuts(); return; }
            Close();
            return;
        }
        if (_state.GoNext()) { WizardStore.Save(_state); _ = RunAsync(force: false); }
    }

    private void OnRetry()
    {
        _state.Reset(_state.Current);
        WizardStore.Save(_state);
        _ = RunAsync(force: true);
    }

    private void OnBack()
    {
        if (!_state.GoBack()) return;
        ClearActions();
        WizardStore.Save(_state);
        Out($"── 回到步驟 {(int)_state.Current + 1}：{SetupWizardState.Title(_state.Current)}（按「重新執行」再跑一次）");
        Render();
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        if (!_running || e.CloseReason is CloseReason.WindowsShutDown or CloseReason.ApplicationExitCall or CloseReason.TaskManagerClosing) return;
        if (_cancelDownload.Visible)
        {
            _cts?.Cancel();
            return;
        }
        e.Cancel = true;
        MessageBox.Show(this, "目前步驟正在執行（例如匯入發行版或安裝 strongSwan），中途中止可能留下一半的狀態。請等它完成再關閉。",
            "SplitSwan", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    // MARK: 流程

    /// <summary>
    /// 從目前步驟往下自動執行。force＝使用者按了「重試／重新執行」：目前這一步不因先前完成而跳過。
    /// 停下來的時機：失敗、要重開機、要使用者填設定、全部完成。
    /// </summary>
    private async Task RunAsync(bool force)
    {
        if (_running) return;
        _running = true;
        ClearActions();
        _cts = new CancellationTokenSource();
        try
        {
            while (!IsDisposed)
            {
                var step = _state.Current;
                if (!force && _state.IsFinished(step))
                {
                    if (!_state.GoNext()) break;
                    continue;
                }
                force = false;
                var result = await RunStepAsync(step, _cts.Token);
                if (IsDisposed) return;
                switch (result.Outcome)
                {
                    case StepOutcome.Done:
                    case StepOutcome.Skipped:
                        _state.Complete(step, skipped: result.Outcome == StepOutcome.Skipped);
                        Out($"✔ 步驟 {(int)step + 1}「{SetupWizardState.Title(step)}」" + (result.Outcome == StepOutcome.Skipped ? "已完成（略過）" : "完成"));
                        WizardStore.Save(_state);
                        if (step == WizardStep.InstallWsl) WizardStore.ClearRunOnce();
                        if (!_state.GoNext()) { OnAllDone(); return; }
                        WizardStore.Save(_state);
                        Render();
                        continue;
                    case StepOutcome.WaitingReboot:
                        _state.RequireReboot(WizardStore.CurrentBootTime());
                        WizardStore.Save(_state);
                        ShowRebootActions();
                        return;
                    case StepOutcome.WaitingUser:
                        _state.Reset(step);
                        WizardStore.Save(_state);
                        ShowConfigureActions();
                        return;
                    default:
                        _state.Fail(step, result.Error ?? "失敗");
                        WizardStore.Save(_state);
                        Out($"✖ 步驟 {(int)step + 1}「{SetupWizardState.Title(step)}」失敗：{result.Error}");
                        AppLog.Error($"精靈步驟 {SetupWizardState.Title(step)} 失敗：{result.Error}");
                        // 測試連線失敗常是設定內容錯（例如密碼）：直接在精靈裡提供修改設定，存檔後重測
                        if (step == WizardStep.TestConnection)
                        {
                            AddAction("修改設定…", () => _ = ReconfigureAsync());
                            Out("若是帳號、密碼或閘道有誤，按「修改設定…」改完儲存後會自動重新測試；否則按「重試」。");
                        }
                        return;
                }
            }
            if (_state.Completed) OnAllDone();
        }
        catch (Exception ex)
        {
            // async 例外沒人接會結束 App：攔下來記成目前步驟失敗
            var msg = $"{ex.GetType().Name}：{ex.Message}";
            AppLog.Error("精靈發生未預期的錯誤：" + msg);
            if (!IsDisposed)
            {
                _state.Fail(_state.Current, "發生未預期的錯誤：" + msg);
                WizardStore.Save(_state);
                Out("✖ " + msg);
            }
        }
        finally
        {
            _running = false;
            _cts?.Dispose();
            _cts = null;
            // 下載中關閉視窗時，這裡執行時控制項已經釋放
            if (!IsDisposed && !Disposing)
            {
                _cancelDownload.Visible = false;
                Render();
            }
        }
    }

    private async Task<StepResult> RunStepAsync(WizardStep step, CancellationToken ct)
    {
        _state.Start(step);
        Render();
        Out("");
        Out($"══ 步驟 {(int)step + 1}：{SetupWizardState.Title(step)}");
        UiWatchdog.Mark("精靈：開始 " + SetupWizardState.Title(step));
        _progress.Indeterminate = true;
        _progressText.Text = "執行中…";
        _close.Enabled = false;
        var ctx = new WizardContext { Output = Out, Progress = OnProgress, Downloading = OnDownloading, Vpn = _vpn, State = _state };
        try
        {
            return step switch
            {
                WizardStep.SystemCheck => await WizardSteps.SystemCheckAsync(ctx, ct),
                WizardStep.InstallWsl => await WizardSteps.InstallWslAsync(ctx, ct),
                WizardStep.ImportDistro => await WizardSteps.ImportDistroAsync(ctx, ct),
                WizardStep.SetupStrongSwan => await WizardSteps.SetupStrongSwanAsync(ctx, ct),
                WizardStep.Configure => ConfiguredJustNow(WizardSteps.CheckConfigured(ctx)),
                WizardStep.TestConnection => await WizardSteps.TestConnectionAsync(ctx),
                _ => StepResult.Fail("未知的步驟"),
            };
        }
        finally
        {
            if (!IsDisposed && !Disposing)
            {
                _cancelDownload.Visible = false;
                _progress.Indeterminate = false;
                _progressText.Text = "";
            }
            UiWatchdog.Mark("精靈：結束 " + SetupWizardState.Title(step));
        }
    }

    private void ShowRebootActions()
    {
        ClearActions();
        var why = WizardStore.RegisterRunOnce();
        SetError("");
        _desc.Text = Describe(WizardStep.InstallWsl);
        Out(why is null
            ? "需要重新開機：重開後登入時會嘗試自動開啟 SplitSwan 並繼續（可能跳出 UAC；若沒有自動開啟，請手動開 SplitSwan，會從這一步繼續）。"
            : $"需要重新開機：{why}。重開後請手動開啟 SplitSwan，精靈會從這一步繼續。");
        AddAction("立即重新開機", RebootNow);
        AddAction("稍後再重新開機", () =>
        {
            Out("好的。重開機後開啟 SplitSwan 就會從這一步繼續。");
            Close();
        });
        Render();
    }

    private void RebootNow()
    {
        var r = MessageBox.Show(this, "要立即重新開機嗎？請先儲存其他程式的工作。", "SplitSwan － 重新開機",
            MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
        if (r != DialogResult.OK) return;
        try
        {
            AppLog.Info("精靈：使用者選擇立即重新開機");
            var shutdown = Path.Combine(Environment.SystemDirectory, "shutdown.exe");
            var psi = new ProcessStartInfo(shutdown) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in new[] { "/r", "/t", "5", "/c", "SplitSwan 首次設定：重新開機以完成 WSL 安裝" }) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            Out("5 秒後重新開機…");
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            Out("無法重新開機：" + ex.Message + "。請從「開始」選單手動重新開機。");
        }
    }

    private void ShowConfigureActions()
    {
        ClearActions();
        AddAction("匯入 .splitswan…", () => _ = ConfigureAsync(importOnShow: true));
        AddAction("手動填寫…", () => _ = ConfigureAsync(importOnShow: false));
        Out("請匯入公司提供的 .splitswan 設定檔，或手動填寫；儲存後精靈會自動繼續。");
        Render();
    }

    /// <summary>使用者剛在設定視窗儲存過：算「實際做了」，讓之後的測試連線重做。</summary>
    private StepResult ConfiguredJustNow(StepResult r)
    {
        var just = _configuredJustNow;
        _configuredJustNow = false;
        return just && r.Outcome == StepOutcome.Skipped ? new(StepOutcome.Done) : r;
    }

    private bool _configuredJustNow;

    private async Task ConfigureAsync(bool importOnShow)
    {
        if (_running) return;
        var saved = await _openSettings(importOnShow);
        if (IsDisposed) return;
        if (saved is null) { Out("設定視窗已關閉（沒有儲存）。"); return; }
        Out("設定已儲存。");
        _configuredJustNow = true;
        ClearActions();
        _ = RunAsync(force: false);   // 回到「設定」步驟重新偵測，通過就繼續測試連線
    }

    /// <summary>測試連線失敗後修改設定：存檔就重新測試連線。</summary>
    private async Task ReconfigureAsync()
    {
        if (_running) return;
        var saved = await _openSettings(false);
        if (IsDisposed || saved is null) return;
        Out("設定已儲存，重新測試連線。");
        ClearActions();
        _state.Reset(WizardStep.TestConnection);
        WizardStore.Save(_state);
        _ = RunAsync(force: true);
    }

    private void OnAllDone()
    {
        WizardStore.Save(_state);
        WizardStore.ClearRunOnce();
        ClearActions();
        Out("");
        Out("══ 全部完成！之後從工作列右下角的 SplitSwan 圖示按右鍵就能連線／斷線。");
        AppLog.Info("首次設定精靈：全部完成");
        ShowShortcutChoices();
        Render();
        Finished?.Invoke();
    }

    /// <summary>完成畫面：「建立桌面捷徑」「加到開始選單」兩個勾選（預設勾選）。</summary>
    private void ShowShortcutChoices()
    {
        _shortcutsApplied = false;
        _wizDesktop = new ToggleSwitch("建立桌面捷徑") { Checked = true, Margin = new Padding(0, 2, 16, 2) };
        _wizStartMenu = new ToggleSwitch("加到開始選單") { Checked = true, Margin = new Padding(0, 2, 0, 2) };
        // 明確指定欄列（TableLayoutPanel 自動排列會跳過隱藏的控制項）
        var t = UiLayout.Table(2, 1);
        t.Controls.Add(_wizDesktop, 0, 0);
        t.Controls.Add(_wizStartMenu, 1, 0);
        _actions.Controls.Add(t);
        Out("勾選要建立的捷徑後按「完成」（之後也可以在「設定」的「捷徑」區塊開關；從捷徑啟動一樣會跳出 UAC）。");
    }

    /// <summary>建立勾選的捷徑，每一項的結果寫在輸出區。失敗不影響精靈已完成的狀態。</summary>
    private void ApplyWizardShortcuts()
    {
        var picks = new List<ShortcutLocation>();
        if (_wizDesktop?.Checked == true) picks.Add(ShortcutLocation.Desktop);
        if (_wizStartMenu?.Checked == true) picks.Add(ShortcutLocation.StartMenu);
        _shortcutsApplied = true;
        ClearActions();
        Out("");
        Out("══ 建立捷徑");
        if (picks.Count == 0) Out("沒有勾選，未建立捷徑。");
        foreach (var loc in picks)
        {
            try
            {
                Out(ShortcutRules.ResultLine(loc, Shortcuts.Apply(loc, wantOn: true)));
            }
            catch (Exception ex)
            {
                // 任何例外都只算這一項失敗（寫記錄與輸出區），不影響另一項與精靈已完成的狀態
                AppLog.Error($"精靈建立{ShortcutRules.Title(loc)}失敗：{ex.GetType().Name}：{ex.Message}");
                Out(ShortcutRules.ResultLine(loc, ShortcutAction.Create, ex.Message));
            }
        }
        Out("按「完成」關閉精靈。");
        Render();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _cts?.Cancel();
            ClearActions();
        }
        base.Dispose(disposing);
    }
}
