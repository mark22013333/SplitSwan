using System.Text;
using Microsoft.Win32;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>首次設定精靈的存檔（wizard.json）與重開機後自動開 App（HKCU RunOnce）。</summary>
internal static class WizardStore
{
    private const string RunOnceKey = @"Software\Microsoft\Windows\CurrentVersion\RunOnce";

    public static SetupWizardState Load()
    {
        try
        {
            return File.Exists(AppPaths.WizardFile)
                ? SetupWizardState.FromJson(File.ReadAllText(AppPaths.WizardFile, Encoding.UTF8))
                : new SetupWizardState();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            AppLog.Error($"讀取精靈進度失敗：{ex.Message}");
            return new SetupWizardState();
        }
    }

    /// <summary>先寫暫存檔再替換。失敗只寫記錄（精靈照常可用，只是重開機後要從頭偵測）。</summary>
    public static void Save(SetupWizardState s)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            var tmp = AppPaths.WizardFile + ".tmp";
            File.WriteAllText(tmp, s.ToJson(), new UTF8Encoding(false));
            File.Move(tmp, AppPaths.WizardFile, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            AppLog.Error($"儲存精靈進度失敗：{ex.Message}");
        }
    }

    /// <summary>這次開機的時間（現在減掉開機後經過的時間；GetTickCount64 含睡眠時間）。</summary>
    public static DateTimeOffset CurrentBootTime() =>
        DateTimeOffset.Now - TimeSpan.FromMilliseconds(Environment.TickCount64);

    /// <summary>
    /// 登記重開機後自動開 App（下次登入時執行一次，Windows 執行前就會刪掉這筆）。
    /// 回傳 null＝成功；否則是給使用者看的原因（例如路徑太長），精靈改請使用者重開機後手動開 App。
    /// </summary>
    public static string? RegisterRunOnce()
    {
        var cmd = RunOnceCommand.Build(Environment.ProcessPath);
        if (cmd is null) return "程式路徑太長或含引號，無法登記重開機後自動開啟";
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunOnceKey, writable: true);
            k.SetValue(RunOnceCommand.ValueName, cmd, RegistryValueKind.String);
            AppLog.Info($"已登記重開機後自動開啟：HKCU\\{RunOnceKey}\\{RunOnceCommand.ValueName}");
            return null;
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
            return $"無法寫入登錄（RunOnce）：{ex.Message}";
        }
    }

    /// <summary>精靈已越過重開機步驟：把還沒被 Windows 執行的那筆刪掉，免得下次登入又多開一次。</summary>
    public static void ClearRunOnce()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunOnceKey, writable: true);
            if (k?.GetValue(RunOnceCommand.ValueName) is null) return;
            k.DeleteValue(RunOnceCommand.ValueName, throwOnMissingValue: false);
            AppLog.Info("已取消重開機後自動開啟（精靈已繼續）");
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
            AppLog.Error($"清除 RunOnce 失敗：{ex.Message}");
        }
    }
}
