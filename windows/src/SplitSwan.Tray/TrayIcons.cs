using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 托盤圖示：依使用者選的樣式（TrayIconStyle，對應 Mac 版 MenuBarIconStyle）程式繪製，不放二進位素材。
/// - 字形樣式用系統圖示字型：優先 Segoe Fluent Icons（Windows 11），沒有就用 Segoe MDL2 Assets（Windows 10）；
///   字碼由 Core 的 TrayIconCatalog 提供（兩套字型都有的字碼）。
/// - 「VPN 字樣」自己畫：已連線是實心底反白字，其他是外框字（同 Mac）。
/// - 顏色：開啟「已連線時顯示綠色」且已連線用綠色；其他依工作列深淺色用黑或白（對應 Mac 的 template 圖）。
/// - 狀態不明：用異常的字形畫成半透明（理由見 TrayIconRules.ToIconState）。
/// 圖形一律轉成路徑後縮放置中，不依賴字型的行高與基線，在各種 DPI 下都填滿圖示。
/// </summary>
internal sealed class TrayIcons : IDisposable
{
    private const string ThemeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private static readonly Color GreenColor = Color.FromArgb(0x2E, 0xB8, 0x4F);
    private static readonly string[] FontCandidates = ["Segoe Fluent Icons", "Segoe MDL2 Assets"];
    private static string? _fontName;
    private static bool _fontResolved;

    private readonly Dictionary<TrayState, Icon> _icons = new();
    private readonly List<IntPtr> _handles = new();
    private (TrayIconStyle Style, bool Green, bool Light)? _key;

    /// <summary>目前用的圖示字型名稱；兩套都沒有時為 null（改畫「VPN」字樣）。</summary>
    public static string? IconFontName
    {
        get
        {
            if (_fontResolved) return _fontName;
            using var installed = new InstalledFontCollection();
            var names = installed.Families.Select(f => f.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
            _fontName = FontCandidates.FirstOrDefault(names.Contains);
            _fontResolved = true;
            AppLog.Info(_fontName is null ? "找不到 Segoe Fluent Icons／Segoe MDL2 Assets，托盤圖示改用「VPN」字樣" : $"托盤圖示字型：{_fontName}");
            return _fontName;
        }
    }

    /// <summary>工作列是否為淺色（登錄 SystemUsesLightTheme＝1）；讀不到當深色。</summary>
    public static bool ReadLightTaskbar()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(ThemeKey);
            return TrayIconRules.IsLightTaskbar(k?.GetValue("SystemUsesLightTheme"));
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    public static Color InkColor(TrayIconInk ink) => ink switch
    {
        TrayIconInk.Green => GreenColor,
        TrayIconInk.Black => Color.Black,
        _ => Color.White,
    };

    /// <summary>樣式、綠色選項或工作列深淺色有變才重畫；回傳是否重畫了。</summary>
    public bool Update(TrayIconStyle style, bool green, bool lightTaskbar)
    {
        var key = (style, green, lightTaskbar);
        if (_key == key) return false;
        ReleaseIcons();
        var size = Math.Max(16, SystemInformation.SmallIconSize.Width);
        foreach (var state in Enum.GetValues<TrayState>())
        {
            var iconState = TrayIconRules.ToIconState(state);
            var color = InkColor(TrayIconRules.Ink(iconState, green, lightTaskbar));
            using var bmp = Render(style, state, color, size);
            var h = bmp.GetHicon();
            _handles.Add(h);
            _icons[state] = Icon.FromHandle(h);
        }
        _key = key;
        return true;
    }

    public Icon this[TrayState state] => _icons[state];

    /// <summary>畫一個圖示（托盤與設定頁預覽共用）。呼叫端負責 Dispose。</summary>
    public static Bitmap Render(TrayIconStyle style, TrayState state, Color color, int size)
    {
        if (TrayIconRules.IsDimmed(state)) color = Color.FromArgb(150, color);
        var iconState = TrayIconRules.ToIconState(state);
        var bmp = new Bitmap(size, size);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.Clear(Color.Transparent);

        var glyph = TrayIconCatalog.Glyph(style, iconState);
        var font = IconFontName;
        if (glyph is not null && font is not null)
            DrawGlyph(g, glyph, font, color, size);
        else
            DrawText(g, TrayIconRules.TextLabel(state), TrayIconRules.TextFilled(iconState), color, size);
        return bmp;
    }

    private static void DrawGlyph(Graphics g, string glyph, string fontName, Color color, int size)
    {
        using var family = new FontFamily(fontName);
        using var path = new GraphicsPath();
        path.AddString(glyph, family, (int)FontStyle.Regular, 100f, PointF.Empty, StringFormat.GenericTypographic);
        FitInto(path, new RectangleF(0, 0, size, size), size * 0.06f);
        using var brush = new SolidBrush(color);
        g.FillPath(brush, path);
    }

    /// <summary>「VPN 字樣」：已連線＝實心圓角框、字挖空；其他＝圓角外框＋實心字（同 Mac textImage）。</summary>
    private static void DrawText(Graphics g, string label, bool filled, Color color, int size)
    {
        float s = size;
        var stroke = Math.Max(1f, s / 16f);
        var box = new RectangleF(stroke / 2, s * 0.18f, s - stroke, s * 0.64f);
        using var boxPath = RoundedRect(box, s * 0.14f);

        using var family = new FontFamily("Segoe UI");
        using var text = new GraphicsPath();
        text.AddString(label, family, (int)FontStyle.Bold, 100f, PointF.Empty, StringFormat.GenericTypographic);
        FitInto(text, box, Math.Max(1.5f, s * 0.12f));

        if (filled)
        {
            // 框與字放在同一個路徑，Alternate 填色規則讓字的部分變成洞
            using var combined = (GraphicsPath)boxPath.Clone();
            combined.FillMode = FillMode.Alternate;
            combined.AddPath(text, false);
            using var brush = new SolidBrush(color);
            g.FillPath(brush, combined);
        }
        else
        {
            using var pen = new Pen(color, stroke);
            g.DrawPath(pen, boxPath);
            using var brush = new SolidBrush(color);
            g.FillPath(brush, text);
        }
    }

    /// <summary>把路徑等比縮放、置中到 target 內（四邊留 pad）。</summary>
    private static void FitInto(GraphicsPath path, RectangleF target, float pad)
    {
        var b = path.GetBounds();
        if (b.Width <= 0 || b.Height <= 0) return;
        var w = target.Width - pad * 2;
        var h = target.Height - pad * 2;
        var scale = Math.Min(w / b.Width, h / b.Height);
        using var m = new Matrix();
        m.Translate(target.X + target.Width / 2, target.Y + target.Height / 2);
        m.Scale(scale, scale);
        m.Translate(-(b.X + b.Width / 2), -(b.Y + b.Height / 2));
        path.Transform(m);
    }

    private static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    private void ReleaseIcons()
    {
        foreach (var i in _icons.Values) i.Dispose();
        foreach (var h in _handles) DestroyIcon(h);
        _icons.Clear();
        _handles.Clear();
        _key = null;
    }

    public void Dispose() => ReleaseIcons();
}
