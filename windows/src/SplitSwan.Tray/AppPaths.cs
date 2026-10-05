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
    /// <summary>F4 閘道連線紀錄（非機密：只有編號、位址、成敗、耗時、時間）。</summary>
    public static string GatewayHistoryFile { get; } = Path.Combine(DataDir, "gateway-history.json");
    /// <summary>檢查更新的紀錄（上次檢查時間、已通知過的版本；非機密）。</summary>
    public static string UpdateCheckFile { get; } = Path.Combine(DataDir, "update-check.json");
    /// <summary>首次設定精靈的進度（重開機後從中斷處繼續）。</summary>
    public static string WizardFile { get; } = Path.Combine(DataDir, "wizard.json");
    /// <summary>精靈匯入的 SplitSwan 發行版位置（ext4.vhdx 放這裡，契約 6）。</summary>
    public static string WslDir { get; } = Path.Combine(DataDir, "wsl");
    /// <summary>下載 Ubuntu 映像的暫存處；匯入成功或雜湊不符時刪除下載檔。</summary>
    public static string DownloadDir { get; } = Path.Combine(DataDir, "download");

    /// <summary>
    /// Store 版 WSL 的 wsl.exe（同引擎 Find-StoreWsl）。System32 的 inbox wsl.exe 在 WSL 未安裝時可能跳互動提示，
    /// 精靈只在 Store 版存在時才用它跑 -l／--import 等指令；安裝 WSL 本身用 System32 的那支。
    /// </summary>
    public static string StoreWslExe { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WSL", "wsl.exe");
    public static string SystemWslExe { get; } = Path.Combine(Environment.SystemDirectory, "wsl.exe");

    /// <summary>外部指令的工作目錄：App 的資料夾；建不起來就用系統暫存資料夾。</summary>
    public static string DataDirOrTemp()
    {
        try { Directory.CreateDirectory(DataDir); return DataDir; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return Path.GetTempPath(); }
    }

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
