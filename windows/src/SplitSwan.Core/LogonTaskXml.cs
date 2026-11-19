using System.Xml;
using System.Xml.Linq;

namespace SplitSwan.Core;

/// <summary>
/// 「登入時自動啟動」的工作排程器工作（schtasks /XML 的內容）。歸屬判斷沿用 <see cref="ShortcutRules"/>：
/// 工作的描述就是 <see cref="ShortcutRules.Description"/> 標記，動作的 Command 就是捷徑的目標。
/// 用工作排程器而不是「啟動」資料夾，是因為 App 需要系統管理員權限：啟動資料夾裡要提權的程式，Windows 登入時不會執行；
/// 以「最高權限」執行的工作則不經 UAC 直接提權啟動。
/// </summary>
public static class LogonTaskXml
{
    /// <summary>工作名稱（工作排程器根資料夾下）。</summary>
    public const string TaskName = "SplitSwan";

    private static readonly XNamespace Ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";

    /// <summary>
    /// 產生工作定義：使用者 userId 登入時（延遲 5 秒）以最高權限執行 exe，工作目錄是 exe 所在資料夾。
    /// 用電池時也啟動、不設執行時間上限（預設 72 小時後會被結束）、已在執行時不再啟動第二份。
    /// </summary>
    /// <param name="exe">SplitSwan.exe 的完整路徑。</param>
    /// <param name="userId">登入的帳號（DOMAIN\使用者），也是執行工作的帳號。</param>
    public static string Render(string exe, string userId)
    {
        XElement E(string name, params object[] content) => new(Ns + name, content);
        var doc = new XDocument(new XDeclaration("1.0", "UTF-16", null),
            E("Task", new XAttribute("version", "1.2"),
                E("RegistrationInfo",
                    E("Description", ShortcutRules.Description),
                    E("URI", @"\" + TaskName)),
                E("Triggers",
                    E("LogonTrigger",
                        E("Enabled", "true"),
                        E("UserId", userId),
                        E("Delay", "PT5S"))),
                E("Principals",
                    E("Principal", new XAttribute("id", "Author"),
                        E("UserId", userId),
                        E("LogonType", "InteractiveToken"),
                        E("RunLevel", "HighestAvailable"))),
                E("Settings",
                    E("MultipleInstancesPolicy", "IgnoreNew"),
                    E("DisallowStartIfOnBatteries", "false"),
                    E("StopIfGoingOnBatteries", "false"),
                    E("ExecutionTimeLimit", "PT0S"),
                    E("Priority", "5"),
                    E("Enabled", "true")),
                E("Actions", new XAttribute("Context", "Author"),
                    E("Exec",
                        E("Command", ShortcutRules.NormalizePath(exe)),
                        E("WorkingDirectory", ShortcutRules.DirectoryOf(exe))))));
        return doc.Declaration + "\r\n" + doc.ToString();
    }

    /// <summary>
    /// 從 schtasks /Query /XML 的輸出讀回第一個 Exec 動作的 Command 與工作描述。
    /// 不是合法 XML 時兩者都是 null（歸屬判斷會視為不是我們的，不刪、不覆寫）。
    /// </summary>
    public static (string? Command, string? Description) Parse(string? xml)
    {
        if (string.IsNullOrWhiteSpace(xml)) return (null, null);
        XDocument doc;
        try { doc = XDocument.Parse(xml.TrimStart('﻿')); }
        catch (XmlException) { return (null, null); }
        var description = doc.Descendants(Ns + "RegistrationInfo").Elements(Ns + "Description").FirstOrDefault()?.Value;
        var command = doc.Descendants(Ns + "Exec").Elements(Ns + "Command").FirstOrDefault()?.Value;
        return (command, description);
    }
}
