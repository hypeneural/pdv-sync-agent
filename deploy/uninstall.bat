@echo off
REM =============================================================================
REM PDV Sync Agent - Uninstaller
REM =============================================================================
REM Remove a tarefa agendada e os binarios.
REM Preserva dados (logs, state, outbox) em ProgramData por seguranca.
REM =============================================================================
setlocal

REM ===== Elevacao automatica para Admin =====
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permissao de Administrador...
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

set "INSTALL_DIR=%ProgramFiles%\PDVSyncAgent"
set "DATA_DIR=%ProgramData%\PDVSyncAgent"
set "TASK_NAME=PDVSyncAgent"

echo.
echo ============================================================
echo   PDV Sync Agent - Desinstalador
echo ============================================================
echo.

REM ===== 1. Parar e remover tarefa =====
echo [1/3] Parando tarefa agendada...
schtasks /end /tn "%TASK_NAME%" >nul 2>&1
timeout /t 2 /nobreak >nul
schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1
echo    OK.

REM ===== 2. Remover binarios =====
echo [2/3] Removendo binarios de %INSTALL_DIR%...
if exist "%INSTALL_DIR%" (
    rmdir /s /q "%INSTALL_DIR%" >nul 2>&1
    if exist "%INSTALL_DIR%" (
        echo    AVISO: Alguns arquivos nao puderam ser removidos.
        echo    O processo pode estar em execucao. Tente novamente apos reiniciar.
    ) else (
        echo    OK.
    )
) else (
    echo    Pasta nao encontrada (ja removida?).
)

REM ===== 3. Preservar dados =====
echo [3/3] Dados preservados em:
echo    %DATA_DIR%
echo.
echo    Conteudo preservado:
echo      - Config : %DATA_DIR%\.env
echo      - Logs   : %DATA_DIR%\logs\
echo      - State  : %DATA_DIR%\data\state.json
echo      - Outbox : %DATA_DIR%\data\outbox\
echo.
echo    Para remover TUDO (inclusive dados), execute:
echo      rmdir /s /q "%DATA_DIR%"
echo.

echo ============================================================
echo   DESINSTALACAO CONCLUIDA
echo ============================================================
echo.

endlocal
pause
