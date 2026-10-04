using System.Diagnostics;
using System.Drawing;

namespace SplitSwan.Tray;

/// <summary>「顯示引擎輸出」視窗：App 記錄與引擎輸出（最近 2000 行），即時更新。</summary>
internal sealed class LogForm : Form
{
    private readonly TextBox _text;

    public LogForm()
    {
        Text = "SplitSwan － 引擎輸出";
        AppIcon.Apply(this);
        Size = new Size(860, 520);
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true;

        _text = new TextBox
        {
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Both,
            WordWrap = false,
            Dock = DockStyle.Fill,
            Font = new Font("Consolas", 9.5f),
            BackColor = SystemColors.Window,
        };

        var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(6) };
        var openDir = new Button { Text = "開啟記錄資料夾", AutoSize = true };
        openDir.Click += (_, _) => OpenLogFolder();
        var clear = new Button { Text = "清除畫面", AutoSize = true };
        clear.Click += (_, _) => _text.Clear();
        var note = new Label
        {
            Text = "記錄含內部位址，分享前請先遮蔽。",
            AutoSize = true,
            Padding = new Padding(8, 6, 0, 0),
            ForeColor = SystemColors.GrayText,
        };
        bar.Controls.AddRange([openDir, clear, note]);

        Controls.Add(_text);
        Controls.Add(bar);

        _text.Lines = [.. AppLog.Snapshot()];
        AppLog.LineAdded += OnLine;
        FormClosed += (_, _) => AppLog.LineAdded -= OnLine;
        Shown += (_, _) => ScrollToEnd();
    }

    private void OnLine(string line)
    {
        if (IsDisposed || !IsHandleCreated) return;
        BeginInvoke(() =>
        {
            if (IsDisposed) return;
            // 太長時從頭砍掉，避免 TextBox 越來越慢
            if (_text.TextLength > 400_000) _text.Text = _text.Text[^200_000..];
            _text.AppendText(line + Environment.NewLine);
        });
    }

    private void ScrollToEnd()
    {
        _text.SelectionStart = _text.TextLength;
        _text.ScrollToCaret();
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
}
