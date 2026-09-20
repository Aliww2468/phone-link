 PhoneLink - 把电脑接收端设为开机自动启动
param(
    [switch]$Uninstall
)
$ErrorActionPreference = 'Continue'

$pcDir   = Split-Path -Parent $PSCommandPath
$startBat = Join-Path $pcDir 'start.bat'
$startup  = [Environment]::GetFolderPath('Startup')
$lnkPath  = Join-Path $startup 'PhoneLink.lnk'

if ($Uninstall) {
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath -Force
        Write-Host "已取消开机自启。" -ForegroundColor Green
    } else {
        Write-Host "本来就没有设置开机自启。"
    }
    Read-Host "按回车关闭"
    exit
}

if (-not (Test-Path $startBat)) {
    Write-Host "找不到 start.bat：$startBat" -ForegroundColor Red
    Read-Host "按回车关闭"
    exit 1
}

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($lnkPath)
$lnk.TargetPath       = $startBat
$lnk.WorkingDirectory = $pcDir
$lnk.WindowStyle      = 7          # 7 = 最小化启动，不打扰你
$lnk.Description      = 'PhoneLink 手机消息接收端'
$lnk.Save()

Write-Host ""
Write-Host "已设置开机自动启动（登录后最小化运行）。" -ForegroundColor Green
Write-Host "  快捷方式：$lnkPath"
Write-Host "  想看消息流水，双击 start.bat 或打开网页 http://127.0.0.1:8787/"
Write-Host ""
Write-Host "取消自启：powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Uninstall"
Write-Host ""
Read-Host "按回车关闭"
