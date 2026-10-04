using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SplitSwan.Core;

/// <summary>從 .splitswan 解出的公司設定（不含個人帳密）。</summary>
/// <param name="Gateways">閘道（已去空白、去空項，1..3 台）</param>
/// <param name="RemoteSubnets">通道網段（每筆 a.b.c.d/n）</param>
/// <param name="Psk">預設共享金鑰；檔案沒有附 PSK 時為空字串</param>
public sealed record ImportedProfile(IReadOnlyList<string> Gateways, IReadOnlyList<string> RemoteSubnets, string Psk);

/// <summary>匯入 .splitswan 失敗（密碼錯、格式錯、超過上限、內容不合規則）；訊息為繁中，可直接顯示。</summary>
public sealed class SplitswanImportException : Exception
{
    public SplitswanImportException(string message) : base(message) { }
}

/// <summary>
/// 解開 Mac 版 ConfigExport 產生的 .splitswan（Sources/ConfigExport.swift）。
/// 格式（JSON）：{ format, version, kdf, iterations, salt(base64), sealed(base64：nonce 12＋密文＋tag 16) }
/// 金鑰：PBKDF2-HMAC-SHA256(NFC 正規化後的密碼 UTF-8, salt, iterations) → 32 bytes；AES-256-GCM，
/// AAD = "format|version|kdf|iterations|salt"（檔頭被改就解不開）。
/// 解開後再依 Mac 版匯入流程（MainView.swift:324-331 → CompanyPresetStore.strictPreset）整份嚴格驗證：
/// 來源不可信，任何一項不合格就整份拒絕。
/// </summary>
public static class SplitswanImporter
{
    private const string Format = "splitswan-config";
    private const int Version = 1;
    private const string Kdf = "PBKDF2-HMAC-SHA256";
    internal const int MaxFileBytes = 1_000_000;

    internal const string NotEncryptedFile = "這不是 SplitSwan 的加密設定檔";
    internal const string WrongPassphraseOrTampered = "密碼錯誤，或檔案已損毀／被修改";
    internal static string UnsupportedVersion(long v) => $"設定檔版本 {v} 不支援，請更新 App";

    private static readonly Regex StrictGatewayRe = new(@"^[A-Za-z0-9.-]{1,253}\z", RegexOptions.CultureInvariant);

    public static ImportedProfile Decrypt(byte[] fileBytes, string passphrase)
    {
        ArgumentNullException.ThrowIfNull(fileBytes);
        ArgumentNullException.ThrowIfNull(passphrase);
        var payload = Open(fileBytes, passphrase);
        return Strict(payload);
    }

    private sealed record Payload(string Name, List<string> Gateways, string RemoteTS, string? Psk);

    // MARK: 解密（ConfigExport.decrypt，Sources/ConfigExport.swift:67-87）

    private static Payload Open(byte[] data, string passphrase)
    {
        if (data.Length > MaxFileBytes) throw new SplitswanImportException(NotEncryptedFile);

        string format, kdf, saltText, sealedText;
        long version;
        uint iterations;
        try
        {
            using var doc = ParseJson(data);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new SplitswanImportException(NotEncryptedFile);
            // Swift 先把六個欄位整份解碼（缺欄位或型別不對都算「不是加密設定檔」），再比對 format 與 version
            format = RequireString(root, "format");
            version = RequireInt(root, "version");
            kdf = RequireString(root, "kdf");
            iterations = RequireUInt32(root, "iterations");
            saltText = RequireString(root, "salt");
            sealedText = RequireString(root, "sealed");
        }
        catch (JsonException) { throw new SplitswanImportException(NotEncryptedFile); }

        if (format != Format) throw new SplitswanImportException(NotEncryptedFile);
        if (version != Version) throw new SplitswanImportException(UnsupportedVersion(version));
        // 限制 KDF 次數範圍，避免被惡意檔案拖慢（次數過大）或降級（次數過小）
        var salt = StrictBase64(saltText);
        var sealedBytes = StrictBase64(sealedText);
        if (kdf != Kdf || iterations < 100_000 || iterations > 2_000_000
            || salt is null || salt.Length < 16 || salt.Length > 64
            || sealedBytes is null || sealedBytes.Length < 28 || sealedBytes.Length > 64_000)
            throw new SplitswanImportException(NotEncryptedFile);

        // 統一成 NFC：同一個字在不同輸入法可能是組合字或預組字，不正規化會解不開
        var pw = Encoding.UTF8.GetBytes(passphrase.Normalize(NormalizationForm.FormC));
        var key = Rfc2898DeriveBytes.Pbkdf2(pw, salt, (int)iterations, HashAlgorithmName.SHA256, 32);
        var aad = Encoding.UTF8.GetBytes($"{format}|{version}|{kdf}|{iterations}|{saltText}");

        byte[] plain;
        try
        {
            var nonce = sealedBytes.AsSpan(0, 12);
            var tag = sealedBytes.AsSpan(sealedBytes.Length - 16, 16);
            var cipher = sealedBytes.AsSpan(12, sealedBytes.Length - 28);
            plain = new byte[cipher.Length];
            using var gcm = new AesGcm(key, 16);
            gcm.Decrypt(nonce, cipher, tag, plain, aad);
        }
        catch (CryptographicException) { throw new SplitswanImportException(WrongPassphraseOrTampered); }

        // 解得開但內容不是預期的 JSON：Mac 版同樣歸類為「密碼錯誤或檔案損毀」
        try
        {
            using var doc = ParseJson(plain);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new SplitswanImportException(WrongPassphraseOrTampered);
            var name = RequireString(root, "name");
            if (!TryGetFirst(root, "gateways", out var g) || g.ValueKind != JsonValueKind.Array)
                throw new SplitswanImportException(WrongPassphraseOrTampered);
            var gws = new List<string>();
            foreach (var e in g.EnumerateArray())
            {
                if (e.ValueKind != JsonValueKind.String) throw new SplitswanImportException(WrongPassphraseOrTampered);
                gws.Add(e.GetString()!);
            }
            var ts = RequireString(root, "remoteTS");
            string? psk = null;
            if (TryGetFirst(root, "psk", out var p) && p.ValueKind != JsonValueKind.Null)
            {
                if (p.ValueKind != JsonValueKind.String) throw new SplitswanImportException(WrongPassphraseOrTampered);
                psk = p.GetString();
            }
            return new Payload(name, gws, ts, psk);
        }
        catch (JsonException) { throw new SplitswanImportException(WrongPassphraseOrTampered); }
        catch (SplitswanImportException) { throw new SplitswanImportException(WrongPassphraseOrTampered); }
    }

    // MARK: 匯入的嚴格驗證（CompanyPresetStore.strictPreset，Sources/CompanyPreset.swift:76-100；PSK 換行，MainView.swift:329-331）

    private static ImportedProfile Strict(Payload p)
    {
        var gatewaysCSV = string.Join(",", p.Gateways);
        if (TextRules.ContainsControlExceptNewline(p.Name + gatewaysCSV + p.RemoteTS))
            throw new SplitswanImportException("設定檔含有不允許的控制字元");

        var gws = gatewaysCSV.Split(',').Select(TextRules.TrimWhitespace).Where(x => x.Length > 0).ToList();
        if (gws.Count == 0) throw new SplitswanImportException("設定檔裡沒有閘道");
        if (gws.Count > 3) throw new SplitswanImportException($"閘道最多 3 台，設定檔裡有 {gws.Count} 台");
        foreach (var g in gws)
            if (!StrictGatewayRe.IsMatch(g))
                throw new SplitswanImportException($"閘道格式不正確：{Prefix(g, 40)}");

        var nets = p.RemoteTS.Split([',', '\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'])
            .Select(TextRules.TrimWhitespace).Where(x => x.Length > 0).ToList();
        if (nets.Count == 0) throw new SplitswanImportException("設定檔裡沒有通道網段");
        // 逐筆檢查 CIDR，並拒絕 /0（Mac 版用 probe 帳號跑 ConfigStore.validate）
        var errors = SettingsValidator.ValidateConnection("probe", gws, nets);
        if (errors.Count > 0) throw new SplitswanImportException(errors[0]);

        var psk = p.Psk ?? "";
        if (TextRules.ContainsAnyNewline(psk)) throw new SplitswanImportException("設定檔裡的 PSK 含有換行，已拒絕");
        return new ImportedProfile(gws, nets, psk);
    }

    // MARK: 小工具

    /// <summary>取前 n 個「字元」（Swift 的 Character 是字素叢集），避免切在 surrogate 中間。</summary>
    private static string Prefix(string s, int n)
    {
        var si = new System.Globalization.StringInfo(s);
        return si.LengthInTextElements <= n ? s : si.SubstringByTextElements(0, n);
    }

    /// <summary>
    /// 解析 JSON，行為對齊 Swift JSONDecoder：開頭的 UTF-8 BOM（EF BB BF）略過不算錯
    /// （Windows 記事本另存常會加上；Mac 版照常解得開）。
    /// </summary>
    private static JsonDocument ParseJson(ReadOnlyMemory<byte> data)
    {
        ReadOnlySpan<byte> bom = [0xEF, 0xBB, 0xBF];
        if (data.Span.StartsWith(bom)) data = data[bom.Length..];
        return JsonDocument.Parse(data);
    }

    /// <summary>
    /// 取物件的欄位；同一個 key 出現多次時取**第一個**，與 Swift JSONDecoder 相同
    /// （JsonElement.TryGetProperty 取的是最後一個）。檔頭的 AAD 用的是這裡取到的值，兩版判定才會一致。
    /// </summary>
    private static bool TryGetFirst(JsonElement o, string name, out JsonElement value)
    {
        foreach (var prop in o.EnumerateObject())
        {
            if (prop.NameEquals(name)) { value = prop.Value; return true; }
        }
        value = default;
        return false;
    }

    private static string RequireString(JsonElement o, string name) =>
        TryGetFirst(o, name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString()!
            : throw new SplitswanImportException(NotEncryptedFile);

    private static long RequireInt(JsonElement o, string name) =>
        TryGetFirst(o, name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var x)
            ? x
            : throw new SplitswanImportException(NotEncryptedFile);

    private static uint RequireUInt32(JsonElement o, string name) =>
        TryGetFirst(o, name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetUInt32(out var x)
            ? x
            : throw new SplitswanImportException(NotEncryptedFile);

    /// <summary>嚴格 base64（同 Swift Data(base64Encoded:) 預設：不接受空白與換行）。</summary>
    private static byte[]? StrictBase64(string s)
    {
        if (s.Any(char.IsWhiteSpace)) return null;
        var buf = new byte[s.Length];
        return Convert.TryFromBase64String(s, buf, out var n) ? buf[..n] : null;
    }
}
