<#
SplitSwan Windows 版真機檢查（唯讀）：不連線、不斷線、不改設定，只讀目前狀態並逐項列出 PASS／FAIL／SKIP。

用法（在要檢查的 Windows 上，最好用系統管理員 PowerShell）：
  powershell -ExecutionPolicy Bypass -File windows\tools\verify-windows.ps1 [-AppDir <SplitSwan.exe 所在資料夾>] [-Build]

-AppDir：省略時依序找執行中的 SplitSwan.exe、%ProgramFiles%\SplitSwan、%UserProfile%\SplitSwan。
-Build：另外在 Windows 上建置並跑單元測試（需要 .NET 10 SDK；找 PATH 與 %LOCALAPPDATA%\Microsoft\dotnet）。
輸出不含密碼、PSK，內部位址一律遮成 x.x.x.x，可以直接貼給維護者。結束碼＝FAIL 的項目數。
#>
param(
    [string]$AppDir,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:WSL_UTF8 = '1'

$script:Fails = 0
function Report([string]$Result, [string]$Name, [string]$Detail = '', [switch]$NoMask) {
    if ($Result -eq 'FAIL') { $script:Fails++ }
    $masked = if ($NoMask) { $Detail } else { $Detail -replace '\b\d{1,3}(\.\d{1,3}){3}(/\d+)?\b', 'x.x.x.x' }
    Write-Host ('{0,-4}  {1}{2}' -f $Result, $Name, $(if ($masked) { "：$masked" } else { '' }))
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body } catch { Report 'FAIL' $Name "檢查本身出錯：$($_.Exception.Message)" }
}

$DataDir = Join-Path $env:LOCALAPPDATA 'SplitSwan'
$repoRoot = Split-Path (Split-Path $PSScriptRoot)

Write-Host "== 系統"
Check '作業系統' {
    $v = [Environment]::OSVersion.Version
    if ($v.Build -ge 19041) { Report 'PASS' '作業系統' "組建 $($v.Build)" } else { Report 'FAIL' '作業系統' "組建 $($v.Build) 低於 19041" }
}
Check '架構' {
    $a = $env:PROCESSOR_ARCHITECTURE
    if ($a -eq 'AMD64') { Report 'PASS' '架構' $a } else { Report 'FAIL' '架構' "$a（只支援 x64）" }
}
Check '系統管理員' {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) { Report 'PASS' '系統管理員' '這個 PowerShell 已提權' } else { Report 'SKIP' '系統管理員' '這個 PowerShell 沒有提權，路由與 NRPT 檢查可能讀不完整' }
}

Write-Host "== App"
$proc = Get-Process SplitSwan -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $AppDir) {
    $AppDir = @(
        $(if ($proc -and $proc.Path) { Split-Path $proc.Path }),
        (Join-Path $env:ProgramFiles 'SplitSwan'),
        (Join-Path $env:USERPROFILE 'SplitSwan')
    ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'SplitSwan.exe')) } | Select-Object -First 1
}
$exe = if ($AppDir) { Join-Path $AppDir 'SplitSwan.exe' } else { $null }
Check 'SplitSwan.exe' {
    if ($exe -and (Test-Path $exe)) {
        Report 'PASS' 'SplitSwan.exe' "$((Get-Item $exe).VersionInfo.ProductVersion -replace '\+.*$', '')（$AppDir）" -NoMask
    } else { Report 'FAIL' 'SplitSwan.exe' '找不到；用 -AppDir 指定' }
}
Check '執行中' {
    if ($proc) { Report 'PASS' '執行中' "PID $($proc.Id)，啟動於 $($proc.StartTime)" } else { Report 'SKIP' '執行中' 'App 沒有在執行' }
}
$ps1 = if ($AppDir) { Join-Path $AppDir 'engine\splitswan-wsl.ps1' } else { $null }
Check '連線引擎' {
    $sh = if ($AppDir) { Join-Path $AppDir 'engine\splitswan-wsl.sh' } else { $null }
    if (-not ($ps1 -and (Test-Path $ps1) -and (Test-Path $sh))) { Report 'FAIL' '連線引擎' 'engine\ 缺少 splitswan-wsl.ps1 或 .sh'; return }
    if (-not (Select-String -Path $ps1 -Pattern '\[string\]\$Order' -Quiet)) { Report 'FAIL' '連線引擎' 'splitswan-wsl.ps1 是不支援 -Order 的舊版'; return }
    if ([IO.File]::ReadAllText($sh).Contains("`r")) { Report 'FAIL' '連線引擎' 'splitswan-wsl.sh 含 CR，WSL 內會執行失敗'; return }
    Report 'PASS' '連線引擎' 'ps1 支援 -Order，sh 是 LF'
}

Write-Host "== 設定"
$settings = $null
Check 'settings.json' {
    $f = Join-Path $DataDir 'settings.json'
    if (-not (Test-Path $f)) { Report 'FAIL' 'settings.json' '不存在（還沒存過設定）'; return }
    $script:settings = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $s = $script:settings
    $missing = @('username', 'passwordProtected', 'pskProtected', 'gateways', 'remoteSubnets') |
        Where-Object { -not $s.$_ }
    if ($missing) { Report 'FAIL' 'settings.json' "缺少欄位：$($missing -join ', ')"; return }
    Report 'PASS' 'settings.json' "$(@($s.gateways | Where-Object { $_ }).Count) 台閘道、$(@($s.remoteSubnets).Count) 個網段、發行版 $($s.distro)"
}
Check '密碼加密' {
    if (-not $settings) { Report 'SKIP' '密碼加密' '沒有設定'; return }
    Add-Type -AssemblyName System.Security
    $bad = @()
    foreach ($k in 'passwordProtected', 'pskProtected') {
        try {
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
                [Convert]::FromBase64String($settings.$k), [Text.Encoding]::UTF8.GetBytes('SplitSwan.Settings.v1'),
                [Security.Cryptography.DataProtectionScope]::CurrentUser)
            [Array]::Clear($bytes, 0, $bytes.Length)
        } catch { $bad += $k }
    }
    if ($bad) { Report 'FAIL' '密碼加密' "目前帳號解不開：$($bad -join ', ')（換了帳號或電腦，或不是用執行 App 的帳號跑本腳本）" }
    else { Report 'PASS' '密碼加密' 'DPAPI 可由目前帳號解開（內容未讀出）' }
}
Check 'wizard.json' {
    $f = Join-Path $DataDir 'wizard.json'
    if (-not (Test-Path $f)) { Report 'SKIP' 'wizard.json' '不存在（沒跑過精靈）'; return }
    $w = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $steps = ($w.steps.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
    $errs = @($w.errors.PSObject.Properties).Count
    $r = if ($errs) { 'FAIL' } else { 'PASS' }
    Report $r 'wizard.json' "目前步驟 $($w.current)；$steps；錯誤 $errs 筆；等待重開機 $($w.rebootPending)"
}

Write-Host "== WSL"
$distro = if ($settings -and $settings.distro) { $settings.distro } else { 'Ubuntu-24.04' }
Check 'WSL' {
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path $wsl)) { Report 'FAIL' 'WSL' '沒有 wsl.exe'; return }
    $ver = (& $wsl --version 2>$null | Select-Object -First 1) -replace "`0", ''
    $list = (& $wsl -l -v 2>$null) -replace "`0", '' | Where-Object { $_ -match '\S' } | Select-Object -Skip 1
    $row = $list | Where-Object { ($_ -replace '^\*', '').Trim() -match "^$([regex]::Escape($distro))\s" }
    if (-not $row) { Report 'FAIL' 'WSL' "$ver；找不到發行版 $distro"; return }
    $cols = ($row -replace '^\*', '').Trim() -split '\s+'
    if ($cols[-1] -ne '2') { Report 'FAIL' 'WSL' "發行版 $distro 是 WSL $($cols[-1])，需要 WSL 2"; return }
    Report 'PASS' 'WSL' "$ver；$distro $($cols[1])，WSL 2" -NoMask
}
Check '.wslconfig' {
    $f = Join-Path $env:USERPROFILE '.wslconfig'
    if (-not (Test-Path $f)) { Report 'PASS' '.wslconfig' '沒有（預設 NAT）'; return }
    $mode = Select-String -Path $f -Pattern '^\s*networkingMode\s*=\s*(\S+)' | Select-Object -First 1
    if ($mode -and $mode.Matches[0].Groups[1].Value -ne 'nat') { Report 'FAIL' '.wslconfig' "networkingMode=$($mode.Matches[0].Groups[1].Value)，只支援 NAT" }
    else { Report 'PASS' '.wslconfig' 'NAT 模式' }
}

Write-Host "== 連線（唯讀查詢）"
$state = $null
Check '通道狀態' {
    if (-not ($ps1 -and (Test-Path $ps1))) { Report 'SKIP' '通道狀態' '沒有連線引擎'; return }
    $out = & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass `
        -File $ps1 -Action brief -ConfDir (Join-Path $DataDir 'conf') -Distro $distro 2>&1 | ForEach-Object { "$_" }
    $kv = @{}
    foreach ($l in $out) { if ($l -match '^@@([A-Z]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2].Trim() } }
    $script:state = $kv['STATE']
    switch ($kv['STATE']) {
        'up' { Report 'PASS' '通道狀態' "已連線 $($kv['GATEWAY'])，虛擬 IP $($kv['VIP'])" }
        'down' { Report 'SKIP' '通道狀態' '未連線（路由檢查略過）' }
        default { Report 'FAIL' '通道狀態' "查不到（$($kv['RESULT'])）" }
    }
}
Check '分流路由' {
    if ($state -ne 'up' -or -not $settings) { Report 'SKIP' '分流路由' '未連線'; return }
    $wrong = @()
    foreach ($cidr in @($settings.remoteSubnets)) {
        $ip = ($cidr -split '/')[0]
        $route = Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias } | Select-Object -First 1
        if (-not $route -or $route.InterfaceAlias -notlike 'vEthernet*') { $wrong += "$cidr→$($route.InterfaceAlias)" }
    }
    if ($wrong) { Report 'FAIL' '分流路由' "沒走 vEthernet：$($wrong -join '，')" }
    else { Report 'PASS' '分流路由' "$(@($settings.remoteSubnets).Count) 個網段都走 vEthernet" }
}
Check '一般流量' {
    if ($state -ne 'up') { Report 'SKIP' '一般流量' '未連線'; return }
    $route = Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias } | Select-Object -First 1
    if ($route.InterfaceAlias -like 'vEthernet*') { Report 'FAIL' '一般流量' '公網流量也走 WSL，不是 split tunnel' }
    else { Report 'PASS' '一般流量' "公網走 $($route.InterfaceAlias)" }
}

Write-Host "== 捷徑"
$shell = New-Object -ComObject WScript.Shell
foreach ($place in @(
        @{ Name = '桌面捷徑'; Dir = [Environment]::GetFolderPath('Desktop') },
        @{ Name = '開始選單捷徑'; Dir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Start Menu\Programs' })) {
    Check $place.Name {
        $lnk = Join-Path $place.Dir 'SplitSwan.lnk'
        if (-not (Test-Path $lnk)) { Report 'SKIP' $place.Name '沒有建立'; return }
        $s = $shell.CreateShortcut($lnk)
        if ($s.Description -ne 'SplitSwan VPN') { Report 'SKIP' $place.Name '同名捷徑不是 SplitSwan 建立的'; return }
        if ($exe -and $s.TargetPath -ne $exe) { Report 'FAIL' $place.Name "指向舊位置 $($s.TargetPath)"; return }
        Report 'PASS' $place.Name "指向 $($s.TargetPath)"
    }
}

if ($Build) {
    Write-Host "== 建置與單元測試"
    Check '單元測試' {
        $dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
        if (-not $dotnet) { $dotnet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe' }
        if (-not (Test-Path $dotnet)) { Report 'FAIL' '單元測試' '找不到 .NET SDK'; return }
        $sln = Join-Path $repoRoot 'windows\SplitSwan.Windows.sln'
        $ErrorActionPreference = 'Continue'
        $out = & $dotnet test $sln --nologo -v q 2>&1 | ForEach-Object { "$_" }
        $summary = $out | Where-Object { $_ -match '(Passed|Failed)!|總計|Total tests' } | Select-Object -Last 1
        if ($LASTEXITCODE -eq 0) { Report 'PASS' '單元測試' $summary.Trim() }
        else { $out | Select-Object -Last 30 | ForEach-Object { Write-Host "      $_" }; Report 'FAIL' '單元測試' "結束碼 $LASTEXITCODE" }
    }
}

Write-Host
Write-Host $(if ($Fails) { "有 $Fails 項 FAIL" } else { '全部通過（SKIP 是沒有可檢查的對象）' })
exit $Fails
