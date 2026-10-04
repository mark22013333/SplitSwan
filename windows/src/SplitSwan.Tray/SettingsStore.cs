using System.Security.Cryptography;
using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// settings.json 的讀寫。密碼與 PSK 用 DPAPI（CurrentUser）加密後才寫入，
/// 只有同一個 Windows 帳號在同一台電腦上解得開。
/// </summary>
internal static class SettingsStore
{
    // 額外熵：避免其他程式用同一個帳號的 DPAPI 隨手解開不相干的資料
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("SplitSwan.Settings.v1");

    private static byte[] Protect(byte[] plain) =>
        ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);

    private static byte[] Unprotect(byte[] cipher) =>
        ProtectedData.Unprotect(cipher, Entropy, DataProtectionScope.CurrentUser);

    public static SettingsLoadResult Load()
    {
        try
        {
            if (!File.Exists(AppPaths.SettingsFile)) return new(StoredSettings.Empty, []);
            return SettingsDocument.Deserialize(File.ReadAllText(AppPaths.SettingsFile, Encoding.UTF8), Unprotect);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 檔案存在但讀不到：當成舊版使用者（發行版 Ubuntu-24.04），見 SettingsDocument.Deserialize
            return new(StoredSettings.Empty with { Distro = WslDistros.Legacy }, [$"讀取設定檔失敗：{ex.Message}"]);
        }
    }

    /// <summary>寫入：先寫暫存檔再替換，避免寫到一半斷電留下壞檔。失敗丟例外（訊息不含密碼）。</summary>
    public static void Save(StoredSettings s)
    {
        Directory.CreateDirectory(AppPaths.DataDir);
        var json = SettingsDocument.Serialize(s, Protect);
        var tmp = AppPaths.SettingsFile + ".tmp";
        File.WriteAllText(tmp, json, new UTF8Encoding(false));
        File.Move(tmp, AppPaths.SettingsFile, overwrite: true);
    }
}
