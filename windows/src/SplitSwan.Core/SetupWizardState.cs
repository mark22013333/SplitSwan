using System.Text.Json;
using System.Text.Json.Nodes;

namespace SplitSwan.Core;

/// <summary>首次設定精靈的 6 個步驟（契約 6）。</summary>
public enum WizardStep
{
    SystemCheck = 0,
    InstallWsl = 1,
    ImportDistro = 2,
    SetupStrongSwan = 3,
    Configure = 4,
    TestConnection = 5,
}

public enum WizardStepStatus { NotStarted, Running, Done, Skipped, Failed }

/// <summary>
/// 精靈狀態（存 %LOCALAPPDATA%\SplitSwan\wizard.json，重開機後從中斷處繼續）。純邏輯，不碰檔案與 UI。
/// 規則：
/// - 步驟依序執行；目前步驟完成（Done／Skipped）才能往下一步。
/// - 某一步「實際執行」完成（不是偵測到已完成而略過）時，之後與 WSL 相關的步驟要重做
///   （例：重新匯入發行版後 strongSwan 要重裝）；設定步驟（Configure）不受影響，測試連線一律重做。
/// - 重開機前執行中的步驟，讀回來時當成未開始（程序已被結束）。
/// - 每次開精靈，系統檢查、安裝 WSL、匯入發行版、設定這幾步會重新偵測（便宜、且環境可能變了）；
///   安裝 strongSwan 與測試連線沿用已完成的紀錄（重跑很久）。
/// </summary>
public sealed class SetupWizardState
{
    private const int Version = 1;
    public static readonly IReadOnlyList<WizardStep> Steps = Enum.GetValues<WizardStep>();

    private readonly Dictionary<WizardStep, WizardStepStatus> _status = Steps.ToDictionary(s => s, _ => WizardStepStatus.NotStarted);
    private readonly Dictionary<WizardStep, string> _errors = new();

    public WizardStep Current { get; private set; } = WizardStep.SystemCheck;

    /// <summary>步驟 2 要求重開機、使用者還沒重開。</summary>
    public bool RebootPending { get; private set; }

    /// <summary>要求重開機當下的開機時間（用來判斷之後是否真的重開過）。</summary>
    public DateTimeOffset? RebootRequestedBootTime { get; private set; }

    /// <summary>精靈執行過 wsl --install 之後已確認重開過機（步驟 2 判斷「狀態查不到」時用）。</summary>
    public bool RebootedSinceInstall { get; private set; }

    /// <summary>6 步都完成。</summary>
    public bool Completed => Steps.All(IsFinished);

    public WizardStepStatus StatusOf(WizardStep s) => _status[s];
    public string? ErrorOf(WizardStep s) => _errors.GetValueOrDefault(s);
    public bool IsFinished(WizardStep s) => _status[s] is WizardStepStatus.Done or WizardStepStatus.Skipped;

    /// <summary>目前步驟完成，可以按「下一步」。</summary>
    public bool CanGoNext => IsFinished(Current) && Next(Current) is not null;
    public bool CanGoBack => Previous(Current) is not null && _status[Current] != WizardStepStatus.Running;

    public static WizardStep? Next(WizardStep s) => s == WizardStep.TestConnection ? null : s + 1;
    public static WizardStep? Previous(WizardStep s) => s == WizardStep.SystemCheck ? null : s - 1;

    /// <summary>每次開精靈都重新偵測的步驟（見類別說明）。</summary>
    public static bool RecheckOnOpen(WizardStep s) => s is not (WizardStep.SetupStrongSwan or WizardStep.TestConnection);

    /// <summary>步驟中文名稱（左側清單）。</summary>
    public static string Title(WizardStep s) => s switch
    {
        WizardStep.SystemCheck => "系統檢查",
        WizardStep.InstallWsl => "安裝 WSL",
        WizardStep.ImportDistro => "下載並匯入 Ubuntu",
        WizardStep.SetupStrongSwan => "安裝 strongSwan",
        WizardStep.Configure => "VPN 設定",
        WizardStep.TestConnection => "測試連線",
        _ => s.ToString(),
    };

    /// <summary>左側清單的狀態符號：✔ 完成／▶ 進行中（或目前步驟）／○ 未開始／✖ 失敗。</summary>
    public string Mark(WizardStep s) => _status[s] switch
    {
        WizardStepStatus.Done or WizardStepStatus.Skipped => "✔",
        WizardStepStatus.Failed => "✖",
        WizardStepStatus.Running => "▶",
        _ => s == Current ? "▶" : "○",
    };

    /// <summary>開始執行目前步驟。</summary>
    public void Start(WizardStep s)
    {
        Current = s;
        _status[s] = WizardStepStatus.Running;
        _errors.Remove(s);
    }

    /// <summary>
    /// 步驟完成。skipped＝沒有改變環境（偵測到已完成、或純檢查）；false＝實際做了，之後與 WSL 相關的步驟改回未開始。
    /// 不會自動前進：由呼叫端（自動模式）呼叫 GoNext。
    /// </summary>
    public void Complete(WizardStep s, bool skipped)
    {
        _status[s] = skipped ? WizardStepStatus.Skipped : WizardStepStatus.Done;
        _errors.Remove(s);
        // WSL 已確認可用：不再等重開機
        if (s == WizardStep.InstallWsl) { RebootPending = false; RebootRequestedBootTime = null; }
        if (skipped) return;
        foreach (var later in Steps.Where(x => x > s && x != WizardStep.Configure))
        {
            _status[later] = WizardStepStatus.NotStarted;
            _errors.Remove(later);
        }
    }

    public void Fail(WizardStep s, string error)
    {
        _status[s] = WizardStepStatus.Failed;
        _errors[s] = string.IsNullOrWhiteSpace(error) ? "失敗（原因不明）" : error;
    }

    /// <summary>重試／重新執行：改回未開始（目前步驟不變）。</summary>
    public void Reset(WizardStep s)
    {
        _status[s] = WizardStepStatus.NotStarted;
        _errors.Remove(s);
    }

    /// <summary>步驟 2：已啟用元件、等重開機。記下現在的開機時間，重開後由 ObserveBoot 判斷。</summary>
    public void RequireReboot(DateTimeOffset currentBootTime)
    {
        Current = WizardStep.InstallWsl;
        _status[WizardStep.InstallWsl] = WizardStepStatus.NotStarted;
        _errors.Remove(WizardStep.InstallWsl);
        RebootPending = true;
        RebootRequestedBootTime = currentBootTime;
    }

    /// <summary>
    /// 開精靈時呼叫：若等重開機且開機時間已改變（差距超過 2 分鐘，容許時鐘誤差），記為「已重開過」並清掉等待旗標。
    /// 回傳是否偵測到重開過。
    /// </summary>
    public bool ObserveBoot(DateTimeOffset currentBootTime)
    {
        if (!RebootPending || RebootRequestedBootTime is not { } before) return false;
        if ((currentBootTime - before).Duration() <= TimeSpan.FromMinutes(2)) return false;
        RebootPending = false;
        RebootRequestedBootTime = null;
        RebootedSinceInstall = true;
        return true;
    }

    public bool GoNext()
    {
        if (!CanGoNext) return false;
        Current = Next(Current)!.Value;
        return true;
    }

    public bool GoBack()
    {
        if (!CanGoBack) return false;
        Current = Previous(Current)!.Value;
        return true;
    }

    /// <summary>第一個還沒完成的步驟；全部完成時為最後一步。</summary>
    public WizardStep FirstUnfinished => Steps.FirstOrDefault(s => !IsFinished(s), WizardStep.TestConnection);

    /// <summary>
    /// 開精靈時的起點：需要重新偵測的步驟改回未開始，從第一個未完成的步驟開始。
    /// 需要重新偵測的步驟若在起點之前，偵測時會自動略過（已完成）。
    /// </summary>
    public void PrepareForOpen()
    {
        foreach (var s in Steps)
        {
            if (_status[s] == WizardStepStatus.Running) _status[s] = WizardStepStatus.NotStarted;
            if (RecheckOnOpen(s) && IsFinished(s)) _status[s] = WizardStepStatus.NotStarted;
        }
        Current = WizardStep.SystemCheck;
    }

    // MARK: 存檔

    public string ToJson()
    {
        var steps = new JsonObject();
        foreach (var s in Steps) steps[s.ToString()] = _status[s].ToString();
        var errors = new JsonObject();
        foreach (var (s, e) in _errors) errors[s.ToString()] = e;
        var o = new JsonObject
        {
            ["version"] = Version,
            ["current"] = Current.ToString(),
            ["steps"] = steps,
            ["errors"] = errors,
            ["rebootPending"] = RebootPending,
            ["rebootRequestedBootTime"] = RebootRequestedBootTime?.ToString("o"),
            ["rebootedSinceInstall"] = RebootedSinceInstall,
        };
        return o.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>讀回；檔案不存在、壞掉或版本不對 → 全新狀態（不丟例外）。不認得的步驟名稱與狀態忽略。</summary>
    public static SetupWizardState FromJson(string? json)
    {
        var st = new SetupWizardState();
        JsonObject? o;
        try { o = JsonNode.Parse(json ?? "") as JsonObject; }
        catch (JsonException) { return st; }
        if (o is null || !(o["version"] is JsonValue v && v.TryGetValue<int>(out var ver) && ver == Version)) return st;

        if (o["steps"] is JsonObject steps)
            foreach (var (k, node) in steps)
                if (Enum.TryParse<WizardStep>(k, out var s) && Enum.IsDefined(s)
                    && node is JsonValue sv && sv.TryGetValue<string>(out var text)
                    && Enum.TryParse<WizardStepStatus>(text, out var status) && Enum.IsDefined(status))
                    st._status[s] = status == WizardStepStatus.Running ? WizardStepStatus.NotStarted : status;
        if (o["errors"] is JsonObject errors)
            foreach (var (k, node) in errors)
                if (Enum.TryParse<WizardStep>(k, out var s) && Enum.IsDefined(s) && node is JsonValue ev && ev.TryGetValue<string>(out var e))
                    st._errors[s] = e;
        if (o["current"] is JsonValue cv && cv.TryGetValue<string>(out var cur) && Enum.TryParse<WizardStep>(cur, out var c) && Enum.IsDefined(c))
            st.Current = c;
        st.RebootPending = o["rebootPending"] is JsonValue rp && rp.TryGetValue<bool>(out var b) && b;
        if (o["rebootRequestedBootTime"] is JsonValue bt && bt.TryGetValue<string>(out var bts)
            && DateTimeOffset.TryParse(bts, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind, out var boot))
            st.RebootRequestedBootTime = boot;
        if (st.RebootPending && st.RebootRequestedBootTime is null) st.RebootPending = false;   // 缺開機時間就無從判斷
        st.RebootedSinceInstall = o["rebootedSinceInstall"] is JsonValue rs && rs.TryGetValue<bool>(out var r) && r;
        return st;
    }
}
