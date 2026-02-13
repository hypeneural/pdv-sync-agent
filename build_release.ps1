# build_release.ps1
# Automates the build and packaging of PDV Sync Agent v4.0

$ErrorActionPreference = "Stop"

# Configuration
$AppName = "pdv-sync-agent"
$DistDir = "PDVSyncAgent_dist"
$ZipName = "PDVSyncAgent_latest.zip"
$HashName = "PDVSyncAgent_latest.sha256"
$ServerUploadDir = "server_upload"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   BUILDING PDV SYNC AGENT v4.0 RELEASE" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Clean previous builds
Write-Host "`n[1/7] Cleaning previous builds..."
if (Test-Path "build") { Remove-Item "build" -Recurse -Force }
if (Test-Path "dist") { Remove-Item "dist" -Recurse -Force }
if (Test-Path $DistDir) { Remove-Item $DistDir -Recurse -Force }
if (Test-Path $ZipName) { Remove-Item $ZipName -Force }

# 2. Run PyInstaller
Write-Host "`n[2/7] Compiling with PyInstaller..."
python -m PyInstaller --clean --noconfirm pdv-sync-agent.spec

if (-not (Test-Path "dist\$AppName\$AppName.exe")) {
    Write-Error "PyInstaller failed to create executable."
}

# 3. Assemble Distribution Folder
Write-Host "`n[3/7] Assembling distribution folder ($DistDir)..."
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

# Copy all files from PyInstaller output folder to DistDir
Copy-Item "dist\$AppName\*" -Destination $DistDir -Recurse

# 4. Include update + install scripts in the distribution
Write-Host "`n[4/7] Including deploy scripts..."

# update_v4.ps1 — the smart updater (main way to update)
if (Test-Path "deploy\update_v4.ps1") {
    Copy-Item "deploy\update_v4.ps1" -Destination $DistDir
    Write-Host "   + update_v4.ps1"
}

# Legacy update.bat (kept for backward compat)
if (Test-Path "deploy\update.bat") {
    Copy-Item "deploy\update.bat" -Destination $DistDir
    Write-Host "   + update.bat (legacy)"
}

# ODBC driver MSI
if (Test-Path "msodbcsql.msi") {
    Copy-Item "msodbcsql.msi" -Destination $DistDir
    Write-Host "   + msodbcsql.msi"
}

# Install scripts (for fresh installs)
$installDir = Join-Path $DistDir 'install'
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
foreach ($script in @('install.ps1', 'install.bat', 'on_shutdown.ps1', 'config.template.env')) {
    $src = Join-Path 'deploy' $script
    if (Test-Path $src) {
        Copy-Item $src -Destination $installDir
        Write-Host "   + install/$script"
    }
}

# 5. Create ZIP archive
Write-Host "`n[5/7] Creating ZIP archive ($ZipName)..."
Compress-Archive -Path "$DistDir\*" -DestinationPath $ZipName -Force

$zipSize = "{0:N1}" -f ((Get-Item $ZipName).Length / 1MB)
Write-Host "   Size: $zipSize MB"

# 6. Generate Checksum
Write-Host "`n[6/7] Generating SHA256 checksum..."
$Hash = (Get-FileHash $ZipName -Algorithm SHA256).Hash
$Hash | Out-File $HashName -Encoding ascii
Write-Host "   SHA256: $Hash"

# 7. Prepare server_upload directory
Write-Host "`n[7/7] Preparing server_upload directory..."
if (-not (Test-Path $ServerUploadDir)) { New-Item -ItemType Directory -Path $ServerUploadDir -Force | Out-Null }

# Clean old files in server_upload
Get-ChildItem $ServerUploadDir -File | Where-Object { $_.Name -notmatch '\.htaccess' } | Remove-Item -Force

# Copy distribution files
Copy-Item $ZipName -Destination $ServerUploadDir -Force
Copy-Item $HashName -Destination $ServerUploadDir -Force

# Copy update_v4.ps1 directly for easy access (so admins can download just the script)
if (Test-Path "deploy\update_v4.ps1") {
    Copy-Item "deploy\update_v4.ps1" -Destination $ServerUploadDir -Force
    Write-Host "   + update_v4.ps1 (direct download)"
}

Write-Host "`nBUILD SUCCESSFUL!" -ForegroundColor Green
Write-Host "Files ready in '$ServerUploadDir':"
Get-ChildItem $ServerUploadDir | Select-Object Name, @{N = "Size"; E = { "{0:N1} KB" -f ($_.Length / 1KB) } }, LastWriteTime | Format-Table -AutoSize

Write-Host "`nDEPLOY INSTRUCTIONS:" -ForegroundColor Yellow
Write-Host "  1. Upload tudo de '$ServerUploadDir' para http://erp.maiscapinhas.com.br/download/"
Write-Host "  2. Em cada loja (como Admin), rode:"
Write-Host "     powershell -ExecutionPolicy Bypass -File update_v4.ps1"
Write-Host "     (ou baixe direto do servidor)"
Write-Host ""
