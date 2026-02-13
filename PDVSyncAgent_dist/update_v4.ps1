#Requires -RunAsAdministrator
<#
.SYNOPSIS
    PDV Sync Agent - Smart Updater v4.0
.DESCRIPTION
    Atualiza binarios, migra .env automaticamente (adiciona novas chaves v4),
    auto-detecta STORE_ID_FILIAL, faz backup completo (binarios + .env),
    verifica saude pos-update, e rollback automatico se falhar.
.NOTES
    Rodar como Admin. Pode ser chamado via:
      update_v4.ps1                        (download do servidor)
      update_v4.ps1 -LocalZip "C:\pkg.zip" (zip local)
      update_v4.ps1 -SkipEnvMigration      (pula migracao do .env)
#>

param(
    [string]$LocalZip = "",
    [switch]$SkipEnvMigration,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ============================================================
# CONFIG
# ============================================================
$AppName = 'PDVSyncAgent'
$TaskName = 'PDVSyncAgent'
$InstallDir = Join-Path $env:ProgramFiles $AppName
$DataDir = Join-Path $env:ProgramData $AppName
$EnvFile = Join-Path $DataDir '.env'
$LogDir = Join-Path $DataDir 'logs'
$AgentLog = Join-Path $LogDir 'agent.log'
$BackupDir = Join-Path $DataDir 'backup'
$ExePath = Join-Path $InstallDir 'pdv-sync-agent.exe'
$TmpDir = Join-Path $env:TEMP "pdvsync_update_$(Get-Random)"
$ZipUrl = 'http://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.zip'
$HashUrl = 'http://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.sha256'
$TargetVersion = '4.0'

# ============================================================
# HELPERS
# ============================================================
function Log($msg, $color = 'White') {
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $msg" -ForegroundColor $color
    $logPath = Join-Path $LogDir 'update.log'
    Add-Content -Path $logPath -Value "[$ts] $msg" -ErrorAction SilentlyContinue
}

function Log-Ok($msg) { Log "  OK: $msg" 'Green' }
function Log-Warn($msg) { Log "  AVISO: $msg" 'Yellow' }
function Log-Fail($msg) { Log "  ERRO: $msg" 'Red' }

function Stop-Agent {
    try { schtasks /end /tn $TaskName 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2
    $proc = Get-Process 'pdv-sync-agent' -ErrorAction SilentlyContinue
    if ($proc) {
        Log-Warn "Matando processo travado (PID: $($proc.Id))..."
        Stop-Process -InputObject $proc -Force
        Start-Sleep -Seconds 3
    }
    # Confirmar que realmente parou
    $proc2 = Get-Process 'pdv-sync-agent' -ErrorAction SilentlyContinue
    if ($proc2) {
        Log-Fail "Processo AINDA rodando! Tente reiniciar o PC."
        throw "Agent locked"
    }
}

function Start-Agent {
    try { schtasks /run /tn $TaskName 2>&1 | Out-Null } catch {}
}

# ============================================================
# START
# ============================================================
Clear-Host
Log '' 'Cyan'
Log '============================================================' 'Cyan'
Log "  PDV Sync Agent - Smart Updater v$TargetVersion" 'Cyan'
Log '============================================================' 'Cyan'
Log "  InstallDir : $InstallDir"
Log "  DataDir    : $DataDir"
Log "  EnvFile    : $EnvFile"
Log ''

# Ensure dirs
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

# ============================================================
# STEP 1: Download ou usar zip local
# ============================================================
Log '[1/7] Obtendo pacote...' 'Yellow'

if ($LocalZip -ne "") {
    if (-not (Test-Path $LocalZip)) {
        Log-Fail "Arquivo nao encontrado: $LocalZip"
        exit 1
    }
    $ZipPath = $LocalZip
    Log-Ok "Usando arquivo local: $ZipPath"
}
else {
    Log "  Baixando de $ZipUrl"
    $ZipPath = Join-Path $TmpDir 'pkg.zip'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest $ZipUrl -OutFile $ZipPath -UseBasicParsing
    }
    catch {
        Log-Fail "Download falhou: $_"
        exit 1
    }
    Log-Ok "Download OK ($("{0:N1}" -f ((Get-Item $ZipPath).Length / 1MB)) MB)"
}

# ============================================================
# STEP 2: Verificar integridade (SHA256)
# ============================================================
Log '[2/7] Verificando integridade (SHA256)...' 'Yellow'

$hashOk = $false
try {
    $hashFile = Join-Path $TmpDir 'expected.sha256'
    if ($LocalZip -eq "") {
        Invoke-WebRequest $HashUrl -OutFile $hashFile -UseBasicParsing -ErrorAction Stop
    }

    if (Test-Path $hashFile) {
        $expected = (Get-Content $hashFile -First 1).Trim().Split(' ')[0]
        $actual = (Get-FileHash $ZipPath -Algorithm SHA256).Hash
        if ($expected -eq $actual) {
            Log-Ok "Hash OK: $($actual.Substring(0,16))..."
            $hashOk = $true
        }
        else {
            Log-Fail "Hash NAO confere! Esperado: $($expected.Substring(0,16))... Recebido: $($actual.Substring(0,16))..."
            if (-not $Force) { exit 1 }
            Log-Warn "Continuando com -Force..."
        }
    }
    else {
        Log-Warn "Arquivo .sha256 nao disponivel (pulando)"
    }
}
catch {
    Log-Warn "Nao foi possivel verificar hash: $_"
}

# ============================================================
# STEP 3: Extrair pacote
# ============================================================
Log '[3/7] Extraindo pacote...' 'Yellow'

$ExtractDir = Join-Path $TmpDir 'pkg'
Expand-Archive $ZipPath -DestinationPath $ExtractDir -Force

# Lidar com pastas aninhadas (se o ZIP tem subpasta)
$items = Get-ChildItem $ExtractDir
if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
    $ExtractDir = $items[0].FullName
}

if (-not (Test-Path (Join-Path $ExtractDir 'pdv-sync-agent.exe'))) {
    Log-Fail "pdv-sync-agent.exe nao encontrado no pacote!"
    exit 1
}

Log-Ok "Pacote extraido ($((Get-ChildItem $ExtractDir -File).Count) arquivos)"

# ============================================================
# STEP 4: Backup COMPLETO (binarios + .env)
# ============================================================
Log '[4/7] Fazendo backup completo...' 'Yellow'

$backupTs = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupPath = Join-Path $BackupDir "v_$backupTs"
New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

# Backup binarios
if (Test-Path $ExePath) {
    xcopy /e /i /y "$InstallDir\*" "$backupPath\bin\" 2>&1 | Out-Null
    Log-Ok "Binarios salvos em: $backupPath\bin"
}
else {
    Log-Warn "Nenhum binario anterior encontrado (primeira instalacao?)"
}

# Backup .env (CRITICO!)
if (Test-Path $EnvFile) {
    Copy-Item $EnvFile -Destination "$backupPath\.env.bak" -Force
    Log-Ok ".env salvo em: $backupPath\.env.bak"
}

# ============================================================
# STEP 5: Migrar .env (adicionar novas chaves v4)
# ============================================================
if (-not $SkipEnvMigration -and (Test-Path $EnvFile)) {
    Log '[5/7] Migrando .env para v4.0...' 'Yellow'

    $envContent = Get-Content $EnvFile -Raw -Encoding UTF8
    $envLines = Get-Content $EnvFile -Encoding UTF8
    $changed = $false

    # --- Garantir SQL_DATABASE_GESTAO ---
    if ($envContent -notmatch 'SQL_DATABASE_GESTAO\s*=') {
        $insertAfter = 'SQL_DATABASE='
        $newLines = @()
        foreach ($line in $envLines) {
            $newLines += $line
            if ($line -match "^SQL_DATABASE=") {
                $newLines += 'SQL_DATABASE_GESTAO=Hiper'
            }
        }
        $envLines = $newLines
        $changed = $true
        Log-Ok "Adicionado: SQL_DATABASE_GESTAO=Hiper"
    }
    else {
        Log "  SQL_DATABASE_GESTAO ja existe" 'Gray'
    }

    # --- Garantir STORE_ID_FILIAL ---
    if ($envContent -notmatch 'STORE_ID_FILIAL\s*=') {
        # Tentar auto-detectar do banco
        $detectedFilial = $null
        try {
            # Ler config existente para pegar credenciais
            $sqlHost = 'localhost'
            $sqlInstance = 'HIPER'
            $sqlUser = $null
            $sqlPass = $null
            $sqlTrusted = $false
            $gestaoDb = 'Hiper'

            foreach ($line in $envLines) {
                if ($line -match '^\s*SQL_SERVER_HOST\s*=\s*(.+)') { $sqlHost = $Matches[1].Trim() }
                if ($line -match '^\s*SQL_SERVER_INSTANCE\s*=\s*(.+)') { $sqlInstance = $Matches[1].Trim() }
                if ($line -match '^\s*SQL_USERNAME\s*=\s*(.+)') { $sqlUser = $Matches[1].Trim() }
                if ($line -match '^\s*SQL_PASSWORD\s*=\s*(.+)') { $sqlPass = $Matches[1].Trim() }
                if ($line -match '^\s*SQL_TRUSTED_CONNECTION\s*=\s*true') { $sqlTrusted = $true }
                if ($line -match '^\s*SQL_DATABASE_GESTAO\s*=\s*(.+)') { $gestaoDb = $Matches[1].Trim() }
            }

            $server = "$sqlHost\$sqlInstance"
            if ($sqlTrusted) {
                $cs = "Server=$server;Database=$gestaoDb;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=10;"
            }
            else {
                $cs = "Server=$server;Database=$gestaoDb;User Id=$sqlUser;Password=$sqlPass;TrustServerCertificate=True;Connect Timeout=10;"
            }

            $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT DISTINCT op.id_filial FROM dbo.operacao_pdv op WHERE op.origem=2 AND op.operacao=1 ORDER BY op.id_filial"
            $reader = $cmd.ExecuteReader()
            $filiais = @()
            while ($reader.Read()) { $filiais += $reader.GetInt32(0) }
            $reader.Close()
            $conn.Close()

            if ($filiais.Count -eq 1) {
                $detectedFilial = $filiais[0]
                Log-Ok "STORE_ID_FILIAL auto-detectado: $detectedFilial"
            }
            elseif ($filiais.Count -gt 1) {
                Log-Warn "Multiplas filiais encontradas: $($filiais -join ', ')"
                Log-Warn "Configure STORE_ID_FILIAL manualmente no .env"
            }
            else {
                Log "  Nenhuma filial Gestao encontrada (origem=2)" 'Gray'
            }
        }
        catch {
            Log-Warn "Nao foi possivel auto-detectar id_filial: $_"
        }

        # Inserir STORE_ID_FILIAL depois de STORE_ID_PONTO_VENDA
        $newLines = @()
        foreach ($line in $envLines) {
            $newLines += $line
            if ($line -match "^STORE_ID_PONTO_VENDA=") {
                if ($detectedFilial) {
                    $newLines += "STORE_ID_FILIAL=$detectedFilial"
                }
                else {
                    $newLines += '# STORE_ID_FILIAL=  (configure manualmente se PDV e Gestao usam IDs diferentes)'
                }
            }
        }
        $envLines = $newLines
        $changed = $true

        if ($detectedFilial) {
            Log-Ok "Adicionado: STORE_ID_FILIAL=$detectedFilial"
        }
        else {
            Log-Warn "STORE_ID_FILIAL adicionado como comentario - configure manualmente"
        }
    }
    else {
        Log "  STORE_ID_FILIAL ja existe" 'Gray'
    }

    # --- Salvar .env atualizado ---
    if ($changed) {
        $envOutput = $envLines -join "`r`n"
        [IO.File]::WriteAllText($EnvFile, $envOutput, [Text.Encoding]::UTF8)
        Log-Ok ".env migrado para v4.0"
    }
    else {
        Log "  .env ja esta atualizado" 'Gray'
    }
}
elseif ($SkipEnvMigration) {
    Log '[5/7] Migracao de .env PULADA (-SkipEnvMigration)' 'DarkGray'
}
else {
    Log '[5/7] .env nao encontrado - sera criado na primeira execucao ou via install.ps1' 'Yellow'
}

# ============================================================
# STEP 6: Parar + Substituir binarios
# ============================================================
Log '[6/7] Parando agente e atualizando binarios...' 'Yellow'

Stop-Agent

# Remover binarios antigos
if (Test-Path $ExePath) { Remove-Item $ExePath -Force }
$internalDir = Join-Path $InstallDir '_internal'
if (Test-Path $internalDir) { Remove-Item $internalDir -Recurse -Force }

# Garantir diretorio de instalacao
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

# Copiar novos binarios
Copy-Item "$ExtractDir\*" $InstallDir -Recurse -Force
Log-Ok "Binarios atualizados"

# ============================================================
# STEP 7: Reiniciar + Verificar saude
# ============================================================
Log '[7/7] Reiniciando e verificando saude...' 'Yellow'

# Marcar timestamp antes de iniciar (para filtrar logs novos)
$startTime = Get-Date

Start-Agent
Start-Sleep -Seconds 8

# --- Verificacao 1: Processo rodando? ---
$proc = Get-Process 'pdv-sync-agent' -ErrorAction SilentlyContinue
if ($proc) {
    Log-Ok "Processo rodando (PID: $($proc.Id))"
}
else {
    Log-Fail "Processo NAO iniciou!"
    Log "  Iniciando ROLLBACK automatico..." 'Red'

    # Rollback binarios
    $binBackup = Join-Path $backupPath 'bin'
    if (Test-Path $binBackup) {
        if (Test-Path $ExePath) { Remove-Item $ExePath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $internalDir) { Remove-Item $internalDir -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item "$binBackup\*" $InstallDir -Recurse -Force
    }

    # Rollback .env
    $envBackup = Join-Path $backupPath '.env.bak'
    if (Test-Path $envBackup) {
        Copy-Item $envBackup $EnvFile -Force
    }

    Start-Agent
    Start-Sleep -Seconds 5

    $procAfter = Get-Process 'pdv-sync-agent' -ErrorAction SilentlyContinue
    if ($procAfter) {
        Log-Warn "ROLLBACK OK - versao anterior restaurada (PID: $($procAfter.Id))"
    }
    else {
        Log-Fail "ROLLBACK FALHOU! Intervencao manual necessaria."
    }

    exit 1
}

# --- Verificacao 2: Versao no log ---
Start-Sleep -Seconds 5

if (Test-Path $AgentLog) {
    $recentLogs = Get-Content $AgentLog -Tail 30 -ErrorAction SilentlyContinue
    $logText = $recentLogs -join "`n"

    if ($logText -match "Starting PDV Sync v$TargetVersion") {
        Log-Ok "Versao v$TargetVersion confirmada nos logs!"
    }
    elseif ($logText -match "Starting PDV Sync v(\d+\.\d+)") {
        Log-Warn "Versao detectada: v$($Matches[1]) (esperada: v$TargetVersion)"
    }

    if ($logText -match 'Database connection established') {
        Log-Ok "Conexao SQL Server OK"
    }
    elseif ($logText -match 'Login failed') {
        Log-Fail "SQL Login falhou! Verifique credenciais no .env"
    }

    if ($logText -match 'STORE_ID_FILIAL not set') {
        Log-Warn "STORE_ID_FILIAL nao configurado - configure no .env"
    }
}

# --- Verificacao 3: .env tem as chaves novas? ---
if (Test-Path $EnvFile) {
    $envCheck = Get-Content $EnvFile -Raw
    $missing = @()
    if ($envCheck -notmatch 'SQL_DATABASE_GESTAO\s*=') { $missing += 'SQL_DATABASE_GESTAO' }
    if ($envCheck -notmatch 'STORE_ID_FILIAL\s*=\s*\d') { $missing += 'STORE_ID_FILIAL' }

    if ($missing.Count -gt 0) {
        Log-Warn "Chaves v4 faltando no .env: $($missing -join ', ')"
        Log "  Edite: notepad `"$EnvFile`"" 'Yellow'
    }
    else {
        Log-Ok "Todas chaves v4 presentes no .env"
    }
}

# ============================================================
# LIMPEZA
# ============================================================
Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================
# RESULTADO
# ============================================================
Log '' 'Cyan'
Log '============================================================' 'Green'
Log '  ATUALIZACAO v4.0 CONCLUIDA!' 'Green'
Log '============================================================' 'Green'
Log ''
Log "  Binario  : $ExePath"
Log "  Config   : $EnvFile"
Log "  Logs     : $AgentLog"
Log "  Backup   : $backupPath"
Log ''
Log '  Comandos uteis:' 'DarkGray'
Log "    Ver logs    : notepad `"$AgentLog`"" 'DarkGray'
Log "    Diagnostico : & `"$ExePath`" --doctor --config `"$EnvFile`"" 'DarkGray'
Log "    Editar .env : notepad `"$EnvFile`"" 'DarkGray'
Log ''

Read-Host "Pressione Enter para sair"
