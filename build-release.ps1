[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
$packageName = 'CodexSettings-OneClick'
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ("$packageName-" + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stagingRoot $packageName
$archivePath = Join-Path $OutputDirectory "$packageName.zip"
$items = @(
    'Install.cmd', 'install.ps1', 'install-ccusage.ps1', 'backup.ps1', 'restore.ps1', 'update.ps1', 'uninstall.ps1', 'README.md',
    'lib', 'templates'
)

try {
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    foreach ($item in $items) {
        $source = Join-Path $PSScriptRoot $item
        if (-not (Test-Path -LiteralPath $source)) { throw "發佈內容遺失：$item" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $packageRoot $item) -Recurse -Force
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    Compress-Archive -LiteralPath $packageRoot -DestinationPath $archivePath -Force
    Write-Host "已建立一鍵安裝包：$archivePath"
    Write-Host '解壓縮後請只執行 Install.cmd。'
} finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
