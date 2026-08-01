@echo off
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
)

set EXIT_CODE=%errorlevel%
echo.
pause
exit /b %EXIT_CODE%
