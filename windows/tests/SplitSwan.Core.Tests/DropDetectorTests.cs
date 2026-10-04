namespace SplitSwan.Core.Tests;

/// <summary>移植 Mac 版 Tests/ReconnectTests.swift:163-228 的 F2 非預期斷線通知案例。</summary>
public class DropDetectorTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_000_000);
    private static DateTimeOffset At(double s) => T0.AddSeconds(s);
    private static DropDetector New() => new(TimeSpan.FromSeconds(30));

    /// <summary>依序餵 (秒, 想連線, 已連線)，回傳每一步的結果。</summary>
    private static List<DropAction> Feed(DropDetector d, params (double s, bool want, bool conn)[] steps) =>
        steps.Select(x => d.Evaluate(At(x.s), x.want, x.conn, networkAvailable: true)).ToList();

    private static DropAction Step(DropDetector d, double s, bool connected = false, bool paused = false) =>
        d.Evaluate(At(s), wantConnected: true, isConnected: connected, networkAvailable: !paused);

    private static void AllNone(IEnumerable<DropAction> a) => Assert.All(a, x => Assert.Equal(DropAction.None, x));

    [Fact]
    public void DropAndRestoreCycle()
    {
        var d = New();
        AllNone(Feed(d, (0, true, true), (3, true, false), (32, true, false)));             // 掉線 29 秒不發
        Assert.Equal(DropAction.NotifyDrop, d.Evaluate(At(33), true, false, true));         // 滿 30 秒發一次掉線通知
        AllNone(Feed(d, (36, true, false), (120, true, false), (600, true, false)));        // 之後持續斷線不重複
        Assert.Equal(DropAction.NotifyRestore, d.Evaluate(At(603), true, true, true));      // 恢復時發恢復通知
        AllNone(Feed(d, (606, true, true), (609, true, true)));                             // 恢復通知只發一次
        Assert.Equal([DropAction.None, DropAction.NotifyDrop], Feed(d, (700, true, false), (730, true, false))); // 再掉線超過 30 秒可以再發
        Assert.Equal(DropAction.NotifyRestore, d.Evaluate(At(733), true, true, true));      // 第二次恢復也會發
    }

    [Fact]
    public void RecoveredWithinThreshold_NoNotification_AndTimerResets()
    {
        var d = New();
        // App 自己重建通道（down → up）28 秒內完成：不發，且重置計時
        AllNone(Feed(d, (0, true, true), (3, true, false), (30, true, false), (31, true, true)));
        Assert.Null(d.DownSince);
        AllNone(Feed(d, (40, true, false), (69, true, false)));   // 重置後重新計時：再斷 29 秒不發
    }

    [Fact]
    public void UserDisconnect_NoNotification_AndStateReset()
    {
        var d = New();
        AllNone(Feed(d, (0, true, false), (20, false, false), (60, false, false), (100, false, true)));
        Assert.Null(d.DownSince);
        Assert.False(d.DropNotified);
    }

    [Fact]
    public void UserDisconnectAfterDropNotified_NoRestoreNotification()
    {
        var d = New();
        Feed(d, (0, true, false), (30, true, false));
        AllNone(Feed(d, (40, false, false), (50, true, true)));
    }

    [Fact]
    public void Reset_RestartsTimer()
    {
        var d = New();
        Feed(d, (0, true, false), (25, true, false));
        d.Reset();   // 對應 VPNController.disconnect() 立即重置
        AllNone(Feed(d, (26, true, false), (50, true, false)));
    }

    // Mac 版「開關關閉：掉線不發」「掉線通知後關閉開關：恢復也不發」：
    // Windows 版沒有 enabled 參數，約定為「關閉時呼叫端呼叫 Reset() 且不發通知」，這裡驗證該約定可達到相同效果
    [Fact]
    public void DisabledByCallerReset_AfterDrop_NoRestore()
    {
        var d = New();
        Feed(d, (0, true, false), (30, true, false));
        d.Reset();   // 使用者關閉通知
        Assert.Equal(DropAction.None, d.Evaluate(At(43), true, true, true));
    }

    // 暫停計時：沒網路時不算掉線
    [Fact]
    public void NoNetwork_PausesTimer()
    {
        var d = New();
        AllNone([Step(d, 0), Step(d, 10, paused: true), Step(d, 100, paused: true)]);   // 暫停期間不發
        AllNone([Step(d, 110), Step(d, 139)]);                                          // 暫停結束後重新計時：29 秒不發
        Assert.Equal(DropAction.NotifyDrop, Step(d, 140));                              // 暫停結束後滿 30 秒才發
        Assert.Equal(DropAction.None, Step(d, 150, paused: true));                      // 已發掉線通知後暫停：不重複發
        Assert.True(d.DropNotified);
        Assert.Equal(DropAction.NotifyRestore, Step(d, 160, connected: true));          // 暫停後接回：仍發恢復通知
    }

    // 睡眠喚醒：睡前開始的計時不算，喚醒後重新計時
    [Fact]
    public void Wake_RestartGrace_DoesNotCountSleep()
    {
        var d = New();
        Step(d, 0);
        d.RestartGrace();
        Assert.Equal(DropAction.None, Step(d, 600));                   // 喚醒後第一次更新不因睡眠時間發通知
        Assert.Equal(DropAction.None, Step(d, 620, connected: true));  // 喚醒後 30 秒內接回不發
    }

    [Fact]
    public void Wake_AfterDropNotified_KeepsRestoreNotification()
    {
        var d = New();
        Step(d, 0); Step(d, 30);
        d.RestartGrace();
        Assert.True(d.DropNotified);
        Assert.Equal(DropAction.NotifyRestore, Step(d, 700, connected: true));
    }

    // 契約的 bool Update：只在該發斷線通知時回 true（恢復通知回 false）
    [Fact]
    public void Update_ReturnsTrueOnlyForDrop()
    {
        var d = New();
        Assert.False(d.Update(At(0), true, false, true));
        Assert.False(d.Update(At(29), true, false, true));
        Assert.True(d.Update(At(30), true, false, true));
        Assert.False(d.Update(At(31), true, false, true));
        Assert.False(d.Update(At(40), true, true, true));   // 恢復
    }

    [Fact]
    public void CustomThreshold_Respected()
    {
        var d = new DropDetector(TimeSpan.FromSeconds(10));
        Assert.False(d.Update(At(0), true, false, true));
        Assert.True(d.Update(At(10), true, false, true));
    }

    [Fact]
    public void NegativeThreshold_Throws() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => new DropDetector(TimeSpan.FromSeconds(-1)));

    [Fact] public void DropTitle() => Assert.Equal("SplitSwan 已斷線", DropDetector.DropTitle("SplitSwan"));
    [Fact] public void RestoreTitle() => Assert.Equal("SplitSwan 已恢復連線", DropDetector.RestoreTitle("SplitSwan"));
    [Fact] public void RestoreBody_WithGateway() => Assert.Equal("VPN2 已重新連上", DropDetector.RestoreBody("vpn2"));
    [Fact] public void RestoreBody_WithoutGateway() => Assert.Equal("VPN 已重新連上", DropDetector.RestoreBody(null));
    [Fact] public void RestoreBody_BareVpn() => Assert.Equal("VPN 已重新連上", DropDetector.RestoreBody("vpn"));
    [Fact] public void DropBody() => Assert.Equal("VPN 中斷超過 30 秒，正在自動重連", DropDetector.DropBody(TimeSpan.FromSeconds(30)));
}
