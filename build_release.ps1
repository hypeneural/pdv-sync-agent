# build_release.ps1
# Automates the build and packaging of PDV Sync Agent

$ErrorActionPreference = "Stop"

# Configuration
$AppName = "pdv-sync-agent"
$DistDir = "PDVSyncAgent_dist"
$ZipName = "PDVSyncAgent_latest.zip"
$HashName = "PDVSyncAgent_latest.sha256"
$ServerUploadDir = "server_upload"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   BUILDING PDV SYNC AGENT RELEASE" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Clean previous builds
Write-Host "`n[1/6] Cleaning previous builds..."
if (Test-Path "build") { Remove-Item "build" -Recurse -Force }
if (Test-Path "dist") { Remove-Item "dist" -Recurse -Force }
if (Test-Path $DistDir) { Remove-Item $DistDir -Recurse -Force }
if (Test-Path $ZipName) { Remove-Item $ZipName -Force }

# 2. Run PyInstaller
Write-Host "`n[2/6] Compiling with PyInstaller..."
# Ensure pyinstaller is installed or run via python -m
python -m PyInstaller --clean --noconfirm pdv-sync-agent.spec

if (-not (Test-Path "dist\$AppName\$AppName.exe")) {
    Write-Error "PyInstaller failed to create executable."
}

# 3. Assemble Distribution Folder
Write-Host "`n[3/6] Assembling distribution folder ($DistDir)..."
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

# Copy all files from PyInstaller output folder to DistDir
# This includes .exe, _internal (if present), and all DLLs
Copy-Item "dist\$AppName\*" -Destination $DistDir -Recurse

# Copy scripts and helpers
if (Test-Path "server_upload\update.bat") {
    Copy-Item "server_upload\update.bat" -Destination $DistDir
}
if (Test-Path "msodbcsql.msi") {
    Copy-Item "msodbcsql.msi" -Destination $DistDir
}

# Create empty .env template if not exists (optional, mostly for new installs)
# New-Item -ItemType File -Path "$DistDir\.env.example" -Force | Out-Null

# 4. Create ZIP archive
Write-Host "`n[4/6] Creating ZIP archive ($ZipName)..."
Compress-Archive -Path "$DistDir\*" -DestinationPath $ZipName -Force

# 5. Generate Checksum
Write-Host "`n[5/6] Generating SHA256 checksum..."
$Hash = (Get-FileHash $ZipName -Algorithm SHA256).Hash
$Hash | Out-File $HashName -Encoding ascii
Write-Host "SHA256: $Hash"

# 6. Moves to server_upload
Write-Host "`n[6/6] Preparing server_upload directory..."
if (-not (Test-Path $ServerUploadDir)) { New-Item -ItemType Directory -Path $ServerUploadDir -Force | Out-Null }

Copy-Item $ZipName -Destination $ServerUploadDir -Force
Copy-Item $HashName -Destination $ServerUploadDir -Force
# Copy update.bat to server_upload explicitly if it's not there or updated
if (Test-Path "server_upload\update.bat") {
    # It's already there effectively, but ensure we have the files ready for upload
    Write-Host "   update.bat already present in server_upload"
}

Write-Host "`nBUILD SUCCESSFUL!" -ForegroundColor Green
Write-Host "Files ready in '$ServerUploadDir':"
Get-ChildItem $ServerUploadDir | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
