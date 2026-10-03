using System.Text;

namespace SplitSwan.Core.Tests;

/// <summary>
/// 第二輪相容性修正（審查 L1～L3）：期望值來自 Fixtures/compat-cases.json，
/// 由 generate-fixtures.swift 以 Mac 版原始碼實際跑出（Swift 的行為，不是推測）。
/// </summary>
public class SwiftCompatTests
{
    private const string Pw = "correct horse";
    private const string Zwsp = "\u200B";

    private static string Swift(string name) =>
        Fixture.Json("compat-cases.json").First(x => x!["name"]!.GetValue<string>() == name)!["swift"]!.GetValue<string>();

    [Fact]
    public void CompatFixture_HasExpectedCases() =>
        Assert.Equal(6, Fixture.Json("compat-cases.json").Count);   // 防呆：fixture 讀不到時下面的比對會失真

    // ---- L1：CharacterSet.whitespaces 含 U+200B，修剪時要一併去掉 ----

    [Fact]
    public void L1_SwiftTrimsZwsp_FixtureSaysSo() =>
        Assert.Equal("a" + Zwsp + "b", Swift("trim-zwsp"));   // 頭尾的 ZWSP 與空白被去掉，中間的保留

    [Fact]
    public void L1_ZwspAroundFields_AcceptedLikeMac()
    {
        Assert.Equal("ok", Swift("validate-zwsp"));
        var s = new VpnSettings(Zwsp + "alice" + Zwsp, "pw", "k", [Zwsp + "203.0.113.10"], [Zwsp + "192.0.2.0/24" + Zwsp]);
        Assert.Empty(SettingsValidator.Validate(s));
    }

    [Fact]
    public void L1_ZwspAroundFields_RenderedConfMatchesSwift()
    {
        var s = new VpnSettings(Zwsp + "alice" + Zwsp, "pw", "k", [Zwsp + "203.0.113.10", "", ""], [Zwsp + "192.0.2.0/24" + Zwsp]);
        var conf = SwanctlRenderer.RenderConf(s);
        Assert.Equal(Fixture.Text("render-zwsp.conf"), conf);
        // 不可把零寬字元寫進設定檔。要用 ordinal 比對：xunit 的字串 DoesNotContain 走語系比對，
        // 零寬字元在語系比對下會被忽略而「在位置 0 找到」（實測），變成假失敗
        Assert.Equal(-1, conf.IndexOf('\u200B'));
    }

    [Fact]
    public void L1_ZwspInsideUsername_StillRejected() =>
        Assert.Equal(["帳號只能包含英數字與 . _ @ -"],
            SettingsValidator.Validate(new VpnSettings("al" + Zwsp + "ice", "pw", "k", ["203.0.113.10"], ["192.0.2.0/24"])));

    // 換行仍然不可被修剪（修 L1 時不能順手放寬）
    [Fact]
    public void L1_TrailingNewlineStillRejected() =>
        Assert.NotEmpty(SettingsValidator.Validate(new VpnSettings("alice\n", "pw", "k", ["203.0.113.10"], ["192.0.2.0/24"])));

    // ---- L2：檔頭有 UTF-8 BOM（Swift 實際解得開） ----

    [Fact]
    public void L2_BomFile_DecryptsLikeSwift()
    {
        var data = Fixture.Bytes("bom.splitswan");
        Assert.Equal([0xEF, 0xBB, 0xBF], data[..3]);   // 正對照：fixture 真的有 BOM
        Assert.Equal("ok:" + SplitswanImporter.Decrypt(data, Pw).Psk, Swift("bom.splitswan"));
    }

    [Fact]
    public void L2_BomFile_WrongPassphraseStillRejected() =>
        Assert.Equal("密碼錯誤，或檔案已損毀／被修改",
            Assert.Throws<SplitswanImportException>(() => SplitswanImporter.Decrypt(Fixture.Bytes("bom.splitswan"), "wrong pass")).Message);

    // BOM 也算進 1,000,000 bytes 上限（Swift 先比大小再解析）
    [Fact]
    public void L2_BomCountsTowardSizeLimit()
    {
        var demo = Fixture.Bytes("demo.splitswan");
        var pad = Encoding.UTF8.GetBytes(new string(' ', 1_000_000 - demo.Length - 3 + 1));
        byte[] data = [0xEF, 0xBB, 0xBF, .. demo, .. pad];
        Assert.Equal(1_000_001, data.Length);
        Assert.Equal("這不是 SplitSwan 的加密設定檔",
            Assert.Throws<SplitswanImportException>(() => SplitswanImporter.Decrypt(data, Pw)).Message);
    }

    [Fact]
    public void L2_BomInDecryptedPayload_Accepted()
    {
        var plain = Encoding.UTF8.GetBytes("""{"name":"N","gateways":["203.0.113.10"],"remoteTS":"192.0.2.0/24","psk":"k"}""");
        var file = TestEncryptor.EncryptRaw([0xEF, 0xBB, 0xBF, .. plain], Pw);
        Assert.Equal("k", SplitswanImporter.Decrypt(file, Pw).Psk);
    }

    // ---- L3：重複 key 取第一個（Swift JSONDecoder） ----

    [Fact]
    public void L3_DuplicateFormat_FirstValid_DecryptsLikeSwift()
    {
        Assert.StartsWith("ok:", Swift("dupkey-first-valid.splitswan"));
        Assert.Equal("ok:" + SplitswanImporter.Decrypt(Fixture.Bytes("dupkey-first-valid.splitswan"), Pw).Psk,
            Swift("dupkey-first-valid.splitswan"));
    }

    [Fact]
    public void L3_DuplicateFormat_FirstInvalid_RejectedLikeSwift() =>
        Assert.Equal(Swift("dupkey-first-invalid.splitswan"),
            Assert.Throws<SplitswanImportException>(() =>
                SplitswanImporter.Decrypt(Fixture.Bytes("dupkey-first-invalid.splitswan"), Pw)).Message);

    // 檔頭欄位重複時 AAD 用的是第一個值：在後面補一個不同的 iterations 不影響解密
    [Fact]
    public void L3_DuplicateIterations_SecondIgnored()
    {
        var text = Encoding.UTF8.GetString(Fixture.Bytes("demo.splitswan"));
        var i = text.LastIndexOf('}');
        var data = Encoding.UTF8.GetBytes(text[..i] + ", \"iterations\" : 3000000\n}");
        Assert.Equal("p\"s\\k 密鑰 !@#", SplitswanImporter.Decrypt(data, Pw).Psk);
    }

    [Fact]
    public void L3_DuplicateKeyInDecryptedPayload_TakesFirst()
    {
        Assert.Equal("first", Swift("payload-dupkey"));
        var plain = Encoding.UTF8.GetBytes(
            """{"name":"N","gateways":["203.0.113.10"],"gateways":["$(id)"],"remoteTS":"192.0.2.0/24","remoteTS":"203.0.113.0/0","psk":"first","psk":"second"}""");
        var p = SplitswanImporter.Decrypt(TestEncryptor.EncryptRaw(plain, Pw), Pw);
        Assert.Equal(["203.0.113.10"], p.Gateways);
        Assert.Equal(["192.0.2.0/24"], p.RemoteSubnets);
        Assert.Equal("first", p.Psk);
    }

    // 反方向：第一個值不合法時一定要擋（不能因為後面有合法值而放行）
    [Fact]
    public void L3_DuplicateKeyInPayload_FirstInvalid_Rejected()
    {
        var plain = Encoding.UTF8.GetBytes(
            """{"name":"N","gateways":["$(id)"],"gateways":["203.0.113.10"],"remoteTS":"192.0.2.0/24"}""");
        Assert.Equal("閘道格式不正確：$(id)",
            Assert.Throws<SplitswanImportException>(() => SplitswanImporter.Decrypt(TestEncryptor.EncryptRaw(plain, Pw), Pw)).Message);
    }
}
