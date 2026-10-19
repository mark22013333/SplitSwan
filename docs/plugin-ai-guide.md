# 給 AI 的 SplitSwan 外掛開發指引

把以下指令連同需求交給 AI；規範以本 repo 的格式 v1 文件為準。

> 為 SplitSwan 開發可分享的外掛安裝包。先完整閱讀 `docs/plugin-development.md`、`docs/plugin-package.schema.json`，若需要設定介面再閱讀 `docs/plugin-settings.md`。從 `config/plugin-packages/sharing-demo/` 參考可執行範例。
>
> 使用我指定的固定反向網域 ID 與 SemVer。程式、資源、README、授權與預設值列入 Manifest；私人設定、帳密、OAuth JSON、權杖及紀錄不得進入程式目錄或安裝包。私人狀態只寫入 `SPLITSWAN_PLUGIN_STATE`，權杖放鑰匙圈，資源透過 `SPLITSWAN_PLUGIN_ROOT` 讀取。
>
> 不使用 sudo，不加入安裝、更新或移轉鉤子，不在匯入、預覽或讀取設定時下載及安裝依賴，不建立系統服務。依賴以 Manifest 支援的名稱宣告。需要自動準備環境時，提供不依賴該環境的原生安裝入口，透過已宣告的設定動作讓使用者按一下安裝；固定下載來源、版本與雜湊，寫入私人狀態目錄，顯示進度及可重試的失敗原因，不提權、不自動啟用業務功能。不要修改已安裝目錄；改版提高版本並維持既有狀態相容。需要設定時使用原生設定協定，不載入 HTML／JavaScript 設定頁。
>
> 為主要行為準備正常、邊界、失敗案例，所有驗證使用假的資料與外部操作端。以 `tools/plugin-package.py pack` 打包，再用 `validate` 與 `inspect` 驗證產物。交付 `.splitswan-plugin`、來源、README 與驗證結果，說明依賴與限制；不得只交付未經打包驗證的腳本，也不得宣稱雜湊能證明作者身分或程式安全。

ID、功能或外部服務權限若不明確，先釐清；不得從聊天截圖預填真實公司資料、姓名或憑證。

若要承接舊腳本，先確認舊部署資料與背景服務的相容策略，再宣告 `legacyReplacement` 的精確檔名及已知 SHA-256。實作並驗證 App 私人狀態目錄的升級收據；不可只靠名稱相似就覆蓋舊檔，也不可因此將舊設定或授權放入安裝包。
