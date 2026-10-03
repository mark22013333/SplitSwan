using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 托盤圖示：程式繪製（GDI），不放二進位素材。四種狀態用不同顏色與記號區分，
/// 色盲使用者也能靠記號分辨：已連線＝實心圓＋勾、連線中＝圓環＋點、錯誤＝驚嘆號、未連線＝空心圓。
/// </summary>
internal sealed class TrayIcons : IDisposable
{
    private readonly Dictionary<TrayState, Icon> _icons = new();
    private readonly List<IntPtr> _handles = new();

    public TrayIcons()
    {
        var size = SystemInformation.SmallIconSize.Width;
        if (size < 16) size = 16;
        foreach (var state in Enum.GetValues<TrayState>())
            _icons[state] = Create(state, size);
    }

    public Icon this[TrayState state] => _icons[state];

    private Icon Create(TrayState state, int size)
    {
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            float s = size;
            var pad = s * 0.08f;
            var rect = new RectangleF(pad, pad, s - pad * 2, s - pad * 2);
            var stroke = Math.Max(1.5f, s / 10f);

            switch (state)
            {
                case TrayState.Connected:
                {
                    using var fill = new SolidBrush(Color.FromArgb(0x2E, 0x9E, 0x4F));
                    g.FillEllipse(fill, rect);
                    using var pen = new Pen(Color.White, stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round };
                    g.DrawLines(pen, new[]
                    {
                        new PointF(s * 0.30f, s * 0.52f),
                        new PointF(s * 0.45f, s * 0.67f),
                        new PointF(s * 0.72f, s * 0.36f),
                    });
                    break;
                }
                case TrayState.Busy:
                {
                    using var pen = new Pen(Color.FromArgb(0xE0, 0x9B, 0x16), stroke * 1.2f);
                    var inner = RectangleF.Inflate(rect, -stroke / 2, -stroke / 2);
                    g.DrawEllipse(pen, inner);
                    using var dot = new SolidBrush(Color.FromArgb(0xE0, 0x9B, 0x16));
                    var d = s * 0.28f;
                    g.FillEllipse(dot, (s - d) / 2, (s - d) / 2, d, d);
                    break;
                }
                case TrayState.Error:
                {
                    using var fill = new SolidBrush(Color.FromArgb(0xD1, 0x34, 0x38));
                    g.FillEllipse(fill, rect);
                    using var pen = new Pen(Color.White, stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round };
                    g.DrawLine(pen, s / 2, s * 0.26f, s / 2, s * 0.56f);
                    using var w = new SolidBrush(Color.White);
                    var d = stroke * 1.1f;
                    g.FillEllipse(w, s / 2 - d / 2, s * 0.70f - d / 2, d, d);
                    break;
                }
                default:
                {
                    using var pen = new Pen(Color.FromArgb(0x80, 0x80, 0x80), stroke);
                    var inner = RectangleF.Inflate(rect, -stroke / 2, -stroke / 2);
                    g.DrawEllipse(pen, inner);
                    break;
                }
            }
        }
        var h = bmp.GetHicon();
        _handles.Add(h);
        return Icon.FromHandle(h);
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    public void Dispose()
    {
        foreach (var i in _icons.Values) i.Dispose();
        foreach (var h in _handles) DestroyIcon(h);
        _icons.Clear();
        _handles.Clear();
    }
}
