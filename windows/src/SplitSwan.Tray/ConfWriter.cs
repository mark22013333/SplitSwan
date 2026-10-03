using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>設定本身不合法（驗證失敗）：重試也沒用，要使用者修改設定。訊息為繁中、不含密碼。</summary>
internal sealed class SettingsInvalidException(string message) : Exception(message);

/// <summary>
/// 產生引擎要讀的設定檔到 %LOCALAPPDATA%\SplitSwan\conf。
/// secrets.conf 含 PSK 與密碼：寫入前先把資料夾 ACL 設為「受保護、只含 目前使用者／SYSTEM／Administrators」，
/// 並刪掉舊檔讓新檔從資料夾繼承這份 ACL；引擎跑完（不論成敗）由呼叫端呼叫 DeleteSecrets 刪掉。
/// </summary>
internal static class ConfWriter
{
    /// <summary>App 會寫的檔案；只有這幾個會被刪除重建，資料夾裡的其他檔案一律不動。</summary>
    private static string[] OwnFiles => [AppPaths.SwanctlConf, AppPaths.SecretsConf, AppPaths.OptionsIni];

    /// <summary>驗證設定（連線欄位＋DNS 分流）；回傳繁中錯誤清單，空清單＝合法。</summary>
    public static IReadOnlyList<string> Validate(StoredSettings s) =>
        [.. SettingsValidator.Validate(s.ToVpnSettings()), .. DnsOptions.Validate(s.Domain, s.DnsServer)];

    /// <summary>
    /// 驗證並寫入 swanctl.conf、secrets.conf、options.ini（Domain／DnsServer 有填才寫）。
    /// 設定不合法 → SettingsInvalidException（不會寫任何檔案）；
    /// ACL 設不起來、磁碟錯誤等執行期問題 → 其他例外（不會寫出 secrets.conf，或已寫的由呼叫端刪除）。
    /// </summary>
    public static void Write(StoredSettings s)
    {
        var errors = Validate(s);
        if (errors.Count > 0)
            throw new SettingsInvalidException("設定不完整或格式不正確，請先到「設定…」修正：\n" + string.Join("\n", errors));

        // 產生內容放在動檔案之前：Renderer 丟例外時訊息是驗證錯誤清單（不含密碼）
        string conf, secrets;
        string? options;
        try
        {
            var vpn = s.ToVpnSettings();
            conf = SwanctlRenderer.RenderConf(vpn);
            secrets = SwanctlRenderer.RenderSecrets(vpn);
            options = DnsOptions.RenderOptionsIni(s.Domain, s.DnsServer);
        }
        catch (ArgumentException ex)
        {
            throw new SettingsInvalidException("設定格式不正確：" + ex.Message);
        }

        Directory.CreateDirectory(AppPaths.ConfDir);
        RestrictDirectoryAcl(AppPaths.ConfDir);

        // 先刪舊檔再寫：新建的檔案一定從資料夾繼承上面設定的 ACL。
        // 不去改既有檔案的 ACL——「空 DACL＋取消保護」要靠 Windows 重新套用繼承的行為，沒有實測過，
        // 萬一變成受保護的空 DACL，連自己都打不開；刪掉重建沒有這個不確定性。
        foreach (var f in OwnFiles)
            if (File.Exists(f)) File.Delete(f);

        var utf8 = new UTF8Encoding(false);
        File.WriteAllText(AppPaths.SwanctlConf, conf, utf8);
        if (options is not null) File.WriteAllText(AppPaths.OptionsIni, options, utf8);
        File.WriteAllText(AppPaths.SecretsConf, secrets, utf8);
    }

    /// <summary>刪除 secrets.conf；失敗只記錄、回傳 false，不丟例外（由呼叫端通知使用者）。</summary>
    public static bool DeleteSecrets()
    {
        if (!File.Exists(AppPaths.SecretsConf)) return true;
        try
        {
            File.Delete(AppPaths.SecretsConf);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            AppLog.Error($"刪除 secrets.conf 失敗：{ex.Message}（路徑 {AppPaths.SecretsConf}）");
            return false;
        }
    }

    /// <summary>
    /// 對資料夾套用明確建立的 DACL：受保護（不繼承上層）、只有三筆「完全控制」ACE——目前使用者、SYSTEM、Administrators，
    /// 且設為子資料夾與檔案繼承。不是在既有 ACL 上增減，而是整份取代，所以結果不取決於原本的 ACL。
    /// 設不起來就丟例外，呼叫端不得繼續寫 secrets.conf。
    /// </summary>
    private static void RestrictDirectoryAcl(string dir)
    {
        try
        {
            var user = WindowsIdentity.GetCurrent().User
                ?? throw new InvalidOperationException("取不到目前使用者的 SID");
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            var admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);

            var sec = new DirectorySecurity();
            sec.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            foreach (var sid in new[] { user, system, admins })
            {
                sec.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                    PropagationFlags.None, AccessControlType.Allow));
            }
            new DirectoryInfo(dir).SetAccessControl(sec);
        }
        catch (Exception ex)
        {
            throw new IOException($"無法設定設定檔資料夾的存取權限，為了保護密碼已停止連線：{ex.Message}", ex);
        }
    }
}
