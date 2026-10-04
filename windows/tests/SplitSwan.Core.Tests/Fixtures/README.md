# Core 測試 fixture

這裡的 `render-*`、`validate-cases.json`、`*.splitswan` 都是用 **Mac 版 Swift 原始碼實際跑出來的**，
用來證明 C# 版與 Mac 版行為一致（設定檔逐字相同、驗證訊息相同、能解開 Mac 匯出的 .splitswan）。

- `.gitattributes` 設 `-text`：Windows 上 git 不可把 LF 轉成 CRLF，否則逐字比對會失真。
- `validate-cases.json` 產生後做過一次替換：Mac 錯誤訊息裡的範例網段改成 RFC 5737 的 `192.0.2.0/24`（公開 repo 規定，C# 版訊息也用這個範例）。
- `*.splitswan` 的密碼：`demo`、`evil` 是 `correct horse`；`nopsk-nfc` 是 `café-pass`（NFC）。
- 每次加密都用新的隨機 salt／nonce，重新產生後檔案內容會不同，但測試結果應相同。

## 重新產生（macOS）

`renderSecrets` 在 Mac 版是 private，產生時用暫存複本把 private 拿掉，不改 `Sources/`：

```bash
R=/path/to/SplitSwan          # repo 根目錄
T=$(mktemp -d)
sed 's/private static func renderSecrets/static func renderSecrets/' "$R/Sources/ConfigStore.swift" > "$T/ConfigStore.swift"
cp "$R/windows/tests/SplitSwan.Core.Tests/Fixtures/generate-fixtures.swift" "$T/main.swift"
swiftc -O -o "$T/gen" "$T/main.swift" "$T/ConfigStore.swift" \
  "$R/Sources/CompanyPreset.swift" "$R/Sources/AppInfo.swift" "$R/Sources/ConfigExport.swift"
"$T/gen" "$R/windows/tests/SplitSwan.Core.Tests/Fixtures"
sed -i '' 's#（例：10\.0\.0\.0/8）#（例：192.0.2.0/24）#g' "$R/windows/tests/SplitSwan.Core.Tests/Fixtures/validate-cases.json"
```

## gateway-cases.json（F4 閘道排序，對應 Sources/GatewayHistory.swift）

固定種子的亂數產生 200 組歷史，加上 shouldRecord、gateway(fromConnection:) 的邊界輸入，用 Mac 版原始碼實跑出期望值：

```bash
R=/path/to/SplitSwan
T=$(mktemp -d)
cp "$R/windows/tests/SplitSwan.Core.Tests/Fixtures/generate-gateway-fixtures.swift" "$T/main.swift"
swiftc -O -o "$T/gen" "$T/main.swift" "$R/Sources/GatewayHistory.swift"
"$T/gen" "$R/windows/tests/SplitSwan.Core.Tests/Fixtures"
```

## segoe-glyphs-both.json（托盤圖示字碼）

Microsoft Learn 的 Segoe Fluent Icons 與 Segoe MDL2 Assets 兩張官方對照表中，**兩套都有**的字碼與官方名稱（2026-10-04 取得）。
`TrayIconCatalog` 用到的每個字碼都必須在這張表裡（`TrayIconCatalogTests` 檢查）。來源：
- https://learn.microsoft.com/en-us/windows/apps/design/iconography/segoe-fluent-icons-font
- https://learn.microsoft.com/en-us/windows/apps/design/iconography/segoe-ui-symbol-font
