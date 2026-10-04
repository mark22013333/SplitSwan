<#
SplitSwan Windows 實驗版：用 WSL2 裡的 Linux strongSwan 連 FortiGate（split tunnel）

用法（建議直接雙擊同目錄的 connect.cmd／disconnect.cmd／status.cmd）：
  .\splitswan-wsl.ps1 -Action connect
  .\splitswan-wsl.ps1 -Action disconnect
  .\splitswan-wsl.ps1 -Action status
  .\splitswan-wsl.ps1 -Action brief      ← 給托盤 App 輪詢：不提權、不啟動 WSL、不寫記錄檔
  .\splitswan-wsl.ps1 -Action setup      ← 只在 WSL 內安裝 strongSwan（給首次設定精靈用）：不提權、不連線、不需要設定檔

機讀輸出（給托盤 App）：每個 Action 結束時 stdout 最後一行是 @@RESULT=ok 或 @@RESULT=fail:<原因>，
結束碼 ok=0、fail=1。connect 成功另外輸出 @@GATEWAY=、@@VIP=。
brief 輸出 @@STATE=up|down|unknown：up 時加 @@GATEWAY、@@VIP，取得到通道流量時再加 @@BYTESIN、@@BYTESOUT（位元組數）；unknown＝查詢本身失敗或逾時（約 6 秒），
不代表斷線，此時 @@RESULT=fail。
-NoInstall：connect 遇到 WSL 或發行版未安裝時不啟動安裝，直接回 @@RESULT=fail:尚未安裝…（托盤 App 用）。
-Distro <名稱>：WSL 發行版名稱（首字須為英數字，其餘只接受英數字與 . _ -，最多 64 字元），省略時用 options.ini 的 Distro，再沒有就是 Ubuntu-24.04。
setup：WSL 或發行版不存在時直接回 @@RESULT=fail:尚未安裝…，永不執行 wsl --install。
-Order 2,1,3：connect 依此順序嘗試閘道（1 起算的編號；省略＝vpn1..N 依編號）。每台嘗試完輸出一行
@@ATTEMPT=<n>|<ok|fail>|<秒數>|<失敗摘要>（同一 key 多行，要逐行讀）；編號不存在回 @@RESULT=fail:閘道編號 N 不存在。

需要的檔案（放在本腳本旁的 conf\ 資料夾，或用 -ConfDir 指定其他資料夾；從 Mac 版複製過來）：
  conf\swanctl.conf   ← Mac：/opt/homebrew/etc/swanctl/swanctl.conf
  conf\secrets.conf   ← Mac：/opt/homebrew/etc/swanctl/conf.d/secrets.conf
  conf\options.ini    ← 選用，格式見 options.example.ini

限制：只支援 WSL 預設的 NAT 網路模式；睡眠喚醒或換網路後請手動 disconnect 再 connect。
#>
param(
    [ValidateSet('connect', 'disconnect', 'status', 'brief', 'setup')]
    [string]$Action = 'connect',
    [string]$ConfDir,     # 設定檔資料夾；省略時用本腳本旁的 conf\
    [string]$Distro,      # WSL 發行版名稱；省略時用 options.ini 的 Distro，再沒有就是 $DefaultDistro
    [string]$Domain,      # 內部網域，逗號分隔，例如 corp.example,ad.corp.example
    [string]$DnsServer,   # 內部 DNS，逗號分隔；省略時用 strongSwan 拿到的
    [string]$TestHost,    # 連上後測試的內部主機
    [int]$TestPort = 0,
    [switch]$PauseAtEnd,
    [switch]$NoInstall,   # connect 遇到 WSL／發行版未安裝時不啟動安裝，直接回「尚未安裝」（托盤 App 用）
    [string]$Order        # connect 的閘道嘗試順序，逗號分隔的編號（例 2,1,3）；省略＝vpn1..N 依編號
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = New-Object Text.UTF8Encoding $false
$env:WSL_UTF8 = '1'

$NrptComment = 'SplitSwan-WSL'
$DefaultDistro = 'Ubuntu-24.04'
if ($ConfDir) {
    # 提權重開後工作目錄會變，先轉成絕對路徑；去掉結尾的 \，免得傳參數時跳脫掉結尾的引號
    if (-not [IO.Path]::IsPathRooted($ConfDir)) { $ConfDir = Join-Path (Get-Location).ProviderPath $ConfDir }
    if ($ConfDir.Length -gt 3) { $ConfDir = $ConfDir.TrimEnd('\', '/') }
} else {
    $ConfDir = Join-Path $PSScriptRoot 'conf'
}
$DataDir = Join-Path $env:LOCALAPPDATA 'SplitSwan-WSL'
$StateFile = Join-Path $DataDir 'state.json'

# 機讀結果行：stdout 最後一行，原因只留一行
function Write-ResultLine([string]$failReason) {
    if ($failReason) {
        Write-Host ('@@RESULT=fail:' + (($failReason -replace '[\r\n]+', ' ').Trim()))
    } else {
        Write-Host '@@RESULT=ok'
    }
}

# 發行版名稱會被拼進 wsl.exe 的命令列（含提權重開與 brief 自組的參數字串），只接受固定字元
# 首字元限英數字：以 - 開頭的名稱會被 wsl.exe 當成參數（例 -u）
# 用 -cmatch：不分大小寫比對時 [A-Za-z] 會連 U+212A（克氏溫標符號）也接受；\z 才不會放過結尾換行
function Test-DistroName([string]$name) {
    return ($name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z')
}

# brief 每 15 秒輪詢一次：不提權、不寫記錄檔（其餘 Action 照舊）
$IsBrief = ($Action -eq 'brief')

# 命令列給的 -Distro 在提權重開之前就檢查，不合法的值不會被轉傳
if ($Distro -and -not (Test-DistroName $Distro)) {
    if ($IsBrief) { Write-Host '@@STATE=unknown' }
    Write-ResultLine '發行版名稱不合法（首字須為英數字，其餘只接受英數字與 . _ -，最多 64 字元）'
    exit 1
}

# ── 提權：不是系統管理員就用 UAC 重新啟動自己 ─────────────────────────
# setup 只動 WSL 內部（以 WSL 的 root 執行），不需要 Windows 管理員；也不能提權：
# 換成別的管理員帳號執行時，會操作到那個帳號底下的發行版
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $IsBrief -and $Action -ne 'setup' -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Action', $Action, '-PauseAtEnd')
    foreach ($name in 'ConfDir', 'Distro', 'Domain', 'DnsServer', 'TestHost', 'Order') {
        $v = Get-Variable -Name $name -ValueOnly
        if ($v) { $argList += @("-$name", "`"$v`"") }
    }
    if ($TestPort) { $argList += @('-TestPort', $TestPort) }
    if ($NoInstall) { $argList += '-NoInstall' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($argList -join ' ')
    } catch {
        Write-ResultLine "無法以系統管理員身分重新啟動：$($_.Exception.Message)"
        exit 1
    }
    # 動作在提權後的新視窗裡執行，這個程序本身沒有完成動作
    Write-ResultLine '目前不是系統管理員，已另開提權視窗執行'
    exit 1
}

# 記錄檔在主程式的 try 裡才開始，開不成也會走到 finally 輸出 @@RESULT
$LogFile = $null
$script:Transcribing = $false
# 動作沒有完成、但也不是例外時（例如剛開始安裝 WSL），把原因放這裡
$script:FailReason = $null
# connect 成功時的閘道與虛擬 IP
$script:ConnectResult = $null
# -Order 驗證後的順序（例 2,1,3）；$null＝沒指定，照設定檔順序
$script:OrderArg = $null

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
# stdin 餵空管線：stdin 是主控台時 wsl.exe 會配 pty 並改主控台模式，期間印出的行不回行首（階梯狀）
function Invoke-Wsl {
    param([string[]]$Argv, [switch]$Quiet)
    $lines = New-Object System.Collections.Generic.List[string]
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        @() | & $script:Wsl @Argv 2>&1 | ForEach-Object {
            $l = ("$_") -replace "`0", ''
            $lines.Add($l)
            # @@ 機讀行不顯示；@@ATTEMPT 例外，原樣即時轉出給托盤 App 逐台記錄
            if ($l.StartsWith('@@ATTEMPT=')) { Write-Host $l }
            elseif (-not $Quiet -and -not $l.StartsWith('@@')) { Write-Host "  $l" }
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

# 驗證 -Order：格式為逗號分隔的編號，且每個 vpnN 都在 swanctl.conf 裡；回傳去重後的「2,1,3」
function Resolve-Order([string]$raw) {
    if ($raw -notmatch '^\s*[0-9]{1,4}(\s*,\s*[0-9]{1,4})*\s*$') { throw "閘道順序格式錯誤：$raw（例：2,1,3）" }
    $names = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $ConfDir 'swanctl.conf') -Encoding UTF8) {
        if ($line -cmatch '^\s*(vpn[0-9]+)\s*\{') { $names[$Matches[1]] = $true }
    }
    $list = New-Object System.Collections.Generic.List[int]
    foreach ($s in $raw -split ',') {
        $n = [int]$s.Trim()
        if (-not $names.ContainsKey("vpn$n")) { throw "閘道編號 $n 不存在" }
        if (-not $list.Contains($n)) { $list.Add($n) }
    }
    return ($list -join ',')
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

# WSL 內的準備：systemd、strongSwan 套件、核心模組、swanctl.load（connect 第 3 步與 setup 共用）
# 回 10＝剛開啟 systemd，要重啟發行版後再跑一次
function Invoke-WslSetup {
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
}

# ── 首次設定（setup）──────────────────────────────────────────────────
# 只做 WSL 內的準備，不讀設定檔、不連線、不改 Windows 路由；WSL 或發行版不存在時永不安裝
function Invoke-Setup {
    Write-Step "1/2 檢查 WSL 與 $Distro"
    switch (Get-WslState) {
        'nowsl'    { $script:FailReason = "尚未安裝 WSL，請先完成首次設定的「安裝 WSL」步驟"; return }
        'nodistro' { $script:FailReason = "尚未安裝 $Distro 發行版，請先完成首次設定的「匯入發行版」步驟"; return }
        'wsl1'     { throw "$Distro 是 WSL1，請先執行：wsl --set-version $Distro 2" }
    }
    Write-Ok "$Distro 已安裝（WSL2）"

    Write-Step '2/2 WSL 內安裝 strongSwan（第一次會比較久）'
    Invoke-WslSetup
    Write-Host "`nstrongSwan 已就緒。" -ForegroundColor Green
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
    if ($Order) {
        $script:OrderArg = Resolve-Order $Order
        Write-Ok "閘道嘗試順序：$($script:OrderArg)"
    }
    Write-Ok $ConfDir

    Write-Step "2/6 檢查 WSL 與 $Distro"
    switch (Get-WslState) {
        'nowsl' {
            if ($NoInstall) {
                $script:FailReason = "尚未安裝 WSL 與 $Distro，請用托盤選單「首次安裝 WSL／Ubuntu…」"
                return
            }
            Write-Warn2 "找不到 Store 版 WSL，開始安裝 WSL 與 $Distro。請照畫面建立 Ubuntu 帳號；要求重開機就重開，完成後再執行一次 connect。"
            & "$env:SystemRoot\System32\wsl.exe" --install -d $Distro --web-download
            $script:FailReason = "已開始安裝 WSL 與 $Distro，完成（必要時重開機）後請再連線一次"
            return
        }
        'nodistro' {
            if ($NoInstall) {
                $script:FailReason = "尚未安裝 $Distro，請用托盤選單「首次安裝 WSL／Ubuntu…」"
                return
            }
            Write-Warn2 "尚未安裝 $Distro，開始安裝。請照畫面建立 Ubuntu 帳號，完成後再執行一次 connect。"
            # 不自動 --update：WSL 太舊時第 3 步載入核心模組會失敗並提示更新
            # --web-download 從 GitHub 下載、不經 Microsoft Store（內建 Administrator 帳號用 Store 會卡住）
            & $script:Wsl --install -d $Distro --web-download
            $script:FailReason = "已開始安裝 $Distro，完成後請再連線一次"
            return
        }
        'wsl1' {
            throw "$Distro 是 WSL1，請先執行：wsl --set-version $Distro 2"
        }
    }
    Invoke-Wsl -Argv @('--version') | Out-Null
    Write-Ok "$Distro 已安裝（WSL2）"

    Write-Step '3/6 WSL 內安裝 strongSwan（第一次會比較久）'
    Invoke-WslSetup

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
    $shArgs = @('connect', (ConvertTo-WslPath $ConfDir))
    if ($script:OrderArg) { $shArgs += $script:OrderArg }
    $r = Invoke-Sh $shArgs
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

    $script:ConnectResult = $res
    # 由托盤 App 呼叫時（SPLITSWAN_HOST=tray）不提 .cmd：App 有自己的「斷線」選單
    if ($env:SPLITSWAN_HOST -eq 'tray') { Write-Host "`n已連線。" -ForegroundColor Green }
    else { Write-Host "`n已連線。斷線請執行 disconnect.cmd。" -ForegroundColor Green }
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

# ── 輪詢狀態（brief）──────────────────────────────────────────────────
# 限時執行 wsl.exe，不經主控台、不顯示；逾時就結束它並丟出例外
function Invoke-WslQuick([string[]]$Argv, [int]$TimeoutMs) {
    if ($TimeoutMs -lt 100) { throw '查詢 WSL 逾時' }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Wsl
    # PowerShell 5.1 的 ProcessStartInfo 沒有 ArgumentList，自己組字串（參數不含引號）
    $psi.Arguments = (@($Argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        throw '查詢 WSL 逾時'
    }
    $p.WaitForExit()
    # wsl -l 沒吃到 WSL_UTF8 時是 UTF-16：去掉 NUL、BOM 與解碼失敗的替代字元，名稱仍比對得到
    $lines = @(($out.Result -replace "[`0\uFEFF\uFFFD]", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return [pscustomobject]@{ Code = $p.ExitCode; Lines = $lines }
}

# brief 用的 Linux 端腳本：內容沒變就不重寫
function Sync-BriefSh {
    $src = Join-Path $PSScriptRoot 'splitswan-wsl.sh'
    if (-not (Test-Path $src)) { throw "找不到 $src" }
    $dst = Join-Path $DataDir 'splitswan-wsl.sh'
    $text = [IO.File]::ReadAllText($src) -replace "`r", ''
    if (-not (Test-Path $dst) -or [IO.File]::ReadAllText($dst) -ne $text) {
        New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
        [IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding $false))
    }
}

# 不啟動 VM：發行版沒在跑就直接回 down；在跑才進去讀 SA。全程限時約 6 秒
# 查詢本身失敗或逾時一律丟例外，由主程式輸出 @@STATE=unknown（不代表斷線）
function Invoke-Brief {
    $deadline = (Get-Date).AddMilliseconds(6000)
    if (-not $script:Wsl) { Write-Host '@@STATE=down'; return }
    $r = Invoke-WslQuick @('-l', '--running', '-q') ([int]($deadline - (Get-Date)).TotalMilliseconds)
    if (-not ($r.Lines | Where-Object { $_ -eq $Distro })) { Write-Host '@@STATE=down'; return }
    Sync-BriefSh
    # --cd 直接吃 Windows 路徑，省掉一次 wslpath
    $r = Invoke-WslQuick @('-d', $Distro, '-u', 'root', '--cd', $DataDir, '--exec', 'bash', 'splitswan-wsl.sh', 'brief') ([int]($deadline - (Get-Date)).TotalMilliseconds)
    $res = Get-Results $r.Lines
    if ($r.Code -ne 0 -or -not $res.STATE) { throw "WSL 內查詢狀態失敗（結束碼 $($r.Code)）" }
    if ($res.STATE -eq 'unknown') { throw "WSL 內查詢狀態失敗：$($res.ERROR)" }
    Write-Host "@@STATE=$($res.STATE)"
    if ($res.STATE -eq 'up') {
        if ($res.GATEWAY) { Write-Host "@@GATEWAY=$($res.GATEWAY)" }
        if ($res.VIP) { Write-Host "@@VIP=$($res.VIP)" }
        # 通道流量：只接受純數字，取不到就不輸出（舊版 sh 沒有這兩行）
        if ($res.BYTESIN -match '^[0-9]+$') { Write-Host "@@BYTESIN=$($res.BYTESIN)" }
        if ($res.BYTESOUT -match '^[0-9]+$') { Write-Host "@@BYTESOUT=$($res.BYTESOUT)" }
    }
}

# ── 主程式 ──────────────────────────────────────────────────────────────
try {
    if (-not $IsBrief) {
        New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'logs') | Out-Null
        $LogFile = Join-Path $DataDir ("logs\{0}-{1:yyyyMMdd-HHmmss}.log" -f $Action, (Get-Date))
        Start-Transcript -Path $LogFile | Out-Null
        $script:Transcribing = $true
    }
    $opt = Read-Options
    if (-not $Distro)    { $Distro = if ($opt.Distro) { $opt.Distro } else { $DefaultDistro } }
    # options.ini 來的值也要過同一道檢查
    if (-not (Test-DistroName $Distro)) { throw '發行版名稱不合法（首字須為英數字，其餘只接受英數字與 . _ -，最多 64 字元）' }
    if (-not $Domain)    { $Domain = $opt.Domain }
    if (-not $DnsServer) { $DnsServer = $opt.DnsServer }
    if (-not $TestHost)  { $TestHost = $opt.TestHost }
    if (-not $TestPort -and $opt.TestPort) { $TestPort = [int]$opt.TestPort }
    $script:Wsl = Find-StoreWsl

    switch ($Action) {
        'connect'    { Invoke-Connect }
        'disconnect' { Invoke-Disconnect }
        'status'     { Invoke-Status }
        'brief'      { Invoke-Brief }
        'setup'      { Invoke-Setup }
    }
} catch {
    if (-not $script:FailReason) { $script:FailReason = $_.Exception.Message }
    if ($IsBrief) {
        # 查不到不等於斷線：托盤遇到 unknown 會沿用上一次狀態
        Write-Host '@@STATE=unknown'
    } else {
        Write-Host "`n失敗：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "位置：$($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    }
} finally {
    if ($script:Transcribing) {
        try { Stop-Transcript | Out-Null } catch { Write-Host "停止記錄檔時發生錯誤：$($_.Exception.Message)" }
        Write-Host "`n記錄檔：$LogFile（含內部位址，分享前請遮蔽）" -ForegroundColor DarkGray
    }
    # 機讀結果放在記錄檔路徑之後，確保是 stdout 最後一行（PauseAtEnd 的提示只給雙擊 .cmd 的人看）
    if (-not $script:FailReason -and $script:ConnectResult) {
        Write-Host "@@GATEWAY=$($script:ConnectResult.GATEWAY)"
        Write-Host "@@VIP=$($script:ConnectResult.VIP)"
    }
    Write-ResultLine $script:FailReason
    if ($PauseAtEnd) { Read-Host '按 Enter 關閉' | Out-Null }
}
if ($script:FailReason) { exit 1 } else { exit 0 }
