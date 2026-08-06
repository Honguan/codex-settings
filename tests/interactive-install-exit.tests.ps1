$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$installerSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\installer.ps1') -Raw
$installCommand = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Install.cmd') -Raw
$buildSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tools\build-installer.ps1') -Raw

$globalPattern = '(?ms)''Global''\s*\{.*?& \$PSCommandPath -Mode Global .*?\r?\n\s*return\s*\r?\n\s*\}'
if ($installerSource -notmatch $globalPattern) {
    throw '互動式全域安裝成功後不會直接結束安裝器。'
}

$pausePattern = '(?ms)echo\.\s*\r?\n\s*if "%~1"=="" pause\s*\r?\n\s*exit /b'
if ($installCommand -match $pausePattern) {
    throw 'Install.cmd 完成後仍會等待按鍵。'
}
if ($buildSource -match $pausePattern) {
    throw '單檔安裝器完成後仍會等待按鍵。'
}

Write-Host 'Interactive installation exit tests passed.'
