namespace SplitSwan.Core;

/// <summary>DropDetector 每次更新的判定結果。</summary>
public enum DropAction
{
    /// <summary>不用發通知</summary>
    None,
    /// <summary>想連線但沒連上已達門檻：發「已斷線」通知</summary>
    NotifyDrop,
    /// <summary>發過斷線通知後又接回：發「已恢復連線」通知</summary>
    NotifyRestore,
}

/// <summary>
/// 非預期斷線通知的判定，移植自 Mac 版 VPNController.swift:64-115 的 DropDetector（純邏輯，不碰系統狀態）。
/// 每次狀態更新餵一次：
/// - 想連線但沒連上持續 ≥ threshold 才發斷線通知，每次掉線只發一次；
/// - 沒有網路時暫停計時（這段時間不算掉線，恢復後重新計時；已發過的斷線通知保留）；
/// - 發過斷線通知後接回，發一次恢復通知；
/// - 使用者不想連線（按了斷線）時重置，不發任何通知。
/// 通知設定關閉時，呼叫端不要發通知並呼叫 Reset()（等同 Mac 版 enabled = false）。
/// </summary>
public sealed class DropDetector
{
    private readonly TimeSpan _threshold;
    private DateTimeOffset? _downSince;   // 第一次觀察到「想連線但沒連上」的時間
    private bool _dropNotified;           // 這次掉線已發過通知

    public DropDetector(TimeSpan threshold)
    {
        if (threshold < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(threshold), "門檻不可為負數");
        _threshold = threshold;
    }

    /// <summary>門檻（Mac 版固定 30 秒）。</summary>
    public TimeSpan Threshold => _threshold;
    /// <summary>目前掉線計時的起點；沒有在計時為 null。</summary>
    public DateTimeOffset? DownSince => _downSince;
    /// <summary>這次掉線是否已發過斷線通知。</summary>
    public bool DropNotified => _dropNotified;

    /// <summary>true＝這一刻該發斷線通知（等同 Evaluate(...) == NotifyDrop）。</summary>
    public bool Update(DateTimeOffset now, bool wantConnected, bool isConnected, bool networkAvailable) =>
        Evaluate(now, wantConnected, isConnected, networkAvailable) == DropAction.NotifyDrop;

    /// <summary>完整判定（含恢復通知）。</summary>
    public DropAction Evaluate(DateTimeOffset now, bool wantConnected, bool isConnected, bool networkAvailable)
    {
        if (!wantConnected) { Reset(); return DropAction.None; }
        if (isConnected)
        {
            var notified = _dropNotified;
            Reset();
            return notified ? DropAction.NotifyRestore : DropAction.None;
        }
        if (!networkAvailable) { _downSince = null; return DropAction.None; }
        _downSince ??= now;
        if (!_dropNotified && now - _downSince.Value >= _threshold)
        {
            _dropNotified = true;
            return DropAction.NotifyDrop;
        }
        return DropAction.None;
    }

    /// <summary>使用者手動操作（連線／斷線）時呼叫：清掉計時與已通知狀態。</summary>
    public void Reset()
    {
        _downSince = null;
        _dropNotified = false;
    }

    /// <summary>
    /// 睡眠喚醒時呼叫：睡眠期間不算進門檻，從喚醒後重新計時；
    /// 已發過的斷線通知保留，之後接回仍會發恢復通知（Mac 版 restartGrace）。
    /// </summary>
    public void RestartGrace() => _downSince = null;

    // 通知文字（Mac 版 DropDetector 的 dropTitle／dropBody／restoreTitle／restoreBody）

    public static string DropTitle(string app) => $"{app} 已斷線";
    public static string DropBody(TimeSpan threshold) => $"VPN 中斷超過 {(int)threshold.TotalSeconds} 秒，正在自動重連";
    public static string RestoreTitle(string app) => $"{app} 已恢復連線";

    /// <summary>connection 是引擎回報的連線名稱（例：vpn2）；取不到台號就省略。</summary>
    public static string RestoreBody(string? connection)
    {
        if (connection is null || !connection.StartsWith("vpn", StringComparison.OrdinalIgnoreCase) || connection.Length <= 3)
            return "VPN 已重新連上";
        return $"{connection.ToUpperInvariant()} 已重新連上";
    }
}
