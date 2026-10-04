using System.Drawing;

namespace SplitSwan.Tray;

/// <summary>
/// App 圖示（與 Mac 版同圖，windows/tools/make-ico.sh 產生的 app.ico）。
/// exe 的圖示由 csproj 的 ApplicationIcon 設定；這裡從嵌入資源讀同一個檔，給各視窗的 Form.Icon 用。
/// </summary>
internal static class AppIcon
{
    private static Icon? _icon;
    private static bool _loaded;

    /// <summary>讀不到（理論上不會發生）時為 null，視窗沿用 WinForms 預設圖示。</summary>
    public static Icon? Get()
    {
        if (_loaded) return _icon;
        _loaded = true;
        try
        {
            using var s = typeof(AppIcon).Assembly.GetManifestResourceStream("SplitSwan.app.ico");
            if (s is not null) _icon = new Icon(s);
        }
        catch (Exception ex) when (ex is ArgumentException or IOException)
        {
            AppLog.Error($"讀取 App 圖示失敗：{ex.Message}");
        }
        return _icon;
    }

    /// <summary>套用到視窗（不轉移擁有權：同一個 Icon 物件給所有視窗共用，App 結束才釋放）。</summary>
    public static void Apply(Form f)
    {
        if (Get() is { } icon) f.Icon = icon;
    }
}
