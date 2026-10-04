using System.Globalization;
using System.Text.RegularExpressions;

namespace SplitSwan.Core;

/// <summary>SHA256SUMS 列出的一個 Ubuntu WSL 映像（.wsl＝gzip 壓縮的 rootfs tar，可直接給 wsl --import）。</summary>
public sealed record UbuntuWslImage(string FileName, string Version, string Sha256)
{
    /// <summary>下載網址（一律 HTTPS、固定目錄）。</summary>
    public Uri Url => new(UbuntuWslImages.BaseUrl + FileName);
}

/// <summary>
/// 首次設定精靈步驟 3 的下載規則（契約 6）：從 https://releases.ubuntu.com/24.04/SHA256SUMS
/// 挑出版本最大的 ubuntu-24.04.N-wsl-amd64.wsl，下載完比對 SHA256。純字串處理，不碰網路。
/// </summary>
public static partial class UbuntuWslImages
{
    public const string BaseUrl = "https://releases.ubuntu.com/24.04/";
    public static Uri SumsUrl { get; } = new(BaseUrl + "SHA256SUMS");

    /// <summary>SHA256SUMS 正常只有數 KB；超過這個大小就不是預期的檔案。</summary>
    public const int MaxSumsBytes = 64 * 1024;

    /// <summary>
    /// 匯入需要的空間：下載檔本身，加上展開成 ext4.vhdx 後約 2 GB（Ubuntu 24.04 rootfs 約 1.5 GB，留餘裕），
    /// 再加上之後 apt 安裝 strongSwan 的空間。
    /// </summary>
    public static long RequiredFreeBytes(long imageBytes) => Math.Max(0, imageBytes) + 3L * 1024 * 1024 * 1024;

    // 每行：<64 個十六進位> 空白 [*]<檔名>（* 表示 binary mode，同 sha256sum 輸出）
    // 數字一律用 [0-9]（不用 \d，免得全形數字通過）；檔名只接受 amd64 的 24.04.x WSL 映像
    [GeneratedRegex(@"^([0-9A-Fa-f]{64})[ \t]+\*?(ubuntu-24\.04\.([0-9]{1,6}(?:\.[0-9]{1,6})*)-wsl-amd64\.wsl)[ \t]*$")]
    private static partial Regex LineRegex();

    /// <summary>
    /// 解析 SHA256SUMS，回傳所有 24.04.x 的 amd64 WSL 映像，版本由大到小。
    /// 同一個檔名出現兩次且雜湊不同 → 該檔不可信，整個略過；格式不符的行忽略。雜湊一律轉小寫。
    /// </summary>
    public static IReadOnlyList<UbuntuWslImage> Parse(string? sums)
    {
        var byName = new Dictionary<string, UbuntuWslImage>(StringComparer.Ordinal);
        var conflicted = new HashSet<string>(StringComparer.Ordinal);
        foreach (var raw in (sums ?? "").Split('\n'))
        {
            var m = LineRegex().Match(raw.TrimEnd('\r'));
            if (!m.Success) continue;
            var img = new UbuntuWslImage(m.Groups[2].Value, "24.04." + m.Groups[3].Value, m.Groups[1].Value.ToLowerInvariant());
            if (byName.TryGetValue(img.FileName, out var prev) && prev.Sha256 != img.Sha256) conflicted.Add(img.FileName);
            byName[img.FileName] = img;
        }
        return [.. byName.Values.Where(i => !conflicted.Contains(i.FileName))
            .OrderByDescending(i => i.Version, Comparer<string>.Create(CompareVersions))];
    }

    /// <summary>版本最大的映像；沒有任何符合的行時為 null。</summary>
    public static UbuntuWslImage? Latest(string? sums) => Parse(sums).FirstOrDefault();

    /// <summary>點分隔的版本號逐段數字比較（"24.04.10" &gt; "24.04.9"；"24.04.5.1" &gt; "24.04.5"）。</summary>
    public static int CompareVersions(string a, string b)
    {
        var x = a.Split('.');
        var y = b.Split('.');
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            long xi = i < x.Length && long.TryParse(x[i], NumberStyles.None, CultureInfo.InvariantCulture, out var p) ? p : -1;
            long yi = i < y.Length && long.TryParse(y[i], NumberStyles.None, CultureInfo.InvariantCulture, out var q) ? q : -1;
            if (xi != yi) return xi.CompareTo(yi);
        }
        return 0;
    }

    /// <summary>下載完的雜湊（任意大小寫十六進位）是否等於 SHA256SUMS 的值。</summary>
    public static bool HashMatches(string expectedHex, byte[] actualHash)
    {
        ArgumentNullException.ThrowIfNull(actualHash);
        return actualHash.Length == 32
               && string.Equals(expectedHex, Convert.ToHexString(actualHash), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>進度顯示：「123.4 MB / 371.0 MB（33%）」；總長不明時只顯示已下載量。</summary>
    public static string FormatProgress(long done, long? total)
    {
        static string Mb(long b) => (b / 1024.0 / 1024.0).ToString("0.0", CultureInfo.InvariantCulture) + " MB";
        if (total is not { } t || t <= 0) return Mb(done);
        var pct = (int)Math.Clamp(done * 100 / t, 0, 100);
        return $"{Mb(done)} / {Mb(t)}（{pct}%）";
    }
}
