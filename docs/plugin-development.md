# SplitSwan 外掛安裝包規格 v1

外掛是以使用者身分執行的程式，不是安全沙盒。安裝包只分享程式、資源、授權文件與預設值；個人設定、帳密、Google OAuth JSON／權杖、紀錄必須留在本機狀態目錄或鑰匙圈。

## 使用者操作

在「設定 → 外掛」選「匯入外掛…」，或拖曳一個安裝包到虛線區。確認名稱、版本、作者、依賴與檔案清單後，選「信任並安裝」。作者是自行填寫的資料，不代表已驗證身分。新外掛預設停用；需要個別啟用及全域「啟用外掛」才會執行。

套件列的「管理 → 更新…」或直接拖入相同識別碼的新版可更新；「管理 → 匯出…」產生可分享的安裝包。安裝包本身是 zip 格式，分享時請直接傳送 `.splitswan-plugin` 檔；若收件端解壓縮後再重新壓縮（例如 Finder 的「壓縮」），外層會多一層資料夾或夾帶 `._` 檔，App 會拒絕並提示改用原始檔。更新保留個別啟用狀態與私人狀態資料。缺少 Manifest 宣告的執行環境時不允許啟用。需要一鍵準備依賴的套件可提供不依賴該環境的原生設定入口，依下述規範讓使用者明確啟動安裝。App 不安裝系統服務、不執行安裝鉤子。

舊式 `~/.config/splitswan/plugins/` 單檔外掛保持相容；若要分享，開發者須先依本規格整理成獨立套件。App 不會猜測私人腳本的依賴或自動匯出周邊資料。開發者可宣告經驗證的舊入口，提供確認後的升級取代流程。

更新以 Manifest 固定識別碼比對，不以顯示名稱或腳本檔名比對。匯入相同識別碼的較新版本會進入更新確認；相同版本及內容略過，同版本改內容與降版拒絕。未宣告 `legacyReplacement` 的套件不會取代單檔腳本。支援舊入口的套件可依下述規則升級；App 仍不接管外掛自己的後端與授權。

單檔與套件的「管理 → 移除外掛…」先自動檢查目前使用者的程序與 `~/Library/LaunchAgents`，再顯示確認。「停止並移除」暫停 App 排程、停止可確認歸屬的程序及子程序、停用並卸載相關登入背景服務，將相關 plist 與程式移到系統垃圾桶；保留私人設定、鑰匙圈與紀錄，不執行移除鉤子。App 工作收尾後會再次檢查，才回報成功。失敗保留外掛並停用排程，避免自動重新啟動；部分已停止的服務不會自動恢復。重新匯入套件視為新安裝且預設停用。

歸屬依完整執行入口、套件專屬路徑或完整 `SPLITSWAN_PLUGIN_STATE` 環境鍵判斷，並追蹤子程序；不依程序名稱、文字提及或模糊標籤終止工作。程序以 PID 加啟動時間確認，避免 PID 重用。登入背景服務必須有安全的擁有者、權限、ACL 與唯一標籤，操作前再次驗證內容；只操作目前使用者的 GUI domain，不使用 sudo/helper。以不透明 shell 字串包裝、抹除環境或無歸屬資訊的系統服務無法保證自動接管；偵測結果只涵蓋能確認歸屬的工作，不代表整台電腦沒有其他服務。

### 診斷紀錄

匯入、更新、升級、移除、啟用、匯出與執行的每一步都記在 `~/Library/Logs/SplitSwan/plugins.jsonl`（一行一筆 JSON，權限 600，超過 256 KiB 會保留一份舊檔 `plugins.1.jsonl`）。記錄內容是操作種類、階段、結果、錯誤碼，以及固定種類的佐證：安裝包大小與 SHA-256、ZIP 項目數、頂層路徑、Manifest 識別碼與版本、舊腳本檔名與 SHA-256、結束碼、是否逾時、stderr 結尾、App 與 macOS 版本。寫入前會把家目錄換成 `~`，網址只留主機，`Authorization`、`Bearer`、`token=`、`key=` 之後的值與長串疑似金鑰的字元一律遮蔽；不記錄外掛輸出、設定內容或帳密。排程執行成功不記錄，連續相同的失敗會合併。

匯入或安裝失敗時，紅字訊息下方會顯示錯誤碼與「複製診斷資訊」按鈕，按下後把這次操作的記錄整理成十幾行文字放到剪貼簿，可以直接貼給維護者。外掛列在最後一次執行失敗時，會在原因後面附上錯誤碼。「設定 → 外掛」那一排的「診斷紀錄…」選單有兩項：「在 Finder 中顯示」選取記錄檔；「匯出診斷報告…」另存一份文字檔（權限 600），內容包括外掛總開關、已安裝套件的識別碼、版本、digest 前 12 碼、啟用與信任狀態、外掛資料夾第一層單檔腳本的檔名與 SHA-256，以及最近 200 筆事件。這兩份文字都只來自已遮蔽的記錄與檔案雜湊，不含腳本內容。

## 建立與打包

工具只需要 Python 3 標準函式庫，App 本身匯入不需要 Python。

```sh
python3 tools/plugin-package.py init /tmp/my-plugin --id org.example.my-plugin
python3 tools/plugin-package.py validate /tmp/my-plugin
python3 tools/plugin-package.py pack /tmp/my-plugin -o /tmp/my-plugin-1.0.0.splitswan-plugin
python3 tools/plugin-package.py inspect /tmp/my-plugin-1.0.0.splitswan-plugin
```

`init` 不覆寫既有目錄。`validate` 核對目前 Manifest 與內容；`pack` 依 Manifest 明確列出的檔案重新計算雜湊，將更新後的 Manifest 寫入安裝包，不修改來源 Manifest。不收錄未列出的開發檔案，也不覆寫既有輸出。修改程式後先 `pack`，再以 `validate` 驗證產物。參考 `config/plugin-packages/sharing-demo/`。

套件是一般 ZIP，副檔名 `.splitswan-plugin`；App 也接受符合規格的 `.zip`。每包一個外掛，`manifest.json` 必須在根目錄，不可多包一層資料夾：

```text
manifest.json
main.sh
README.md
lib/                 # 可選，須逐檔列出
resources/           # 可選，須逐檔列出
```

## Manifest

正式結構見 [JSON Schema](plugin-package.schema.json)。v1 基本欄位必填，另支援可選的 `legacyReplacement`；不接受其他未知欄位或安裝鉤子。

| 欄位 | 規則 |
|---|---|
| `formatVersion` | 固定 `1` |
| `id` | 小寫反向網域格式，例如 `org.example.my-plugin`；最多 120 字元；發布後固定 |
| `name`, `author`, `description` | 非空、最多 500 字元，不含控制或文字方向操控字元 |
| `version`, `minimumAppVersion` | SemVer，例如 `1.0.0`；支援 prerelease，build metadata 不參與版本排序 |
| `entrypoint` | 套件內相對路徑，必須列於 `files` 並設 `executable: true` |
| `interval` | 整數秒，30–86400 |
| `runtime` | `sh`、`bash`、`zsh`、`python3` 或 `node` |
| `dependencies` | 其他必要環境名稱，使用相同白名單，最多 5 個，不重複 |
| `settings` | 是否提供原生設定協定 v1，布林值 |
| `files` | 每檔 `path`、小寫 SHA-256 `sha256`、布林 `executable`；不含 Manifest 本身 |

入口第一行必須與 runtime 相符且沒有附加參數，例如 `#!/bin/sh`、`#!/usr/bin/env python3`、`#!/usr/bin/env node`。程式直接執行，不將命令與參數拼成 shell 指令。多檔資源透過 `SPLITSWAN_PLUGIN_ROOT` 定位，不依賴目前工作目錄。

執行環境的檢查只確認固定 PATH 下可執行檔存在，不執行套件提供的探測命令，也不保證第三方函式庫已安裝。App 不內附執行環境，也不自動安裝 Python／Node 套件；需要額外函式庫的外掛可提供明確的一鍵安裝設定動作，或提供清楚的手動準備說明。

## 執行與設定介面

沿用 README 的 SwiftBar 文字輸出與 [設定協定 v1](plugin-settings.md)。`bash=` 只能指向外掛執行入口本身；使用環境變數組合入口絕對路徑。`settings: true` 讓管理列在外掛尚未執行時也能提供設定入口。

| 環境變數 | 用途 |
|---|---|
| `SPLITSWAN_PLUGIN_ID` | Manifest 固定識別碼 |
| `SPLITSWAN_PLUGIN_VERSION` | 目前執行版本 |
| `SPLITSWAN_PLUGIN_ROOT` | 本版本程式與唯讀資源根目錄 |
| `SPLITSWAN_PLUGIN_PACKAGE_FORMAT` | `1` |
| `SPLITSWAN_PLUGIN_STATE` | 固定私人狀態目錄，更新不變 |
| `SPLITSWAN_PLUGIN_SETTINGS_PROTOCOL` | `1` |
| `SPLITSWAN_APP_PID` | 啟動工作的 App 程序識別碼；需要自行管理子程序的外掛應在提交動作前確認此程序仍存在，不以任意同名 App 代替 |

另提供既有 `SPLITSWAN=1`、`HOME` 與固定 PATH。不得將執行時產物、快取、設定寫入程式目錄，否則完整性檢查會阻擋後續執行與匯出。Python 外掛應停用 bytecode 快取（例如程式開頭設定 `sys.dont_write_bytecode = True`）；依賴模組匯入前完成設定。私人狀態目錄 700、設定檔 600，權杖使用鑰匙圈，診斷不記錄機密。

單次執行及設定命令仍有既有逾時、輸出與同時執行限制。第一版不提供安裝／更新／移除／設定移轉鉤子；同一識別碼的版本必須維持狀態格式相容，破壞性變更須使用新識別碼。子程序應保留 `SPLITSWAN_PLUGIN_STATE`，讓移除時可辨識歸屬；套件仍不得自行安裝或建立系統服務。

## 完整性與版本切換

套件位於 `~/.config/splitswan/plugin-packages/<id>/versions/<digest>/`，`active.json` 是原子切換點。狀態位於 `~/.config/splitswan/plugin-state/packages/<id>/`。套件檔案逐次驗證；修改後須提高版本並重新打包，不可就地修改已安裝程式。

相同版本與內容不重裝，相同版本不同內容、降版拒絕。更新先停止此 ID 的新工作，等待 App 管理的舊工作結束，舊結果不再交付；新版本完整寫入驗證後才切換。失敗保留原版本，目前與上一版本保留，其他舊版本清除。既有設定視窗須先完成儲存／取消及工作。

安裝前將壓縮檔複製到私人暫存區，驗證中央目錄與每個檔頭、完整列舉、CRC、檔案雜湊及路徑。不允許連結、特殊檔案、絕對／穿越路徑、大小寫或 Unicode 重複路徑、加密、分卷、ZIP64。上限：壓縮檔 20 MiB、解壓後 100 MiB、單檔 20 MiB、1,000 項（含隱含資料夾與 Manifest）、Manifest 64 KiB。

不清除下載隔離標記，來源資訊保留在版本資料夾。明確確認只為該份套件內容建立 App 內信任，並非系統簽章或作者驗證。匯出重新驗證安裝內容與原始安裝包，不呼叫外掛、不讀私人狀態或鑰匙圈。

工具拒絕常見 `.env`、私鑰、權杖、紀錄與快取路徑，但無法保證任意程式碼沒有硬編碼秘密。開發者必須自行檢查允許清單、程式及資源。雜湊是完整性檢查，不是惡意程式掃描或信任證明。

## 從舊腳本升級（App 1.8.6 起）

Manifest 可選擇宣告一個舊入口與 1–20 個已知版本的 SHA-256：

```json
"legacyReplacement": {
  "fileName": "example.1m.sh",
  "sha256s": ["開發者計算的 64 位小寫 SHA-256"]
}
```

`fileName` 必須是外掛資料夾第一層的非隱藏一般檔案名稱，不能是路徑或連結。App 會套用原有權限、ACL、隔離檢查，核對完整內容；同名但雜湊不符時拒絕自動取代。請將 `minimumAppVersion` 設為 `1.8.6` 或更新版本。

預覽會列出將取代的舊腳本，使用者按「信任並取代舊腳本」後，App 同時暫停新舊入口、等待已管理的工作、重新驗證，將舊入口原子移到外掛資料夾的 `.splitswan-backups/<UUID>/`，再啟用新套件登錄。套件顯示開關承接舊入口狀態；背景工作設定不由 App 猜測。失敗時恢復原套件、入口與原收據；若外部程序建立了同名新檔案，不覆寫該檔案並回報備份位置。

App 只在固定套件狀態目錄寫入 `.legacy-replacement.json`（600），欄位為 `version: 1`、`packageID`、`fileName`、`sha256`、`backup`。收據與備份不在匯出內容中。既有私人設定不複製、不覆寫，也不進入公開套件。套件必須自行實作對應舊部署的相容承接，否則不要宣告 `legacyReplacement`。

第一版的承接策略是沿用舊部署的設定、授權及既有後端，套件接手入口與設定介面；不重新安裝、重新啟動或建立第二套服務。新安裝沒有符合的舊入口時，仍使用套件自己的全新設定並預設停用。這不是任意資料移轉 API，App 不執行安裝／移轉鉤子，也不接受任意家目錄路徑。

### 外掛自行準備依賴

App 不執行安裝鉤子，也不替外掛安裝系統環境。外掛若提供一鍵準備依賴，必須在設定協定宣告明確動作，供使用者主動操作；匯入、預覽與讀取設定時只能偵測，不可下載或安裝。安裝器應隨套件提供，避免缺少主要執行環境時無法開啟設定。下載應固定來源、版本及完整性資訊，寫入此外掛私人狀態目錄，以背景工作回報進度及可重試的失敗原因，全部驗證完成後才切換。不得提權、安裝系統服務或自動啟用業務操作，也不得覆寫原帳號、授權與設定。

