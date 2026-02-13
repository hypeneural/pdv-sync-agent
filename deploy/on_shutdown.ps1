# =============================================================================
# PDV Sync Agent — Last-Chance Sync on Shutdown/Logoff
# =============================================================================
# Executado pelo Task Scheduler quando o Windows inicia shutdown ou logoff.
# Roda o agente UMA vez com timeout de 25 segundos para enviar dados finais
# (especialmente fechamento de turno) antes do PC desligar.
#
# Criado por: install.ps1 (v3.0)
# Task Scheduler: PDVSyncAgent_Shutdown
# =============================================================================

$ErrorActionPreference = "SilentlyContinue"

# Caminhos
$installDir = "$env:ProgramFiles\PDVSyncAgent"
$dataDir = "$env:ProgramData\PDVSyncAgent"
$exePath = "$installDir\pdv-sync-agent.exe"
$configPath = "$dataDir\.env"
$logFile = "$dataDir\logs\shutdown_sync.log"

# Verificar se o exe existe
if (-not (Test-Path $exePath)) {
    Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | ERRO: $exePath nao encontrado"
    exit 1
}

# Verificar se o config existe
if (-not (Test-Path $configPath)) {
    Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | ERRO: $configPath nao encontrado"
    exit 1
}

# Log inicio
Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | SHUTDOWN_SYNC: Iniciando sync final..."

# Executar o agente com timeout de 25 segundos
# (Windows da ~30s para scripts de shutdown)
$process = Start-Process -FilePath $exePath `
    -ArgumentList "--config", "`"$configPath`"" `
    -WindowStyle Hidden `
    -PassThru

# Aguardar ate 25 segundos
$finished = $process.WaitForExit(25000)

if ($finished) {
    $exitCode = $process.ExitCode
    Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | SHUTDOWN_SYNC: Concluido (exit=$exitCode)"
}
else {
    # Timeout — matar o processo
    $process | Stop-Process -Force -ErrorAction SilentlyContinue
    Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | SHUTDOWN_SYNC: TIMEOUT (25s) — processo encerrado"
}
