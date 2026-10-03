namespace SplitSwan.Tray;

/// <summary>App 用到的固定路徑。資料一律放在目前使用者的 %LOCALAPPDATA%\SplitSwan 底下。</summary>
internal static class AppPaths
{
    public const string AppName = "SplitSwan";

    public static string DataDir { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);

    /// <summary>給引擎的設定檔資料夾（swanctl.conf、secrets.conf、options.ini）。</summary>
    public static string ConfDir { get; } = Path.Combine(DataDir, "conf");
    public static string SwanctlConf { get; } = Path.Combine(ConfDir, "swanctl.conf");
    public static string SecretsConf { get; } = Path.Combine(ConfDir, "secrets.conf");
    public static string OptionsIni { get; } = Path.Combine(ConfDir, "options.ini");

    public static string LogDir { get; } = Path.Combine(DataDir, "logs");
    public static string SettingsFile { get; } = Path.Combine(DataDir, "settings.json");

    /// <summary>引擎腳本：exe 旁的 engine\。單一檔案發佈時 AppContext.BaseDirectory 就是 exe 所在資料夾。</summary>
    public static string EngineDir { get; } = Path.Combine(AppContext.BaseDirectory, "engine");
    public static string EnginePs1 { get; } = Path.Combine(EngineDir, "splitswan-wsl.ps1");
    public static string EngineSh { get; } = Path.Combine(EngineDir, "splitswan-wsl.sh");

    /// <summary>
    /// 用系統目錄下的 Windows PowerShell 5.1 完整路徑，不靠 PATH 搜尋
    /// （App 以管理員執行，不能讓 PATH 上的同名程式被執行）。
    /// </summary>
    public static string PowerShellExe { get; } =
        Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");

    /// <summary>引擎腳本缺了哪些檔；全部都在回傳 null。</summary>
    public static string? MissingEngineFiles()
    {
        var missing = new[] { EnginePs1, EngineSh }.Where(p => !File.Exists(p)).ToList();
        return missing.Count == 0 ? null : string.Join("、", missing);
    }
}
