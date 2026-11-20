using System.Diagnostics;
using System.Runtime.InteropServices;
using SplitSwan.Core;

namespace SplitSwan.Tray.Controls;

/// <summary>
/// 系統的「動畫效果」設定（設定 → 協助工具 → 視覺效果）。關閉時介面不做位移與縮放，只留短淡入或不動（同 Mac 的「減少動態效果」）。
/// 每次開始動畫時重讀（SystemParametersInfo 很便宜），使用者切換設定後下一次動畫就生效。
/// </summary>
internal static class MotionPrefs
{
    /// <summary>SPI_GETCLIENTAREAANIMATION（learn.microsoft.com/windows/win32/api/winuser/nf-winuser-systemparametersinfow）。</summary>
    private const uint SpiGetClientAreaAnimation = 0x1042;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfo(uint action, uint param, out int value, uint winIni);

    /// <summary>是否減少動態效果：「動畫效果」關閉，或整體 UI 效果關閉（遠端桌面等）。讀不到時以 UI 效果為準。</summary>
    public static bool Reduced
    {
        get
        {
            if (!SystemInformation.UIEffectsEnabled) return true;
            try
            {
                if (SystemParametersInfo(SpiGetClientAreaAnimation, 0, out var on, 0)) return on == 0;
            }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException) { }
            return false;
        }
    }
}

/// <summary>進行中的一段動畫；Stop 後不再呼叫畫格與完成回呼。</summary>
internal sealed class Animation
{
    internal Animation(Control owner, double seconds, Action<double> frame, Action? done)
    {
        Owner = owner;
        Seconds = seconds;
        Frame = frame;
        Done = done;
    }

    internal Control Owner { get; }
    internal double Seconds { get; }
    internal Action<double> Frame { get; }
    internal Action? Done { get; }
    /// <summary>
    /// 第一個計時器畫格才開始計時：開始動畫的同一輪常緊接著版面配置與第一次繪製（例如錯誤說明剛顯示），
    /// 若從呼叫 Start 就計時，UI 執行緒忙完時動畫可能已經播完，使用者一格也看不到。
    /// </summary>
    internal Stopwatch Clock { get; } = new();
    public bool Stopped { get; private set; }

    public void Stop() => Stopped = true;
}

/// <summary>
/// 全 App 共用一個 UI 執行緒計時器（約 60 fps）驅動短動畫；沒有動畫時計時器停止。只在 UI 執行緒使用。
/// 畫格回呼收到的是線性進度 0～1（曲線由呼叫端套 Motion.EaseInOut）；擁有者控制項被 Dispose 時動畫自動結束。
/// </summary>
internal static class Animator
{
    private static readonly List<Animation> Active = [];
    private static System.Windows.Forms.Timer? _timer;

    /// <summary>開始一段動畫；seconds ≤ 0 時立即畫最後一格並完成。</summary>
    public static Animation Start(Control owner, double seconds, Action<double> frame, Action? done = null)
    {
        var a = new Animation(owner, seconds, frame, done);
        if (seconds <= 0)
        {
            frame(1);
            done?.Invoke();
            a.Stop();
            return a;
        }
        frame(0);
        Active.Add(a);
        _timer ??= CreateTimer();
        _timer.Start();
        return a;
    }

    private static System.Windows.Forms.Timer CreateTimer()
    {
        var t = new System.Windows.Forms.Timer { Interval = 15 };
        t.Tick += (_, _) => Tick();
        return t;
    }

    private static void Tick()
    {
        foreach (var a in Active.ToList())
        {
            if (a.Stopped || a.Owner.IsDisposed) { Active.Remove(a); continue; }
            if (!a.Clock.IsRunning) a.Clock.Start();
            var p = Motion.Progress(a.Clock.Elapsed.TotalSeconds, a.Seconds);
            a.Frame(p);
            if (p < 1) continue;
            Active.Remove(a);
            a.Stop();
            a.Done?.Invoke();
        }
        if (Active.Count == 0) _timer?.Stop();
    }
}

/// <summary>
/// 驗證失敗時左右搖晃（6px、3 次、0.3 秒）；減少動態效果時不動，只靠紅字提示。
/// 搖的是控制項的左右內距（內容在外框裡位移），不是 Left：要搖的控制項都放在 TableLayoutPanel／FlowLayoutPanel 裡，
/// 改 Left 會立刻被版面配置拉回；內距左加右減總寬不變，外框與周圍版面都不動。
/// 只適用依 Padding 擺放內容的控制項（SectionCard 系列、InputFrame）。
/// </summary>
internal static class Shake
{
    private static readonly Dictionary<Control, (Animation Anim, Padding Base)> Running = new();

    public static void Run(Control c)
    {
        if (c.IsDisposed || !c.Visible) return;
        var reduced = MotionPrefs.Reduced;
        if (reduced) return;
        var basePadding = c.Padding;
        if (Running.Remove(c, out var old))
        {
            old.Anim.Stop();
            basePadding = old.Base;
        }
        var travel = c.LogicalToDeviceUnits((int)Motion.ShakeTravel);
        var anim = Animator.Start(c, Motion.ShakeDuration,
            p =>
            {
                var (left, right) = Motion.ShakePadding(basePadding.Left, basePadding.Right, p, reduced, travel);
                c.Padding = new Padding(left, basePadding.Top, right, basePadding.Bottom);
            },
            () =>
            {
                Running.Remove(c);
                c.Padding = basePadding;
            });
        Running[c] = (anim, basePadding);
    }
}

/// <summary>清單交錯出場：每列由下往上 6px 並淡入，間隔 0.04 秒、最多延遲 0.25 秒；減少動態效果時只淡入。</summary>
internal static class Stagger
{
    /// <summary>在版面排好之後呼叫（列已在最終位置）。</summary>
    public static void Reveal(IReadOnlyList<ThemedLabel> rows)
    {
        if (rows.Count == 0) return;
        var reduced = MotionPrefs.Reduced;
        var owner = rows[0].Parent ?? rows[0];
        var bases = rows.Select(r => r.Top).ToArray();
        void Apply(double elapsed)
        {
            for (int i = 0; i < rows.Count; i++)
            {
                var r = rows[i];
                if (r.IsDisposed) continue;
                var (opacity, offset) = Motion.StaggerFrame(i, elapsed, reduced);
                r.Reveal = opacity;
                r.Top = bases[i] + r.LogicalToDeviceUnits((int)Math.Round(offset));
            }
        }
        var total = Motion.StaggerTotal(rows.Count, reduced);
        Animator.Start(owner, total, p => Apply(p * total), () => owner.PerformLayout());
    }
}
