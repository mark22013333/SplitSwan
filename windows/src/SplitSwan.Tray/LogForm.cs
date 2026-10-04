using System.Diagnostics;
using System.Drawing;
using SplitSwan.Core;
using SplitSwan.Tray.Controls;

namespace SplitSwan.Tray;

/// <summary>
/// 「顯示引擎輸出」視窗（視覺稿 C 的記錄視窗）：App 記錄與引擎輸出（最近 2000 行），即時更新。
/// 上方分段篩選「全部／錯誤 N／引擎」（計數即時更新）、複製（目前篩選結果）、開啟記錄資料夾；
/// 清單三欄：時間、等級（上色）、內容。解析與篩選規則在 Core 的 LogView。
/// </summary>
internal sealed class LogForm : ThemedForm
{
    private const int KeepLines = 2000;
    private static readonly LogFilter[] Filters = [LogFilter.All, LogFilter.Errors, LogFilter.Engine];

    private readonly List<LogEntry> _all = new();
    private readonly SegmentedControl _filter = new() { AccessibleName = "篩選記錄" };
    private readonly LogList _list = new();
    private readonly ThemedButton _copy = new("複製");
    private readonly ThemedButton _openDir = new("開啟資料夾");
    private readonly ThemedLabel _status = new("", TextRole.Muted);

    public LogForm()
    {
        Text = "SplitSwan 記錄";
        Size = new Size(880, 540);
        MinimumSize = new Size(520, 320);
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true;
        Padding = new Padding(16, 14, 16, 12);
        KeyPreview = true;

        var tools = UiLayout.Table(4, 1);
        tools.Dock = DockStyle.Top;
        tools.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        tools.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        tools.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        tools.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        tools.Padding = new Padding(0, 0, 0, 10);
        _filter.Margin = Padding.Empty;
        tools.Controls.Add(_filter, 0, 0);
        tools.Controls.Add(new Panel { Width = 1, Height = 1, BackColor = Color.Transparent, Margin = Padding.Empty }, 1, 0);
        tools.Controls.Add(_copy, 2, 0);
        tools.Controls.Add(_openDir, 3, 0);

        var listFrame = new CardPanel { Dock = DockStyle.Fill, Padding = new Padding(1) };
        _list.Dock = DockStyle.Fill;
        listFrame.Controls.Add(_list);

        var bottom = UiLayout.Table(2, 1);
        bottom.Dock = DockStyle.Bottom;
        bottom.Padding = new Padding(0, 8, 0, 0);
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        bottom.Controls.Add(new ThemedLabel("記錄含內部位址，分享前請先遮蔽。", TextRole.Muted, Theme.Ui(8.25f)) { Margin = Padding.Empty }, 0, 0);
        _status.Margin = Padding.Empty;
        _status.Font = Theme.Ui(8.25f);
        bottom.Controls.Add(_status, 1, 0);

        // Dock 的順序：先加 Fill，再加 Top／Bottom（後加的先排）
        Controls.Add(listFrame);
        Controls.Add(tools);
        Controls.Add(bottom);

        _filter.SelectedIndexChanged += (_, _) => Rebuild();
        _copy.Click += (_, _) => CopyFiltered();
        _openDir.Click += (_, _) => OpenLogFolder();

        _all.AddRange(AppLog.Snapshot().Select(LogView.Parse));
        UpdateCounts();
        Rebuild();
        AppLog.LineAdded += OnLine;
        FormClosed += (_, _) => AppLog.LineAdded -= OnLine;
        Shown += (_, _) => { _list.ScrollToEnd(); _list.Focus(); };
        FinishLayout();
    }

    private LogFilter Current => Filters[Math.Clamp(_filter.SelectedIndex, 0, Filters.Length - 1)];

    private void UpdateCounts()
    {
        var (all, errors, engine) = LogView.Count(_all);
        var titles = Filters.Select(f => LogView.SegmentTitle(f, errors)).ToList();
        if (!_filter.Items.SequenceEqual(titles)) _filter.Items = titles;
        _status.Text = $"共 {all} 行（錯誤 {errors}、引擎 {engine}）";
    }

    private void Rebuild()
    {
        _list.SetEntries(LogView.Filter(_all, Current));
        _list.ScrollToEnd();
    }

    private void OnLine(string line)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try
        {
            BeginInvoke(() =>
            {
                if (IsDisposed) return;
                var e = LogView.Parse(line);
                _all.Add(e);
                var dropped = false;
                if (_all.Count > KeepLines)
                {
                    var old = _all[0];
                    _all.RemoveAt(0);
                    dropped = LogView.Matches(old, Current);
                }
                UpdateCounts();
                if (dropped) _list.RemoveFirst();
                if (LogView.Matches(e, Current)) _list.Append(e);
            });
        }
        catch (InvalidOperationException) { /* 視窗正在關閉 */ }
    }

    private void CopyFiltered()
    {
        var text = LogView.CopyText(LogView.Filter(_all, Current));
        if (text.Length == 0) { _status.Text = "目前篩選沒有內容可複製"; return; }
        try
        {
            Clipboard.SetText(text);
            _status.Text = $"已複製 {LogView.Filter(_all, Current).Count} 行";
        }
        catch (System.Runtime.InteropServices.ExternalException ex)
        {
            _status.Text = "複製失敗：" + ex.Message;
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        // Ctrl+C：清單有選取時複製該行，否則複製整個篩選結果
        if (e.Control && e.KeyCode == Keys.C && _list.ContainsFocus)
        {
            if (_list.SelectedEntry is { } sel)
            {
                try { Clipboard.SetText(sel.Raw); _status.Text = "已複製 1 行"; }
                catch (System.Runtime.InteropServices.ExternalException ex) { _status.Text = "複製失敗：" + ex.Message; }
            }
            else CopyFiltered();
            e.Handled = true;
        }
        base.OnKeyDown(e);
    }

    public static void OpenLogFolder()
    {
        try
        {
            Directory.CreateDirectory(AppPaths.LogDir);
            // 用完整路徑，不靠 PATH 搜尋（App 以管理員執行）
            var explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
            Process.Start(new ProcessStartInfo(explorer) { ArgumentList = { AppPaths.LogDir }, UseShellExecute = false });
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or IOException or UnauthorizedAccessException)
        {
            MessageBox.Show($"無法開啟記錄資料夾：{ex.Message}\n路徑：{AppPaths.LogDir}", "SplitSwan",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    /// <summary>
    /// 記錄清單：自繪 ListBox，三欄（時間、等級、內容）對齊；等級上色（錯誤紅、引擎灰、訊息強調色）。
    /// 內容不換行，太長時用水平捲軸。字型共用 Theme 的快取（不在繪製時建立）。
    /// </summary>
    private sealed class LogList : ListBox, IThemed
    {
        private int _extent;

        public LogList()
        {
            DrawMode = DrawMode.OwnerDrawFixed;
            BorderStyle = BorderStyle.None;
            IntegralHeight = false;
            HorizontalScrollbar = true;
            SelectionMode = SelectionMode.One;
            Font = Theme.Mono(9f);
            ItemHeight = Font.Height + LogicalToDeviceUnits(6);
            AccessibleName = "記錄內容";
            // 項目文字（無障礙工具讀到的內容）用原始整行，而不是 record 的 ToString
            FormattingEnabled = true;
            Format += (_, e) => { if (e.ListItem is LogEntry le) e.Value = le.Raw; };
            ApplyTheme();
        }

        public LogEntry? SelectedEntry => SelectedItem as LogEntry;

        public void ApplyTheme()
        {
            BackColor = Theme.Surface;
            ForeColor = Theme.Ink;
            Theme.ApplyNativeScrollbars(this);   // 原生捲軸（含水平捲軸）跟著深淺色
            Invalidate();
        }

        /// <summary>等級欄的字型：直接繪製用，依清單目前的 DeviceDpi 縮放（Theme.AtDpi 依 DPI 快取）。</summary>
        private Font LevelFont => Theme.AtDpi(Theme.Ui(8.25f), DeviceDpi);

        private int TimeWidth => Theme.Measure("00:00:00", Font).Width + LogicalToDeviceUnits(14);
        private int LevelWidth => Theme.Measure("錯誤", LevelFont).Width + LogicalToDeviceUnits(16);

        public void SetEntries(IReadOnlyList<LogEntry> entries)
        {
            BeginUpdate();
            Items.Clear();
            _extent = 0;
            foreach (var e in entries) { Items.Add(e); Measure(e); }
            EndUpdate();
        }

        public void Append(LogEntry e)
        {
            var atEnd = Items.Count == 0 || TopIndex + VisibleRows >= Items.Count - 1;
            Items.Add(e);
            Measure(e);
            if (atEnd) ScrollToEnd();
        }

        public void RemoveFirst()
        {
            if (Items.Count > 0) Items.RemoveAt(0);
        }

        private int VisibleRows => Math.Max(1, ClientSize.Height / Math.Max(1, ItemHeight));

        public void ScrollToEnd()
        {
            if (Items.Count > 0) TopIndex = Math.Max(0, Items.Count - VisibleRows);
        }

        private void Measure(LogEntry e)
        {
            var w = LogicalToDeviceUnits(10) + TimeWidth + LevelWidth
                    + Theme.Measure(OneLine(e.Text), Font).Width + LogicalToDeviceUnits(16);
            if (w > _extent) { _extent = w; HorizontalExtent = w; }
        }

        private static string OneLine(string s) => s.Replace("\r", "").Replace('\n', '⏎');

        protected override void OnDrawItem(DrawItemEventArgs e)
        {
            if (e.Index < 0 || e.Index >= Items.Count || Items[e.Index] is not LogEntry entry) return;
            var g = e.Graphics;
            var selected = (e.State & DrawItemState.Selected) != 0;
            using (var b = new SolidBrush(selected ? Theme.AccentSoft : Theme.Surface)) g.FillRectangle(b, e.Bounds);
            if (e.Index > 0)
            {
                using var pen = new Pen(Theme.Mix(Theme.Line, Theme.Surface, 0.55));
                g.DrawLine(pen, e.Bounds.Left, e.Bounds.Top, e.Bounds.Right, e.Bounds.Top);
            }
            var x = e.Bounds.X + LogicalToDeviceUnits(10);
            var r = new Rectangle(x, e.Bounds.Y, TimeWidth, e.Bounds.Height);
            TextRenderer.DrawText(g, entry.Time, Font, r, Theme.Muted, Theme.TextFlags | TextFormatFlags.VerticalCenter);
            r.X += TimeWidth;
            r.Width = LevelWidth;
            var levelColor = entry.Level switch
            {
                LogLevel.Error => Theme.Tone(StatusTone.Bad),
                LogLevel.Engine => Theme.Muted,
                _ => Theme.Accent,
            };
            TextRenderer.DrawText(g, LogView.LevelTitle(entry.Level), LevelFont, r, levelColor,
                Theme.TextFlags | TextFormatFlags.VerticalCenter);
            r.X += LevelWidth;
            r.Width = Math.Max(0, e.Bounds.Right - r.X);
            var ink = entry.Level == LogLevel.Error ? Theme.Tone(StatusTone.Bad) : Theme.Ink;
            TextRenderer.DrawText(g, OneLine(entry.Text), Font, r, ink,
                TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.VerticalCenter);
            if ((e.State & DrawItemState.Focus) != 0 && Focused) e.DrawFocusRectangle();
        }

        /// <summary>控制碼建立時（視窗已依 DPI 縮放完）再算一次列高，避免縮放前算的像素值被再放大。</summary>
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ItemHeight = Font.Height + LogicalToDeviceUnits(6);
            Theme.ApplyNativeScrollbars(this);
        }

        protected override void OnFontChanged(EventArgs e)
        {
            base.OnFontChanged(e);
            ItemHeight = Font.Height + LogicalToDeviceUnits(6);
        }

        protected override void OnDpiChangedAfterParent(EventArgs e)
        {
            base.OnDpiChangedAfterParent(e);
            ItemHeight = Font.Height + LogicalToDeviceUnits(6);
        }
    }
}
