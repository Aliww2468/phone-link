# PhoneLink - 打包可分发的电脑端安装包
#
# 产物：dist\PhoneLink-PC-v<版本>.zip
#   解压后对方双击「安装.bat」即可，不需要装 Node.js、不需要联网、不需要命令行。
#
# 用法：powershell -ExecutionPolicy Bypass -File build-pc-package.ps1
#
param(
    [string]$Version = '1.0.0',
    [switch]$SkipApkBuild
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cache = Join-Path $Root '.cache'
$Dist  = Join-Path $Root 'dist'
$PkgName = 'PhoneLink-PC'
$PkgDir  = Join-Path $Dist $PkgName
$ZipPath = Join-Path $Dist "$PkgName-v$Version.zip"
$NodePin = 'v24.21.0'

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

New-Item -ItemType Directory -Force -Path $Cache, $Dist | Out-Null

# ---------------------------------------------------------------- 1. APK
if (-not $SkipApkBuild) {
    Step "构建 APK"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'build.ps1') 2>&1 |
        Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" }
}
$apk = Join-Path $Dist 'PhoneLink.apk'
if (-not (Test-Path $apk)) { Warn "找不到 $apk，请先运行 build.ps1"; exit 1 }
Ok "PhoneLink.apk ($([math]::Round((Get-Item $apk).Length/1KB,1)) KB)"

# ---------------------------------------------------------------- 2. Node 运行时
Step "准备 Node 运行时 ($NodePin)"
$nodeZip = Join-Path $Cache "node-win-x64.zip"
if (-not (Test-Path $nodeZip)) {
    $urls = @(
        "https://nodejs.org/dist/$NodePin/node-$NodePin-win-x64.zip",
        "https://npmmirror.com/mirrors/node/$NodePin/node-$NodePin-win-x64.zip",
        "https://cdn.npmmirror.com/binaries/node/$NodePin/node-$NodePin-win-x64.zip"
    )
    foreach ($u in $urls) {
        try {
            Write-Host "    下载: $u" -ForegroundColor DarkGray
            Invoke-WebRequest -Uri $u -OutFile $nodeZip -UseBasicParsing -TimeoutSec 900
            if (Test-Path $nodeZip) { break }
        } catch {
            Warn "失败: $($_.Exception.Message)"
            if (Test-Path $nodeZip) { Remove-Item $nodeZip -Force }
        }
    }
}
if (-not (Test-Path $nodeZip)) { Warn "无法获取 Node 运行时，打包中止"; exit 1 }
Ok "运行时压缩包 $([math]::Round((Get-Item $nodeZip).Length/1MB,1)) MB"

# ---------------------------------------------------------------- 3. 组装目录
Step "组装 $PkgName"
Remove-Item $PkgDir -Recurse -Force -ErrorAction SilentlyContinue
foreach ($d in @($PkgDir, "$PkgDir\pc", "$PkgDir\pc\public", "$PkgDir\node")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# 启动器（打包专用：中文文件名 + 纯 ASCII 内容，避免 cmd 代码页问题）
Copy-Item (Join-Path $Root 'packaging\安装.bat')     $PkgDir -Force
Copy-Item (Join-Path $Root 'packaging\启动.bat')     $PkgDir -Force
Copy-Item (Join-Path $Root 'packaging\使用说明.txt') $PkgDir -Force
Copy-Item (Join-Path $Root 'install-pc.ps1')         $PkgDir -Force
Copy-Item $apk (Join-Path $PkgDir 'PhoneLink.apk') -Force

Copy-Item (Join-Path $Root 'pc\server.js')           "$PkgDir\pc" -Force
Copy-Item (Join-Path $Root 'pc\simulate-phone.js')   "$PkgDir\pc" -Force
Copy-Item (Join-Path $Root 'pc\public\index.html')   "$PkgDir\pc\public" -Force
Ok "程序文件已复制"

# 从官方 zip 里只取出 node.exe
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($nodeZip)
try {
    $entry = $zip.Entries | Where-Object { $_.FullName -match '/node\.exe$' } | Select-Object -First 1
    if (-not $entry) { Warn "压缩包里找不到 node.exe"; exit 1 }
    $target = Join-Path $PkgDir 'node\node.exe'
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
} finally { $zip.Dispose() }
Ok "node.exe ($([math]::Round((Get-Item (Join-Path $PkgDir 'node\node.exe')).Length/1MB,1)) MB)"

# 自检：node.exe 能跑起来吗
$nver = (& (Join-Path $PkgDir 'node\node.exe') --version) 2>&1
if ($nver -match '^v\d') { Ok "运行时可用: $nver" } else { Warn "运行时自检失败: $nver"; exit 1 }

# ---------------------------------------------------------------- 4. 打包成 zip
Step "压缩"
Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $PkgDir, $ZipPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $true)   # true = zip 里带一层 PhoneLink-PC 目录

$sz = [math]::Round((Get-Item $ZipPath).Length / 1MB, 1)
Ok "$ZipPath ($sz MB)"

# ---------------------------------------------------------------- 5. 校验
Step "校验压缩包"
$verify = Join-Path $env:TEMP "phonelink-pkg-verify"
Remove-Item $verify -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $ZipPath -DestinationPath $verify -Force
$missing = @()
foreach ($f in @(
    "$PkgName\安装.bat", "$PkgName\启动.bat", "$PkgName\使用说明.txt",
    "$PkgName\PhoneLink.apk", "$PkgName\install-pc.ps1",
    "$PkgName\pc\server.js", "$PkgName\pc\public\index.html",
    "$PkgName\node\node.exe")) {
    if (-not (Test-Path (Join-Path $verify $f))) { $missing += $f }
}
if ($missing.Count) {
    Warn "压缩包内缺少: $($missing -join ', ')"
    Warn "（文件名编码可能有问题）"
    exit 1
}
Ok "解压校验通过，文件齐全、中文文件名正常"
Remove-Item $verify -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "打包完成 -> $ZipPath" -ForegroundColor Green
