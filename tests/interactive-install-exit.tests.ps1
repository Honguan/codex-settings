$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$installerSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\installer.ps1') -Raw
$installCommand = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Install.cmd') -Raw
$buildSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tools\build-installer.ps1') -Raw

$globalPattern = '(?ms)''Global''\s*\{.*?& \$PSCommandPath -Mode Global .*?\r?\n\s*exit 0\s*\r?\n\s*\}'
if ($installerSource -notmatch $globalPattern) {
    throw '互動式全域安裝成功後未以 exit 0 明確結束安裝器。'
}

$pausePattern = '(?im)^\s*(?:if\s+"%~1"==""\s+)?pause\s*$'
if ($installCommand -match $pausePattern) {
    throw 'Install.cmd 仍包含按鍵等待。'
}
if ($buildSource -match $pausePattern) {
    throw '單檔安裝器仍包含按鍵等待。'
}

Write-Host 'Interactive installation exit tests passed.'
