using System.Drawing;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 匯入 Mac 版匯出的 .splitswan：選檔 → 輸入密碼 → 解密。
/// 只回傳解出的公司設定，不寫入任何檔案；由設定視窗讓使用者看過閘道並按「儲存」才寫入
/// （加密只保密、不證明來源，Mac 版同樣要求確認）。
/// </summary>
internal static class ImportFlow
{
    /// <summary>檔案大小上限（同 Mac 版與 Core 的 SplitswanImporter）。</summary>
    private const long MaxFileBytes = 1_000_000;

    /// <summary>使用者取消或失敗時回傳 null（失敗已顯示訊息）。</summary>
    public static async Task<ImportedProfile?> RunAsync(IWin32Window? owner)
    {
        string path;
        using (var dlg = new OpenFileDialog
        {
            Title = "匯入 SplitSwan 設定檔",
            Filter = "SplitSwan 設定檔 (*.splitswan)|*.splitswan|所有檔案 (*.*)|*.*",
            CheckFileExists = true,
            Multiselect = false,
        })
        {
            if (dlg.ShowDialog(owner) != DialogResult.OK) return null;
            path = dlg.FileName;
        }
        UiWatchdog.Mark("匯入：已選檔");

        byte[] bytes;
        try
        {
            var len = new FileInfo(path).Length;
            if (len > MaxFileBytes)
            {
                Error(owner, $"檔案太大（{len:N0} bytes），這不是 SplitSwan 的設定檔。上限 {MaxFileBytes:N0} bytes。");
                return null;
            }
            bytes = await File.ReadAllBytesAsync(path);
            if (bytes.LongLength > MaxFileBytes)
            {
                Error(owner, "檔案太大，這不是 SplitSwan 的設定檔。");
                return null;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Error(owner, $"讀取檔案失敗：{ex.Message}");
            return null;
        }

        while (true)
        {
            UiWatchdog.Mark("匯入：開啟密碼視窗");
            var pass = PassphraseForm.Ask(owner, Path.GetFileName(path));
            UiWatchdog.Mark(pass is null ? "匯入：密碼視窗已關閉（取消）" : "匯入：密碼視窗已關閉（確定）");
            if (pass is null) return null;
            try
            {
                // PBKDF2 60 萬次約需半秒，放到背景避免畫面凍結
                UiWatchdog.Mark("匯入：開始解密");
                var profile = await Task.Run(() => SplitswanImporter.Decrypt(bytes, pass));
                UiWatchdog.Mark("匯入：解密完成，回到 UI 執行緒");
                AppLog.Info($"已解開設定檔 {Path.GetFileName(path)}：{profile.Gateways.Count} 台閘道、{profile.RemoteSubnets.Count} 筆網段（尚未儲存）");
                return profile;
            }
            catch (SplitswanImportException ex)
            {
                AppLog.Info($"匯入 {Path.GetFileName(path)} 失敗：{ex.Message}");
                var retry = MessageBox.Show(owner, ex.Message + "\n\n要重新輸入密碼嗎？", "匯入失敗",
                    MessageBoxButtons.RetryCancel, MessageBoxIcon.Warning);
                if (retry != DialogResult.Retry) return null;
            }
        }
    }

    private static void Error(IWin32Window? owner, string msg) =>
        MessageBox.Show(owner, msg, "匯入失敗", MessageBoxButtons.OK, MessageBoxIcon.Warning);
}

/// <summary>輸入 .splitswan 密碼的小視窗。</summary>
internal sealed class PassphraseForm : Form
{
    private readonly TextBox _box;

    private PassphraseForm(string fileName)
    {
        Text = "輸入設定檔密碼";
        AppIcon.Apply(this);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(12);

        var layout = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, Dock = DockStyle.Fill };
        layout.Controls.Add(new Label { Text = $"「{fileName}」的密碼（匯出時設定的那一組）：", AutoSize = true });
        _box = new TextBox { UseSystemPasswordChar = true, Width = 320 };
        layout.Controls.Add(_box);
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        var ok = new Button { Text = "確定", DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.AddRange([cancel, ok]);
        layout.Controls.Add(buttons);
        Controls.Add(layout);
        AcceptButton = ok;
        CancelButton = cancel;
        Font = new Font("Microsoft JhengHei UI", 9f);
    }

    public static string? Ask(IWin32Window? owner, string fileName)
    {
        using var f = new PassphraseForm(fileName);
        return f.ShowDialog(owner) == DialogResult.OK ? f._box.Text : null;
    }
}
