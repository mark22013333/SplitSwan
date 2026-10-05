#!/bin/bash
# 單元測試：每組測試是一支獨立的小程式，只編譯它需要的原始檔。
#   bash Tests/run-tests.sh
# 不會連線 VPN、不需要 sudo，也不會寫入 ~/.config 或 /opt/homebrew。
set -uo pipefail
cd "$(dirname "$0")/.."
S=Sources
OUT=$(mktemp -d)
trap 'command rm -r "$OUT"' EXIT
printf 'enum AppActions { static func openLog() {} }\n' > "$OUT/stub.swift"

FAILED=0
run() {  # 名稱 測試檔 原始檔...
  local name=$1 test=$2; shift 2
  echo "▸ $name"
  local dir="$OUT/$name"; mkdir -p "$dir"
  cp "$test" "$dir/main.swift"
  if ! swiftc -O -o "$dir/t" "$dir/main.swift" "$@" 2>"$dir/err"; then cat "$dir/err"; FAILED=1; return; fi
  "$dir/t" "$dir" | tee "$dir/log" | grep -E "❌|通過 "
  grep -q "失敗 0" "$dir/log" || FAILED=1
}

run reconnect Tests/ReconnectTests.swift $S/VPNController.swift $S/GatewayHistory.swift $S/DropNotifier.swift $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift $S/LogStore.swift
run export    Tests/ExportTests.swift    $S/ConfigExport.swift $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift
run security  Tests/SecurityTests.swift  $S/ConfigExport.swift $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift
run settings  Tests/SettingsFormatTests.swift "$OUT/stub.swift" $S/MainView.swift $S/VPNController.swift $S/GatewayHistory.swift $S/DropNotifier.swift $S/ConfigStore.swift \
              $S/CompanyPreset.swift $S/AppInfo.swift $S/EnvChecker.swift $S/MenuBarIcon.swift $S/ConfigExport.swift $S/LogStore.swift \
              $S/DiagnosticReport.swift $S/DiagnosticRunner.swift $S/AboutInfo.swift \
              $S/HostCheck.swift $S/HostCheckRunner.swift $S/HostCheckPanel.swift $S/UpdateLogic.swift $S/UpdateCenter.swift $S/UpdateInstaller.swift $S/ProcessRunner.swift
run diagnostic Tests/DiagnosticTests.swift $S/DiagnosticReport.swift $S/GatewayHistory.swift $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift
run hostcheck Tests/HostCheckTests.swift $S/HostCheck.swift $S/DiagnosticReport.swift $S/GatewayHistory.swift $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift
run update    Tests/UpdateTests.swift    $S/UpdateLogic.swift $S/UpdateInstaller.swift $S/ProcessRunner.swift $S/AboutInfo.swift $S/AppInfo.swift \
              $S/DiagnosticReport.swift $S/GatewayHistory.swift $S/ConfigStore.swift $S/CompanyPreset.swift
run about     Tests/AboutTests.swift     $S/AboutInfo.swift $S/AppInfo.swift

if [ "$FAILED" = 0 ]; then echo "✅ 全部通過"; else echo "❌ 有測試失敗"; exit 1; fi
