using System.Runtime.InteropServices;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 系統工作列的位置與自動隱藏狀態（SHAppBarMessage）。只回報主工作列；取不到時回 (null, false)，呼叫端維持原本的做法。
/// 來源：learn.microsoft.com/windows/win32/api/shellapi/nf-shellapi-shappbarmessage、
/// learn.microsoft.com/windows/win32/shell/abm-gettaskbarpos（rc 收到工作列的螢幕座標矩形）、
/// learn.microsoft.com/windows/win32/shell/abm-getstate（回傳值含 ABS_AUTOHIDE 表示自動隱藏）。
/// 訊息編號與旗標值取自 Shellapi.h：ABM_GETSTATE = 0x4、ABM_GETTASKBARPOS = 0x5、ABS_AUTOHIDE = 0x1。
/// </summary>
internal static class Taskbar
{
    private const uint AbmGetState = 0x4;
    private const uint AbmGetTaskbarPos = 0x5;
    private const uint AbsAutoHide = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct AppBarData
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uCallbackMessage;
        public uint uEdge;
        public Rect rc;
        public IntPtr lParam;
    }

    [DllImport("shell32.dll")]
    private static extern UIntPtr SHAppBarMessage(uint dwMessage, ref AppBarData pData);

    public static (PxRect? Rect, bool AutoHide) Query()
    {
        try
        {
            var data = new AppBarData { cbSize = (uint)Marshal.SizeOf<AppBarData>() };
            var autoHide = (SHAppBarMessage(AbmGetState, ref data).ToUInt64() & AbsAutoHide) != 0;
            data = new AppBarData { cbSize = (uint)Marshal.SizeOf<AppBarData>() };
            if (SHAppBarMessage(AbmGetTaskbarPos, ref data) == UIntPtr.Zero) return (null, autoHide);
            var r = data.rc;
            return (new PxRect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top), autoHide);
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            return (null, false);
        }
    }
}
