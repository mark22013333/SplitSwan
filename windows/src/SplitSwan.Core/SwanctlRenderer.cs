using System.Text;

namespace SplitSwan.Core;

/// <summary>
/// 產生 swanctl.conf 與 secrets.conf，輸出與 Mac 版 ConfigStore.renderConf／renderSecrets
/// （Sources/ConfigStore.swift:273-341）逐字一致：換行一律 LF、檔尾有換行、不含 BOM。
/// </summary>
public static class SwanctlRenderer
{
    // Mac 版的標記是「# 由 <CFBundleName>.app 產生」，Mac 版 confGeneratedByApp 以此辨認，保持相同
    private const string Marker = "# 由 SplitSwan.app 產生";

    /// <summary>
    /// 產生 swanctl.conf。帳號、閘道、網段不合法時丟 ArgumentException（避免把未驗證的值寫進設定檔）。
    /// </summary>
    public static string RenderConf(VpnSettings s)
    {
        ArgumentNullException.ThrowIfNull(s);
        var errors = SettingsValidator.ValidateConnection(s.Username, s.Gateways, s.RemoteSubnets);
        if (errors.Count > 0) throw new ArgumentException(string.Join("；", errors), nameof(s));

        var user = TextRules.TrimWhitespace(s.Username);
        var remoteTS = SettingsValidator.JoinSubnets(s.RemoteSubnets);
        var ts = string.Join(", ", TextRules.SplitOmitEmpty(remoteTS, ',').Select(TextRules.TrimWhitespace));

        var sb = new StringBuilder();
        sb.Append(Marker).Append("，請用 App 的「設定」頁修改，手動修改會在下次儲存時被覆蓋。\n");
        sb.Append("# 公司 FortiGate IPsec VPN（IKEv2 + PSK + EAP + Mode Config）\n");
        sb.Append("#   Phase 1：AES128/AES256 + SHA256，DH 20（ecp384），金鑰有效期 86400 秒，DPD 每 10 秒\n");
        sb.Append("#   Phase 2：AES128/AES256 + SHA256，金鑰有效期 43200 秒\n");
        sb.Append("# 密碼與 PSK 在 conf.d/secrets.conf（權限 600）。\n");
        sb.Append('\n');
        sb.Append("connections {\n");
        // 連線名稱依「欄位位置」編號（空欄位跳過但不重新編號），與 Mac 版相同
        for (int i = 0; i < Math.Min(3, s.Gateways.Count); i++)
        {
            var gw = TextRules.TrimWhitespace(s.Gateways[i] ?? "");
            if (gw.Length == 0) continue;
            sb.Append($"    vpn{i + 1} {{\n");
            sb.Append("        version = 2\n");
            sb.Append($"        remote_addrs = {gw}\n");
            sb.Append("        proposals = aes128-sha256-ecp384, aes256-sha256-ecp384\n");
            sb.Append("        rekey_time = 86400s\n");
            sb.Append("        vips = 0.0.0.0\n");
            sb.Append("        mobike = no\n");
            sb.Append("        fragmentation = yes\n");
            sb.Append("        dpd_delay = 10s\n");
            sb.Append('\n');
            sb.Append("        local {\n");
            sb.Append("            auth = eap\n");
            sb.Append($"            eap_id = {user}\n");
            sb.Append("        }\n");
            sb.Append("        remote {\n");
            sb.Append("            auth = psk\n");
            sb.Append("            id = %any\n");
            sb.Append("        }\n");
            sb.Append("        children {\n");
            sb.Append("            corp {\n");
            sb.Append("                local_ts = dynamic\n");
            sb.Append($"                remote_ts = {ts}\n");
            sb.Append("                esp_proposals = aes128-sha256-ecp384, aes256-sha256-ecp384, aes128-sha256, aes256-sha256\n");
            sb.Append("                rekey_time = 43200s\n");
            sb.Append("                dpd_action = clear     # 失聯時直接移除，重連交給 App（規格 §2.2）\n");
            sb.Append("                start_action = none\n");
            sb.Append("                close_action = none\n");
            sb.Append("            }\n");
            sb.Append("        }\n");
            sb.Append("    }\n");
            sb.Append('\n');
        }
        sb.Append("}\n\ninclude conf.d/*.conf\n");
        return sb.ToString();
    }

    /// <summary>
    /// 產生 secrets.conf（PSK 與 EAP 帳密）。PSK、密碼的反斜線與雙引號會被跳脫。
    /// 任何欄位不合法（含 PSK／密碼空白或含換行）時丟 ArgumentException。
    /// </summary>
    public static string RenderSecrets(VpnSettings s)
    {
        ArgumentNullException.ThrowIfNull(s);
        var errors = SettingsValidator.Validate(s);
        if (errors.Count > 0) throw new ArgumentException(string.Join("；", errors), nameof(s));

        var user = TextRules.TrimWhitespace(s.Username);
        var sb = new StringBuilder();
        sb.Append(Marker).Append("，請勿提交版控或貼到任何地方。\n");
        sb.Append("secrets {\n");
        sb.Append("    ike-fortigate {\n");
        sb.Append($"        secret = \"{TextRules.Quote(s.Psk)}\"\n");
        sb.Append("    }\n");
        sb.Append("    eap-user {\n");
        sb.Append($"        id = {user}\n");
        sb.Append($"        secret = \"{TextRules.Quote(s.Password)}\"\n");
        sb.Append("    }\n");
        sb.Append("}\n");
        return sb.ToString();
    }
}
