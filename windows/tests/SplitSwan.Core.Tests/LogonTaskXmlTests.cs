using System.Xml.Linq;
using SplitSwan.Core;
using Xunit;

namespace SplitSwan.Core.Tests;

public class LogonTaskXmlTests
{
    private const string Exe = @"C:\Users\someone\SplitSwan\SplitSwan.exe";
    private const string User = @"PC\someone";
    private static readonly XNamespace Ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";

    private static XElement Task(string xml) => XDocument.Parse(xml).Root!;

    [Fact]
    public void RenderedTask_IsClassifiedAsOurs()
    {
        var (command, description) = LogonTaskXml.Parse(LogonTaskXml.Render(Exe, User));
        Assert.Equal(ShortcutState.Ours, ShortcutRules.Classify(true, command, description, Exe));
    }

    [Fact]
    public void RenderedTask_FromOldFolder_IsStale()
    {
        var (command, description) = LogonTaskXml.Parse(LogonTaskXml.Render(@"D:\old\SplitSwan.exe", User));
        Assert.Equal(ShortcutState.Stale, ShortcutRules.Classify(true, command, description, Exe));
    }

    [Fact]
    public void RunsElevatedAtLogonOfThatUser_WithoutBatteryOrTimeLimits()
    {
        var t = Task(LogonTaskXml.Render(Exe, User));
        Assert.Equal(User, t.Descendants(Ns + "LogonTrigger").Elements(Ns + "UserId").Single().Value);
        Assert.Equal("HighestAvailable", t.Descendants(Ns + "RunLevel").Single().Value);
        Assert.Equal("InteractiveToken", t.Descendants(Ns + "LogonType").Single().Value);
        Assert.Equal("false", t.Descendants(Ns + "DisallowStartIfOnBatteries").Single().Value);
        Assert.Equal("false", t.Descendants(Ns + "StopIfGoingOnBatteries").Single().Value);
        Assert.Equal("PT0S", t.Descendants(Ns + "ExecutionTimeLimit").Single().Value);
        Assert.Equal("IgnoreNew", t.Descendants(Ns + "MultipleInstancesPolicy").Single().Value);
        Assert.Equal(@"C:\Users\someone\SplitSwan", t.Descendants(Ns + "WorkingDirectory").Single().Value);
    }

    [Fact]
    public void SpecialCharactersInPathOrUser_AreEscaped()
    {
        var exe = @"C:\R&D <x>\SplitSwan.exe";
        var xml = LogonTaskXml.Render(exe, @"PC\a&b");
        Assert.Equal(exe, LogonTaskXml.Parse(xml).Command);
        Assert.Equal(@"PC\a&b", Task(xml).Descendants(Ns + "UserId").First().Value);
    }

    [Fact]
    public void DeclaresUtf16_MatchingTheFileEncodingSchtasksReads()
    {
        Assert.StartsWith("<?xml version=\"1.0\" encoding=\"utf-16\"", LogonTaskXml.Render(Exe, User), StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("錯誤: 系統找不到指定的檔案。")]
    [InlineData("<Task><unclosed>")]
    public void UnreadableOutput_IsForeign_NeverRemoved(string? output)
    {
        var (command, description) = LogonTaskXml.Parse(output);
        var state = ShortcutRules.Classify(true, command, description, Exe);
        Assert.Equal(ShortcutState.Foreign, state);
        Assert.False(ShortcutRules.CanRemove(state));
    }

    [Fact]
    public void UserMadeTaskWithSameName_IsForeign()
    {
        var xml = $"""
            <?xml version="1.0" encoding="UTF-16"?>
            <Task version="1.2" xmlns="{Ns}">
              <RegistrationInfo><Description>my own</Description></RegistrationInfo>
              <Actions Context="Author"><Exec><Command>{Exe}</Command></Exec></Actions>
            </Task>
            """;
        var (command, description) = LogonTaskXml.Parse(xml);
        Assert.Equal(Exe, command);
        Assert.Equal(ShortcutState.Foreign, ShortcutRules.Classify(true, command, description, Exe));
    }

    [Fact]
    public void Texts()
    {
        Assert.Equal("登入時自動啟動", ShortcutRules.Title(ShortcutLocation.Logon));
        Assert.Contains("SplitSwan", ShortcutRules.ItemName(ShortcutLocation.Logon));
        Assert.Equal("SplitSwan.lnk", ShortcutRules.ItemName(ShortcutLocation.Desktop));
    }
}
