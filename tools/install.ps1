# Nexus - Windows installer
# Detects your architecture, downloads the latest release from GitHub,
# extracts it to ~\.nexus, adds it to your PATH, and creates a Start-menu
# shortcut.
#
# Usage (from PowerShell):
#   irm https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.ps1 | iex
#
# Usage (from cmd.exe or "Run"):
#   powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.ps1 | iex"

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 defaults to TLS 1.0 on some Windows builds; GitHub needs TLS 1.2+.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12

$Repo     = 'TVcraft01/Nexus'
$InstallDir = Join-Path $HOME '.nexus'

Write-Host ''
Write-Host '  Nexus - your devices, one system.' -ForegroundColor Cyan
Write-Host ''

# --- Detect architecture ------------------------------------------------
switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $Arch = 'x64' }
    'ARM64' { $Arch = 'arm64' }
    'x86'   { $Arch = 'x86' }
    default { Write-Host "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" -ForegroundColor Red; exit 1 }
}
Write-Host "  Detected platform: windows-$Arch"

# --- Find the latest release --------------------------------------------
Write-Host '  Checking latest release...' -ForegroundColor Cyan
$Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
    -Headers @{ 'User-Agent' = 'nexus-installer' }
$Version = $Release.tag_name
Write-Host "  Latest version: $Version"

# --- Download and extract ------------------------------------------------
$Url     = "https://github.com/$Repo/releases/download/$Version/nexus-windows-$Arch.zip"
$ZipPath = Join-Path $env:TEMP "nexus-windows-$Arch.zip"

Write-Host "  Downloading Windows build..."
Invoke-WebRequest -Uri $Url -OutFile $ZipPath -Headers @{ 'User-Agent' = 'nexus-installer' }

Write-Host '  Extracting...'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
Remove-Item -Force $ZipPath

$Exe = Join-Path $InstallDir 'nexus.exe'
if (-not (Test-Path $Exe)) {
    Write-Host "Install failed: $Exe not found after extraction." -ForegroundColor Red
    exit 1
}

# --- Add to PATH (persists as a user environment variable) ---------------
$Path = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($Path -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$InstallDir;$Path", 'User')
    $env:Path = "$InstallDir;$env:Path"   # current session too
    Write-Host '  Added ~\.nexus to your PATH.'
}

# --- Start-menu shortcut -------------------------------------------------
try {
    $StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $StartMenu | Out-Null
    $Shell = New-Object -ComObject WScript.Shell
    $Shortcut = $Shell.CreateShortcut((Join-Path $StartMenu 'Nexus.lnk'))
    $Shortcut.TargetPath       = $Exe
    $Shortcut.WorkingDirectory = $InstallDir
    $Shortcut.Description      = 'Nexus - your devices, one system'
    $Shortcut.Save()
    Write-Host '  Added "Nexus" to your Start menu.' -ForegroundColor Green
} catch {
    Write-Host '  Could not create Start-menu shortcut (running as another user?).' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Installed to ~\.nexus\nexus.exe' -ForegroundColor Green
Write-Host '  Next time, look for Nexus in your Start menu - or press Win+R and type:'
Write-Host "    $InstallDir\nexus.exe"
Write-Host ''
Write-Host '  Note: the build is unsigned, so Windows SmartScreen may ask you to'
Write-Host '        click "More info" then "Run anyway" the first time.'
Write-Host '        To update later, just run the same install command again.'
Write-Host ''