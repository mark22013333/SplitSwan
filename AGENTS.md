# Repository Guidelines

## 專案結構與模組組織

主要 macOS App 程式碼位於 `Sources/`，依功能拆分為 VPN 控制、設定、診斷、更新與外掛模組。`Tests/` 內是以 Swift 小程式執行的測試群組；新增來源檔時，請同步更新 `Tests/run-tests.sh` 對應群組的檔案清單。`config/` 放可公開的設定與外掛範例，`tools/` 放測試、圖示及發布工具。根目錄的 shell 腳本負責建置、安裝與系統元件。

## 建置、測試與開發指令

- `bash build.sh`：以 `swiftc` 編譯並 ad-hoc 簽署 `build/SplitSwan.app`。
- `bash build.sh --install`：建置後安裝至 `/Applications`；會結束目前 App，但不會中斷 VPN 通道。
- `bash Tests/run-tests.sh`：執行全部測試，不連 VPN、不需 `sudo`。
- `bash Tests/run-tests.sh plugins`：只跑指定群組；可同時列出多組。
- `bash make-dmg.sh`：檢查版本、跑完整測試並產生已簽署的發布檔。

## 程式風格與命名

Swift 使用 4 個空白縮排，型別採 `UpperCamelCase`，方法與屬性採 `lowerCamelCase`。純邏輯應與 AppKit／SwiftUI 介面分離，方便離線測試。Shell 腳本使用 `set -euo pipefail`，變數緊接非 ASCII 字元時寫成 `${NAME}`。註解著重安全邊界與非直覺原因，不重述程式碼。

## 測試準則

測試不使用 XCTest；腳本會將測試檔複製成 `main.swift` 後獨立編譯。每項修正需包含正常、邊界與失敗案例。涉及非同步或排程時，使用可觀測條件等待，避免固定睡眠造成偶發失敗。提交前至少跑受影響群組及完整測試。

## Commit 與 Pull Request

沿用 Git 歷史中的前綴，例如 `feat:`, `fix:`, `test:`, `docs:` 與 `chore(release):`。Commit 應單一目的、訊息用繁體中文說明結果。PR 需描述行為變更、測試證據與風險；UI 變更附截圖，關聯既有 issue 或規格。

## 安全與設定

這是公開 repo。不得提交真實公司名稱、閘道、內網位址、帳密、私鑰或 `company.env`。範例位址使用 RFC 5737 保留網段。外掛不得經 `sudo` 或 helper 執行；修改檔案驗證、URL、程序環境或更新簽章時，必須保留既有安全測試。
