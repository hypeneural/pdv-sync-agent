@echo off
REM =============================================================================
REM PDV Sync Agent - Updater (v1.1 — com hash + rollback)
REM =============================================================================
REM Baixa a versao mais recente, valida integridade, faz backup antes de trocar.
REM Se a nova versao falhar ao iniciar, reverte automaticamente do backup.
REM
REM Uso:
REM   update.bat                    (baixa do servidor)
REM   update.bat "C:\path\pkg.zip"  (usa zip local)
REM =============================================================================
setlocal EnableDelayedExpansion

REM ===== Elevacao automatica para Admin =====
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permissao de Administrador...
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c \"%~f0\" \"%~1\"' -Verb RunAs"
    exit /b
)

REM ===== Configuracao =====
set "INSTALL_DIR=%ProgramFiles%\PDVSyncAgent"
set "DATA_DIR=%ProgramData%\PDVSyncAgent"
set "BACKUP_DIR=%DATA_DIR%\backup"
set "TASK_NAME=PDVSyncAgent"
set "TMP_DIR=%TEMP%\pdvsync_update"

REM ===== URL do pacote (ajuste para seu servidor de releases) =====
set "ZIP_URL=http://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.zip"
set "HASH_URL=http://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.sha256"

echo.
echo ============================================================
echo   PDV Sync Agent - Atualizador v1.1
echo ============================================================
echo.

REM ===== Preparar temp =====
if exist "%TMP_DIR%" rmdir /s /q "%TMP_DIR%"
mkdir "%TMP_DIR%"

REM ===== Verificar se eh update local =====
if "%~1" neq "" (
    echo Modo local: usando arquivo %~1
    set "LOCAL_ZIP=%~1"
    goto :extract
)

REM ===== 1. Download =====
echo [1/6] Baixando atualizacao...
echo    URL: %ZIP_URL%
echo.

powershell -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;" ^
    "try { Invoke-WebRequest '%ZIP_URL%' -OutFile '%TMP_DIR%\pkg.zip' -UseBasicParsing } catch { Write-Error $_.Exception.Message; exit 1 }"

if %errorlevel% neq 0 (
    echo    ERRO: Falha no download!
    goto :end
)
echo    OK.

set "LOCAL_ZIP=%TMP_DIR%\pkg.zip"

REM ===== 2. Validar hash (opcional — se o servidor fornece .sha256) =====
echo [2/6] Verificando integridade (SHA256)...

powershell -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;" ^
    "try { Invoke-WebRequest '%HASH_URL%' -OutFile '%TMP_DIR%\expected.sha256' -UseBasicParsing } catch { exit 0 }"

if exist "%TMP_DIR%\expected.sha256" (
    REM Calcular hash do zip baixado
    for /f "tokens=*" %%H in ('powershell -Command "(Get-FileHash '%LOCAL_ZIP%' -Algorithm SHA256).Hash"') do set "ACTUAL_HASH=%%H"
    
    REM Ler hash esperado (primeira palavra do arquivo)
    for /f "tokens=1" %%E in (%TMP_DIR%\expected.sha256) do set "EXPECTED_HASH=%%E"
    
    if /i "!ACTUAL_HASH!"=="!EXPECTED_HASH!" (
        echo    Hash OK: !ACTUAL_HASH:~0,16!...
    ) else (
        echo    ERRO: Hash nao confere!
        echo    Esperado: !EXPECTED_HASH:~0,16!...
        echo    Recebido: !ACTUAL_HASH:~0,16!...
        echo    Abortando update (arquivo pode estar corrompido).
        goto :end
    )
) else (
    echo    Arquivo .sha256 nao disponivel (pulando validacao)
)
echo.

:extract
REM ===== 3. Extrair =====
echo [3/6] Extraindo pacote...
powershell -Command "Expand-Archive -Force '%LOCAL_ZIP%' '%TMP_DIR%\pkg'"
if %errorlevel% neq 0 (
    echo    ERRO: Falha ao extrair!
    goto :end
)
echo    OK.

REM ===== 4. Backup da versao atual =====
echo [4/6] Fazendo backup da versao atual...
if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"

REM Limpar backup anterior
if exist "%BACKUP_DIR%\prev" rmdir /s /q "%BACKUP_DIR%\prev"
mkdir "%BACKUP_DIR%\prev"

REM Copiar binarios atuais para backup
if exist "%INSTALL_DIR%\pdv-sync-agent.exe" (
    xcopy /e /i /y "%INSTALL_DIR%\*" "%BACKUP_DIR%\prev\" >nul 2>&1
    echo    Backup salvo em: %BACKUP_DIR%\prev
) else (
    echo    Nenhuma versao anterior encontrada (primeira instalacao?)
)
echo.

REM ===== 5. Parar + substituir =====
echo [5/6] Parando agente e atualizando binarios...
schtasks /end /tn "%TASK_NAME%" >nul 2>&1
timeout /t 3 /nobreak >nul

REM Remover exe e _internal antigos
del /q "%INSTALL_DIR%\pdv-sync-agent.exe" >nul 2>&1
if exist "%INSTALL_DIR%\_internal" rmdir /s /q "%INSTALL_DIR%\_internal" >nul 2>&1

REM Copiar novos
xcopy /e /i /y "%TMP_DIR%\pkg\*" "%INSTALL_DIR%\" >nul 2>&1
echo    OK.

REM ===== 6. Reiniciar e verificar =====
echo [6/6] Reiniciando agente...
schtasks /run /tn "%TASK_NAME%"

REM Esperar 5 segundos e verificar se o processo subiu
timeout /t 5 /nobreak >nul

tasklist /fi "IMAGENAME eq pdv-sync-agent.exe" 2>nul | find /i "pdv-sync-agent.exe" >nul
if %errorlevel% equ 0 (
    echo    Agente rodando com sucesso!
) else (
    echo.
    echo    AVISO: Agente pode nao ter iniciado corretamente!
    echo    Tentando rollback do backup...
    
    REM Rollback
    schtasks /end /tn "%TASK_NAME%" >nul 2>&1
    timeout /t 2 /nobreak >nul
    
    del /q "%INSTALL_DIR%\pdv-sync-agent.exe" >nul 2>&1
    if exist "%INSTALL_DIR%\_internal" rmdir /s /q "%INSTALL_DIR%\_internal" >nul 2>&1
    
    xcopy /e /i /y "%BACKUP_DIR%\prev\*" "%INSTALL_DIR%\" >nul 2>&1
    schtasks /run /tn "%TASK_NAME%"
    
    echo    Rollback concluido. Versao anterior restaurada.
    echo    Verifique o log: %DATA_DIR%\logs\agent.log
)

REM ===== Limpeza =====
if exist "%TMP_DIR%" rmdir /s /q "%TMP_DIR%" >nul 2>&1

echo.
echo ============================================================
echo   ATUALIZACAO CONCLUIDA
echo ============================================================
echo.
echo   Verifique o log:
echo     notepad "%DATA_DIR%\logs\agent.log"
echo.
echo   Diagnostico:
echo     "%INSTALL_DIR%\pdv-sync-agent.exe" --doctor --config "%DATA_DIR%\.env"
echo.

:end
endlocal
pause
