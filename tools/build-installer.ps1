[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')]
    [string]$Version,

    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexSettings-Setup-' + [guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $stagingRoot 'payload'
$archivePath = Join-Path $stagingRoot 'payload.zip'
$installerPath = Join-Path $OutputDirectory "CodexSettings-Setup-$Version.cmd"

$header = @'
@echo off
setlocal
set "CODEX_SETTINGS_SETUP=%~f0"
set "CODEX_SETTINGS_TEMP=%TEMP%\CodexSettings-Setup-%RANDOM%-%RANDOM%"

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell 7 or later is required.
    echo Download: https://aka.ms/powershell-release?tag=stable
    exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command "$text=[IO.File]::ReadAllText($env:CODEX_SETTINGS_SETUP);$marker=':'+('__CODEX_SETTINGS_PAYLOAD__');$index=$text.LastIndexOf($marker);if($index-lt 0){throw 'Installer payload marker was not found.'};$payload=$text.Substring($index+$marker.Length).Trim();New-Item -ItemType Directory -Path $env:CODEX_SETTINGS_TEMP -Force|Out-Null;$zip=Join-Path $env:CODEX_SETTINGS_TEMP 'payload.zip';[IO.File]::WriteAllBytes($zip,[Convert]::FromBase64String($payload));Expand-Archive -LiteralPath $zip -DestinationPath $env:CODEX_SETTINGS_TEMP -Force"
if errorlevel 1 (
    set "CODEX_SETTINGS_EXIT=1"
    goto cleanup
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%CODEX_SETTINGS_TEMP%\src\install.ps1" %*
set "CODEX_SETTINGS_EXIT=%ERRORLEVEL%"

:cleanup
pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command "if(Test-Path -LiteralPath $env:CODEX_SETTINGS_TEMP){Remove-Item -LiteralPath $env:CODEX_SETTINGS_TEMP -Recurse -Force}" >nul 2>nul
echo.
exit /b %CODEX_SETTINGS_EXIT%

:__CODEX_SETTINGS_PAYLOAD__
'@

try {
    New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src') -Destination (Join-Path $payloadRoot 'src') -Recurse -Force
    Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $archivePath -CompressionLevel Optimal

    $base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($archivePath))
    $lines = for ($index = 0; $index -lt $base64.Length; $index += 120) {
        $length = [Math]::Min(120, $base64.Length - $index)
        $base64.Substring($index, $length)
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $OutputDirectory -Filter 'CodexSettings-Setup-v*.cmd' -File | Where-Object {
        $_.FullName -ne $installerPath
    } | Remove-Item -Force
    [IO.File]::WriteAllText($installerPath, $header + ($lines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
    Write-Host "已建立單檔安裝器：$installerPath"
    Write-Host "檔案大小：$((Get-Item -LiteralPath $installerPath).Length) bytes"
} finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
