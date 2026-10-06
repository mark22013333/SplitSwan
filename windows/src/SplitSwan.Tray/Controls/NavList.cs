using System.ComponentModel;
using System.Drawing;

namespace SplitSwan.Tray.Controls;

/// <summary>
/// 設定視窗左側的分類清單（類似 Windows 11 設定 App）：Surface 底、右側一條分隔線；
/// 選中項目用淡強調底（AccentSoft）＋左側 3px 強調色直條標示。
/// 鍵盤：Tab 進入後用 ↑／↓／Home／End 切換；無障礙角色為分頁清單，每項是一個分頁（可由輔助工具選取）。
/// </summary>
internal sealed class NavList : Control, IThemed
{
    private string[] _items = [];
    private int _selected;
    private int _hover = -1;

    /// <summary>每項的高度與上方留白（96 DPI 的邏輯像素）。</summary>
    private const int ItemHeight = 34;
    private const int TopGap = 12;
    private const int SideGap = 8;

    public NavList()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        TabStop = true;
        Font = Theme.Ui(9.75f);
        AccessibleRole = AccessibleRole.PageTabList;
        AccessibleName = "設定分類";
    }

    public event EventHandler? SelectedIndexChanged;

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public IReadOnlyList<string> Items
    {
        get => _items;
        set
        {
            _items = [.. value];
            if (_selected >= _items.Length) _selected = Math.Max(0, _items.Length - 1);
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
            if (Focused) AccessibilityNotifyClients(AccessibleEvents.Focus, v);
            SelectedIndexChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void ApplyTheme()
    {
        BackColor = Theme.Surface;
        Invalidate();
    }

    private int Px(int logical) => LogicalToDeviceUnits(logical);

    /// <summary>第 i 項的矩形（左右各留 SideGap，焦點框畫在裡面）。</summary>
    private Rectangle ItemRect(int i) =>
        new(Px(SideGap), Px(TopGap) + i * Px(ItemHeight), Width - Px(SideGap) * 2 - 1, Px(ItemHeight) - Px(4));

    private int HitTest(Point p)
    {
        for (var i = 0; i < _items.Length; i++) if (ItemRect(i).Contains(p)) return i;
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
        (keyData & Keys.KeyCode) is Keys.Up or Keys.Down or Keys.Home or Keys.End || base.IsInputKey(keyData);

    protected override void OnKeyDown(KeyEventArgs e)
    {
        switch (e.KeyCode)
        {
            case Keys.Up: SelectedIndex = _selected - 1; e.Handled = true; break;
            case Keys.Down: SelectedIndex = _selected + 1; e.Handled = true; break;
            case Keys.Home: SelectedIndex = 0; e.Handled = true; break;
            case Keys.End: SelectedIndex = _items.Length - 1; e.Handled = true; break;
        }
        base.OnKeyDown(e);
    }

    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Theme.Surface);
        using var pen = new Pen(Theme.Line);
        g.DrawLine(pen, Width - 1, 0, Width - 1, Height);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var radius = Px(4);
        for (var i = 0; i < _items.Length; i++)
        {
            var r = ItemRect(i);
            var selected = i == _selected;
            if (selected) Theme.FillRound(g, r, radius, Theme.AccentSoft, null, 0);
            else if (i == _hover)
            {
                using var b = new SolidBrush(Theme.Mix(Theme.Ink, Theme.Surface, 0.06));
                g.FillRectangle(b, r);
            }
            if (selected)
            {
                // 左側強調色直條（Windows 11 設定 App 的選取標記）
                var barH = Math.Max(Px(12), r.Height / 2);
                var bar = new Rectangle(r.X + Px(2), r.Y + (r.Height - barH) / 2, Px(3), barH);
                Theme.FillRound(g, bar, Px(2), Theme.Accent, null, 0);
            }
            var textRect = new Rectangle(r.X + Px(14), r.Y, r.Width - Px(18), r.Height);
            TextRenderer.DrawText(g, _items[i], Font, textRect, Enabled ? Theme.Ink : Theme.Muted,
                Theme.TextFlags | TextFormatFlags.VerticalCenter);
            if (selected && Focused && ShowFocusCues) Theme.FocusRing(g, r, radius, Px(2));
        }
    }

    protected override AccessibleObject CreateAccessibilityInstance() => new NavAccessible(this);

    private sealed class NavAccessible(NavList owner) : ControlAccessibleObject(owner)
    {
        public override AccessibleRole Role => AccessibleRole.PageTabList;
        public override int GetChildCount() => owner._items.Length;
        public override AccessibleObject? GetChild(int index) =>
            index >= 0 && index < owner._items.Length ? new NavItem(owner, index, this) : null;
        public override AccessibleObject? GetSelected() =>
            owner._items.Length > 0 ? new NavItem(owner, owner._selected, this) : null;
        public override AccessibleObject? GetFocused() => owner.Focused ? GetSelected() : null;
    }

    private sealed class NavItem(NavList owner, int index, AccessibleObject parent) : AccessibleObject
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
        public override Rectangle Bounds => index < owner._items.Length ? owner.RectangleToScreen(owner.ItemRect(index)) : Rectangle.Empty;
    }
}

/// <summary>
/// 設定視窗右側的一個分頁：內容過高時自己捲動（底部按鈕不跟著捲）。原生捲軸跟著深淺色。
/// 內容放在 <see cref="Body"/>（自動大小、不停駐），左上角固定在 <paramref name="inset"/>；
/// 位置與捲動邊界都用 96 DPI 的邏輯像素，在建構子裡設定，隨視窗的 DPI 縮放一起換算。
/// </summary>
internal sealed class ScrollPage : Panel, IThemed
{
    public ScrollPage(TableLayoutPanel body, Size inset)
    {
        Body = body;
        AutoScroll = true;
        BackColor = Theme.Bg;
        Dock = DockStyle.Fill;
        Margin = Padding.Empty;
        body.Location = new Point(inset.Width, inset.Height);
        // 捲到底時最後一列下方仍留同樣的空白
        AutoScrollMargin = new Size(0, inset.Height);
        Controls.Add(body);
    }

    public TableLayoutPanel Body { get; }

    public void ApplyTheme()
    {
        BackColor = Theme.Bg;
        Theme.ApplyNativeScrollbars(this);
        Invalidate();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyNativeScrollbars(this);
    }
}
