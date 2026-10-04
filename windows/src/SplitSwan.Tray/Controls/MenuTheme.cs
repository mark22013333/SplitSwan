using System.Drawing;
using System.Drawing.Drawing2D;
using SplitSwan.Core;

namespace SplitSwan.Tray.Controls;

/// <summary>托盤右鍵選單的配色（視覺稿 .menu：Surface 底、AccentSoft 反白、Line 分隔線）。</summary>
internal sealed class ThemedColorTable : ProfessionalColorTable
{
    public ThemedColorTable() => UseSystemColors = false;

    public override Color ToolStripDropDownBackground => Theme.Surface;
    public override Color ImageMarginGradientBegin => Theme.Surface;
    public override Color ImageMarginGradientMiddle => Theme.Surface;
    public override Color ImageMarginGradientEnd => Theme.Surface;
    public override Color MenuBorder => Theme.Line;
    public override Color MenuItemBorder => Theme.AccentSoft;
    public override Color MenuItemSelected => Theme.AccentSoft;
    public override Color MenuItemSelectedGradientBegin => Theme.AccentSoft;
    public override Color MenuItemSelectedGradientEnd => Theme.AccentSoft;
    public override Color MenuItemPressedGradientBegin => Theme.AccentSoft;
    public override Color MenuItemPressedGradientEnd => Theme.AccentSoft;
    public override Color SeparatorDark => Theme.Line;
    public override Color SeparatorLight => Theme.Line;
    public override Color CheckBackground => Theme.AccentSoft;
    public override Color CheckSelectedBackground => Theme.AccentSoft;
    public override Color CheckPressedBackground => Theme.AccentSoft;
}

/// <summary>
/// 套主題色的選單繪製：文字依啟用狀態用 Ink／Muted、勾選符號與子選單箭頭用 Ink，反白為圓角。
/// 深色模式時選單也是深色（配色來自 Theme）。
/// </summary>
internal sealed class ThemedMenuRenderer : ToolStripProfessionalRenderer
{
    public ThemedMenuRenderer() : base(new ThemedColorTable()) => RoundedEdges = false;

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = e.Item.Enabled ? Theme.Ink : Theme.Mix(Theme.Muted, Theme.Surface, 0.8);
        base.OnRenderItemText(e);
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        e.ArrowColor = e.Item?.Enabled == false ? Theme.Muted : Theme.Ink;
        base.OnRenderArrow(e);
    }

    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        // 勾選：淡強調底＋Ink 勾號（預設勾號圖是黑色，在深色底看不到）
        var g = e.Graphics;
        var r = e.ImageRectangle;
        if (r.Width <= 0) return;
        var px = PxOf(e.ToolStrip);
        Theme.FillRound(g, Rectangle.Inflate(r, px(1), px(1)), px(3), Theme.AccentSoft);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var pen = new Pen(Theme.Ink, Math.Max(1.5f, r.Width / 9f));
        g.DrawLines(pen,
        [
            new PointF(r.X + r.Width * 0.22f, r.Y + r.Height * 0.52f),
            new PointF(r.X + r.Width * 0.42f, r.Y + r.Height * 0.72f),
            new PointF(r.X + r.Width * 0.78f, r.Y + r.Height * 0.30f),
        ]);
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        var px = PxOf(e.ToolStrip);
        var r = new Rectangle(px(2), 0, e.Item.Width - px(4), e.Item.Height);
        Theme.FillRound(e.Graphics, r, px(4), Theme.AccentSoft);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        var y = e.Item.Height / 2;
        using var pen = new Pen(Theme.Line);
        var inset = PxOf(e.ToolStrip)(8);
        e.Graphics.DrawLine(pen, inset, y, e.Item.Width - inset, y);
    }

    /// <summary>邏輯像素（96 DPI）→ 選單目前 DPI 的像素。</summary>
    private static Func<int, int> PxOf(ToolStrip? strip) => v => strip?.LogicalToDeviceUnits(v) ?? v;
}

/// <summary>
/// 選單最上方的狀態列（視覺稿 .menu .head）：狀態點＋粗體狀態＋閘道，下一行灰色等寬的虛擬 IP／說明。
/// 不可選取（滑鼠與鍵盤都會略過）。
/// </summary>
internal sealed class MenuHeaderItem : ToolStripItem
{
    private string _title = "";
    private string _detail = "";
    private StatusTone _tone = StatusTone.Idle;

    public MenuHeaderItem()
    {
        AccessibleRole = AccessibleRole.StaticText;
        Font = Theme.Ui(9f, FontStyle.Bold);
    }

    public override bool CanSelect => false;

    public void Set(StatusTone tone, string title, string detail)
    {
        _tone = tone;
        _title = title;
        _detail = detail;
        AccessibleName = string.IsNullOrEmpty(detail) ? title : $"{title}，{detail}";
        Text = AccessibleName;
        Invalidate();
    }

    private int Dpi => Owner?.DeviceDpi ?? 96;
    /// <summary>直接繪製用的字型依選單目前的 DPI 縮放（Theme.AtDpi 依 DPI 快取）。</summary>
    private Font TitleFont => Theme.AtDpi(Theme.Ui(9f, FontStyle.Bold), Dpi);
    private Font DetailFont => Theme.AtDpi(Theme.Mono(8.25f), Dpi);

    private int Px(int v) => Owner?.LogicalToDeviceUnits(v) ?? v;

    public override Size GetPreferredSize(Size constrainingSize)
    {
        var t = Theme.Measure(_title, TitleFont);
        var d = string.IsNullOrEmpty(_detail) ? Size.Empty : Theme.Measure(_detail, DetailFont);
        var w = Math.Max(t.Width + Px(26), d.Width) + Px(20);
        return new Size(Math.Min(w, Px(420)), t.Height + (d.Height > 0 ? d.Height + Px(2) : 0) + Px(16));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var pad = Px(10);
        var t = Theme.Measure(_title, TitleFont);
        var y = Px(8);
        var titleRect = new Rectangle(pad, y, Width - pad * 2 - Px(16), t.Height);
        TextRenderer.DrawText(g, _title, TitleFont, titleRect, Theme.Ink, Theme.TextFlags);
        // 狀態點在右側（同視覺稿 .head .line）
        var d = Px(8);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var b = new SolidBrush(Theme.Tone(_tone)))
            g.FillEllipse(b, Width - pad - d, y + (t.Height - d) / 2f, d, d);
        if (!string.IsNullOrEmpty(_detail))
        {
            var dr = new Rectangle(pad, y + t.Height + Px(2), Width - pad * 2, Theme.Measure(_detail, DetailFont).Height);
            TextRenderer.DrawText(g, _detail, DetailFont, dr, Theme.Muted, Theme.TextFlags);
        }
    }
}
