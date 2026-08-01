[CmdletBinding()]
param(
    [string]$BackupPath,
    [string]$BackupRoot = (Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'lib\codex-settings-common.ps1')

function Copy-DirectoryContent {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        return 0
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $items = @(Get-ChildItem -LiteralPath $Source -Force)
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
    if ($selection -eq 0) { exit 0 }
    if ($selection -lt 1 -or $selection -gt $candidates.Count) { throw 'Invalid selection.' }
    $BackupPath = $candidates[$selection - 1].FullName
}

$BackupPath = (Resolve-Path -LiteralPath $BackupPath).Path
$metadataPath = Join-Path $BackupPath 'backup-meta.json'
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "Backup metadata is missing: $metadataPath"
}
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop

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
$warnings = New-Object 'System.Collections.Generic.List[string]'

if ($metadata.PSObject.Properties.Name -contains 'Files' -and $null -ne $metadata.Files) {
    foreach ($entry in @($metadata.Files)) {
        $targetPath = [string]$entry.Path
        if ([bool]$entry.Existed) {
            $backupFile = [string]$entry.BackupPath
            if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) {
                throw "Transaction backup file is missing: $backupFile"
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force | Out-Null
            Copy-Item -LiteralPath $backupFile -Destination $targetPath -Force
            $restoredCount++
        } else {
            Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($metadata.PSObject.Properties.Name -contains 'CcusageBefore' -and $null -ne $metadata.CcusageBefore) {
        Restore-CcusageState -State $metadata.CcusageBefore
    }

    if ($metadata.PSObject.Properties.Name -contains 'Context7KeyCreatedNow' -and [bool]$metadata.Context7KeyCreatedNow -and
        -not [bool]$metadata.Context7KeyWasPresent) {
        [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'User')
        [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'Process')
    } elseif ($metadata.PSObject.Properties.Name -contains 'Context7KeyWasPresent' -and [bool]$metadata.Context7KeyWasPresent -and
        [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))) {
        [void]$warnings.Add('This transaction backup detected a Context7 key, but the secret was not copied. Set CONTEXT7_API_KEY again manually.')
    }
} elseif ($metadata.PSObject.Properties.Name -contains 'FilesRoot') {
    $restoredCount += Copy-DirectoryContent -Source ([string]$metadata.FilesRoot) -Destination ([string]$metadata.TargetRoot)
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

if ($metadata.PSObject.Properties.Name -contains 'Global' -and $null -ne $metadata.Global) {
    $profileMetadata = $metadata.Global.PowerShellProfile
    if ($null -ne $profileMetadata) {
        $profilePath = [string]$profileMetadata.Path
        if ([bool]$profileMetadata.Existed) {
            $profileBackup = Join-Path $BackupPath ([string]$profileMetadata.BackupRelativePath)
            if (-not (Test-Path -LiteralPath $profileBackup -PathType Leaf)) {
                throw "PowerShell profile backup is missing: $profileBackup"
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
            Copy-Item -LiteralPath $profileBackup -Destination $profilePath -Force
            $restoredCount++
        } else {
            Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($null -ne $metadata.Global.Ccusage) {
        Restore-CcusageState -State $metadata.Global.Ccusage
    }

    if ($null -ne $metadata.Global.Context7 -and [bool]$metadata.Global.Context7.KeyPresent -and
        [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))) {
        [void]$warnings.Add('The backup had a Context7 key, but secrets are not backed up. Set CONTEXT7_API_KEY again manually.')
    }
}

Write-Host ''
Write-Host "Restored items : $restoredCount"
foreach ($warning in $warnings) {
    Write-Warning $warning
}
Write-Host 'Restart PowerShell and Codex to reload the restored settings.'
