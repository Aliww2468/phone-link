# PhoneLink - 手机端一键安装（通过 USB 数据线，全程无需在手机上点任何东西）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Wireless 192.168.31.50     # 无线调试
#   powershell -ExecutionPolicy Bypass -File install.ps1 -PairHost 192.168.31.50 -PairCode 123456
#
param(
    [string]$Apk,
    [string]$PcIp,
    [int]$Port = 0,
    [string]$Token,
    [string]$Wireless,
    [string]$PairHost,
    [string]$PairCode,
    [switch]$NoConfig
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Pkg  = 'com.phonelink.app'
$Listener = "$Pkg/$Pkg.NotifListener"

$Adb = Join-Path $Root 'toolchain\android-sdk\platform-tools\adb.exe'
if (-not (Test-Path $Adb)) {
    foreach ($alt in @("$env:USERPROFILE\android-toolchain\android-sdk\platform-tools\adb.exe",
                       'C:\android-toolchain\android-sdk\platform-tools\adb.exe')) {
        if (Test-Path $alt) { $Adb = $alt; break }
    }
}
if (-not (Test-Path $Adb)) {
    $c = Get-Command adb -ErrorAction SilentlyContinue
    if ($c) { $Adb = $c.Source }
}
if (-not (Test-Path $Adb)) {
    Write-Host "找不到 adb。请确认已安装 Android SDK platform-tools。" -ForegroundColor Red
    exit 1
}

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Adb { param([Parameter(ValueFromRemainingArguments=$true)]$a) & $Adb @a 2>&1 }

# ---------------------------------------------------------------- 1. APK
if (-not $Apk) { $Apk = Join-Path $Root 'dist\PhoneLink.apk' }
if (-not (Test-Path $Apk)) {
    Say "找不到 APK：$Apk" Red
    Say "请先运行 build.ps1 构建。" Red
    exit 1
}
Say "使用 APK: $Apk"

# ---------------------------------------------------------------- 2. 电脑侧参数
$cfgPath = Join-Path $Root 'pc\config.json'
if (-not $Token -and (Test-Path $cfgPath)) {
    try { $Token = (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).token } catch { }
}
if ($Port -le 0) {
    $Port = 8787
    if (Test-Path $cfgPath) {
        try { $p = (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).port; if ($p) { $Port = [int]$p } } catch { }
    }
}
if (-not $PcIp) {
    $best = $null
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -ne 'Up') { continue }
        foreach ($u in $n.GetIPProperties().UnicastAddresses) {
            if ($u.Address.AddressFamily -ne 'InterNetwork') { continue }
            $ip = $u.Address.ToString()
            if ($ip.StartsWith('169.254.')) { continue }
            if (-not $best) { $best = $ip }
            elseif ($ip.StartsWith('192.168.') -and -not $best.StartsWith('192.168.')) { $best = $ip }
        }
    }
    $PcIp = $best
}
if (-not $PcIp) { Say "警告：没检测到局域网 IP，手机可能无法连上电脑。" Yellow }
Say "电脑地址: ${PcIp}:$Port   令牌: $Token"

# ---------------------------------------------------------------- 3. 连接手机
if ($PairHost -and $PairCode) {
    Say "`n[1/7] 无线配对 $PairHost ..." Cyan
    Adb pair $PairHost $PairCode | ForEach-Object { Say "    $_" }
}
if ($Wireless) {
    Say "`n[1/7] 连接 $Wireless ..." Cyan
    Adb connect "${Wireless}:5555" | ForEach-Object { Say "    $_" }
}

Say "`n[1/7] 等待手机连接（请确认手机已插好数据线并允许 USB 调试）..." Cyan
$deadline = (Get-Date).AddSeconds(90)
$serial = $null
while ((Get-Date) -lt $deadline) {
    $out = (Adb devices) -join "`n"
    if ($out -match '(?m)^(\S+)\s+unauthorized') {
        Say "    手机提示「是否允许 USB 调试」——请在手机屏幕上点【允许/始终允许】" Yellow
    }
    $m = [regex]::Match($out, '(?m)^(\S+)\s+device$')
    if ($m.Success) { $serial = $m.Groups[1].Value; break }
    Start-Sleep -Seconds 2
}
if (-not $serial) {
    Say "`n没有检测到已授权的设备。请检查：" Red
    Say "  1) 手机 设置 → 关于手机 → 连点「版本号」7 次开启开发者选项"
    Say "  2) 开发者选项 → 打开「USB 调试」"
    Say "  3) 数据线插好后，手机弹出的「允许 USB 调试」要点允许"
    Read-Host "按回车退出"
    exit 1
}
Say "    已连接设备: $serial" Green

function Dev { param([Parameter(ValueFromRemainingArguments=$true)]$a) Adb -s $serial @a }

# ---------------------------------------------------------------- 4. 安装
Say "`n[2/7] 安装 APK ..." Cyan
Dev install -r -d $Apk | ForEach-Object { Say "    $_" }

$installed = (Dev shell pm list packages $Pkg) -join ''
if ($installed -notmatch [regex]::Escape($Pkg)) {
    Say "安装失败。如果手机提示「应用未安装」，请先在手机上卸载旧版 PhoneLink 再重试。" Red
    Read-Host "按回车退出"
    exit 1
}
Say "    安装成功" Green

# ---------------------------------------------------------------- 5. 权限
Say "`n[3/7] 自动授权 ..." Cyan
Dev shell am force-stop $Pkg | Out-Null

$grants = @(
    'android.permission.RECEIVE_SMS',
    'android.permission.READ_SMS',
    'android.permission.RECEIVE_MMS',
    'android.permission.POST_NOTIFICATIONS'
)
foreach ($g in $grants) {
    $r = (Dev shell pm grant $Pkg $g) -join ' '
    if ($r -match 'Exception|Error|not allowed') {
        Say ("    {0,-50} 未授予（可用通知通道兜底）" -f $g) Yellow
    } else {
        Say ("    {0,-50} OK" -f $g) Green
    }
}

Say "`n[4/7] 开启通知使用权 ..." Cyan
$r = (Dev shell cmd notification allow_listener $Listener) -join ' '
$cur = (Dev shell settings get secure enabled_notification_listeners) -join ''
if ($cur -notmatch [regex]::Escape($Pkg)) {
    $new = if ([string]::IsNullOrWhiteSpace($cur) -or $cur -eq 'null') { $Listener } else { "$cur`:$Listener" }
    Dev shell settings put secure enabled_notification_listeners $new | Out-Null
    $cur2 = (Dev shell settings get secure enabled_notification_listeners) -join ''
    if ($cur2 -match [regex]::Escape($Pkg)) { Say "    已开启（兼容方式）" Green }
    else { Say "    自动开启失败——稍后请在手机上手动打开：设置 → 通知 → 通知使用权 → PhoneLink" Yellow }
} else {
    Say "    已开启" Green
}

Say "`n[5/7] 加入电池优化白名单 + 后台策略 ..." Cyan
Dev shell dumpsys deviceidle whitelist "+$Pkg" | Out-Null
Dev shell cmd deviceidle whitelist "+$Pkg" | Out-Null
foreach ($op in @('RUN_IN_BACKGROUND','RUN_ANY_IN_BACKGROUND','WAKE_LOCK','START_FOREGROUND')) {
    Dev shell cmd appops set $Pkg $op allow | Out-Null
}
$wl = (Dev shell dumpsys deviceidle whitelist) -join ''
if ($wl -match [regex]::Escape($Pkg)) { Say "    已加入电池白名单" Green } else { Say "    白名单设置可能未生效（可在 App 内点按钮再试）" Yellow }

# ---------------------------------------------------------------- 6. 写入配置
if (-not $NoConfig -and $PcIp) {
    Say "`n[6/7] 把电脑地址直接写进手机 App 配置 ..." Cyan
    Dev shell run-as $Pkg mkdir -p shared_prefs | Out-Null
    $xml = @"
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="host">$PcIp</string>
    <int name="port" value="$Port" />
    <string name="token">$Token</string>
    <boolean name="sms" value="true" />
    <boolean name="notif" value="true" />
    <boolean name="onlyText" value="true" />
    <boolean name="autoDiscover" value="true" />
    <boolean name="enabled" value="true" />
</map>
"@
    $tmp = Join-Path $env:TEMP 'phonelink-prefs.xml'
    [System.IO.File]::WriteAllText($tmp, $xml, (New-Object System.Text.UTF8Encoding($false)))
    Get-Content $tmp -Raw -Encoding UTF8 | & $Adb -s $serial shell "run-as $Pkg sh -c 'cat > shared_prefs/phonelink.xml'" 2>&1 | Out-Null
    $check = (Dev shell run-as $Pkg cat shared_prefs/phonelink.xml) -join "`n"
    if ($check -match [regex]::Escape($PcIp)) {
        Say "    配置已写入：$PcIp`:$Port（手机端无需任何手动设置）" Green
    } else {
        Say "    自动写入失败。没关系：打开手机上的 PhoneLink，点「自动搜索电脑」再点「保存并开启同步」即可。" Yellow
    }
} else {
    Say "`n[6/7] 跳过配置写入（-NoConfig 或没有电脑 IP）" Yellow
}

# ---------------------------------------------------------------- 7. 启动
Say "`n[7/7] 启动 PhoneLink ..." Cyan
Dev shell am start -n "$Pkg/.MainActivity" | ForEach-Object { Say "    $_" }
Start-Sleep -Seconds 3
$ps = (Dev shell "dumpsys activity services $Pkg") -join "`n"
if ($ps -match 'PushService') { Say "    后台同步服务已运行" Green } else { Say "    服务未运行——请在手机 App 里点「保存并开启同步」" Yellow }

# ---------------------------------------------------------------- 收尾
$line = '=' * 66
Write-Host ""
Say $line Cyan
Say "  安装完成。现在还需要在手机上做最后两件事（荣耀系统限制，无法用脚本代劳）：" Cyan
Say $line Cyan
Write-Host ""
Say "  1) 设置 → 应用 → 应用启动管理 → 找到 PhoneLink" White
Say "     关闭「自动管理」，把 自启动 / 关联启动 / 后台活动 三项全部打开"
Say ""
Say "  2) 设置 → 电池 → 更多电池设置 → 关闭「智能省电」对 PhoneLink 的限制"
Say "     （App 里也有按钮可直接跳到该页面）"
Write-Host ""
Say "  完成后就可以拔掉数据线了：手机重启、锁屏、清后台，它都会自己回来。" Green
Write-Host ""
Say "  电脑地址 ${PcIp}:$Port    令牌 $Token" White
Say "  电脑上打开 http://127.0.0.1:$Port/ 就能看到消息。" White
Write-Host ""
Read-Host "按回车退出"
