using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 產生引擎要讀的設定檔到 %LOCALAPPDATA%\SplitSwan\conf。
/// secrets.conf 含 PSK 與密碼：寫入前先把資料夾 ACL 收緊為「目前使用者＋SYSTEM＋Administrators」並移除繼承，
/// 引擎跑完（不論成敗）由呼叫端呼叫 DeleteSecrets 刪掉。
/// </summary>
internal static class ConfWriter
{
    /// <summary>
    /// 驗證並寫入 swanctl.conf、secrets.conf、options.ini（Domain／DnsServer 有填才寫，沒填就刪掉舊的）。
    /// 驗證失敗或 ACL 設不起來時丟 InvalidOperationException（繁中訊息，不含密碼），且不會寫出 secrets.conf。
    /// </summary>
    public static void Write(StoredSettings s)
    {
        var vpn = s.ToVpnSettings();
        var errors = SettingsValidator.Validate(vpn).Concat(DnsOptions.Validate(s.Domain, s.DnsServer)).ToList();
        if (errors.Count > 0)
            throw new InvalidOperationException("設定不完整或格式不正確，請先到「設定…」修正：\n" + string.Join("\n", errors));

        // 產生內容放在 ACL 之前：Renderer 若丟例外，訊息是驗證錯誤清單（不含密碼）
        string conf, secrets;
        string? options;
        try
        {
            conf = SwanctlRenderer.RenderConf(vpn);
            secrets = SwanctlRenderer.RenderSecrets(vpn);
            options = DnsOptions.RenderOptionsIni(s.Domain, s.DnsServer);
        }
        catch (ArgumentException ex)
        {
            throw new InvalidOperationException("設定格式不正確：" + ex.Message);
        }

        Directory.CreateDirectory(AppPaths.ConfDir);
        RestrictAcl(AppPaths.ConfDir);

        var utf8 = new UTF8Encoding(false);
        File.WriteAllText(AppPaths.SwanctlConf, conf, utf8);
        if (options is null) TryDelete(AppPaths.OptionsIni);
        else File.WriteAllText(AppPaths.OptionsIni, options, utf8);
        File.WriteAllText(AppPaths.SecretsConf, secrets, utf8);
    }

    /// <summary>刪除 secrets.conf；失敗只記錄，不丟例外。回傳是否已不存在。</summary>
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
            AppLog.Error($"刪除 secrets.conf 失敗：{ex.Message}（路徑 {AppPaths.SecretsConf}，請手動刪除）");
            return false;
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            AppLog.Error($"刪除 {Path.GetFileName(path)} 失敗：{ex.Message}");
        }
    }

    /// <summary>
    /// 資料夾只允許：目前使用者、SYSTEM、Administrators（完全控制，子檔案與子資料夾繼承），移除從上層繼承的權限。
    /// 已存在的檔案改成繼承這份設定。設不起來就丟例外，呼叫端不得繼續寫 secrets.conf。
    /// </summary>
    private static void RestrictAcl(string dir)
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

            // 先前留下的檔案若有明確 ACL，改回只繼承資料夾的設定
            foreach (var f in Directory.GetFiles(dir))
            {
                var fs = new FileSecurity();
                fs.SetAccessRuleProtection(isProtected: false, preserveInheritance: false);
                new FileInfo(f).SetAccessControl(fs);
            }
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException or SystemException
                                       and not InvalidOperationException)
        {
            throw new InvalidOperationException($"無法設定設定檔資料夾的存取權限，為了保護密碼已停止連線：{ex.Message}");
        }
    }
}
