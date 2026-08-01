[CmdletBinding()]
param(
    [string]$BackupPath,
    [string]$BackupRoot = (Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Copy-DirectoryContent {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        return 0
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $items = Get-ChildItem -LiteralPath $Source -Force
    foreach ($item in $items) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force
    }

    return $items.Count
}

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $candidates = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
    if ($candidates.Count -eq 0) {
        throw "No backups were found under: $BackupRoot"
    }

    Write-Host ''
    Write-Host 'Available backups'
    Write-Host '================='
    for ($index = 0; $index -lt $candidates.Count; $index++) {
        Write-Host ("[{0}] {1}" -f ($index + 1), $candidates[$index].FullName)
    }
    Write-Host '[0] Exit'
    Write-Host ''

    $selection = [int](Read-Host 'Select')
    if ($selection -eq 0) {
        exit 0
    }
    if ($selection -lt 1 -or $selection -gt $candidates.Count) {
        throw 'Invalid selection.'
    }

    $BackupPath = $candidates[$selection - 1].FullName
}

$BackupPath = (Resolve-Path -LiteralPath $BackupPath).Path
$metadataPath = Join-Path $BackupPath 'backup-meta.json'
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "Backup metadata is missing: $metadataPath"
}

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json

if (-not $Force) {
    Write-Host ''
    Write-Host "Backup : $BackupPath"
    Write-Host "Created: $($metadata.CreatedAt)"
    Write-Host "Mode   : $($metadata.Mode)"
    $confirmation = Read-Host 'Restore this backup? [y/N]'
    if ($confirmation -notin @('y', 'Y', 'yes', 'YES')) {
        Write-Host 'Restore cancelled.'
        exit 0
    }
}

$restoredCount = 0

if ($metadata.PSObject.Properties.Name -contains 'FilesRoot') {
    $filesRoot = [string]$metadata.FilesRoot
    $targetRoot = [string]$metadata.TargetRoot
    $restoredCount += Copy-DirectoryContent -Source $filesRoot -Destination $targetRoot
} else {
    $globalCodex = Join-Path $BackupPath 'global\.codex'
    $globalAgents = Join-Path $BackupPath 'global\.agents'
    $project = Join-Path $BackupPath 'project'

    $restoredCount += Copy-DirectoryContent -Source $globalCodex -Destination (Join-Path $HOME '.codex')
    $restoredCount += Copy-DirectoryContent -Source $globalAgents -Destination (Join-Path $HOME '.agents')

    if (Test-Path -LiteralPath $project -PathType Container) {
        $projectRoot = [string]$metadata.ProjectRoot
        if ([string]::IsNullOrWhiteSpace($projectRoot)) {
            throw 'ProjectRoot is missing from backup metadata.'
        }
        $restoredCount += Copy-DirectoryContent -Source $project -Destination $projectRoot
    }
}

Write-Host ''
Write-Host "Restored items : $restoredCount"
Write-Host 'Restart Codex to reload the restored settings.'
