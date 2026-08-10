[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global')]
    [string]$Mode = 'Interactive',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRoot = Split-Path -Parent $ScriptRoot
$BackupBase = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'
. (Join-Path $SourceRoot 'load-operations.ps1')

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
        [switch]$ForceRemoval
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
    $ownsWindowsNotifications = $null -ne $manifest.Community -and $null -ne $manifest.Community.windowsUsageNotifications -and ([bool]$manifest.Community.windowsUsageNotifications.Selected -or [bool]$manifest.Community.windowsUsageNotifications.managedByInstaller)
    $ownsLongRunningAsyncWait = $null -ne $manifest.OtherSettings -and $null -ne $manifest.OtherSettings.longRunningAsyncWait -and [bool]$manifest.OtherSettings.longRunningAsyncWait.managedBlockPresent
    $notificationFingerprints = if ($ownsWindowsNotifications) { @(Get-ManifestManagedHookFingerprints -Manifest $manifest -Kind Notification) } else { @() }

    try {
        Save-TransactionFile -Transaction $transaction -Path $manifestPath
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
                    $newContent = Remove-ManagedLineEndingHooksJson -Content $state.Content
                    if ($ownsWindowsNotifications) { $newContent = Remove-ManagedNotificationHooksJson -Content $newContent -ManagedHookFingerprints $notificationFingerprints }
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
                        Write-Warning "已略過無效的 Hook 檔案：$managedPath - $($_.Exception.Message)"
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
                Write-Warning "已略過使用者修改過的檔案：$managedPath"
                [void]$remainingEntries.Add($entry)
                $skippedCount++
                continue
            }

            Remove-Item -LiteralPath $managedPath -Force
            $removedCount++
        }

        if ($ownsLongRunningAsyncWait) {
            $agentsPath = Join-Path $TargetRoot 'AGENTS.md'
            if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
                $state = Get-TextFileState -Path $agentsPath
                $template = Get-LongRunningAsyncWaitPolicyTemplate -SourceRoot $SourceRoot
                $newContent = Set-LongRunningAsyncWaitPolicy -Content $state.Content -ManagedContent $template -Action Remove -NewLine $state.NewLine
                if ($newContent -ne $state.Content) {
                    Save-TransactionFile -Transaction $transaction -Path $agentsPath
                    if ([string]::IsNullOrWhiteSpace($newContent)) { Remove-Item -LiteralPath $agentsPath -Force; $removedCount++ }
                    else { Write-TextFileState -Path $agentsPath -Content ($newContent.TrimEnd() + $state.NewLine) -Encoding $state.Encoding; $updatedCount++ }
                }
            }
        }

        if ($ownsWindowsNotifications) {
            $configPath = Join-Path $TargetRoot 'config.toml'
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                $state = Get-TextFileState -Path $configPath
                $newContent = Remove-WindowsNotificationCommandConfig -Content $state.Content
                if ($newContent -ne $state.Content) {
                    Save-TransactionFile -Transaction $transaction -Path $configPath
                    if ([string]::IsNullOrWhiteSpace($newContent)) { Remove-Item -LiteralPath $configPath -Force; $removedCount++ }
                    else { Write-TextFileState -Path $configPath -Content ($newContent.TrimEnd() + $state.NewLine) -Encoding $state.Encoding; $updatedCount++ }
                }
            }
            foreach ($relativePath in @($manifest.Community.windowsUsageNotifications.ManagedPaths)) {
                $managedPath = Join-Path $TargetRoot ([string]$relativePath)
                if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf)) { continue }
                Save-TransactionFile -Transaction $transaction -Path $managedPath
                Remove-Item -LiteralPath $managedPath -Force
                $removedCount++
            }
        }

        if ($manifest.PSObject.Properties.Name -contains 'External' -and $null -ne $manifest.External) {
            $profileEntries = if ($manifest.External.PSObject.Properties.Name -contains 'PowerShellProfiles') {
                @($manifest.External.PowerShellProfiles)
            } elseif ($null -ne $manifest.External.PowerShellProfile) {
                @($manifest.External.PowerShellProfile)
            } else { @() }
            $profileChanged = 0
            foreach ($profile in $profileEntries) {
                $profilePath = [string]$profile.Path
                if ([string]::IsNullOrWhiteSpace($profilePath)) { continue }
                Save-TransactionFile -Transaction $transaction -Path $profilePath
                if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
                    $state = Get-TextFileState -Path $profilePath
                    $newContent = Remove-CcusageProfileBlocks -Content $state.Content
                    $profileExistedBefore = if ($profile.PSObject.Properties.Name -contains 'ExistedBefore') {
                        [bool]$profile.ExistedBefore
                    } else { $true }
                    if ([string]::IsNullOrWhiteSpace($newContent) -and -not $profileExistedBefore) {
                        Remove-Item -LiteralPath $profilePath -Force
                    } else {
                        if (-not [string]::IsNullOrWhiteSpace($newContent)) { $newContent = $newContent.TrimEnd() + $state.NewLine }
                        Write-TextFileState -Path $profilePath -Content $newContent -Encoding $state.Encoding
                    }
                    $profileChanged++
                }
            }
            if ($profileChanged -gt 0) { $externalResults.PowerShellProfiles = "removed managed ccsessions/cdaily blocks from $profileChanged profile(s)" }

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
            $manifest.Files = $remainingEntries.ToArray()
            Write-JsonFileAtomic -Path $manifestPath -Value $manifest -Depth 14
        }

        Complete-FileTransaction -Transaction $transaction
        return [pscustomobject]@{
            Target = $TargetRoot
            Removed = $removedCount
            Updated = $updatedCount
            Skipped = $skippedCount
            Backup = $backupRoot
            External = $externalResults
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
                RollbackErrors = $rollbackErrors.ToArray()
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
    if ($recovered.Count -gt 0) { Write-Host "已自動回復上次中斷的交易：$($recovered.Count) 筆。" }

    if ($Mode -eq 'Interactive') {
        Write-Host ''
        Write-Host '移除受管理的 Codex 設定'
        Write-Host '========================'
        Write-Host '[1] 全域設定、ccsessions、cdaily 與受管理的 ccusage 狀態'
        Write-Host '[0] 結束'
        Write-Host ''
        switch (Read-Host '請選擇') {
            '1' { $Mode = 'Global' }
            '0' { exit 0 }
            default { throw '選項無效。' }
        }
    }

    $targets = @(
        [pscustomobject]@{ Root = Join-Path $HOME '.codex'; Label = 'global' },
        [pscustomobject]@{ Root = Join-Path $HOME '.codex\skills'; Label = 'global-skills' }
    )

    $availableTargets = @($targets | Where-Object { Test-Path -LiteralPath (Join-Path $_.Root '.codex-settings-manifest.json') -PathType Leaf })
    if ($availableTargets.Count -eq 0) { throw '所選範圍找不到受管理設定的資訊檔。' }

    if (-not $Force) {
        Write-Host ''
        Write-Host '受管理目標：'
        foreach ($target in $availableTargets) { Write-Host "- $($target.Root)" }
        $confirmation = Read-Host '要移除此安裝包設定的內容嗎？[y/N]'
        if ($confirmation -notin @('y', 'Y', 'yes', 'YES')) {
            Write-Host '已取消移除。'
            exit 0
        }
    }

    $results = @()
    foreach ($target in $availableTargets) {
        $result = Uninstall-ManagedTarget -TargetRoot $target.Root -TargetLabel $target.Label -ForceRemoval:$Force
        if ($null -ne $result) { $results += $result }
    }

    Write-Host ''
    foreach ($result in $results) {
        Write-Host "目標：$($result.Target)"
        Write-Host "已移除檔案：$($result.Removed)"
        Write-Host "已更新檔案：$($result.Updated)"
        Write-Host "已略過檔案：$($result.Skipped)"
        Write-Host "備份：$($result.Backup)"
        if ($result.External.Count -gt 0) {
            foreach ($key in $result.External.Keys) { Write-Host ("{0,-14}: {1}" -f $key, $result.External[$key]) }
        }
        Write-Host ''
    }
} finally {
    Exit-CodexSettingsLock -Lock $operationLock
}
