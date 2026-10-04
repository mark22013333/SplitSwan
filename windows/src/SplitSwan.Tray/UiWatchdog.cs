namespace SplitSwan.Tray;

/// <summary>
/// 偵測 UI 執行緒卡住：背景執行緒每 2 秒往 UI 執行緒投遞一次「報到」，
/// 超過 5 秒沒報到就寫一行記錄（含最後一個記錄點），卡住期間每 30 秒再寫一次，恢復時也寫一次。
/// 記錄由背景執行緒寫入，所以 UI 完全凍結時記錄檔仍看得到卡在哪一步。
/// </summary>
internal sealed class UiWatchdog : IDisposable
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan HangThreshold = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan RepeatEvery = TimeSpan.FromSeconds(30);

    private static string _lastMark = "（尚無）";

    private readonly SynchronizationContext _ui;
    private readonly CancellationTokenSource _cts = new();
    private long _lastBeatTicks = Environment.TickCount64;

    /// <summary>記錄目前走到哪一步（任何執行緒都可呼叫），同時寫進記錄。</summary>
    public static void Mark(string step)
    {
        Volatile.Write(ref _lastMark, $"{DateTime.Now:HH:mm:ss} {step}");
        AppLog.Info("［記錄點］" + step);
    }

    public UiWatchdog(SynchronizationContext ui)
    {
        _ui = ui;
        var thread = new Thread(Loop) { IsBackground = true, Name = "UiWatchdog" };
        thread.Start();
    }

    private void Loop()
    {
        var hung = false;
        long lastReport = 0;
        while (!_cts.IsCancellationRequested)
        {
            _ui.Post(_ => Interlocked.Exchange(ref _lastBeatTicks, Environment.TickCount64), null);
            if (_cts.Token.WaitHandle.WaitOne(Interval)) return;

            var now = Environment.TickCount64;
            var silent = TimeSpan.FromMilliseconds(now - Interlocked.Read(ref _lastBeatTicks));
            if (silent > HangThreshold)
            {
                if (!hung || now - lastReport >= RepeatEvery.TotalMilliseconds)
                {
                    AppLog.Error($"UI 執行緒已 {(int)silent.TotalSeconds} 秒沒有回應；最後一個記錄點：{Volatile.Read(ref _lastMark)}");
                    lastReport = now;
                }
                hung = true;
            }
            else if (hung)
            {
                AppLog.Info("UI 執行緒已恢復回應");
                hung = false;
            }
        }
    }

    public void Dispose() => _cts.Cancel();
}
