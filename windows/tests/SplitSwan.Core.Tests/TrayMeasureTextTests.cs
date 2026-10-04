using System.Text;
using System.Text.RegularExpressions;

namespace SplitSwan.Core.Tests;

/// <summary>
/// 回歸：托盤 App 的文字量測不可帶省略號旗標。
/// WinForms 的 TextExtensions.MeasureText 會把小於 1px 的寬度（含 Size.Empty）改成約 1px，再以 DT_CALCRECT 呼叫 DrawTextEx；
/// 旗標含 DT_END_ELLIPSIS 時量到的是「截斷後」的寬度，真機上 chips、開關標籤、按鈕全部只剩「10....」「顯...」。
/// 這裡直接掃描 windows/src/SplitSwan.Tray 的原始碼（Core 測試專案無法參考 WinForms 專案）。
/// </summary>
public class TrayMeasureTextTests
{
    [Fact]
    public void TrayMeasureText_NeverUsesDrawFlagsOrEllipsis()
    {
        var root = FindTrayDir();
        var files = Directory.EnumerateFiles(root, "*.cs", SearchOption.AllDirectories)
            .Where(f => !IsBuildOutput(root, f))
            .ToList();
        Assert.True(files.Count >= 10, $"只找到 {files.Count} 個 .cs，掃描範圍不對：{root}");

        var calls = 0;
        var bad = new List<string>();
        foreach (var f in files)
        {
            var text = File.ReadAllText(f);
            calls += FindMeasureTextCalls(text).Count;
            bad.AddRange(FindViolations(text).Select(v => $"{Path.GetFileName(f)}: {v}"));
        }

        // 正對照：掃描範圍內確實有 MeasureText 呼叫（至少 Theme.Measure 那一處），避免「掃不到所以沒違規」
        Assert.True(calls >= 1, "托盤原始碼裡找不到任何 MeasureText 呼叫，偵測器或掃描範圍失效");
        Assert.True(bad.Count == 0, "MeasureText 不可傳入 Theme.TextFlags 或含 Ellipsis 的旗標（改用 Theme.Measure）：\n" + string.Join("\n", bad));
    }

    [Fact]
    public void Theme_MeasureFlags_HasNoEllipsisOrWordBreak()
    {
        var theme = File.ReadAllText(Path.Combine(FindTrayDir(), "Controls", "Theme.cs"));
        var m = Regex.Match(StripCommentsAndStrings(theme), @"\bMeasureFlags\s*=\s*([^;]*);");
        Assert.True(m.Success, "Theme.cs 找不到 MeasureFlags 的定義");
        var def = m.Groups[1].Value;
        Assert.Contains("SingleLine", def);
        Assert.DoesNotContain("Ellipsis", def);
        Assert.DoesNotContain("WordBreak", def);
        Assert.DoesNotMatch(@"\bTextFlags\b", def);
    }

    [Fact]
    public void Detector_CatchesViolations_PositiveControl()
    {
        const string sample = """
            var a = TextRenderer.MeasureText(Text, Font, Size.Empty, Theme.TextFlags);
            var b = TextRenderer.MeasureText(
                OneLine(e.Text), Font, new Size(10, 10),
                TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis);
            var c = TextRenderer.MeasureText(g, s, f, Size.Empty, TextFormatFlags.WordEllipsis);
            var d = TextRenderer.MeasureText(s, f, sz, flags | TextFormatFlags.PathEllipsis);
            """;
        var v = FindViolations(sample);
        Assert.Equal(4, v.Count);
        Assert.Equal(4, FindMeasureTextCalls(sample).Count);
    }

    [Fact]
    public void Detector_IgnoresAllowedCalls_CommentsAndStrings()
    {
        const string sample = """
            // 舊寫法 TextRenderer.MeasureText(Text, Font, Size.Empty, Theme.TextFlags) 會截斷
            /* TextRenderer.MeasureText(x, f, Size.Empty, TextFormatFlags.EndEllipsis) */
            var msg = "MeasureText(x, Theme.TextFlags)";
            var ok1 = TextRenderer.MeasureText(text, font, Unbounded, MeasureFlags);
            var ok2 = TextRenderer.MeasureText("…", font);
            var ok3 = Theme.Measure(Text, Font);
            TextRenderer.DrawText(g, Text, Font, r, ink, Theme.TextFlags | TextFormatFlags.EndEllipsis);
            """;
        Assert.Empty(FindViolations(sample));
        Assert.Equal(2, FindMeasureTextCalls(sample).Count);
    }

    [Fact]
    public void TrayMenu_DoesNotReadBackToolStripItemVisible()
    {
        // ToolStripItem.Visible 的 getter 是「父層可見 && Available」：選單沒開時一律 false。
        // 之前 Redraw 寫 item.Visible = …; if (!item.Visible) continue; → 「連線 VPN1–3」的文字從沒設上，選單只剩三列空白。
        var code = StripCommentsAndStrings(File.ReadAllText(Path.Combine(FindTrayDir(), "TrayContext.cs")));
        Assert.Contains("_connectGw", code);   // 正對照：讀到的是對的檔案
        Assert.DoesNotMatch(@"!\s*item\.Visible\b", code);
        Assert.DoesNotMatch(@"if\s*\(\s*!?\s*_connectGw\[[^\]]+\]\.Visible\b", code);
    }

    // ── 偵測器 ─────────────────────────────────────────

    /// <summary>每個 MeasureText(...) 呼叫的引數文字（已去掉註解與字串內容）。</summary>
    private static List<string> FindMeasureTextCalls(string source)
    {
        var code = StripCommentsAndStrings(source);
        var result = new List<string>();
        foreach (Match m in Regex.Matches(code, @"\bMeasureText\s*\("))
        {
            var start = m.Index + m.Length;
            var depth = 1;
            var i = start;
            for (; i < code.Length && depth > 0; i++)
            {
                if (code[i] == '(') depth++;
                else if (code[i] == ')') depth--;
            }
            result.Add(code[start..Math.Max(start, i - 1)]);
        }
        return result;
    }

    private static List<string> FindViolations(string source) =>
        [.. FindMeasureTextCalls(source)
            .Where(args => Regex.IsMatch(args, @"\bTextFlags\b") || args.Contains("Ellipsis", StringComparison.Ordinal))
            .Select(args => "MeasureText(" + Regex.Replace(args, @"\s+", " ").Trim() + ")")];

    /// <summary>把註解換成空白、字串／字元常值的內容清空（保留引號），避免註解或訊息文字被當成呼叫。</summary>
    private static string StripCommentsAndStrings(string s)
    {
        var sb = new StringBuilder(s.Length);
        var i = 0;
        while (i < s.Length)
        {
            var c = s[i];
            var next = i + 1 < s.Length ? s[i + 1] : '\0';
            if (c == '/' && next == '/')
            {
                while (i < s.Length && s[i] != '\n') i++;
                sb.Append(' ');
            }
            else if (c == '/' && next == '*')
            {
                var end = s.IndexOf("*/", i + 2, StringComparison.Ordinal);
                i = end < 0 ? s.Length : end + 2;
                sb.Append(' ');
            }
            else if (c == '"' || (c == '@' && next == '"') || (c == '$' && next == '"') || (c == '$' && next == '@') || (c == '@' && next == '$'))
            {
                var verbatim = false;
                while (s[i] != '"') { verbatim |= s[i] == '@'; i++; }
                i++;
                sb.Append("\"\"");
                while (i < s.Length)
                {
                    if (verbatim && s[i] == '"' && i + 1 < s.Length && s[i + 1] == '"') { i += 2; continue; }
                    if (!verbatim && s[i] == '\\') { i += 2; continue; }
                    if (s[i] == '"' || (!verbatim && s[i] == '\n')) { i++; break; }
                    i++;
                }
            }
            else if (c == '\'')
            {
                i++;
                while (i < s.Length && s[i] != '\'' && s[i] != '\n') i += s[i] == '\\' ? 2 : 1;
                i++;
                sb.Append("' '");
            }
            else
            {
                sb.Append(c);
                i++;
            }
        }
        return sb.ToString();
    }

    private static bool IsBuildOutput(string root, string file)
    {
        var rel = Path.GetRelativePath(root, file).Replace('\\', '/');
        return rel.StartsWith("bin/", StringComparison.Ordinal) || rel.StartsWith("obj/", StringComparison.Ordinal);
    }

    private static string FindTrayDir()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var p = Path.Combine(dir.FullName, "src", "SplitSwan.Tray");
            if (File.Exists(Path.Combine(p, "Controls", "Theme.cs"))) return p;
            p = Path.Combine(dir.FullName, "windows", "src", "SplitSwan.Tray");
            if (File.Exists(Path.Combine(p, "Controls", "Theme.cs"))) return p;
            dir = dir.Parent;
        }
        Assert.Fail("找不到 windows/src/SplitSwan.Tray：測試要在 repo 內執行（不可用 --artifacts-path 把輸出移出 repo）");
        return "";
    }
}
