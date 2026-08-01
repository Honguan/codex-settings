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

function Get-Context7BackupState {
    $value = [Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User')
    return [pscustomobject]@{
        WasPresent = -not [string]::IsNullOrWhiteSpace($value)
        ProtectedValue = if ([string]::IsNullOrWhiteSpace($value)) { $null } else { Protect-LocalSecret -Value $value }
    }
}

function Uninstall-ManagedTarget {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$TargetLabel,
        [switch]$ForceRemoval,
        [switch]$UnregisterProject
    )

    $manifestPath = Join-Path $TargetRoot '.codex-settings-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    New-Item -ItemType Directory -Path $BackupBase -Force | Out-Null
    $backupRoot = Join-Path $BackupBase ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-uninstall-$TargetLabel")
    $transaction = New-FileTransaction -Root $backupRoot -Mode "Uninstall-$TargetLabel"
    $ccusageBefore = $null
    $context7Before = $null
    $externalResults = [ordered]@{}

    if ($manifest.PSObject.Properties.Name -contains 'External' -and $null -ne $manifest.External) {
        if ($null -ne $manifest.External.Ccusage -and [bool]$manifest.External.Ccusage.Managed) {
            $ccusageBefore = Get-CcusageState
        }
        if ($null -ne $manifest.External.Context7 -and [bool]$manifest.External.Context7.CreatedByInstaller) {
            $context7Before = Get-Context7BackupState
        }
    }

    Save-TransactionMetadata -Transaction $transaction -Metadata @{
        Mode = 'Uninstall'
        Status = 'InProgress'
        TargetRoot = $TargetRoot
        CcusageBefore = $ccusageBefore
        Context7Before = $context7Before
    }

    $removedCount = 0
    $updatedCount = 0
    $skippedCount = 0
    $remainingEntries = New-Object 'System.Collections.Generic.List[object]'

    try {
        Save-TransactionFile -Transaction $transaction -Path $manifestPath
        $registryPath = $null
        if ($UnregisterProject) {
            $registryPath = Get-CodexProjectRegistryPath
            Save-TransactionFile -Transaction $transaction -Path $registryPath
        }

        foreach ($entry in @($manifest.Files)) {
            $relativePath = [string]$entry.Path
            $managedPath = Join-Path $TargetRoot $relativePath
            if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf)) { continue }

            Save-TransactionFile -Transaction $transaction -Path $managedPath
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

        if ($manifest.PSObject.Properties.Name -contains 'External' -and $null -ne $manifest.External) {
            if ($null -ne $manifest.External.PowerShellProfile) {
                $profilePath = [string]$manifest.External.PowerShellProfile.Path
                Save-TransactionFile -Transaction $transaction -Path $profilePath
                if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
                    $state = Get-TextFileState -Path $profilePath
                    $newContent = Remove-CcusageProfileBlocks -Content $state.Content
                    $profileExistedBefore = if ($manifest.External.PowerShellProfile.PSObject.Properties.Name -contains 'ExistedBefore') {
                        [bool]$manifest.External.PowerShellProfile.ExistedBefore
                    } else { $true }
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

        if ($remainingEntries.Count -eq 0) {
            Remove-Item -LiteralPath $manifestPath -Force
        } else {
            $manifest.Files = @($remainingEntries)
            Write-JsonFileAtomic -Path $manifestPath -Value $manifest -Depth 14
        }

        $projectUnregistered = $false
        if ($UnregisterProject -and -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $projectUnregistered = Unregister-CodexProject -Path $TargetRoot
        }

        Complete-FileTransaction -Transaction $transaction
        return [pscustomobject]@{
            Target = $TargetRoot
            Removed = $removedCount
            Updated = $updatedCount
            Skipped = $skippedCount
            Backup = $backupRoot
            External = $externalResults
            ProjectUnregistered = $projectUnregistered
        }
    } catch {
        $reason = $_.Exception.Message
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
        try { Undo-FileTransaction -Transaction $transaction }
        catch { [void]$rollbackErrors.Add("File rollback failed: $($_.Exception.Message)") }
        try { Restore-ExternalTransactionState -Metadata ([pscustomobject]$transaction.Metadata) }
        catch { [void]$rollbackErrors.Add("External rollback failed: $($_.Exception.Message)") }
        try {
            Save-TransactionMetadata -Transaction $transaction -Metadata @{
                Status = 'RolledBack'
                RolledBackAt = (Get-Date).ToString('o')
                FailureReason = $reason
                RollbackErrors = @($rollbackErrors)
            }
        } catch { [void]$rollbackErrors.Add("Journal update failed: $($_.Exception.Message)") }

        $message = "Uninstall failed and rollback was attempted.`nReason: $reason"
        if ($rollbackErrors.Count -gt 0) { $message += "`nRollback errors:`n- " + ($rollbackErrors -join "`n- ") }
        throw $message
    }
}

$operationLock = $null
try {
    $operationLock = Enter-CodexSettingsLock
    New-Item -ItemType Directory -Path $BackupBase -Force | Out-Null
    $recovered = @(Repair-PendingTransactions -BackupRoot $BackupBase)
    foreach ($path in $recovered) { Write-Warning "Recovered interrupted transaction: $path" }

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
            [pscustomobject]@{ Root = Join-Path $HOME '.codex'; Label = 'global'; Unregister = $false },
            [pscustomobject]@{ Root = Join-Path $HOME '.agents\skills'; Label = 'global-skills'; Unregister = $false }
        )
    } else {
        if ([string]::IsNullOrWhiteSpace($ProjectPath)) { $ProjectPath = Read-Host 'Enter the project root' }
        $targets = @([pscustomobject]@{ Root = (Resolve-Path -LiteralPath $ProjectPath).Path; Label = 'project'; Unregister = $true })
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
        $result = Uninstall-ManagedTarget -TargetRoot $target.Root -TargetLabel $target.Label -ForceRemoval:$Force -UnregisterProject:$target.Unregister
        if ($null -ne $result) { $results += $result }
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
        if ($result.ProjectUnregistered) { Write-Host "Unregistered  : $($result.Target)" }
        Write-Host ''
    }
} finally {
    Exit-CodexSettingsLock -Lock $operationLock
}
