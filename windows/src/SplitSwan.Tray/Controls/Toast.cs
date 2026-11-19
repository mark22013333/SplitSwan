using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using SplitSwan.Core;

namespace SplitSwan.Tray.Controls;

/// <summary>
/// 吐司（Mac 的 ToastCenter／toastHost）：「已儲存」「已拷貝」等短暫確認，浮在視窗底部往上 64px（不蓋住設定頁底部的儲存列），
/// 膠囊、半透明底＋陰影，約 2.5 秒後淡出，點一下就關。同一則訊息再出現一次也會重新顯示。
/// 以分層視窗（WS_EX_LAYERED＋UpdateLayeredWindow，逐像素透明）實作，屬於擁有者視窗、不搶焦點；擁有者移動時跟著移動。
/// 每個視窗同時只有一則，新的取代舊的。只在 UI 執行緒使用。
/// </summary>
internal sealed class Toast : Form
{
    private static readonly Dictionary<Form, Toast> ByOwner = new();

    private readonly Form _owner;
    private readonly System.Windows.Forms.Timer _hideTimer = new() { Interval = (int)(Motion.ToastSeconds * 1000) };
    private Bitmap? _bitmap;
    private string _text = "";
    private bool _isError;
    private double _alpha;
    private int _slide;
    private Animation? _anim;

    /// <summary>在 owner 底部顯示一則吐司（已有的話取代並重新計時）。</summary>
    public static void ShowFor(Form owner, string text, bool isError = false)
    {
        if (owner.IsDisposed || !owner.Visible) return;
        if (!ByOwner.TryGetValue(owner, out var t) || t.IsDisposed)
        {
            t = new Toast(owner);
            ByOwner[owner] = t;
        }
        t.Present(text, isError);
    }

    /// <summary>目前顯示中的吐司文字（截圖與測試用）；沒有為 null。</summary>
    public static string? Current(Form owner) =>
        ByOwner.TryGetValue(owner, out var t) && !t.IsDisposed && t.Visible ? t._text : null;

    private Toast(Form owner)
    {
        _owner = owner;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AccessibleRole = AccessibleRole.Alert;
        _hideTimer.Tick += (_, _) => Dismiss();
        owner.LocationChanged += OnOwnerMoved;
        owner.SizeChanged += OnOwnerMoved;
        owner.VisibleChanged += OnOwnerVisibleChanged;
        owner.FormClosed += OnOwnerClosed;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            const int WS_EX_LAYERED = 0x80000;
            const int WS_EX_TOOLWINDOW = 0x80;
            const int WS_EX_NOACTIVATE = 0x08000000;
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => true;

    private int Px(int logical) => (int)Math.Round(logical * _owner.DeviceDpi / 96.0);

    private void Present(string text, bool isError)
    {
        _text = text;
        _isError = isError;
        Text = text;
        AccessibleName = text;
        Render();
        _hideTimer.Stop();
        _anim?.Stop();
        var reduced = MotionPrefs.Reduced;
        var travel = reduced ? 0 : Px(10);
        if (!Visible)
        {
            _alpha = 0;
            _slide = travel;
            Push();
            base.Show(_owner);
            Push();   // Show 會以 Form 自己的大小呼叫 SetWindowPos，再送一次正確的大小與位置
        }
        else
        {
            // 同一則再出現：從淡一點開始重新浮上來，看得出是新的回饋
            _alpha = Math.Min(_alpha, 0.35);
            _slide = travel;
            Push();
        }
        var startAlpha = _alpha;
        _anim = Animator.Start(this, Motion.TransitionSeconds(reduced), p =>
        {
            var e = Motion.EaseInOut(p);
            _alpha = startAlpha + (1 - startAlpha) * e;
            _slide = (int)Math.Round(travel * (1 - e));
            Push();
        });
        _hideTimer.Start();
        AccessibilityNotifyClients(AccessibleEvents.SystemAlert, -1);
    }

    /// <summary>淡出後隱藏（點一下或時間到）。</summary>
    private void Dismiss()
    {
        _hideTimer.Stop();
        if (IsDisposed || !Visible) return;
        _anim?.Stop();
        var startAlpha = _alpha;
        _anim = Animator.Start(this, Motion.TransitionSeconds(MotionPrefs.Reduced), p =>
        {
            _alpha = startAlpha * (1 - Motion.EaseInOut(p));
            Push();
        }, () => { if (!IsDisposed) Hide(); });
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        Dismiss();
    }

    private void OnOwnerMoved(object? sender, EventArgs e) { if (Visible) Push(); }

    private void OnOwnerVisibleChanged(object? sender, EventArgs e)
    {
        if (!_owner.Visible && Visible) { _hideTimer.Stop(); _anim?.Stop(); Hide(); }
    }

    private void OnOwnerClosed(object? sender, FormClosedEventArgs e) => Dispose();

    // MARK: 繪製

    /// <summary>畫出膠囊（含陰影）到逐像素透明的點陣圖。</summary>
    private void Render()
    {
        var font = Theme.AtDpi(Theme.Ui(9f, FontStyle.Bold), _owner.DeviceDpi);
        var shadow = Px(12);
        var icon = Px(16);
        var maxText = Math.Max(Px(120), _owner.ClientSize.Width - Px(48) - Px(28) - icon - Px(8));
        SizeF textSize;
        using (var probe = new Bitmap(1, 1))
        using (var pg = Graphics.FromImage(probe))
        {
            pg.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            textSize = pg.MeasureString(_text, font, maxText, StringFormat.GenericTypographic);
        }
        var capW = Px(14) + icon + Px(8) + (int)Math.Ceiling(textSize.Width) + Px(16);
        var capH = Math.Max(icon, (int)Math.Ceiling(textSize.Height)) + Px(18);
        var w = capW + shadow * 2;
        var h = capH + shadow * 2;
        _bitmap?.Dispose();
        _bitmap = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(_bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.Clear(Color.Transparent);
        var cap = new RectangleF(shadow, shadow - Px(2), capW, capH);
        // 陰影：往外逐層變淡（約 radius 8、y 2）
        for (int i = shadow; i >= 1; i--)
        {
            var a = (int)(38.0 * Math.Pow(1 - i / (double)(shadow + 1), 2));
            using var sp = Theme.Round(RectangleF.Inflate(new RectangleF(cap.X, cap.Y + Px(2), cap.Width, cap.Height), i, i), capH / 2f + i);
            using var sb = new SolidBrush(Color.FromArgb(a / 3, 0, 0, 0));
            g.FillPath(sb, sp);
        }
        var fill = Theme.Raised;
        using (var path = Theme.Round(cap, capH / 2f))
        {
            using (var b = new SolidBrush(Color.FromArgb(242, fill))) g.FillPath(b, path);
            using var pen = new Pen(Color.FromArgb(64, Theme.Muted), Math.Max(1f, Px(1)));
            g.DrawPath(pen, path);
        }
        var tone = _isError ? StatusTone.Bad : StatusTone.Ok;
        var iconRect = new RectangleF(cap.X + Px(14), cap.Y + (capH - icon) / 2f, icon, icon);
        ToneIcons.Draw(g, iconRect, ToneStyle.Glyph(tone), Theme.Tone(tone), fill);
        using var tb = new SolidBrush(_isError ? Theme.Tone(StatusTone.Bad) : Theme.Ink);
        var textRect = new RectangleF(iconRect.Right + Px(8), cap.Y + (capH - textSize.Height) / 2f, textSize.Width + 2, textSize.Height + 2);
        g.DrawString(_text, font, tb, textRect, StringFormat.GenericTypographic);
    }

    /// <summary>把點陣圖以目前的透明度與位置送到分層視窗。</summary>
    private void Push()
    {
        if (_bitmap is null || IsDisposed || _owner.IsDisposed) return;
        var client = _owner.RectangleToScreen(_owner.ClientRectangle);
        var shadow = Px(12);
        var x = client.Left + (client.Width - _bitmap.Width) / 2;
        var y = client.Bottom - Px(Motion.ToastBottomInset) - (_bitmap.Height - shadow) + _slide;
        var screenDc = GetDC(IntPtr.Zero);
        var memDc = CreateCompatibleDC(screenDc);
        var hBitmap = _bitmap.GetHbitmap(Color.FromArgb(0));
        var old = SelectObject(memDc, hBitmap);
        try
        {
            var size = new NativeSize { Cx = _bitmap.Width, Cy = _bitmap.Height };
            var src = new NativePoint();
            var dst = new NativePoint { X = x, Y = y };
            var blend = new BlendFunction
            {
                BlendOp = 0, BlendFlags = 0, AlphaFormat = 1,   // AC_SRC_OVER、AC_SRC_ALPHA
                SourceConstantAlpha = (byte)Math.Clamp((int)Math.Round(_alpha * 255), 0, 255),
            };
            _ = UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, 2);   // ULW_ALPHA
        }
        finally
        {
            SelectObject(memDc, old);
            DeleteObject(hBitmap);
            DeleteDC(memDc);
            _ = ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _hideTimer.Dispose();
            _bitmap?.Dispose();
            _owner.LocationChanged -= OnOwnerMoved;
            _owner.SizeChanged -= OnOwnerMoved;
            _owner.VisibleChanged -= OnOwnerVisibleChanged;
            _owner.FormClosed -= OnOwnerClosed;
            if (ByOwner.TryGetValue(_owner, out var t) && t == this) ByOwner.Remove(_owner);
        }
        base.Dispose(disposing);
    }

    // MARK: Win32（learn.microsoft.com/windows/win32/api/winuser/nf-winuser-updatelayeredwindow）

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSize { public int Cx, Cy; }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct BlendFunction
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref NativePoint pptDst, ref NativeSize psize,
        IntPtr hdcSrc, ref NativePoint pptSrc, int crKey, ref BlendFunction pblend, int dwFlags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr obj);
}
