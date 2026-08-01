[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Project')]
    [string]$Mode = 'Interactive',

    [string]$ProjectPath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$BackupBase = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'

function Uninstall-ManagedTarget {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$TargetLabel,
        [switch]$ForceRemoval
    )

    $manifestPath = Join-Path $TargetRoot '.codex-settings-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $null
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    New-Item -ItemType Directory -Path $BackupBase -Force | Out-Null
    $backupName = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-uninstall-$TargetLabel"
    $backupRoot = Join-Path $BackupBase $backupName
    $backupFilesRoot = Join-Path $backupRoot 'files'
    New-Item -ItemType Directory -Path $backupFilesRoot -Force | Out-Null

    $removedCount = 0
    $skippedCount = 0
    $remainingEntries = @()

    foreach ($entry in $manifest.Files) {
        $relativePath = [string]$entry.Path
        $managedPath = Join-Path $TargetRoot $relativePath

        if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf)) {
            continue
        }

        $backupPath = Join-Path $backupFilesRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Copy-Item -LiteralPath $managedPath -Destination $backupPath -Force

        $currentHash = (Get-FileHash -LiteralPath $managedPath -Algorithm SHA256).Hash
        $installedHash = [string]$entry.Sha256

        if (-not $ForceRemoval -and $currentHash -ne $installedHash) {
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
        TargetRoot = $TargetRoot
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

    return [pscustomobject]@{
        Target = $TargetRoot
        Removed = $removedCount
        Skipped = $skippedCount
        Backup = $backupRoot
    }
}

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
    $targets = @(
        [pscustomobject]@{
            Root = Join-Path $HOME '.codex'
            Label = 'global'
        },
        [pscustomobject]@{
            Root = Join-Path $HOME '.agents\skills'
            Label = 'global-skills'
        }
    )
} else {
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        $ProjectPath = Read-Host 'Enter the project root'
    }

    $targets = @(
        [pscustomobject]@{
            Root = (Resolve-Path -LiteralPath $ProjectPath).Path
            Label = 'project'
        }
    )
}

$availableTargets = @(
    $targets | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.Root '.codex-settings-manifest.json') -PathType Leaf
    }
)

if ($availableTargets.Count -eq 0) {
    throw 'No managed settings manifests were found for the selected scope.'
}

if (-not $Force) {
    Write-Host ''
    Write-Host 'Managed targets:'
    foreach ($target in $availableTargets) {
        Write-Host "- $($target.Root)"
    }

    $confirmation = Read-Host 'Remove settings installed by this package? [y/N]'
    if ($confirmation -notin @('y', 'Y', 'yes', 'YES')) {
        Write-Host 'Uninstall cancelled.'
        exit 0
    }
}

$results = @()
foreach ($target in $availableTargets) {
    $result = Uninstall-ManagedTarget `
        -TargetRoot $target.Root `
        -TargetLabel $target.Label `
        -ForceRemoval:$Force

    if ($null -ne $result) {
        $results += $result
    }
}

Write-Host ''
foreach ($result in $results) {
    Write-Host "Target        : $($result.Target)"
    Write-Host "Removed files : $($result.Removed)"
    Write-Host "Skipped files : $($result.Skipped)"
    Write-Host "Backup        : $($result.Backup)"
    Write-Host ''
}
