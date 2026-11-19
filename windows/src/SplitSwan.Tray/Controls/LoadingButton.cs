using System.ComponentModel;
using System.Drawing;
using SplitSwan.Core;

namespace SplitSwan.Tray.Controls;

/// <summary>
/// 載入按鈕（Mac 的 LoadingButton）：進行中時文字左側轉圈（減少動態效果時是靜態沙漏），
/// 以 <see cref="Finish"/> 結束；成功時打勾 1.2 秒。主要按鈕用強調色底，其他用外框樣式（ThemedButton）。
/// 進行中是否可按由呼叫端以 Enabled 決定（有的動作允許再按一次取消）。
/// </summary>
internal sealed class LoadingButton : ThemedButton
{
    private readonly System.Windows.Forms.Timer _spin = new() { Interval = 30 };
    private readonly System.Windows.Forms.Timer _doneTimer = new() { Interval = (int)(Motion.DoneSeconds * 1000) };
    private bool _loading;
    private bool _done;
    private bool _reduced;
    private float _angle;

    public LoadingButton(string text, bool primary = false) : base(text, primary)
    {
        _spin.Tick += (_, _) => { _angle = (_angle + 12f) % 360f; Invalidate(); };
        _doneTimer.Tick += (_, _) => { _doneTimer.Stop(); _done = false; Relayout(); };
    }

    /// <summary>是否進行中（轉圈）。設為 false 等於 Finish(false)：不打勾。</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool IsLoading
    {
        get => _loading;
        set
        {
            if (value) Begin();
            else Finish(false);
        }
    }

    /// <summary>目前是否顯示完成的打勾（測試與截圖用）。</summary>
    public bool ShowingDone => _done;

    public void Begin()
    {
        if (_loading) return;
        _loading = true;
        _done = false;
        _doneTimer.Stop();
        _reduced = MotionPrefs.Reduced;
        _spin.Enabled = !_reduced;
        AccessibleDescription = "處理中";
        Relayout();
    }

    /// <summary>結束進行中；succeeded 時打勾 1.2 秒再恢復。</summary>
    public void Finish(bool succeeded)
    {
        if (!_loading) return;
        _loading = false;
        _spin.Stop();
        _done = succeeded && !IsDisposed;
        AccessibleDescription = succeeded ? "完成" : null;
        if (_done) _doneTimer.Start();
        Relayout();
    }

    protected override bool HasIcon => _loading || _done;

    protected override void PaintIcon(Graphics g, Rectangle r, Color ink)
    {
        if (_done) ToneIcons.Check(g, Rectangle.Inflate(r, -1, -1), ink);
        else if (_reduced) ToneIcons.Hourglass(g, r, ink);
        else ToneIcons.Spinner(g, Rectangle.Inflate(r, -1, -1), ink, Color.FromArgb(70, ink), _angle);
    }

    /// <summary>圖示位置出現或消失時寬度改變：自動大小的按鈕要重新排版。</summary>
    private void Relayout()
    {
        if (IsDisposed) return;
        if (AutoSize) Parent?.PerformLayout(this, nameof(Bounds));
        Invalidate();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _spin.Dispose();
            _doneTimer.Dispose();
        }
        base.Dispose(disposing);
    }
}
