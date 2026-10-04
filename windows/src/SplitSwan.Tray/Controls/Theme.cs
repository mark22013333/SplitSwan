using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using SplitSwan.Core;

namespace SplitSwan.Tray.Controls;

/// <summary>會跟著主題重新上色的控制項（自繪元件實作它；Theme.Apply 走訪時呼叫）。</summary>
internal interface IThemed
{
    void ApplyTheme();
}

/// <summary>
/// 介面主題（視覺稿 C）：配色依 Windows「應用程式模式」深淺色（AppsUseLightTheme，讀不到＝淺色），
/// 字型、DWM 標題列深色與 Windows 11 圓角。只在 UI 執行緒使用。
/// 字型在整個 App 生命週期共用（快取），App 結束時由 <see cref="DisposeFonts"/> 釋放；控制項不得 Dispose 它們。
/// </summary>
internal static class Theme
{
    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private static readonly Dictionary<(string Family, float Size, FontStyle Style), Font> Fonts = new();
    private static string? _uiFamily;
    private static string? _monoFamily;

    public static ThemePalette Palette { get; private set; } = ReadPalette();

    /// <summary>深淺色改變（已切回 UI 執行緒）。</summary>
    public static event Action? Changed;

    public static Color C(uint argb) => Color.FromArgb(unchecked((int)argb));

    public static Color Bg => C(Palette.Bg);
    public static Color Surface => C(Palette.Surface);
    public static Color Raised => C(Palette.Raised);
    public static Color Ink => C(Palette.Ink);
    public static Color Muted => C(Palette.Muted);
    public static Color Line => C(Palette.Line);
    public static Color Accent => C(Palette.Accent);
    public static Color AccentInk => C(Palette.AccentInk);
    public static Color AccentSoft => C(Palette.AccentSoft);

    public static Color Tone(StatusTone t) => t switch
    {
        StatusTone.Ok => C(Palette.Ok),
        StatusTone.Warn => C(Palette.Warn),
        StatusTone.Bad => C(Palette.Bad),
        _ => Muted,
    };

    /// <summary>front 以 t 疊在 back 上（CSS color-mix）。</summary>
    public static Color Mix(Color front, Color back, double t) =>
        C(ThemePalette.Mix((uint)front.ToArgb(), (uint)back.ToArgb(), t));

    private static ThemePalette ReadPalette()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return ThemePalette.For(ThemeRules.IsDarkApps(k?.GetValue("AppsUseLightTheme")));
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return ThemePalette.Light;
        }
    }

    /// <summary>重讀登錄；深淺色有變才觸發 Changed。在 UI 執行緒呼叫。</summary>
    public static void Refresh()
    {
        var p = ReadPalette();
        if (p.IsDark == Palette.IsDark) return;
        Palette = p;
        AppLog.Info(p.IsDark ? "應用程式改為深色模式，介面改用深色" : "應用程式改為淺色模式，介面改用淺色");
        Changed?.Invoke();
    }

    // MARK: 字型

    /// <summary>
    /// 介面字型：Microsoft JhengHei UI（微軟正黑體 UI，舊版本在真機確認過中文顯示正常；英數字形也由它提供），
    /// 沒有時退回 Segoe UI。
    /// </summary>
    public static string UiFamily => _uiFamily ??= FirstInstalled("Microsoft JhengHei UI", "Segoe UI") ?? "Segoe UI";

    /// <summary>等寬字型：Cascadia Mono → Consolas。</summary>
    public static string MonoFamily => _monoFamily ??= FirstInstalled("Cascadia Mono", "Consolas") ?? "Consolas";

    private static string? FirstInstalled(params string[] names)
    {
        foreach (var n in names)
        {
            // FontFamily 建構子找不到字型時丟 ArgumentException
            try
            {
                using var f = new FontFamily(n);
                if (string.Equals(f.Name, n, StringComparison.OrdinalIgnoreCase)) return n;
            }
            catch (ArgumentException) { }
        }
        return null;
    }

    /// <summary>介面字型（點數；DPI 縮放由 WinForms 處理）。共用快取，不可 Dispose。</summary>
    public static Font Ui(float points = 9f, FontStyle style = FontStyle.Regular) => Get(UiFamily, points, style);

    /// <summary>等寬字型。共用快取，不可 Dispose。</summary>
    public static Font Mono(float points = 9f, FontStyle style = FontStyle.Regular) => Get(MonoFamily, points, style);

    private static Font Get(string family, float points, FontStyle style)
    {
        var key = (family, points, style);
        if (!Fonts.TryGetValue(key, out var f))
        {
            f = new Font(family, points, style, GraphicsUnit.Point);
            Fonts[key] = f;
        }
        return f;
    }

    private static readonly Dictionary<(string Family, float Size, FontStyle Style, int Dpi), Font> DpiFonts = new();

    /// <summary>
    /// 直接繪製用的字型（不是控制項的 Font）：依控制項目前的 DeviceDpi 換成像素大小，並依 DPI 快取。
    /// 點數字型在繪製時是用程序（系統）DPI 換算，PerMonitorV2 下移到不同縮放的螢幕會變小或變大；
    /// 控制項自己的 Font 由 WinForms 縮放，這裡補上直接取用的那幾處。共用快取，不可 Dispose。
    /// </summary>
    public static Font AtDpi(Font font, int dpi)
    {
        if (dpi <= 0) dpi = 96;
        var key = (font.Name, font.SizeInPoints, font.Style, dpi);
        if (!DpiFonts.TryGetValue(key, out var f))
        {
            f = new Font(font.FontFamily, font.SizeInPoints * dpi / 72f, font.Style, GraphicsUnit.Pixel);
            DpiFonts[key] = f;
        }
        return f;
    }

    /// <summary>App 結束時釋放共用字型。</summary>
    public static void DisposeFonts()
    {
        foreach (var f in Fonts.Values) f.Dispose();
        Fonts.Clear();
        foreach (var f in DpiFonts.Values) f.Dispose();
        DpiFonts.Clear();
    }

    // MARK: 走訪上色

    /// <summary>
    /// 依目前主題替控制項樹上色：IThemed 自己處理；標準控制項設底色與字色。
    /// Label／Panel 預設透明（沿用父層底色），需要特定顏色的由呼叫端在 ApplyTheme 之後覆寫。
    /// </summary>
    public static void Apply(Control root)
    {
        foreach (Control c in root.Controls)
        {
            switch (c)
            {
                case IThemed t:
                    t.ApplyTheme();
                    break;
                case TextBoxBase tb:
                    tb.BackColor = Raised;
                    tb.ForeColor = Ink;
                    break;
                case ComboBox cb:
                    cb.BackColor = Raised;
                    cb.ForeColor = Ink;
                    break;
            }
            if (c is not IThemed || c is ContainerControl or Panel) Apply(c);
        }
    }

    // MARK: DWM

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    /// <summary>DWMWA_WINDOW_CORNER_PREFERENCE 的值 DWMWCP_ROUND（learn.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwm_window_corner_preference）。</summary>
    private const int DwmwcpRound = 2;
    /// <summary>DWMWA_WINDOW_CORNER_PREFERENCE（learn.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute，值 33）。</summary>
    private const int DwmwaWindowCornerPreference = 33;

    private static int Build => Environment.OSVersion.Version.Build;

    /// <summary>標題列跟著深淺色（DWMWA_USE_IMMERSIVE_DARK_MODE，屬性編號見 ThemeRules.DarkModeAttribute）；失敗就忽略。</summary>
    public static void ApplyTitleBar(Form f)
    {
        if (!f.IsHandleCreated || ThemeRules.DarkModeAttribute(Build) is not { } attr) return;
        var on = Palette.IsDark ? 1 : 0;
        try { _ = DwmSetWindowAttribute(f.Handle, attr, ref on, sizeof(int)); }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException) { }
    }

    /// <summary>Windows 11 的圓角視窗（無邊框的狀態面板用）；Windows 10 不支援就維持直角。</summary>
    public static void ApplyRoundCorners(Form f)
    {
        if (!f.IsHandleCreated || !ThemeRules.SupportsCornerPreference(Build)) return;
        var v = DwmwcpRound;
        try { _ = DwmSetWindowAttribute(f.Handle, DwmwaWindowCornerPreference, ref v, sizeof(int)); }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException) { }
    }

    // MARK: 繪圖小工具

    /// <summary>往上找第一個不透明的底色（透明的 Panel／Label 沿用父層）；都沒有用視窗底色。</summary>
    public static Color OpaqueBack(Control? c)
    {
        for (var p = c?.Parent; p is not null; p = p.Parent)
            if (p.BackColor.A == 255) return p.BackColor;
        return Bg;
    }

    /// <summary>圓角矩形路徑（呼叫端 Dispose）。</summary>
    public static GraphicsPath Round(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        var d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0.5f)
        {
            p.AddRectangle(r);
            return p;
        }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    /// <summary>填滿＋框線的圓角矩形（框線畫在內側半像素，避免被裁掉）。</summary>
    public static void FillRound(Graphics g, Rectangle r, float radius, Color fill, Color? border = null, float borderWidth = 1f)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var rf = new RectangleF(r.X + borderWidth / 2f, r.Y + borderWidth / 2f, r.Width - borderWidth, r.Height - borderWidth);
        using var path = Round(rf, radius);
        using (var b = new SolidBrush(fill)) g.FillPath(b, path);
        if (border is { } bc)
        {
            using var pen = new Pen(bc, borderWidth);
            g.DrawPath(pen, path);
        }
    }

    /// <summary>鍵盤焦點框（2px 強調色，貼著控制項邊緣）。</summary>
    public static void FocusRing(Graphics g, Rectangle r, float radius, float width)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var rf = new RectangleF(r.X + width / 2f, r.Y + width / 2f, r.Width - width, r.Height - width);
        using var path = Round(rf, radius + width);
        using var pen = new Pen(Accent, width);
        g.DrawPath(pen, path);
    }

    /// <summary>文字繪製的共用旗標：單行、不加前後空白、超出以省略號結尾。</summary>
    public const TextFormatFlags TextFlags =
        TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
}
