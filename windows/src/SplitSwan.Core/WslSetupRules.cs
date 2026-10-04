using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace SplitSwan.Core;

/// <summary>系統檢查一項的結果。</summary>
public enum CheckLevel { Ok, Warning, Error }

public sealed record CheckItem(CheckLevel Level, string Text);

/// <summary>首次設定精靈步驟 1：系統需求（契約 6）。</summary>
public static class SystemRequirements
{
    /// <summary>
    /// wsl --install 的最低版本：「Windows 10 version 2004 and higher (Build 19041 and higher) or Windows 11」
    /// （https://learn.microsoft.com/en-us/windows/wsl/install 的 Prerequisites）。
    /// </summary>
    public const int MinBuild = 19041;

    /// <summary>Windows 11 從組建 22000 開始；之前的 Windows 10 另外需要「Windows 子系統 Linux 版」選用元件。</summary>
    public const int Windows11Build = 22000;

    /// <param name="hypervisorPresent">Win32_ComputerSystem.HypervisorPresent；查不到為 null。</param>
    /// <param name="virtualizationFirmwareEnabled">Win32_Processor.VirtualizationFirmwareEnabled；查不到為 null。
    /// 注意：Hypervisor 已在執行時這個值會是 false（CPU 的虛擬化已被 Hypervisor 佔用），所以要先看 hypervisorPresent。</param>
    public static IReadOnlyList<CheckItem> Evaluate(int build, Architecture osArchitecture, bool? hypervisorPresent, bool? virtualizationFirmwareEnabled)
    {
        var items = new List<CheckItem>();
        items.Add(build >= MinBuild
            ? new(CheckLevel.Ok, $"Windows 組建 {build}（需要 {MinBuild} 以上）")
            : new(CheckLevel.Error, $"Windows 組建 {build} 太舊：WSL2 需要 Windows 10 2004（組建 {MinBuild}）以上或 Windows 11，請先更新 Windows"));
        items.Add(osArchitecture switch
        {
            Architecture.X64 => new(CheckLevel.Ok, "64 位元 x64 Windows"),
            Architecture.Arm64 => new(CheckLevel.Error, "這台是 ARM64 Windows：SplitSwan 只支援 x64（下載的 Ubuntu 映像與連線引擎都是 amd64）"),
            _ => new(CheckLevel.Error, $"不支援的處理器架構 {osArchitecture}：SplitSwan 只支援 x64 Windows"),
        });
        if (hypervisorPresent == true)
            items.Add(new(CheckLevel.Ok, "虛擬化：Hypervisor 已在執行"));
        else if (virtualizationFirmwareEnabled == true)
            items.Add(new(CheckLevel.Ok, "虛擬化：BIOS／UEFI 已開啟"));
        else if (virtualizationFirmwareEnabled == false)
            items.Add(new(CheckLevel.Error, "虛擬化：BIOS／UEFI 沒有開啟（Intel VT-x／AMD-V／SVM）。WSL2 需要虛擬化，請進 BIOS 開啟後重試"));
        else
            items.Add(new(CheckLevel.Warning, "虛擬化：無法確認是否開啟（查詢失敗）；若後面步驟失敗，請檢查 BIOS 的虛擬化設定"));
        return items;
    }

    public static bool Passed(IEnumerable<CheckItem> items) => items.All(i => i.Level != CheckLevel.Error);
}

/// <summary>步驟 2 的判斷結果。</summary>
public enum WslReadiness
{
    /// <summary>Store 版 WSL 與必要元件都已生效。</summary>
    Ready,
    /// <summary>要執行 wsl --install --no-distribution --web-download。</summary>
    NeedInstall,
    /// <summary>元件已啟用但要重開機才會生效（或無法確認，寧可提示重開）。</summary>
    NeedReboot,
}

/// <summary>探測腳本回報的 WSL 狀態（各欄位查不到時為 null）。</summary>
public sealed record WslProbe(
    bool StoreWsl,
    string? VmpState,
    string? WslFeatureState,
    bool? HnsPresent,
    bool? VmcomputePresent,
    bool? HypervisorPresent,
    bool? VirtualizationFirmwareEnabled);

/// <summary>
/// 步驟 2：判斷要不要安裝 WSL、要不要重開機。依據 WSL 原始碼（microsoft/WSL，src/windows/common/WslInstall.cpp
/// CheckForMissingOptionalComponents：缺任何必要元件就需要重開機；wslutil.cpp IsVirtualMachinePlatformInstalled：
/// HNS、vmcompute 服務存在且元件已安裝才算可用）。wsl --install 需要重開機時結束碼仍是 0、提示文字又會在地化，
/// 所以不看結束碼與輸出，改看元件狀態（Get-WindowsOptionalFeature 的 State 列舉名稱不在地化）。
/// 研究紀錄見 tray3-research.md。
/// </summary>
public static class WslInstallState
{
    /// <summary>探測用的 PowerShell 指令稿：每項輸出一行 @@KEY=VALUE（值查不到就輸出空字串）。</summary>
    public const string ProbeScript =
        "$ErrorActionPreference='SilentlyContinue';" +
        "function F($n){$f=Get-WindowsOptionalFeature -Online -FeatureName $n;if($f){[string]$f.State}else{''}};" +
        "function S($n){if(Get-Service -Name $n){'1'}else{'0'}};" +
        "$w=Join-Path $env:ProgramFiles 'WSL\\wsl.exe';" +
        "$store=(Test-Path $w) -or [bool](Get-AppxPackage -AllUsers -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux');" +
        "Write-Output ('@@STOREWSL='+$(if($store){'1'}else{'0'}));" +
        "Write-Output ('@@VMP='+(F 'VirtualMachinePlatform'));" +
        "Write-Output ('@@WSLFEATURE='+(F 'Microsoft-Windows-Subsystem-Linux'));" +
        "Write-Output ('@@HNS='+(S 'hns'));" +
        "Write-Output ('@@VMCOMPUTE='+(S 'vmcompute'));" +
        "$cs=Get-CimInstance Win32_ComputerSystem;Write-Output ('@@HYPERVISOR='+$(if($cs){[string]$cs.HypervisorPresent}else{''}));" +
        "$cpu=@(Get-CimInstance Win32_Processor)[0];Write-Output ('@@VTFW='+$(if($cpu){[string]$cpu.VirtualizationFirmwareEnabled}else{''}));" +
        "Write-Output '@@RESULT=ok'";

    public static WslProbe ParseProbe(IEnumerable<string> lines)
    {
        var kv = EngineOutput.Parse(lines);
        string? Str(string k) => kv.TryGetValue(k, out var v) && v.Trim().Length > 0 ? v.Trim() : null;
        bool? Flag(string k) => Str(k) switch
        {
            "1" => true,
            "0" => false,
            { } s when s.Equals("True", StringComparison.OrdinalIgnoreCase) => true,
            { } s when s.Equals("False", StringComparison.OrdinalIgnoreCase) => false,
            _ => null,
        };
        return new WslProbe(Flag("STOREWSL") == true, Str("VMP"), Str("WSLFEATURE"), Flag("HNS"), Flag("VMCOMPUTE"),
            Flag("HYPERVISOR"), Flag("VTFW"));
    }

    private static bool IsEnabled(string? s) => string.Equals(s, "Enabled", StringComparison.OrdinalIgnoreCase);
    private static bool IsPending(string? s) => s is not null && s.EndsWith("Pending", StringComparison.OrdinalIgnoreCase);
    private static bool IsDisabled(string? s) => s is not null && s.StartsWith("Disabled", StringComparison.OrdinalIgnoreCase);

    /// <param name="build">Windows 組建；Windows 10（&lt; 22000）另外需要 Microsoft-Windows-Subsystem-Linux 元件（同 WSL 原始碼）。</param>
    /// <param name="rebootedSinceInstall">精靈執行過安裝之後是否已重開過機。已重開過但元件狀態仍查不到、服務都在時視為可用，
    /// 避免查詢本身失敗（例如群組原則擋 DISM）讓精靈永遠要求重開機。</param>
    public static WslReadiness Evaluate(WslProbe p, int build, bool rebootedSinceInstall = false)
    {
        ArgumentNullException.ThrowIfNull(p);
        var states = new List<string?> { p.VmpState };
        if (build < SystemRequirements.Windows11Build) states.Add(p.WslFeatureState);

        // 1. 沒有 Store 版 WSL、或元件明確是停用 → 執行安裝（wsl --install 會補裝缺的元件）
        if (!p.StoreWsl || states.Any(IsDisabled)) return WslReadiness.NeedInstall;
        // 2. 元件已啟用但待重開機
        if (states.Any(IsPending)) return WslReadiness.NeedReboot;
        var servicesUp = p.HnsPresent == true && p.VmcomputePresent == true;
        // 3. 都已啟用且服務已出現 → 可用（同 WSL 的 IsVirtualMachinePlatformInstalled）
        // 已重開過機仍偵測不到服務：服務查詢本身可能有問題，不再要求重開（否則每次都要重開），交給後面步驟實際執行時報錯
        if (states.All(IsEnabled)) return servicesUp || rebootedSinceInstall ? WslReadiness.Ready : WslReadiness.NeedReboot;
        // 4. 狀態查不到：重開過機且服務都在才算可用，否則寧可提示重開機
        return rebootedSinceInstall && servicesUp ? WslReadiness.Ready : WslReadiness.NeedReboot;
    }

    /// <summary>給使用者看的一行狀態說明。</summary>
    public static string Describe(WslProbe p) =>
        $"Store 版 WSL：{(p.StoreWsl ? "有" : "沒有")}；虛擬機器平台：{p.VmpState ?? "查不到"}；" +
        $"WSL 選用元件：{p.WslFeatureState ?? "查不到"}；HNS／vmcompute 服務：{Yn(p.HnsPresent)}／{Yn(p.VmcomputePresent)}";

    private static string Yn(bool? b) => b switch { true => "有", false => "沒有", null => "查不到" };
}

/// <summary>WSL 發行版名稱與清單。</summary>
public static partial class WslDistros
{
    /// <summary>精靈新匯入的發行版名稱（契約 6）。</summary>
    public const string SplitSwan = "SplitSwan";
    /// <summary>舊版（第一、二階段）用 wsl --install 安裝的發行版；settings.json 沒有 distro 欄位時沿用。</summary>
    public const string Legacy = "Ubuntu-24.04";

    // 與引擎 splitswan-wsl.ps1 的 Test-DistroName 同一份規則：首字為英數，其餘英數與 . _ -，1～64 字元
    // （wsl.exe -d --install 會被當成選項）。用 \z 而非 $：.NET 的 $ 允許結尾多一個換行。
    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z")]
    private static partial Regex NameRegex();

    /// <summary>名稱首字為英數、其餘英數與 . _ -、最多 64 字元（會放進命令列與 -Distro 參數）。</summary>
    public static bool IsValidName(string? name) => name is not null && NameRegex().IsMatch(name);

    /// <summary>
    /// 解析 wsl -l -q 的輸出：去掉 NUL（沒設 WSL_UTF8 時 wsl.exe 輸出 UTF-16，被當 UTF-8 讀會夾 NUL）、BOM 與空白。
    /// </summary>
    public static IReadOnlyList<string> ParseList(IEnumerable<string> lines) =>
        [.. lines.Select(l => (l ?? "").Replace("\0", "").Replace("\uFEFF", "").Trim()).Where(l => l.Length > 0)];

    /// <summary>清單裡有沒有這個發行版（WSL 的名稱不分大小寫）。</summary>
    public static bool Contains(IEnumerable<string> installed, string name) =>
        installed.Any(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// 匯入後讓預設使用者是 root 的 sh 指令稿（保險：文件說 --import 一律以 root 開始，但 Ubuntu 映像的
    /// /etc/wsl-distribution.conf 有 oobe.defaultUid=1000）。已有 [user] 段就換掉其中的 default=，否則附加一段；
    /// 不動其他段（引擎 setup 之後會附加 [boot] systemd=true）。
    /// 刻意不含雙引號：它經過 Windows 命令列傳給 wsl.exe --exec sh -c，雙引號的跳脫規則因程式而異。
    /// </summary>
    public const string DefaultRootScript =
        "touch /etc/wsl.conf; " +
        "if grep -q '^\\[user\\]' /etc/wsl.conf; then " +
        "sed -i '/^\\[user\\]/,/^\\[/{/^[[:space:]]*default[[:space:]]*=/d}' /etc/wsl.conf; " +
        "sed -i '/^\\[user\\]/a default=root' /etc/wsl.conf; " +
        "else printf '\\n[user]\\ndefault=root\\n' >> /etc/wsl.conf; fi; " +
        "grep -A2 '^\\[user\\]' /etc/wsl.conf";
}

/// <summary>步驟 3 要做什麼。</summary>
public enum DistroAction
{
    /// <summary>查不到發行版清單（wsl -l 失敗且無法確認「沒有任何發行版」）：步驟失敗，不下載、不改設定。</summary>
    QueryFailed,
    /// <summary>設定裡的發行版已存在，略過。</summary>
    UseConfigured,
    /// <summary>設定的不在，但 SplitSwan 已存在：改用它（設定改成 SplitSwan）。</summary>
    UseExistingSplitSwan,
    /// <summary>安裝位置已有 ext4.vhdx（之前匯入過、被取消註冊）：wsl --import-in-place 重新註冊，不覆蓋資料。</summary>
    ImportInPlace,
    /// <summary>下載並 wsl --import。</summary>
    DownloadAndImport,
}

public static class DistroPlan
{
    /// <param name="installed">已安裝的發行版；null＝查不到（一律 QueryFailed，絕不下載或改用新發行版）。</param>
    public static DistroAction Decide(string configured, IReadOnlyList<string>? installed, bool vhdxExistsAtLocation)
    {
        if (installed is null) return DistroAction.QueryFailed;
        if (WslDistros.Contains(installed, configured)) return DistroAction.UseConfigured;
        if (WslDistros.Contains(installed, WslDistros.SplitSwan)) return DistroAction.UseExistingSplitSwan;
        return vhdxExistsAtLocation ? DistroAction.ImportInPlace : DistroAction.DownloadAndImport;
    }

    /// <summary>
    /// 決定已安裝清單。wsl -l -q 成功 → 用它的輸出；失敗時（沒有任何發行版也會回非 0，但提示文字會在地化、無法比對）
    /// 只有在登錄 HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss 讀得到且確定一個發行版都沒有時，才當成空清單；
    /// 其他情況（登錄讀不到、登錄裡有發行版但 wsl 失敗＝WSL 暫時異常）一律 null＝查不到。
    /// </summary>
    /// <param name="registryNames">登錄 Lxss 底下各發行版的 DistributionName；讀不到為 null。</param>
    public static IReadOnlyList<string>? ResolveInstalled(bool wslOk, IReadOnlyList<string> wslList, IReadOnlyList<string>? registryNames)
    {
        if (wslOk) return wslList;
        return registryNames is { Count: 0 } ? [] : null;
    }

    /// <summary>
    /// 能不能把設定改成另一個發行版：VPN 已連線或想連線時不行——之後的斷線、輪詢都會帶新的 -Distro，
    /// 舊發行版裡的通道與保活程序就沒人收（review3）。要先斷線。
    /// </summary>
    public static bool CanSwitchDistro(bool isUp, bool wantConnected) => !isUp && !wantConnected;

    /// <summary>
    /// 設定的是 SplitSwan、但機器上已經有舊版的 Ubuntu-24.04：行為不變（另外建立專用發行版），只給一行提示。
    /// 不需要提示時回 null。
    /// </summary>
    public static string? LegacyCoexistNote(string configured, IReadOnlyList<string> installed, DistroAction action) =>
        action is DistroAction.DownloadAndImport or DistroAction.ImportInPlace
        && string.Equals(configured, WslDistros.SplitSwan, StringComparison.OrdinalIgnoreCase)
        && WslDistros.Contains(installed, WslDistros.Legacy)
            ? $"這台已經有 {WslDistros.Legacy}：SplitSwan 會另外建立專用的發行版 {WslDistros.SplitSwan}，原本的 {WslDistros.Legacy} 不會被修改或刪除。"
            : null;
}

/// <summary>App 啟動時要不要自動開精靈（契約 6）。</summary>
public static class WizardTrigger
{
    /// <param name="resumeAfterReboot">精靈存檔顯示在等重開機（或命令列帶了 --wizard）。</param>
    /// <param name="settingsValid">現有設定通過驗證。</param>
    /// <param name="distroExists">設定的發行版存在；查不到（探測失敗）為 null，不因此開精靈。</param>
    public static bool ShouldAutoOpen(bool resumeAfterReboot, bool settingsValid, bool? distroExists) =>
        resumeAfterReboot || !settingsValid || distroExists == false;
}

/// <summary>重開機後自動開 App：HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce 的值。</summary>
public static class RunOnceCommand
{
    /// <summary>值名稱（固定，重複寫入會覆蓋同一筆）。</summary>
    public const string ValueName = "SplitSwanSetup";

    /// <summary>App 收到這個參數就開首次設定精靈並自動繼續。</summary>
    public const string WizardArgument = "--wizard";

    /// <summary>
    /// 「Run and RunOnce Registry Keys」文件：「The data value for a key is a command line no longer than 260 characters.」
    /// （https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys）
    /// </summary>
    public const int MaxLength = 260;

    /// <summary>
    /// 組出命令列 "&lt;exe&gt;" --wizard；路徑空白、含雙引號或超過 260 字元時回傳 null（呼叫端改請使用者手動開 App）。
    /// </summary>
    public static string? Build(string? exePath)
    {
        if (string.IsNullOrWhiteSpace(exePath) || exePath.Contains('"')) return null;
        var cmd = $"\"{exePath}\" {WizardArgument}";
        return cmd.Length <= MaxLength ? cmd : null;
    }

    /// <summary>命令列參數是否要求開精靈。</summary>
    public static bool WantsWizard(IEnumerable<string>? args) =>
        args?.Any(a => string.Equals(a, WizardArgument, StringComparison.OrdinalIgnoreCase)) == true;
}
