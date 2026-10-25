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

## 可選的狀態卡片、分組與隱藏頁籤

v1 頁籤可再加入下列選填欄位。舊版 App 忽略它們並照原本方式列出欄位；沒有這些欄位的外掛維持原樣。

```json
{
  "id": "status", "title": "狀態",
  "summary": {
    "eyebrow": "今天", "headline": "今天上班", "reason": "範例日曆：上班日", "tone": "ok",
    "toggleField": "enabled",
    "metrics": [{"label": "上次結果", "value": "通過", "detail": "10/19 22:38", "badge": {"text": "已過期", "tone": "warn"}}]
  },
  "groups": [{
    "id": "conditions", "title": "執行條件", "help": "按「說明」才展開的補充文字。",
    "rows": [{"label": "必要環境", "value": "已就緒", "tone": "ok", "action": "recheck"}],
    "fields": [], "actions": []
  }]
}
```

- `tone` 只接受 `ok`、`info`、`warn`、`error`、`neutral`，其他值整份表單視為格式錯誤。
- `summary` 是頁籤最上方的狀態卡片：`metrics` 最多 4 個；`toggleField` 若提供，必須是同頁籤的 `toggle` 欄位，顯示在卡片右上角，仍須按「儲存」才會套用。
- `groups` 最多 10 個，每組 `rows` 最多 12 列。`rows` 是唯讀狀態列，`action` 顯示成列尾按鈕；`fields` 依「標題在左、控制項在右」排列，短文字欄位不佔滿整列；`actions` 排在組底，宣告 `afterField` 且該欄位在同組時改排在欄位下方。
- 所有參照只能指向同頁籤既有的欄位或動作。同一頁籤內，每個欄位與動作最多出現在一個群組（列尾按鈕也算），卡片開關不能再放進群組。未歸屬的欄位與動作照原本方式排在群組之後。有 `guide` 的頁籤不能同時使用 `summary` 或 `groups`。
- 可見頁籤顯示在上方分段控制，放不下時改為下拉選單。頁籤可宣告 `hidden: true`，不出現在分段控制或選單，只能由動作的 `opensTab` 進入，頁面頂端提供「返回」。至少要有一個非隱藏頁籤。
- 動作可宣告 `opensTab: "頁籤識別碼"`：按下時只在 App 內切換到指定的隱藏頁籤，這個切換本身不呼叫外掛，有未儲存變更時也可使用。進入的隱藏頁籤若有 `guide`，會照精靈規則自動執行它的 `checkAction`（30 秒內不重複；有未儲存變更時延後），這次檢查會呼叫外掛，也可能連網。這類動作不能同時宣告 `input`、`destructive`、`opensExternal`、`recheckAfter` 或 `signsIn`。
- 動作可宣告 `signsIn: true`，按鈕旁顯示紅色「會登入」標籤，提醒此動作會登入外部服務。
- 文字有長度上限：`eyebrow` 60、`headline` 80、`reason` 200、指標標題 40、指標值 80、指標補充 200、徽章 24、群組標題 60、群組說明 2000、列標題 40、列值 300 個字元。所有文字仍經過與其他欄位相同的控制字元與雙向文字過濾。

頂端訊息顯示目前背景工作的 `job.message`。由設定視窗觸發的工作會加上動作標題與觸發時間；工作結束後可關閉訊息，使用者切換到其他頁籤時已成功的訊息自動收起（開窗後第一次進入頁籤不收起），失敗訊息保留到使用者關閉或下一個工作開始。

## 選單資訊卡片（選填）

標題行可再加 `card=<base64url 編碼的 JSON>`，App 會在此外掛子選單最上方顯示一張不可點的卡片，下方仍是一般輸出列與「開啟設定…」。卡片從 App 1.9.4 起支援，舊版 App 會忽略這個參數。外掛若在有卡片時省略文字列，必須把 `minimumAppVersion` 提高到 1.9.4 以上，否則舊版 App 上狀態資訊會整個消失；要相容舊版 App 就保留文字列。

```json
{"version":1,"headline":"今天 08:41 自動打卡","tone":"ok","detail":"政府日曆：上班日","enabled":true,
 "timeline":{"start":"08:20","end":"09:05","check":"08:24","windowStart":"08:30","windowEnd":"09:00","planned":"08:41","now":"08:35"},
 "conditions":[{"label":"VPN","value":"已連線","tone":"ok"}],
 "history":[{"date":"2026-10-22","weekday":"四","time":"08:37","result":"auto"}]}
```

- `tone`：`ok`、`info`、`warn`、`error`、`neutral`。`result`：`auto`（自動成功）、`manual`（人工處理）、`leave`（請假）、`missed`（未執行）、`skipped`（跳過）。
- 時間一律是半形 `HH:mm`；`timeline` 的每個時刻都要落在 `start`…`end` 內，範圍最長 6 小時。`detail`、`timeline`、`time`、`footnote` 可省略。
- 上限：解碼後 8 KB、`conditions` 4 個、`history` 10 筆（日期由舊到新、不可重複）。文字會去掉控制字元並截斷。
- 任一欄位不合規時整張卡片忽略，選單照常顯示文字列。外掛若因有卡片而精簡文字列，應先自行檢查卡片是否合規。
- 圖例與統計用語（自動成功、人工處理、請假、未執行、跳過）目前偏向打卡用途，外掛還不能自訂。

沒有 `href`、`bash`、`refresh` 也沒有子項目的輸出列只是資訊：不會反白、點了也不會動作，文字顏色照常（含 `color=`）。

## 停用與相容性

停用個別外掛後，仍可明確開啟設定。外掛功能整體關閉時，不自動掃描或執行；「掃描外掛設定…」是手動管理入口，不恢復一般計時器。舊外掛若未實作設定協定，手動嘗試開啟設定會顯示格式錯誤，不會修改設定。

外掛自己的獨立背景服務不受選單顯示開關控制，設定介面應清楚提供背景功能的停用方式。設定視窗中的動作只使用已儲存設定；有未儲存變更時，動作按鈕不可操作。

可執行範例見 `config/plugins/settings-demo.1m.py.example`。範例不連線、不啟動背景工作、不讀取任何真實帳號資料。
