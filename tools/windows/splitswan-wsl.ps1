<#
SplitSwan Windows 實驗版：用 WSL2 裡的 Linux strongSwan 連 FortiGate（split tunnel）

用法（建議直接雙擊同目錄的 connect.cmd／disconnect.cmd／status.cmd）：
  .\splitswan-wsl.ps1 -Action connect
  .\splitswan-wsl.ps1 -Action disconnect
  .\splitswan-wsl.ps1 -Action status

需要的檔案（放在本腳本旁的 conf\ 資料夾，從 Mac 版複製過來）：
  conf\swanctl.conf   ← Mac：/opt/homebrew/etc/swanctl/swanctl.conf
  conf\secrets.conf   ← Mac：/opt/homebrew/etc/swanctl/conf.d/secrets.conf
  conf\options.ini    ← 選用，格式見 options.example.ini

限制：只支援 WSL 預設的 NAT 網路模式；睡眠喚醒或換網路後請手動 disconnect 再 connect。
#>
param(
    [ValidateSet('connect', 'disconnect', 'status')]
    [string]$Action = 'connect',
    [string]$Distro,
    [string]$Domain,      # 內部網域，逗號分隔，例如 corp.example,ad.corp.example
    [string]$DnsServer,   # 內部 DNS，逗號分隔；省略時用 strongSwan 拿到的
    [string]$TestHost,    # 連上後測試的內部主機
    [int]$TestPort = 0,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = New-Object Text.UTF8Encoding $false
$env:WSL_UTF8 = '1'

$NrptComment = 'SplitSwan-WSL'
$ConfDir = Join-Path $PSScriptRoot 'conf'
$DataDir = Join-Path $env:LOCALAPPDATA 'SplitSwan-WSL'
$StateFile = Join-Path $DataDir 'state.json'

# ── 提權：不是系統管理員就用 UAC 重新啟動自己 ─────────────────────────
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Action', $Action, '-PauseAtEnd')
    foreach ($name in 'Distro', 'Domain', 'DnsServer', 'TestHost') {
        $v = Get-Variable -Name $name -ValueOnly
        if ($v) { $argList += @("-$name", "`"$v`"") }
    }
    if ($TestPort) { $argList += @('-TestPort', $TestPort) }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($argList -join ' ')
    exit
}

New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'logs') | Out-Null
$LogFile = Join-Path $DataDir ("logs\{0}-{1:yyyyMMdd-HHmmss}.log" -f $Action, (Get-Date))
Start-Transcript -Path $LogFile | Out-Null

function Write-Step([string]$msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host "  !!  $msg" -ForegroundColor Yellow }

# 讀 conf\options.ini（key=value），命令列參數優先
function Read-Options {
    $opt = @{}
    $f = Join-Path $ConfDir 'options.ini'
    if (Test-Path $f) {
        foreach ($line in Get-Content -LiteralPath $f -Encoding UTF8) {
            if ($line -match '^\s*([A-Za-z]+)\s*=\s*(.*?)\s*$' -and $line -notmatch '^\s*[#;]') {
                $opt[$Matches[1]] = $Matches[2]
            }
        }
    }
    return $opt
}

# 執行 wsl.exe，即時顯示輸出（@@ 開頭的機讀行不顯示），回傳結束碼與所有行
function Invoke-Wsl {
    param([string[]]$Argv, [switch]$Quiet)
    $lines = New-Object System.Collections.Generic.List[string]
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $script:Wsl @Argv 2>&1 | ForEach-Object {
            $l = ("$_") -replace "`0", ''
            $lines.Add($l)
            if (-not $Quiet -and -not $l.StartsWith('@@')) { Write-Host "  $l" }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Code = $code; Lines = $lines }
}

function Get-Results($lines) {
    $r = @{}
    foreach ($l in $lines) {
        if ($l -match '^@@([A-Z]+)=(.*)$') { $r[$Matches[1]] = $Matches[2].Trim() }
    }
    return $r
}

function Split-List([string]$s) {
    if (-not $s) { return @() }
    return @($s -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Store 版 WSL（2.x）裝在 Program Files\WSL；System32 的 inbox wsl.exe 在 WSL 未安裝時可能跳互動提示，
# 所以先找 Store 版的執行檔，找不到就視為未安裝，不去呼叫 inbox 版探測。
function Find-StoreWsl {
    $p = Join-Path $env:ProgramFiles 'WSL\wsl.exe'
    if (Test-Path $p) { return $p }
    # 較舊的 Store 版是 MSIX 套件，System32 的 wsl.exe 會轉給它
    if (Get-AppxPackage -AllUsers -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' -ErrorAction SilentlyContinue) {
        return (Join-Path $env:SystemRoot 'System32\wsl.exe')
    }
    return $null
}

# 回傳 'nowsl'、'nodistro'、'wsl1' 或 'ok'
function Get-WslState {
    if (-not $script:Wsl) { return 'nowsl' }
    $r = Invoke-Wsl -Argv @('-l', '-v') -Quiet
    if ($r.Code -ne 0) { return 'nodistro' }   # 沒有任何發行版時 -l 會回非 0
    foreach ($line in $r.Lines) {
        $cols = @(($line -replace '^\s*\*?\s*', '').Trim() -split '\s+')
        if ($cols.Count -ge 3 -and $cols[0] -eq $Distro) {
            if ($cols[-1] -eq '2') { return 'ok' } else { return 'wsl1' }
        }
    }
    return 'nodistro'
}

# 把 Linux 端腳本轉成 LF 放到暫存目錄，回傳 WSL 內的路徑
function Get-ShPath {
    $src = Join-Path $PSScriptRoot 'splitswan-wsl.sh'
    if (-not (Test-Path $src)) { throw "找不到 $src" }
    $dst = Join-Path $DataDir 'splitswan-wsl.sh'
    $text = [IO.File]::ReadAllText($src) -replace "`r", ''
    [IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding $false))
    return ConvertTo-WslPath $dst
}

function ConvertTo-WslPath([string]$winPath) {
    $r = Invoke-Wsl -Argv @('-d', $Distro, '-u', 'root', '--exec', 'wslpath', '-a', $winPath) -Quiet
    $p = ($r.Lines | Select-Object -Last 1)
    if ($r.Code -ne 0 -or -not $p) { throw "wslpath 轉換失敗：$winPath" }
    return $p.Trim()
}

function Invoke-Sh([string[]]$shArgs) {
    $sh = Get-ShPath
    return Invoke-Wsl -Argv (@('-d', $Distro, '-u', 'root', '--exec', 'bash', $sh) + $shArgs)
}

# 讓 WSL VM 在腳本結束後繼續跑（否則閒置就關機，通道跟著消失）
function Start-KeepAlive {
    $state = Read-State
    if ($state -and $state.KeepAlivePid) {
        $p = Get-Process -Id $state.KeepAlivePid -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'wsl') { return $state.KeepAlivePid }
    }
    $p = Start-Process -FilePath $script:Wsl -ArgumentList @('-d', $Distro, '-u', 'root', '--exec', 'sleep', 'infinity') -WindowStyle Hidden -PassThru
    return $p.Id
}

function Read-State {
    if (Test-Path $StateFile) { return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json }
    return $null
}

function Remove-SplitSwanRoutes($state) {
    if (-not $state -or -not $state.Prefixes -or -not $state.InterfaceIndex) { return }
    foreach ($p in $state.Prefixes) {
        Get-NetRoute -DestinationPrefix $p -InterfaceIndex $state.InterfaceIndex -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -eq $state.WslIp } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Write-State($obj) {
    $obj | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

# 清掉上一次（或這次失敗一半）留下的一切：Windows 路由、NRPT、WSL 內的 SA 與規則、保活程序、state
function Clear-Connection {
    $state = Read-State
    Remove-SplitSwanRoutes $state
    Remove-SplitSwanNrpt
    Clear-DnsClientCache
    if ((Get-WslState) -eq 'ok') { Invoke-Sh @('disconnect') | Out-Null }
    if ($state -and $state.KeepAlivePid) {
        $p = Get-Process -Id $state.KeepAlivePid -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'wsl') { Stop-Process -Id $p.Id -Force }
    }
    if (Test-Path $StateFile) { Remove-Item -LiteralPath $StateFile -Force }
}

function Remove-SplitSwanNrpt {
    Get-DnsClientNrptRule | Where-Object { $_.Comment -eq $NrptComment } | ForEach-Object {
        Remove-DnsClientNrptRule -Name $_.Name -Force
    }
}

# ── 連線 ────────────────────────────────────────────────────────────────
function Invoke-Connect {
    Write-Step '1/6 檢查設定檔'
    foreach ($f in 'swanctl.conf', 'secrets.conf') {
        if (-not (Test-Path (Join-Path $ConfDir $f))) {
            throw "缺少 conf\$f。請從 Mac 複製（見腳本開頭說明）到：$ConfDir"
        }
    }
    if ((Test-Path (Join-Path $env:USERPROFILE '.wslconfig')) -and
        (Select-String -Path (Join-Path $env:USERPROFILE '.wslconfig') -Pattern '^\s*networkingMode\s*=\s*mirrored' -Quiet)) {
        throw '.wslconfig 設成 mirrored 網路模式，本腳本只支援預設的 NAT 模式'
    }
    Write-Ok $ConfDir

    Write-Step "2/6 檢查 WSL 與 $Distro"
    switch (Get-WslState) {
        'nowsl' {
            Write-Warn2 "找不到 Store 版 WSL，開始安裝 WSL 與 $Distro。請照畫面建立 Ubuntu 帳號；要求重開機就重開，完成後再執行一次 connect。"
            & "$env:SystemRoot\System32\wsl.exe" --install -d $Distro --web-download
            return
        }
        'nodistro' {
            Write-Warn2 "尚未安裝 $Distro，開始安裝。請照畫面建立 Ubuntu 帳號，完成後再執行一次 connect。"
            # 不自動 --update：WSL 太舊時第 3 步載入核心模組會失敗並提示更新
            # --web-download 從 GitHub 下載、不經 Microsoft Store（內建 Administrator 帳號用 Store 會卡住）
            & $script:Wsl --install -d $Distro --web-download
            return
        }
        'wsl1' {
            throw "$Distro 是 WSL1，請先執行：wsl --set-version $Distro 2"
        }
    }
    Invoke-Wsl -Argv @('--version') | Out-Null
    Write-Ok "$Distro 已安裝（WSL2）"

    Write-Step '3/6 WSL 內安裝 strongSwan（第一次會比較久）'
    $r = Invoke-Sh @('setup')
    if ($r.Code -eq 10) {
        Write-Warn2 '已開啟 systemd，重新啟動 WSL…'
        Invoke-Wsl -Argv @('--terminate', $Distro) -Quiet | Out-Null
        Start-Sleep -Seconds 3
        # WSL 常回 degraded（非 0），只用來等開機完成，結果不判斷
        Invoke-Wsl -Argv @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-system-running', '--wait') -Quiet | Out-Null
        $r = Invoke-Sh @('setup')
        if ($r.Code -eq 10) { throw 'WSL 重啟後 systemd 仍未啟用。請在 Windows 執行 wsl --update --web-download 後重試' }
    }
    if ($r.Code -ne 0) { throw "WSL setup 失敗（結束碼 $($r.Code)）" }
    if ((Get-Results $r.Lines).MODULES -eq 'fail') { Write-Warn2 '核心模組載入失敗，連線可能在建立 CHILD SA 時失敗（見上方訊息）' }
    Write-Ok '完成'

    Write-Step '清除上一次的連線狀態'
    Clear-Connection
    Write-Ok '完成'

    # 保活程序一啟動就寫 state，之後任何一步失敗都能被清掉
    $state = [pscustomobject]@{
        Distro         = $Distro
        InterfaceIndex = $null
        WslIp          = $null
        Prefixes       = @()
        KeepAlivePid   = (Start-KeepAlive)
        ConnectedAt    = (Get-Date).ToString('s')
    }
    Write-State $state

    try {
        Invoke-ConnectSteps $state
    } catch {
        Write-Warn2 '連線失敗，清除這次設定到一半的狀態…'
        try { Clear-Connection } catch { Write-Warn2 "清除時發生錯誤：$($_.Exception.Message)" }
        throw
    }
}

function Invoke-ConnectSteps($state) {
    Write-Step '4/6 連線 FortiGate'
    $r = Invoke-Sh @('connect', (ConvertTo-WslPath $ConfDir))
    if ($r.Code -ne 0) { throw "WSL 內連線失敗（結束碼 $($r.Code)）" }
    $res = Get-Results $r.Lines
    foreach ($k in 'VIP', 'WSLIP', 'HOSTIP', 'TS') {
        if (-not $res[$k]) { throw "WSL 端沒有回傳 $k，無法繼續" }
    }
    Write-Ok "閘道 $($res.GATEWAY)，虛擬 IP $($res.VIP)，WSL $($res.WSLIP)"

    Write-Step '5/6 設定 Windows 路由'
    $ip = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $res.HOSTIP -ErrorAction SilentlyContinue
    if (-not $ip) { throw "Windows 上找不到 WSL 網卡位址 $($res.HOSTIP)（WSL 是不是 NAT 模式？）" }
    $ifIndex = @($ip)[0].InterfaceIndex
    $state.InterfaceIndex = $ifIndex
    $state.WslIp = $res.WSLIP

    $prefixes = @()
    foreach ($p in Split-List $res.TS) {
        if ($p -match ':') { continue }   # 略過 IPv6
        if ($p -notmatch '/') { $p = "$p/32" }
        Get-NetRoute -DestinationPrefix $p -InterfaceIndex $ifIndex -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        $prefixes += $p
        $state.Prefixes = $prefixes
        Write-State $state   # 先記再加，加到一半失敗也清得掉
        New-NetRoute -DestinationPrefix $p -InterfaceIndex $ifIndex -NextHop $res.WSLIP -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
        Write-Ok "$p → $($res.WSLIP)"
    }

    Write-Step '6/6 DNS 分流（NRPT）'
    $domains = Split-List $Domain
    $dns = Split-List $DnsServer
    if (-not $dns) { $dns = Split-List $res.DNS }
    if (-not $domains) {
        Write-Warn2 '未設定 Domain，略過。內部主機名稱解析不到時，在 conf\options.ini 填 Domain='
    } elseif (-not $dns) {
        Write-Warn2 'strongSwan 沒給 DNS，也沒設定 DnsServer，略過 NRPT'
    } else {
        foreach ($d in $domains) {
            Add-DnsClientNrptRule -Namespace ('.' + $d.TrimStart('.')) -NameServers $dns -Comment $NrptComment
            Write-Ok ".$($d.TrimStart('.')) → $($dns -join ', ')"
        }
        Clear-DnsClientCache
    }

    if ($TestHost) {
        Write-Step "測試 $TestHost"
        $port = if ($TestPort) { $TestPort } else { 443 }
        Test-NetConnection -ComputerName $TestHost -Port $port | Format-List ComputerName, RemoteAddress, TcpTestSucceeded, InterfaceAlias
    }

    Write-Host "`n已連線。斷線請執行 disconnect.cmd。" -ForegroundColor Green
}

# ── 斷線 ────────────────────────────────────────────────────────────────
function Invoke-Disconnect {
    Write-Step '移除 Windows 路由與 NRPT、中斷 WSL 內的通道'
    Clear-Connection
    Write-Host "`n已斷線。" -ForegroundColor Green
}

# ── 狀態 ────────────────────────────────────────────────────────────────
function Invoke-Status {
    $state = Read-State
    Write-Step 'WSL 內 SA 與 SNAT'
    $ws = Get-WslState
    if ($ws -eq 'ok') { Invoke-Sh @('status') | Out-Null } else { Write-Warn2 "WSL 狀態：$ws" }

    Write-Step 'Windows 路由'
    if ($state) {
        foreach ($p in $state.Prefixes) {
            $rt = Get-NetRoute -DestinationPrefix $p -InterfaceIndex $state.InterfaceIndex -PolicyStore ActiveStore -ErrorAction SilentlyContinue
            if ($rt) { Write-Ok "$p → $($rt.NextHop)" } else { Write-Warn2 "$p 沒有路由" }
        }
    } else {
        Write-Warn2 '沒有連線紀錄'
    }

    Write-Step 'NRPT'
    Get-DnsClientNrptRule | Where-Object { $_.Comment -eq $NrptComment } | Format-Table Namespace, NameServers -AutoSize

    # Hyper-V firewall（Win11 22H2＋WSL 2.0.9 起預設開）是否擋轉發只能實測，這裡印出設定供對照
    Write-Step 'Hyper-V firewall（WSL）'
    if (Get-Command Get-NetFirewallHyperVVMSetting -ErrorAction SilentlyContinue) {
        Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Format-List Name, Enabled, DefaultInboundAction, DefaultOutboundAction, LoopbackEnabled
    } else {
        Write-Ok '這台 Windows 沒有 Hyper-V firewall'
    }
}

# ── 主程式 ──────────────────────────────────────────────────────────────
try {
    $opt = Read-Options
    if (-not $Distro)    { $Distro = if ($opt.Distro) { $opt.Distro } else { 'Ubuntu-24.04' } }
    if (-not $Domain)    { $Domain = $opt.Domain }
    if (-not $DnsServer) { $DnsServer = $opt.DnsServer }
    if (-not $TestHost)  { $TestHost = $opt.TestHost }
    if (-not $TestPort -and $opt.TestPort) { $TestPort = [int]$opt.TestPort }
    $script:Wsl = Find-StoreWsl

    switch ($Action) {
        'connect'    { Invoke-Connect }
        'disconnect' { Invoke-Disconnect }
        'status'     { Invoke-Status }
    }
} catch {
    Write-Host "`n失敗：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "位置：$($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
} finally {
    Stop-Transcript | Out-Null
    Write-Host "`n記錄檔：$LogFile（含內部位址，分享前請遮蔽）" -ForegroundColor DarkGray
    if ($PauseAtEnd) { Read-Host '按 Enter 關閉' | Out-Null }
}
