# deploy_update.ps1
# Script de Atualização Robusta para PDV Sync Agent v3.1
# Autor: PDV Sync Team
# Data: 2026-02-12

$ErrorActionPreference = "Stop"
$InstallDir = "C:\Program Files\PDVSyncAgent"
$DataDir = "C:\ProgramData\PDVSyncAgent"
$LogFile = "$DataDir\logs\agent.log"
$Url = "http://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.zip"
$TaskName = "PDVSyncAgent"

function Log-Msg($msg, $color = "White") {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor $color
}

Clear-Host
Log-Msg "INICIANDO ATUALIZAÇÃO PARA V3.1" "Cyan"
Log-Msg "==========================================" "Cyan"

# 1. Parar Serviço e Processos
Log-Msg "1. Parando serviço e processos..." "Yellow"
try {
    SchTasks /End /TN $TaskName *>$null
}
catch { Log-Msg "   (Tarefa já estava parada)" "Gray" }

Start-Sleep -Seconds 2
$p = Get-Process "pdv-sync-agent" -ErrorAction SilentlyContinue
if ($p) {
    Log-Msg "   Matando processo travado (PID: $($p.Id))..." "Red"
    Stop-Process -InputObject $p -Force
    Start-Sleep -Seconds 2
}

# 2. Limpeza (Backup e Remoção)
Log-Msg "2. Limpando arquivos antigos..." "Yellow"
if (Test-Path "$InstallDir\_internal") {
    Remove-Item "$InstallDir\_internal" -Recurse -Force -ErrorAction SilentlyContinue
}

if (Test-Path "$InstallDir\pdv-sync-agent.exe") {
    try {
        Remove-Item "$InstallDir\pdv-sync-agent.exe" -Force
    }
    catch {
        Log-Msg "   ERRO FATAL: Arquivo.exe está travado! Reinicie o PC." "Red"
        exit 1
    }
}

# 3. Download
Log-Msg "3. Baixando nova versão..." "Yellow"
$ZipFile = "$env:TEMP\pdv_update.zip"
try {
    Invoke-WebRequest $Url -OutFile $ZipFile -UseBasicParsing
}
catch {
    Log-Msg "   ERRO DOWNLOAD: $_" "Red"
    exit 1
}

# 4. Instalação
Log-Msg "4. Instalando..." "Yellow"
$ExtractDir = "$env:TEMP\pdv_extract_$(Get-Random)"
Expand-Archive $ZipFile -DestinationPath $ExtractDir -Force

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Copy-Item "$ExtractDir\*" $InstallDir -Recurse -Force

# 5. Reiniciar
Log-Msg "5. Reiniciando serviço..." "Green"
SchTasks /Run /TN $TaskName | Out-Null
Start-Sleep -Seconds 5

# 6. Verificação Final
Log-Msg "6. Verificando saúde da instalação..." "Cyan"

# Check 1: Processo
$proc = Get-Process "pdv-sync-agent" -ErrorAction SilentlyContinue
if ($proc) {
    Log-Msg "   [OK] Processo rodando (PID: $($proc.Id))" "Green"
}
else {
    Log-Msg "   [ERRO] Processo não iniciou!" "Red"
    exit 1
}

# Check 2: Versão do Arquivo (Data)
$fileParams = Get-Item "$InstallDir\pdv-sync-agent.exe"
if ($fileParams.LastWriteTime -gt (Get-Date).AddMinutes(-30)) {
    # Alterado recentemente
    Log-Msg "   [OK] Arquivo atualizado (Data: $($fileParams.LastWriteTime))" "Green"
}
else {
    Log-Msg "   [ERRO] Arquivo antigo detectado! ($($fileParams.LastWriteTime))" "Red"
}

# Check 3: Logs (Versão 3.1)
if (Test-Path $LogFile) {
    Log-Msg "`n--- Últimas linhas do log ---" "Gray"
    Get-Content $LogFile -Tail 5
    
    # Check simples por string nova
    $logs = Get-Content $LogFile -Tail 50
    if ($logs | Select-String "Payload built" -Quiet) {
        Log-Msg "`n[OK] Agente gerando payload v3.1 (CNPJ/Login Ativos)!" "Green"
    }
}

Log-Msg "`nATUALIZAÇÃO CONCLUÍDA COM SUCESSO! 🚀" "Green"

# Limpeza temporária (não falhar se der erro)
Remove-Item $ZipFile -Force -ErrorAction SilentlyContinue
if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue }

Read-Host "Pressione Enter para sair..."
