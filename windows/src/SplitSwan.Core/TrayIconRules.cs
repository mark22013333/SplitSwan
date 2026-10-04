namespace SplitSwan.Core;

/// <summary>圖示前景色的種類（實際 RGB 由托盤決定）。</summary>
public enum TrayIconInk
{
    /// <summary>黑色：工作列是淺色時（對應 Mac 的 template 圖在淺色選單列）。</summary>
    Black,
    /// <summary>白色：工作列是深色、或讀不到設定時（Windows 預設工作列是深色）。</summary>
    White,
    /// <summary>綠色：已連線且開啟「已連線時顯示綠色」。</summary>
    Green,
}

/// <summary>托盤圖示的繪製規則（狀態對應、顏色、「VPN 字樣」文字），純邏輯方便測試。</summary>
public static class TrayIconRules
{
    /// <summary>
    /// App 狀態 → 圖示狀態（同 Mac 版 MenuBarIcon.state：動作進行中算「連線中」）。
    /// 狀態不明（Unknown）沒有對應的 Mac 狀態：用「異常」的字形，再由托盤以半透明另行標示（見 <see cref="IsDimmed"/>）。
    /// 理由：狀態不明時 App 不會發斷線通知也不會自動重連，需要使用者留意（「內網連不到就按連線」），
    /// 所以用醒目的異常字形；但它不代表斷線，半透明讓它和真正的異常看得出差別，tooltip 也會寫明。
    /// </summary>
    public static TrayIconState ToIconState(TrayState s) => s switch
    {
        TrayState.Connected => TrayIconState.Connected,
        TrayState.Busy => TrayIconState.Connecting,
        TrayState.Error => TrayIconState.Error,
        TrayState.Unknown => TrayIconState.Error,
        _ => TrayIconState.Disconnected,
    };

    /// <summary>要不要畫成半透明（只有狀態不明）。</summary>
    public static bool IsDimmed(TrayState s) => s == TrayState.Unknown;

    /// <summary>
    /// 前景色：開啟「已連線時顯示綠色」且已連線 → 綠色；其他依工作列深淺色（淺色用黑、深色用白）。
    /// </summary>
    public static TrayIconInk Ink(TrayIconState st, bool greenWhenConnected, bool lightTaskbar) =>
        greenWhenConnected && st == TrayIconState.Connected ? TrayIconInk.Green
        : lightTaskbar ? TrayIconInk.Black
        : TrayIconInk.White;

    /// <summary>
    /// 解讀登錄值 HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize 的 SystemUsesLightTheme：
    /// 1＝工作列淺色；0、讀不到（null）、型別不對都當深色（Windows 預設）。
    /// </summary>
    public static bool IsLightTaskbar(object? registryValue) => registryValue is int i && i == 1;

    /// <summary>
    /// 「VPN 字樣」樣式的文字（同 Mac 版 textImage：連線中加「…」、異常加「!」）；
    /// 狀態不明 Mac 沒有，用「VPN?」。
    /// </summary>
    public static string TextLabel(TrayState s) => s switch
    {
        TrayState.Busy => "VPN…",
        TrayState.Error => "VPN!",
        TrayState.Unknown => "VPN?",
        _ => "VPN",
    };

    /// <summary>「VPN 字樣」樣式在預覽用的圖示狀態 → 文字（設定頁四種狀態預覽用）。</summary>
    public static string TextLabel(TrayIconState st) => st switch
    {
        TrayIconState.Connecting => "VPN…",
        TrayIconState.Error => "VPN!",
        _ => "VPN",
    };

    /// <summary>「VPN 字樣」是否畫成實心底反白字（只有已連線；其他狀態是外框字，同 Mac）。</summary>
    public static bool TextFilled(TrayIconState st) => st == TrayIconState.Connected;
}
