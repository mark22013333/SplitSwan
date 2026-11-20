namespace SplitSwan.Core;

/// <summary>語意色調對應的圖示（同 Mac 版 DesignSystem 的 SF Symbols），托盤端以 GDI+ 繪製。</summary>
public enum ToneGlyph
{
    /// <summary>打勾圓（checkmark.circle.fill）。</summary>
    CheckCircle,
    /// <summary>時鐘（clock.fill）。</summary>
    Clock,
    /// <summary>三角驚嘆號（exclamationmark.triangle.fill）。</summary>
    Triangle,
    /// <summary>八角叉（xmark.octagon.fill）。</summary>
    Octagon,
    /// <summary>虛線圓（circle.dashed）。</summary>
    DashedCircle,
}

/// <summary>
/// 卡片、狀態卡、狀態徽章的樣式數值（同 Mac 版 DesignSystem：DSSurface、StatusCard、StatusBadge）。
/// 透明度在 Windows 端以「疊在底色上」換算成不透明色（ThemePalette.Mix），子控制項沿用父層底色時才不會露出破綻。
/// </summary>
public static class ToneStyle
{
    /// <summary>一般卡片底：灰（次要文字色）8%。</summary>
    public const double CardFill = 0.08;
    /// <summary>卡片框線：灰或色調 22%。</summary>
    public const double CardBorder = 0.22;
    /// <summary>有色調的卡片（狀態卡、錯誤說明）底：色調 10%。</summary>
    public const double TintFill = 0.10;
    /// <summary>狀態卡左側圓形圖示的底：色調 14%。</summary>
    public const double IconFill = 0.14;
    /// <summary>狀態徽章的膠囊底：色調 15%。</summary>
    public const double BadgeFill = 0.15;
    /// <summary>卡片圓角（邏輯像素）。</summary>
    public const int CardRadius = 10;
    /// <summary>卡片內距。</summary>
    public const int CardPadding = 14;
    /// <summary>狀態卡內距。</summary>
    public const int StatusPadding = 16;
    /// <summary>卡片內各列的間距。</summary>
    public const int RowSpacing = 10;
    /// <summary>狀態卡左側圓形圖示的直徑。</summary>
    public const int StatusIconSize = 52;

    /// <summary>色調對應的圖示。</summary>
    public static ToneGlyph Glyph(StatusTone tone) => tone switch
    {
        StatusTone.Ok => ToneGlyph.CheckCircle,
        StatusTone.Working => ToneGlyph.Clock,
        StatusTone.Warn => ToneGlyph.Triangle,
        StatusTone.Bad => ToneGlyph.Octagon,
        _ => ToneGlyph.DashedCircle,
    };

    /// <summary>中性色調不上色：卡片用一般底色，圖示與文字用次要文字色。</summary>
    public static bool IsNeutral(StatusTone tone) => tone == StatusTone.Idle;
}

/// <summary>
/// 動畫時間與曲線（同 Mac 版 DSMotion、ShakeEffect、StaggeredAppear）。全部是純函式，托盤端每一格呼叫一次。
/// 「減少動態效果」（Windows 設定 → 協助工具 → 視覺效果 → 動畫效果關閉）時，轉場改成短淡入或不動。
/// </summary>
public static class Motion
{
    /// <summary>一般轉場秒數（ease-in-out）。</summary>
    public const double Duration = 0.25;
    /// <summary>減少動態效果時的淡入秒數。</summary>
    public const double ReducedDuration = 0.15;
    /// <summary>驗證失敗搖晃的總秒數。</summary>
    public const double ShakeDuration = 0.3;
    /// <summary>搖晃的水平幅度（邏輯像素）。</summary>
    public const double ShakeTravel = 6;
    /// <summary>搖晃次數。</summary>
    public const int ShakeCount = 3;
    /// <summary>交錯出場：每一項延遲幾秒。</summary>
    public const double StaggerStep = 0.04;
    /// <summary>交錯出場：最多延遲幾秒（清單再長也不拖慢操作）。</summary>
    public const double StaggerMax = 0.25;
    /// <summary>交錯出場：由下往上滑入的距離（邏輯像素）。</summary>
    public const double StaggerOffset = 6;
    /// <summary>吐司停留秒數。</summary>
    public const double ToastSeconds = 2.5;
    /// <summary>吐司離視窗底部的距離（邏輯像素）：浮在設定頁底部儲存列之上。</summary>
    public const int ToastBottomInset = 64;
    /// <summary>載入按鈕完成後打勾停留秒數。</summary>
    public const double DoneSeconds = 1.2;

    /// <summary>一般轉場的秒數：減少動態效果時改用短淡入。</summary>
    public static double TransitionSeconds(bool reduced) => reduced ? ReducedDuration : Duration;

    /// <summary>經過時間換成 0～1 的進度（duration ≤ 0 時直接完成）。</summary>
    public static double Progress(double elapsedSeconds, double durationSeconds) =>
        durationSeconds <= 0 ? 1 : Math.Clamp(elapsedSeconds / durationSeconds, 0, 1);

    /// <summary>ease-in-out（三次）：0→0、0.5→0.5、1→1，兩端平緩。</summary>
    public static double EaseInOut(double t)
    {
        t = Math.Clamp(t, 0, 1);
        return t < 0.5 ? 4 * t * t * t : 1 - Math.Pow(-2 * t + 2, 3) / 2;
    }

    /// <summary>
    /// 搖晃的水平位移（同 Mac 版 ShakeEffect：travel × sin(進度 × π × 次數 × 2)），進度 0～1；開始與結束都是 0。
    /// 減少動態效果時一律 0（只靠紅字提示）。
    /// </summary>
    public static double ShakeOffset(double progress, bool reduced, double travel = ShakeTravel, int shakes = ShakeCount)
    {
        if (reduced || progress <= 0 || progress >= 1) return 0;
        return travel * Math.Sin(progress * Math.PI * shakes * 2);
    }

    /// <summary>
    /// 搖晃時內容的左右內距：以 ShakeOffset 位移，左加右減，總寬不變，外框與版面都不動。
    /// 幅度不超過原本較小的一邊內距，內距永遠不會變成負的（負值會被版面配置當成 0）。
    /// </summary>
    public static (int Left, int Right) ShakePadding(int baseLeft, int baseRight, double progress, bool reduced, double travel = ShakeTravel)
    {
        var amplitude = Math.Min(travel, Math.Min(baseLeft, baseRight));
        if (amplitude <= 0) return (baseLeft, baseRight);
        var offset = (int)Math.Round(ShakeOffset(progress, reduced, amplitude));
        return (baseLeft + offset, baseRight - offset);
    }

    /// <summary>交錯出場第 index 項（0 起算）的延遲秒數：每項 0.04 秒、最多 0.25 秒；減少動態效果時不延遲。</summary>
    public static double StaggerDelay(int index, bool reduced) =>
        reduced || index <= 0 ? 0 : Math.Min(index * StaggerStep, StaggerMax);

    /// <summary>
    /// 交錯出場第 index 項在 elapsed 秒時的狀態：不透明度 0～1 與往下的位移（邏輯像素，最後回到 0）。
    /// 減少動態效果時不位移，只淡入。
    /// </summary>
    public static (double Opacity, double OffsetY) StaggerFrame(int index, double elapsedSeconds, bool reduced)
    {
        var p = EaseInOut(Progress(elapsedSeconds - StaggerDelay(index, reduced), TransitionSeconds(reduced)));
        return (p, reduced ? 0 : StaggerOffset * (1 - p));
    }

    /// <summary>整份清單全部出場完成要幾秒（最後一項的延遲＋轉場時間）。</summary>
    public static double StaggerTotal(int count, bool reduced) =>
        count <= 0 ? 0 : StaggerDelay(count - 1, reduced) + TransitionSeconds(reduced);
}

/// <summary>
/// 圓角卡片的幾何判斷（托盤端 CardPanel 畫背景時用）。座標與尺寸都是裝置像素。
/// </summary>
public static class CardGeometry
{
    /// <summary>框線與抗鋸齒邊緣佔用的寬度：離外緣這麼近的像素不算卡片內部。</summary>
    public const int EdgeAllowance = 2;

    /// <summary>
    /// 重繪範圍是否完全落在卡片內部：不碰外緣的框線，也不碰四個角落 radius×radius 的圓角區。
    /// 是的話整塊都是卡片底色，可以一次填色，不必先清成父層底色再畫圓角。
    /// </summary>
    public static bool ClipInsideBody(int x, int y, int width, int height, int cardWidth, int cardHeight, int radius)
    {
        if (width <= 0 || height <= 0) return true;
        var right = x + width;
        var bottom = y + height;
        if (x < EdgeAllowance || y < EdgeAllowance || right > cardWidth - EdgeAllowance || bottom > cardHeight - EdgeAllowance)
            return false;
        var r = Math.Max(radius, EdgeAllowance);
        bool Hits(int cx, int cy) => x < cx + r && right > cx && y < cy + r && bottom > cy;
        return !(Hits(0, 0) || Hits(cardWidth - r, 0) || Hits(0, cardHeight - r) || Hits(cardWidth - r, cardHeight - r));
    }
}
