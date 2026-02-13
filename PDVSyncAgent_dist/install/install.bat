@echo off
REM =============================================================================
REM PDV Sync Agent - Installer v3.0 (Launcher)
REM =============================================================================
REM Este script apenas lanca o instalador PowerShell.
REM Toda a logica esta em install.ps1.
REM =============================================================================

REM Elevacao automatica para Admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permissao de Administrador...
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

echo.
echo Iniciando instalador PowerShell...
echo.

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0install.ps1"

pause
