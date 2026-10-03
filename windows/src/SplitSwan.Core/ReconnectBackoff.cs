namespace SplitSwan.Core;

/// <summary>
/// 自動重連的退避間隔（托盤 App 用）：30 秒 → 60 → 120 → 240 → 之後固定 5 分鐘。
/// Mac 版是 5／15／30／60 秒；Windows 版每次 connect 都會重跑 WSL 與路由設定、成本較高，所以拉長。
/// </summary>
public static class ReconnectBackoff
{
    /// <summary>上限。</summary>
    public static readonly TimeSpan Max = TimeSpan.FromMinutes(5);

    private static readonly TimeSpan[] Steps =
    [
        TimeSpan.FromSeconds(30),
        TimeSpan.FromSeconds(60),
        TimeSpan.FromSeconds(120),
        TimeSpan.FromSeconds(240),
    ];

    /// <summary>第 step 次（從 0 起）重試前要等多久；負數視為 0。</summary>
    public static TimeSpan Delay(int step)
    {
        if (step < 0) step = 0;
        return step < Steps.Length ? Steps[step] : Max;
    }
}
