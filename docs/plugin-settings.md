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
- 動作可宣告 `shortcut: "k"`：單一小寫英文字母或數字，設定視窗開著時在任何頁籤按 ⌘ 加此鍵，等同按下按鈕；按鈕旁顯示「⌘K」。`destructive` 動作仍會先跳確認，確認視窗按 Enter 執行、Esc 取消。同一份 snapshot 內不可重複，也不可使用 s、w、q、h、m、a、c、v、x、z 與逗號（App 已用於儲存與標準指令）。舊版 App 忽略此鍵。
- 每支外掛的設定視窗右上角有「快捷鍵」，由使用者錄製或清除，在任何 App 按下即開啟該外掛的設定視窗；這是 App 的設定，外掛不必實作，變更立即生效、不進入儲存流程。新外掛預設不綁；同一組不可同時給兩支外掛；外掛移除後它的熱鍵不再註冊。只在外掛啟用時註冊。從 1.9.17 升級時，原本的單一熱鍵（預設 ⌃⌥⌘K）轉給當時會開啟的那支外掛。
- 文字有長度上限：`eyebrow` 60、`headline` 80、`reason` 200、指標標題 40、指標值 80、指標補充 200、徽章 24、群組標題 60、群組說明 2000、列標題 40、列值 300 個字元。所有文字仍經過與其他欄位相同的控制字元與雙向文字過濾。

頂端訊息顯示目前背景工作的 `job.message`。由設定視窗觸發的工作會加上動作標題與觸發時間；工作結束後可關閉訊息，使用者切換到其他頁籤時已成功的訊息自動收起（開窗後第一次進入頁籤不收起），失敗訊息保留到使用者關閉或下一個工作開始。

### 日期標記編輯器（`dates`，選填）

在 `type: "stringList"` 欄位上加 `dates` 物件，新版 App 就會把這個欄位畫成月曆編輯器。舊版 App 會忽略這個鍵，照常畫成多行文字框。不需要提高 `minimumAppVersion`，也沒有能力協商。

- **值**：仍是字串陣列，每個元素是一行正規行：`YYYY-MM-DD <optionId>[ <備註>]`。陣列依日期遞增排序，日期不重複。
- **正規行文法**：日期必須是真實存在的日期（不接受 2026-02-30），數字只收 `[0-9]`。`optionId` 必須是欄位 `options[].id` 之一。備註為 1～`noteLimit` 個 Unicode scalar，不含 Cc／Cf／Zl／Zp 與 `|`，前後不能有空白，也不能有連續空白或 tab。各部分之間剛好一個半形空白；沒有備註時行尾不留空白。
- **新版 App 的驗證**：帶 `dates` 的欄位逐行嚴格驗證，任何一行不合規就**整份 snapshot 拒收**（與其他欄位的 decode 規則相同）。值必須由外掛產生，不可直接轉送使用者手寫的內容。早於 `earliest` 的既有行仍可接受，`earliest`／`latest` 只限制新套用的日期。
- **外掛 save 必須寬鬆解析**：舊版 App 會原樣送回文字框內容，可能有空行、多餘空白、順序錯亂或同日重複。外掛要去頭尾空白、跳過空行、同日以最後一行為準，再正規化；錯誤訊息要附行號。
- 帶 `dates` 的欄位不可放進 `groups[].fields`，只能放在獨立欄位，編輯器會佔滿整個寬度。新版 App 不顯示這個欄位的 `help`，因為它是寫給舊版文字框的格式說明；給月曆使用者的說明請放在頁籤的 `help`。
- App 只寫 `draft[fieldID]`，所有修改都走既有的「草稿 → 儲存」流程，不會呼叫外掛動作。新版 App 送出的備註已把任何空白換成一個半形空白並去頭尾。

| 鍵 | 必填 | 規則 | App 怎麼用 |
|----|------|------|-----------|
| `options`（Field 既有） | 是 | 1～8 個；id 符合 `[a-z][a-z0-9-]{0,15}` | 分段選擇器；第 0 個在月曆上畫空心圈，其餘畫實心點 |
| `dates.today` | 是 | `YYYY-MM-DD`，外掛時區的今天 | 區分「即將生效／已過期」與「今」標記；App 不使用本機時鐘 |
| `dates.noteLimit` | 否 | 1～60，預設 20 | 輸入到上限後無法再輸入，不截斷 |
| `dates.maxEntries` | 否 | 1～400，預設 400 | 套用後若超過上限，停用「套用」按鈕並說明原因 |
| `dates.earliest`／`latest` | 否 | `earliest ≤ today ≤ latest` | 限制月曆翻頁範圍與「從／到」可選範圍 |
| `dates.locked` | 否 | `null` 或 1～200 字的原因 | 有原因時編輯器唯讀，並顯示原因 |
| `dates.expiredHelp` | 否 | ≤ 200 字 | 「已過期」段首的說明 |
| `dates.baseline` | 否 | 見下 | 灰字、「原本：…」、預設類型取反 |
| `baseline.title`／`weeklyTitle` | 是 | 1～40 字 | 「原本：上班（政府日曆）」 |
| `baseline.weekly` | 是 | 7 個 option id，索引 0＝週日 | `known` 範圍外的日子用它推定 |
| `baseline.known` | 否 | `{from,to}`，`from ≤ to` | 範圍外顯示「（以週一至週五推定）」 |
| `baseline.days` | 是 | ≤ 400 筆 `{date, option, label?}`，日期不重複，`label` 1～40 字；只列與 weekly 不同或需要標籤的日子 | 例外日 |

月曆上的灰字代表原本判定不是第 0 個選項。選取的日子原本判定全部相同時，「覆寫為」預設成另一個選項；混合或沒有 `baseline` 時沿用上一次的選擇。

「每週」模式在 App 端把勾選的星期展開成一般的正規行，寫進同一個欄位，外掛不需要任何改動。範圍是開始日期到結束日期前一天，結束日期當天不套用。結束選「不限」時展開到 `latest`（沒宣告時是 `today` 起兩年），到期不會自動延長，仍受 `maxEntries` 限制；已有覆寫的日子會略過並保留原設定。清單會把同類型、同備註、剛好相隔 7 天的單日合成「每週X」一列，按「移除」一次刪掉整串。

snapshot 片段（日期與備註均為虛構）：

```json
{
  "tabs": [ { "id": "overrides", "title": "手動覆寫", "hidden": true,
              "help": "覆寫優先於政府日曆與週一至週五。「上班」覆寫仍須通過請假檢查。" } ],
  "actions": [ { "id": "overrides-open", "tab": "settings", "title": "管理…", "opensTab": "overrides" } ],
  "fields": [ {
    "id": "overrides", "tab": "overrides", "title": "手動覆寫", "type": "stringList",
    "help": "每行一筆：YYYY-MM-DD work|off 備註（20 字內）。同一天寫兩行以最後一行為準。更新 SplitSwan 後會改成月曆。",
    "options": [ { "id": "work", "title": "上班" }, { "id": "off", "title": "放假" } ],
    "dates": {
      "today": "2026-11-06", "noteLimit": 20, "maxEntries": 400,
      "earliest": "2025-11-06", "latest": "2028-11-06", "locked": null,
      "expiredHelp": "近 45 天內的覆寫仍會影響選單「近期紀錄」的分類。",
      "baseline": {
        "title": "政府日曆", "weekly": ["off","work","work","work","work","work","off"],
        "weeklyTitle": "週一至週五", "known": { "from": "2026-01-01", "to": "2026-12-31" },
        "days": [ { "date": "2026-10-09", "option": "off", "label": "範例補假" },
                  { "date": "2026-10-10", "option": "off", "label": "範例節日" } ] } } } ],
  "values": { "overrides": [ "2026-11-10 off 員工旅遊", "2026-11-11 off 員工旅遊", "2026-11-21 work 補上班" ] }
}
```

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

## 設定基準（選填）

使用者可以在設定視窗按「記住目前設定」，之後只要原本已設定的項目變成空的或被關掉，App 就會提醒。外掛不用實作任何東西就能使用；下面兩個鍵只讓判斷更準確。兩者都可省略，舊版 App 會忽略它們。

```json
{
  "fields": [
    {"id": "password", "tab": "account", "title": "密碼", "type": "secret"},
    {"id": "previewDate", "tab": "general", "title": "預覽日期", "type": "text", "baseline": false}
  ],
  "values": {"password": "", "previewDate": "2026-11-11"},
  "configured": ["password"]
}
```

- `configured`：列出已有儲存值的 `secret` 欄位 id。每個 id 都必須是本份 snapshot 的 `secret` 欄位，不可重複，否則整份 snapshot 拒收。secret 的 `value` 仍必須是空字串。省略 `configured` 時，App 無從得知機密是否存在，所有 secret 欄位都不納入基準。
- `baseline: false`：此欄位不納入基準，適用每天都會變、或本來就允許留空的欄位。
- 基準只記「哪些欄位必須保持已設定」，不記值，改時間不算缺漏。已設定的判定是：`text`、`time`、`select` 非空字串；`stringList`、`multiselect` 非空陣列；`toggle` 為 true；`secret` 列在 `configured` 裡。`readonly` 不參與。
- 基準只會自動往上加：每次評估時，新設定好的欄位自動併入。欄位變少一律提醒，使用者按「這是刻意的」才從基準移除。基準內的欄位不在目前 snapshot 裡（例：切換模式後隱藏）時視為不適用，不提醒也不移除。
- 主動檢查：外掛功能啟用、電腦喚醒並解鎖、套件更新完成後，App 對有基準的外掛呼叫一次 `snapshot`。沒有按過「記住目前設定」的外掛不會被呼叫。有缺漏時選單標題加 ⚠︎、子選單第一列可開啟設定，並發一則「外掛：<名稱>」通知；這類提醒不佔外掛自己的每日通知上限，另外計算：同一組缺漏每天只通知一次，每支外掛每天最多 3 則。
- 基準存在 App 的外掛狀態資料夾（`.baseline/<外掛識別>.json`，600），提醒紀錄在 `.baseline-reminded/<外掛識別>.json`，外掛不應讀寫。
- 「記住目前設定」時若沒有任何已設定的項目，不建立基準，視窗會提示「目前沒有已設定的項目可以記住」。

## 停用與相容性

停用個別外掛後，仍可明確開啟設定。外掛功能整體關閉時，不自動掃描或執行；「掃描外掛設定…」是手動管理入口，不恢復一般計時器。舊外掛若未實作設定協定，手動嘗試開啟設定會顯示格式錯誤，不會修改設定。

外掛自己的獨立背景服務不受選單顯示開關控制，設定介面應清楚提供背景功能的停用方式。設定視窗中的動作只使用已儲存設定；有未儲存變更時，動作按鈕不可操作。

可執行範例見 `config/plugins/settings-demo.1m.py.example`。範例不連線、不啟動背景工作、不讀取任何真實帳號資料。
