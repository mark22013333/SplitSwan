using System.Drawing;
using SplitSwan.Core;

namespace SplitSwan.Tray;

/// <summary>
/// 設定視窗：帳號、密碼、PSK、閘道 1–3、內網網段（多行）、選用的內部網域／內部 DNS。
/// 按「儲存」時用 SettingsValidator 與 DnsOptions 驗證，錯誤逐條列出；通過才寫入 settings.json。
/// 匯入 .splitswan 只把值填進表單，使用者看過閘道並按「儲存」才寫入。
/// </summary>
internal sealed class SettingsForm : Form
{
    private readonly StoredSettings _original;
    private readonly TextBox _user = new() { Width = 300 };
    private readonly TextBox _password = new() { Width = 300, UseSystemPasswordChar = true };
    private readonly TextBox _psk = new() { Width = 300, UseSystemPasswordChar = true };
    private readonly CheckBox _show = new() { Text = "顯示密碼與 PSK", AutoSize = true };
    private readonly TextBox[] _gw = [new() { Width = 300 }, new() { Width = 300 }, new() { Width = 300 }];
    private readonly TextBox _subnets = new()
    {
        Width = 300, Height = 90, Multiline = true, ScrollBars = ScrollBars.Vertical, AcceptsReturn = true,
    };
    private readonly TextBox _domain = new() { Width = 300 };
    private readonly TextBox _dns = new() { Width = 300 };
    private readonly Label _importNote = new()
    {
        AutoSize = true, MaximumSize = new Size(460, 0), ForeColor = Color.FromArgb(0xB0, 0x5A, 0x00), Visible = false,
    };
    private readonly Label _errors = new()
    {
        AutoSize = true, MaximumSize = new Size(460, 0), ForeColor = Color.FromArgb(0xC0, 0x1C, 0x28),
    };
    private readonly bool _importOnShow;
    private readonly Func<bool> _currentAutoReconnect;
    private readonly Button _importBtn = new() { Text = "匯入 .splitswan…", AutoSize = true };
    private readonly Button _saveBtn = new() { Text = "儲存", AutoSize = true };
    private bool _importing;

    /// <summary>按下儲存並寫入成功後的設定；取消為 null。</summary>
    public StoredSettings? Saved { get; private set; }

    /// <param name="currentAutoReconnect">儲存時取「自動重連」的最新值（視窗開著時可能從托盤切換過）。</param>
    public SettingsForm(StoredSettings current, Func<bool> currentAutoReconnect, bool importOnShow = false)
    {
        _original = current;
        _currentAutoReconnect = currentAutoReconnect;
        _importOnShow = importOnShow;

        Text = "SplitSwan 設定";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(12);
        Font = new Font("Microsoft JhengHei UI", 9f);
        ShowInTaskbar = true;

        var grid = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, Dock = DockStyle.Fill };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        void Row(string label, Control c, string? hint = null)
        {
            grid.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left | AnchorStyles.Top, Padding = new Padding(0, 5, 8, 0) });
            if (hint is null) { grid.Controls.Add(c); return; }
            var p = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Margin = Padding.Empty };
            p.Controls.Add(c);
            p.Controls.Add(new Label { Text = hint, AutoSize = true, MaximumSize = new Size(320, 0), ForeColor = SystemColors.GrayText });
            grid.Controls.Add(p);
        }

        _importBtn.Click += (_, _) => StartImport();
        grid.Controls.Add(new Label());
        grid.Controls.Add(_importBtn);
        grid.Controls.Add(new Label());
        grid.Controls.Add(_importNote);

        Row("帳號", _user);
        Row("密碼", _password);
        Row("預設共享金鑰（PSK）", _psk);
        grid.Controls.Add(new Label());
        grid.Controls.Add(_show);
        Row("閘道 1", _gw[0], "IP 或主機名稱，例：203.0.113.10");
        Row("閘道 2（選填）", _gw[1]);
        Row("閘道 3（選填）", _gw[2]);
        Row("內網網段", _subnets, "一行一筆，格式 a.b.c.d/n（單一主機寫 /32），例：192.0.2.0/24");
        Row("內部網域（選填）", _domain, "逗號分隔，填了才會設定 DNS 分流，例：corp.example");
        Row("內部 DNS（選填）", _dns, "逗號分隔的 IPv4；不填就用閘道給的，例：192.0.2.53");

        _show.CheckedChanged += (_, _) =>
        {
            _password.UseSystemPasswordChar = !_show.Checked;
            _psk.UseSystemPasswordChar = !_show.Checked;
        };

        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        var save = _saveBtn;
        var cancel = new Button { Text = "取消", AutoSize = true };
        save.Click += (_, _) => OnSave();
        // 非模態視窗（Show）時 Button.DialogResult 不會自動關閉視窗，要自己 Close；Esc 透過 CancelButton 觸發同一個 Click
        cancel.Click += (_, _) => Close();
        buttons.Controls.AddRange([cancel, save]);

        var outer = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Dock = DockStyle.Fill };
        outer.Controls.Add(grid);
        outer.Controls.Add(new Label
        {
            Text = "新設定在下次連線時生效；已建立的通道不受影響。密碼與 PSK 以 Windows 帳號加密（DPAPI）儲存。",
            AutoSize = true, MaximumSize = new Size(460, 0), ForeColor = SystemColors.GrayText,
        });
        outer.Controls.Add(_errors);
        outer.Controls.Add(buttons);
        Controls.Add(outer);
        AcceptButton = save;
        CancelButton = cancel;

        Fill(current);
        Shown += (_, _) => { if (_importOnShow) StartImport(); };
    }

    private void Fill(StoredSettings s)
    {
        _user.Text = s.Username;
        _password.Text = s.Password;
        _psk.Text = s.Psk;
        for (int i = 0; i < 3; i++) _gw[i].Text = i < s.Gateways.Count ? s.Gateways[i] : "";
        _subnets.Text = SettingsInput.FormatSubnets(s.RemoteSubnets);
        _domain.Text = s.Domain;
        _dns.Text = s.DnsServer;
    }

    private StoredSettings Collect() => new(
        _user.Text,
        _password.Text,
        _psk.Text,
        [.. _gw.Select(t => t.Text)],
        SettingsInput.ParseSubnets(_subnets.Text),
        _domain.Text.Trim(),
        _dns.Text.Trim(),
        _currentAutoReconnect());

    /// <summary>開始匯入（已在匯入中就不重複開始）。</summary>
    public async void StartImport()
    {
        if (_importing || IsDisposed) return;
        _importing = true;
        _importBtn.Enabled = _saveBtn.Enabled = false;
        try
        {
            await ImportAsync();
        }
        catch (Exception ex)
        {
            AppLog.Error($"匯入時發生錯誤：{ex.GetType().Name}：{ex.Message}");
            if (!IsDisposed) _errors.Text = $"匯入時發生錯誤：{ex.Message}";
        }
        finally
        {
            _importing = false;
            if (!IsDisposed) _importBtn.Enabled = _saveBtn.Enabled = true;
        }
    }

    private async Task ImportAsync()
    {
        var profile = await ImportFlow.RunAsync(this);
        // 解密期間使用者可能已關閉視窗
        if (profile is null || IsDisposed) return;
        var merged = SettingsInput.ApplyImport(Collect(), profile);
        Fill(merged);
        var gws = string.Join("、", profile.Gateways);
        _importNote.Text =
            $"已從設定檔填入閘道（{gws}）、{profile.RemoteSubnets.Count} 筆網段" +
            (string.IsNullOrEmpty(profile.Psk) ? "（設定檔沒有附 PSK，保留原本的）" : "與 PSK") +
            "。請確認閘道是公司提供的位址，再按「儲存」；不確定就按「取消」。";
        _importNote.Visible = true;
        _errors.Text = "";
    }

    private void OnSave()
    {
        var s = Collect();
        var errors = SettingsValidator.Validate(s.ToVpnSettings()).Concat(DnsOptions.Validate(s.Domain, s.DnsServer)).ToList();
        if (errors.Count > 0)
        {
            _errors.Text = "請修正以下問題：\n" + string.Join("\n", errors.Select(e => "・" + e));
            return;
        }
        try
        {
            SettingsStore.Save(s);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
                                       or System.Security.Cryptography.CryptographicException)
        {
            _errors.Text = $"儲存失敗：{ex.Message}";
            return;
        }
        AppLog.Info("設定已儲存");
        Saved = s;
        DialogResult = DialogResult.OK;
        Close();
    }
}
