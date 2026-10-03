using System.Text;
using System.Text.Json.Nodes;

namespace SplitSwan.Core.Tests;

/// <summary>
/// 移植 Mac 版 Tests/ExportTests.swift 與 SecurityTests.swift 的匯入相關案例。
/// demo.splitswan、nopsk-nfc.splitswan、evil.splitswan 都是 Mac 版 ConfigExport.encrypt 實際產生的檔案。
/// </summary>
public class SplitswanImporterTests
{
    private const string Pw = "correct horse";
    private const string NotEncrypted = "這不是 SplitSwan 的加密設定檔";
    private const string Wrong = "密碼錯誤，或檔案已損毀／被修改";

    private static byte[] Demo => Fixture.Bytes("demo.splitswan");

    private static string Fails(byte[] data, string pw = Pw) =>
        Assert.Throws<SplitswanImportException>(() => SplitswanImporter.Decrypt(data, pw)).Message;

    // ExportTests「正確密碼解得開、內容一致（含引號、反斜線、中文）」——Swift 產生、C# 解開
    [Fact]
    public void SwiftFile_CorrectPassphrase_Decrypts()
    {
        var p = SplitswanImporter.Decrypt(Demo, Pw);
        Assert.Equal(["203.0.113.10", "203.0.113.20"], p.Gateways);   // Mac 匯出的空白第 3 台被略過
        Assert.Equal(["192.0.2.0/24", "198.51.100.5/32"], p.RemoteSubnets);
        Assert.Equal("p\"s\\k 密鑰 !@#", p.Psk);
    }

    [Fact]
    public void SwiftFile_DecryptedProfile_PassesValidator()
    {
        var p = SplitswanImporter.Decrypt(Demo, Pw);
        Assert.Empty(SettingsValidator.Validate(new VpnSettings("alice", "pw", p.Psk, p.Gateways, p.RemoteSubnets)));
    }

    // SecurityTests「NFC 匯出、NFD 匯入可以解開」：Swift 以 NFC "café-pass" 加密
    [Theory]
    [InlineData("caf\u00e9-pass")]   // NFC
    [InlineData("cafe\u0301-pass")]  // NFD
    public void SwiftFile_NfcOrNfdPassphrase_Decrypts(string pw)
    {
        var p = SplitswanImporter.Decrypt(Fixture.Bytes("nopsk-nfc.splitswan"), pw);
        Assert.Equal(["vpn.example.com"], p.Gateways);
        Assert.Equal(["192.0.2.0/24"], p.RemoteSubnets);
        Assert.Equal("", p.Psk);   // Mac 匯出時沒有 PSK（psk 欄位省略）
    }

    // ExportTests「錯誤密碼 → wrongPassphraseOrTampered」
    [Fact]
    public void WrongPassphrase_Rejected() => Assert.Equal(Wrong, Fails(Demo, "wrong pass"));

    // ExportTests「竄改密文 → 解不開」（改 base64 的一個字元）
    [Fact]
    public void TamperedCiphertextChar_Rejected()
    {
        var data = Fixture.Mutate(Demo, o =>
        {
            var s = o["sealed"]!.GetValue<string>().ToCharArray();
            var i = s.Length / 2;
            s[i] = s[i] == 'A' ? 'B' : 'A';
            o["sealed"] = new string(s);
        });
        Assert.Throws<SplitswanImportException>(() => SplitswanImporter.Decrypt(data, Pw));
    }

    // ExportTests「位元組竄改 → wrongPassphraseOrTampered」（base64 仍合法，真正測到 GCM 驗證）
    [Fact]
    public void TamperedCiphertextByte_RejectedAsWrongOrTampered()
    {
        var data = Fixture.Mutate(Demo, o =>
        {
            var raw = Convert.FromBase64String(o["sealed"]!.GetValue<string>());
            raw[raw.Length / 2] ^= 0x01;
            o["sealed"] = Convert.ToBase64String(raw);
        });
        Assert.Equal(Wrong, Fails(data));
    }

    // ExportTests「竄改檔頭 iterations → 解不開」（AAD 綁住檔頭）
    [Fact]
    public void TamperedHeaderIterations_Rejected() =>
        Assert.Equal(Wrong, Fails(Fixture.Mutate(Demo, o => o["iterations"] = 600_001)));

    [Fact]
    public void TamperedSalt_Rejected() =>
        Assert.Equal(Wrong, Fails(Fixture.Mutate(Demo, o => o["salt"] = Convert.ToBase64String(new byte[16]))));

    // ExportTests「過低的 iterations（降級攻擊）被拒」
    [Fact]
    public void TooFewIterations_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o["iterations"] = 1_000)));

    // SecurityTests「iterations 超過 2,000,000 → 拒絕」
    [Fact]
    public void TooManyIterations_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o["iterations"] = 3_000_000)));

    // SecurityTests「salt 超過 64 bytes → 拒絕」
    [Fact]
    public void SaltOver64Bytes_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o["salt"] = Convert.ToBase64String(new byte[65]))));

    [Fact]
    public void SaltUnder16Bytes_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o["salt"] = Convert.ToBase64String(new byte[15]))));

    [Fact]
    public void SealedTooShort_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o["sealed"] = Convert.ToBase64String(new byte[27]))));

    [Fact]
    public void SealedTooLong_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o["sealed"] = Convert.ToBase64String(new byte[64_001]))));

    // SecurityTests「超過 1 MB 的檔案 → 拒絕」
    [Fact]
    public void FileOver1MB_Rejected() => Assert.Equal(NotEncrypted, Fails(new byte[1_000_001]));

    // 上限邊界：剛好 1,000,000 bytes 不因大小被擋（但內容不是 JSON，一樣是格式錯）
    [Fact]
    public void FileExactly1MB_NotRejectedForSize()
    {
        var pad = Encoding.UTF8.GetBytes(new string(' ', 1_000_000 - Demo.Length));
        Assert.Equal("p\"s\\k 密鑰 !@#", SplitswanImporter.Decrypt([.. Demo, .. pad], Pw).Psk);
    }

    // ExportTests「未知版本被拒」
    [Fact]
    public void UnknownVersion_Rejected() =>
        Assert.Equal("設定檔版本 2 不支援，請更新 App", Fails(Fixture.Mutate(Demo, o => o["version"] = 2)));

    // ExportTests「一般 company.env 不會被當成加密檔」
    [Fact]
    public void PlainEnvFile_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Encoding.UTF8.GetBytes("SPLITSWAN_GATEWAYS=\"203.0.113.10\"")));

    [Fact]
    public void WrongFormatField_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o["format"] = "other")));

    [Fact]
    public void WrongKdf_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o["kdf"] = "PBKDF2-HMAC-SHA1")));

    [Fact]
    public void MissingField_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o.Remove("kdf"))));

    [Fact]
    public void NegativeIterations_Rejected() =>
        Assert.Equal(NotEncrypted, Fails(Fixture.Mutate(Demo, o => o["iterations"] = -1)));

    [Fact]
    public void JsonArrayRoot_Rejected() => Assert.Equal(NotEncrypted, Fails(Encoding.UTF8.GetBytes("[1,2]")));

    // 來源不可信（MainView 匯入流程 → strictPreset）：Mac 版 ConfigExport.encrypt 實際產生的惡意內容
    // （4 台閘道、0/0、PSK 含換行），必須整份拒絕
    [Fact]
    public void SwiftEvilFile_FourGateways_Rejected() =>
        Assert.Equal("閘道最多 3 台，設定檔裡有 4 台", Fails(Fixture.Bytes("evil.splitswan")));

    // 以下用測試加密器造檔（Mac 版 UI 不會產生，但惡意檔案可能這樣）

    private static byte[] Craft(string[] gws, string ts, string? psk = "k", string name = "N") =>
        TestEncryptor.Encrypt(new Dictionary<string, object?>
        {
            ["name"] = name, ["gateways"] = gws, ["remoteTS"] = ts, ["psk"] = psk,
        }, Pw);

    [Fact]
    public void TestEncryptor_PositiveControl_Decrypts()
    {
        // 正對照：確認下面的拒絕不是因為測試加密器本身壞掉
        var p = SplitswanImporter.Decrypt(Craft(["203.0.113.10"], "192.0.2.0/24\n198.51.100.0/24"), Pw);
        Assert.Equal(["192.0.2.0/24", "198.51.100.0/24"], p.RemoteSubnets);   // 換行也可當分隔（同 Mac strictPreset）
    }

    // SecurityTests「網段 0.0.0.0/0 → 拒絕」「網段 /0 混在其他網段中 → 拒絕」
    [Theory]
    [InlineData("0.0.0.0/0")]
    [InlineData("192.0.2.0/24, 198.51.100.0/0")]
    public void DefaultRoute_Rejected(string ts) =>
        Assert.StartsWith("不可使用 ", Fails(Craft(["203.0.113.10"], ts)));

    // SecurityTests「網段夾帶指令 → 拒絕」
    [Fact]
    public void SubnetCommandInjection_Rejected() =>
        Assert.Equal("通道網段格式不正確：$(touch x)（例：192.0.2.0/24）", Fails(Craft(["203.0.113.10"], "192.0.2.0/24,$(touch x)")));

    // SecurityTests「閘道含 $ 字元 → 拒絕」
    [Fact]
    public void GatewayDollar_Rejected() => Assert.Equal("閘道格式不正確：$(id)", Fails(Craft(["$(id)"], "192.0.2.0/24")));

    // SecurityTests「閘道含換行 → 拒絕」（控制字元檢查只放行 \n，但換行在閘道白名單外）
    [Fact]
    public void GatewayNewline_Rejected() =>
        Assert.StartsWith("閘道格式不正確：", Fails(Craft(["203.0.113.10\nSPLITSWAN_GATEWAYS=x"], "192.0.2.0/24")));

    [Fact]
    public void GatewayCommaSmuggling_CountedAfterSplit() =>
        Assert.Equal("閘道最多 3 台，設定檔裡有 4 台",
            Fails(Craft(["203.0.113.10,203.0.113.20", "203.0.113.30,203.0.113.40"], "192.0.2.0/24")));

    [Fact]
    public void GatewayOver253Chars_Rejected() =>
        Assert.StartsWith("閘道格式不正確：", Fails(Craft([new string('a', 254)], "192.0.2.0/24")));

    [Theory]
    [InlineData("N\u0000")]
    [InlineData("N\u200B")]   // 零寬空白（Cf）
    [InlineData("N\r")]
    public void ControlCharacters_Rejected(string name) =>
        Assert.Equal("設定檔含有不允許的控制字元", Fails(Craft(["203.0.113.10"], "192.0.2.0/24", name: name)));

    [Theory]
    [InlineData("a\nb")]
    [InlineData("a\rb")]
    [InlineData("a\u2028b")]   // Unicode 行分隔字元
    public void PskWithNewline_Rejected(string psk) =>
        Assert.Equal("設定檔裡的 PSK 含有換行，已拒絕", Fails(Craft(["203.0.113.10"], "192.0.2.0/24", psk)));

    [Fact]
    public void NoGateways_Rejected() => Assert.Equal("設定檔裡沒有閘道", Fails(Craft(["", " "], "192.0.2.0/24")));

    [Fact]
    public void NoSubnets_Rejected() => Assert.Equal("設定檔裡沒有通道網段", Fails(Craft(["203.0.113.10"], " , \n")));

    [Fact]
    public void NullPsk_BecomesEmpty() => Assert.Equal("", SplitswanImporter.Decrypt(Craft(["203.0.113.10"], "192.0.2.0/24", null), Pw).Psk);

    // 解得開但內容不是預期結構：Mac 版歸為「密碼錯誤或檔案損毀」
    [Fact]
    public void DecryptedButMalformedPayload_Rejected() =>
        Assert.Equal(Wrong, Fails(TestEncryptor.Encrypt(new Dictionary<string, object> { ["name"] = "N" }, Pw)));
}
