# PhoneLink - build the Android APK with the raw SDK toolchain (no Gradle, no network).
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# Toolchain lives beside this script so the whole project can be moved anywhere.
# NOTE: the path must stay pure ASCII - aapt2/zipalign are native programs that read
# their argv in the Windows ANSI code page and mangle any non-ASCII path.
$Tool = Join-Path $Root 'toolchain'
if (-not (Test-Path (Join-Path $Tool 'jdk-17'))) {
    foreach ($alt in @("$env:USERPROFILE\android-toolchain", 'C:\android-toolchain')) {
        if (Test-Path (Join-Path $alt 'jdk-17')) { $Tool = $alt; break }
    }
}
$Jdk  = Join-Path $Tool 'jdk-17'
$Sdk  = Join-Path $Tool 'android-sdk'
$BT   = Join-Path $Sdk 'build-tools\34.0.0'

$env:JAVA_HOME = $Jdk
$env:PATH = "$Jdk\bin;$Sdk\platform-tools;$BT;$env:PATH"

$aapt2 = Join-Path $BT 'aapt2.exe'
$d8    = Join-Path $BT 'd8.bat'
$align = Join-Path $BT 'zipalign.exe'
$sign  = Join-Path $BT 'apksigner.bat'
$androidJar = Join-Path $Sdk 'platforms\android-34\android.jar'
$keytool = Join-Path $Jdk 'bin\keytool.exe'

foreach ($t in @($aapt2,$d8,$align,$sign,$androidJar,$keytool)) {
    if (-not (Test-Path $t)) { Write-Host "MISSING TOOL: $t" -ForegroundColor Red; exit 1 }
}

$And = Join-Path $Root 'android'
$B   = Join-Path $Root 'build'
$Out = Join-Path $Root 'dist'
Remove-Item $B -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$B\compiled","$B\gen","$B\classes","$B\dex","$B\apk",$Out | Out-Null

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. launcher icons
$Mip = Join-Path $And 'res\mipmap-xxhdpi'
New-Item -ItemType Directory -Force -Path $Mip | Out-Null
$iconPath = Join-Path $Mip 'ic_launcher.png'
if (-not (Test-Path $iconPath)) {
    Step "generating launcher icon"
    Add-Type -AssemblyName System.Drawing
    $sizes = @{ 'mipmap-mdpi'=48; 'mipmap-hdpi'=72; 'mipmap-xhdpi'=96; 'mipmap-xxhdpi'=144; 'mipmap-xxxhdpi'=192 }
    foreach ($k in $sizes.Keys) {
        $px = $sizes[$k]
        $dir = Join-Path $And "res\$k"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bmp = New-Object System.Drawing.Bitmap($px, $px)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 16, 110, 100))
        $r = [int]($px * 0.22)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $r * 2
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc($px - $d, 0, $d, $d, 270, 90)
        $path.AddArc($px - $d, $px - $d, $d, $d, 0, 90)
        $path.AddArc(0, $px - $d, $d, $d, 90, 90)
        $path.CloseFigure()
        $g.FillPath($bg, $path)
        # white chat bubble
        $wb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $bx = $px * 0.20; $by = $px * 0.24; $bw = $px * 0.60; $bh = $px * 0.42
        $br = $px * 0.10
        $bp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $dd = $br * 2
        $bp.AddArc($bx, $by, $dd, $dd, 180, 90)
        $bp.AddArc($bx + $bw - $dd, $by, $dd, $dd, 270, 90)
        $bp.AddArc($bx + $bw - $dd, $by + $bh - $dd, $dd, $dd, 0, 90)
        $bp.AddArc($bx, $by + $bh - $dd, $dd, $dd, 90, 90)
        $bp.CloseFigure()
        $g.FillPath($wb, $bp)
        # tail
        $tri = @(
            (New-Object System.Drawing.PointF(($px * 0.34), ($px * 0.64))),
            (New-Object System.Drawing.PointF(($px * 0.30), ($px * 0.80))),
            (New-Object System.Drawing.PointF(($px * 0.46), ($px * 0.66)))
        )
        $g.FillPolygon($wb, $tri)
        $g.Dispose()
        $bmp.Save((Join-Path $dir 'ic_launcher.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Host "    $k ($px px)"
    }
}

# ---------------------------------------------------------------- 2. compile resources
Step "aapt2 compile"
& $aapt2 compile --dir (Join-Path $And 'res') -o "$B\compiled\res.zip" 2>&1 | ForEach-Object { Write-Host "    $_" }
if (-not (Test-Path "$B\compiled\res.zip")) { Write-Host "resource compile failed" -ForegroundColor Red; exit 1 }

Step "aapt2 link"
& $aapt2 link `
    -o "$B\apk\base.apk" `
    -I $androidJar `
    --manifest (Join-Path $And 'AndroidManifest.xml') `
    --java "$B\gen" `
    --min-sdk-version 23 `
    --target-sdk-version 34 `
    --version-code 1 `
    --version-name "1.0" `
    "$B\compiled\res.zip" 2>&1 | ForEach-Object { Write-Host "    $_" }
$linkCode = $LASTEXITCODE
if ($linkCode -ne 0 -or -not (Test-Path "$B\apk\base.apk")) {
    Write-Host "aapt2 link FAILED (exit $linkCode)" -ForegroundColor Red; exit 1
}

# ---------------------------------------------------------------- 3. compile java
Step "javac"
$srcs = @()
$srcs += (Get-ChildItem -Path (Join-Path $And 'src') -Recurse -Filter *.java | ForEach-Object { $_.FullName })
$srcs += (Get-ChildItem -Path "$B\gen" -Recurse -Filter *.java | ForEach-Object { $_.FullName })
Write-Host "    $($srcs.Count) source files"
$javacArgs = @('-encoding','UTF-8','-nowarn','-Xlint:-options','-source','8','-target','8',
               '-bootclasspath',$androidJar,'-d',"$B\classes") + $srcs
& "$Jdk\bin\javac.exe" @javacArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
$javacCode = $LASTEXITCODE
# javac emits partial output even on error, so the exit code is the ONLY reliable signal.
if ($javacCode -ne 0) {
    Write-Host "javac FAILED (exit $javacCode)" -ForegroundColor Red; exit 1
}
$expected = Get-ChildItem -Path (Join-Path $And 'src') -Recurse -Filter *.java | ForEach-Object { $_.BaseName }
$missing = @()
foreach ($e in $expected) {
    if (-not (Test-Path "$B\classes\com\phonelink\app\$e.class")) { $missing += $e }
}
if ($missing.Count -gt 0) {
    Write-Host "javac produced no class for: $($missing -join ', ')" -ForegroundColor Red; exit 1
}

# ---------------------------------------------------------------- 4. dex
Step "d8"
$classes = (Get-ChildItem -Path "$B\classes" -Recurse -Filter *.class | ForEach-Object { $_.FullName })
& $d8 --release --min-api 23 --lib $androidJar --output "$B\dex" @classes 2>&1 | ForEach-Object { Write-Host "    $_" }
$d8Code = $LASTEXITCODE
if ($d8Code -ne 0 -or -not (Test-Path "$B\dex\classes.dex")) {
    Write-Host "d8 FAILED (exit $d8Code)" -ForegroundColor Red; exit 1
}

# ---------------------------------------------------------------- 5. add dex into apk
Step "packaging classes.dex"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$unsigned = "$B\apk\unsigned.apk"
Copy-Item "$B\apk\base.apk" $unsigned -Force
$zip = [System.IO.Compression.ZipFile]::Open($unsigned, 'Update')
try {
    $existing = $zip.GetEntry('classes.dex')
    if ($existing) { $existing.Delete() }
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip, "$B\dex\classes.dex", 'classes.dex',
        [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
} finally { $zip.Dispose() }

# ---------------------------------------------------------------- 6. zipalign
Step "zipalign"
$aligned = "$B\apk\aligned.apk"
& $align -f -p 4 $unsigned $aligned 2>&1 | ForEach-Object { Write-Host "    $_" }
if (-not (Test-Path $aligned)) { Write-Host "zipalign failed" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 7. key + sign
$ks = Join-Path $Root 'phonelink.jks'
if (-not (Test-Path $ks)) {
    Step "creating signing key"
    & $keytool -genkeypair -v -keystore $ks -alias phonelink -keyalg RSA -keysize 2048 `
        -validity 10950 -storepass phonelink -keypass phonelink `
        -dname "CN=PhoneLink, OU=Personal, O=PhoneLink, L=Local, C=CN" 2>&1 |
        ForEach-Object { Write-Host "    $_" }
}
if (-not (Test-Path $ks)) { Write-Host "keystore creation failed" -ForegroundColor Red; exit 1 }

Step "apksigner"
$final = Join-Path $Out 'PhoneLink.apk'
& $sign sign --ks $ks --ks-key-alias phonelink --ks-pass pass:phonelink --key-pass pass:phonelink `
    --v1-signing-enabled true --v2-signing-enabled true --out $final $aligned 2>&1 |
    ForEach-Object { Write-Host "    $_" }
if (-not (Test-Path $final)) { Write-Host "signing failed" -ForegroundColor Red; exit 1 }

Step "verify"
& $sign verify --print-certs $final 2>&1 | Select-Object -First 6 | ForEach-Object { Write-Host "    $_" }
$sz = [math]::Round((Get-Item $final).Length / 1KB, 1)
Write-Host ""
Write-Host "BUILD OK -> $final ($sz KB)" -ForegroundColor Green
