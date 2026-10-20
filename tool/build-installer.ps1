# Builds the release app and packages it into a Windows installer with Inno Setup.
# Run from any folder:  powershell -File tool/build-installer.ps1
# Output is ASCII only on purpose: Windows PowerShell 5.1 reads UTF-8 files without BOM as ANSI.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# 1. The installer version is the app version without the build number ("0.1.0+1" -> "0.1.0").
$pubspec = Get-Content (Join-Path $root 'apps/nexus_bridges/pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)') {
    Write-Host 'Could not read the version from apps/nexus_bridges/pubspec.yaml.' -ForegroundColor Red
    exit 1
}
$version = $Matches[1]

# 2. Find the Inno Setup compiler.
$candidates = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
)
$iscc = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) {
    Write-Host 'Inno Setup was not found. Install it with: winget install JRSoftware.InnoSetup' -ForegroundColor Red
    exit 1
}

# 3. Find the Visual C++ runtime DLLs. The app needs msvcp140, vcruntime140 and vcruntime140_1,
#    and a clean Windows does not have them, so the installer ships them next to the exe.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products '*' -property installationPath | Select-Object -First 1
}
if (-not $vsPath) {
    Write-Host 'Visual Studio (or Build Tools) with the C++ workload was not found.' -ForegroundColor Red
    exit 1
}
$crtRoot = Join-Path $vsPath 'VC\Redist\MSVC'
$crtDir = Get-ChildItem $crtRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' } |
    Where-Object { (Test-Path (Join-Path $_ 'msvcp140.dll')) -and (Test-Path (Join-Path $_ 'vcruntime140.dll')) -and (Test-Path (Join-Path $_ 'vcruntime140_1.dll')) } |
    Select-Object -First 1
if (-not $crtDir) {
    Write-Host "Could not find the Visual C++ runtime DLLs under $crtRoot." -ForegroundColor Red
    exit 1
}

# 4. Build the release app.
Push-Location (Join-Path $root 'apps/nexus_bridges')
flutter build windows --release
$buildExit = $LASTEXITCODE
Pop-Location
if ($buildExit -ne 0) { exit $buildExit }

# 5. Package it.
& $iscc "/DAppVersion=$version" "/DCrtDir=$crtDir" (Join-Path $root 'installer/nexus_bridges.iss')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$output = Join-Path $root "installer/Output/NexusBridges-Setup-$version.exe"
Write-Host ''
Write-Host "Installer ready: $output"
