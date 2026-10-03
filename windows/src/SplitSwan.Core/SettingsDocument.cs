using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SplitSwan.Core;

/// <summary>托盤 App 存在 settings.json 的完整設定（密碼與 PSK 為原文，只存在記憶體）。</summary>
public sealed record StoredSettings(
    string Username,
    string Password,
    string Psk,
    IReadOnlyList<string> Gateways,
    IReadOnlyList<string> RemoteSubnets,
    string Domain,
    string DnsServer,
    bool AutoReconnect)
{
    /// <summary>全新安裝的預設值：全部空白、自動重連關閉。</summary>
    public static StoredSettings Empty { get; } = new("", "", "", ["", "", ""], [], "", "", false);

    /// <summary>轉成產生 swanctl.conf／secrets.conf 用的設定。</summary>
    public VpnSettings ToVpnSettings() => new(Username, Password, Psk, Gateways, RemoteSubnets);
}

/// <summary>讀取 settings.json 的結果；Warnings 是要顯示給使用者的繁中提示（例如密碼解不開）。</summary>
public sealed record SettingsLoadResult(StoredSettings Settings, IReadOnlyList<string> Warnings);

/// <summary>
/// settings.json 的序列化。密碼與 PSK 交給呼叫端提供的 protect／unprotect 加解密
/// （Windows 上是 DPAPI CurrentUser），JSON 裡只出現加密後的 base64，不出現原文。
/// 本類別不碰任何 Windows API，方便在 macOS 上測試。
/// </summary>
public static class SettingsDocument
{
    private const int Version = 1;

    public static string Serialize(StoredSettings s, Func<byte[], byte[]> protect)
    {
        ArgumentNullException.ThrowIfNull(s);
        ArgumentNullException.ThrowIfNull(protect);
        var o = new JsonObject
        {
            ["version"] = Version,
            ["username"] = s.Username,
            ["passwordProtected"] = ProtectText(s.Password, protect),
            ["pskProtected"] = ProtectText(s.Psk, protect),
            ["gateways"] = new JsonArray([.. s.Gateways.Select(g => (JsonNode?)JsonValue.Create(g))]),
            ["remoteSubnets"] = new JsonArray([.. s.RemoteSubnets.Select(n => (JsonNode?)JsonValue.Create(n))]),
            ["domain"] = s.Domain,
            ["dnsServer"] = s.DnsServer,
            ["autoReconnect"] = s.AutoReconnect,
        };
        return o.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>
    /// 讀回設定。JSON 壞掉或版本不對時回傳空白設定加一則提示（不丟例外，App 照樣能開）；
    /// 密碼／PSK 解不開（例如換了 Windows 帳號）時該欄留空並加提示，其他欄位照常讀回。
    /// 提示文字不含任何密碼內容。
    /// </summary>
    public static SettingsLoadResult Deserialize(string json, Func<byte[], byte[]> unprotect)
    {
        ArgumentNullException.ThrowIfNull(unprotect);
        var warnings = new List<string>();
        JsonObject? o;
        try { o = JsonNode.Parse(json ?? "") as JsonObject; }
        catch (JsonException) { o = null; }
        if (o is null)
            return new(StoredSettings.Empty, ["設定檔已損毀，已改用空白設定，請重新填寫或匯入"]);
        if (ReadInt(o, "version") != Version)
            return new(StoredSettings.Empty, ["設定檔版本不支援，已改用空白設定，請重新填寫或匯入"]);

        var gateways = ReadStringList(o, "gateways");
        while (gateways.Count < 3) gateways.Add("");
        var s = new StoredSettings(
            ReadString(o, "username"),
            UnprotectText(ReadString(o, "passwordProtected"), unprotect, "密碼", warnings),
            UnprotectText(ReadString(o, "pskProtected"), unprotect, "預設共享金鑰（PSK）", warnings),
            gateways,
            ReadStringList(o, "remoteSubnets"),
            ReadString(o, "domain"),
            ReadString(o, "dnsServer"),
            ReadBool(o, "autoReconnect"));
        return new(s, warnings);
    }

    private static string ProtectText(string plain, Func<byte[], byte[]> protect) =>
        string.IsNullOrEmpty(plain) ? "" : Convert.ToBase64String(protect(Encoding.UTF8.GetBytes(plain)));

    private static string UnprotectText(string b64, Func<byte[], byte[]> unprotect, string name, List<string> warnings)
    {
        if (b64.Length == 0) return "";
        try
        {
            return Encoding.UTF8.GetString(unprotect(Convert.FromBase64String(b64)));
        }
        catch (Exception ex) when (ex is FormatException or System.Security.Cryptography.CryptographicException
                                       or InvalidOperationException or ArgumentException)
        {
            // 例外訊息不帶出去：只說哪一欄解不開
            warnings.Add($"已存的{name}無法解開（可能換了 Windows 帳號或電腦），請重新輸入");
            return "";
        }
    }

    private static string ReadString(JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    private static int ReadInt(JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<int>(out var i) ? i : -1;

    private static bool ReadBool(JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    private static List<string> ReadStringList(JsonObject o, string key)
    {
        var list = new List<string>();
        if (o[key] is not JsonArray a) return list;
        foreach (var e in a)
            if (e is JsonValue v && v.TryGetValue<string>(out var s)) list.Add(s);
        return list;
    }
}
