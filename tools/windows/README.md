# SplitSwan Windows 實驗版（WSL2）

**實驗用途**：驗證「在 WSL2 裡跑 Linux strongSwan，讓 Windows 透過它走 split tunnel」可不可行。這不是正式版。

Windows 內建的 IKEv2 用戶端無法使用「閘道用 PSK、使用者用 EAP」的組合，原生的 strongSwan Windows 版又不支援虛擬 IP，所以改由 WSL2 裡的 Linux 負責 IPsec：

```
Windows ──路由──▶ WSL2 Ubuntu（轉發＋SNAT 成虛擬 IP）──▶ strongSwan ─IKEv2／NAT-T─▶ FortiGate
```

## 準備

1. Windows 11（或 Windows 10 22H2）、BIOS 已開啟虛擬化，**目前登入的帳號本身**要有系統管理員權限。如果是標準使用者，在 UAC 輸入別人的管理員帳密，WSL 會裝到那個管理員帳號底下。
   需要 WSL 2.3.11 以上才有 IPsec 核心模組，`wsl --version` 可以查版本。要更新時請用 `wsl --update --web-download`；用內建 Administrator 帳號時，不加 `--web-download` 會經過 Microsoft Store 而卡住。
2. 把整個 `tools\windows` 資料夾放到 Windows 上**自己的使用者目錄底下**（例如 `%UserProfile%\SplitSwan`；放在 `C:\` 底下的共用位置，其他本機使用者也讀得到密碼檔），在裡面建立 `conf` 資料夾，從 Mac 複製兩個檔案進去：

   | Windows | 來源（Mac） |
   |---|---|
   | `conf\swanctl.conf` | `/opt/homebrew/etc/swanctl/swanctl.conf` |
   | `conf\secrets.conf` | `/opt/homebrew/etc/swanctl/conf.d/secrets.conf` |

   `secrets.conf` 含 PSK 與密碼，請用隨身碟或其他私人管道傳送，不要經過聊天軟體或 email。`conf` 資料夾已加進 `.gitignore`。
3. 選用：把 `options.example.ini` 複製成 `conf\options.ini`，填入內部網域（`Domain=`），內部主機名稱才解析得到。

## 使用

| 雙擊 | 作用 |
|---|---|
| `connect.cmd` | 第一次會安裝 WSL 與 Ubuntu（照畫面建立 Ubuntu 帳號，必要時重開機後再雙擊一次），接著安裝 strongSwan、依序嘗試各閘道、設定 Windows 路由與 DNS 分流 |
| `disconnect.cmd` | 移除路由與 DNS 規則，中斷通道 |
| `status.cmd` | 顯示 SA、SNAT、Windows 路由與 DNS 規則 |

每次執行都會跳出 UAC 提權視窗，記錄檔寫在 `%LOCALAPPDATA%\SplitSwan-WSL\logs\`。記錄檔裡有內部位址，分享前請先遮蔽。

**睡眠喚醒、換網路或重開機後**：先執行 `disconnect.cmd`，再執行 `connect.cmd`。WSL 的 IP 每次啟動都會變，路由也不會保留（只存在記憶體中）。

## 已知限制與待驗證

- 只支援 WSL 預設的 NAT 網路模式（`.wslconfig` 設成 `networkingMode=mirrored` 時會拒絕執行）。
- 內網網段不能和 WSL 的 NAT 網段（通常在 172.16–31.x）重疊，重疊時 `connect` 會中止。這是這個架構才有的問題，Mac 版不會遇到。
- WSL 核心的 IPsec（`xfrm_user`、`esp4`）是模組，`connect` 第 3 步會嘗試載入，失敗時會提示。如果 IKE 成功但 CHILD SA 裝不起來，多半就是這個原因，要改用 strongSwan 的 `kernel-libipsec`。
- Hyper-V firewall（Win11 22H2 以後預設開啟）會不會擋 Windows 經 WSL 轉發的封包，官方文件沒有說明，只能實測。`status.cmd` 會印出它的設定。
- 偵測 WSL 時，會找 `C:\Program Files\WSL\wsl.exe` 或 Store 版 WSL 套件，但還沒在真機上確認過。
- 公司端點防護可能擋 WSL 或轉發，只能實測。
- 不會自動重連，閘道排序也不會記錄歷史（Mac 版的 F2／F4 都沒有）。
