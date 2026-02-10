@echo off
REM =============================================================================
REM PDV Sync Agent - Installer (v1.1 — Hardened)
REM =============================================================================
REM Executa como ADMIN automaticamente.
REM Verifica ODBC driver, copia binario para Program Files,
REM cria dados em ProgramData, registra tarefa no Agendador.
REM =============================================================================
setlocal EnableDelayedExpansion

REM ===== Elevacao automatica para Admin =====
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permissao de Administrador...
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

REM ===== Variaveis =====
set "INSTALL_DIR=%ProgramFiles%\PDVSyncAgent"
set "DATA_DIR=%ProgramData%\PDVSyncAgent"
set "TASK_NAME=PDVSyncAgent"
set "SOURCE_DIR=%~dp0"

echo.
echo ============================================================
echo   PDV Sync Agent - Instalador v1.1
echo ============================================================
echo.
echo   Binario : %INSTALL_DIR%
echo   Dados   : %DATA_DIR%
echo.

REM ===== 0. Verificar ODBC Driver =====
echo [0/6] Verificando driver ODBC...

set "ODBC_OK=0"
set "ODBC_DRIVER="

REM Check for Driver 18
reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server" >nul 2>&1
if %errorlevel% equ 0 (
    set "ODBC_OK=1"
    set "ODBC_DRIVER=ODBC Driver 18 for SQL Server"
    echo    Encontrado: ODBC Driver 18 for SQL Server
    goto :odbc_done
)

REM Check for Driver 17
reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 17 for SQL Server" >nul 2>&1
if %errorlevel% equ 0 (
    set "ODBC_OK=1"
    set "ODBC_DRIVER=ODBC Driver 17 for SQL Server"
    echo    Encontrado: ODBC Driver 17 for SQL Server
    goto :odbc_done
)

REM Not found
echo.
echo    ============================================
echo    ATENCAO: Driver ODBC do SQL Server NAO encontrado!
echo    ============================================
echo.
echo    O agente precisa do "ODBC Driver 17 for SQL Server"
echo    ou "ODBC Driver 18 for SQL Server" para funcionar.
echo.

REM Check if installer is bundled
if exist "%SOURCE_DIR%msodbcsql.msi" (
    echo    Instalador encontrado no pacote: msodbcsql.msi
    set /p "INSTALL_ODBC=   Deseja instalar agora? (S/N): "
    if /i "!INSTALL_ODBC!"=="S" (
        echo    Instalando driver ODBC...
        msiexec /i "%SOURCE_DIR%msodbcsql.msi" /passive /norestart IACCEPTMSODBCSQLLICENSETERMS=YES
        if !errorlevel! equ 0 (
            echo    Driver instalado com sucesso!
            set "ODBC_OK=1"
        ) else (
            echo    ERRO na instalacao do driver!
        )
    )
) else (
    echo    Baixe e instale manualmente:
    echo    https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server
    echo.
    set /p "CONTINUE=   Continuar mesmo assim? (S/N): "
    if /i not "!CONTINUE!"=="S" (
        echo    Instalacao cancelada.
        goto :end
    )
)

:odbc_done
echo.

REM ===== 1. Copiar binarios para Program Files =====
echo [1/6] Copiando binarios...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

REM Copiar executavel
xcopy /e /i /y "%SOURCE_DIR%pdv-sync-agent.exe" "%INSTALL_DIR%\" >nul 2>&1
if exist "%SOURCE_DIR%_internal" (
    xcopy /e /i /y "%SOURCE_DIR%_internal" "%INSTALL_DIR%\_internal\" >nul 2>&1
)
echo    OK.

REM ===== 2. Criar pastas de dados =====
echo [2/6] Criando estrutura de dados...
if not exist "%DATA_DIR%" mkdir "%DATA_DIR%"
if not exist "%DATA_DIR%\data" mkdir "%DATA_DIR%\data"
if not exist "%DATA_DIR%\data\outbox" mkdir "%DATA_DIR%\data\outbox"
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs"
if not exist "%DATA_DIR%\backup" mkdir "%DATA_DIR%\backup"
echo    OK.

REM ===== 3. Configuracao interativa =====
set "CFG=%DATA_DIR%\.env"

if exist "%CFG%" (
    echo [3/6] Configuracao ja existe: "%CFG%"
    echo    Pulando... ^(edite manualmente se necessario^)
    goto :skip_config
)

echo [3/6] Configuracao inicial...
echo.

set /p "STORE_ID=   ID da Loja (store_id_ponto_venda, ex: 10): "
set /p "STORE_ALIAS=   Apelido da Loja (ex: TIJUCAS-01): "
set /p "DB_PASSWORD=   Senha do usuario pdv_sync no SQL Server: "
set /p "API_TOKEN=   Token da API (ou ENTER para placeholder): "

if "!API_TOKEN!"=="" set "API_TOKEN=COLOQUE_SEU_TOKEN_AQUI"

REM Copiar template e substituir placeholders
copy /y "%SOURCE_DIR%config.template.env" "%CFG%" >nul 2>&1

REM Substituir placeholders usando PowerShell (UTF8 sem BOM)
powershell -Command ^
    "$c = Get-Content -Raw '%CFG%';" ^
    "$c = $c -replace '__STORE_ID__', '%STORE_ID%';" ^
    "$c = $c -replace '__STORE_ALIAS__', '%STORE_ALIAS%';" ^
    "$c = $c -replace '__DB_PASSWORD__', '%DB_PASSWORD%';" ^
    "$c = $c -replace '__API_TOKEN__', '%API_TOKEN%';" ^
    "[IO.File]::WriteAllText('%CFG%', $c)"

echo    Config salvo em: %CFG%
echo.

:skip_config

REM ===== 4. Registrar tarefa agendada =====
echo [4/6] Registrando tarefa no Agendador do Windows...

set "EXE_PATH=%INSTALL_DIR%\pdv-sync-agent.exe"
set "EXE_ARGS=--loop --config \"%CFG%\""
set "TASK_XML=%DATA_DIR%\task.xml"

REM Copiar template XML
set "TPL=%SOURCE_DIR%task.template.xml"

REM Gerar XML final substituindo placeholders (UTF-16 para schtasks)
powershell -Command ^
    "$t = Get-Content -Raw '%TPL%';" ^
    "$t = $t -replace '__EXE_PATH__', '%EXE_PATH%';" ^
    "$t = $t -replace '__EXE_ARGS__', '%EXE_ARGS%';" ^
    "$t = $t -replace '__INSTALL_DIR__', '%INSTALL_DIR%';" ^
    "[IO.File]::WriteAllText('%TASK_XML%', $t, [Text.Encoding]::Unicode)"

REM Remover tarefa antiga (se existir)
schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1

REM Criar tarefa a partir do XML
schtasks /create /tn "%TASK_NAME%" /xml "%TASK_XML%" /f
if %errorlevel% neq 0 (
    echo    ERRO: Falha ao criar tarefa agendada!
    echo    Verifique as permissoes.
    goto :end
)
echo    OK.

REM ===== 5. Rodar diagnostico =====
echo [5/6] Executando diagnostico...
echo.
"%EXE_PATH%" --doctor --config "%CFG%"
echo.

REM ===== 6. Iniciar agente =====
echo [6/6] Iniciando agente...
schtasks /run /tn "%TASK_NAME%"
echo    OK.

echo.
echo ============================================================
echo   INSTALACAO CONCLUIDA COM SUCESSO!
echo ============================================================
echo.
echo   Binario   : %INSTALL_DIR%
echo   Config    : %CFG%
echo   Logs      : %DATA_DIR%\logs
echo   Dados     : %DATA_DIR%\data
echo   Tarefa    : %TASK_NAME% (Agendador de Tarefas)
echo.
echo   O agente inicia automaticamente a cada boot.
echo   Em caso de falha, sera reiniciado em 1 minuto.
echo   Nao roda 2 instancias simultaneas.
echo.
echo   Comandos uteis:
echo     Verificar status : schtasks /query /tn %TASK_NAME% /v
echo     Parar            : schtasks /end /tn %TASK_NAME%
echo     Diagnostico      : "%EXE_PATH%" --doctor --config "%CFG%"
echo     Logs             : notepad "%DATA_DIR%\logs\agent.log"
echo.

:end
endlocal
pause
