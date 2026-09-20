# PhoneLink - Android build toolchain bootstrap
# Installs: Temurin JDK 17 + Android SDK command-line tools + platform-tools + build-tools + platform
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# Installs into this script's own folder, so the toolchain travels with the project.
# Keep this path pure ASCII: aapt2/zipalign are native programs that mangle non-ASCII argv.
$Root      = $PSScriptRoot
$JdkDir    = Join-Path $Root 'jdk-17'
$SdkDir    = Join-Path $Root 'android-sdk'
$DlDir     = Join-Path $Root 'downloads'
New-Item -ItemType Directory -Force -Path $Root,$SdkDir,$DlDir | Out-Null

function Say($m) { Write-Host "[toolchain] $m" -ForegroundColor Cyan }

# ---------- 1. JDK 17 ----------
$javaExe = Join-Path $JdkDir 'bin\java.exe'
if (Test-Path $javaExe) {
    Say "JDK already present"
} else {
    $zip = Join-Path $DlDir 'jdk17.zip'
    if (-not (Test-Path $zip)) {
        Say "Downloading Temurin JDK 17 ..."
        Invoke-WebRequest -Uri 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse' -OutFile $zip -UseBasicParsing
    }
    Say "Extracting JDK ..."
    $tmp = Join-Path $DlDir 'jdk-tmp'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    if (Test-Path $JdkDir) { Remove-Item $JdkDir -Recurse -Force }
    Move-Item $inner.FullName $JdkDir
    Remove-Item $tmp -Recurse -Force
}
if (-not (Test-Path $javaExe)) { throw "JDK extraction failed" }
$env:JAVA_HOME = $JdkDir
$env:PATH = "$JdkDir\bin;$env:PATH"
Say "JAVA_HOME=$JdkDir"
cmd /c "`"$javaExe`" -version 2>&1" | ForEach-Object { Say "  $_" }

# ---------- 2. Android command-line tools ----------
$sdkManager = Join-Path $SdkDir 'cmdline-tools\latest\bin\sdkmanager.bat'
if (Test-Path $sdkManager) {
    Say "cmdline-tools already present"
} else {
    $zip = Join-Path $DlDir 'cmdline-tools.zip'
    if (-not (Test-Path $zip)) {
        Say "Downloading Android command-line tools ..."
        Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' -OutFile $zip -UseBasicParsing
    }
    Say "Extracting cmdline-tools ..."
    $tmp = Join-Path $DlDir 'cmdline-tmp'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $SdkDir 'cmdline-tools') | Out-Null
    $dest = Join-Path $SdkDir 'cmdline-tools\latest'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item (Join-Path $tmp 'cmdline-tools') $dest
    Remove-Item $tmp -Recurse -Force
}
if (-not (Test-Path $sdkManager)) { throw "cmdline-tools extraction failed" }

# ---------- 3. SDK packages ----------
Say "Accepting SDK licenses ..."
$yes = (1..40 | ForEach-Object { 'y' }) -join "`n"
$yes | cmd /c "`"$sdkManager`" --sdk_root=$SdkDir --licenses 2>&1" | ForEach-Object { Say "  $_" }

Say "Installing platform-tools / build-tools;34.0.0 / platforms;android-34 ..."
cmd /c "`"$sdkManager`" --sdk_root=$SdkDir --install platform-tools `"build-tools;34.0.0`" `"platforms;android-34`" 2>&1" | ForEach-Object { Say "  $_" }

foreach ($p in @('platform-tools\adb.exe','build-tools\34.0.0\aapt2.exe','build-tools\34.0.0\d8.bat','build-tools\34.0.0\zipalign.exe','build-tools\34.0.0\apksigner.bat','platforms\android-34\android.jar')) {
    $full = Join-Path $SdkDir $p
    if (Test-Path $full) { Say "OK   $p" } else { Say "MISS $p" }
}
Say "DONE"
