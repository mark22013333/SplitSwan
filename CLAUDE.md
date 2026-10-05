# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

SplitSwan：macOS（Apple Silicon、macOS 14+）狀態列 App，用 Homebrew 版 strongSwan 以 IKEv2 split tunnel 連 FortiGate，取代 FortiClient。使用者文件、VPN 參數、安全模型、已知問題都在 `README.md`，改行為前先看對應段落。

## 常用指令

不用 Xcode／SPM，全部是 `swiftc` 直接編譯（需 Swift 6.1+）。

```bash
bash build.sh                 # 編譯到 build/SplitSwan.app（ad-hoc 簽章）
bash build.sh --install       # 編譯並裝到 /Applications（先結束執行中的 App）
bash make-dmg.sh              # 編譯並打包 dist/SplitSwan-<版本>.dmg
bash Tests/run-tests.sh       # 全部單元測試（不連 VPN、不需 sudo、不寫系統設定）
open build/SplitSwan.app --args -InitialTab settings   # 直接開在指定分頁（settings / environment / about）
```

- **測試沒有 XCTest**：`Tests/run-tests.sh` 把每個測試檔複製成暫存目錄的 `main.swift`，再跟一份**寫死的** Sources 清單一起用 `swiftc` 編成獨立執行檔；輸出含「失敗 0」才算通過。
- **只跑單一測試組**：沒有參數可選，暫時註解掉 `run-tests.sh` 裡其他 `run …` 行，或照該行的檔案清單手動 `swiftc`。
- 因為測試檔自己就是 `main.swift`，`Sources/main.swift` 永遠不能編進測試。新增 Sources 檔時，要手動加進 `run-tests.sh` 裡用到它的每一組編譯清單，否則測試會編譯失敗。`settings` 組另外編入一個 `AppActions` stub。
- **版本號**：`build.sh` 開頭的 `VERSION`、`BUILD_NUM`，並手動同步 `README.md` 第 10 行的「版本：」。`make-dmg.sh` 從 Info.plist 讀版本，不用改。
- App 名稱與 bundle id 在 `app.env`（Swift 端從 Info.plist 讀，不寫死）。改 bundle id 會讓 UserDefaults 與登入項目重新開始。

## 架構

權限分成兩層：App 以一般使用者執行，所有 root 動作集中在一支 bash 輔助程式。

```
SplitSwan.app ──sudo -n──▶ /usr/local/libexec/splitswan-helper (root) ──▶ swanctl ─vici─▶ charon ─IKEv2─▶ FortiGate
```

- **`splitswan-helper`**（repo 根目錄的 bash 腳本）：只接受 `status`、`up [auto|1|2|3]`、`down`、`log`、`reload`、`reload-settings`、`sas`、`logtrim`，其他一律拒絕。`logtrim` 不接受參數，只處理固定路徑 `/var/log/splitswan/charon.log`（超過 2 MB 就地截斷成最後 1 MB，同 inode；拒絕 symlink 與 hard link），截斷測試是 `bash tools/test-logtrim.sh`。連線名稱固定 `vpn1..3`、child 為 `corp`。`status` 回一行字串，由 `VPNController.swift` 的 `HelperStatus.parse` 解析，**新舊兩種格式都要相容**（已安裝的 helper 可能比 App 舊）。`log` 是長串流，helper 會定期檢查上層程序還在不在。
- **安裝特權元件**：`EnvChecker.installHelper` 用 `osascript … with administrator privileges` 執行 App 內附的 `install-root.sh`，把 helper 裝成 root:wheel，並寫入只放行這支程式的 `/etc/sudoers.d/splitswan`（先過 `visudo -cf` 語法檢查）。`build.sh` 會把 helper 與 install-root.sh 複製進 `Contents/Resources/`。
- **改了 `splitswan-helper` 就等於要求使用者重新安裝**：`EnvChecker` 逐 byte 比對已安裝版本與 App 內附版本，不同就顯示「需要更新」。
- **`VPNController`**：唯一的連線協調器，同時只跑一個操作；負責輪替三台閘道、自動重連與退避、睡眠喚醒、網路變更。`main.swift`（AppDelegate、NSStatusItem 選單）與 `MainView.swift`（SwiftUI 三分頁）共用同一個 `VPNController`／`EnvChecker` 實例，選單透過 Combine 訂閱其 `@Published` 狀態重畫。`LogStore` 負責 `helper log` 串流。
- **設定寫入不需 root**：`ConfigStore` 直接寫 Homebrew 目錄下的 `/opt/homebrew/etc/swanctl/swanctl.conf`、`conf.d/secrets.conf`（PSK 與 EAP 帳密，600，暫存檔再替換）與 `/opt/homebrew/etc/strongswan.d/splitswan.conf`（charon 重送參數），存檔後呼叫 helper `reload`。IKE/ESP 加密參數在 `ConfigStore.renderConf`。表單值另存 UserDefaults（`VPNSettings`）。
- **設定來源優先序**：UserDefaults → 解析現有 swanctl.conf → `~/.config/splitswan/company.env`（`CompanyPreset`）→ 環境變數 `SPLITSWAN_*`。公司位址不進 repo（`company.env`、`secrets.conf` 已 gitignore，只放 `config/*.example`）。
- **`ConfigExport`**：`.splitswan` 加密設定檔（AES-256-GCM＋PBKDF2-SHA256 600,000 次），只含閘道、網段、PSK，不含個人帳密。
- **F2 斷線通知**：`VPNController.swift` 的 `DropDetector`（純邏輯）在每次 `refresh` 判定「想連線但沒連上 ≥ 30 秒」；沒網路或 `helperMissing` 時暫停計時，睡眠喚醒時重新計時。實際發送在 `DropNotifier.swift`（`UNUserNotificationCenter`，第一次要發時才請求權限）。
- **F4 閘道排序**：`GatewayHistory.swift` 存每台最近 10 筆 `up N` 結果（UserDefaults JSON），`order` 決定自動輪替順序（冷卻 10 分鐘排最後 → 上次成功 → 成功率／平均耗時 → 無紀錄 → 從未成功）。只有 helper 輸出 `fail vpnN` 才記失敗；連上不到 60 秒被踢、卡在連線中 30 秒會補記失敗。
- **一鍵主機檢查**：設定頁「某台公司主機連不上？」由 `HostCheckPanel.swift`（UI 流程）、`HostCheck.swift`（輸入解析、網段涵蓋、結果文字的純函式，有 `Tests/HostCheckTests.swift`）、`HostCheckRunner.swift`（`dscacheutil`／`route -n get`／`nc -z`，不需 root）組成。確認後走 `SettingsTab.persist()` 存檔，再呼叫 `VPNController.reconnect(reason:)`（先 helper `reload` 再斷線重連）。表單有未儲存修改時一律擋下（`SettingsTab.isDirty`）。
- **F3 診斷報告**：`DiagnosticReport.swift` 是組字與遮蔽的純函式（有 `Tests/DiagnosticTests.swift`），`DiagnosticRunner.swift` 限時執行外部指令並寫出報告（600）。charon 的 filelog 設定由 `ConfigStore` 寫進 `strongswan.d/splitswan.conf`，等級固定 1。

## 輸入驗證（改 ConfigStore／CompanyPreset／ConfigExport 時必守）

這些規則有 `Tests/SecurityTests.swift` 做回歸，改了要讓它維持全綠：

- 帳號、閘道、網段只接受固定字元白名單，防止換行、大括號破壞 swanctl.conf 結構；密碼與 PSK 跳脫雙引號與反斜線，且不可含換行。
- 網段逐筆檢查，拒絕 `/0`（全流量在 macOS 會讓 DNS 失敗，見 README「已知問題」）；數字用 `[0-9]` 而非 `\d`，避免全形數字通過。閘道最多 3 台。
- `company.env` 會被 shell `source`，所以一律由驗證後的值重新產生、值用單引號包住，不可直接複製使用者提供的檔案內容。
- 匯入 `.splitswan` 要檢查 salt／iterations 上限與檔案大小（≤ 1,000,000 bytes），並讓使用者確認閘道後才寫入（加密只保密、不證明來源）。

## 其他腳本

- `vpn.sh`：命令列版，直接 `sudo swanctl`，不經 App 也不經 helper。
- `diag.sh`：會**實際連線**、收集路由／DNS／SA 並測試，再自動斷線；輸出 `diag-*.txt` 含內部網段（已 gitignore）。
- `tools/test-dpd.sh`：需要 root，會暫時封鎖閘道來量測失聯偵測，不要在一般驗證流程中執行（由使用者自己跑 `sudo bash tools/test-dpd.sh`）。

## 公開 repo 的限制

這是 public repo：範例位址一律用 RFC 5737（`203.0.113.x`、`198.51.100.x`），不可寫入任何真實公司名稱、閘道、內網位址或帳號。`secrets.conf`、`company.env` 含密碼與實際位址，不要讀取或提交。

## 發版流程

依序執行，缺一步就不算發版完成：

1. `bash Tests/run-tests.sh` 全綠
2. 改 `build.sh` 的 `VERSION`、`BUILD_NUM`，同步 `README.md` 的「版本：」
3. `bash make-dmg.sh` → `dist/SplitSwan-X.Y.Z.dmg`
4. 在 `dist/` 內產生 `SplitSwan-X.Y.Z.dmg.sha256`，內容只寫檔名不含路徑（格式同 `shasum -a 256 SplitSwan-X.Y.Z.dmg` 的輸出）
5. commit、push
6. annotated tag `vX.Y.Z` 並 push
7. `gh release create vX.Y.Z` 附 dmg 與 .sha256；說明開頭是「## 本版更新」條列，並附 SHA-256。輔助程式有變更時，要提醒使用者到「環境檢查」按系統元件的「更新」
8. 從 GitHub 下載回來，在同一目錄執行 `shasum -a 256 -c SplitSwan-X.Y.Z.dmg.sha256` 驗證

## 本機環境注意事項

- zsh 開了 `noclobber`：覆寫既有檔案要用 `>|`。BSD grep 不支援 `\s`，改用 `[[:space:]]`。
- PreToolUse hook 會攔截指令文字裡出現的遞迴刪除、磁碟直寫、強制推送等字串（包括 heredoc 內文與 commit message）；需要寫到這類內容時改用 Write 工具落檔，或用中文描述。
- 權限設定有 `Read()` deny 涵蓋 `./build`：讀 build 產物一律用絕對路徑。
- GUI App 讀不到 `~/.zshrc` 的環境變數。狀態列 App 沒有主選單時 ⌘C／⌘V 無效，所以 `main.swift` 補了隱藏主選單，不要移除。
- SF Symbols 用 `paletteColors` 上色會吃掉內部圖案，`MenuBarIcon` 改用 sourceAtop 合成上色。
- 截圖驗證 UI 時用 PID 找視窗：`build/` 與 `/Applications` 的同名 App 可能同時在跑。
- 用 AppleScript（System Events）自動點按鈕時，SwiftUI 按鈕沒有可讀的標籤（name 為 missing value），要用 `position`／`size` 辨認，點之前先截圖確認是哪一顆。
- **通知只在 App 位於 Applications 資料夾時有效**（ad-hoc 簽章也可以）；從 `build/` 或 `/tmp` 執行會直接回 `Notifications are not allowed`。測通知要用 `build.sh --install`。
- `build.sh --install` 會結束執行中的 App，但 charon 的通道不會斷；新 App 啟動後依 `WantConnected` 決定要不要自動連線。
- `Tests/run-tests.sh` 共 7 組（reconnect、export、security、settings、diagnostic、hostcheck、about），完整跑一次要數分鐘，主要花在 settings 組的編譯；有其他程序同時改 Sources 時會出現「input file was modified during the build」，那不是測試失敗。
- 狀態列的 `gitstatusd` 會在 `.git/` 留下 0 byte 的殘留 `index.lock`，git 寫入失敗時先用 stat 連續取樣確認 mtime 不動、已是過去式，再清除。
