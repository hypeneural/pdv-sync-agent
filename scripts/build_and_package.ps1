# =============================================================================
# PDV Sync Agent — Build, Package & Prepare for Upload
# =============================================================================
# Executa o build do PyInstaller, cria o ZIP com update.bat, gera SHA256,
# e prepara tudo na pasta server_upload/ pronto para subir na hospedagem.
#
# USO:
#   .\scripts\build_and_package.ps1
#
# PRE-REQUISITOS:
#   - .venv_build com PyInstaller instalado
#   - pdv-sync-agent.spec na raiz do projeto
# =============================================================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ===== Configuracao =====
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path "$ProjectRoot\pdv-sync-agent.spec")) {
    $ProjectRoot = (Get-Location).Path
}
$VenvPython = "$ProjectRoot\.venv_build\Scripts\python.exe"
$VenvPyInstaller = "$ProjectRoot\.venv_build\Scripts\pyinstaller.exe"
$SpecFile = "$ProjectRoot\pdv-sync-agent.spec"
$DistDir = "$ProjectRoot\dist\pdv-sync-agent"
$OutputDir = "$ProjectRoot\server_upload"
$ZipName = "PDVSyncAgent_latest.zip"
$HashName = "PDVSyncAgent_latest.sha256"
$DeployDir = "$ProjectRoot\deploy"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  PDV Sync Agent — Build & Package v2.0" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Projeto: $ProjectRoot"
Write-Host "  venv:    $VenvPython"
Write-Host ""

# ===== STEP 1: Validacao =====
Write-Host "[1/6] Validando pre-requisitos..." -ForegroundColor Yellow

if (-not (Test-Path $VenvPython)) {
    Write-Host "  ERRO: venv nao encontrado em: $VenvPython" -ForegroundColor Red
    Write-Host "  Crie a venv com: python -m venv .venv_build" -ForegroundColor Red
    exit 1
}
Write-Host "  OK - Python venv encontrado"

if (-not (Test-Path $SpecFile)) {
    Write-Host "  ERRO: .spec nao encontrado: $SpecFile" -ForegroundColor Red
    exit 1
}
Write-Host "  OK - .spec encontrado"

if (-not (Test-Path $VenvPyInstaller)) {
    Write-Host "  PyInstaller nao encontrado. Instalando..." -ForegroundColor Yellow
    & $VenvPython -m pip install pyinstaller --quiet
}
Write-Host "  OK - PyInstaller disponivel"
Write-Host ""

# ===== STEP 2: Rodar validacao pre-build =====
Write-Host "[2/6] Executando validacao pre-build..." -ForegroundColor Yellow

$validateScript = "$ProjectRoot\scripts\validate_production.py"
if (Test-Path $validateScript) {
    & $VenvPython $validateScript 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  AVISO: Validacao retornou erros (veja output acima)" -ForegroundColor Yellow
        $resp = Read-Host "  Continuar mesmo assim? (s/N)"
        if ($resp -ne "s" -and $resp -ne "S") {
            Write-Host "  Build cancelado." -ForegroundColor Red
            exit 1
        }
    }
    else {
        Write-Host "  OK - Validacao pre-build passou" -ForegroundColor Green
    }
}
else {
    Write-Host "  Sem script de validacao (pulando)" -ForegroundColor Gray
}
Write-Host ""

# ===== STEP 3: PyInstaller Build =====
Write-Host "[3/6] Buildando com PyInstaller..." -ForegroundColor Yellow
Write-Host "  Spec: $SpecFile"
Write-Host "  Isso pode levar 1-2 minutos..."
Write-Host ""

# Limpar build anterior
if (Test-Path "$ProjectRoot\build") {
    Remove-Item -Recurse -Force "$ProjectRoot\build"
}
if (Test-Path $DistDir) {
    Remove-Item -Recurse -Force $DistDir
}

# Build
& $VenvPyInstaller $SpecFile --noconfirm --clean 2>&1 | ForEach-Object {
    if ($_ -match "ERROR|FATAL|error") {
        Write-Host "  $_" -ForegroundColor Red
    }
}

if (-not (Test-Path "$DistDir\pdv-sync-agent.exe")) {
    Write-Host ""
    Write-Host "  ERRO: Build falhou! pdv-sync-agent.exe nao encontrado." -ForegroundColor Red
    Write-Host "  Verifique os erros acima." -ForegroundColor Red
    exit 1
}

$exeSize = (Get-Item "$DistDir\pdv-sync-agent.exe").Length / 1MB
Write-Host ""
Write-Host "  OK - Build concluido ($([math]::Round($exeSize, 1)) MB)" -ForegroundColor Green
Write-Host ""

# ===== STEP 4: Copiar update.bat para o dist =====
Write-Host "[4/6] Preparando pacote..." -ForegroundColor Yellow

# Copiar update.bat para dentro do dist (para as lojas terem o atualizador)
$updateBat = "$DeployDir\update.bat"
if (Test-Path $updateBat) {
    Copy-Item $updateBat "$DistDir\update.bat" -Force
    Write-Host "  OK - update.bat incluido no pacote"
}
else {
    Write-Host "  AVISO: update.bat nao encontrado em deploy/" -ForegroundColor Yellow
}
Write-Host ""

# ===== STEP 5: Criar ZIP + SHA256 =====
Write-Host "[5/6] Criando ZIP e SHA256..." -ForegroundColor Yellow

# Garantir diretorio de output
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$zipPath = "$OutputDir\$ZipName"
$hashPath = "$OutputDir\$HashName"

# Remover zip anterior
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# Criar ZIP
Compress-Archive -Path "$DistDir\*" -DestinationPath $zipPath -CompressionLevel Optimal

$zipSize = (Get-Item $zipPath).Length / 1MB
Write-Host "  OK - ZIP criado: $ZipName ($([math]::Round($zipSize, 1)) MB)"

# Gerar SHA256
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
$hash | Set-Content -Path $hashPath -NoNewline -Encoding ASCII

Write-Host "  OK - SHA256: $($hash.Substring(0, 16))..."
Write-Host ""

# ===== STEP 6: Resumo =====
Write-Host "[6/6] Pronto para upload!" -ForegroundColor Yellow
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  BUILD CONCLUIDO COM SUCESSO!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Arquivos para upload na hospedagem:" -ForegroundColor White
Write-Host ""
Write-Host "    1. $zipPath" -ForegroundColor Cyan
Write-Host "       ($([math]::Round($zipSize, 1)) MB)"
Write-Host ""
Write-Host "    2. $hashPath" -ForegroundColor Cyan
Write-Host "       ($hash)"
Write-Host ""
Write-Host "  Destino na hospedagem:" -ForegroundColor White
Write-Host "    http://erp.maiscapinhas.com.br/download/" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subir para:   public_html/download/" -ForegroundColor White
Write-Host "    - PDVSyncAgent_latest.zip"
Write-Host "    - PDVSyncAgent_latest.sha256"
Write-Host ""
Write-Host "  Depois, nas lojas rodar:" -ForegroundColor White
Write-Host "    update.bat" -ForegroundColor Cyan
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green

# Abrir pasta com os arquivos
Write-Host ""
$open = Read-Host "Abrir pasta server_upload no Explorer? (S/n)"
if ($open -ne "n" -and $open -ne "N") {
    Start-Process explorer.exe $OutputDir
}
