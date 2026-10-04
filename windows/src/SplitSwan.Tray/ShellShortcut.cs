using System.Runtime.InteropServices;
using System.Text;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 桌面／開始選單捷徑（SplitSwan.lnk）的讀寫。判斷規則在 Core 的 ShortcutRules；這裡只負責檔案系統與 COM。
/// 捷徑狀態不寫進 settings.json，每次都從檔案系統重新讀。
/// 刪除一律先重新讀取並經 ShortcutRules.CanRemove 判斷，只刪「指向本程式」或「指向舊位置」的捷徑。
/// </summary>
internal static class Shortcuts
{
    /// <summary>目前執行中的 exe（捷徑目標）。</summary>
    public static string? CurrentExe => Environment.ProcessPath;

    /// <summary>捷徑檔的完整路徑：目前使用者的桌面或開始選單「程式集」＋ SplitSwan.lnk。</summary>
    /// <exception cref="InvalidOperationException">系統回報沒有這個資料夾。</exception>
    public static string PathOf(ShortcutLocation l)
    {
        var folder = Environment.GetFolderPath(l == ShortcutLocation.Desktop
            ? Environment.SpecialFolder.DesktopDirectory
            : Environment.SpecialFolder.Programs);
        if (string.IsNullOrEmpty(folder))
            throw new InvalidOperationException($"找不到目前使用者的{(l == ShortcutLocation.Desktop ? "桌面" : "開始選單")}資料夾");
        return Path.Combine(folder, ShortcutRules.FileName);
    }

    /// <summary>讀取目前狀態與目標路徑（讀不出目標或描述時為 null，狀態判為「不是我們的」）。</summary>
    /// <exception cref="InvalidOperationException">找不到資料夾。</exception>
    public static (ShortcutState State, string? Target) Inspect(ShortcutLocation l)
    {
        var path = PathOf(l);
        // 同名的資料夾也算「已存在、不是我們的」（不可建立，也不可刪除）
        var exists = File.Exists(path) || Directory.Exists(path);
        string? target = null;
        string? description = null;
        if (File.Exists(path))
        {
            // 任何讀取失敗都只代表「無法確認是我們的」→ Foreign（不刪、不覆寫），不往外丟
            try { (target, description) = ShellLink.Read(path); }
            catch (Exception ex)
            {
                AppLog.Info($"讀取捷徑 {path} 失敗（視為不是 SplitSwan 的捷徑）：{ex.GetType().Name}：{ex.Message}");
            }
        }
        return (ShortcutRules.Classify(exists, target, description, CurrentExe), target);
    }

    /// <summary>
    /// 把捷徑切到 wantOn：重新讀取狀態 → ShortcutRules.OnToggle 決定動作 → 執行。回傳實際採取的動作（Refuse＝沒有變更）。
    /// </summary>
    /// <exception cref="InvalidOperationException">找不到資料夾或目前 exe 路徑。</exception>
    /// <exception cref="IOException">寫入或刪除失敗。</exception>
    /// <exception cref="UnauthorizedAccessException">權限不足。</exception>
    /// <exception cref="COMException">Shell 建立捷徑失敗。</exception>
    public static ShortcutAction Apply(ShortcutLocation l, bool wantOn)
    {
        var path = PathOf(l);
        var (state, _) = Inspect(l);
        var action = ShortcutRules.OnToggle(state, wantOn);
        switch (action)
        {
            case ShortcutAction.Create:
            case ShortcutAction.Update:
                Write(path);
                AppLog.Info($"{ShortcutRules.Title(l)}：{(action == ShortcutAction.Create ? "已建立" : "已更新為目前位置")}（{path}）");
                break;
            case ShortcutAction.Remove:
                // 守門：OnToggle 只會對可刪除的狀態回 Remove；這裡再擋一次，任何改動都不能讓「不是我們的」被刪
                if (!ShortcutRules.CanRemove(state)) return ShortcutAction.Refuse;
                File.Delete(path);
                AppLog.Info($"{ShortcutRules.Title(l)}：已移除（{path}）");
                break;
            case ShortcutAction.Refuse:
                AppLog.Info($"{ShortcutRules.Title(l)}：{ShortcutRules.RefuseMessage}（{path}）");
                break;
        }
        return action;
    }

    /// <summary>把狀態為「指向舊位置」的捷徑改寫成目前的 exe；其他狀態不動，回傳 None／Refuse。</summary>
    public static ShortcutAction UpdateStale(ShortcutLocation l)
    {
        var (state, _) = Inspect(l);
        if (state != ShortcutState.Stale) return state == ShortcutState.Foreign ? ShortcutAction.Refuse : ShortcutAction.None;
        return Apply(l, wantOn: true);
    }

    private static void Write(string path)
    {
        var exe = CurrentExe;
        if (string.IsNullOrEmpty(exe) || !File.Exists(exe)) throw new InvalidOperationException("找不到目前程式的路徑，無法建立捷徑");
        var dir = Path.GetDirectoryName(path);
        if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) throw new DirectoryNotFoundException($"資料夾不存在：{dir}");
        ShellLink.Save(path, exe, Path.GetDirectoryName(exe) ?? "", ShortcutRules.Description);
    }
}

/// <summary>
/// IShellLinkW＋IPersistFile 的 COM interop（不用 dynamic、不用 WScript.Shell）。
/// 介面定義的來源：
/// - 方法語意：https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-ishelllinkw
///   （注意：該頁的方法表是**字母順序**，不是 vtable 順序）、
///   https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ishelllinkw-getpath 、
///   https://learn.microsoft.com/en-us/windows/win32/api/objidl/nn-objidl-ipersistfile
/// - vtable 順序與 IID／CLSID：Windows SDK 標頭 ShObjIdl_core.h（IShellLinkW、CLSID_ShellLink）與 ObjIdl.h（IPersist、IPersistFile），
///   取自 Microsoft 官方 repo microsoft/win32metadata 的 generation/WinSDK/RecompiledIdlHeaders/um/（main@5c5efbc）。
/// [ComImport] 介面不會帶入基底介面的方法，所以 IPersistFile 要自己先列出 IPersist 的 GetClassID。
/// </summary>
internal static class ShellLink
{
    /// <summary>STGM_READ＝0（以唯讀開啟）。</summary>
    private const uint StgmRead = 0;
    /// <summary>GetPath 的 fFlags：0＝一般長路徑（不要 SLGP_SHORTPATH 0x1 的 8.3 短檔名、不要 SLGP_RAWPATH 0x4 的未展開路徑）。</summary>
    private const uint SlgpDefault = 0;
    /// <summary>SW_SHOWNORMAL。</summary>
    private const int SwShowNormal = 1;
    /// <summary>讀回路徑的緩衝區（官方說最長回傳 MAX_PATH，多給一些無妨）。</summary>
    private const int PathBuffer = 1024;
    /// <summary>讀回描述的緩衝區（我們寫入的標記只有 13 字，1024 字元足夠；較長的描述被截斷也只會讓它不等於標記 → 不是我們的）。</summary>
    private const int DescriptionBuffer = 1024;

    /// <summary>
    /// 讀回 .lnk 的目標路徑與描述。目標不是檔案（GetPath 回 S_FALSE）時 Target 為空字串；
    /// 讀描述失敗時 Description 為 null（歸屬判斷會視為沒有標記）。
    /// </summary>
    public static (string Target, string? Description) Read(string lnkPath)
    {
        var link = (IShellLinkW)new ShellLinkCoClass();
        try
        {
            ((IPersistFile)link).Load(lnkPath, StgmRead);
            var sb = new StringBuilder(PathBuffer);
            link.GetPath(sb, sb.Capacity, IntPtr.Zero, SlgpDefault);
            string? description = null;
            try
            {
                var d = new StringBuilder(DescriptionBuffer);
                link.GetDescription(d, d.Capacity);
                description = d.ToString();
            }
            catch (COMException ex)
            {
                AppLog.Info($"讀取捷徑描述失敗（視為沒有 SplitSwan 標記）：{ex.Message}");
            }
            return (sb.ToString(), description);
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    /// <summary>建立（或覆寫）.lnk：目標、工作目錄、圖示（exe 本身 index 0）、描述。</summary>
    public static void Save(string lnkPath, string target, string workingDir, string description)
    {
        var link = (IShellLinkW)new ShellLinkCoClass();
        try
        {
            link.SetPath(target);
            link.SetWorkingDirectory(workingDir);
            link.SetIconLocation(target, 0);
            link.SetDescription(description);
            link.SetShowCmd(SwShowNormal);
            ((IPersistFile)link).Save(lnkPath, true);
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    /// <summary>CLSID_ShellLink（ShObjIdl_core.h：DECLSPEC_UUID("00021401-0000-0000-C000-000000000046") ShellLink）。</summary>
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLinkCoClass;

    /// <summary>
    /// IShellLinkW（IID 000214F9-0000-0000-C000-000000000046，繼承 IUnknown）。
    /// 順序逐一對照 ShObjIdl_core.h 的 MIDL_INTERFACE 宣告，不可重排：
    /// GetPath, GetIDList, SetIDList, GetDescription, SetDescription, GetWorkingDirectory, SetWorkingDirectory,
    /// GetArguments, SetArguments, GetHotkey, SetHotkey, GetShowCmd, SetShowCmd, GetIconLocation, SetIconLocation,
    /// SetRelativePath, Resolve, SetPath。
    /// </summary>
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        // 1. HRESULT GetPath(LPWSTR pszFile, int cch, WIN32_FIND_DATAW *pfd, DWORD fFlags)；pfd 可為 NULL
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
        // 2. HRESULT GetIDList(PIDLIST_ABSOLUTE *ppidl)
        void GetIDList(out IntPtr ppidl);
        // 3. HRESULT SetIDList(PCIDLIST_ABSOLUTE pidl)
        void SetIDList(IntPtr pidl);
        // 4. HRESULT GetDescription(LPWSTR pszName, int cch)
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
        // 5. HRESULT SetDescription(LPCWSTR pszName)
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        // 6. HRESULT GetWorkingDirectory(LPWSTR pszDir, int cch)
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
        // 7. HRESULT SetWorkingDirectory(LPCWSTR pszDir)
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        // 8. HRESULT GetArguments(LPWSTR pszArgs, int cch)
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
        // 9. HRESULT SetArguments(LPCWSTR pszArgs)
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        // 10. HRESULT GetHotkey(WORD *pwHotkey)
        void GetHotkey(out ushort pwHotkey);
        // 11. HRESULT SetHotkey(WORD wHotkey)
        void SetHotkey(ushort wHotkey);
        // 12. HRESULT GetShowCmd(int *piShowCmd)
        void GetShowCmd(out int piShowCmd);
        // 13. HRESULT SetShowCmd(int iShowCmd)
        void SetShowCmd(int iShowCmd);
        // 14. HRESULT GetIconLocation(LPWSTR pszIconPath, int cch, int *piIcon)
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
        // 15. HRESULT SetIconLocation(LPCWSTR pszIconPath, int iIcon)
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        // 16. HRESULT SetRelativePath(LPCWSTR pszPathRel, DWORD dwReserved)
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        // 17. HRESULT Resolve(HWND hwnd, DWORD fFlags)
        void Resolve(IntPtr hwnd, uint fFlags);
        // 18. HRESULT SetPath(LPCWSTR pszFile)
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    /// <summary>
    /// IPersistFile（IID 0000010b-0000-0000-C000-000000000046，繼承 IPersist 0000010c-…）。
    /// 順序對照 ObjIdl.h：IPersist::GetClassID，接著 IsDirty, Load, Save, SaveCompleted, GetCurFile。
    /// </summary>
    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFile
    {
        // IPersist 1. HRESULT GetClassID(CLSID *pClassID)
        void GetClassID(out Guid pClassID);
        // 2. HRESULT IsDirty(void)：S_OK／S_FALSE 都是成功，保留 HRESULT
        [PreserveSig] int IsDirty();
        // 3. HRESULT Load(LPCOLESTR pszFileName, DWORD dwMode)
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        // 4. HRESULT Save(LPCOLESTR pszFileName, BOOL fRemember)
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        // 5. HRESULT SaveCompleted(LPCOLESTR pszFileName)
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        // 6. HRESULT GetCurFile(LPOLESTR *ppszFileName)（CoTaskMem 配置，封送器負責釋放）
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }
}
