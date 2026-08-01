[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Project')]
    [string]$Mode = 'Interactive',

    [string]$ProjectPath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupBase = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'
. (Join-Path $ScriptRoot 'lib\codex-settings-common.ps1')
. (Join-Path $ScriptRoot 'lib\project-registry.ps1')

function Backup-UninstallFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$BackupFilesRoot
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $relative = $Path.Substring($TargetRoot.Length).TrimStart([char[]]'\/')
    $backupPath = Join-Path $BackupFilesRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
}

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

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    New-Item -ItemType Directory -Path $BackupBase -Force | Out-Null
    $backupRoot = Join-Path $BackupBase ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-uninstall-$TargetLabel")
    $backupFilesRoot = Join-Path $backupRoot 'files'
    New-Item -ItemType Directory -Path $backupFilesRoot -Force | Out-Null

    $removedCount = 0
    $updatedCount = 0
    $skippedCount = 0
    $remainingEntries = New-Object 'System.Collections.Generic.List[object]'

    foreach ($entry in @($manifest.Files)) {
        $relativePath = [string]$entry.Path
        $managedPath = Join-Path $TargetRoot $relativePath
        if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf)) {
            continue
        }

        Backup-UninstallFile -Path $managedPath -TargetRoot $TargetRoot -BackupFilesRoot $backupFilesRoot
        $strategy = if ($entry.PSObject.Properties.Name -contains 'Strategy') { [string]$entry.Strategy } else { 'replace' }

        if ($strategy -in @('managed-block', 'managed-toml')) {
            $state = Get-TextFileState -Path $managedPath
            $newContent = Remove-ManagedBlock -Content $state.Content -StartMarker ([string]$entry.StartMarker) -EndMarker ([string]$entry.EndMarker)
            $existedBefore = if ($entry.PSObject.Properties.Name -contains 'ExistedBefore') { [bool]$entry.ExistedBefore } else { $true }

            if ([string]::IsNullOrWhiteSpace($newContent) -and -not $existedBefore) {
                Remove-Item -LiteralPath $managedPath -Force
                $removedCount++
            } else {
                if (-not [string]::IsNullOrWhiteSpace($newContent)) { $newContent = $newContent.TrimEnd() + $state.NewLine }
                Write-TextFileState -Path $managedPath -Content $newContent -Encoding $state.Encoding
                $updatedCount++
            }
            continue
        }

        if ($strategy -eq 'managed-hooks') {
            $state = Get-TextFileState -Path $managedPath
            try {
                $newContent = Remove-ManagedHooksJson -Content $state.Content
                $object = if ([string]::IsNullOrWhiteSpace($newContent)) { $null } else { $newContent | ConvertFrom-Json }
                $hookCount = 0
                if ($null -ne $object -and $null -ne $object.hooks) {
                    foreach ($property in @($object.hooks.PSObject.Properties)) { $hookCount += @($property.Value).Count }
                }
                $existedBefore = if ($entry.PSObject.Properties.Name -contains 'ExistedBefore') { [bool]$entry.ExistedBefore } else { $true }
                if ($hookCount -eq 0 -and -not $existedBefore) {
                    Remove-Item -LiteralPath $managedPath -Force
                    $removedCount++
                } else {
                    Write-TextFileState -Path $managedPath -Content ($newContent.TrimEnd() + $state.NewLine) -Encoding $state.Encoding
                    $updatedCount++
                }
            } catch {
                if (-not $ForceRemoval) {
                    Write-Warning "Skipped invalid hooks file: $managedPath - $($_.Exception.Message)"
                    [void]$remainingEntries.Add($entry)
                    $skippedCount++
                    continue
                }
                Remove-Item -LiteralPath $managedPath -Force
                $removedCount++
            }
            continue
        }

        $currentHash = (Get-FileHash -LiteralPath $managedPath -Algorithm SHA256).Hash
        $installedHash = [string]$entry.Sha256
        if (-not $ForceRemoval -and $currentHash -ne $installedHash) {
            Write-Warning "Skipped modified file: $managedPath"
            [void]$remainingEntries.Add($entry)
            $skippedCount++
            continue
        }

        Remove-Item -LiteralPath $managedPath -Force
        $removedCount++
    }

    $externalResults = [ordered]@{}
    if ($manifest.PSObject.Properties.Name -contains 'External' -and $null -ne $manifest.External) {
        if ($null -ne $manifest.External.PowerShellProfile) {
            $profileInfo = $manifest.External.PowerShellProfile
            $profilePath = [string]$profileInfo.Path
            if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
                $profileBackupRoot = Join-Path $backupRoot 'external\powershell'
                New-Item -ItemType Directory -Path $profileBackupRoot -Force | Out-Null
                Copy-Item -LiteralPath $profilePath -Destination (Join-Path $profileBackupRoot 'profile.ps1') -Force

                $state = Get-TextFileState -Path $profilePath
                $newContent = Remove-CcusageProfileBlocks -Content $state.Content
                $profileExistedBefore = if ($profileInfo.PSObject.Properties.Name -contains 'ExistedBefore') { [bool]$profileInfo.ExistedBefore } else { $true }
                if ([string]::IsNullOrWhiteSpace($newContent) -and -not $profileExistedBefore) {
                    Remove-Item -LiteralPath $profilePath -Force
                } else {
                    if (-not [string]::IsNullOrWhiteSpace($newContent)) { $newContent = $newContent.TrimEnd() + $state.NewLine }
                    Write-TextFileState -Path $profilePath -Content $newContent -Encoding $state.Encoding
                }
                $externalResults.PowerShellProfile = 'removed managed cs/cdaily blocks'
            }
        }

        if ($null -ne $manifest.External.Ccusage -and [bool]$manifest.External.Ccusage.Managed) {
            $originalState = [pscustomobject]@{
                Installed = [bool]$manifest.External.Ccusage.WasInstalledBefore
                Version = [string]$manifest.External.Ccusage.PreviousVersion
            }
            Restore-CcusageState -State $originalState
            $externalResults.Ccusage = if ($originalState.Installed) { "restored $($originalState.Version)" } else { 'uninstalled' }
        }

        if ($null -ne $manifest.External.Context7 -and [bool]$manifest.External.Context7.CreatedByInstaller) {
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'User')
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'Process')
            $externalResults.Context7 = 'removed installer-created user environment variable'
        }
    }

    $backupMetadata = [ordered]@{
        Version = 2
        CreatedAt = (Get-Date).ToString('o')
        Mode = 'Uninstall'
        TargetRoot = $TargetRoot
        FilesRoot = $backupFilesRoot
        RemovedFiles = $removedCount
        UpdatedFiles = $updatedCount
        SkippedFiles = $skippedCount
        External = $externalResults
    }
    $backupMetadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $backupRoot 'backup-meta.json') -Encoding UTF8

    if ($remainingEntries.Count -eq 0) {
        Remove-Item -LiteralPath $manifestPath -Force
    } else {
        $manifest.Files = @($remainingEntries)
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    }

    return [pscustomobject]@{
        Target = $TargetRoot
        Removed = $removedCount
        Updated = $updatedCount
        Skipped = $skippedCount
        Backup = $backupRoot
        External = $externalResults
    }
}

if ($Mode -eq 'Interactive') {
    Write-Host ''
    Write-Host 'Uninstall Managed Codex Settings'
    Write-Host '================================'
    Write-Host '[1] Global settings, cs, cdaily, and managed ccusage state'
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
        [pscustomobject]@{ Root = Join-Path $HOME '.codex'; Label = 'global' },
        [pscustomobject]@{ Root = Join-Path $HOME '.agents\skills'; Label = 'global-skills' }
    )
} else {
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) { $ProjectPath = Read-Host 'Enter the project root' }
    $targets = @([pscustomobject]@{ Root = (Resolve-Path -LiteralPath $ProjectPath).Path; Label = 'project' })
}

$availableTargets = @($targets | Where-Object { Test-Path -LiteralPath (Join-Path $_.Root '.codex-settings-manifest.json') -PathType Leaf })
if ($availableTargets.Count -eq 0) { throw 'No managed settings manifests were found for the selected scope.' }

if (-not $Force) {
    Write-Host ''
    Write-Host 'Managed targets:'
    foreach ($target in $availableTargets) { Write-Host "- $($target.Root)" }
    $confirmation = Read-Host 'Remove settings installed by this package? [y/N]'
    if ($confirmation -notin @('y', 'Y', 'yes', 'YES')) {
        Write-Host 'Uninstall cancelled.'
        exit 0
    }
}

$results = @()
foreach ($target in $availableTargets) {
    $result = Uninstall-ManagedTarget -TargetRoot $target.Root -TargetLabel $target.Label -ForceRemoval:$Force
    if ($null -ne $result) { $results += $result }
}

$projectUnregistered = $false
if ($Mode -eq 'Project' -and -not (Test-Path -LiteralPath (Join-Path $targets[0].Root '.codex-settings-manifest.json') -PathType Leaf)) {
    $registryPath = Get-CodexProjectRegistryPath
    if ((Test-Path -LiteralPath $registryPath -PathType Leaf) -and $results.Count -gt 0) {
        $registryBackup = Join-Path $results[0].Backup 'external\registry\projects.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $registryBackup) -Force | Out-Null
        Copy-Item -LiteralPath $registryPath -Destination $registryBackup -Force
    }
    $projectUnregistered = Unregister-CodexProject -Path $targets[0].Root
}

Write-Host ''
foreach ($result in $results) {
    Write-Host "Target        : $($result.Target)"
    Write-Host "Removed files : $($result.Removed)"
    Write-Host "Updated files : $($result.Updated)"
    Write-Host "Skipped files : $($result.Skipped)"
    Write-Host "Backup        : $($result.Backup)"
    if ($result.External.Count -gt 0) {
        foreach ($key in $result.External.Keys) { Write-Host ("{0,-14}: {1}" -f $key, $result.External[$key]) }
    }
    Write-Host ''
}
if ($projectUnregistered) {
    Write-Host "Unregistered project: $($targets[0].Root)"
}
