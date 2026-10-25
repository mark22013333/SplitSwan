# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

SplitSwan：macOS（Apple Silicon、macOS 14+）狀態列 App，用 Homebrew 版 strongSwan 以 IKEv2 split tunnel 連 FortiGate，取代 FortiClient。使用者文件、VPN 參數、安全模型、已知問題都在 `README.md`，改行為前先看對應段落。

## 常用指令

不用 Xcode／SPM，全部是 `swiftc` 直接編譯（需 Swift 6.1+）。

```bash
bash build.sh                 # 編譯到 build/SplitSwan.app（ad-hoc 簽章）
bash build.sh --install       # 編譯並裝到 /Applications（先結束執行中的 App）
bash make-dmg.sh              # 檢查版號＋跑測試＋編譯打包 dist/SplitSwan-<版本>.dmg＋.sha256＋.sig（--skip-tests、--no-sign）
bash Tests/run-tests.sh       # 全部單元測試，各組並行（不連 VPN、不需 sudo、不寫系統設定）
bash Tests/run-tests.sh security update   # 只跑指定的組
bash tools/test-punch-example.sh          # 打卡提醒範例外掛的測試（暫存目錄、覆寫時間）
bash tools/check-version.sh   # 檢查 build.sh 的 VERSION 與 README「版本：」一致
open build/SplitSwan.app --args -InitialTab settings   # 直接開在指定分頁（settings / environment / about）
```

- **測試沒有 XCTest**：`Tests/run-tests.sh` 把每個測試檔複製成暫存目錄的 `main.swift`，再跟一份**寫死的** Sources 清單（`files()` 函式）一起用 `swiftc -Onone` 編成獨立執行檔；各組並行編譯執行，結束後依組別順序輸出。結尾那行「失敗 0」且程式正常結束才算通過，任一組失敗（含編譯失敗）整體退出碼 1，未知組名退出碼 2。
- **只跑部分測試組**：把組名當參數，例 `bash Tests/run-tests.sh settings`；沒參數就跑全部。
- 因為測試檔自己就是 `main.swift`，`Sources/main.swift` 永遠不能編進測試。新增 Sources 檔時，要手動加進 `run-tests.sh` 的 `files()` 裡用到它的每一組，否則測試會編譯失敗。
- `settings` 組只編 `SettingsLogic.swift`（設定頁的純函式，`MainView` 的 `SettingsTab` 轉呼叫它），不編 SwiftUI 介面；設定頁新增要測的純函式時放在 `SettingsLogic`。
- **版本號**：`build.sh` 開頭的 `VERSION`、`BUILD_NUM`，並手動同步 `README.md` 開頭「> 版本：」那一行（`tools/check-version.sh` 用內容找這行比對，`make-dmg.sh` 會先跑它）。`make-dmg.sh` 從 Info.plist 讀版本，不用改。
- App 名稱與 bundle id 在 `app.env`（Swift 端從 Info.plist 讀，不寫死）。改 bundle id 會讓 UserDefaults 與登入項目重新開始。

## 架構

權限分成兩層：App 以一般使用者執行，所有 root 動作集中在一支 bash 輔助程式。

```
SplitSwan.app ──sudo -n──▶ /usr/local/libexec/splitswan-helper (root) ──▶ swanctl ─vici─▶ charon ─IKEv2─▶ FortiGate
```

- **`splitswan-helper`**（repo 根目錄的 bash 腳本）：只接受 `status`、`up [auto|1|2|3]`、`down`、`log`、`reload`、`reload-settings`、`sas`、`logtrim`，其他一律拒絕。`logtrim` 不接受參數，只處理固定路徑 `/var/log/splitswan/charon.log`（超過 2 MB 就地截斷成最後 1 MB，同 inode；拒絕 symlink 與 hard link），截斷測試是 `bash tools/test-logtrim.sh`。連線名稱固定 `vpn1..3`、child 為 `corp`。`status` 回一行字串，由 `VPNController.swift` 的 `HelperStatus.parse` 解析，**新舊兩種格式都要相容**（已安裝的 helper 可能比 App 舊）。`log` 是長串流，helper 會定期檢查上層程序還在不在。
  - **`up` 的路由自我修復**：連上後用 `route -n get` 查 CHILD_SA 每一個遠端網段（網路位址）的介面（略過 IPv6、範圍、`/0`，以及網路位址落在本機非 utun 介面直接相連網段內的，避免家用 LAN 重疊誤判；全部略過時印 `route vpnN skip <數>`），任一個不是 `utun*` 就 terminate 全部、結束 charon（只結束 `pgrep -x charon` 中 `ps -o comm=` 逐字等於 `$CHARON` 且 uid 為 `$CHARON_UID`（0）的程序，argv[0] 可偽造所以 uid 必比；TERM 等 5 秒再 KILL，動用 KILL 時印 `route vpnN killed`）、重新啟動並等 vici、load-all、再連同一台，**只做一次**。在 ok／reason 之前另起一行 `route vpnN fixed|bad|failed <原本的介面>`（bad＝仍錯但照印 ok；failed＝重連失敗，照印 reason 與 fail），由 `RouteRepair` 解析寫進連線紀錄（修復中 `RepairWindow` 暫停 F2 計時）；舊 App 只認 `ok vpnN`／`fail vpnN` 整行，不受影響。成因未查證，註解只描述現象。離線測試是 `bash tools/test-stale-route.sh`（假 swanctl／charon／route；含同名不同路徑的誘餌程序、TERM 中斷不留孤兒）。
  - helper 裡呼叫外部指令一律走 `run_bg`／`swan`（背景執行＋wait，逾時 TERM 時由 trap 結束子程序），結果用全域變數（`REPLY`／`RESULT`）回傳，不用命令替換；迴圈變數要 `local`（bash 動態作用域，曾因 `terminate_all` 的 `c` 覆蓋呼叫端而連到錯的台）。
  - 設定頁主機檢查遇到「IP 不走 utun」時，會用唯讀的 `sas` 取目前 CHILD_SA 的遠端網段（`HostCheck.activeRemoteTS`），網段已生效才提示 strongSwan 狀態異常並給「重新連線」，否則維持「確認網段已儲存且已重新連線」（`HostCheck.routeAdvice`）；staleRoute 的下一步依系統元件是否需更新與是否已重連過（`HostCheck.staleRouteHint`），等連線上限 130 秒（大於 up 最壞耗時）。
- **安裝特權元件**：`EnvChecker.installHelper` 用 `osascript … with administrator privileges` 執行 App 內附的 `install-root.sh`，把 helper 裝成 root:wheel，並寫入只放行這支程式的 `/etc/sudoers.d/splitswan`（先過 `visudo -cf` 語法檢查）。`build.sh` 會把 helper 與 install-root.sh 複製進 `Contents/Resources/`。
- **改了 `splitswan-helper` 就等於要求使用者重新安裝**：`EnvChecker` 逐 byte 比對已安裝版本與 App 內附版本，不同就顯示「需要更新」。
- **`VPNController`**：唯一的連線協調器，同時只跑一個操作；負責輪替三台閘道、自動重連與退避、睡眠喚醒、網路變更。`main.swift`（AppDelegate、NSStatusItem 選單）與 `MainView.swift`（SwiftUI 三分頁）共用同一個 `VPNController`／`EnvChecker` 實例，選單透過 Combine 訂閱其 `@Published` 狀態重畫。`LogStore` 負責 `helper log` 串流。
- **設定寫入不需 root**：`ConfigStore` 直接寫 Homebrew 目錄下的 `/opt/homebrew/etc/swanctl/swanctl.conf`、`conf.d/secrets.conf`（PSK 與 EAP 帳密，600，暫存檔再替換）與 `/opt/homebrew/etc/strongswan.d/splitswan.conf`（charon 重送參數），存檔後呼叫 helper `reload`。IKE/ESP 加密參數在 `ConfigStore.renderConf`。表單值另存 UserDefaults（`VPNSettings`）。
- **設定來源優先序**：UserDefaults → 解析現有 swanctl.conf → `~/.config/splitswan/company.env`（`CompanyPreset`）→ 環境變數 `SPLITSWAN_*`。公司位址不進 repo（`company.env`、`secrets.conf` 已 gitignore，只放 `config/*.example`）。
- **`ConfigExport`**：`.splitswan` 加密設定檔（AES-256-GCM＋PBKDF2-SHA256 600,000 次），只含閘道、網段、PSK，不含個人帳密。
- **F2 斷線通知**：`VPNController.swift` 的 `DropDetector`（純邏輯）在每次 `refresh` 判定「想連線但沒連上 ≥ 30 秒」；沒網路或 `helperMissing` 時暫停計時，睡眠喚醒時重新計時。實際發送在 `DropNotifier.swift`（`UNUserNotificationCenter`，第一次要發時才請求權限）。
- **F4 閘道排序**：`GatewayHistory.swift` 存每台最近 10 筆 `up N` 結果（UserDefaults JSON），`order` 決定自動輪替順序（冷卻 10 分鐘排最後 → 上次成功 → 成功率／平均耗時 → 無紀錄 → 從未成功）。只有 helper 輸出 `fail vpnN` 才記失敗；連上不到 60 秒被踢、卡在連線中 30 秒會補記失敗。
- **一鍵主機檢查**：設定頁「某台公司主機連不上？」由 `HostCheckPanel.swift`（UI 流程）、`HostCheck.swift`（輸入解析、網段涵蓋、結果文字的純函式，有 `Tests/HostCheckTests.swift`）、`HostCheckRunner.swift`（`dscacheutil`／`route -n get`／`nc -z`，不需 root）組成。兩顆按鈕：「檢查並加入」（預設、Enter）不經確認畫面，把不在網段內的 IP（`HostCheck.proposal`）直接以 /32 加入，結果最上方列「已加入」、公網位址顯示橘色警告；「只檢查」不改設定，有 IP 不在網段內時在結果提供「加入並重新連線」；結果頁的「再檢查一次」一律只檢查。加入時走 `SettingsTab.persist()` 存檔，再呼叫 `VPNController.reconnect(reason:)`（先 helper `reload` 再斷線重連）。表單有未儲存修改時一律擋下（`SettingsTab.isDirty`）。
- **一鍵更新**：`UpdateCenter`（`@MainActor` 單例，「關於」頁與狀態列選單共用）負責檢查與每日排程（`AutoCheckUpdates`，預設關）；`UpdateInstaller` 下載 release 的 dmg 與 `.sig`、以 Ed25519 公鑰驗證、`hdiutil` 掛載後檢查 bundle id 與版本（必須等於 release 版本且比目前新，防降級）、`ditto` 複製並 `codesign --verify`，再把舊版移到暫存區、新版放回原位，最後由 `/bin/sh` 等本程序結束後重新開啟。純邏輯在 `UpdateLogic`，測試在 `Tests/UpdateTests.swift`（含用假 App 實際跑 `stage`／`swap`）。限時執行外部指令在 `ProcessRunner`（`DiagnosticRunner.runLimited` 轉呼叫它）；`VPNController.run` 呼叫輔助程式有時限時也走 `ProcessRunner.execute`（寬限 `HelperRun.termGrace` 秒，逾時回 `HelperRun.timeoutCode`），全 App 只有這一份逾時實作。
- **外掛區塊**：設定頁開關 `PluginsEnabled`（預設關）。`PluginLogic.swift` 是純邏輯（檔名間隔、SwiftBar 子集輸出解析＋`notify` 擴充、href 只收 http(s)、bash 只收絕對路徑、通知每日去重、以 stat 結果判斷權限），有 `Tests/PluginTests.swift`（`plugins` 組，含在暫存目錄實跑假外掛的整合測試）。`PluginRunner.swift`（`@MainActor` 單例）掃描 `~/.config/splitswan/plugins/`、檢查擁有者與 group／other 不可寫（symlink 看解析後目標）、經 `ProcessRunner.execute(env:, maxBytes: 64 KB+1, qos: .utility, stderrLimit: 4096)` 直接執行外掛檔（環境變數整組換掉，不經 shell；10 秒上限；stderr 另外收集不寫檔）。資安是硬性要求：`PluginRunner.fullCheck` 在掃描、每次執行、點擊取得名額後都要跑——實際檔案必須在外掛資料夾第一層、擁有者與 mode、寫入類 ACL（`acl_get_file`＋`mbr_uuid_to_id`，給自己的與 deny 不算）、`com.apple.quarantine`、外掛資料夾以上每一層直到 `/`（自己或 root、他人不可寫，sticky 例外）；`bash=` 只准外掛本身；外掛識別一律用完整檔名（狀態資料夾、去重紀錄）；通知標題固定「外掛：<名稱>」、輸出標題只進 subtitle；文字經 `PluginLogic.sanitize`（去 Cc／Cf／行段分隔）與 `clip`（200 字、600 bytes）；通知每次 3 則、每天 20 鍵（`planNotifications`），紀錄每外掛一份、讀寫在背景；`epoch` 在關閉／暫停時遞增，排隊或執行中的 run 發現世代變了就放棄。效能是硬性要求：關閉時 `isActive=false`，不得有 timer、掃描、plugin-state、事件訂閱（`resources` 可量測，有測試）；開啟後每個外掛一個 Timer（tolerance＝間隔 10%、至少 1 秒），資料夾變動用 DispatchSource vnode 監看（不輪詢），執行與解析在 `Task.detached(priority: .utility)`＋`ProcessRunner` qos `.utility`，主執行緒只在 `Plugin` 內容變了才發布（`lastRuns`／`runningIDs` 另外發布，選單不訂閱）；睡眠、螢幕關閉、鎖定、螢幕保護程式時 `pause`，全部解除才 `resume`（各跑一次再排程）；最短間隔 30 秒、同時最多 2 個；`inFlight` 讓排程與點擊動作不重疊（關閉開關也不清）。擁有者檢查擋不住屬於使用者本人的 Homebrew 直譯器，所以 `bash=` 與 symlink 都以「位置」限制。測試裡用 `chmod +a` 造 ACL 時不要用 deny delete（run-tests.sh 會清不掉暫存目錄）。`PluginMenu.swift` 把結果畫在選單「結束」之前（標題行選填的 `card=` 由 `PluginMenuCard.swift` 解碼驗證、`PluginMenuCardView.swift` 以重用的 NSHostingView 畫在子選單頂端，測試組 `plugin-card`；沒有動作的輸出列用 `InfoRowView` 呈現，不反白也不可點），`PluginSettingsView.swift` 是設定頁區塊；外掛通知經 `DropNotifier.sendPlugin`（userInfo `kind=plugin`，點擊開 href）。外掛**絕不經 sudo／helper**。範例在 `config/plugins/punch-reminder.1m.sh.example`（不可放公司名稱或真實打卡網址）。開發測試用啟動參數 `-PluginsDir`、`-PluginStateDir`、`-PluginsEnabled YES`、`-WantConnected NO`，不要動到 `~/.config/splitswan/plugins`。
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

1. 改 `build.sh` 的 `VERSION`、`BUILD_NUM`，同步 `README.md` 的「版本：」
2. `bash make-dmg.sh`（不加 `--no-sign`）：依序檢查版號一致、跑全部測試、編譯打包 `dist/SplitSwan-X.Y.Z.dmg`、在 `dist/` 內產生只含檔名的 `.dmg.sha256` 並用 `shasum -c` 核對、私鑰存在時呼叫 `swift tools/release-sign.swift sign` 再 `verify` 產生 `.dmg.sig`。任何一步失敗就中止
3. 確認輸出有「✅ 已產生並驗證：…dmg.sig」。印出「找不到私鑰」警告時**不可發版**：沒有 `.sig` 的版本，App 的「下載並安裝」會拒絕安裝
4. commit、push
5. annotated tag `vX.Y.Z` 並 push
6. `gh release create vX.Y.Z` 附 dmg、.sha256 與 .sig；說明開頭是「## 本版更新」條列，並附 SHA-256。輔助程式有變更時，要提醒使用者到「環境檢查」按系統元件的「更新」
7. 從 GitHub 下載回來，在同一目錄執行 `shasum -a 256 -c SplitSwan-X.Y.Z.dmg.sha256` 與 `swift tools/release-sign.swift verify SplitSwan-X.Y.Z.dmg` 驗證

**更新簽章金鑰**：私鑰在 `~/.config/splitswan-release/update-ed25519.key`（600，不在 repo），公鑰寫在 `UpdateLogic.publicKeyBase64`。私鑰遺失或換金鑰，已安裝的舊版就無法再自動更新，只能請使用者手動下載一次。私鑰不可提交、不可貼進對話或 release。

## 本機環境注意事項

- bash 腳本裡 `$VAR` 後面緊接全形字元（例：`$VAR（`）會被當成變數名稱的一部分，`set -u` 下直接報 unbound variable；一律寫成 `${VAR}`。
- zsh 開了 `noclobber`：覆寫既有檔案要用 `>|`。BSD grep 不支援 `\s`，改用 `[[:space:]]`。
- PreToolUse hook 會攔截指令文字裡出現的遞迴刪除、磁碟直寫、強制推送等字串（包括 heredoc 內文與 commit message）；需要寫到這類內容時改用 Write 工具落檔，或用中文描述。
- 權限設定有 `Read()` deny 涵蓋 `./build`：讀 build 產物一律用絕對路徑。
- GUI App 讀不到 `~/.zshrc` 的環境變數。狀態列 App 沒有主選單時 ⌘C／⌘V 無效，所以 `main.swift` 補了隱藏主選單，不要移除。
- SF Symbols 用 `paletteColors` 上色會吃掉內部圖案，`MenuBarIcon` 改用 sourceAtop 合成上色。
- 截圖驗證 UI 時用 PID 找視窗：`build/` 與 `/Applications` 的同名 App 可能同時在跑。
- 用 AppleScript（System Events）自動點按鈕時，SwiftUI 按鈕沒有可讀的標籤（name 為 missing value），要用 `position`／`size` 辨認，點之前先截圖確認是哪一顆。
- **通知只在 App 位於 Applications 資料夾時有效**（ad-hoc 簽章也可以）；從 `build/` 或 `/tmp` 執行會直接回 `Notifications are not allowed`。測通知要用 `build.sh --install`。
- `build.sh --install` 會結束執行中的 App，但 charon 的通道不會斷；新 App 啟動後依 `WantConnected` 決定要不要自動連線。
- `Tests/run-tests.sh` 共 9 組（reconnect、export、security、settings、diagnostic、hostcheck、update、about、plugins），並行完整跑一次約 25 秒；有其他程序同時改 Sources 時會出現「input file was modified during the build」，那不是測試失敗，重跑即可。
- 狀態列的 `gitstatusd` 會在 `.git/` 留下 0 byte 的殘留 `index.lock`，git 寫入失敗時先用 stat 連續取樣確認 mtime 不動、已是過去式，再清除。
