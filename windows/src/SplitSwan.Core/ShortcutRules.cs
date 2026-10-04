namespace SplitSwan.Core;

/// <summary>捷徑放在哪裡（目前使用者的桌面、開始選單程式集）。</summary>
public enum ShortcutLocation { Desktop, StartMenu }

/// <summary>同名捷徑（SplitSwan.lnk）的狀態，以檔案系統為準，不存進 settings.json。</summary>
public enum ShortcutState
{
    /// <summary>沒有這個檔案。</summary>
    Missing,
    /// <summary>指向目前執行中的這支 exe。</summary>
    Ours,
    /// <summary>有我們的標記、但指向別處的 SplitSwan.exe（例如解壓縮到新資料夾後，舊捷徑還指向舊位置）。</summary>
    Stale,
    /// <summary>
    /// 同名但不是我們建立的：沒有標記（描述不是 "SplitSwan VPN"，含讀不出描述）、讀不出目標、
    /// 或目標既不是目前的 exe 也不是 SplitSwan.exe。一律不刪、不覆寫——即使它指向本程式（使用者自己做的捷徑）。
    /// </summary>
    Foreign,
}

/// <summary>使用者切換開關時要做的事。</summary>
public enum ShortcutAction
{
    /// <summary>不用做任何事（已經是想要的狀態）。</summary>
    None,
    /// <summary>建立新捷徑。</summary>
    Create,
    /// <summary>改寫成指向目前的 exe（舊位置 → 新位置）。</summary>
    Update,
    /// <summary>刪除捷徑檔。</summary>
    Remove,
    /// <summary>拒絕：同名檔案不是我們的，不建立也不刪除。</summary>
    Refuse,
}

/// <summary>
/// 桌面／開始選單捷徑的判斷規則（純函式，可在 macOS 測試）。實際讀寫 .lnk 在托盤的 ShellShortcut（COM）。
/// 路徑一律以 Windows 規則比較：不分大小寫、/ 與 \ 視為相同、去掉重複的分隔符號、. 與 ..、結尾的 \、
/// 以及 \\?\ 長路徑前綴；不呼叫 Path.GetFullPath（在 macOS 上 \ 不是分隔符號，測試會不準）。
/// </summary>
public static class ShortcutRules
{
    /// <summary>捷徑檔名（桌面與開始選單相同）。</summary>
    public const string FileName = "SplitSwan.lnk";

    /// <summary>發佈的 exe 檔名（csproj 的 AssemblyName＝SplitSwan）。</summary>
    public const string ExeName = "SplitSwan.exe";

    /// <summary>
    /// 捷徑的「描述」欄位（檔案總管的提示文字），同時是「這是 SplitSwan 建立的捷徑」的標記：
    /// 判斷歸屬時要求逐字相同（區分大小寫、不去空白）。
    /// </summary>
    public const string Description = "SplitSwan VPN";

    /// <summary>
    /// 判斷捷徑狀態（Leader 裁決：「我們的捷徑」要同時有標記，且目標是目前的 exe 或 SplitSwan.exe）。
    /// 1. 檔案不存在 → Missing
    /// 2. 描述不等於 <see cref="Description"/>（含讀不出描述）→ Foreign
    /// 3. 讀不出目標 → Foreign
    /// 4. 目標＝目前 exe 的完整路徑（正規化後不分大小寫）→ Ours
    /// 5. 目標檔名是 SplitSwan.exe（不分大小寫）但路徑不同 → Stale
    /// 6. 其他 → Foreign（例如 exe 被改名後，別人同名的捷徑）
    /// </summary>
    /// <param name="exists">捷徑檔是否存在。</param>
    /// <param name="target">從 .lnk 讀回的目標路徑；讀不出來（檔案損壞、不是檔案目標）傳 null 或空字串。</param>
    /// <param name="description">從 .lnk 讀回的描述；讀取失敗傳 null。</param>
    /// <param name="currentExe">目前執行中的 exe 完整路徑（Environment.ProcessPath）。</param>
    public static ShortcutState Classify(bool exists, string? target, string? description, string? currentExe)
    {
        if (!exists) return ShortcutState.Missing;
        if (!IsOurMark(description)) return ShortcutState.Foreign;
        var t = NormalizePath(target);
        if (t.Length == 0) return ShortcutState.Foreign;   // 讀不出目標：不能確定是我們的，就不動它
        if (SamePath(t, currentExe)) return ShortcutState.Ours;
        return string.Equals(FileNameOf(t), ExeName, StringComparison.OrdinalIgnoreCase)
            ? ShortcutState.Stale
            : ShortcutState.Foreign;
    }

    /// <summary>描述是否為我們寫入的標記（逐字相同）。</summary>
    public static bool IsOurMark(string? description) => string.Equals(description, Description, StringComparison.Ordinal);

    /// <summary>
    /// 長路徑的顯示用縮寫：超過 maxChars 時保留開頭（磁碟機或 \server\share）與盡量多的結尾段落，中間以「…」代替；
    /// 連檔名都放不下時只留結尾。完整路徑請放在 tooltip。
    /// </summary>
    public static string CompactPath(string? path, int maxChars)
    {
        var p = NormalizePath(path);
        if (maxChars < 4 || p.Length <= maxChars) return p;
        var unc = p.StartsWith(@"\\", StringComparison.Ordinal);
        var segs = p.TrimStart('\\').Split('\\');
        var headCount = unc ? Math.Min(2, segs.Length) : 1;
        var head = (unc ? @"\\" : "") + string.Join('\\', segs.Take(headCount));
        var tail = "";
        for (int i = segs.Length - 1; i >= headCount; i--)
        {
            var candidate = "\\" + segs[i] + tail;
            if (head.Length + 2 + candidate.Length > maxChars) break;   // 2＝「\…」的 \ 與 …
            tail = candidate;
        }
        if (tail.Length > 0) return head + "\\…" + tail;
        return "…" + p[^(maxChars - 1)..];
    }

    /// <summary>開關要顯示成「開」嗎：指向本程式或舊位置都算有捷徑（舊位置另外提示「更新」）。</summary>
    public static bool IsOn(ShortcutState s) => s is ShortcutState.Ours or ShortcutState.Stale;

    /// <summary>只有指向本程式或舊位置的捷徑可以刪除；「不是我們的」永遠不刪。</summary>
    public static bool CanRemove(ShortcutState s) => s is ShortcutState.Ours or ShortcutState.Stale;

    /// <summary>使用者把開關切到 wantOn 時，依目前（剛重新讀取的）狀態決定動作。</summary>
    public static ShortcutAction OnToggle(ShortcutState current, bool wantOn) => (current, wantOn) switch
    {
        (ShortcutState.Foreign, _) => ShortcutAction.Refuse,
        (ShortcutState.Missing, true) => ShortcutAction.Create,
        (ShortcutState.Stale, true) => ShortcutAction.Update,
        (ShortcutState.Ours, true) => ShortcutAction.None,
        (ShortcutState.Missing, false) => ShortcutAction.None,
        (ShortcutState.Ours or ShortcutState.Stale, false) => ShortcutAction.Remove,
        _ => ShortcutAction.None,
    };

    /// <summary>位置的顯示名稱。</summary>
    public static string Title(ShortcutLocation l) => l switch
    {
        ShortcutLocation.Desktop => "桌面捷徑",
        ShortcutLocation.StartMenu => "開始選單",
        _ => l.ToString(),
    };

    /// <summary>拒絕變更時的提示（規格指定的文字）。</summary>
    public const string RefuseMessage = "已有同名捷徑，未變更";

    /// <summary>精靈「建立」結果的一行文字。</summary>
    public static string ResultLine(ShortcutLocation l, ShortcutAction done, string? error = null)
    {
        var name = l == ShortcutLocation.Desktop ? "桌面捷徑" : "開始選單捷徑";
        if (error is not null) return $"✖ {name}建立失敗：{error}";
        return done switch
        {
            ShortcutAction.Create => $"✔ 已建立{name}",
            ShortcutAction.Update => $"✔ 已把{name}更新為目前的位置",
            ShortcutAction.None => $"✔ {name}已存在",
            ShortcutAction.Refuse => $"⚠ {name}：{RefuseMessage}（同名檔案不是 SplitSwan 建立的）",
            _ => $"✔ {name}",
        };
    }

    /// <summary>Windows 路徑正規化（見類別說明）；null／空白回傳空字串。</summary>
    public static string NormalizePath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return "";
        var p = path.Trim();
        if (p.Length >= 2 && p[0] == '"' && p[^1] == '"') p = p[1..^1].Trim();
        p = p.Replace('/', '\\');
        // \\?\C:\… 與 \\?\UNC\server\share\… 長路徑前綴
        if (p.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) p = @"\\" + p[8..];
        else if (p.StartsWith(@"\\?\", StringComparison.Ordinal)) p = p[4..];
        var unc = p.StartsWith(@"\\", StringComparison.Ordinal);
        var parts = new List<string>();
        foreach (var seg in p.Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            if (seg == ".") continue;
            if (seg == "..")
            {
                // 不能退到磁碟機根目錄（C:）或 UNC 的 server\share 之上
                var floor = unc ? 2 : (parts.Count > 0 && IsDrive(parts[0]) ? 1 : 0);
                if (parts.Count > floor) parts.RemoveAt(parts.Count - 1);
                continue;
            }
            parts.Add(seg.TrimEnd(' ', '.') is { Length: > 0 } s ? s : seg);   // Windows 忽略名稱結尾的空白與句點
        }
        if (parts.Count == 0) return unc ? @"\\" : "";
        var joined = string.Join('\\', parts);
        if (unc) return @"\\" + joined;
        if (parts.Count == 1 && IsDrive(parts[0])) return parts[0].ToUpperInvariant() + "\\";
        return IsDrive(parts[0]) ? char.ToUpperInvariant(joined[0]) + joined[1..] : joined;
    }

    /// <summary>兩個路徑正規化後是否相同（不分大小寫）。</summary>
    public static bool SamePath(string? a, string? b)
    {
        var x = NormalizePath(a);
        return x.Length > 0 && string.Equals(x, NormalizePath(b), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>最後一段（檔名）；以 \ 或 / 分隔。</summary>
    public static string FileNameOf(string? path)
    {
        var p = NormalizePath(path);
        var i = p.LastIndexOf('\\');
        return i < 0 ? p : p[(i + 1)..];
    }

    /// <summary>所在資料夾（給捷徑的工作目錄）；沒有資料夾時回傳空字串。</summary>
    public static string DirectoryOf(string? path)
    {
        var p = NormalizePath(path);
        var i = p.LastIndexOf('\\');
        if (i < 0) return "";
        var dir = p[..i];
        return dir.Length == 2 && dir[1] == ':' ? dir + "\\" : dir;
    }

    private static bool IsDrive(string seg) => seg.Length == 2 && seg[1] == ':' && char.IsAsciiLetter(seg[0]);
}
