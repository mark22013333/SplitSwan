namespace SplitSwan.Core;

/// <summary>一次 brief 輪詢的判讀結果。</summary>
public enum BriefKind
{
    /// <summary>確定已連線（@@RESULT=ok 且 @@STATE=up）</summary>
    Up,
    /// <summary>確定沒有通道（@@RESULT=ok 且 @@STATE=down）——唯一算「斷線」的結果</summary>
    Down,
    /// <summary>查不到：@@STATE=unknown、@@RESULT 不是 ok、托盤端逾時、或沒有 STATE。不代表斷線。</summary>
    Unknown,
}

/// <summary>
/// brief 輪詢的「查不到」計數（契約 1 brief 段，2026-10-04 第二次修訂）：
/// 查不到時沿用上一次狀態、不餵 DropDetector，**永遠不因查不到判定斷線或觸發自動重建**；
/// 連續 3 次以上只把狀態標成「不明」。只有引擎明確回 @@STATE=down 才算斷線。
/// 理由：brief 要啟動兩次 wsl.exe，機器持續忙碌時可能每次都逾時；若把「查不到」當成斷線，
/// 會反覆拆掉其實正常的通道重建、反覆發假的斷線通知。
/// </summary>
public sealed class BriefTracker
{
    /// <summary>連續幾次查不到就標成「狀態不明」。</summary>
    public const int UnknownLimit = 3;

    private int _unknownCount;

    /// <summary>目前連續查不到的次數。</summary>
    public int ConsecutiveUnknown => _unknownCount;

    /// <summary>連續查不到已達上限：顯示「狀態不明」（不代表斷線）。</summary>
    public bool IsStateUnknown => _unknownCount >= UnknownLimit;

    /// <summary>
    /// 判讀引擎輸出：只有 @@RESULT=ok 且 @@STATE 是 up／down 才是確定的結果；
    /// timedOut（托盤端逾時）一律是 Unknown。
    /// </summary>
    public static BriefKind Classify(IReadOnlyDictionary<string, string> kv, bool timedOut = false)
    {
        ArgumentNullException.ThrowIfNull(kv);
        if (timedOut) return BriefKind.Unknown;
        if (!EngineOutput.Result(kv).Ok) return BriefKind.Unknown;
        if (!kv.TryGetValue("STATE", out var st)) return BriefKind.Unknown;
        return st switch
        {
            "up" => BriefKind.Up,
            "down" => BriefKind.Down,
            _ => BriefKind.Unknown,
        };
    }

    /// <summary>
    /// 餵一次判讀結果。Up／Down 把計數歸零；Unknown 累加計數。
    /// 回傳 true＝這一次剛好達到上限（呼叫端寫一行「狀態不明」記錄，之後不重複寫）。
    /// 不論計數多少，Unknown 都不會被轉成 Down。
    /// </summary>
    public bool Observe(BriefKind kind)
    {
        if (kind != BriefKind.Unknown)
        {
            _unknownCount = 0;
            return false;
        }
        _unknownCount++;
        return _unknownCount == UnknownLimit;
    }

    /// <summary>使用者操作或連線動作完成後歸零（之後的狀態以新的查詢為準）。</summary>
    public void Reset() => _unknownCount = 0;
}
