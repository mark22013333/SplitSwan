#!/bin/bash
# 單元測試：每組測試是一支獨立的小程式，只編譯它需要的原始檔。
#   bash Tests/run-tests.sh                   跑全部組別（各組並行編譯與執行）
#   bash Tests/run-tests.sh security update   只跑指定的組
# 不會連線 VPN、不需要 sudo，也不會寫入 ~/.config 或 /opt/homebrew。
# 編譯用 -Onone：測試只驗邏輯，省下最佳化的時間（App 本身仍由 build.sh 用 -O 編譯）。
set -uo pipefail
cd "$(dirname "$0")/.."
S=Sources
OUT=$(mktemp -d)
trap 'command rm -r "$OUT"' EXIT

ALL_GROUPS="reconnect export security settings diagnostic hostcheck update about plugins"

# 每組的測試檔與要一起編譯的原始檔（第一個是測試檔，會被複製成 main.swift）。
# 新增 Sources 檔時，要加進用到它的每一組，否則該組會編譯失敗。
files() {
  case $1 in
    reconnect)  echo Tests/ReconnectTests.swift $S/VPNController.swift $S/GatewayHistory.swift $S/DropNotifier.swift \
                     $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift $S/LogStore.swift \
                     $S/ProcessRunner.swift $S/DiagnosticReport.swift ;;
    export)     echo Tests/ExportTests.swift $S/ConfigExport.swift $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift ;;
    security)   echo Tests/SecurityTests.swift $S/ConfigExport.swift $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift ;;
    settings)   echo Tests/SettingsFormatTests.swift $S/SettingsLogic.swift $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift ;;
    diagnostic) echo Tests/DiagnosticTests.swift $S/DiagnosticReport.swift $S/GatewayHistory.swift $S/ConfigStore.swift \
                     $S/CompanyPreset.swift $S/AppInfo.swift ;;
    hostcheck)  echo Tests/HostCheckTests.swift $S/HostCheck.swift $S/DiagnosticReport.swift $S/GatewayHistory.swift \
                     $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift ;;
    update)     echo Tests/UpdateTests.swift $S/UpdateLogic.swift $S/UpdateInstaller.swift $S/ProcessRunner.swift $S/AboutInfo.swift \
                     $S/AppInfo.swift $S/DiagnosticReport.swift $S/GatewayHistory.swift $S/ConfigStore.swift $S/CompanyPreset.swift ;;
    about)      echo Tests/AboutTests.swift $S/AboutInfo.swift $S/AppInfo.swift ;;
    plugins)    echo Tests/PluginTests.swift $S/PluginLogic.swift $S/PluginRunner.swift $S/ProcessRunner.swift $S/DiagnosticReport.swift \
                     $S/GatewayHistory.swift $S/ConfigStore.swift $S/CompanyPreset.swift $S/AppInfo.swift ;;
    *) return 1 ;;
  esac
}

# 編譯並執行一組，結果寫進 $OUT/<組名>/status：pass／fail／compile（編譯失敗）
run_group() {
  local name=$1 dir="$OUT/$1"
  # shellcheck disable=SC2046
  set -- $(files "$name")
  local test=$1; shift
  cp "$test" "$dir/main.swift"
  if ! swiftc -Onone -o "$dir/t" "$dir/main.swift" "$@" >"$dir/compile.log" 2>&1; then
    echo compile >"$dir/status"; return
  fi
  "$dir/t" "$dir" >"$dir/log" 2>&1
  local rc=$?
  # 結尾那行是「通過 N，失敗 M」；M 必須剛好是 0，且程式正常結束
  if [ "$rc" = 0 ] && grep -Eq "失敗 0$" "$dir/log"; then echo pass >"$dir/status"; else echo fail >"$dir/status"; fi
}

if [ $# -gt 0 ]; then SELECTED="$*"; else SELECTED=$ALL_GROUPS; fi
QUEUE=""
for g in $SELECTED; do
  if ! files "$g" >/dev/null; then echo "未知的測試組：${g}（可用：${ALL_GROUPS}）" >&2; exit 2; fi
  [ -d "$OUT/$g" ] && continue   # 同一組指定兩次只跑一次
  mkdir -p "$OUT/$g"; QUEUE="$QUEUE $g"
done

START=$SECONDS
for g in $QUEUE; do run_group "$g" & done
wait

# 依組別順序輸出，每組的結果集中在一起，不會和其他組交錯
FAILED=0
for g in $QUEUE; do
  dir="$OUT/$g"
  st=$(cat "$dir/status" 2>/dev/null || echo fail)
  case $st in
    pass)    echo "▸ $g ✅ $(grep -E "通過 " "$dir/log" | tail -1)"
             grep "⚠️" "$dir/log" ;;   # 略過的項目也要讓人看到
    compile) echo "▸ $g ❌ 編譯失敗"; cat "$dir/compile.log"; FAILED=1 ;;
    *)       echo "▸ $g ❌"
             if grep -qE "❌|通過 " "$dir/log" 2>/dev/null; then grep -E "❌|⚠️|通過 " "$dir/log"; else tail -20 "$dir/log" 2>/dev/null; fi
             FAILED=1 ;;
  esac
done

echo "（耗時 $((SECONDS - START)) 秒）"
if [ "$FAILED" = 0 ]; then echo "✅ 全部通過"; else echo "❌ 有測試失敗"; exit 1; fi
