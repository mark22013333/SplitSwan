using System.ComponentModel;
using System.Drawing;
using SplitSwan.Core;

namespace SplitSwan.Tray.Controls;

/// <summary>文字標籤的顏色角色。</summary>
internal enum TextRole { Ink, Muted, Bad, Warn, Ok, Accent, HeroInk, HeroMuted }

/// <summary>依角色上色的標籤（透明底、沿用父層底色）。</summary>
internal sealed class ThemedLabel : Label, IThemed
{
    private TextRole _role;

    public ThemedLabel(string text = "", TextRole role = TextRole.Ink, Font? font = null)
    {
        Text = text;
        _role = role;
        AutoSize = true;
        BackColor = Color.Transparent;
        UseMnemonic = false;
        Font = font ?? Theme.Ui(9f);
        ApplyTheme();
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public TextRole Role
    {
        get => _role;
        set { _role = value; ApplyTheme(); }
    }

    public void ApplyTheme() => ForeColor = _role switch
    {
        TextRole.Muted => Theme.Muted,
        TextRole.Bad => Theme.Tone(StatusTone.Bad),
        TextRole.Warn => Theme.Tone(StatusTone.Warn),
        TextRole.Ok => Theme.Tone(StatusTone.Ok),
        TextRole.Accent => Theme.Accent,
        TextRole.HeroInk => Theme.C(Theme.Palette.HeroInk),
        TextRole.HeroMuted => Theme.C(Theme.Palette.HeroMuted),
        _ => Theme.Ink,
    };
}

/// <summary>
/// 套用主題的視窗基底：底色、字型、DWM 深色標題列、主題變更時整棵樹重新上色。
/// 以 96 DPI 為設計基準（AutoScaleMode.Dpi），衍生類別在建構子結尾呼叫 <see cref="FinishLayout"/>。
/// </summary>
internal class ThemedForm : Form
{
    public ThemedForm()
    {
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = Theme.Ui(9f);
        BackColor = Theme.Bg;
        ForeColor = Theme.Ink;
        AppIcon.Apply(this);
        Theme.Changed += OnThemeChanged;
    }

    /// <summary>建構子結尾呼叫：恢復版面（觸發 DPI 縮放）並套用一次主題。</summary>
    protected void FinishLayout()
    {
        Theme.Apply(this);
        ResumeLayout(false);
        PerformLayout();
    }

    protected int Px(int logical) => LogicalToDeviceUnits(logical);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyTitleBar(this);
    }

    private void OnThemeChanged()
    {
        if (IsDisposed) return;
        BackColor = Theme.Bg;
        ForeColor = Theme.Ink;
        Theme.ApplyTitleBar(this);
        Theme.Apply(this);
        OnThemeApplied();
        Invalidate(true);
    }

    /// <summary>主題變更後衍生類別要額外處理的部分（例如非控制項的顏色）。</summary>
    protected virtual void OnThemeApplied() { }

    protected override void Dispose(bool disposing)
    {
        if (disposing) Theme.Changed -= OnThemeChanged;
        base.Dispose(disposing);
    }
}

/// <summary>版面小工具：建立透明、不自動補邊距的容器。</summary>
internal static class UiLayout
{
    public static TableLayoutPanel Table(int columns, int rows = 0)
    {
        var t = new TableLayoutPanel
        {
            ColumnCount = columns,
            RowCount = rows,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Margin = Padding.Empty,
            Padding = Padding.Empty,
            BackColor = Color.Transparent,
        };
        return t;
    }

    public static FlowLayoutPanel Flow(FlowDirection dir = FlowDirection.LeftToRight, bool wrap = false) => new()
    {
        FlowDirection = dir,
        WrapContents = wrap,
        AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink,
        Margin = Padding.Empty,
        Padding = Padding.Empty,
        BackColor = Color.Transparent,
    };
}
