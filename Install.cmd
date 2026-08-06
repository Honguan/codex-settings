@echo off
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell 7 or later is required.
    echo Download: https://aka.ms/powershell-release?tag=stable
    if "%~1"=="" pause
    exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\installer.ps1" %*

set EXIT_CODE=%errorlevel%
echo.
exit /b %EXIT_CODE%
