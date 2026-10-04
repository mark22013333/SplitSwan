namespace SplitSwan.Core;

/// <summary>
/// 托盤 App 介面配色（視覺稿 C「狀態優先」的 .dir-c token）。顏色一律是 0xAARRGGBB，
/// 托盤端用 Color.FromArgb 轉換；Core 不依賴 System.Drawing，方便在 macOS 上測試。
/// </summary>
/// <param name="Bg">視窗底色（--w-bg）。</param>
/// <param name="Surface">卡片、清單底色（--w-surface）。</param>
/// <param name="Raised">輸入框、次要按鈕底色（--w-raised）。</param>
/// <param name="Ink">主要文字（--w-ink）。</param>
/// <param name="Muted">次要文字（--w-muted）。</param>
/// <param name="Line">框線（--w-line）。</param>
/// <param name="Accent">強調色（--w-accent）。</param>
/// <param name="AccentInk">強調色上的文字（--w-accent-ink）。</param>
/// <param name="AccentSoft">淡強調底色（--w-accent-soft）。</param>
/// <param name="Hero">狀態面板頂部的深色區（--w-title）。</param>
/// <param name="HeroInk">深色區的文字（.c-hero 的 #e3eeef，兩種主題相同）。</param>
/// <param name="HeroMuted">深色區的小標（.c-kv span 的 #8fa5a9）。</param>
/// <param name="Ok">成功（--ok）。</param>
/// <param name="Warn">注意（--warn）。</param>
/// <param name="Bad">錯誤（--bad）。</param>
/// <param name="TermBg">精靈輸出區底色（.term，兩種主題相同）。</param>
/// <param name="TermInk">精靈輸出區文字。</param>
public sealed record ThemePalette(
    bool IsDark,
    uint Bg, uint Surface, uint Raised, uint Ink, uint Muted, uint Line,
    uint Accent, uint AccentInk, uint AccentSoft,
    uint Hero, uint HeroInk, uint HeroMuted,
    uint Ok, uint Warn, uint Bad,
    uint TermBg, uint TermInk)
{
    /// <summary>淺色（.dir-c 預設值）。</summary>
    public static ThemePalette Light { get; } = new(
        IsDark: false,
        Bg: 0xFFF4F6F6, Surface: 0xFFFFFFFF, Raised: 0xFFFAFBFB, Ink: 0xFF122024, Muted: 0xFF55666B, Line: 0xFFDDE3E4,
        Accent: 0xFF0E7C86, AccentInk: 0xFFFFFFFF, AccentSoft: 0xFFDFF1F2,
        Hero: 0xFF122024, HeroInk: 0xFFE3EEEF, HeroMuted: 0xFF8FA5A9,
        Ok: 0xFF1F8A4C, Warn: 0xFFB26A00, Bad: 0xFFC4314B,
        TermBg: 0xFF0C0F12, TermInk: 0xFFCFD8E3);

    /// <summary>深色（.dir-c 在 prefers-color-scheme: dark 的值）。</summary>
    public static ThemePalette Dark { get; } = new(
        IsDark: true,
        Bg: 0xFF0F1719, Surface: 0xFF152124, Raised: 0xFF1A282B, Ink: 0xFFE3EEEF, Muted: 0xFF8FA5A9, Line: 0xFF26383C,
        Accent: 0xFF3CC3CF, AccentInk: 0xFF06282B, AccentSoft: 0xFF123A3E,
        Hero: 0xFF0A1113, HeroInk: 0xFFE3EEEF, HeroMuted: 0xFF8FA5A9,
        Ok: 0xFF5CC98A, Warn: 0xFFF0B04A, Bad: 0xFFF0798D,
        TermBg: 0xFF0C0F12, TermInk: 0xFFCFD8E3);

    /// <summary>精靈輸出區「指令」行的顏色（.term .cmd）。</summary>
    public const uint TermCommand = 0xFF8FD3FF;
    /// <summary>精靈輸出區「完成」行的顏色（.term .okl）。</summary>
    public const uint TermOk = 0xFF7EE2A8;

    /// <summary>依主題選配色。</summary>
    public static ThemePalette For(bool dark) => dark ? Dark : Light;

    /// <summary>
    /// 把 front 以 t（0～1）比例疊在 back 上（等同 CSS color-mix(in srgb, front t, back)），結果不透明。
    /// 用來做 hover／pressed 色、chip 的淡框線。
    /// </summary>
    public static uint Mix(uint front, uint back, double t)
    {
        t = Math.Clamp(t, 0, 1);
        static uint Ch(uint c, int shift) => (c >> shift) & 0xFF;
        uint Blend(int shift) => (uint)Math.Round(Ch(front, shift) * t + Ch(back, shift) * (1 - t));
        return 0xFF000000 | (Blend(16) << 16) | (Blend(8) << 8) | Blend(0);
    }
}

/// <summary>主題判斷與 DWM 屬性選擇（純邏輯）。</summary>
public static class ThemeRules
{
    /// <summary>
    /// 解讀 HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize 的 AppsUseLightTheme：
    /// 只有明確為 0 才是深色；讀不到（null）、型別不對、其他值都當淺色（規格：讀不到＝淺色）。
    /// </summary>
    public static bool IsDarkApps(object? registryValue) => registryValue is int i && i == 0;

    /// <summary>
    /// DWMWA_USE_IMMERSIVE_DARK_MODE 要用的屬性編號：
    /// - 組建 18985 以上（Windows 10 20H1 起、Windows 11）用 20（文件值）；
    /// - 組建 17763～18984（Windows 10 1809～1909）只認未公開的舊值 19；
    /// - 更舊的系統不支援深色標題列，回 null（呼叫端不設定）。
    /// 來源：learn.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute（值 20；文件只寫 Windows 11 22000 起，
    /// 實際在 Windows 10 20H1 已可用）；19 為未公開的舊值，設定失敗時呼叫端忽略。
    /// </summary>
    public static int? DarkModeAttribute(int build) =>
        build >= 18985 ? 20
        : build >= 17763 ? 19
        : null;

    /// <summary>DWMWA_WINDOW_CORNER_PREFERENCE（33）：Windows 11（組建 22000）起才支援。</summary>
    public static bool SupportsCornerPreference(int build) => build >= 22000;
}
