# PhoneLink - 电脑端一键安装
#
#   · 准备 Node 运行时（优先用自带的，其次系统已装的，最后自动下载）
#   · 生成配对令牌
#   · 放行防火墙（需要管理员权限，会自动请求提权）
#   · 设置开机自动启动
#   · 打印手机需要填的 IP / 端口 / 令牌
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File install-pc.ps1
#   powershell -ExecutionPolicy Bypass -File install-pc.ps1 -NoAutostart
#   powershell -ExecutionPolicy Bypass -File install-pc.ps1 -NoFirewall -Port 9000
#
param(
    [switch]$NoAutostart,
    [switch]$NoFirewall,
    [int]$Port = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = Join-Path $Root 'pc'
$NodeDir = Join-Path $Root 'node'
$NodePin = 'v24.21.0'

function Say($m, $c = 'Gray') { if (-not $Quiet -or $c -eq 'Red') { Write-Host $m -ForegroundColor $c } }
function Head($m) {
    if ($Quiet) { return }
    Write-Host ""
    Write-Host "  $m" -ForegroundColor Cyan
}

$line = '=' * 62
if (-not $Quiet) {
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  PhoneLink 电脑端安装程序" -ForegroundColor White
    Write-Host $line -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 0. 自检
if (-not (Test-Path (Join-Path $AppDir 'server.js'))) {
    Say "找不到 pc\server.js，请确认解压完整后再运行。" Red
    exit 1
}

# ---------------------------------------------------------------- 1. 提权（只为防火墙）
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $NoFirewall) {
    Say ""
    Say "  添加防火墙规则需要管理员权限，正在请求提权…" Yellow
    Say "  请在弹窗中点击「是」。点「否」也能继续，但手机可能连不上电脑。" DarkGray
    try {
        $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($NoAutostart) { $fwd += '-NoAutostart' }
        if ($Port -gt 0)    { $fwd += @('-Port', $Port) }
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $fwd -PassThru -Wait
        exit $p.ExitCode
    } catch {
        Say "  已取消提权，继续以普通权限安装（将跳过防火墙设置）。" Yellow
        $isAdmin = $false
    }
}

# ---------------------------------------------------------------- 2. Node 运行时
Head "[1/5] 准备 Node 运行时"

function Find-Node {
    $bundled = Join-Path $NodeDir 'node.exe'
    if (Test-Path $bundled) { return $bundled }
    $c = Get-Command node -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Download-Node {
    $urls = @(
        "https://nodejs.org/dist/$NodePin/node-$NodePin-win-x64.zip",
        "https://npmmirror.com/mirrors/node/$NodePin/node-$NodePin-win-x64.zip",
        "https://cdn.npmmirror.com/binaries/node/$NodePin/node-$NodePin-win-x64.zip"
    )
    $zip = Join-Path $env:TEMP "phonelink-node-$NodePin.zip"
    foreach ($u in $urls) {
        try {
            Say "    下载中: $u" DarkGray
            Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -TimeoutSec 900
            if (Test-Path $zip) { break }
        } catch {
            Say "    失败: $($_.Exception.Message)" DarkYellow
            if (Test-Path $zip) { Remove-Item $zip -Force }
        }
    }
    if (-not (Test-Path $zip)) { return $null }

    $tmp = Join-Path $env:TEMP 'phonelink-node-extract'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    try {
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $exe = Get-ChildItem $tmp -Recurse -Filter node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) {
            New-Item -ItemType Directory -Force -Path $NodeDir | Out-Null
            Copy-Item $exe.FullName (Join-Path $NodeDir 'node.exe') -Force
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    $out = Join-Path $NodeDir 'node.exe'
    if (Test-Path $out) { return $out } else { return $null }
}

$NodeExe = Find-Node
if ($NodeExe) {
    Say "    已找到: $NodeExe" Green
} else {
    Say "    没有找到 Node，尝试自动下载…" Yellow
    $NodeExe = Download-Node
    if ($NodeExe) { Say "    已下载到: $NodeExe" Green }
}
if (-not $NodeExe) {
    Say ""
    Say "  安装失败：找不到也没有下载到 Node.js 运行时。" Red
    Say "  请手动从 https://nodejs.org/ 安装 Node.js 后重新运行本程序。" Red
    exit 1
}
$ver = (& $NodeExe --version) 2>&1
Say "    Node 版本: $ver"

# ---------------------------------------------------------------- 3. 配置与令牌
Head "[2/5] 生成配置与配对令牌"

$cfgPath = Join-Path $AppDir 'config.json'
if (-not (Test-Path $cfgPath)) {
    $bytes = New-Object byte[] 3
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
    $cfgObj = [ordered]@{
        port          = $(if ($Port -gt 0) { $Port } else { 8787 })
        discoveryPort = 8788
        token         = $token
        toast         = $true
        openBrowser   = $true
        maxBodyBytes  = 5242880
    }
    [System.IO.File]::WriteAllText($cfgPath, ($cfgObj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Say "    已生成 pc\config.json" Green
} else {
    Say "    pc\config.json 已存在，沿用原有配置" DarkGray
}

$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Port -gt 0 -and $cfg.port -ne $Port) {
    $cfg.port = $Port
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Say "    端口已改为 $Port"
}
$port = [int]$cfg.port
$disc = [int]$cfg.discoveryPort
$token = $cfg.token

# ---------------------------------------------------------------- 4. 防火墙
Head "[3/5] 放行防火墙"

if ($NoFirewall) {
    Say "    已按参数跳过（-NoFirewall）" DarkYellow
} elseif (-not $isAdmin) {
    Say "    跳过：没有管理员权限，手机大概率连不上电脑。" Yellow
    Say "    稍后请右键「以管理员身份运行」再执行一次本程序。" Yellow
} else {
    foreach ($n in @("PhoneLink TCP $port", "PhoneLink UDP $disc")) {
        Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
    $ok = $true
    try {
        New-NetFirewallRule -DisplayName "PhoneLink TCP $port" -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $port -Profile Any -RemoteAddress LocalSubnet `
            -Description "PhoneLink: receive phone messages" | Out-Null
        New-NetFirewallRule -DisplayName "PhoneLink UDP $disc" -Direction Inbound -Action Allow `
            -Protocol UDP -LocalPort $disc -Profile Any -RemoteAddress LocalSubnet `
            -Description "PhoneLink: LAN discovery" | Out-Null
    } catch {
        $ok = $false
        Say "    添加失败: $($_.Exception.Message)" Red
    }
    if ($ok) {
        Say "    已放行 TCP $port（手机推送）和 UDP $disc（自动发现），仅限本网段" Green
    }
}

# ---------------------------------------------------------------- 5. 开机自启
Head "[4/5] 设置开机自动启动"

$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'PhoneLink.lnk'

if ($NoAutostart) {
    Say "    已按参数跳过（-NoAutostart）" DarkYellow
} else {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $NodeExe
        $lnk.Arguments        = "`"$(Join-Path $AppDir 'server.js')`" --no-browser"
        $lnk.WorkingDirectory = $AppDir
        $lnk.WindowStyle      = 7
        $lnk.Description      = 'PhoneLink 手机消息接收端'
        $lnk.Save()
        Say "    已设置（登录后最小化运行，不弹浏览器）" Green
        Say "    快捷方式: $lnkPath" DarkGray
    } catch {
        Say "    设置失败: $($_.Exception.Message)" Yellow
    }
}

# ---------------------------------------------------------------- 6. 打印配对信息
Head "[5/5] 完成"

$ips = @()
foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    if ($n.OperationalStatus -ne 'Up') { continue }
    foreach ($u in $n.GetIPProperties().UnicastAddresses) {
        if ($u.Address.AddressFamily -ne 'InterNetwork') { continue }
        $ip = $u.Address.ToString()
        if ($ip.StartsWith('169.254.')) { continue }
        $ips += [pscustomobject]@{ IP = $ip; Name = $n.Name }
    }
}
$ips = $ips | Sort-Object { if ($_.IP.StartsWith('192.168.')) { 0 } elseif ($_.IP.StartsWith('10.')) { 1 } else { 2 } }

if (-not $Quiet) {
    Write-Host ""
    Write-Host $line -ForegroundColor Green
    Write-Host "  安装完成" -ForegroundColor Green
    Write-Host $line -ForegroundColor Green
    Write-Host ""
    Write-Host "  手机需要填写：" -ForegroundColor White
    if ($ips.Count -eq 0) {
        Write-Host "    IP   : 没有检测到局域网 IP，请先连上 WiFi 或网线" -ForegroundColor Yellow
    } else {
        foreach ($i in $ips) {
            Write-Host "    IP   : $($i.IP)    ($($i.Name))" -ForegroundColor Green
        }
    }
    Write-Host "    端口 : $port" -ForegroundColor Green
    Write-Host "    令牌 : $token" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  在电脑上查看消息：http://127.0.0.1:$port/" -ForegroundColor Cyan
    Write-Host "  启动接收端：双击「启动.bat」（开机时会自动启动）" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  下一步：" -ForegroundColor White
    Write-Host "    1) 把 PhoneLink.apk 装到手机上"
    Write-Host "    2) 荣耀手机务必到「设置 → 应用 → 应用启动管理」把 PhoneLink"
    Write-Host "       设为手动管理，自启动 / 关联启动 / 后台活动 三项全开"
    Write-Host "    3) 手机和电脑连同一个 WiFi"
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
}

exit 0
