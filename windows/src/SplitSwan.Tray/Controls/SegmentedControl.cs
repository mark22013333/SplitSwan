using System.ComponentModel;
using System.Drawing;

namespace SplitSwan.Tray.Controls;

/// <summary>
/// 分段選擇（視覺稿 .seg）：外框圓角、選中段為強調色。
/// 鍵盤：Tab 進入後用 ←／→／Home／End 切換；無障礙角色為分頁清單，每段是一個分頁（可由輔助工具選取）。
/// </summary>
internal sealed class SegmentedControl : Control, IThemed
{
    private string[] _items = [];
    private int _selected;
    private int _hover = -1;

    public SegmentedControl()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.SupportsTransparentBackColor, true);
        TabStop = true;
        AutoSize = true;
        Font = Theme.Ui(9f);
        AccessibleRole = AccessibleRole.PageTabList;
        BackColor = Color.Transparent;
    }

    public event EventHandler? SelectedIndexChanged;

    /// <summary>各段文字；改了會重新量大小（計數改變時呼叫）。</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public IReadOnlyList<string> Items
    {
        get => _items;
        set
        {
            _items = [.. value];
            if (_selected >= _items.Length) _selected = Math.Max(0, _items.Length - 1);
            if (AutoSize) Size = GetPreferredSize(Size.Empty);
            Invalidate();
            AccessibilityNotifyClients(AccessibleEvents.NameChange, -1);
        }
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int SelectedIndex
    {
        get => _selected;
        set
        {
            if (_items.Length == 0) return;
            var v = Math.Clamp(value, 0, _items.Length - 1);
            if (v == _selected) return;
            _selected = v;
            Invalidate();
            AccessibilityNotifyClients(AccessibleEvents.Selection, v);
            SelectedIndexChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void ApplyTheme() => Invalidate();

    private int Px(int logical) => LogicalToDeviceUnits(logical);

    private int[] SegmentWidths() =>
        [.. _items.Select(t => TextRenderer.MeasureText(t, Font, Size.Empty, Theme.TextFlags).Width + Px(20))];

    public override Size GetPreferredSize(Size proposedSize)
    {
        var h = TextRenderer.MeasureText("全", Font, Size.Empty, Theme.TextFlags).Height + Px(10);
        return new Size(SegmentWidths().Sum() + Px(4), Math.Max(Px(26), h) + Px(4));
    }

    /// <summary>每段的矩形（含焦點框保留的 2px 邊）。</summary>
    private Rectangle[] SegmentRects()
    {
        var widths = SegmentWidths();
        var m = Px(2);
        var x = m;
        var rects = new Rectangle[widths.Length];
        for (var i = 0; i < widths.Length; i++)
        {
            rects[i] = new Rectangle(x, m, widths[i], Height - m * 2);
            x += widths[i];
        }
        return rects;
    }

    private int HitTest(Point p)
    {
        var rects = SegmentRects();
        for (var i = 0; i < rects.Length; i++) if (rects[i].Contains(p)) return i;
        return -1;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var h = HitTest(e.Location);
        if (h != _hover) { _hover = h; Invalidate(); }
        base.OnMouseMove(e);
    }

    protected override void OnMouseLeave(EventArgs e) { _hover = -1; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        Focus();
        var h = HitTest(e.Location);
        if (h >= 0) SelectedIndex = h;
    }

    protected override bool IsInputKey(Keys keyData) =>
        (keyData & Keys.KeyCode) is Keys.Left or Keys.Right or Keys.Home or Keys.End || base.IsInputKey(keyData);

    protected override void OnKeyDown(KeyEventArgs e)
    {
        switch (e.KeyCode)
        {
            case Keys.Left: SelectedIndex = _selected - 1; e.Handled = true; break;
            case Keys.Right: SelectedIndex = _selected + 1; e.Handled = true; break;
            case Keys.Home: SelectedIndex = 0; e.Handled = true; break;
            case Keys.End: SelectedIndex = _items.Length - 1; e.Handled = true; break;
        }
        base.OnKeyDown(e);
    }

    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var back = Theme.OpaqueBack(this);
        g.Clear(back);
        if (_items.Length == 0) return;
        var rects = SegmentRects();
        var outer = Rectangle.FromLTRB(rects[0].Left, rects[0].Top, rects[^1].Right, rects[0].Bottom);
        var radius = Px(4);
        Theme.FillRound(g, outer, radius, Theme.Raised, Theme.Line);

        for (var i = 0; i < rects.Length; i++)
        {
            var r = rects[i];
            Color ink;
            if (i == _selected)
            {
                // 選中段：強調色（左右兩端跟外框一起圓角，中間段直角）
                using var clip = Theme.Round(new RectangleF(outer.X + 0.5f, outer.Y + 0.5f, outer.Width - 1, outer.Height - 1), radius);
                var state = g.Save();
                g.SetClip(clip);
                using (var b = new SolidBrush(Theme.Accent)) g.FillRectangle(b, r);
                g.Restore(state);
                ink = Theme.AccentInk;
            }
            else
            {
                if (i == _hover)
                {
                    using var b = new SolidBrush(Theme.Mix(Theme.Ink, Theme.Raised, 0.06));
                    g.FillRectangle(b, Rectangle.Inflate(r, -1, -1));
                }
                ink = Theme.Ink;
            }
            TextRenderer.DrawText(g, _items[i], Font, r, Enabled ? ink : Theme.Muted,
                Theme.TextFlags | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        if (Focused && ShowFocusCues) Theme.FocusRing(g, ClientRectangle, radius, Px(2));
    }

    protected override AccessibleObject CreateAccessibilityInstance() => new SegAccessible(this);

    private sealed class SegAccessible(SegmentedControl owner) : ControlAccessibleObject(owner)
    {
        public override AccessibleRole Role => AccessibleRole.PageTabList;
        public override int GetChildCount() => owner._items.Length;
        public override AccessibleObject? GetChild(int index) =>
            index >= 0 && index < owner._items.Length ? new SegItem(owner, index, this) : null;
        public override AccessibleObject? GetSelected() =>
            owner._items.Length > 0 ? new SegItem(owner, owner._selected, this) : null;
    }

    private sealed class SegItem(SegmentedControl owner, int index, AccessibleObject parent) : AccessibleObject
    {
        public override string? Name => index < owner._items.Length ? owner._items[index] : null;
        public override AccessibleRole Role => AccessibleRole.PageTab;
        public override AccessibleObject Parent => parent;
        public override AccessibleStates State =>
            AccessibleStates.Focusable | AccessibleStates.Selectable
            | (index == owner._selected ? AccessibleStates.Selected : AccessibleStates.None)
            | (owner.Focused && index == owner._selected ? AccessibleStates.Focused : AccessibleStates.None);
        public override string DefaultAction => "選取";
        public override void DoDefaultAction() => owner.SelectedIndex = index;
        public override void Select(AccessibleSelection flags)
        {
            if ((flags & (AccessibleSelection.TakeSelection | AccessibleSelection.AddSelection)) != 0) owner.SelectedIndex = index;
        }
        public override Rectangle Bounds
        {
            get
            {
                var rects = owner.SegmentRects();
                return index < rects.Length ? owner.RectangleToScreen(rects[index]) : Rectangle.Empty;
            }
        }
    }
}
