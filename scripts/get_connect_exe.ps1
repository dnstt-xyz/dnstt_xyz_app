# PowerShell script to obtain connect.exe for Windows SSH proxy support
# Run this script on Windows before building the app

$toolsDir = "$PSScriptRoot\..\windows\runner\tools"
$connectExe = "$toolsDir\connect.exe"

# Create tools directory if it doesn't exist
if (-not (Test-Path $toolsDir)) {
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
}

# Check if connect.exe already exists
if (Test-Path $connectExe) {
    Write-Host "connect.exe already exists at $connectExe" -ForegroundColor Green
    exit 0
}

Write-Host "Looking for connect.exe..." -ForegroundColor Cyan

# Option 1: Try to copy from Git for Windows
$gitConnectPaths = @(
    "$env:ProgramFiles\Git\mingw64\bin\connect.exe",
    "$env:ProgramFiles(x86)\Git\mingw64\bin\connect.exe",
    "$env:LocalAppData\Programs\Git\mingw64\bin\connect.exe"
)

foreach ($path in $gitConnectPaths) {
    if (Test-Path $path) {
        Write-Host "Found Git for Windows connect.exe at $path" -ForegroundColor Green
        Copy-Item $path $connectExe
        Write-Host "Copied to $connectExe" -ForegroundColor Green
        exit 0
    }
}

# Option 2: Download from GitHub releases
Write-Host "Git for Windows not found, attempting to download connect.exe..." -ForegroundColor Yellow

$downloadUrl = "https://github.com/gotoh/ssh-connect/releases/download/v1.105/connect.exe"
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $connectExe -UseBasicParsing
    Write-Host "Downloaded connect.exe to $connectExe" -ForegroundColor Green
    exit 0
} catch {
    Write-Host "Failed to download from GitHub: $_" -ForegroundColor Red
}

# Provide manual instructions
Write-Host ""
Write-Host "Could not automatically obtain connect.exe." -ForegroundColor Red
Write-Host ""
Write-Host "Please manually obtain connect.exe and place it in:" -ForegroundColor Yellow
Write-Host "  $connectExe" -ForegroundColor White
Write-Host ""
Write-Host "Options:" -ForegroundColor Cyan
Write-Host "  1. Install Git for Windows and copy from:" -ForegroundColor White
Write-Host "     C:\Program Files\Git\mingw64\bin\connect.exe" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Download from GitHub:" -ForegroundColor White
Write-Host "     https://github.com/gotoh/ssh-connect/releases" -ForegroundColor Gray
Write-Host ""

exit 1
