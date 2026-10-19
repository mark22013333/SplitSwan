# 原生外掛設定協定 v1

外掛可以用資料描述 SwiftUI 表單，不需要提供網頁或可執行的 UI 程式碼。第一行輸出 `名稱 | settings=true` 時，App 在此外掛子選單與外掛管理列加入設定入口。一般輸出規則維持不變。

App 傳入 `SPLITSWAN_PLUGIN_SETTINGS_PROTOCOL=1`；外掛可依此提供精簡選單，舊版 App 則保留原有選單。`menu=false` 的項目不出現在選單，但 `notify=true` 仍依既有上限及每日去重規則發送通知。

## 命令與資料

App 只直接執行外掛本身，固定命令如下：

- `--splitswan-settings snapshot`：不傳標準輸入，回傳目前表單。
- `--splitswan-settings save`：標準輸入為 `{"revision":"r1","values":{"enabled":true}}`。
- `--splitswan-settings action`：標準輸入為 `{"revision":"r1","id":"refresh"}`。

stdout 必須是單份 UTF-8 JSON，結束碼為 0；stderr 不作為表單資料。每次輸入／輸出最多 64 KiB，執行最多 10 秒。外掛設定命令與一般執行、點擊動作共用同支外掛互斥及全域執行上限，執行前重新驗證檔案權限。不得從表單宣告其他執行檔、shell、檔案讀寫路徑或 HTML。

成功的三種命令都回傳完整 snapshot：

```json
{
  "version": 1,
  "title": "範例設定",
  "revision": "r1",
  "tabs": [{"id": "general", "title": "一般", "help": "可選的說明"}],
  "fields": [
    {"id": "enabled", "tab": "general", "title": "啟用背景功能", "type": "toggle"},
    {"id": "state", "tab": "general", "title": "目前狀態", "type": "readonly"}
  ],
  "values": {"enabled": false, "state": "尚未啟用"},
  "actions": [{"id": "refresh", "tab": "general", "title": "重新取得資料"}]
}
```

- `version` 固定為 1；`revision` 是非空字串，只應隨可儲存設定改變，背景進度不應使表單持續衝突。
- 頁籤、欄位及動作各自的 `id` 必須唯一，只接受英數字、底線、連字號及句點，最多 128 bytes；`tab` 必須參照已宣告頁籤。最多 10 個頁籤、100 個欄位、50 個動作。
- `text`、`time`、`select`、`readonly` 對應字串；`toggle` 對應布林值；`stringList`、`multiselect` 對應字串陣列。`time` 使用 HH:mm，由外掛驗證值的範圍。
- `secret` 使用遮蔽輸入框，snapshot 的值必須是空字串，不得回傳既有機密。save 可傳入新值；空字串表示保留原設定，移除應由獨立動作處理。外掛須自行以鑰匙圈等安全方式儲存，且不得將原值放入狀態、錯誤訊息或診斷紀錄。
- `select`、`multiselect` 使用 `options: [{"id":"value","title":"顯示文字"}]`，最多 200 個選項。值可保留已失效的選項；外掛應補上對應選項說明，讓使用者能移除。
- `help` 為可選說明。`readonly` 不包含在 save 的 values 裡。save 可能只傳變更欄位，外掛應保留其他設定並驗證完整結果。
- 動作可宣告 `afterField: "欄位識別碼"`，緊接在同頁籤的指定欄位後顯示；省略則放在頁籤底部。連接帳號及匯入等首次設定動作宜放在對應狀態欄位後。
- 動作可宣告 `destructive: true`，App 會先顯示確認視窗。`input: "jsonFile"` 會開啟檔案選擇器，使用者選取的 UTF-8 JSON 內容最多 32 KiB，透過 request 的 `input` 字串傳遞；不傳檔案路徑。

外掛須檢查 revision；設定過期、驗證失敗或動作不在宣告清單時，不得寫入或執行。拒絕時回傳：

```json
{"error": "conflict", "message": "設定已變更，請取消變更後重新載入。"}
```

App 會保留尚未儲存的表單。使用者取消修改後才能重新載入。儲存採原子替換，外掛自行協調與其背景工作共用的檔案鎖。帳密、權杖及其他機密不得出現在 snapshot、revision 原文或診斷內容。

## 長時間工作

action 應先啟動背景工作，迅速回傳 snapshot，並加入：

```json
{"job": {"id": "job-123", "state": "running", "message": "正在取得資料"}}
```

`state` 只接受 `running`、`succeeded`、`failed`。外掛必須記錄工作的完成或失敗，並處理程序中斷／逾時，避免永久顯示執行中。App 僅在設定視窗開啟且工作進行中時，每 2 秒呼叫 snapshot；關閉即停止查詢，不會終止已授權的背景工作。背景工作結束後仍可自行通知。

## 可選的逐步設定精靈

v1 的頁籤可增加 `guide`，舊版 App 忽略此描述並保留原有表單；沒有 `guide` 的外掛維持原樣。步驟狀態由外掛依實際檢查決定，App 不推測業務條件。

```json
{
  "id": "general", "title": "一般",
  "guide": {
    "summary": "完成目前步驟後再啟用。",
    "checkAction": "check",
    "refreshFields": ["name"],
    "managementActions": [],
    "steps": [{
      "id": "configure", "title": "填寫設定", "help": "儲存後檢查。",
      "state": "pending", "fields": ["name"], "actions": [],
      "details": "按需展開的詳細操作說明。", "saveTitle": "儲存並檢查"
    }]
  }
}
```

- 每頁籤 1～10 個步驟，識別碼唯一；狀態為 `pending`、`checking`、`completed`、`attention`。第一個未完成步驟預設展開，已完成步驟可再展開修改；全部完成後顯示摘要與「調整設定」。
- `fields`、`actions`、`managementActions`、`refreshFields` 只能參照同頁籤既有項目；欄位及動作不能重複歸屬。`primaryAction` 若提供，必須屬於該步驟的 `actions`。未歸屬的欄位仍顯示；未歸屬的動作放入收合的管理區。
- `checkAction` 參照同頁籤的檢查動作，不能要求檔案輸入、破壞性確認、開啟外部頁面或再次觸發檢查。外掛須確保它只讀取並更新診斷狀態，不啟用功能、開啟授權或執行一般排程。
- 進入頁籤時自動執行檢查，30 秒內不重複；「重新檢查」與成功儲存 `refreshFields` 變更會略過冷卻。儲存其他欄位不增加查詢。精靈的 `saveTitle` 僅改變儲存按鈕文字，不允許略過原有驗證。
- 動作可增加 `opensExternal: true`：完成操作並從外部視窗返回時，重新檢查來源頁籤。`recheckAfter: true` 則在動作工作結束後檢查一次，適用匯入設定。一般視窗切換、進度查詢及檢查完成本身不會觸發新檢查。
- 有草稿時延後檢查，儲存或取消後接續；不會隱含儲存。背景工作、冷卻與延後狀態皆由同一個視窗模型協調，關閉後停止查詢及待執行檢查。

外掛須自行保存附設定指紋及時間的檢查結果；設定變更後應失效，暫存結果不得取代正式操作時必要的即時驗證。機密與原始服務錯誤不得回傳至表單或公開範例。

## 停用與相容性

停用個別外掛後，仍可明確開啟設定。外掛功能整體關閉時，不自動掃描或執行；「掃描外掛設定…」是手動管理入口，不恢復一般計時器。舊外掛若未實作設定協定，手動嘗試開啟設定會顯示格式錯誤，不會修改設定。

外掛自己的獨立背景服務不受選單顯示開關控制，設定介面應清楚提供背景功能的停用方式。設定視窗中的動作只使用已儲存設定；有未儲存變更時，動作按鈕不可操作。

可執行範例見 `config/plugins/settings-demo.1m.py.example`。範例不連線、不啟動背景工作、不讀取任何真實帳號資料。
