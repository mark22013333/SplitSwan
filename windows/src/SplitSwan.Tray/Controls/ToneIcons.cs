using System.Drawing;
using System.Drawing.Drawing2D;
using SplitSwan.Core;

namespace SplitSwan.Tray.Controls;

/// <summary>
/// 五種語意色調的圖示與載入用圖示（打勾、沙漏、轉圈），以 GDI+ 向量繪製：不依賴圖示字型，任何 DPI 都清楚。
/// 實心圖示的內部記號用 knock（圖示後面的底色）畫出，看起來像 SF Symbols 的鏤空。
/// </summary>
internal static class ToneIcons
{
    /// <summary>畫色調圖示，填滿 r（取正方形置中）。</summary>
    public static void Draw(Graphics g, RectangleF r, ToneGlyph glyph, Color color, Color knock)
    {
        var s = Math.Min(r.Width, r.Height);
        var box = new RectangleF(r.X + (r.Width - s) / 2f, r.Y + (r.Height - s) / 2f, s, s);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var stroke = Math.Max(1.2f, s * 0.11f);
        switch (glyph)
        {
            case ToneGlyph.CheckCircle:
                Fill(g, color, p => p.AddEllipse(box));
                Lines(g, knock, stroke, Pt(box, 0.28f, 0.52f), Pt(box, 0.44f, 0.67f), Pt(box, 0.72f, 0.36f));
                break;
            case ToneGlyph.Clock:
                Fill(g, color, p => p.AddEllipse(box));
                Lines(g, knock, stroke, Pt(box, 0.5f, 0.24f), Pt(box, 0.5f, 0.52f), Pt(box, 0.69f, 0.64f));
                break;
            case ToneGlyph.Triangle:
            {
                Fill(g, color, p =>
                {
                    p.AddPolygon([Pt(box, 0.5f, 0.06f), Pt(box, 0.97f, 0.9f), Pt(box, 0.03f, 0.9f)]);
                });
                using (var pen = new Pen(color, s * 0.08f) { LineJoin = LineJoin.Round })
                    g.DrawPolygon(pen, [Pt(box, 0.5f, 0.06f), Pt(box, 0.97f, 0.9f), Pt(box, 0.03f, 0.9f)]);
                Lines(g, knock, stroke, Pt(box, 0.5f, 0.36f), Pt(box, 0.5f, 0.6f));
                Dot(g, knock, Pt(box, 0.5f, 0.75f), stroke * 0.65f);
                break;
            }
            case ToneGlyph.Octagon:
            {
                var pts = Enumerable.Range(0, 8).Select(i =>
                {
                    var a = Math.PI / 8 + i * Math.PI / 4;
                    return new PointF(box.X + s / 2f + (float)Math.Cos(a) * s / 2f, box.Y + s / 2f + (float)Math.Sin(a) * s / 2f);
                }).ToArray();
                Fill(g, color, p => p.AddPolygon(pts));
                Lines(g, knock, stroke, Pt(box, 0.33f, 0.33f), Pt(box, 0.67f, 0.67f));
                Lines(g, knock, stroke, Pt(box, 0.67f, 0.33f), Pt(box, 0.33f, 0.67f));
                break;
            }
            default:
            {
                // 虛線圓：12 段
                var inset = stroke / 2f + s * 0.04f;
                var c = RectangleF.Inflate(box, -inset, -inset);
                using var pen = new Pen(color, stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round };
                for (int i = 0; i < 12; i++) g.DrawArc(pen, c, i * 30f, 15f);
                break;
            }
        }
    }

    /// <summary>粗體打勾（載入按鈕完成時）。</summary>
    public static void Check(Graphics g, RectangleF r, Color color)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var s = Math.Min(r.Width, r.Height);
        var box = new RectangleF(r.X + (r.Width - s) / 2f, r.Y + (r.Height - s) / 2f, s, s);
        Lines(g, color, Math.Max(1.5f, s * 0.15f), Pt(box, 0.16f, 0.52f), Pt(box, 0.4f, 0.76f), Pt(box, 0.86f, 0.26f));
    }

    /// <summary>靜態沙漏（減少動態效果時取代轉圈與不定長度進度條）。</summary>
    public static void Hourglass(Graphics g, RectangleF r, Color color)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var s = Math.Min(r.Width, r.Height);
        var box = new RectangleF(r.X + (r.Width - s) / 2f, r.Y + (r.Height - s) / 2f, s, s);
        var w = Math.Max(1.2f, s * 0.09f);
        Lines(g, color, w, Pt(box, 0.22f, 0.1f), Pt(box, 0.78f, 0.1f));
        Lines(g, color, w, Pt(box, 0.22f, 0.9f), Pt(box, 0.78f, 0.9f));
        Lines(g, color, w, Pt(box, 0.3f, 0.1f), Pt(box, 0.3f, 0.25f), Pt(box, 0.5f, 0.5f), Pt(box, 0.3f, 0.75f), Pt(box, 0.3f, 0.9f));
        Lines(g, color, w, Pt(box, 0.7f, 0.1f), Pt(box, 0.7f, 0.25f), Pt(box, 0.5f, 0.5f), Pt(box, 0.7f, 0.75f), Pt(box, 0.7f, 0.9f));
        Fill(g, color, p => p.AddPolygon([Pt(box, 0.36f, 0.82f), Pt(box, 0.64f, 0.82f), Pt(box, 0.5f, 0.66f)]));
    }

    /// <summary>轉圈：淡色整圈＋一段 90° 的實色弧，angle 為弧的起點（度）。</summary>
    public static void Spinner(Graphics g, RectangleF r, Color color, Color track, float angle)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var s = Math.Min(r.Width, r.Height);
        var w = Math.Max(1.5f, s * 0.14f);
        var c = new RectangleF(r.X + (r.Width - s) / 2f + w / 2f, r.Y + (r.Height - s) / 2f + w / 2f, s - w, s - w);
        using (var tp = new Pen(track, w)) g.DrawEllipse(tp, c);
        using var pen = new Pen(color, w) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        g.DrawArc(pen, c, angle, 90f);
    }

    private static PointF Pt(RectangleF box, float fx, float fy) => new(box.X + box.Width * fx, box.Y + box.Height * fy);

    private static void Fill(Graphics g, Color color, Action<GraphicsPath> build)
    {
        using var path = new GraphicsPath();
        build(path);
        using var b = new SolidBrush(color);
        g.FillPath(b, path);
    }

    private static void Lines(Graphics g, Color color, float width, params PointF[] pts)
    {
        using var pen = new Pen(color, width) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        g.DrawLines(pen, pts);
    }

    private static void Dot(Graphics g, Color color, PointF c, float radius)
    {
        using var b = new SolidBrush(color);
        g.FillEllipse(b, c.X - radius, c.Y - radius, radius * 2, radius * 2);
    }
}
