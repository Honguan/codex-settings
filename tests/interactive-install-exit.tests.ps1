$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$installerSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\install.ps1') -Raw
$runnerSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\installation\installation-runner.ps1') -Raw
$installCommand = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Install.cmd') -Raw
$buildSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tools\build-installer.ps1') -Raw
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

function Read-Host([string]$Prompt) { return '' }
try {
    if ((Select-Mode) -ne 'Global') { throw '主選單直接按 Enter 未預設選擇全域安裝。' }
} finally {
    Remove-Item -LiteralPath Function:\Read-Host -ErrorAction SilentlyContinue
}

$globalPattern = '(?ms)Invoke-Installer -Mode Global .*?\r?\n\s*return\s*\r?\n'
if ($runnerSource -notmatch $globalPattern -or $installerSource -notmatch 'Invoke-Installer @installerParameters') {
    throw '互動式全域安裝成功後未直接結束安裝器。'
}

$pausePattern = '(?im)^\s*(?:if\s+"%~1"==""\s+)?pause\s*$'
if ($installCommand -match $pausePattern) {
    throw 'Install.cmd 仍包含按鍵等待。'
}
if ($buildSource -match $pausePattern) {
    throw '單檔安裝器仍包含按鍵等待。'
}
if ($installCommand -notmatch 'src\\install\.ps1' -or $installCommand -match 'src\\installer\.ps1') {
    throw 'Install.cmd 未使用重新命名後的安裝入口。'
}
if ($buildSource -notmatch 'src\\install\.ps1' -or $buildSource -match 'src\\installer\.ps1') {
    throw '單檔安裝器未使用重新命名後的安裝入口。'
}

Write-Host 'Interactive installation exit tests passed.'
