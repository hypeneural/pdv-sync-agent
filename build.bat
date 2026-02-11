@echo off
REM =============================================================================
REM PDV Sync Agent - Build Script
REM =============================================================================
REM Cria o executavel (.exe) usando PyInstaller e monta a pasta de distribuicao.
REM Execute este script na maquina de DESENVOLVIMENTO, nao na loja.
REM
REM Pre-requisitos: Python 3.11+ instalado e no PATH
REM =============================================================================
setlocal EnableDelayedExpansion

set "APP_NAME=pdv-sync-agent"
set "ENTRY=agent.py"
set "DIST_FOLDER=PDVSyncAgent_dist"

echo.
echo ============================================================
echo   PDV Sync Agent - Build
echo ============================================================
echo.

REM ===== 1. Criar venv limpa =====
echo [1/5] Criando virtual environment limpo...
if exist .venv_build rmdir /s /q .venv_build
python -m venv .venv_build
call .venv_build\Scripts\activate.bat
echo    OK.

REM ===== 2. Instalar dependencias =====
echo [2/5] Instalando dependencias...
python -m pip install --upgrade pip --quiet
pip install -r requirements.txt --quiet
pip install pyinstaller --quiet
echo    OK.

REM ===== 3. Limpar builds anteriores =====
echo [3/5] Limpando builds anteriores...
if exist dist rmdir /s /q dist
if exist build rmdir /s /q build
if exist "%DIST_FOLDER%" rmdir /s /q "%DIST_FOLDER%"
echo    OK.

REM ===== 4. Build com PyInstaller =====
echo [4/5] Compilando executavel (--onedir)...
echo    Isso pode demorar alguns minutos...
echo.

pyinstaller ^
    --noconfirm ^
    --clean ^
    --onedir ^
    --console ^
    --name "%APP_NAME%" ^
    "%ENTRY%"

if %errorlevel% neq 0 (
    echo.
    echo    ERRO: PyInstaller falhou!
    goto :end
)
echo.
echo    Build OK.

REM ===== 5. Montar pasta de distribuicao =====
echo [5/5] Montando pacote de distribuicao...

mkdir "%DIST_FOLDER%"

REM Copiar binarios
xcopy /e /i /y "dist\%APP_NAME%\*" "%DIST_FOLDER%\" >nul

REM Copiar scripts de deploy
copy /y "deploy\install.bat" "%DIST_FOLDER%\" >nul
copy /y "deploy\install.ps1" "%DIST_FOLDER%\" >nul
copy /y "deploy\uninstall.bat" "%DIST_FOLDER%\" >nul
copy /y "deploy\update.bat" "%DIST_FOLDER%\" >nul
copy /y "deploy\task.template.xml" "%DIST_FOLDER%\" >nul
copy /y "deploy\config.template.env" "%DIST_FOLDER%\" >nul

REM Empacotar ODBC Driver 17 MSI
if exist "msodbcsql.msi" (
    mkdir "%DIST_FOLDER%\extra" 2>nul
    copy /y "msodbcsql.msi" "%DIST_FOLDER%\extra\" >nul
    echo    ODBC Driver 17 MSI empacotado em extra\
) else (
    echo    AVISO: msodbcsql.msi nao encontrado na raiz do projeto!
    echo    Coloque o arquivo na raiz para empacotar.
)

echo    OK.

REM ===== Resumo =====
echo.
echo ============================================================
echo   BUILD CONCLUIDO COM SUCESSO!
echo ============================================================
echo.
echo   Pasta pronta para distribuicao:
echo     %CD%\%DIST_FOLDER%\
echo.
echo   Conteudo:
echo     %DIST_FOLDER%\
echo       pdv-sync-agent.exe
echo       _internal\           (bibliotecas)
echo       install.bat          (launcher)
echo       install.ps1          (instalador PowerShell v2.0)
echo       uninstall.bat        (desinstalador)
echo       update.bat           (atualizador com rollback)
echo       task.template.xml    (template do agendador)
echo       config.template.env  (template de configuracao)
echo       extra\
echo         msodbcsql.msi      (ODBC Driver 17)
echo.
echo   Proximo passo:
echo     1. Compacte a pasta %DIST_FOLDER% em um ZIP
echo     2. Copie para o PC da loja
echo     3. Extraia e execute install.bat como Admin
echo.

:end
call deactivate 2>nul
endlocal
pause

