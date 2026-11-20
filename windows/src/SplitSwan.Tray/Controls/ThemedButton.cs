using System.ComponentModel;
using System.Drawing;

namespace SplitSwan.Tray.Controls;

/// <summary>
/// 主要／次要按鈕（視覺稿 .btn／.btn.pri）：圓角、hover／pressed／disabled、鍵盤焦點框。
/// 繼承 Button，保留鍵盤操作（空白鍵、Enter、AcceptButton／CancelButton）與無障礙角色。
/// 文字用控制項自己的 Font（不在 OnPaint 建字型），尺寸以 DeviceDpi 縮放。
/// </summary>
internal class ThemedButton : Button, IThemed
{
    private bool _hover;
    private bool _pressed;
    private bool _primary;

    public ThemedButton(string text, bool primary = false)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        Text = text;
        AccessibleName = text;
        _primary = primary;
        AutoSize = true;
        Font = Theme.Ui(9f);
        Margin = new Padding(4, 0, 0, 0);
        UseVisualStyleBackColor = false;
        BackColor = Color.Transparent;
    }

    /// <summary>主要按鈕（強調色底）。</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Primary
    {
        get => _primary;
        set { _primary = value; Invalidate(); }
    }

    /// <summary>右側畫向下箭頭（按下會開子選單）。</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool DropDownArrow { get; set; }

    protected override void OnTextChanged(EventArgs e)
    {
        base.OnTextChanged(e);
        AccessibleName = Text;
    }

    public void ApplyTheme() => Invalidate();

    private int Px(int logical) => LogicalToDeviceUnits(logical);

    /// <summary>文字左側要不要留圖示位置（16×16，與文字相隔 6）；衍生類別在 <see cref="PaintIcon"/> 畫圖示。</summary>
    protected virtual bool HasIcon => false;

    /// <summary>畫文字左側的圖示（r 是 16×16 的圖示位置，ink 是目前的文字色）。</summary>
    protected virtual void PaintIcon(Graphics g, Rectangle r, Color ink) { }

    private int IconWidth => HasIcon ? Px(16) + Px(6) : 0;

    public override Size GetPreferredSize(Size proposedSize)
    {
        var text = Theme.Measure(Text, Font);
        var arrow = DropDownArrow ? Px(14) : 0;
        return new Size(text.Width + Px(28) + arrow + IconWidth, Math.Max(Px(30), text.Height + Px(12)));
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = _pressed = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _pressed = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _pressed = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { _hover = _pressed = false; Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var parentBg = Theme.OpaqueBack(this);
        g.Clear(parentBg);

        var dark = Theme.Palette.IsDark;
        Color fill, border, ink;
        if (_primary)
        {
            fill = Theme.Accent;
            border = Theme.Accent;
            ink = Theme.AccentInk;
        }
        else
        {
            fill = Theme.Raised;
            border = Theme.Line;
            ink = Theme.Ink;
        }
        // hover／pressed：深色時往白疊、淺色時往黑疊
        var shade = dark ? Color.White : Color.Black;
        if (Enabled && _pressed) fill = Theme.Mix(shade, fill, _primary ? 0.22 : 0.10);
        else if (Enabled && _hover) fill = Theme.Mix(shade, fill, _primary ? 0.12 : 0.05);
        if (!Enabled)
        {
            // 視覺稿 disabled 是 opacity .55：與父層底色混合
            fill = Theme.Mix(fill, parentBg, 0.55);
            border = Theme.Mix(border, parentBg, 0.55);
            ink = Theme.Mix(ink, parentBg, 0.55);
        }

        var focusW = Px(2);
        var body = Rectangle.Inflate(ClientRectangle, -focusW, -focusW);
        var radius = Px(4);
        Theme.FillRound(g, body, radius, fill, border);
        if (Focused && ShowFocusCues) Theme.FocusRing(g, ClientRectangle, radius, focusW);

        var textRect = body;
        if (DropDownArrow)
        {
            var aw = Px(14);
            textRect.Width -= aw;
            var cx = body.Right - Px(12);
            var cy = body.Y + body.Height / 2;
            var s = Px(3);
            using var pen = new Pen(ink, Math.Max(1f, Px(1) * 1.4f));
            g.DrawLines(pen, [new Point(cx - s, cy - s / 2), new Point(cx, cy + s / 2), new Point(cx + s, cy - s / 2)]);
        }
        if (HasIcon)
        {
            // 圖示＋文字整組置中（文字太長時圖示貼左、文字以省略號結尾）
            var tw = Math.Min(Theme.Measure(Text, Font).Width, Math.Max(0, textRect.Width - IconWidth - Px(8)));
            var left = textRect.X + Math.Max(Px(4), (textRect.Width - IconWidth - tw) / 2);
            var icon = Px(16);
            PaintIcon(g, new Rectangle(left, textRect.Y + (textRect.Height - icon) / 2, icon, icon), ink);
            textRect = new Rectangle(left + IconWidth, textRect.Y, tw + Px(2), textRect.Height);
            TextRenderer.DrawText(g, Text, Font, textRect, ink, Theme.TextFlags | TextFormatFlags.VerticalCenter);
            return;
        }
        TextRenderer.DrawText(g, Text, Font, textRect, ink,
            Theme.TextFlags | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
}
