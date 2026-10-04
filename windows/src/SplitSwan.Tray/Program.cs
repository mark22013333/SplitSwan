namespace SplitSwan.Tray;

internal static class Program
{
    // Local\：只在同一個登入工作階段內互斥（不同使用者各自可以開）
    private const string MutexName = @"Local\SplitSwan.Tray.SingleInstance";

    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show("SplitSwan 已經在執行中，請看工作列右下角的通知區域（可能收在「^」裡）。",
                "SplitSwan", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        // 讓連線引擎知道是由 App 呼叫（背景與首次安裝的可見視窗都繼承這個行程環境變數），
        // 引擎就不會印「請執行 disconnect.cmd」這類只給雙擊 .cmd 的人看的提示
        Environment.SetEnvironmentVariable("SPLITSWAN_HOST", "tray");

        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) =>
            AppLog.Error($"未處理的例外：{e.Exception.GetType().Name}：{e.Exception.Message}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            AppLog.Error($"未處理的例外（即將結束）：{(e.ExceptionObject as Exception)?.Message}");

        AppLog.Init();
        // ProductVersion 可能帶「+git 版本」，記錄只留版本號
        AppLog.Info($"SplitSwan {Application.ProductVersion.Split('+')[0]} 啟動");

        // 上次若在連線中途被結束（當機、重開機），secrets.conf 可能留著：一律先清掉
        if (File.Exists(AppPaths.SecretsConf))
        {
            AppLog.Info("清除上次殘留的 secrets.conf");
            ConfWriter.DeleteSecrets();
        }

        var loaded = SettingsStore.Load();
        try
        {
            Application.Run(new TrayContext(loaded));
        }
        finally
        {
            ConfWriter.DeleteSecrets();
            AppLog.Close();
            mutex.ReleaseMutex();
        }
    }
}
