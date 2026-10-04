using System.Globalization;

namespace SplitSwan.Core;

/// <summary>
/// 解析連線引擎 connect 逐台回報的 @@ATTEMPT 行（契約 3）：
/// <c>@@ATTEMPT=&lt;n&gt;|&lt;ok|fail&gt;|&lt;秒數，一位小數&gt;|&lt;摘要&gt;</c>。
/// 同一個 key 會出現多次（每台一行），所以不能用 <see cref="EngineOutput.Parse"/> 的「取最後一次」，要逐行讀。
/// </summary>
public static class EngineAttempts
{
    /// <summary>一台閘道的嘗試結果。</summary>
    /// <param name="Gateway">閘道編號，1 起算。</param>
    /// <param name="Success">ok＝true、fail＝false。</param>
    /// <param name="Seconds">耗時（秒）。</param>
    /// <param name="Summary">失敗摘要；成功時為空字串。</param>
    public sealed record Attempt(int Gateway, bool Success, double Seconds, string Summary);

    private const string Prefix = "@@ATTEMPT=";

    /// <summary>
    /// 依出現順序回傳所有格式正確的 @@ATTEMPT 行；格式錯的行（欄位不足、編號不是正整數、結果不是 ok／fail、
    /// 秒數不是非負有限數）一律忽略。秒數用 InvariantCulture 解析（小數點固定是「.」）。
    /// 摘要是第 4 欄之後的全部內容（引擎已去掉「|」，萬一還有也原樣保留）。
    /// </summary>
    public static IReadOnlyList<Attempt> Parse(IEnumerable<string> lines)
    {
        ArgumentNullException.ThrowIfNull(lines);
        var list = new List<Attempt>();
        foreach (var raw in lines)
        {
            if (raw is null) continue;
            // 同 EngineOutput：經 WSL 轉出的行可能帶 CR，行尾空白去掉；行首不去
            var line = raw.TrimEnd('\r', '\n', ' ', '\t');
            if (!line.StartsWith(Prefix, StringComparison.Ordinal)) continue;
            var parts = line[Prefix.Length..].Split('|', 4);
            if (parts.Length != 4) continue;

            if (!IsAsciiDigits(parts[0])) continue;
            if (!int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var n) || n < 1) continue;

            bool ok;
            if (parts[1] == "ok") ok = true;
            else if (parts[1] == "fail") ok = false;
            else continue;

            if (!double.TryParse(parts[2], NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var secs)
                || !double.IsFinite(secs) || secs < 0) continue;

            list.Add(new Attempt(n, ok, secs, parts[3]));
        }
        return list;
    }

    private static bool IsAsciiDigits(string s)
    {
        if (s.Length == 0) return false;
        foreach (var c in s) if (c < '0' || c > '9') return false;
        return true;
    }
}
