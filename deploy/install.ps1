#Requires -RunAsAdministrator
<#
.SYNOPSIS
    PDV Sync Agent - Installer v3.0 (PowerShell)
.DESCRIPTION
    Instala ODBC 17, cria usuario SQL, gera .env, copia binarios,
    cria Task Scheduler e valida tudo rodando como SYSTEM.
.NOTES
    Rodar como Admin. Chamado pelo install.bat.
#>

param(
    [switch]$Repair
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
$LogDir = Join-Path $DataDir 'logs'
$SourceDir = $PSScriptRoot
$EnvFile = Join-Path $DataDir '.env'
$InstallLog = Join-Path $LogDir 'install.log'
$OdbcMsiPath = Join-Path $SourceDir 'extra\msodbcsql.msi'
$ExePath = Join-Path $InstallDir 'pdv-sync-agent.exe'
$DefaultSqlPwd = 'PdvSync2026!'
$DefaultSqlUser = 'pdv_sync'
$DefaultDb = 'HiperPdv'
$DefaultDbGestao = 'Hiper'

# ============================================================
# HELPERS
# ============================================================

function Write-Step {
    param([string]$Step, [string]$Message)
    $msg = "[$Step] $Message"
    Write-Host $msg -ForegroundColor Cyan
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $InstallLog -Value "$ts | $msg" -ErrorAction SilentlyContinue
}

function Write-Ok {
    param([string]$Message = 'OK')
    Write-Host "    $Message" -ForegroundColor Green
    Add-Content -Path $InstallLog -Value "    OK: $Message" -ErrorAction SilentlyContinue
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    AVISO: $Message" -ForegroundColor Yellow
    Add-Content -Path $InstallLog -Value "    WARN: $Message" -ErrorAction SilentlyContinue
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    ERRO: $Message" -ForegroundColor Red
    Add-Content -Path $InstallLog -Value "    FAIL: $Message" -ErrorAction SilentlyContinue
}

# ============================================================
# START
# ============================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor White
Write-Host '  PDV Sync Agent - Instalador v3.0' -ForegroundColor White
Write-Host '============================================================' -ForegroundColor White
Write-Host ''
Write-Host "  Binario : $InstallDir"
Write-Host "  Dados   : $DataDir"
Write-Host ''

# Prepare dirs + log
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $DataDir 'data') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $DataDir 'data\outbox') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $DataDir 'backup') -Force | Out-Null
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content -Path $InstallLog -Value "`n$ts | === INSTALL START ===" -ErrorAction SilentlyContinue

# ============================================================
# STEP 1: ODBC 17
# ============================================================
Write-Step '1/8' 'Verificando driver ODBC 17...'

$driversKey = 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers'
$has17 = $null
try {
    $has17 = (Get-ItemProperty $driversKey -ErrorAction SilentlyContinue).'ODBC Driver 17 for SQL Server'
}
catch {}

if ($has17) {
    Write-Ok 'ODBC Driver 17 for SQL Server ja instalado'
}
else {
    # Try to install from bundled MSI
    if (-not (Test-Path $OdbcMsiPath)) {
        Write-Fail "msodbcsql.msi nao encontrado em: $OdbcMsiPath"
        Write-Host '  Coloque o arquivo em: extra\msodbcsql.msi' -ForegroundColor Yellow
        exit 1
    }

    Write-Host '    Instalando ODBC 17 silenciosamente...' -ForegroundColor Yellow
    $odbcLog = Join-Path $LogDir 'odbc_install.log'

    $msiArgs = '/i "' + $OdbcMsiPath + '" /qn /norestart IACCEPTMSODBCSQLLICENSETERMS=YES /L*v "' + $odbcLog + '"'
    $proc = Start-Process msiexec -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -notin @(0, 3010)) {
        Write-Fail "ODBC install falhou (exit code: $($proc.ExitCode))"
        Write-Host "    Log: $odbcLog" -ForegroundColor Yellow
        exit 1
    }

    if ($proc.ExitCode -eq 3010) {
        Write-Warn 'ODBC instalado, mas reboot recomendado (exit 3010)'
    }

    # Validate post-install
    Start-Sleep -Seconds 2
    $has17 = $null
    try {
        $has17 = (Get-ItemProperty $driversKey -ErrorAction SilentlyContinue).'ODBC Driver 17 for SQL Server'
    }
    catch {}

    if ($has17) {
        Write-Ok 'ODBC Driver 17 instalado e confirmado no registry'
    }
    else {
        Write-Fail 'ODBC Driver 17 NAO aparece no registry apos instalacao!'
        Write-Host "    Log: $odbcLog" -ForegroundColor Yellow
        exit 1
    }
}

# ============================================================
# STEP 2: Detectar instancia SQL Server
# ============================================================
Write-Step '2/8' 'Detectando instancia SQL Server...'

$sqlServices = @(Get-Service -Name 'MSSQL$*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Running' })

$Instance = $null

if ($sqlServices.Length -gt 0) {
    foreach ($svc in $sqlServices) {
        $instName = $svc.Name.Replace('MSSQL$', '')
        Write-Host "    Encontrada: localhost\$instName (Status: $($svc.Status))" -ForegroundColor White
        if (-not $Instance) {
            $Instance = "localhost\$instName"
        }
    }
    Write-Ok "Usando: $Instance"
}
else {
    Write-Warn 'Nenhum servico MSSQL encontrado. Tentando localhost\HIPER...'
    $Instance = 'localhost\HIPER'
}

# ============================================================
# STEP 3: Criar usuario SQL (via SqlClient, sem sqlcmd)
# ============================================================
Write-Step '3/8' "Criando usuario SQL '$DefaultSqlUser'..."

$sqlCreated = $false

# Build SQL scripts as simple strings (no here-strings)
$tsqlLogin = "IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = '$DefaultSqlUser') " +
"CREATE LOGIN [$DefaultSqlUser] WITH PASSWORD = '$DefaultSqlPwd', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF; " +
"ELSE " +
"ALTER LOGIN [$DefaultSqlUser] WITH PASSWORD = '$DefaultSqlPwd';"

$tsqlUser = "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$DefaultSqlUser') " +
"CREATE USER [$DefaultSqlUser] FOR LOGIN [$DefaultSqlUser]; " +
"ALTER ROLE [db_datareader] ADD MEMBER [$DefaultSqlUser];"

try {
    # Tentar com Windows Auth do tecnico (estrategia A)
    $cs = "Server=$Instance;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=10;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
    $conn.Open()
    Write-Host '    Conectado via Windows Auth' -ForegroundColor White

    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $tsqlLogin
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "    Login '$DefaultSqlUser' criado/atualizado no SQL Server" -ForegroundColor White

    # Criar user no HiperPdv
    $conn.ChangeDatabase($DefaultDb)
    $cmd.CommandText = $tsqlUser
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "    db_datareader concedido no $DefaultDb" -ForegroundColor White

    # Criar user no Hiper (Gestao) - necessario para vendas Loja
    $conn.ChangeDatabase($DefaultDbGestao)
    $cmd.CommandText = $tsqlUser
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "    db_datareader concedido no $DefaultDbGestao" -ForegroundColor White

    $conn.Close()

    $sqlCreated = $true
    Write-Ok "Usuario '$DefaultSqlUser' pronto com db_datareader em $DefaultDb + $DefaultDbGestao"

}
catch {
    Write-Warn "Windows Auth falhou: $($_.Exception.Message)"
    Write-Host ''

    # Estrategia B: pedir credencial SQL admin
    Write-Host '    Para criar o usuario, informe um admin SQL:' -ForegroundColor Yellow
    $saUser = Read-Host '    Usuario SQL admin (ex: sa)'
    $saPass = Read-Host '    Senha' -AsSecureString
    $saBSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPass)
    $saPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($saBSTR)

    try {
        $cs2 = "Server=$Instance;Database=master;User Id=$saUser;Password=$saPlain;TrustServerCertificate=True;Connect Timeout=10;"
        $conn2 = New-Object System.Data.SqlClient.SqlConnection($cs2)
        $conn2.Open()

        $cmd2 = $conn2.CreateCommand()
        $cmd2.CommandText = $tsqlLogin
        $cmd2.ExecuteNonQuery() | Out-Null

        $conn2.ChangeDatabase($DefaultDb)
        $cmd2.CommandText = $tsqlUser
        $cmd2.ExecuteNonQuery() | Out-Null

        # Criar user no Hiper (Gestao)
        $conn2.ChangeDatabase($DefaultDbGestao)
        $cmd2.CommandText = $tsqlUser
        $cmd2.ExecuteNonQuery() | Out-Null
        $conn2.Close()

        $sqlCreated = $true
        Write-Ok "Usuario '$DefaultSqlUser' criado via SQL Auth ($DefaultDb + $DefaultDbGestao)"
    }
    catch {
        Write-Fail "Nao foi possivel criar usuario: $($_.Exception.Message)"
        Write-Host '    Crie manualmente no SQL Server Management Studio' -ForegroundColor Yellow
        Write-Host '    e configure a senha no .env' -ForegroundColor Yellow
    }
}

# ============================================================
# STEP 4: Detectar Store ID
# ============================================================
Write-Step '4/8' 'Detectando lojas no banco...'

$StoreId = $null
$StoreName = $null

try {
    $csPdv = "Server=$Instance;Database=$DefaultDb;User Id=$DefaultSqlUser;Password=$DefaultSqlPwd;TrustServerCertificate=True;Connect Timeout=10;"
    $connPdv = New-Object System.Data.SqlClient.SqlConnection($csPdv)
    $connPdv.Open()

    $cmdPdv = $connPdv.CreateCommand()

    # Check which name column exists
    $cmdPdv.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'ponto_venda' AND COLUMN_NAME IN ('apelido','nome','descricao') ORDER BY ORDINAL_POSITION"
    $reader = $cmdPdv.ExecuteReader()
    $nameCol = 'id_ponto_venda'
    while ($reader.Read()) {
        $nameCol = $reader.GetString(0)
        break
    }
    $reader.Close()

    $cmdPdv.CommandText = "SELECT id_ponto_venda, $nameCol AS nome FROM dbo.ponto_venda ORDER BY id_ponto_venda"
    $reader = $cmdPdv.ExecuteReader()

    $stores = @()
    while ($reader.Read()) {
        $stores += [PSCustomObject]@{
            Id   = $reader.GetInt32(0)
            Nome = $reader.GetValue(1)
        }
    }
    $reader.Close()
    $connPdv.Close()

    if ($stores.Count -gt 0) {
        Write-Host ''
        Write-Host '    Lojas encontradas:' -ForegroundColor White
        foreach ($s in $stores) {
            Write-Host "      [$($s.Id)] $($s.Nome)" -ForegroundColor White
        }
        Write-Host ''

        if ($stores.Count -eq 1) {
            $StoreId = $stores[0].Id
            $StoreName = $stores[0].Nome
            Write-Ok "Selecionada automaticamente: [$StoreId] $StoreName"
        }
        else {
            $inputId = Read-Host '    Digite o ID da loja'
            $StoreId = [int]$inputId
            $match = $stores | Where-Object { $_.Id -eq $StoreId }
            if ($match) { $StoreName = $match.Nome } else { $StoreName = "PDV $StoreId" }
        }
    }
}
catch {
    Write-Warn "Nao foi possivel listar lojas: $($_.Exception.Message)"
}

if (-not $StoreId) {
    $StoreId = Read-Host '    Digite o ID da loja (store_id_ponto_venda)'
    $StoreId = [int]$StoreId
}

$StoreAlias = Read-Host '    Apelido da loja (ex: TIJUCAS-01)'
if (-not $StoreAlias) { $StoreAlias = "loja-$StoreId" }

Write-Ok "Loja: [$StoreId] $StoreAlias"

# ============================================================
# STEP 5: Gerar .env
# ============================================================
Write-Step '5/8' 'Gerando configuracao (.env)...'

if ((Test-Path $EnvFile) -and -not $Repair) {
    Write-Ok "Config ja existe: $EnvFile (pulando)"
    Write-Host '    Use -Repair para reescrever' -ForegroundColor Yellow
}
else {
    # Pedir token da API
    $ApiToken = Read-Host '    Token da API (ou ENTER para placeholder)'
    if (-not $ApiToken) { $ApiToken = 'COLOQUE_SEU_TOKEN_AQUI' }

    # Extract instance name
    $instName = ($Instance -split '\\')[-1]

    $envLines = @(
        '# =========================================================='
        '# PDV Sync Agent v3.0 - Configuracao de Producao'
        "# Gerado automaticamente em $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        '# =========================================================='
        ''
        '# --- SQL Server ---'
        'SQL_SERVER_HOST=localhost'
        "SQL_SERVER_INSTANCE=$instName"
        "SQL_DATABASE=$DefaultDb"
        "SQL_DATABASE_GESTAO=$DefaultDbGestao"
        'SQL_DRIVER=ODBC Driver 17 for SQL Server'
        'SQL_ENCRYPT=no'
        'SQL_TRUST_SERVER_CERT=yes'
        ''
        '# --- Autenticacao SQL (padrao para deploy) ---'
        'SQL_TRUSTED_CONNECTION=false'
        "SQL_USERNAME=$DefaultSqlUser"
        "SQL_PASSWORD=$DefaultSqlPwd"
        ''
        '# --- Loja ---'
        "STORE_ID_PONTO_VENDA=$StoreId"
        "STORE_ALIAS=$StoreAlias"
        ''
        '# --- API ---'
        'API_ENDPOINT=https://webhook.soclick.click/webhook/1276580b-9957-402a-8ad6-bb13b9e0d349'
        "API_TOKEN=$ApiToken"
        'REQUEST_TIMEOUT_SECONDS=15'
        ''
        '# --- Sync ---'
        'SYNC_WINDOW_MINUTES=10'
        ''
        '# --- Caminhos (absolutos) ---'
        "STATE_FILE=$DataDir\data\state.json"
        "OUTBOX_DIR=$DataDir\data\outbox"
        ''
        '# --- Logs ---'
        "LOG_FILE=$DataDir\logs\agent.log"
        'LOG_LEVEL=INFO'
        'LOG_ROTATION=10 MB'
        'LOG_RETENTION=30 days'
    )

    $envContent = $envLines -join "`r`n"
    [IO.File]::WriteAllText($EnvFile, $envContent, [Text.Encoding]::UTF8)
    Write-Ok "Config salvo em: $EnvFile"
}

# ============================================================
# STEP 6: Copiar binarios
# ============================================================
Write-Step '6/8' "Copiando binarios para $InstallDir..."

# Parar task existente antes de copiar (evita file lock)
try { schtasks /end /tn $TaskName 2>&1 | Out-Null } catch {}
Start-Sleep -Seconds 3
try { Stop-Process -Name 'pdv-sync-agent' -Force -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 1

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Copy exe
$srcExe = Join-Path $SourceDir 'pdv-sync-agent.exe'
if (Test-Path $srcExe) {
    Copy-Item $srcExe $InstallDir -Force
}
else {
    Write-Fail "pdv-sync-agent.exe nao encontrado em: $SourceDir"
    exit 1
}

# Copy _internal
$srcInternal = Join-Path $SourceDir '_internal'
if (Test-Path $srcInternal) {
    Copy-Item $srcInternal $InstallDir -Recurse -Force
}

# Copy utility scripts
foreach ($script in @('update.bat', 'uninstall.bat')) {
    $src = Join-Path $SourceDir $script
    if (Test-Path $src) { Copy-Item $src $InstallDir -Force }
}

Write-Ok 'Binarios copiados'

# ============================================================
# STEP 7: Task Scheduler
# ============================================================
Write-Step '7/8' 'Configurando tarefa agendada...'

# Delete existing task (already stopped in step 6)
try { schtasks /delete /tn $TaskName /f 2>&1 | Out-Null } catch {}

# Build task XML using array join (no here-strings)
$xmlLines = @(
    '<?xml version="1.0" encoding="UTF-16"?>'
    '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
    '  <RegistrationInfo>'
    "    <URI>\$TaskName</URI>"
    '    <Description>PDV Sync Agent v3.0 - Sincronizacao automatica de vendas</Description>'
    '  </RegistrationInfo>'
    '  <Triggers>'
    '    <BootTrigger>'
    '      <Enabled>true</Enabled>'
    '      <Delay>PT30S</Delay>'
    '    </BootTrigger>'
    '  </Triggers>'
    '  <Principals>'
    '    <Principal id="Author">'
    '      <UserId>S-1-5-18</UserId>'
    '      <RunLevel>HighestAvailable</RunLevel>'
    '    </Principal>'
    '  </Principals>'
    '  <Settings>'
    '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
    '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
    '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
    '    <StartWhenAvailable>true</StartWhenAvailable>'
    '    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>'
    '    <IdleSettings>'
    '      <StopOnIdleEnd>false</StopOnIdleEnd>'
    '      <RestartOnIdle>false</RestartOnIdle>'
    '    </IdleSettings>'
    '    <AllowHardTerminate>true</AllowHardTerminate>'
    '    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'
    '    <RestartOnFailure>'
    '      <Interval>PT1M</Interval>'
    '      <Count>999</Count>'
    '    </RestartOnFailure>'
    '    <Enabled>true</Enabled>'
    '    <Hidden>false</Hidden>'
    '  </Settings>'
    '  <Actions Context="Author">'
    '    <Exec>'
    "      <Command>$ExePath</Command>"
    "      <Arguments>--loop --config `"$EnvFile`"</Arguments>"
    "      <WorkingDirectory>$InstallDir</WorkingDirectory>"
    '    </Exec>'
    '  </Actions>'
    '</Task>'
)

$taskXmlContent = $xmlLines -join "`r`n"
$taskXmlPath = Join-Path $DataDir 'task.xml'
[IO.File]::WriteAllText($taskXmlPath, $taskXmlContent, [Text.Encoding]::Unicode)

$result = schtasks /create /tn $TaskName /xml $taskXmlPath /f 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Falha ao criar tarefa: $result"
    exit 1
}
Write-Ok "Tarefa '$TaskName' criada (boot + restart on fail)"

# ---- Shutdown Task (last-chance sync) ----
$ShutdownTaskName = 'PDVSyncAgent_Shutdown'
$shutdownScript = Join-Path $DataDir 'on_shutdown.ps1'

# Copy shutdown script
$srcShutdown = Join-Path $SourceDir 'on_shutdown.ps1'
if (Test-Path $srcShutdown) {
    Copy-Item $srcShutdown $shutdownScript -Force
}

try { schtasks /delete /tn $ShutdownTaskName /f 2>&1 | Out-Null } catch {}

$shutdownXmlLines = @(
    '<?xml version="1.0" encoding="UTF-16"?>'
    '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
    '  <RegistrationInfo>'
    "    <URI>\$ShutdownTaskName</URI>"
    '    <Description>PDV Sync Agent - Last-chance sync on shutdown/logoff</Description>'
    '  </RegistrationInfo>'
    '  <Triggers>'
    '    <EventTrigger>'
    '      <Enabled>true</Enabled>'
    '      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name=''User32''] and (EventID=1074)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>'
    '    </EventTrigger>'
    '  </Triggers>'
    '  <Principals>'
    '    <Principal id="Author">'
    '      <UserId>S-1-5-18</UserId>'
    '      <RunLevel>HighestAvailable</RunLevel>'
    '    </Principal>'
    '  </Principals>'
    '  <Settings>'
    '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
    '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
    '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
    '    <AllowHardTerminate>true</AllowHardTerminate>'
    '    <ExecutionTimeLimit>PT30S</ExecutionTimeLimit>'
    '    <Enabled>true</Enabled>'
    '    <Hidden>true</Hidden>'
    '  </Settings>'
    '  <Actions Context="Author">'
    '    <Exec>'
    "      <Command>powershell.exe</Command>"
    "      <Arguments>-ExecutionPolicy Bypass -File `"$shutdownScript`"</Arguments>"
    "      <WorkingDirectory>$InstallDir</WorkingDirectory>"
    '    </Exec>'
    '  </Actions>'
    '</Task>'
)

$shutdownXmlContent = $shutdownXmlLines -join "`r`n"
$shutdownXmlPath = Join-Path $DataDir 'task_shutdown.xml'
[IO.File]::WriteAllText($shutdownXmlPath, $shutdownXmlContent, [Text.Encoding]::Unicode)

$result = schtasks /create /tn $ShutdownTaskName /xml $shutdownXmlPath /f 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Tarefa '$ShutdownTaskName' criada (shutdown/logoff trigger)"
}
else {
    Write-Host "    AVISO: Nao foi possivel criar tarefa de shutdown: $result" -ForegroundColor Yellow
    Write-Host "    (Agente funcionara normalmente, mas sem sync no desligamento)" -ForegroundColor Yellow
}

# ============================================================
# STEP 8: Validacao real (roda como SYSTEM)
# ============================================================
Write-Step '8/8' 'Validando (rodando task como SYSTEM)...'

# First run --doctor as current user
Write-Host ''
Write-Host '    --- Doctor (como admin) ---' -ForegroundColor DarkGray
& $ExePath --doctor --config $EnvFile
Write-Host ''

# Now run the actual task as SYSTEM
Write-Host '    --- Iniciando task como SYSTEM ---' -ForegroundColor DarkGray
schtasks /run /tn $TaskName | Out-Null
Start-Sleep -Seconds 10

# Check log for success/failure
$agentLog = Join-Path $DataDir 'logs\agent.log'
if (Test-Path $agentLog) {
    $logTail = Get-Content $agentLog -Tail 30 -ErrorAction SilentlyContinue
    $logText = $logTail -join "`n"

    if ($logText -match 'Login failed') {
        Write-Fail 'Task SYSTEM nao conseguiu conectar ao SQL Server!'
        Write-Host "    Verifique se SQL_TRUSTED_CONNECTION=false no .env" -ForegroundColor Yellow
        Write-Host "    e se o usuario '$DefaultSqlUser' existe no SQL Server" -ForegroundColor Yellow
    }
    elseif ($logText -match 'Database connection established') {
        Write-Ok 'Task rodando como SYSTEM - conexao SQL OK!'
    }
    elseif ($logText -match 'Starting PDV Sync') {
        Write-Ok 'Task iniciada (verificando conexao...)'
    }
    else {
        Write-Warn "Log nao mostra resultado claro. Verifique: $agentLog"
    }
}
else {
    Write-Warn "Log nao encontrado: $agentLog"
    Write-Host '    A task pode demorar alguns segundos para iniciar' -ForegroundColor Yellow
}

# ============================================================
# DONE
# ============================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host '  INSTALACAO CONCLUIDA COM SUCESSO!' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host ''
Write-Host "  Binario    : $ExePath"
Write-Host "  Config     : $EnvFile"
Write-Host "  Logs       : $LogDir"
Write-Host "  Dados      : $DataDir\data"
Write-Host "  Tarefa     : $TaskName (Agendador de Tarefas)"
Write-Host "  Log Install: $InstallLog"
Write-Host ''
Write-Host '  O agente inicia automaticamente a cada boot.' -ForegroundColor White
Write-Host '  Em caso de falha, reinicia em 1 minuto.' -ForegroundColor White
Write-Host ''
Write-Host '  Comandos uteis:' -ForegroundColor DarkGray
Write-Host "    Verificar status : schtasks /query /tn $TaskName /v" -ForegroundColor DarkGray
Write-Host "    Parar            : schtasks /end /tn $TaskName" -ForegroundColor DarkGray
Write-Host "    Diagnostico      : `"$ExePath`" --doctor --config `"$EnvFile`"" -ForegroundColor DarkGray
Write-Host "    Logs             : notepad `"$agentLog`"" -ForegroundColor DarkGray
Write-Host '    Reinstalar       : .\install.ps1 -Repair' -ForegroundColor DarkGray
Write-Host ''

$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content -Path $InstallLog -Value "$ts | === INSTALL COMPLETE ===" -ErrorAction SilentlyContinue
