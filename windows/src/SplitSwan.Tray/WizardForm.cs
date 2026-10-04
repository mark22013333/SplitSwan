using System.Diagnostics;
using System.Drawing;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 首次設定精靈（契約 6）。左側步驟清單（✔／▶／○／✖），右側說明、進度條、唯讀輸出區與按鈕。
/// 步驟規則在 Core 的 SetupWizardState，各步驟的動作在 WizardSteps；這裡只處理畫面與流程控制：
/// - 按「開始」後自動一路執行；遇到失敗、要重開機、要使用者填設定時停下來。
/// - 已完成的步驟偵測到就自動略過；狀態每一步都存 wizard.json，重開機後從中斷處繼續。
/// </summary>
internal sealed class WizardForm : Form
{
    private readonly VpnCoordinator _vpn;
    private readonly Func<bool, Task<StoredSettings?>> _openSettings;
    private readonly SetupWizardState _state;
    private readonly ListBox _steps = new()
    {
        Dock = DockStyle.Fill, IntegralHeight = false, SelectionMode = SelectionMode.None,
        Font = new Font("Microsoft JhengHei UI", 10f), BorderStyle = BorderStyle.None,
    };
    private readonly Label _title = new() { AutoSize = true, Font = new Font("Microsoft JhengHei UI", 12f, FontStyle.Bold) };
    private readonly Label _desc = new() { AutoSize = true, MaximumSize = new Size(560, 0) };
    private readonly Label _error = new() { AutoSize = true, MaximumSize = new Size(560, 0), ForeColor = Color.FromArgb(0xC0, 0x1C, 0x28) };
    private readonly ProgressBar _progress = new() { Width = 560, Height = 16, Visible = false };
    private readonly Label _progressText = new() { AutoSize = true, ForeColor = SystemColors.GrayText };
    private readonly TextBox _output = new()
    {
        Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Dock = DockStyle.Fill,
        Font = new Font("Consolas", 9f), BackColor = SystemColors.Window,
    };
    private readonly FlowLayoutPanel _actions = new() { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 4, 0, 4) };
    private readonly Button _back = new() { Text = "上一步", AutoSize = true };
    private readonly Button _retry = new() { Text = "重試", AutoSize = true };
    private readonly Button _next = new() { Text = "開始", AutoSize = true };
    private readonly Button _close = new() { Text = "關閉", AutoSize = true };
    private readonly Button _cancelDownload = new() { Text = "取消下載", AutoSize = true, Visible = false };

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

        Text = "SplitSwan － 首次設定精靈";
        AppIcon.Apply(this);
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(900, 620);
        MinimumSize = new Size(760, 520);
        Font = new Font("Microsoft JhengHei UI", 9f);
        ShowInTaskbar = true;

        var split = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(10) };
        split.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 200));
        split.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        var right = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 8, Padding = new Padding(10, 0, 0, 0) };
        right.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // 標題
        right.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // 說明
        right.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // 錯誤
        right.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // 動作按鈕（重開機、設定…）
        right.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // 進度條
        right.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // 進度文字
        right.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); // 輸出區
        right.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // 下方按鈕
        right.Controls.Add(_title, 0, 0);
        right.Controls.Add(_desc, 0, 1);
        right.Controls.Add(_error, 0, 2);
        right.Controls.Add(_actions, 0, 3);
        right.Controls.Add(_progress, 0, 4);
        right.Controls.Add(_progressText, 0, 5);
        right.Controls.Add(_output, 0, 6);
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        buttons.Controls.AddRange([_close, _next, _retry, _back, _cancelDownload]);
        right.Controls.Add(buttons, 0, 7);

        split.Controls.Add(_steps, 0, 0);
        split.Controls.Add(right, 1, 0);
        Controls.Add(split);

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
    }

    // MARK: 畫面

    private void Render()
    {
        if (IsDisposed) return;
        _steps.BeginUpdate();
        _steps.Items.Clear();
        foreach (var s in SetupWizardState.Steps)
            _steps.Items.Add($"{_state.Mark(s)} {(int)s + 1}. {SetupWizardState.Title(s)}");
        _steps.EndUpdate();

        var cur = _state.Current;
        _title.Text = $"步驟 {(int)cur + 1}／6：{SetupWizardState.Title(cur)}";
        _desc.Text = Describe(cur);
        _error.Text = _state.ErrorOf(cur) is { } e ? "✖ " + e : "";
        var status = _state.StatusOf(cur);
        _back.Enabled = !_running && _started && _state.CanGoBack;
        _retry.Enabled = !_running && _started && status != WizardStepStatus.NotStarted;
        _retry.Text = status == WizardStepStatus.Failed ? "重試" : "重新執行";
        _next.Enabled = !_running && (!_started || _state.CanGoNext || (_state.Completed && cur == WizardStep.TestConnection));
        _next.Text = !_started ? "開始" : _state.Completed && cur == WizardStep.TestConnection ? "完成" : "下一步";
        _close.Enabled = !_running || _cancelDownload.Visible;
        if (!_running) { _progress.Visible = false; _progressText.Text = ""; }
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
        if (_output.TextLength > MaxOutputChars) _output.Text = _output.Text[^(MaxOutputChars / 2)..];
        _output.AppendText(line + Environment.NewLine);   // AppendText 會自動捲到最後
    }

    private void OnProgress(long done, long? total)
    {
        if (IsDisposed || Disposing) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(() => OnProgress(done, total)); } catch (InvalidOperationException) { }
            return;
        }
        _progress.Visible = true;
        if (total is { } t && t > 0)
        {
            _progress.Style = ProgressBarStyle.Continuous;
            _progress.Maximum = 1000;
            _progress.Value = (int)Math.Clamp(done * 1000 / t, 0, 1000);
        }
        else
        {
            _progress.Style = ProgressBarStyle.Marquee;
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
        foreach (Control c in _actions.Controls) c.Dispose();
        _actions.Controls.Clear();
    }

    private void AddAction(string text, Action onClick)
    {
        var b = new Button { Text = text, AutoSize = true };
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
        if (_state.Completed && _state.Current == WizardStep.TestConnection) { Close(); return; }
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
        _progress.Style = ProgressBarStyle.Marquee;
        _progress.Visible = true;
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
                _progress.Visible = false;
                _progressText.Text = "";
            }
            UiWatchdog.Mark("精靈：結束 " + SetupWizardState.Title(step));
        }
    }

    private void ShowRebootActions()
    {
        ClearActions();
        var why = WizardStore.RegisterRunOnce();
        _error.Text = "";
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
        Render();
        Finished?.Invoke();
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
