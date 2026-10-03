using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SplitSwan.Core.Tests;

/// <summary>讀取 Fixtures/ 目錄（由 Mac 版 Swift 原始碼實際產生，見 Fixtures/README.md）。</summary>
internal static class Fixture
{
    public static string Path(string name) => System.IO.Path.Combine(AppContext.BaseDirectory, "Fixtures", name);
    public static byte[] Bytes(string name) => File.ReadAllBytes(Path(name));
    public static string Text(string name) => File.ReadAllText(Path(name), new UTF8Encoding(false));
    public static JsonArray Json(string name) => JsonNode.Parse(Text(name))!.AsArray();

    /// <summary>改 .splitswan 檔頭的某個欄位後重新序列化（模擬竄改）。</summary>
    public static byte[] Mutate(byte[] file, Action<JsonObject> change)
    {
        var o = JsonNode.Parse(file)!.AsObject();
        change(o);
        return Encoding.UTF8.GetBytes(o.ToJsonString());
    }
}

/// <summary>
/// 測試專用：依 Mac 版 ConfigExport.encrypt 的格式產生 .splitswan，用來造「Mac 版正常匯出不會產生、
/// 但惡意檔案可能長這樣」的案例（控制字元、/0、PSK 換行…）。
/// 與 Swift 的相容性由 Fixtures/*.splitswan（Swift 實際產生）證明，不靠這支。
/// </summary>
internal static class TestEncryptor
{
    public static byte[] Encrypt(object payload, string passphrase, int iterations = 100_000) =>
        EncryptRaw(JsonSerializer.SerializeToUtf8Bytes(payload), passphrase, iterations);

    /// <summary>直接加密指定的明文 bytes（用來造重複 key、BOM 這類序列化器不會產生的內容）。</summary>
    public static byte[] EncryptRaw(byte[] plain, string passphrase, int iterations = 100_000)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var saltText = Convert.ToBase64String(salt);
        var key = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(passphrase.Normalize(NormalizationForm.FormC)),
            salt, iterations, HashAlgorithmName.SHA256, 32);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        var aad = Encoding.UTF8.GetBytes($"splitswan-config|1|PBKDF2-HMAC-SHA256|{iterations}|{saltText}");
        using (var gcm = new AesGcm(key, 16)) gcm.Encrypt(nonce, plain, cipher, tag, aad);
        var env = new JsonObject
        {
            ["format"] = "splitswan-config",
            ["version"] = 1,
            ["kdf"] = "PBKDF2-HMAC-SHA256",
            ["iterations"] = iterations,
            ["salt"] = saltText,
            ["sealed"] = Convert.ToBase64String([.. nonce, .. cipher, .. tag]),
        };
        return Encoding.UTF8.GetBytes(env.ToJsonString());
    }
}
