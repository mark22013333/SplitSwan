namespace SplitSwan.Core;

/// <summary>
/// 解析連線引擎（tools/windows/splitswan-wsl.ps1）的機器可讀輸出（契約 1）：
/// 每行 @@KEY=VALUE，例如 @@STATE=up、@@GATEWAY=vpn2、@@VIP=…、@@RESULT=ok／fail:&lt;原因&gt;。
/// </summary>
public static class EngineOutput
{
    private const string Prefix = "@@";

    /// <summary>解析 @@KEY=VALUE 行；同 key 取最後一次；非 @@ 行、沒有 '=' 或 key 空白的行忽略。</summary>
    public static IReadOnlyDictionary<string, string> Parse(IEnumerable<string> lines)
    {
        ArgumentNullException.ThrowIfNull(lines);
        var kv = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var raw in lines)
        {
            if (raw is null) continue;
            // PowerShell 經由 WSL 轉出的行可能帶 CR，行尾空白一併去掉；行首不去，避免把一般輸出誤當成標記
            var line = raw.TrimEnd('\r', '\n', ' ', '\t');
            if (!line.StartsWith(Prefix, StringComparison.Ordinal)) continue;
            var eq = line.IndexOf('=', Prefix.Length);
            if (eq < 0) continue;
            var key = line[Prefix.Length..eq];
            if (key.Length == 0) continue;
            kv[key] = line[(eq + 1)..];
        }
        return kv;
    }

    /// <summary>
    /// 從 @@RESULT 取結果：ok → (true, null)；fail:&lt;msg&gt; → (false, msg)；
    /// 沒有 @@RESULT → (false, "引擎沒有回傳結果")。
    /// </summary>
    public static (bool Ok, string? Error) Result(IReadOnlyDictionary<string, string> kv)
    {
        ArgumentNullException.ThrowIfNull(kv);
        if (!kv.TryGetValue("RESULT", out var r)) return (false, "引擎沒有回傳結果");
        if (r == "ok") return (true, null);
        if (r.StartsWith("fail:", StringComparison.Ordinal))
        {
            var msg = r["fail:".Length..].Trim();
            return (false, msg.Length > 0 ? msg : "引擎回報失敗，但沒有附上原因");
        }
        return (false, $"引擎回傳無法辨識的結果：{r}");
    }
}
