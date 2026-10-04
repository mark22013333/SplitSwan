namespace SplitSwan.Core;

/// <summary>螢幕上的矩形（像素，可為負座標：多螢幕時主螢幕左側或上方的螢幕）。</summary>
public readonly record struct PxRect(int X, int Y, int Width, int Height)
{
    public int Right => X + Width;
    public int Bottom => Y + Height;
}

/// <summary>螢幕上的點（像素）。</summary>
public readonly record struct PxPoint(int X, int Y);

/// <summary>工作列在螢幕的哪一邊。</summary>
public enum TaskbarEdge { Bottom, Top, Left, Right }

/// <summary>
/// 面板開啟當下記下的錨點：所在螢幕、（已扣掉自動隱藏工作列的）可用區域、游標、工作列所在邊。
/// 面板開著時大小改變（例如狀態從已連線變成連線中），一律用同一個錨點重算，不再讀當下的游標，
/// 面板就不會跟著游標跳到別的位置或別的邊。
/// </summary>
public readonly record struct FlyoutAnchor(PxRect Bounds, PxRect WorkingArea, PxPoint Cursor, TaskbarEdge Edge);

/// <summary>
/// 狀態面板（左鍵托盤圖示彈出）的位置計算：貼齊工作列所在邊、靠近托盤圖示（游標位置）。
/// 純函式：輸入螢幕 Bounds、WorkingArea、游標、面板大小，輸出面板左上角。
/// </summary>
public static class FlyoutPlacement
{
    /// <summary>
    /// 工作列在哪一邊：比較 WorkingArea 與 Bounds 哪一邊被讓出來。
    /// 工作列自動隱藏時 WorkingArea 等於 Bounds，改用游標最靠近的那一邊（點托盤圖示時游標就在工作列上）。
    /// 兩邊都讓出時（例如另有停靠的工具列），讓出最多的那邊。
    /// </summary>
    public static TaskbarEdge DetectEdge(PxRect bounds, PxRect workingArea, PxPoint cursor)
    {
        var gaps = new (TaskbarEdge Edge, int Gap)[]
        {
            (TaskbarEdge.Bottom, bounds.Bottom - workingArea.Bottom),
            (TaskbarEdge.Top, workingArea.Y - bounds.Y),
            (TaskbarEdge.Left, workingArea.X - bounds.X),
            (TaskbarEdge.Right, bounds.Right - workingArea.Right),
        };
        var best = gaps.MaxBy(g => g.Gap);
        if (best.Gap > 0) return best.Edge;

        // 自動隱藏：游標離哪一邊最近（同距離時依 下→上→左→右，Windows 預設工作列在下）
        var dist = new (TaskbarEdge Edge, int D)[]
        {
            (TaskbarEdge.Bottom, Math.Abs(bounds.Bottom - cursor.Y)),
            (TaskbarEdge.Top, Math.Abs(cursor.Y - bounds.Y)),
            (TaskbarEdge.Left, Math.Abs(cursor.X - bounds.X)),
            (TaskbarEdge.Right, Math.Abs(bounds.Right - cursor.X)),
        };
        return dist.MinBy(d => d.D).Edge;
    }

    /// <summary>
    /// 面板左上角。工作列在下／上：水平置中於游標、垂直貼齊工作列內側；在左／右：垂直置中於游標、水平貼齊工作列內側。
    /// 一律夾在 WorkingArea 內（留 margin）；面板比可用空間還大時對齊可用空間的左／上緣（至少看得到標題與狀態）。
    /// </summary>
    /// <param name="margin">與工作列、螢幕邊緣的間距（像素，呼叫端依 DPI 換算）。</param>
    public static PxPoint Place(PxRect bounds, PxRect workingArea, PxPoint cursor, int width, int height, int margin) =>
        Place(new FlyoutAnchor(bounds, workingArea, cursor, DetectEdge(bounds, workingArea, cursor)), width, height, margin);

    /// <summary>
    /// 開面板時建立錨點：自動隱藏工作列時先用工作列矩形扣出可用區域（<see cref="EffectiveWorkingArea"/>），再判斷工作列在哪一邊。
    /// </summary>
    /// <param name="taskbar">系統工作列矩形（SHAppBarMessage ABM_GETTASKBARPOS）；取不到為 null。</param>
    /// <param name="autoHide">工作列是否自動隱藏（ABM_GETSTATE 含 ABS_AUTOHIDE）。</param>
    public static FlyoutAnchor CreateAnchor(PxRect bounds, PxRect workingArea, PxPoint cursor, PxRect? taskbar, bool autoHide)
    {
        var wa = EffectiveWorkingArea(bounds, workingArea, taskbar, autoHide);
        return new FlyoutAnchor(bounds, wa, cursor, DetectEdge(bounds, wa, cursor));
    }

    /// <summary>
    /// 自動隱藏工作列時的可用區域：Screen.WorkingArea 在自動隱藏時回傳整個螢幕
    /// （learn.microsoft.com/dotnet/api/system.windows.forms.screen.workingarea），工作列滑出時會蓋住貼底的面板，
    /// 所以讓出工作列的厚度（矩形較短的一邊）。工作列的位置與厚度來自 ABM_GETTASKBARPOS
    /// （learn.microsoft.com/windows/win32/shell/abm-gettaskbarpos），是否自動隱藏來自 ABM_GETSTATE
    /// （learn.microsoft.com/windows/win32/shell/abm-getstate）。
    /// 下列情況維持原本的 workingArea：不是自動隱藏、取不到工作列矩形、工作列不在這個螢幕上（ABM_GETTASKBARPOS 只回報主工作列）、
    /// WorkingArea 已經比螢幕小（系統已經讓出空間）、矩形不合理（厚度 ≤ 0 或超過螢幕一半）。
    /// </summary>
    public static PxRect EffectiveWorkingArea(PxRect bounds, PxRect workingArea, PxRect? taskbar, bool autoHide)
    {
        if (!autoHide || taskbar is not { } tb || workingArea != bounds) return workingArea;
        if (tb.Width <= 0 || tb.Height <= 0) return workingArea;
        // 工作列要跟這個螢幕重疊（隱藏時通常只剩 2px 露在螢幕內）
        var ix = Math.Min(tb.Right, bounds.Right) - Math.Max(tb.X, bounds.X);
        var iy = Math.Min(tb.Bottom, bounds.Bottom) - Math.Max(tb.Y, bounds.Y);
        if (ix <= 0 || iy <= 0) return workingArea;

        var horizontal = tb.Width >= tb.Height;
        var thickness = horizontal ? tb.Height : tb.Width;
        if (thickness > (horizontal ? bounds.Height : bounds.Width) / 2) return workingArea;
        var cy2 = tb.Y * 2 + tb.Height;           // 中心點 ×2，避免整數除法誤差
        var cx2 = tb.X * 2 + tb.Width;
        if (horizontal)
            return cy2 < bounds.Y * 2 + bounds.Height
                ? new PxRect(workingArea.X, workingArea.Y + thickness, workingArea.Width, workingArea.Height - thickness)   // 上
                : new PxRect(workingArea.X, workingArea.Y, workingArea.Width, workingArea.Height - thickness);             // 下
        return cx2 < bounds.X * 2 + bounds.Width
            ? new PxRect(workingArea.X + thickness, workingArea.Y, workingArea.Width - thickness, workingArea.Height)       // 左
            : new PxRect(workingArea.X, workingArea.Y, workingArea.Width - thickness, workingArea.Height);                 // 右
    }

    /// <summary>用開啟時記下的錨點計算面板左上角（面板大小改變時重算也用同一個錨點）。</summary>
    public static PxPoint Place(FlyoutAnchor anchor, int width, int height, int margin)
    {
        margin = Math.Max(0, margin);
        var (workingArea, cursor, edge) = (anchor.WorkingArea, anchor.Cursor, anchor.Edge);
        int x, y;
        switch (edge)
        {
            case TaskbarEdge.Top:
                x = cursor.X - width / 2;
                y = workingArea.Y + margin;
                break;
            case TaskbarEdge.Left:
                x = workingArea.X + margin;
                y = cursor.Y - height / 2;
                break;
            case TaskbarEdge.Right:
                x = workingArea.Right - margin - width;
                y = cursor.Y - height / 2;
                break;
            default:
                x = cursor.X - width / 2;
                y = workingArea.Bottom - margin - height;
                break;
        }
        return new PxPoint(
            Clamp(x, workingArea.X + margin, workingArea.Right - margin - width),
            Clamp(y, workingArea.Y + margin, workingArea.Bottom - margin - height));
    }

    /// <summary>夾在 [min, max]；max &lt; min（面板太大）時取 min。</summary>
    private static int Clamp(int v, int min, int max) => max < min ? min : Math.Clamp(v, min, max);
}

/// <summary>
/// 「再點一次托盤圖示就關閉」的判斷：點托盤圖示時面板會先失去焦點而關閉，接著才收到點擊事件；
/// 若剛因失去焦點而關閉（間隔很短），這次點擊視為「關閉」而不是「重新開啟」。
/// </summary>
public static class FlyoutToggle
{
    /// <summary>失去焦點關閉後多久內的點擊算「關閉」。</summary>
    public static readonly TimeSpan ReopenGuard = TimeSpan.FromMilliseconds(400);

    /// <summary>
    /// 以「按下滑鼠」的時間判斷（審查發現：按住超過 400ms 才放開時，舊判斷會先因失去焦點關閉、放開時又重開）：
    /// - 放開時面板還開著 → 關閉；
    /// - 按下時面板開著 → 這次點擊是要關它（失去焦點已先關了），不重開；
    /// - 失去焦點關閉的時間落在「按下前 ReopenGuard 內」到「放開」之間 → 是這次點擊造成的，不重開；
    /// - 其他 → 開啟。
    /// </summary>
    /// <param name="visibleNow">放開（Click）當下面板是否還開著。</param>
    /// <param name="visibleAtDown">按下滑鼠當下面板是否開著；沒有收到按下事件時傳 false。</param>
    /// <param name="downAt">按下滑鼠的時間；沒有收到按下事件時為 null（改用 now）。</param>
    public static bool ShouldOpenOnClick(bool visibleNow, bool visibleAtDown, DateTimeOffset? downAt,
        DateTimeOffset? lastDeactivatedClose, DateTimeOffset now)
    {
        if (visibleNow || visibleAtDown) return false;
        if (lastDeactivatedClose is not { } closed) return true;
        var down = downAt ?? now;
        if (down > now) down = now;
        return !(closed >= down - ReopenGuard && closed <= now);
    }

    /// <param name="visible">點擊當下面板是否還開著。</param>
    /// <param name="lastDeactivatedClose">上一次因失去焦點而關閉的時間；沒有為 null。</param>
    public static bool ShouldOpen(bool visible, DateTimeOffset? lastDeactivatedClose, DateTimeOffset now)
    {
        if (visible) return false;
        if (lastDeactivatedClose is not { } t) return true;
        var since = now - t;
        return since < TimeSpan.Zero || since >= ReopenGuard;
    }
}
