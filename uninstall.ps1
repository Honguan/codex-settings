[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Project')]
    [string]$Mode = 'Interactive',

    [string]$ProjectPath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$BackupBase = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'

if ($Mode -eq 'Interactive') {
    Write-Host ''
    Write-Host 'Uninstall Managed Codex Settings'
    Write-Host '================================'
    Write-Host '[1] Global settings'
    Write-Host '[2] Project settings'
    Write-Host '[0] Exit'
    Write-Host ''

    switch (Read-Host 'Select') {
        '1' { $Mode = 'Global' }
        '2' { $Mode = 'Project' }
        '0' { exit 0 }
        default { throw 'Invalid selection.' }
    }
}

if ($Mode -eq 'Global') {
    $targetRoot = Join-Path $HOME '.codex'
} else {
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        $ProjectPath = Read-Host 'Enter the project root'
    }
    $targetRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
}

$manifestPath = Join-Path $targetRoot '.codex-settings-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Managed settings manifest was not found: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if (-not $Force) {
    Write-Host ''
    Write-Host "Target: $targetRoot"
    $confirmation = Read-Host 'Remove settings installed by this package? [y/N]'
    if ($confirmation -notin @('y', 'Y', 'yes', 'YES')) {
        Write-Host 'Uninstall cancelled.'
        exit 0
    }
}

New-Item -ItemType Directory -Path $BackupBase -Force | Out-Null
$backupRoot = Join-Path $BackupBase ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-uninstall')
$backupFilesRoot = Join-Path $backupRoot 'files'
New-Item -ItemType Directory -Path $backupFilesRoot -Force | Out-Null

$removedCount = 0
$skippedCount = 0
$remainingEntries = @()

foreach ($entry in $manifest.Files) {
    $relativePath = [string]$entry.Path
    $managedPath = Join-Path $targetRoot $relativePath

    if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf)) {
        continue
    }

    $backupPath = Join-Path $backupFilesRoot $relativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
    Copy-Item -LiteralPath $managedPath -Destination $backupPath -Force

    $currentHash = (Get-FileHash -LiteralPath $managedPath -Algorithm SHA256).Hash
    $installedHash = [string]$entry.Sha256

    if (-not $Force -and $currentHash -ne $installedHash) {
        Write-Warning "Skipped modified file: $managedPath"
        $remainingEntries += $entry
        $skippedCount++
        continue
    }

    Remove-Item -LiteralPath $managedPath -Force
    $removedCount++
}

$backupMetadata = [pscustomobject]@{
    Version = 1
    CreatedAt = (Get-Date).ToString('o')
    Mode = 'Uninstall'
    TargetRoot = $targetRoot
    FilesRoot = $backupFilesRoot
    BackedUpFiles = $removedCount + $skippedCount
}
$backupMetadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupRoot 'backup-meta.json') -Encoding UTF8

if ($remainingEntries.Count -eq 0) {
    Remove-Item -LiteralPath $manifestPath -Force
} else {
    $manifest.Files = $remainingEntries
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

Write-Host ''
Write-Host "Removed files : $removedCount"
Write-Host "Skipped files : $skippedCount"
Write-Host "Backup        : $backupRoot"
