using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 閘道連線紀錄（F4）的讀寫：%LOCALAPPDATA%\SplitSwan\gateway-history.json。
/// 讀不到或壞檔一律當空歷史（GatewayHistory.FromJson 不丟例外）；寫入失敗只寫記錄，不打斷連線流程。
/// </summary>
internal static class GatewayHistoryStore
{
    public static GatewayHistory Load()
    {
        try
        {
            if (!File.Exists(AppPaths.GatewayHistoryFile)) return new GatewayHistory();
            return GatewayHistory.FromJson(File.ReadAllText(AppPaths.GatewayHistoryFile, Encoding.UTF8));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            AppLog.Error($"讀取閘道連線紀錄失敗，改用空紀錄：{ex.Message}");
            return new GatewayHistory();
        }
    }

    /// <summary>先寫暫存檔再替換，避免寫到一半留下壞檔。</summary>
    public static void Save(GatewayHistory h)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            var tmp = AppPaths.GatewayHistoryFile + ".tmp";
            File.WriteAllText(tmp, h.ToJson(), new UTF8Encoding(false));
            File.Move(tmp, AppPaths.GatewayHistoryFile, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            AppLog.Error($"儲存閘道連線紀錄失敗：{ex.Message}");
        }
    }
}
