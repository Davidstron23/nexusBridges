# Sets up a fresh clone so the app and the tests run.
# Run it once from any folder:  powershell -File tool/bootstrap.ps1
# Output is ASCII only on purpose: Windows PowerShell 5.1 reads UTF-8 files without BOM as ANSI.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# 1. Flutter must be installed and on the PATH.
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host 'Flutter was not found on the PATH.' -ForegroundColor Red
    Write-Host 'Install Flutter (stable channel) and open a new terminal: https://docs.flutter.dev/install'
    exit 1
}

# 2. The installed version must match the one pinned in the app pubspec.
$pubspec = Get-Content (Join-Path $root 'apps/nexus_bridges/pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^\s+flutter:\s*(\d+\.\d+\.\d+)\s*$') {
    Write-Host 'Could not find the pinned Flutter version in apps/nexus_bridges/pubspec.yaml.' -ForegroundColor Red
    exit 1
}
$required = $Matches[1]

$versionLine = (flutter --version 2>&1 | Out-String)
if ($versionLine -notmatch 'Flutter (\d+\.\d+\.\d+)') {
    Write-Host 'Could not read the installed Flutter version.' -ForegroundColor Red
    exit 1
}
$installed = $Matches[1]

if ($installed -ne $required) {
    Write-Host "Flutter $installed is installed but this project needs $required." -ForegroundColor Red
    Write-Host 'Switch the installed version, or change the pin in apps/nexus_bridges/pubspec.yaml'
    Write-Host '(and the matching line in .claude/CLAUDE.md) if you are upgrading on purpose.'
    exit 1
}
Write-Host "Flutter $installed OK."

# 3. Resolve the dependencies of the whole workspace.
flutter pub get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# 4. Enable the versioned git hooks (the local lock on main).
if (Test-Path (Join-Path $root '.git')) {
    git config core.hooksPath .githooks
    Write-Host 'Git hooks enabled (core.hooksPath = .githooks).'
}

Write-Host ''
Write-Host 'Ready. Useful commands:'
Write-Host '  Run the app:       cd apps/nexus_bridges; flutter run -d windows'
Write-Host '  Core tests:        cd packages/nexus_bridges_core; dart test'
Write-Host '  App tests:         cd apps/nexus_bridges; flutter test'
Write-Host '  Build installer:   tool/build-installer.ps1'
