using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// App 自己的記錄：寫到 %LOCALAPPDATA%\SplitSwan\logs\tray-yyyyMMdd-HHmmss.log（每次啟動一份，保留最近 10 份），
/// 同時留最近 2000 行在記憶體給「引擎輸出」視窗看。
/// 不記錄密碼／PSK：呼叫端本來就不傳，另外每一行寫入前再用目前設定的密碼與 PSK 遮蔽一次。
/// 可從任何執行緒呼叫。
/// </summary>
internal static class AppLog
{
    private const string Prefix = "tray-";
    private const int KeepFiles = 10;
    private const int KeepLines = 2000;

    private static readonly object Gate = new();
    private static readonly LinkedList<string> Recent = new();
    private static StreamWriter? _writer;
    private static string[] _secrets = [];

    /// <summary>新的一行（已遮蔽、含時間）。在寫入的執行緒上觸發，UI 要自己切回 UI 執行緒。</summary>
    public static event Action<string>? LineAdded;

    public static void Init()
    {
        lock (Gate)
        {
            if (_writer is not null) return;
            try
            {
                Directory.CreateDirectory(AppPaths.LogDir);
                var path = Path.Combine(AppPaths.LogDir, $"{Prefix}{DateTime.Now:yyyyMMdd-HHmmss}.log");
                _writer = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read),
                    new UTF8Encoding(false)) { AutoFlush = true };
                PruneOldFiles();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // 記錄檔寫不了不影響連線功能，只留在記憶體
                _writer = null;
                AddRecent($"{DateTime.Now:HH:mm:ss} 無法建立記錄檔：{ex.Message}");
            }
        }
    }

    /// <summary>設定目前的密碼與 PSK，寫入記錄前遮蔽。設定變更後要再呼叫一次。</summary>
    public static void SetSecrets(params string?[] secrets)
    {
        lock (Gate) _secrets = [.. secrets.Where(s => !string.IsNullOrEmpty(s)).Select(s => s!)];
    }

    public static void Info(string message) => Write("", message);
    public static void Engine(string line) => Write("│ ", line);
    public static void Error(string message) => Write("錯誤：", message);

    public static IReadOnlyList<string> Snapshot()
    {
        lock (Gate) return [.. Recent];
    }

    private static void Write(string tag, string message)
    {
        string line;
        lock (Gate)
        {
            line = $"{DateTime.Now:HH:mm:ss} {tag}{LogHygiene.Redact(message ?? "", _secrets)}";
            AddRecent(line);
            try { _writer?.WriteLine(line); }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException) { _writer = null; }
        }
        try { LineAdded?.Invoke(line); } catch (InvalidOperationException) { /* 視窗已關閉 */ }
    }

    private static void AddRecent(string line)
    {
        Recent.AddLast(line);
        while (Recent.Count > KeepLines) Recent.RemoveFirst();
    }

    private static void PruneOldFiles()
    {
        // 只刪自己產生的 tray-*.log，其他檔案不動
        var names = Directory.GetFiles(AppPaths.LogDir).Select(Path.GetFileName).OfType<string>();
        foreach (var name in LogHygiene.SelectForDeletion(names, Prefix, KeepFiles))
        {
            try { File.Delete(Path.Combine(AppPaths.LogDir, name)); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* 下次再刪 */ }
        }
    }

    public static void Close()
    {
        lock (Gate)
        {
            _writer?.Dispose();
            _writer = null;
        }
    }
}
