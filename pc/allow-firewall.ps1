 PhoneLink - 放行局域网入站端口（需要管理员权限，会自动提权）
$ErrorActionPreference = 'Continue'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "需要管理员权限，正在弹出 UAC 确认框..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`""
    )
    exit
}

$cfgPath = Join-Path (Split-Path -Parent $PSCommandPath) 'config.json'
$port = 8787
$disc = 8788
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.port) { $port = [int]$cfg.port }
        if ($cfg.discoveryPort) { $disc = [int]$cfg.discoveryPort }
    } catch { }
}

foreach ($n in @("PhoneLink TCP $port", "PhoneLink UDP $disc")) {
    Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

New-NetFirewallRule -DisplayName "PhoneLink TCP $port" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $port -Profile Any -RemoteAddress LocalSubnet `
    -Description "PhoneLink: 接收手机推送的消息" | Out-Null

New-NetFirewallRule -DisplayName "PhoneLink UDP $disc" -Direction Inbound -Action Allow `
    -Protocol UDP -LocalPort $disc -Profile Any -RemoteAddress LocalSubnet `
    -Description "PhoneLink: 手机自动搜索电脑" | Out-Null

Write-Host ""
Write-Host "已放行（仅限同一局域网）：" -ForegroundColor Green
Write-Host "  TCP $port  - 手机推送消息"
Write-Host "  UDP $disc  - 手机自动发现电脑"
Write-Host ""
Write-Host "注意：如果这个 WiFi 在系统里被标成「公用网络」，规则同样生效，但只允许本网段访问。"
Write-Host ""
Read-Host "按回车关闭"
