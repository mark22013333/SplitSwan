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
