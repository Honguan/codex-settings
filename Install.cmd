@echo off
setlocal
cd /d "%~dp0"
set "CODEX_SETTINGS_REQUEST_NO_PAUSE="
for %%A in (%*) do if /I "%%~A"=="-NoPause" set "CODEX_SETTINGS_REQUEST_NO_PAUSE=1"

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell 7 or later is required.
    echo Download: https://aka.ms/powershell-release?tag=stable
    set "EXIT_CODE=1"
    goto finish
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\install.ps1" %*

set EXIT_CODE=%errorlevel%

:finish
echo.
if /I not "%CODEX_SETTINGS_NO_PAUSE%"=="1" if not defined CODEX_SETTINGS_REQUEST_NO_PAUSE (
    echo Press any key to close...
    pause >nul
)
exit /b %EXIT_CODE%
