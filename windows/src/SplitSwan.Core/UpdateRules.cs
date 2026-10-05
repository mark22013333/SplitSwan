using System.Text.Json;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace SplitSwan.Core;

/// <summary>Windows 版 release 的附檔（zip 與 Ed25519 簽章）。</summary>
public sealed record UpdateAssets(Uri Zip, Uri Sig);

/// <summary>
/// 版本最高的 Windows release。Assets 為 null＝附檔不齊或網址不合規則，不能自動安裝（只能「前往下載」）。
/// </summary>
public sealed record UpdateRelease(string Version, UpdateAssets? Assets)
{
    /// <summary>release 頁面：由驗證過的版本號組出來，不採用 API 回傳的 html_url。</summary>
    public string PageUrl => UpdateRules.ReleasePageUrl(Version);
}

/// <summary>
/// 一鍵更新的純邏輯（對應 Mac 版 UpdateLogic）：解析 GitHub release 列表、驗證 Ed25519 簽章、
/// 版本比較與防降級、每日自動檢查的時機。不連網、不碰檔案系統，方便在 macOS 上測試。
/// </summary>
public static class UpdateRules
{
    public const string Owner = "mark22013333";
    public const string Repo = "SplitSwan";

    /// <summary>
    /// Windows 版一律發成 prerelease，/releases/latest 會排除它，所以查列表再自己挑。
    /// </summary>
    public const string ReleasesApi = $"https://api.github.com/repos/{Owner}/{Repo}/releases?per_page=30";
    public const string ReleasesPage = $"https://github.com/{Owner}/{Repo}/releases";
    public const string DownloadPrefix = $"https://github.com/{Owner}/{Repo}/releases/download/";

    /// <summary>Windows 版的 tag 前綴；Mac 版的 vX.Y.Z 一律忽略。</summary>
    public const string TagPrefix = "windows-v";

    /// <summary>發版簽章的公鑰（與 Mac 版共用同一把；私鑰只在維護者電腦，見 tools/release-sign.swift）。</summary>
    public const string PublicKeyBase64 = "URYq9rg4ntHqiWV0ZhSd6dMm1uLrL5fZ/J76pnX048g=";

    /// <summary>zip 與 .sig 的大小上限，超過視為異常不下載。</summary>
    public const long MaxDownloadBytes = 100_000_000;

    /// <summary>release 列表 JSON 的大小上限。</summary>
    public const long MaxReleaseListBytes = 5_000_000;

    /// <summary>
    /// 一鍵更新啟動新版時帶的參數：新版會等舊版結束、釋放單一執行個體的 mutex 後才繼續，
    /// 並清掉替換時留下的 *.old。
    /// </summary>
    public const string AfterUpdateArgument = "--after-update";

    public static bool IsAfterUpdate(IEnumerable<string>? args) =>
        args?.Any(a => string.Equals(a, AfterUpdateArgument, StringComparison.OrdinalIgnoreCase)) == true;

    /// <summary>每日自動檢查的間隔。</summary>
    public static readonly TimeSpan AutoCheckInterval = TimeSpan.FromHours(24);

    public static string ZipName(string version) => $"SplitSwan-Windows-{version}.zip";

    public static string ReleasePageUrl(string version) => $"{ReleasesPage}/tag/{TagPrefix}{version}";

    // MARK: 版本

    /// <summary>
    /// 解析 X.Y.Z（數字只接受 [0-9]，避免全形數字）。另外接受結尾的「.0」第四段（Windows FileVersion 的格式）
    /// 與「+…」建置資訊（ProductVersion 的格式）。其他一律回 null。
    /// </summary>
    public static int[]? ParseVersion(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var s = text;
        var plus = s.IndexOf('+');
        if (plus >= 0) s = s[..plus];
        var parts = s.Split('.');
        if (parts.Length == 4 && parts[3] == "0") parts = parts[..3];
        if (parts.Length != 3) return null;
        var v = new int[3];
        for (int i = 0; i < 3; i++)
        {
            var p = parts[i];
            if (p.Length == 0 || p.Length > 6 || p.Any(c => c is < '0' or > '9')) return null;
            v[i] = int.Parse(p, System.Globalization.CultureInfo.InvariantCulture);
        }
        return v;
    }

    /// <summary>正規化成 X.Y.Z；無法辨識回 null。</summary>
    public static string? NormalizeVersion(string? text) =>
        ParseVersion(text) is { } v ? string.Join('.', v) : null;

    public static int Compare(int[] a, int[] b)
    {
        for (int i = 0; i < 3; i++)
            if (a[i] != b[i]) return a[i].CompareTo(b[i]);
        return 0;
    }

    /// <summary>tag「windows-vX.Y.Z」的版本；不是 Windows 版的 tag 回 null。</summary>
    public static string? VersionFromTag(string? tag)
    {
        if (tag is null || !tag.StartsWith(TagPrefix, StringComparison.Ordinal)) return null;
        var rest = tag[TagPrefix.Length..];
        // tag 只接受正規的 X.Y.Z（不接受 .0 第四段、+、前置 0），版本號才能原樣組回附檔名與頁面網址
        return NormalizeVersion(rest) == rest ? rest : null;
    }

    /// <summary>release 的版本是否比目前新。任一邊無法辨識都回 false。</summary>
    public static bool IsNewer(string release, string current) =>
        ParseVersion(release) is { } r && ParseVersion(current) is { } c && Compare(r, c) > 0;

    // MARK: release 列表

    /// <summary>
    /// 從 /releases?per_page=30 的 JSON 挑出版本最高的 Windows release（tag 以 windows-v 開頭、非 draft；
    /// prerelease 照收）。找不到任何 Windows release 回 null。
    /// 版本最高的那一筆附檔不齊或網址不合規則時，Assets 為 null（不退而求其次改裝較舊的版本）。
    /// </summary>
    public static UpdateRelease? PickLatest(string json)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(json ?? ""); }
        catch (JsonException) { return null; }
        using (doc)
        {
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return null;
            string? bestVersion = null;
            int[]? best = null;
            JsonElement bestElement = default;
            foreach (var r in doc.RootElement.EnumerateArray())
            {
                if (r.ValueKind != JsonValueKind.Object) continue;
                if (r.TryGetProperty("draft", out var d) && d.ValueKind != JsonValueKind.False) continue;
                if (!r.TryGetProperty("tag_name", out var t) || t.ValueKind != JsonValueKind.String) continue;
                var version = VersionFromTag(t.GetString());
                if (version is null) continue;
                var v = ParseVersion(version)!;
                if (best is null || Compare(v, best) > 0)
                {
                    best = v;
                    bestVersion = version;
                    bestElement = r.Clone();
                }
            }
            if (bestVersion is null) return null;
            return new UpdateRelease(bestVersion, ParseAssets(bestElement, bestVersion));
        }
    }

    /// <summary>找出 SplitSwan-Windows-&lt;版本&gt;.zip 與 .zip.sig；檔名版本必須等於 tag 版本，網址必須在本 repo 的 releases/download 底下。</summary>
    private static UpdateAssets? ParseAssets(JsonElement release, string version)
    {
        if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return null;
        var zipName = ZipName(version);
        Uri? zip = null, sig = null;
        foreach (var a in assets.EnumerateArray())
        {
            if (a.ValueKind != JsonValueKind.Object) continue;
            if (!a.TryGetProperty("name", out var n) || n.ValueKind != JsonValueKind.String) continue;
            var name = n.GetString();
            if (name != zipName && name != zipName + ".sig") continue;
            var url = a.TryGetProperty("browser_download_url", out var u) && u.ValueKind == JsonValueKind.String ? u.GetString() : null;
            var ok = IsAllowedDownloadUrl(url, name!);
            if (!ok) return null;   // 同名附檔的網址不合規則：整筆不採用
            if (name == zipName) zip = new Uri(url!); else sig = new Uri(url!);
        }
        return zip is not null && sig is not null ? new UpdateAssets(zip, sig) : null;
    }

    /// <summary>下載網址必須以本 repo 的 releases/download/ 開頭、不含「..」、且最後一段等於附檔名。</summary>
    public static bool IsAllowedDownloadUrl(string? url, string assetName)
    {
        if (url is null || !url.StartsWith(DownloadPrefix, StringComparison.Ordinal) || url.Contains("..")) return false;
        if (url.Contains('?') || url.Contains('#') || url.Contains('\\')) return false;
        if (!url.EndsWith("/" + assetName, StringComparison.Ordinal)) return false;
        return Uri.TryCreate(url, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps && u.Host == "github.com";
    }

    // MARK: 簽章

    /// <summary>
    /// 驗證 Ed25519 簽章（RFC 8032 純 Ed25519，對 zip 全檔簽）。.sig 內容是一行 base64。
    /// 用 BouncyCastle 的實作（.NET 10 沒有內建獨立的 Ed25519）。任何格式錯誤都回 false。
    /// </summary>
    public static bool VerifySignature(byte[] data, string signatureText, string publicKeyBase64 = PublicKeyBase64)
    {
        ArgumentNullException.ThrowIfNull(data);
        byte[] sig, key;
        try
        {
            sig = Convert.FromBase64String((signatureText ?? "").Trim());
            key = Convert.FromBase64String(publicKeyBase64 ?? "");
        }
        catch (FormatException) { return false; }
        if (sig.Length != 64 || key.Length != 32) return false;
        try
        {
            var signer = new Ed25519Signer();
            signer.Init(false, new Ed25519PublicKeyParameters(key, 0));
            signer.BlockUpdate(data, 0, data.Length);
            return signer.VerifySignature(sig);
        }
        catch (ArgumentException) { return false; }   // 公鑰不是曲線上的點
    }

    // MARK: 安裝前檢查

    /// <summary>
    /// 檢查下載的 exe：FileVersion 與 ProductVersion 都必須等於 release 版本，且比目前新（防止拿舊的已簽版本降級／重放）。
    /// 回傳錯誤訊息，沒問題回 null。
    /// </summary>
    public static string? ValidateExeVersion(string? fileVersion, string? productVersion, string expected, string current)
    {
        var want = ParseVersion(expected);
        var mine = ParseVersion(current);
        if (want is null || mine is null) return "無法辨識版本號";
        var fv = ParseVersion(fileVersion);
        var pv = ParseVersion(productVersion);
        if (fv is null || pv is null) return "無法辨識下載的 SplitSwan.exe 版本";
        if (Compare(fv, want) != 0 || Compare(pv, want) != 0)
            return $"下載的 SplitSwan.exe 版本（{NormalizeVersion(productVersion)}）與發布版本（{expected}）不符";
        if (Compare(want, mine) <= 0) return $"下載的版本（{expected}）沒有比目前（{current}）新";
        return null;
    }

    /// <summary>每日自動檢查：有勾選、且距離上次檢查滿 24 小時（或從沒檢查過、時鐘被往回調）。</summary>
    public static bool ShouldAutoCheck(bool enabled, DateTimeOffset? last, DateTimeOffset now)
    {
        if (!enabled) return false;
        if (last is not { } l) return true;
        var elapsed = now - l;
        return elapsed >= AutoCheckInterval || elapsed < TimeSpan.Zero;
    }
}
