using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using SplitSwan.Core;

namespace SplitSwan.Tray.Controls;

// 各介面共用的卡片元件（同 Mac 版 DesignSystem.swift）：卡片、區塊標題、色調圖示、狀態徽章、狀態卡、錯誤說明、忙碌指示。
// 原則：每個介面頂端一張狀態卡，其餘內容依主題分卡片；狀態只用五種語意色調（StatusTone）。

/// <summary>
/// 區塊卡片（Mac 的 DSCard／DSSurface）：圓角 10、內距 14，底色為灰 8%、框線灰 22%，深淺色都看得出邊界；
/// Tone 不是 Idle 時改用該色調 10% 的底與 22% 的框線（狀態卡、錯誤說明）。色調改變時顏色以 0.25 秒漸變。
/// 透明度以「疊在父層底色上」換算成不透明色，子控制項沿用卡片底色時才一致。
/// </summary>
internal class SectionCard : CardPanel
{
    private Color? _fromFill;
    private Color? _fromBorder;
    private double _mix = 1;
    private Animation? _anim;

    public SectionCard()
    {
        Padding = new Padding(ToneStyle.CardPadding);
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Margin = Padding.Empty;
    }

    private Color Back => Theme.OpaqueBack(this);

    private Color TargetFill => ToneStyle.IsNeutral(Tone)
        ? Theme.Mix(Theme.Muted, Back, ToneStyle.CardFill)
        : Theme.Mix(Theme.Tone(Tone), Back, ToneStyle.TintFill);

    private Color TargetBorder => Theme.Mix(ToneStyle.IsNeutral(Tone) ? Theme.Muted : Theme.Tone(Tone), Back, ToneStyle.CardBorder);

    public override Color Fill => _fromFill is { } f && _mix < 1 ? Theme.Mix(TargetFill, f, _mix) : TargetFill;

    protected override Color Border => _fromBorder is { } b && _mix < 1 ? Theme.Mix(TargetBorder, b, _mix) : TargetBorder;

    protected override int Radius => ToneStyle.CardRadius;

    protected override void OnToneChanged(StatusTone old)
    {
        base.OnToneChanged(old);
        if (!IsHandleCreated || !Visible) return;
        _fromFill = Fill;
        _fromBorder = Border;
        _anim?.Stop();
        _anim = Animator.Start(this, Motion.TransitionSeconds(MotionPrefs.Reduced), p =>
        {
            _mix = Motion.EaseInOut(p);
            ApplyTheme();
        }, () => { _fromFill = _fromBorder = null; _mix = 1; });
        _mix = 0;
    }

    protected override void OnParentChanged(EventArgs e) { base.OnParentChanged(e); ApplyTheme(); }
    protected override void OnParentBackColorChanged(EventArgs e) { base.OnParentBackColorChanged(e); ApplyTheme(); }

    // Panel 的 Padding 只影響停駐的子控制項與自動大小的計算，不會移動一般子控制項：
    // 內容（通常是一個表格）一律放在內距的左上角，自動大小時右下再加上內距，四邊才一致
    protected override void OnControlAdded(ControlEventArgs e)
    {
        base.OnControlAdded(e);
        PlaceContent(e.Control!);
    }

    protected override void OnPaddingChanged(EventArgs e)
    {
        base.OnPaddingChanged(e);
        foreach (Control c in Controls) PlaceContent(c);
    }

    private void PlaceContent(Control c)
    {
        if (c.Dock == DockStyle.None) c.Location = new Point(Padding.Left + c.Margin.Left, Padding.Top + c.Margin.Top);
    }
}

/// <summary>卡片外的區塊標題（Mac 的 SectionHeader）：粗體標題、可選的圖示字（Segoe Fluent Icons）與一行灰色說明。</summary>
internal sealed class SectionHeader : TableLayoutPanel
{
    public SectionHeader(string title, string? caption = null, string? glyph = null, int width = 0)
    {
        ColumnCount = 1;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Margin = Padding.Empty;
        Padding = Padding.Empty;
        BackColor = Color.Transparent;
        var row = UiLayout.Flow();
        if (glyph is not null && Theme.Icons(9.75f) is { } iconFont)
            row.Controls.Add(new ThemedLabel(glyph, TextRole.Muted, iconFont) { Margin = new Padding(0, 2, 6, 0), AccessibleRole = AccessibleRole.Graphic });
        row.Controls.Add(new ThemedLabel(title, TextRole.Ink, Theme.Ui(9.75f, FontStyle.Bold)) { Margin = Padding.Empty, AccessibleRole = AccessibleRole.StaticText });
        Controls.Add(row, 0, 0);
        if (caption is not null)
            Controls.Add(new ThemedLabel(caption, TextRole.Muted, Theme.Ui(8.25f))
            {
                Margin = new Padding(0, 2, 0, 0),
                MaximumSize = width > 0 ? new Size(width, 0) : Size.Empty,
            }, 0, 1);
    }
}

/// <summary>色調圖示。Circle＝狀態卡左側的大圓（色調 14% 底，圖示在中間）。</summary>
internal sealed class ToneIcon : PaintedControl
{
    private readonly bool _circle;
    private StatusTone _tone;

    public ToneIcon(int size, bool circle = false, StatusTone tone = StatusTone.Idle)
    {
        _circle = circle;
        _tone = tone;
        Size = new Size(size, size);
        Margin = Padding.Empty;
        AccessibleRole = AccessibleRole.Graphic;
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public StatusTone Tone
    {
        get => _tone;
        set { if (_tone == value) return; _tone = value; Invalidate(); }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var back = Theme.OpaqueBack(this);
        var color = Theme.Tone(_tone);
        var r = new RectangleF(0, 0, Width, Height);
        var knock = back;
        if (_circle)
        {
            knock = Theme.Mix(color, back, ToneStyle.IconFill);
            using (var b = new SolidBrush(knock)) g.FillEllipse(b, 0.5f, 0.5f, Width - 1f, Height - 1f);
            var inner = Width * 0.46f;
            r = new RectangleF((Width - inner) / 2f, (Height - inner) / 2f, inner, inner);
        }
        ToneIcons.Draw(g, r, ToneStyle.Glyph(_tone), color, knock);
    }
}

/// <summary>
/// 狀態徽章（Mac 的 StatusBadge）：膠囊、粗體小字、左側色調圖示、色調文字、色調 15% 底、內距左右 8 上下 3。
/// 文字或色調改變時淡入並由 0.8 倍放大（0.25 秒）；減少動態效果時直接換。
/// </summary>
internal sealed class StatusBadge : PaintedControl
{
    private string _text = "";
    private StatusTone _tone = StatusTone.Idle;
    private double _p = 1;
    private Animation? _anim;

    public StatusBadge()
    {
        Font = Theme.Ui(8.25f, FontStyle.Bold);
        AccessibleRole = AccessibleRole.StaticText;
        Margin = Padding.Empty;
        Size = GetPreferredSize(Size.Empty);
    }

    public string BadgeText => _text;
    public StatusTone BadgeTone => _tone;

    public void Set(string text, StatusTone tone)
    {
        if (text == _text && tone == _tone) return;
        _text = text;
        _tone = tone;
        AccessibleName = text;
        Size = GetPreferredSize(Size.Empty);
        _anim?.Stop();
        if (IsHandleCreated && Visible && !MotionPrefs.Reduced)
            _anim = Animator.Start(this, Motion.Duration, p => { _p = Motion.EaseInOut(p); Invalidate(); });
        else
        {
            _p = 1;
            Invalidate();
        }
    }

    public override Size GetPreferredSize(Size proposedSize)
    {
        var t = Theme.Measure(_text.Length == 0 ? " " : _text, Font);
        var icon = t.Height - Px(2);
        return new Size(Px(8) + icon + Px(4) + t.Width + Px(8), t.Height + Px(6));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (_text.Length == 0) return;
        var g = e.Graphics;
        var back = Theme.OpaqueBack(this);
        var color = Theme.Tone(_tone);
        var fill = Theme.Mix(color, back, ToneStyle.BadgeFill * _p);
        var ink = Theme.Mix(ToneStyle.IsNeutral(_tone) ? Theme.Muted : color, back, _p);
        var state = g.Save();
        if (_p < 1)
        {
            var s = (float)(0.8 + 0.2 * _p);
            g.TranslateTransform(Width / 2f, Height / 2f);
            g.ScaleTransform(s, s);
            g.TranslateTransform(-Width / 2f, -Height / 2f);
        }
        Theme.FillRound(g, new Rectangle(0, 0, Width, Height), Height / 2f, fill, null, 0);
        var t = Theme.Measure(_text, Font);
        var iconSize = t.Height - Px(2);
        var iconRect = new RectangleF(Px(8), (Height - iconSize) / 2f, iconSize, iconSize);
        ToneIcons.Draw(g, iconRect, ToneStyle.Glyph(_tone), ink, fill);
        var textRect = new Rectangle((int)iconRect.Right + Px(4), 0, Width - (int)iconRect.Right - Px(4), Height);
        TextRenderer.DrawText(g, _text, Font, textRect, ink, Theme.TextFlags | TextFormatFlags.VerticalCenter);
        g.Restore(state);
    }
}

/// <summary>
/// 每個介面頂端的狀態卡（Mac 的 StatusCard）：左側 52×52 圓形色調圖示；右側大字狀態（右上角狀態徽章）、
/// 下方一句灰色的下一步說明；最下方放唯一的主要按鈕（AddAction）。內距 16；中性色調用一般卡片底。
/// 標題改變時淡入（0.25 秒；減少動態效果時 0.15 秒）。
/// </summary>
internal sealed class StatusCard : SectionCard
{
    private readonly int _textWidth;
    private readonly ToneIcon _icon = new(ToneStyle.StatusIconSize, circle: true);
    private readonly ThemedLabel _title;
    private readonly StatusBadge _badge = new();
    private readonly ThemedLabel _detail = new("", TextRole.Muted);
    private readonly FlowLayoutPanel _actions = UiLayout.Flow();
    private readonly HeadRow _head;
    private Animation? _titleAnim;

    /// <param name="width">卡片寬度（96 DPI 的邏輯像素）。</param>
    /// <param name="titleFont">大字的字型；預設 12pt 粗體。</param>
    public StatusCard(int width, Font? titleFont = null)
    {
        Padding = new Padding(ToneStyle.StatusPadding);
        MinimumSize = new Size(width, 0);
        MaximumSize = new Size(width, 0);
        ActionWidth = width - ToneStyle.StatusPadding * 2;
        _textWidth = ActionWidth - ToneStyle.StatusIconSize - 14;
        _title = new ThemedLabel("", TextRole.Ink, titleFont ?? Theme.Ui(12f, FontStyle.Bold)) { Margin = Padding.Empty };

        var grid = UiLayout.Table(2, 2);
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, ToneStyle.StatusIconSize + 14));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, _textWidth));
        _icon.Anchor = AnchorStyles.Top | AnchorStyles.Left;
        grid.Controls.Add(_icon, 0, 0);

        var text = UiLayout.Table(1);
        _head = new HeadRow(_textWidth, _title, _badge);
        text.Controls.Add(_head, 0, 0);
        _detail.MaximumSize = new Size(_textWidth, 0);
        _detail.Margin = new Padding(0, 4, 0, 0);
        text.Controls.Add(_detail, 0, 1);
        grid.Controls.Add(text, 1, 0);

        _actions.Margin = new Padding(0, 12, 0, 0);
        grid.Controls.Add(_actions, 0, 1);
        grid.SetColumnSpan(_actions, 2);
        Controls.Add(grid);
        AccessibleRole = AccessibleRole.Grouping;
    }

    /// <summary>主要按鈕可用的寬度（邏輯像素；按鈕要填滿整列時用）。</summary>
    public int ActionWidth { get; }

    /// <summary>放進最下方的按鈕列（左到右，間隔 8）。</summary>
    public void AddAction(Control c)
    {
        c.Margin = new Padding(_actions.Controls.Count == 0 ? 0 : 8, 0, 0, 0);
        _actions.Controls.Add(c);
    }

    /// <summary>目前的大字、徽章與說明（無障礙與測試用）。</summary>
    public string Title => _title.Text;
    public string Detail => _detail.Text;

    public void Set(StatusTone tone, string title, string badge, string? detail)
    {
        SuspendLayout();
        Tone = tone;
        _icon.Tone = tone;
        _badge.Set(badge, tone);
        if (_title.Text != title)
        {
            var animate = IsHandleCreated && Visible && _title.Text.Length > 0;
            _title.Text = title;
            _titleAnim?.Stop();
            if (animate)
                _titleAnim = Animator.Start(_title, Motion.TransitionSeconds(MotionPrefs.Reduced), p => _title.Reveal = Motion.EaseInOut(p));
            else _title.Reveal = 1;
        }
        _detail.Text = detail ?? "";
        _detail.Visible = !string.IsNullOrEmpty(detail);
        AccessibleName = title;
        AccessibleDescription = badge + (string.IsNullOrEmpty(detail) ? "" : "。" + detail);
        _head.PerformLayout();
        ResumeLayout(true);
    }

    /// <summary>大字＋右上角徽章：徽章靠右，大字的寬度扣掉徽章後換行，不會壓到徽章。</summary>
    private sealed class HeadRow : Panel
    {
        private readonly ThemedLabel _title;
        private readonly StatusBadge _badge;

        public HeadRow(int width, ThemedLabel title, StatusBadge badge)
        {
            _title = title;
            _badge = badge;
            BackColor = Color.Transparent;
            Margin = Padding.Empty;
            Width = width;
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Controls.Add(title);
            Controls.Add(badge);
        }

        private int Gap => LogicalToDeviceUnits(8);

        public override Size GetPreferredSize(Size proposedSize)
        {
            var tp = _title.GetPreferredSize(new Size(Math.Max(1, Width - _badge.Width - Gap), 0));
            return new Size(Width, Math.Max(tp.Height, _badge.Height + LogicalToDeviceUnits(4)));
        }

        protected override void OnLayout(LayoutEventArgs levent)
        {
            _title.MaximumSize = new Size(Math.Max(LogicalToDeviceUnits(60), Width - _badge.Width - Gap), 0);
            _title.Location = Point.Empty;
            // 徽章與大字第一行垂直置中
            var firstLine = TextRenderer.MeasureText("國", _title.Font, Size.Empty, Theme.MeasureFlags).Height;
            _badge.Location = new Point(Width - _badge.Width, Math.Max(0, (firstLine - _badge.Height) / 2));
            base.OnLayout(levent);
        }
    }
}

/// <summary>可選取、可複製的唯讀文字（無框 TextBox，底色沿用父層）；高度依內容與寬度自動換行計算。</summary>
internal sealed class SelectableText : TextBox, IThemed
{
    private TextRole _role;

    public SelectableText(TextRole role, Font font)
    {
        _role = role;
        ReadOnly = true;
        BorderStyle = BorderStyle.None;
        Multiline = true;
        WordWrap = true;
        ScrollBars = ScrollBars.None;
        TabStop = false;
        Font = font;
        Margin = Padding.Empty;
        ApplyTheme();
    }

    public void ApplyTheme()
    {
        BackColor = Theme.OpaqueBack(this);
        ForeColor = _role switch
        {
            TextRole.Bad => Theme.Tone(StatusTone.Bad),
            TextRole.Muted => Theme.Muted,
            _ => Theme.Ink,
        };
    }

    protected override void OnParentChanged(EventArgs e) { base.OnParentChanged(e); ApplyTheme(); }
    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Fit(); }

    private int _fittedWidth = -1;

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        if (Width != _fittedWidth) Fit();
    }

    /// <summary>高度＝以目前寬度換行後的文字高度。</summary>
    private void Fit()
    {
        if (Width <= 0) return;
        _fittedWidth = Width;
        var size = TextRenderer.MeasureText(Text.Length == 0 ? " " : Text, Font, new Size(Width - 4, int.MaxValue),
            TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl);
        Height = size.Height + 2;
    }
}

/// <summary>
/// 錯誤說明（Mac 的 ErrorBanner）：紅色八角圖示、紅色訊息（可選取複製）、下方灰色的下一步；紅色淡底卡片。
/// </summary>
internal sealed class ErrorBanner : SectionCard
{
    private readonly SelectableText _message;
    private readonly ThemedLabel _next = new("", TextRole.Muted);

    /// <param name="width">卡片寬度（96 DPI 的邏輯像素）。</param>
    public ErrorBanner(int width)
    {
        Tone = StatusTone.Bad;
        Padding = new Padding(12);
        MinimumSize = new Size(width, 0);
        MaximumSize = new Size(width, 0);
        var textWidth = width - 24 - 20 - 10;
        _message = new SelectableText(TextRole.Bad, Theme.Ui(9f, FontStyle.Bold)) { Width = textWidth, AccessibleName = "錯誤訊息" };
        var grid = UiLayout.Table(2, 1);
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 30));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, textWidth));
        grid.Controls.Add(new ToneIcon(20, tone: StatusTone.Bad) { Anchor = AnchorStyles.Top | AnchorStyles.Left }, 0, 0);
        var stack = UiLayout.Table(1);
        stack.Controls.Add(_message, 0, 0);
        _next.MaximumSize = new Size(textWidth, 0);
        _next.Margin = new Padding(0, 3, 0, 0);
        stack.Controls.Add(_next, 0, 1);
        grid.Controls.Add(stack, 1, 0);
        Controls.Add(grid);
        AccessibleRole = AccessibleRole.Alert;
        AccessibleName = "錯誤";
    }

    public string Message => _message.Text;

    public void Set(string message, string? nextStep)
    {
        SuspendLayout();
        _message.Text = message;
        _next.Text = nextStep ?? "";
        _next.Visible = !string.IsNullOrEmpty(nextStep);
        AccessibleDescription = message + (string.IsNullOrEmpty(nextStep) ? "" : "。" + nextStep);
        ResumeLayout(true);
    }
}

/// <summary>忙碌指示的樣式：Bar＝不定長度進度條（下方可附說明）；Spinner＝小轉圈＋說明。</summary>
internal enum BusyStyle { Bar, Spinner }

/// <summary>
/// 不定長度的進度（Mac 的 BusyIndicator）。減少動態效果時改成靜態沙漏＋說明（Bar 沒給說明時補「處理中…」），不轉也不跑。
/// 只在可見時跑計時器。Bar 樣式的寬度由呼叫端指定。
/// </summary>
internal sealed class BusyIndicator : PaintedControl
{
    private readonly BusyStyle _style;
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 30 };
    private float _phase;
    private bool _reduced;

    public BusyIndicator(BusyStyle style, string? text = null)
    {
        _style = style;
        Font = Theme.Ui(9f);
        Text = text ?? "";
        AccessibleRole = AccessibleRole.ProgressBar;
        Margin = Padding.Empty;
        _timer.Tick += (_, _) => { _phase = (_phase + 0.03f) % 1f; Invalidate(); };
        _reduced = MotionPrefs.Reduced;
        Size = GetPreferredSize(Size.Empty);
    }

    private string? Label => Text.Length > 0 ? Text : _reduced && _style == BusyStyle.Bar ? "處理中…" : null;

    protected override void OnTextChanged(EventArgs e)
    {
        base.OnTextChanged(e);
        AccessibleName = Label ?? "處理中";
        var w = Width;
        Size = GetPreferredSize(Size.Empty);
        if (_style == BusyStyle.Bar) Width = w;
        Invalidate();
    }

    protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); UpdateTimer(); }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); UpdateTimer(); }

    private void UpdateTimer()
    {
        _reduced = MotionPrefs.Reduced;
        _timer.Enabled = Visible && IsHandleCreated && !_reduced;
    }

    public override Size GetPreferredSize(Size proposedSize)
    {
        var t = Label is { } l ? Theme.Measure(l, Font) : Size.Empty;
        var icon = Px(16);
        if (_reduced || _style == BusyStyle.Spinner)
            return new Size(icon + (t.Width > 0 ? Px(6) + t.Width : 0) + Px(2), Math.Max(icon, t.Height) + Px(2));
        return new Size(Math.Max(Width, Px(120)), Px(6) + (t.Height > 0 ? Px(6) + t.Height : 0));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var font = Font;
        if (_reduced || _style == BusyStyle.Spinner)
        {
            var icon = Px(16);
            var r = new RectangleF(0, (Height - icon) / 2f, icon, icon);
            if (_reduced) ToneIcons.Hourglass(g, r, Theme.Muted);
            else ToneIcons.Spinner(g, r, Theme.Accent, Theme.Line, _phase * 360f);
            if (Label is { } l)
                TextRenderer.DrawText(g, l, font, new Rectangle(icon + Px(6), 0, Width - icon - Px(6), Height),
                    _style == BusyStyle.Bar ? Theme.Muted : Theme.Ink, Theme.TextFlags | TextFormatFlags.VerticalCenter);
            return;
        }
        var h = Px(6);
        var track = new Rectangle(0, 0, Width, h);
        Theme.FillRound(g, track, h / 2f, Theme.Line, null, 0);
        var state = g.Save();
        using (var clip = Theme.Round(track, h / 2f)) g.SetClip(clip);
        var segW = Width * 0.3f;
        var x = (_phase * 1.3f - 0.3f) * Width;
        Theme.FillRound(g, Rectangle.Round(new RectangleF(x, 0, segW, h)), h / 2f, Theme.Accent, null, 0);
        g.Restore(state);
        if (Label is { } text)
            TextRenderer.DrawText(g, text, font, new Rectangle(0, h + Px(6), Width, Height - h - Px(6)), Theme.Muted, Theme.TextFlags);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _timer.Dispose();
        base.Dispose(disposing);
    }
}
