using System.Globalization;
using System.Text;

namespace SplitSwan.Core;

/// <summary>移植 Mac 版共用的字串處理細節（Swift 的 CharacterSet 語意）。</summary>
internal static class TextRules
{
    /// <summary>
    /// 等同 Swift 的 trimmingCharacters(in: .whitespaces)：去掉 Unicode Zs 類空白、Tab 與 U+200B（零寬空白），
    /// **不**去掉換行（.NET 的 Trim() 會去掉換行，那會讓「帳號結尾夾換行」被默默接受）。
    /// Apple 的 CharacterSet.whitespaces 比 Zs＋Tab 多出 U+200B 一個碼位（以 Swift 掃過全部碼位實測，僅此一個）；
    /// 從網頁或聊天軟體複製的帳號常夾著它，Mac 版會修剪後接受。
    /// </summary>
    public static string TrimWhitespace(string s)
    {
        int start = 0, end = s.Length;
        while (start < end && IsSwiftWhitespace(s[start])) start++;
        while (end > start && IsSwiftWhitespace(s[end - 1])) end--;
        return s.Substring(start, end - start);
    }

    private static bool IsSwiftWhitespace(char c) =>
        c == '\t' || c == '\u200B' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    /// <summary>等同 Swift 的 split(separator:)（預設略過空字串）。</summary>
    public static string[] SplitOmitEmpty(string s, params char[] separators) =>
        s.Split(separators, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>
    /// 等同 Swift 的 CharacterSet.controlCharacters（Unicode Cc 與 Cf），
    /// 例外是 '\n'（Mac 版 strictPreset 允許網段用換行分隔）。
    /// </summary>
    public static bool ContainsControlExceptNewline(string s)
    {
        foreach (var r in s.EnumerateRunes())
        {
            if (r.Value == '\n') continue;
            var cat = Rune.GetUnicodeCategory(r);
            if (cat == UnicodeCategory.Control || cat == UnicodeCategory.Format) return true;
        }
        return false;
    }

    /// <summary>等同 Swift Character.isNewline 涵蓋的字元。</summary>
    public static bool ContainsAnyNewline(string s) =>
        s.IndexOfAny(['\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029']) >= 0;

    /// <summary>strongSwan 設定語法的雙引號字串：跳脫反斜線與雙引號（Mac 版 ConfigStore.quote）。</summary>
    public static string Quote(string s) => s.Replace("\\", "\\\\").Replace("\"", "\\\"");
}
