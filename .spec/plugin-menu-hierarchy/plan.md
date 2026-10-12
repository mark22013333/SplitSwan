---
slug: plugin-menu-hierarchy
name: 外掛選單分層與可擴充架構
type: feature
verified_at_commit: 3ab0479
verified_at: 2026-10-13
drift_policy: normal
---

# 外掛選單分層與可擴充架構

## 目標與範圍        <!-- crew:goal owner=spec -->
- 將狀態列目前攤平的外掛區段重構為單一「外掛」入口。
- 每支外掛各自擁有子選單，承載原有輸出項目與既有一層子項目。
- 功能關閉或沒有可用外掛時仍保留入口，並顯示對應空狀態。
- 延續執行中、輸出截斷、阻擋錯誤與點擊錯誤的既有語意。
- 將「外掛設定…」與「全部重新整理」固定置於外掛根選單下方。
- 保留既有外掛點擊、安全驗證、排程、通知與效能規則。
- 不變更自動打卡規則，不整併 punch reminder／auto clock-in，也不調整其時間欄位。

## 驗收條件          <!-- crew:ac   owner=spec -->
- [ ] AC-1 無論外掛功能是否啟用，主選單在原外掛錨點皆恆有且僅有一個標題為「外掛」的可展開項目。
- [ ] AC-2 功能關閉時，子選單顯示停用的「外掛功能未啟用」，且不建立外掛計時器、監看器或系統事件訂閱。
- [ ] AC-3 功能開啟但掃描結果為零支外掛時，子選單顯示停用的「沒有可用的外掛」。
- [ ] AC-4 有 N 支外掛時，根選單依 `PluginRunner.plugins` 順序顯示恰好 N 個各自可展開的外掛項目。
- [ ] AC-5 正常外掛的子選單依原輸出順序呈現文字、分隔線、顏色、點擊動作與既有一層子項目。
- [ ] AC-6 尚無輸出的外掛，其子選單顯示停用的「執行中…」。
- [ ] AC-7 輸出遭截斷時，外掛子選單末端顯示停用的「（輸出過長，只顯示前面部分）」。
- [ ] AC-8 外掛有阻擋錯誤時，標題帶「⚠︎」，子選單只直接顯示停用的原因且不顯示輸出項目。
- [ ] AC-9 外掛只有點擊錯誤時，標題帶「⚠︎」，子選單直接顯示原因並保留上次成功輸出項目。
- [ ] AC-10 點擊搬入子選單的既有輸出項目，仍以原外掛 ID 與原項目交由既有執行流程處理。
- [ ] AC-11 根選單底部在分隔線後依序顯示「外掛設定…」與「全部重新整理」。
- [ ] AC-12 點擊「外掛設定…」會開啟 SplitSwan 視窗並切換至設定頁的外掛區塊。
- [ ] AC-13 啟用時點擊「全部重新整理」會觸發全體外掛重新掃描及執行；功能關閉時該項目不可操作。
- [ ] AC-14 自動化測試涵蓋多外掛、關閉、零外掛、執行中、阻擋錯誤、點擊錯誤與截斷的選單樹。
- [ ] AC-15 README 說明「外掛 → 單支外掛 → 輸出項目」層級、空狀態及底部通用操作。

## 決策紀錄          <!-- crew:dec  append-only -->
- D-9 [arch] `PluginMenu` 建立並回傳單一永久啟用的「外掛」根 `NSMenuItem`，`main` 只在既有錨點替換此項目｜理由：由單一元件保證根項目恆有且不重複｜否決：讓 `main` 分別組裝根、外掛與通用操作。
- D-10 [arch] 採純選單樹投影與 AppKit Adapter 兩層，投影只接收啟用狀態及不含服務參照的外掛快照｜理由：依賴維持 `main／PluginRunner → 快照 → 純選單樹 → AppKit` 並可離線測試｜否決：`PluginMenu` 主動讀取單例或將規則寫死在 AppKit 建構流程。
- D-11 [arch] 外掛項目、設定與全部重新整理統一掛命令值，由 `main` 注入單一 target/action 並路由｜理由：呈現層不依賴執行引擎或視窗模型，且保留原外掛 ID 與項目｜否決：在 `PluginMenu` 直接開視窗、呼叫單例或啟動非同步工作。
- D-12 [arch] 空狀態以可發布的執行期啟用狀態搭配外掛快照判定，啟用狀態變化必須觸發重繪｜理由：空陣列無法區分功能關閉與零外掛｜否決：由呈現層讀 `UserDefaults` 或只用 `plugins.isEmpty` 推測。
- D-13 [arch] 錯誤優先序固定為阻擋錯誤高於點擊錯誤；前者只顯示原因，後者先顯示原因及分隔線再保留輸出｜理由：阻擋錯誤使輸出不可採信，點擊錯誤不應抹除快取輸出｜否決：兩類錯誤一律清空、同時顯示多個錯誤或將原因置底。
- D-14 [arch] 測試 seam 設在非 AppKit 的純選單樹投影，納入既有 plugins 測試組比對階層、狀態、命令 payload 與順序｜理由：無須啟動 AppKit 仍可機器驗證資訊架構｜否決：只做人工截圖或把完整 App 啟動流程塞進整合測試。
- D-15 [arch] 不修改 `PluginLogic` 輸出語法；新階層只包裝既有 `Output`／`Item`｜理由：既有腳本、安全限制及一層子項目語意可原封不動沿用｜否決：新增縮排、根節點標記或其他腳本輸出協定。
- D-1 [spec] 範圍判斷：TASK_TYPE=refactor、CHANGE_SCOPE=frontend-only、FRONTEND_REQUIRED=true（FRONTEND_TECH=無）、DB_REQUIRED=false（DB_TABLES=無）、NEW_API=false、EXISTING_API_CHANGE=false｜理由：重構 Swift／AppKit 狀態列選單資訊架構，不涉及資料庫或對外介面｜否決：擴張成外掛執行引擎或資料模型改造。
- D-2 [spec] 採永久存在的單一「外掛」根項目｜理由：入口位置與心智模型穩定｜否決：繼續依外掛數量在主選單增減平面區段。
- D-3 [spec] 每支外掛名稱作為第二層可展開項目｜理由：隔離各外掛輸出與錯誤｜否決：只增加根選單但仍把所有輸出混排。
- D-4 [spec] 阻擋錯誤直接成為外掛子選單內容｜理由：一步即可看到所屬外掛的錯誤｜否決：另建錯誤孫選單或只在設定頁顯示。
- D-5 [spec] 點擊錯誤顯示原因並保留上次輸出｜理由：延續既有可用性承諾｜否決：將點擊失敗視為阻擋錯誤並清空項目。
- D-6 [spec] 通用操作固定置底且與外掛清單分隔｜理由：避免與外掛輸出混淆｜否決：在每支外掛內重複通用操作。
- D-7 [spec] 功能關閉時停用全部重新整理｜理由：維持關閉時零開銷｜否決：讓選單操作暗中啟用、掃描或執行外掛。
- D-8 [spec] 不變更解析、執行、排程及打卡領域規則｜理由：本案只處理呈現架構｜否決：趁重構整併出勤腳本或修改時間決策欄位。

## 已知取捨與風險    <!-- crew:risk append-only -->
- `isActive` 目前不是可發布狀態；若仍只訂閱 `$plugins`，關閉後再啟用但結果同為空時可能不會重繪。
- 選單層級增加後，原有子項目會再深一層，需以完整選單樹測試避免項目遺失。
- `NSMenu.autoenablesItems=false` 下必須明確設定根入口與通用操作的啟用狀態。
- 功能關閉會清空 `plugins`，呈現層須另讀啟用狀態才能區分未啟用與沒有外掛。
- 點擊錯誤與阻擋錯誤若共用同一分支，可能破壞保留上次輸出的既有語意。
- 全部重新整理是非同步工作，快速重複點擊須沿用既有不重疊保護。
- 現有 plugins 測試未編譯 `PluginMenu.swift`，測試路由若不調整將漏掉選單層級回歸。
- README 現有「外掛區段」敘述須同步更新，避免操作指引與 UI 不一致。

## 指路              <!-- crew:map  append-only -->
- 純選單樹投影：`@code:Sources/PluginMenu.swift#PluginMenu.project` (L99)
- 選單階層回歸：`@code:Tests/PluginTests.swift` (L11)
- 選單組裝：`@code:Sources/PluginMenu.swift#PluginMenu.project` (L85)
- 輸出項目遞迴組裝：`@code:Sources/PluginMenu.swift#PluginMenu.outputItem` (L127)
- 主選單錨點：`@code:Sources/main.swift#AppDelegate.pluginAnchor` (L23)
- 主選單建立：`@code:Sources/main.swift#AppDelegate.buildMenu` (L155)
- 外掛重新繪製：`@code:Sources/main.swift#AppDelegate.renderPlugins` (L235)
- 外掛命令路由：`@code:Sources/main.swift#AppDelegate.pluginCommand` (L259)
- 外掛錯誤彙整：`@code:Sources/PluginRunner.swift#PluginRunner.Plugin.failure` (L63)
- 全體重新整理：`@code:Sources/PluginRunner.swift#PluginRunner.refreshAll` (L152)
- 輸出解析：`@code:Sources/PluginLogic.swift#PluginLogic.parseOutput` (L100)
- 外掛整合測試：`@code:Tests/PluginTests.swift` (L185)

## 檢查報告摘要      <!-- crew:rep  append-only -->
- [2026-10-13] review PASS｜🔴0 🟡0｜邏輯、品質與效能複核通過，同一外掛動作維持序列執行
- [2026-10-12] verify WARN｜✅14 ⚠️1 ❌0 🚧0 ⏭️0 👤0｜Health 97
- [2026-10-12] security PASS｜🔴0 🟡0｜輸出節點上限與停用／暫停生命週期防線重驗通過
- [2026-10-12] review FAIL｜🔴1 🟡2｜子分隔線可繞過項目上限；另有生命週期競態與空白子選單
- [2026-10-12] verify WARN｜✅14 ⚠️1 ❌0 🚧0 ⏭️0 👤0｜Health 97
- [2026-10-12] security WARN｜🔴0 🟡1｜非同步重新整理可能在停用或暫停切換後仍開始，需統一重驗生命週期狀態
