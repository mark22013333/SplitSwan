using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using SplitSwan.Core;

namespace SplitSwan.Tray.Controls;

/// <summary>自繪小元件的共用基底：雙緩衝、透明底（沿用父層）、主題變更時重畫。</summary>
internal abstract class PaintedControl : Control, IThemed
{
    protected PaintedControl()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        TabStop = false;
        BackColor = Color.Transparent;
    }

    public virtual void ApplyTheme() => Invalidate();

    protected int Px(int logical) => LogicalToDeviceUnits(logical);

    protected override void OnPaintBackground(PaintEventArgs e) => e.Graphics.Clear(Theme.OpaqueBack(this));
}

/// <summary>進度條（視覺稿 .bar：6px、圓角）。Indeterminate 時一段色塊來回移動（只在可見時跑計時器）。</summary>
internal sealed class ProgressStrip : PaintedControl
{
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 30 };
    private double _value;
    private bool _indeterminate;
    private float _phase;

    public ProgressStrip()
    {
        AccessibleRole = AccessibleRole.ProgressBar;
        AccessibleName = "進度";
        _timer.Tick += (_, _) => { _phase = (_phase + 0.02f) % 1.4f; Invalidate(); };
    }

    /// <summary>0～1。</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public double Value
    {
        get => _value;
        set
        {
            var v = Math.Clamp(double.IsNaN(value) ? 0 : value, 0, 1);
            if (Math.Abs(v - _value) < 0.0005 && !_indeterminate) return;
            _value = v;
            AccessibleDescription = $"{Math.Round(v * 100)}%";
            Invalidate();
        }
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Indeterminate
    {
        get => _indeterminate;
        set
        {
            if (_indeterminate == value) return;
            _indeterminate = value;
            AccessibleDescription = value ? "進行中" : $"{Math.Round(_value * 100)}%";
            UpdateTimer();
            Invalidate();
        }
    }

    protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); UpdateTimer(); }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); UpdateTimer(); }

    private void UpdateTimer() => _timer.Enabled = _indeterminate && Visible && IsHandleCreated;

    protected override Size DefaultSize => new(200, 6);

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var h = Math.Min(Height, Px(6));
        var track = new Rectangle(0, (Height - h) / 2, Width, h);
        var r = h / 2f;
        Theme.FillRound(g, track, r, Theme.Line, null, 0);
        if (_indeterminate)
        {
            var segW = Width * 0.3f;
            var x = (_phase - 0.3f) * Width;
            var state = g.Save();
            using var clip = Theme.Round(track, r);
            g.SetClip(clip);
            Theme.FillRound(g, Rectangle.Round(new RectangleF(x, track.Y, segW, h)), r, Theme.Accent, null, 0);
            g.Restore(state);
        }
        else if (_value > 0)
        {
            var w = Math.Max(h, (int)Math.Round(Width * _value));
            Theme.FillRound(g, new Rectangle(0, track.Y, w, h), r, Theme.Accent, null, 0);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _timer.Dispose();
        base.Dispose(disposing);
    }
}

/// <summary>成功率條（視覺稿 .meter：6px、圓角 3，綠／橘）。</summary>
internal sealed class MeterBar : PaintedControl
{
    private double _fraction;
    private StatusTone _tone = StatusTone.Idle;

    public MeterBar() => AccessibleRole = AccessibleRole.ProgressBar;

    public void Set(double fraction, StatusTone tone, string accessibleText)
    {
        _fraction = Math.Clamp(fraction, 0, 1);
        _tone = tone;
        AccessibleName = accessibleText;
        Invalidate();
    }

    protected override Size DefaultSize => new(70, 6);

    protected override void OnPaint(PaintEventArgs e)
    {
        var h = Math.Min(Height, Px(6));
        var track = new Rectangle(0, (Height - h) / 2, Width, h);
        Theme.FillRound(e.Graphics, track, Px(3), Theme.Line, null, 0);
        if (_fraction <= 0) return;
        var w = Math.Max(h, (int)Math.Round(Width * _fraction));
        Theme.FillRound(e.Graphics, new Rectangle(0, track.Y, w, h), Px(3), Theme.Tone(_tone), null, 0);
    }
}

/// <summary>狀態點（視覺稿 .dot；Halo＝狀態面板大字前的點，外圈 4px 淡色光暈）。</summary>
internal sealed class StatusDot : PaintedControl
{
    private StatusTone _tone = StatusTone.Idle;

    public StatusDot(int diameter = 8, bool halo = false)
    {
        Diameter = diameter;
        Halo = halo;
        AccessibleRole = AccessibleRole.Graphic;
        var s = diameter + (halo ? 8 : 0);
        Size = new Size(s, s);
        Margin = new Padding(0, 0, 6, 0);
    }

    public int Diameter { get; }
    public bool Halo { get; }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public StatusTone Tone
    {
        get => _tone;
        set { _tone = value; Invalidate(); }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var color = Theme.Tone(_tone);
        var d = Px(Diameter);
        var cx = Width / 2f;
        var cy = Height / 2f;
        if (Halo)
        {
            var hd = d + Px(8);
            using var hb = new SolidBrush(Color.FromArgb(77, color));   // 30%
            g.FillEllipse(hb, cx - hd / 2f, cy - hd / 2f, hd, hd);
        }
        using var b = new SolidBrush(color);
        g.FillEllipse(b, cx - d / 2f, cy - d / 2f, d, d);
    }
}

/// <summary>chip 的樣式。</summary>
internal enum ChipKind
{
    /// <summary>淡強調底（視覺稿 .pipe i：走 VPN 的網段、已完成步驟）。</summary>
    Soft,
    /// <summary>灰底（.pipe i.loc：走本機網路、接下來的步驟）。</summary>
    Local,
    /// <summary>外框膠囊（.chip）；顏色依 Tone。</summary>
    Outline,
}

/// <summary>chip（網段、步驟名稱、狀態標籤）。大小依文字自動計算。</summary>
internal sealed class Chip : PaintedControl
{
    private readonly ChipKind _kind;
    private readonly bool _mono;
    private StatusTone _tone;

    public Chip(string text, ChipKind kind, bool mono = false, StatusTone tone = StatusTone.Idle)
    {
        _kind = kind;
        _mono = mono;
        _tone = tone;
        Font = mono ? Theme.Mono(8.25f) : Theme.Ui(8.25f);
        Text = text;
        AccessibleName = text;
        AccessibleRole = AccessibleRole.StaticText;
        Margin = new Padding(0, 0, 4, 4);
        AutoSize = true;
    }

    public bool IsMono => _mono;

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public StatusTone Tone
    {
        get => _tone;
        set { _tone = value; Invalidate(); }
    }

    protected override void OnTextChanged(EventArgs e)
    {
        base.OnTextChanged(e);
        AccessibleName = Text;
        Size = GetPreferredSize(Size.Empty);
        Invalidate();
    }

    public override Size GetPreferredSize(Size proposedSize)
    {
        var t = Theme.Measure(Text, Font);
        return new Size(t.Width + Px(_kind == ChipKind.Outline ? 16 : 14), t.Height + Px(4));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var r = new Rectangle(0, 0, Width, Height);
        Color ink;
        switch (_kind)
        {
            case ChipKind.Soft:
                Theme.FillRound(e.Graphics, r, Px(3), Theme.AccentSoft, null, 0);
                ink = Theme.Ink;
                break;
            case ChipKind.Local:
                Theme.FillRound(e.Graphics, r, Px(3), Theme.Line, null, 0);
                ink = Theme.Muted;
                break;
            default:
                var back = Theme.OpaqueBack(this);
                var tone = _tone == StatusTone.Idle ? Theme.Line : Theme.Mix(Theme.Tone(_tone), back, 0.45);
                Theme.FillRound(e.Graphics, r, Height / 2f, back, tone);
                ink = _tone == StatusTone.Idle ? Theme.Muted : Theme.Tone(_tone);
                break;
        }
        TextRenderer.DrawText(e.Graphics, Text, Font, r, ink,
            Theme.TextFlags | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
}

/// <summary>一列可換行的 chips（FlowLayoutPanel，透明底）。</summary>
internal sealed class ChipFlow : FlowLayoutPanel
{
    public ChipFlow()
    {
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        WrapContents = true;
        Margin = Padding.Empty;
        BackColor = Color.Transparent;
    }

    /// <summary>換成新的 chips（舊的 Dispose）；items 為空時顯示 emptyText（灰底）。</summary>
    public void SetChips(IEnumerable<string> items, ChipKind kind, bool mono, string? emptyText = null)
    {
        SuspendLayout();
        foreach (Control c in Controls.Cast<Control>().ToList()) c.Dispose();
        Controls.Clear();
        var list = items.ToList();
        if (list.Count == 0 && emptyText is not null) Controls.Add(new Chip(emptyText, ChipKind.Local));
        foreach (var t in list) Controls.Add(new Chip(t, kind, mono));
        ResumeLayout(true);
    }
}

/// <summary>圓角卡片（Surface 底＋框線）。Tone 不是 Idle 時改用該色的淡底與框線（錯誤、提醒）。</summary>
internal class CardPanel : Panel, IThemed
{
    private StatusTone _tone = StatusTone.Idle;

    public CardPanel()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw, true);
        Padding = new Padding(12, 8, 12, 8);
        ApplyTheme();
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public StatusTone Tone
    {
        get => _tone;
        set { _tone = value; ApplyTheme(); }
    }

    /// <summary>卡片內的底色（子控制項透明時沿用）。</summary>
    public Color Fill => _tone == StatusTone.Idle ? Theme.Surface : Theme.Mix(Theme.Tone(_tone), Theme.Surface, 0.10);

    public virtual void ApplyTheme()
    {
        BackColor = Fill;
        Invalidate(true);
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Theme.OpaqueBack(this));
        var border = _tone == StatusTone.Idle ? Theme.Line : Theme.Mix(Theme.Tone(_tone), Theme.Surface, 0.45);
        Theme.FillRound(g, ClientRectangle, LogicalToDeviceUnits(4), Fill, border);
    }

    protected override void OnPaint(PaintEventArgs e) { }
}

/// <summary>
/// 輸入框外框（視覺稿 .input）：TextBox 改無框，外框自己畫——底部線較深、取得焦點時框線變強調色。
/// 多行時高度由呼叫端指定。
/// </summary>
internal sealed class InputFrame : Panel, IThemed
{
    public InputFrame(TextBox box, bool mono = false)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw, true);
        Box = box;
        box.BorderStyle = BorderStyle.None;
        box.Font = mono ? Theme.Mono(9f) : Theme.Ui(9f);
        box.Dock = DockStyle.Fill;
        box.Margin = Padding.Empty;
        Padding = new Padding(8, 6, 8, 5);
        Margin = new Padding(0, 2, 0, 0);
        Controls.Add(box);
        box.GotFocus += (_, _) => Invalidate();
        box.LostFocus += (_, _) => Invalidate();
        // 多行框的捲軸是原生的，BackColor 管不到：建立 handle 時與主題切換時（ApplyTheme）換成深／淺色樣式
        box.HandleCreated += (_, _) => ApplyNativeScrollbars();
        ApplyTheme();
    }

    private void ApplyNativeScrollbars()
    {
        if (Box.Multiline) Theme.ApplyNativeScrollbars(Box);
    }

    public TextBox Box { get; }

    /// <summary>驗證錯誤時框線改紅色。</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Invalid
    {
        get => _invalid;
        set { _invalid = value; Invalidate(); }
    }
    private bool _invalid;

    public void ApplyTheme()
    {
        BackColor = Theme.Raised;
        Box.BackColor = Theme.Raised;
        Box.ForeColor = Theme.Ink;
        ApplyNativeScrollbars();
        Invalidate();
    }

    /// <summary>
    /// 單行時高度一律＝文字框的偏好高度＋內距（兩者都已是目前 DPI 的像素），
    /// 不在建構時寫死像素高度，避免視窗自動縮放時再乘一次 DPI 比例。
    /// </summary>
    protected override void SetBoundsCore(int x, int y, int width, int height, BoundsSpecified specified)
    {
        if (Box is { Multiline: false }) height = Box.PreferredHeight + Padding.Vertical;
        base.SetBoundsCore(x, y, width, height, specified);
    }

    protected override void OnPaddingChanged(EventArgs e)
    {
        base.OnPaddingChanged(e);
        if (Box is { Multiline: false }) Height = Box.PreferredHeight + Padding.Vertical;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Theme.OpaqueBack(this));
        var focused = Box.Focused;
        var border = _invalid ? Theme.Tone(StatusTone.Bad) : focused ? Theme.Accent : Theme.Line;
        var r = LogicalToDeviceUnits(4);
        Theme.FillRound(g, ClientRectangle, r, Theme.Raised, border, focused || _invalid ? LogicalToDeviceUnits(1) * 1.5f : 1f);
        if (!focused && !_invalid)
        {
            // 底線較深（color-mix(ink 35%, line)）
            using var pen = new Pen(Theme.Mix(Theme.Ink, Theme.Line, 0.35));
            g.DrawLine(pen, r, Height - 1, Width - r - 1, Height - 1);
        }
    }

    protected override void OnPaint(PaintEventArgs e) { }
}

/// <summary>開關（視覺稿 .sw）：繼承 CheckBox，保留空白鍵切換與無障礙的核取狀態。</summary>
internal sealed class ToggleSwitch : CheckBox, IThemed
{
    public ToggleSwitch(string text)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        Text = text;
        AccessibleName = text;
        AutoSize = true;
        Font = Theme.Ui(9f);
        BackColor = Color.Transparent;
        Margin = new Padding(0, 4, 0, 4);
    }

    public void ApplyTheme() => Invalidate();

    private int Px(int logical) => LogicalToDeviceUnits(logical);

    public override Size GetPreferredSize(Size proposedSize)
    {
        var t = Theme.Measure(Text, Font);
        return new Size(Px(34) + Px(10) + t.Width + Px(4), Math.Max(Px(22), t.Height + Px(4)));
    }

    protected override void OnCheckedChanged(EventArgs e) { base.OnCheckedChanged(e); Invalidate(); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var back = Theme.OpaqueBack(this);
        g.Clear(back);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var w = Px(34);
        var h = Px(18);
        var track = new Rectangle(Px(2), (Height - h) / 2, w, h);
        var on = Checked;
        var accent = Enabled ? Theme.Accent : Theme.Mix(Theme.Accent, back, 0.55);
        var muted = Enabled ? Theme.Muted : Theme.Mix(Theme.Muted, back, 0.55);
        if (on) Theme.FillRound(g, track, h / 2f, accent, null, 0);
        else Theme.FillRound(g, track, h / 2f, back, muted);
        var k = Px(12);
        var kx = on ? track.Right - Px(3) - k : track.X + Px(3);
        using (var b = new SolidBrush(on ? Theme.AccentInk : muted))
            g.FillEllipse(b, kx, track.Y + (h - k) / 2f, k, k);
        if (Focused && ShowFocusCues) Theme.FocusRing(g, Rectangle.Inflate(track, Px(2), Px(2)), h / 2f, Px(2));
        var textRect = new Rectangle(track.Right + Px(10), 0, Width - track.Right - Px(10), Height);
        TextRenderer.DrawText(g, Text, Font, textRect, Enabled ? Theme.Ink : Theme.Muted,
            Theme.TextFlags | TextFormatFlags.VerticalCenter);
    }
}

/// <summary>下拉選單（DropDownList），項目用主題色自繪。</summary>
internal sealed class ThemedComboBox : ComboBox, IThemed
{
    public ThemedComboBox()
    {
        DropDownStyle = ComboBoxStyle.DropDownList;
        DrawMode = DrawMode.OwnerDrawFixed;
        // 不用 FlatStyle.Flat：WinForms 的 FlatComboAdapter 會用 SystemBrushes.Control 畫下拉按鈕、
        // SystemColors.Window 畫外框（dotnet/winforms release/10.0 ComboBox.FlatComboAdapter.cs:144、171），
        // 不看 BackColor，深色模式下就是一塊白。改用原生樣式，深色時由 DarkMode_CFD 畫（見 Theme.ApplyNativeCombo）。
        FlatStyle = FlatStyle.Standard;
        Font = Theme.Ui(9f);
        ApplyTheme();
    }

    public void ApplyTheme()
    {
        BackColor = Theme.Raised;
        ForeColor = Theme.Ink;
        Theme.ApplyNativeCombo(this);
        Invalidate();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyNativeCombo(this);
    }

    protected override void OnDrawItem(DrawItemEventArgs e)
    {
        if (e.Index < 0) return;
        var selected = (e.State & DrawItemState.Selected) != 0 && (e.State & DrawItemState.ComboBoxEdit) == 0;
        using (var b = new SolidBrush(selected ? Theme.AccentSoft : Theme.Raised)) e.Graphics.FillRectangle(b, e.Bounds);
        var r = Rectangle.Inflate(e.Bounds, -LogicalToDeviceUnits(4), 0);
        TextRenderer.DrawText(e.Graphics, GetItemText(Items[e.Index]), Font, r, Theme.Ink,
            Theme.TextFlags | TextFormatFlags.VerticalCenter);
        if ((e.State & DrawItemState.Focus) != 0 && (e.State & DrawItemState.NoFocusRect) == 0) e.DrawFocusRectangle();
    }
}

/// <summary>
/// 精靈的輸出區（視覺稿 .term：固定深色底、等寬字）。依行首上色：「══」「> 」為指令色、「✔」為完成色、「✖」為錯誤色。
/// 太長時從頭刪掉一半（保留顏色）。
/// </summary>
internal sealed class TerminalBox : RichTextBox, IThemed
{
    private readonly int _maxChars;

    public TerminalBox(int maxChars)
    {
        _maxChars = maxChars;
        ReadOnly = true;
        BorderStyle = BorderStyle.None;
        WordWrap = false;
        ScrollBars = RichTextBoxScrollBars.Both;
        DetectUrls = false;
        Font = Theme.Mono(9f);
        BackColor = Theme.C(Theme.Palette.TermBg);
        ForeColor = Theme.C(Theme.Palette.TermInk);
        AccessibleName = "執行輸出";
    }

    /// <summary>輸出區兩種主題都是深色底，不跟著換。</summary>
    public void ApplyTheme() { }

    /// <summary>底色固定深色，捲軸也一律用深色樣式。</summary>
    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyNativeScrollbars(this, alwaysDark: true);
    }

    public void AppendLine(string line)
    {
        if (TextLength > _maxChars)
        {
            ReadOnly = false;
            Select(0, TextLength - _maxChars / 2);
            SelectedText = "";
            ReadOnly = true;
        }
        var color = line.StartsWith('✔') ? Theme.C(ThemePalette.TermOk)
            : line.StartsWith('✖') ? Theme.C(ThemePalette.Dark.Bad)
            : line.StartsWith("══", StringComparison.Ordinal) || line.StartsWith("> ", StringComparison.Ordinal) ? Theme.C(ThemePalette.TermCommand)
            : ForeColor;
        Select(TextLength, 0);
        SelectionColor = color;
        AppendText(line + Environment.NewLine);   // AppendText 會自動捲到最後
        SelectionColor = ForeColor;
    }
}
