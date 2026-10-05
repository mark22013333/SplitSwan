namespace SplitSwan.Tray;

internal static class Program
{
    // Local\：只在同一個登入工作階段內互斥（不同使用者各自可以開）
    private const string MutexName = @"Local\SplitSwan.Tray.SingleInstance";

    [STAThread]
    /// <param name="args">
    /// --wizard：開首次設定精靈並自動繼續（重開機後由 HKCU RunOnce 帶入，見 WizardStore）。
    /// --after-update：一鍵更新啟動的新版（UpdateCenter）：先等舊版結束。
    /// </param>
    private static void Main(string[] args)
    {
        var afterUpdate = SplitSwan.Core.UpdateRules.IsAfterUpdate(args);
        using var mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        if (!createdNew && !(afterUpdate && WaitForPreviousInstance(mutex)))
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

        // 一鍵更新替換時留下的 *.old／*.new：舊版已結束，現在可以清掉（失敗只記錄，下次啟動再試）
        CleanupUpdateLeftovers(afterUpdate);

        // 上次若在連線中途被結束（當機、重開機），secrets.conf 可能留著：一律先清掉
        if (File.Exists(AppPaths.SecretsConf))
        {
            AppLog.Info("清除上次殘留的 secrets.conf");
            ConfWriter.DeleteSecrets();
        }

        var loaded = SettingsStore.Load();
        try
        {
            Application.Run(new TrayContext(loaded, SplitSwan.Core.RunOnceCommand.WantsWizard(args), afterUpdate));
        }
        finally
        {
            ConfWriter.DeleteSecrets();
            AppLog.Close();
            mutex.ReleaseMutex();
        }
    }

    /// <summary>
    /// 一鍵更新：舊版啟動新版後才結束，新版要等它釋放 mutex（最多 60 秒）。
    /// 舊版異常結束時 mutex 會變成 abandoned，視同已取得。回傳是否已取得 mutex。
    /// </summary>
    private static bool WaitForPreviousInstance(Mutex mutex)
    {
        try { return mutex.WaitOne(TimeSpan.FromSeconds(60)); }
        catch (AbandonedMutexException) { return true; }
    }

    private static void CleanupUpdateLeftovers(bool afterUpdate)
    {
        try
        {
            var (removed, failed) = SplitSwan.Core.UpdatePackage.CleanupLeftovers(AppContext.BaseDirectory);
            if (removed.Count > 0) AppLog.Info($"已清除更新留下的舊檔：{string.Join("、", removed)}");
            if (failed.Count > 0) AppLog.Info($"更新留下的舊檔清除失敗（下次啟動再試）：{string.Join("、", failed)}");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            AppLog.Info($"清除更新留下的舊檔失敗：{ex.Message}");
        }
        if (!afterUpdate) return;
        // 解壓用的暫存資料夾（%TEMP%\SplitSwan-update-*）：舊版結束後才刪得掉
        try
        {
            foreach (var d in Directory.EnumerateDirectories(Path.GetTempPath(), "SplitSwan-update-*"))
            {
                try { Directory.Delete(d, recursive: true); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    AppLog.Info($"更新暫存資料夾清除失敗：{d}：{ex.Message}");
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            AppLog.Info($"列出更新暫存資料夾失敗：{ex.Message}");
        }
    }
}
