<#
.SYNOPSIS
  PDV Sync Agent v3.0 - Build + Package + Upload-ready
  Roda na maquina de DESENVOLVIMENTO.
.USAGE
  powershell -ExecutionPolicy Bypass -File .\scripts\build_release.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\build_release.ps1 -SkipBuild
  powershell -ExecutionPolicy Bypass -File .\scripts\build_release.ps1 -Force
#>

param(
    [switch]$SkipBuild,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $ROOT

$APP_NAME = "pdv-sync-agent"
$ENTRY = "agent.py"
$DIST_FOLDER = Join-Path $ROOT "PDVSyncAgent_dist"
$ZIP_NAME = "PDVSyncAgent_latest.zip"
$SHA_NAME = "PDVSyncAgent_latest.sha256"
$UPLOAD_DIR = Join-Path $ROOT "server_upload"
$VENV_DIR = Join-Path $ROOT ".venv_build"

$DEPLOY_FILES = @(
    "deploy\install.bat",
    "deploy\install.ps1",
    "deploy\uninstall.bat",
    "deploy\update.bat",
    "deploy\on_shutdown.ps1",
    "deploy\task.template.xml",
    "deploy\config.template.env",
    "deploy\GUIA_INSTALACAO.md"
)

Write-Host ""
Write-Host "================================================================" -Fore Cyan
Write-Host "  PDV Sync Agent v3.0 - Build e Release" -Fore Cyan
Write-Host "  Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Fore Cyan
Write-Host "  Root: $ROOT" -Fore Cyan
Write-Host "================================================================" -Fore Cyan
Write-Host ""

# Ler versao do __init__.py
$version = "unknown"
$initFile = Join-Path $ROOT "src\__init__.py"
if (Test-Path $initFile) {
    $initContent = Get-Content $initFile -Raw
    $pattern = '__version__\s*=\s*"(.+?)"'
    if ($initContent -match $pattern) {
        $version = $Matches[1]
    }
}
Write-Host "  Versao: $version" -Fore White
Write-Host ""

$stepTotal = 5
if (-not $SkipBuild) { $stepTotal = 8 }
$step = 0

# ================================================================
# FASE 1: BUILD (PyInstaller)
# ================================================================

if (-not $SkipBuild) {

    $step++
    Write-Host "[$step/$stepTotal] Verificando Python..." -Fore Cyan
    try {
        $pyVer = python --version 2>&1
        Write-Host "    $pyVer" -Fore Green
    }
    catch {
        Write-Host "    ERRO: Python nao encontrado no PATH!" -Fore Red
        exit 1
    }

    $step++
    Write-Host "[$step/$stepTotal] Preparando virtual environment..." -Fore Cyan
    if ($Force -and (Test-Path $VENV_DIR)) {
        Write-Host "    Removendo venv anterior..." -Fore Yellow
        Remove-Item $VENV_DIR -Recurse -Force
    }
    if (-not (Test-Path $VENV_DIR)) {
        python -m venv $VENV_DIR
        Write-Host "    Venv criado." -Fore Green
    }
    else {
        Write-Host "    Reaproveitando venv existente." -Fore Green
    }

    $activateScript = Join-Path $VENV_DIR "Scripts\Activate.ps1"
    . $activateScript

    $step++
    Write-Host "[$step/$stepTotal] Instalando dependencias..." -Fore Cyan
    python -m pip install --upgrade pip --quiet 2>&1 | Out-Null
    pip install -r requirements.txt --quiet 2>&1 | Out-Null
    pip install pyinstaller --quiet 2>&1 | Out-Null
    Write-Host "    OK." -Fore Green

    $step++
    Write-Host "[$step/$stepTotal] Limpando builds anteriores..." -Fore Cyan
    foreach ($d in @("dist", "build", $DIST_FOLDER)) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }
    Write-Host "    OK." -Fore Green

    $step++
    Write-Host "[$step/$stepTotal] Compilando executavel (--onedir)..." -Fore Cyan
    Write-Host "    Isso pode demorar 1-3 minutos..." -Fore Yellow
    Write-Host ""

    pyinstaller --noconfirm --clean --onedir --console --name $APP_NAME $ENTRY

    if ($LASTEXITCODE -ne 0) {
        Write-Host "    ERRO: PyInstaller falhou!" -Fore Red
        exit 1
    }
    Write-Host ""
    Write-Host "    Build OK." -Fore Green
}
else {
    Write-Host "[--] Build pulado (SkipBuild). Usando dist existente." -Fore Yellow

    $exeA = Join-Path $DIST_FOLDER "$APP_NAME.exe"
    $exeB = "dist\$APP_NAME\$APP_NAME.exe"
    if (-not (Test-Path $exeA) -and -not (Test-Path $exeB)) {
        Write-Host "    ERRO: Nao existe exe em $DIST_FOLDER nem em dist\!" -Fore Red
        Write-Host "    Rode sem -SkipBuild primeiro." -Fore Yellow
        exit 1
    }
}

# ================================================================
# FASE 2: MONTAR PASTA DE DISTRIBUICAO
# ================================================================

$step++
Write-Host "[$step/$stepTotal] Montando pasta de distribuicao..." -Fore Cyan

if (-not (Test-Path $DIST_FOLDER)) {
    New-Item -ItemType Directory -Path $DIST_FOLDER -Force | Out-Null
}

$distSrc = "dist\$APP_NAME"
if (Test-Path $distSrc) {
    Write-Host "    Copiando binarios de dist\..." -Fore White
    Copy-Item "$distSrc\*" $DIST_FOLDER -Recurse -Force
}

Write-Host "    Copiando deploy scripts..." -Fore White
foreach ($f in $DEPLOY_FILES) {
    $src = Join-Path $ROOT $f
    if (Test-Path $src) {
        Copy-Item $src $DIST_FOLDER -Force
        $leaf = Split-Path $f -Leaf
        Write-Host "      + $leaf" -Fore DarkGray
    }
    else {
        Write-Host "      ! $f NAO ENCONTRADO" -Fore Yellow
    }
}

$msiSrc = Join-Path $ROOT "msodbcsql.msi"
if (Test-Path $msiSrc) {
    $extraDir = Join-Path $DIST_FOLDER "extra"
    if (-not (Test-Path $extraDir)) { New-Item -ItemType Directory -Path $extraDir -Force | Out-Null }
    Copy-Item $msiSrc "$extraDir\msodbcsql.msi" -Force
    $msiMB = [math]::Round((Get-Item $msiSrc).Length / 1MB, 1)
    Write-Host "      + extra\msodbcsql.msi ($msiMB MB)" -Fore DarkGray
}
else {
    Write-Host "      ! msodbcsql.msi NAO ENCONTRADO" -Fore Yellow
}

$exeCheck = Join-Path $DIST_FOLDER "$APP_NAME.exe"
if (-not (Test-Path $exeCheck)) {
    Write-Host "    ERRO: $APP_NAME.exe nao encontrado em $DIST_FOLDER!" -Fore Red
    exit 1
}
$exeSize = [math]::Round((Get-Item $exeCheck).Length / 1MB, 1)
Write-Host "    exe: $exeSize MB" -Fore Green

$fileCount = (Get-ChildItem $DIST_FOLDER -Recurse -File).Count
Write-Host "    Total: $fileCount arquivos" -Fore Green
Write-Host "    OK." -Fore Green

# ================================================================
# FASE 3: CRIAR ZIP + SHA256
# ================================================================

$step++
Write-Host "[$step/$stepTotal] Criando $ZIP_NAME..." -Fore Cyan

$zipPath = Join-Path $ROOT $ZIP_NAME
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Compress-Archive -Path "$DIST_FOLDER\*" -DestinationPath $zipPath -CompressionLevel Optimal
$zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host "    ZIP criado: $zipSize MB" -Fore Green

$step++
Write-Host "[$step/$stepTotal] Gerando $SHA_NAME..." -Fore Cyan
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
$shaContent = "$hash  $ZIP_NAME"
$shaPath = Join-Path $ROOT $SHA_NAME
[IO.File]::WriteAllText($shaPath, $shaContent + "`r`n")
$hashShort = $hash.Substring(0, 16)
Write-Host "    Hash: $hashShort..." -Fore Green

# ================================================================
# FASE 4: PREPARAR server_upload/
# ================================================================

$step++
Write-Host "[$step/$stepTotal] Preparando $UPLOAD_DIR/ para hospedagem..." -Fore Cyan

if (-not (Test-Path $UPLOAD_DIR)) { New-Item -ItemType Directory -Path $UPLOAD_DIR -Force | Out-Null }

Copy-Item $zipPath "$UPLOAD_DIR\$ZIP_NAME" -Force
Copy-Item $shaPath "$UPLOAD_DIR\$SHA_NAME" -Force
$updateSrc = Join-Path $ROOT "deploy\update.bat"
if (Test-Path $updateSrc) { Copy-Item $updateSrc "$UPLOAD_DIR\update.bat" -Force }

$htaccessPath = Join-Path $UPLOAD_DIR ".htaccess"
$htLines = @()
$htLines += "# PDV Sync Agent - Download Directory"
$htLines += "# http://erp.maiscapinhas.com.br/download/"
$htLines += ""
$htLines += "<FilesMatch `"\.(zip|sha256|bat)$`">"
$htLines += "    Header set Cache-Control `"no-cache, no-store, must-revalidate`""
$htLines += "    Header set Pragma `"no-cache`""
$htLines += "    Header set Expires `"0`""
$htLines += "</FilesMatch>"
$htLines += ""
$htLines += "Options -Indexes"
$htLines += "<FilesMatch `"\.(zip|sha256|bat|msi)$`">"
$htLines += "    ForceType application/octet-stream"
$htLines += "    Header set Content-Disposition attachment"
$htLines += "</FilesMatch>"
$htContent = $htLines -join "`r`n"
[IO.File]::WriteAllText($htaccessPath, $htContent)

Write-Host "    $UPLOAD_DIR/" -Fore White
Write-Host "      $ZIP_NAME  ($zipSize MB)" -Fore DarkGray
Write-Host "      $SHA_NAME  ($hashShort...)" -Fore DarkGray
Write-Host "      update.bat" -Fore DarkGray
Write-Host "      .htaccess" -Fore DarkGray
Write-Host "    OK." -Fore Green

# ================================================================
# SUMARIO FINAL
# ================================================================

Write-Host ""
Write-Host "================================================================" -Fore Green
Write-Host "  BUILD + RELEASE CONCLUIDO!" -Fore Green
Write-Host "================================================================" -Fore Green
Write-Host ""
Write-Host "  Versao:   $version" -Fore White
Write-Host "  ZIP:      $ZIP_NAME ($zipSize MB)" -Fore White
Write-Host "  SHA256:   $hashShort..." -Fore White
Write-Host "  Exe:      $exeSize MB" -Fore White
Write-Host "  Arquivos: $fileCount" -Fore White
Write-Host ""
Write-Host "  Pasta pronta para upload:" -Fore Cyan
Write-Host "  $ROOT\$UPLOAD_DIR\" -Fore Cyan
Write-Host ""
Write-Host "  Conteudo do ZIP:" -Fore DarkGray
Write-Host "    pdv-sync-agent.exe     (executavel)" -Fore DarkGray
Write-Host "    _internal\             (bibliotecas)" -Fore DarkGray
Write-Host "    install.bat            (launcher)" -Fore DarkGray
Write-Host "    install.ps1            (instalador v3.0)" -Fore DarkGray
Write-Host "    update.bat             (atualizador)" -Fore DarkGray
Write-Host "    uninstall.bat          (desinstalador)" -Fore DarkGray
Write-Host "    on_shutdown.ps1        (sync shutdown)" -Fore DarkGray
Write-Host "    config.template.env    (template config)" -Fore DarkGray
Write-Host "    task.template.xml      (template Task)" -Fore DarkGray
Write-Host "    GUIA_INSTALACAO.md     (guia tecnico)" -Fore DarkGray
Write-Host "    extra\msodbcsql.msi    (ODBC Driver 17)" -Fore DarkGray
Write-Host ""
Write-Host "  PROXIMO PASSO:" -Fore Yellow
Write-Host "  Upload server_upload/ para:" -Fore Yellow
Write-Host "  http://erp.maiscapinhas.com.br/download/" -Fore Yellow
Write-Host ""
Write-Host "  Na loja (primeira vez):" -Fore DarkGray
Write-Host "    Extrair ZIP + executar install.bat como Admin" -Fore DarkGray
Write-Host ""
Write-Host "  Na loja (atualizar):" -Fore DarkGray
Write-Host "    Rodar update.bat (baixa de erp.maiscapinhas.com.br)" -Fore DarkGray
Write-Host ""
Write-Host "================================================================" -Fore Green
