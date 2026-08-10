function Remove-GlobalLineEndingHooks([string]$Root, $Transaction) {
    $hooksPath = Join-Path $Root 'hooks.json'
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        $state = Get-TextFileState $hooksPath
        $cleaned = Remove-ManagedLineEndingHooksJson -Content $state.Content
        if ($cleaned -ne $state.Content) {
            Save-TransactionFile -Transaction $Transaction -Path $hooksPath
            Write-TextFileState -Path $hooksPath -Content $cleaned -Encoding $state.Encoding
        }
    }

    foreach ($scriptName in @('crlf-updated-files.ps1', 'normalize-cvs-crlf.ps1', 'preserve-line-endings.ps1')) {
        $scriptPath = Join-Path $Root ("hooks\$scriptName")
        if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
            Save-TransactionFile -Transaction $Transaction -Path $scriptPath
            Remove-Item -LiteralPath $scriptPath -Force
        }
    }
    $hooksRoot = Join-Path $Root 'hooks'
    if ((Test-Path -LiteralPath $hooksRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $hooksRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $hooksRoot -Force
    }
}

function Remove-GlobalLineEndingHookEntries([string]$Root, $Transaction) {
    $hooksPath = Join-Path $Root 'hooks.json'
    if (-not (Test-Path -LiteralPath $hooksPath -PathType Leaf)) { return }
    $state = Get-TextFileState $hooksPath
    $cleaned = Remove-ManagedLineEndingHooksJson -Content $state.Content
    if ($cleaned -ne $state.Content) {
        Save-TransactionFile -Transaction $Transaction -Path $hooksPath
        Write-TextFileState -Path $hooksPath -Content $cleaned -Encoding $state.Encoding
    }
}

function Get-ManagedHookScriptPaths([string]$Content, [string]$Root, [string[]]$ManagedHookFingerprints = @()) {
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($Content)) { return @($paths | ForEach-Object { $_ }) }
    try { $object = $Content | ConvertFrom-Json -ErrorAction Stop } catch { return @($paths | ForEach-Object { $_ }) }
    if ($null -eq $object.hooks) { return @($paths | ForEach-Object { $_ }) }
    $hooksRoot = [IO.Path]::GetFullPath((Join-Path $Root 'hooks')).TrimEnd('\', '/')
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        foreach ($group in @($property.Value)) {
            foreach ($entry in @(Get-HookHandlerEntries -Entry $group)) {
                if (-not (Test-ManagedGlobalHookEntry -Entry $entry -ManagedHookFingerprints $ManagedHookFingerprints)) { continue }
                foreach ($match in [regex]::Matches((Get-HookEntryText -Entry $entry), '(?i)(?<name>[A-Za-z0-9._-]+\.ps1)')) {
                    $candidate = Join-Path $hooksRoot $match.Groups['name'].Value
                    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
                    $fullCandidate = [IO.Path]::GetFullPath($candidate)
                    if ($fullCandidate.StartsWith($hooksRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { [void]$paths.Add($fullCandidate) }
                }
            }
        }
    }
    return @($paths | ForEach-Object { $_ })
}

function Test-ManagedHookScriptFile([string]$Path) {
    try {
        $content = [IO.File]::ReadAllText($Path)
        return $content -match '(?i)(CodexSettings Windows notification|Codex 任務完成|工作已完成|請回到 Codex|turn[-_]?token[-_]?usage|CodexSettings turn token usage)'
    } catch { return $false }
}

function Remove-ManagedHookScripts([string]$Root, $Transaction, [string[]]$ReferencedPaths = @()) {
    $hooksRoot = [IO.Path]::GetFullPath((Join-Path $Root 'hooks')).TrimEnd('\', '/')
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ReferencedPaths)) {
        try {
            $fullPath = [IO.Path]::GetFullPath($path)
            if ($fullPath.StartsWith($hooksRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { [void]$referenced.Add($fullPath); [void]$paths.Add($fullPath) }
        } catch {}
    }
    foreach ($scriptName in @(
        'show-codex-notification.ps1',
        'show-turn-token-usage.ps1',
        'show-codex-toast.ps1',
        'show-turn-token-notification.ps1',
        'notify-codex.ps1',
        'codex-notification.ps1'
    )) {
        $scriptPath = [IO.Path]::GetFullPath((Join-Path $hooksRoot $scriptName))
        if ((Test-Path -LiteralPath $scriptPath -PathType Leaf) -and ($referenced.Contains($scriptPath) -or (Test-ManagedHookScriptFile -Path $scriptPath))) { [void]$paths.Add($scriptPath) }
    }
    $removed = 0
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        Save-TransactionFile -Transaction $Transaction -Path $path
        Remove-Item -LiteralPath $path -Force
        $removed++
    }
    if ((Test-Path -LiteralPath $hooksRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $hooksRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $hooksRoot -Force }
    return $removed
}

function Remove-ManagedGlobalNotificationHooks([string]$Root, $Transaction, [string[]]$ManagedHookFingerprints = @()) {
    $hooksPath = Join-Path $Root 'hooks.json'
    if (-not (Test-Path -LiteralPath $hooksPath -PathType Leaf)) { return }
    $state = Get-TextFileState $hooksPath
    $referencedScripts = @(Get-ManagedHookScriptPaths -Content $state.Content -Root $Root -ManagedHookFingerprints $ManagedHookFingerprints)
    $cleaned = Remove-ManagedGlobalHooksJson -Content $state.Content -ManagedHookFingerprints $ManagedHookFingerprints
    if ($cleaned -ne $state.Content) {
        Save-TransactionFile -Transaction $Transaction -Path $hooksPath
        Write-TextFileState -Path $hooksPath -Content $cleaned -Encoding $state.Encoding
    }
    [void](Remove-ManagedHookScripts -Root $Root -Transaction $Transaction -ReferencedPaths $referencedScripts)
}

function Find-CvsProjectRoot([string]$StartPath) {
    if ([string]::IsNullOrWhiteSpace($StartPath)) { return $null }
    try {
        $current = if (Test-Path -LiteralPath $StartPath -PathType Container) {
            [IO.DirectoryInfo][IO.Path]::GetFullPath($StartPath)
        } else {
            [IO.DirectoryInfo](Split-Path -Parent ([IO.Path]::GetFullPath($StartPath)))
        }
        while ($null -ne $current) {
            if (Test-Path -LiteralPath (Join-Path $current.FullName 'CVS') -PathType Container) { return $current.FullName }
            $current = $current.Parent
        }
    } catch {}
    return $null
}

function Remove-ManagedProjectHooks([string]$StartPath, $Transaction, [switch]$PreserveNotifications, [string[]]$ManagedHookFingerprints = @()) {
    $projectRoot = Find-CvsProjectRoot -StartPath $StartPath
    if ([string]::IsNullOrWhiteSpace($projectRoot)) { return $null }

    $codexRoot = Join-Path $projectRoot '.codex'
    $hooksPath = Join-Path $codexRoot 'hooks.json'
    $changed = $false
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        $state = Get-TextFileState $hooksPath
        $referencedScripts = if ($PreserveNotifications) { @() } else { @(Get-ManagedHookScriptPaths -Content $state.Content -Root $codexRoot -ManagedHookFingerprints $ManagedHookFingerprints) }
        $cleaned = if ($PreserveNotifications) { $state.Content } else { Remove-ManagedGlobalHooksJson -Content $state.Content -ManagedHookFingerprints $ManagedHookFingerprints }
        $cleaned = Remove-ManagedLineEndingHooksJson -Content $cleaned
        if ($cleaned -ne $state.Content) {
            Save-TransactionFile -Transaction $Transaction -Path $hooksPath
            Write-TextFileState -Path $hooksPath -Content $cleaned -Encoding $state.Encoding
            $changed = $true
        }
    }

    $removedScripts = 0
    foreach ($scriptName in @('crlf-updated-files.ps1', 'normalize-cvs-crlf.ps1', 'preserve-line-endings.ps1')) {
        $scriptPath = Join-Path $codexRoot ("hooks\$scriptName")
        if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
            Save-TransactionFile -Transaction $Transaction -Path $scriptPath
            Remove-Item -LiteralPath $scriptPath -Force
            $removedScripts++
            $changed = $true
        }
    }
    $removedNotificationScripts = if ($PreserveNotifications) { 0 } else { Remove-ManagedHookScripts -Root $codexRoot -Transaction $Transaction -ReferencedPaths $referencedScripts }
    if ($removedNotificationScripts -gt 0) { $removedScripts += $removedNotificationScripts; $changed = $true }

    $hooksRoot = Join-Path $codexRoot 'hooks'
    if ((Test-Path -LiteralPath $hooksRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $hooksRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $hooksRoot -Force
    }
    return [pscustomobject]@{ ProjectRoot = $projectRoot; Changed = $changed; RemovedScripts = $removedScripts }
}

function Get-HookConfigurationCounts([string]$HooksPath, [string[]]$NotificationFingerprints = @(), [string[]]$TokenFingerprints = @()) {
    $counts = [ordered]@{
        NotificationPreToolUse = 0
        NotificationPermissionRequest = 0
        NotificationStop = 0
        LegacyNotificationStop = 0
        Token = 0
        LineEndingPreToolUse = 0
        LineEndingPostToolUse = 0
        LineEndingStop = 0
        LegacyCrlf = 0
    }
    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) { return [pscustomobject]$counts }
    $object = Get-Content -LiteralPath $HooksPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return [pscustomobject]$counts }
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        foreach ($group in @($property.Value)) {
            foreach ($entry in @(Get-HookHandlerEntries -Entry $group)) {
                $isNotification = Test-ManagedNotificationHookEntry -Entry $entry -ManagedHookFingerprints $NotificationFingerprints
                $isLegacyNotification = Test-LegacyManagedNotificationHookEntry -Entry $entry
                if ($isNotification) {
                    if ($property.Name -eq 'PreToolUse') { $counts.NotificationPreToolUse++ }
                    if ($property.Name -eq 'PermissionRequest') { $counts.NotificationPermissionRequest++ }
                    if ($property.Name -eq 'Stop') { $counts.NotificationStop++ }
                }
                if ($property.Name -eq 'Stop' -and $isLegacyNotification) { $counts.LegacyNotificationStop++ }
                if (Test-ManagedTokenHookEntry -Entry $entry -ManagedHookFingerprints $TokenFingerprints) { $counts.Token++ }
                if (Test-ManagedLineEndingHookEntry -Entry $entry) {
                    if ($property.Name -eq 'PreToolUse') { $counts.LineEndingPreToolUse++ }
                    if ($property.Name -eq 'PostToolUse') { $counts.LineEndingPostToolUse++ }
                    if ($property.Name -eq 'Stop') { $counts.LineEndingStop++ }
                }
                if ((Get-HookEntryText -Entry $entry) -match $script:LegacyCrlfHookSignaturePattern) { $counts.LegacyCrlf++ }
            }
        }
    }
    return [pscustomobject]$counts
}

function Get-WindowsNotificationLifecycleState([string]$Root, [string[]]$ManagedNotificationFingerprints = @()) {
    $hooksPath = Join-Path $Root 'hooks.json'
    $configPath = Join-Path $Root 'config.toml'
    $configContent = if (Test-Path -LiteralPath $configPath -PathType Leaf) { [IO.File]::ReadAllText($configPath) } else { '' }
    $configState = Get-WindowsNotificationCommandConfigState -Content $configContent -Root $Root
    $manifest = try { Get-Manifest -Root $Root } catch { $null }
    if (@($ManagedNotificationFingerprints).Count -eq 0) { $ManagedNotificationFingerprints = @(Get-ManifestManagedHookFingerprints -Manifest $manifest -Kind Notification) }
    $fingerprintEvidence = @($ManagedNotificationFingerprints).Count -gt 0
    $manifestComponent = if ($null -eq $manifest) { $null } else { $manifest.Community.windowsUsageNotifications }
    $managedManifestPresent = $null -ne $manifestComponent -and [string]$manifestComponent.Owner -eq 'WindowsUsageNotifications' -and ($fingerprintEvidence -or [bool]$manifestComponent.Selected -or [string]$manifestComponent.Status -in @('SUCCESS', 'Installed', 'Updated', 'Current'))
    $managedMarkersPresent = [regex]::Matches($configContent, '(?m)^\s*' + [regex]::Escape($script:WindowsNotificationConfigStartMarker) + '\s*$').Count -gt 0 -or [regex]::Matches($configContent, '(?m)^\s*' + [regex]::Escape($script:WindowsNotificationConfigEndMarker) + '\s*$').Count -gt 0
    $managedMarkerCount = [Math]::Max([regex]::Matches($configContent, '(?m)^\s*' + [regex]::Escape($script:WindowsNotificationConfigStartMarker) + '\s*$').Count, [regex]::Matches($configContent, '(?m)^\s*' + [regex]::Escape($script:WindowsNotificationConfigEndMarker) + '\s*$').Count)
    $scriptPath = Join-Path $Root 'hooks\show-codex-notification.ps1'
    $scriptPresent = Test-Path -LiteralPath $scriptPath -PathType Leaf
    $managedScriptPresent = $scriptPresent -and (Test-ManagedHookScriptFile -Path $scriptPath)
    try { $counts = Get-HookConfigurationCounts -HooksPath $hooksPath -NotificationFingerprints $ManagedNotificationFingerprints } catch {
        return [pscustomobject][ordered]@{ State = 'Unknown'; SchemaVersion = $script:ManagedNotificationVersion; LegacyCompletedStopDetected = $false; ManagedNotifyBlockPresent = $managedMarkersPresent; ManagedNotifyCommandCurrent = $false; ConfigState = $configState; QuestionHookCount = 0; PermissionHookCount = 0; CompletedStopHookCount = 0; NotificationScriptCount = [int]$scriptPresent; ManagedMarkersPresent = $managedMarkersPresent; ManagedManifestPresent = $managedManifestPresent; ManagedFingerprintEvidence = $fingerprintEvidence; NotificationScriptPresent = $scriptPresent; UnmanagedNotifyPresent = $configState -eq 'UnmanagedNotifyConflict'; ManagedNotifyPresent = $false; ExternalNotifyCoexistence = $false; OwnershipClassification = 'Unknown'; ConflictReason = 'hooks.json cannot be parsed safely'; RecommendedAction = 'repair hooks.json syntax before retrying; the installer will not rewrite it' }
    }
    $question = [int]$counts.NotificationPreToolUse
    $permission = [int]$counts.NotificationPermissionRequest
    $completed = [int]$counts.NotificationStop
    $scriptCount = [int]$scriptPresent
    $managedHookCount = $question + $permission + $completed
    $unmarkedConfig = if ($managedMarkersPresent) { Remove-WindowsNotificationCommandConfig -Content $configContent } else { $configContent }
    $unmarkedNotifyPresent = -not [string]::IsNullOrWhiteSpace((Get-WindowsNotificationCommandLine -Content $unmarkedConfig))
    $knownUnmarkedNotify = $unmarkedNotifyPresent -and (Test-KnownWindowsNotificationCommand -Content $unmarkedConfig -Root $Root)
    $managedUnmarkedNotify = $knownUnmarkedNotify -and ($managedManifestPresent -or $fingerprintEvidence -or $managedScriptPresent -or $managedHookCount -gt 0)
    $unmanagedNotifyPresent = ($configState -eq 'UnmanagedNotifyConflict' -or $unmarkedNotifyPresent) -and -not $managedUnmarkedNotify
    $managedArtifactsPresent = $managedManifestPresent -or $fingerprintEvidence -or $managedScriptPresent -or $managedHookCount -gt 0
    $externalNotifyCoexistence = $unmanagedNotifyPresent -and -not $managedMarkersPresent
    $ownership = if ($managedMarkersPresent) { 'ManagedMarkers' } elseif ($managedUnmarkedNotify) { 'ManagedCorroborated' } elseif ($externalNotifyCoexistence -and $managedArtifactsPresent) { 'ManagedWithExternalNotify' } elseif ($externalNotifyCoexistence) { 'ExternalNotify' } elseif ($unmanagedNotifyPresent) { 'Unmanaged' } elseif ($managedArtifactsPresent) { 'ManagedArtifacts' } else { 'None' }
    $state = if ($configState -eq 'MalformedUserContent') {
        'MalformedUserOwnedState'
    } elseif ($unmanagedNotifyPresent -and -not $externalNotifyCoexistence) {
        'TrueUnmanagedConflict'
    } elseif ($managedMarkerCount -gt 1 -or $question -gt 1 -or $permission -gt 1 -or $completed -gt 1) {
        'ManagedDuplicateState'
    } elseif ($configState -eq 'MalformedManagedBlock') {
        'ManagedPartialState'
    } elseif ($managedUnmarkedNotify) {
        'InstalledNeedsMigration'
    } elseif ($externalNotifyCoexistence -and -not $managedArtifactsPresent) {
        'NotInstalled'
    } elseif ($question -eq 0 -and $permission -eq 0 -and $completed -eq 0 -and $scriptCount -eq 0 -and $configState -eq 'MissingManagedBlock') {
        'NotInstalled'
    } elseif ($question -eq 1 -and $permission -eq 1 -and $completed -eq 0 -and $scriptCount -eq 1 -and ($configState -eq 'CurrentManagedBlock' -or $externalNotifyCoexistence)) {
        'InstalledCurrent'
    } elseif ($question -eq 1 -and $permission -eq 1 -and $completed -eq 1 -and $scriptCount -eq 1 -and ($configState -in @('MissingManagedBlock', 'OutdatedManagedBlock') -or $externalNotifyCoexistence)) {
        'InstalledNeedsMigration'
    } elseif ($question -eq 1 -and $permission -eq 1 -and $completed -eq 0 -and $scriptCount -eq 1 -and $configState -eq 'OutdatedManagedBlock') {
        'InstalledUpdateAvailable'
    } elseif ($ownership -ne 'None') {
        'ManagedPartialState'
    } else {
        'InstalledNeedsRepair'
    }
    $conflictReason = switch ($state) {
        'TrueUnmanagedConflict' { 'top-level notify is not owned by Codex Settings' }
        'MalformedUserOwnedState' { 'config.toml contains malformed user-owned content outside managed notification blocks' }
        default { '' }
    }
    $recommendedAction = switch ($state) {
        'TrueUnmanagedConflict' { 'review the existing top-level notify entry; installer will not overwrite it' }
        'MalformedUserOwnedState' { 'repair config.toml syntax before retrying; installer will not rewrite it' }
        default { if ($state -eq 'NotInstalled') { 'install when selected' } elseif ($state -eq 'InstalledCurrent') { 'keep current' } else { 'repair/update the managed notification component' } }
    }
    return [pscustomobject][ordered]@{ State = $state; SchemaVersion = $script:ManagedNotificationVersion; LegacyCompletedStopDetected = $completed -gt 0; ManagedNotifyBlockPresent = $managedMarkersPresent; ManagedNotifyCommandCurrent = $configState -eq 'CurrentManagedBlock'; ConfigState = $configState; QuestionHookCount = $question; PermissionHookCount = $permission; CompletedStopHookCount = $completed; NotificationScriptCount = $scriptCount; ManagedMarkersPresent = $managedMarkersPresent; ManagedManifestPresent = $managedManifestPresent; ManagedFingerprintEvidence = $fingerprintEvidence; NotificationScriptPresent = $scriptPresent; UnmanagedNotifyPresent = $unmanagedNotifyPresent; ManagedNotifyPresent = $configState -in @('CurrentManagedBlock', 'OutdatedManagedBlock') -or $managedUnmarkedNotify; ExternalNotifyCoexistence = $externalNotifyCoexistence; OwnershipClassification = $ownership; ConflictReason = $conflictReason; RecommendedAction = $recommendedAction }
}

function Format-WindowsNotificationLifecycleDiagnostic($Lifecycle) {
    return "notificationLifecycleState=$($Lifecycle.State) notificationConfigState=$($Lifecycle.ConfigState) schemaVersion=$($Lifecycle.SchemaVersion) managedMarkersPresent=$($Lifecycle.ManagedMarkersPresent) managedManifestPresent=$($Lifecycle.ManagedManifestPresent) managedFingerprintEvidence=$($Lifecycle.ManagedFingerprintEvidence) questionHookCount=$($Lifecycle.QuestionHookCount) permissionHookCount=$($Lifecycle.PermissionHookCount) completedStopHookCount=$($Lifecycle.CompletedStopHookCount) notificationScriptPresent=$($Lifecycle.NotificationScriptPresent) unmanagedNotifyPresent=$($Lifecycle.UnmanagedNotifyPresent) managedNotifyPresent=$($Lifecycle.ManagedNotifyPresent) ownershipClassification=$($Lifecycle.OwnershipClassification) conflictReason=$($Lifecycle.ConflictReason) recommendedAction=$($Lifecycle.RecommendedAction)"
}

function Assert-GlobalLineEndingHook([ValidateSet('Git', 'CVS')][string]$DevelopmentEnvironment, [string]$Root, [bool]$InstallWindowsNotifications, [string]$ProjectRoot, [string[]]$ManagedNotificationFingerprints = @(), [string[]]$ManagedTokenFingerprints = @(), [ValidateSet('Final', 'PreCommunity')][string]$ValidationPhase = 'Final', [string]$PlannedNotificationAction = 'LeaveUnchanged') {
    $hooksPath = Join-Path $Root 'hooks.json'
    $configPath = Join-Path $Root 'config.toml'
    $configContent = if (Test-Path -LiteralPath $configPath -PathType Leaf) { [IO.File]::ReadAllText($configPath) } else { '' }
    $notificationCommandConfigured = Test-WindowsNotificationCommandConfig -Content $configContent -Root $Root
    $globalCounts = Get-HookConfigurationCounts -HooksPath $hooksPath -NotificationFingerprints $ManagedNotificationFingerprints -TokenFingerprints $ManagedTokenFingerprints
    $trackHookCount = [int]$globalCounts.LineEndingPreToolUse
    $restoreHookCount = [int]$globalCounts.LineEndingPostToolUse
    $finalizeHookCount = [int]$globalCounts.LineEndingStop
    $legacyHookCount = [int]$globalCounts.LegacyCrlf
    $notificationQuestionHookCount = [int]$globalCounts.NotificationPreToolUse
    $notificationPermissionHookCount = [int]$globalCounts.NotificationPermissionRequest
    $notificationCompletedHookCount = [int]$globalCounts.NotificationStop
    $preserveScriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\preserve-line-endings.ps1') -PathType Leaf) { 1 } else { 0 }
    $notificationScriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\show-codex-notification.ps1') -PathType Leaf) { 1 } else { 0 }
    $expectedNotificationCount = if ($InstallWindowsNotifications) { 1 } else { 0 }
    $notificationLifecycle = Get-WindowsNotificationLifecycleState -Root $Root -ManagedNotificationFingerprints $ManagedNotificationFingerprints
    $completionNotificationConfigured = $notificationCommandConfigured -or [bool]$notificationLifecycle.ExternalNotifyCoexistence
    $migrationPending = $ValidationPhase -eq 'PreCommunity' -and $PlannedNotificationAction -in @('Update', 'Repair') -and $notificationLifecycle.State -in @('InstalledNeedsMigration', 'InstalledUpdateAvailable', 'InstalledNeedsRepair', 'ManagedPartialState', 'ManagedDuplicateState')
    $installationPending = $ValidationPhase -eq 'PreCommunity' -and $PlannedNotificationAction -eq 'Install' -and $notificationLifecycle.State -eq 'NotInstalled'
    $transitionPending = $migrationPending -or $installationPending -or ($ValidationPhase -eq 'PreCommunity' -and $PlannedNotificationAction -eq 'Uninstall' -and $notificationLifecycle.State -notin @('NotInstalled', 'TrueUnmanagedConflict', 'MalformedUserOwnedState', 'Conflict', 'Unknown'))
    if (-not $transitionPending -and ($notificationQuestionHookCount -ne $expectedNotificationCount -or $notificationPermissionHookCount -ne $expectedNotificationCount -or $notificationCompletedHookCount -ne 0 -or [int]$completionNotificationConfigured -ne $expectedNotificationCount -or $notificationScriptCount -ne $expectedNotificationCount)) {
        throw "Windows 通知安裝檢查失敗：notificationLifecycleState=$($notificationLifecycle.State) notificationSchemaVersion=$($notificationLifecycle.SchemaVersion) legacyCompletedStopDetected=$($notificationLifecycle.LegacyCompletedStopDetected) managedNotifyBlockPresent=$($notificationLifecycle.ManagedNotifyBlockPresent) managedNotifyCommandCurrent=$($notificationLifecycle.ManagedNotifyCommandCurrent) plannedNotificationAction=$PlannedNotificationAction validationPhase=$ValidationPhase migrationPending=$migrationPending Expected=$expectedNotificationCount QuestionHookCount=$notificationQuestionHookCount PermissionHookCount=$notificationPermissionHookCount CompletedStopHookCount=$notificationCompletedHookCount NotificationCommandConfigured=$notificationCommandConfigured NotificationScriptCount=$notificationScriptCount"
    }
    $projectCounts = [pscustomobject]@{ NotificationStop = 0; LegacyNotificationStop = 0; Token = 0; LineEndingPreToolUse = 0; LineEndingPostToolUse = 0; LineEndingStop = 0; LegacyCrlf = 0 }
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $projectHooksPath = Join-Path $ProjectRoot '.codex\hooks.json'
        if (Test-Path -LiteralPath $projectHooksPath -PathType Leaf) { $projectCounts = Get-HookConfigurationCounts -HooksPath $projectHooksPath }
    }
    $projectNotificationStopHookCount = [int]$projectCounts.NotificationStop
    $projectLineEndingPreToolUseHookCount = [int]$projectCounts.LineEndingPreToolUse
    $projectLineEndingPostToolUseHookCount = [int]$projectCounts.LineEndingPostToolUse
    $projectLineEndingStopHookCount = [int]$projectCounts.LineEndingStop
    $projectLegacyCrlfHookCount = [int]$projectCounts.LegacyCrlf
    $projectLegacyTokenHookCount = [int]$projectCounts.Token

    $notificationScriptPath = Join-Path $Root 'hooks\show-codex-notification.ps1'
    $detachedToastCleanup = -not $InstallWindowsNotifications
    if (Test-Path -LiteralPath $notificationScriptPath -PathType Leaf) {
        $notificationSource = [IO.File]::ReadAllText($notificationScriptPath)
        $detachedToastCleanup = $notificationSource -match '\$startInfo\.UseShellExecute\s*=\s*\$false' -and $notificationSource -match '\$startInfo\.CreateNoWindow\s*=\s*\$true' -and $notificationSource -match 'RedirectStandardInput' -and $notificationSource -match 'RedirectStandardOutput' -and $notificationSource -match 'RedirectStandardError'
    }

    $globalNotificationStopHookCount = $notificationCompletedHookCount
    $legacyTokenHookCount = [int]$globalCounts.Token + $projectLegacyTokenHookCount
    $legacyCompletedNotificationHookCount = [int]$globalCounts.LegacyNotificationStop + [int]$projectCounts.LegacyNotificationStop
    $effectiveCompletedNotificationHookCount = [int]$completionNotificationConfigured + $notificationCompletedHookCount + $projectNotificationStopHookCount
    $legacyCrlfHookCount += $projectLegacyCrlfHookCount
    if ((-not $transitionPending -and $legacyCompletedNotificationHookCount -ne 0) -or ($transitionPending -and [int]$projectCounts.LegacyNotificationStop -ne 0) -or $projectLegacyCrlfHookCount -ne 0 -or $legacyTokenHookCount -ne 0) {
        throw "仍包含受管理的舊 Hook：LegacyCompletedNotification=$legacyCompletedNotificationHookCount LegacyCrlf=$legacyCrlfHookCount LegacyToken=$legacyTokenHookCount"
    }
    $expectedEffectiveNotificationCount = if ($InstallWindowsNotifications) { 1 } else { 0 }
    if (-not $transitionPending -and $effectiveCompletedNotificationHookCount -ne $expectedEffectiveNotificationCount) {
        throw "有效 Completed 通知 Hook 數量錯誤：Expected=$expectedEffectiveNotificationCount Global=$notificationCompletedHookCount Project=$projectNotificationStopHookCount Effective=$effectiveCompletedNotificationHookCount"
    }
    if ($DevelopmentEnvironment -eq 'CVS') {
        if ($projectLineEndingPreToolUseHookCount -ne 0 -or $projectLineEndingPostToolUseHookCount -ne 0 -or $projectLineEndingStopHookCount -ne 0 -or $trackHookCount -ne 1 -or $restoreHookCount -ne 1 -or $finalizeHookCount -ne 1 -or $preserveScriptCount -ne 1 -or $legacyHookCount -ne 0) { throw "CVS 換行保護安裝檢查失敗：ProjectTrackHookCount=$projectLineEndingPreToolUseHookCount ProjectRestoreHookCount=$projectLineEndingPostToolUseHookCount ProjectFinalizeHookCount=$projectLineEndingStopHookCount TrackHookCount=$trackHookCount RestoreHookCount=$restoreHookCount FinalizeHookCount=$finalizeHookCount PreserveLineEndingScriptCount=$preserveScriptCount LegacyCrlfHookCount=$legacyHookCount" }
    } elseif ($trackHookCount -ne 0 -or $restoreHookCount -ne 0 -or $finalizeHookCount -ne 0 -or $preserveScriptCount -ne 0 -or $legacyHookCount -ne 0) {
        throw 'Git 全域設定仍包含 CVS 換行保護 Hook。'
    }
    if ($DevelopmentEnvironment -eq 'Git' -and ($projectLineEndingPostToolUseHookCount -ne 0 -or $projectLineEndingStopHookCount -ne 0)) {
        throw 'Git 專案仍包含 CVS 換行保護 Hook。'
    }
    if (-not $detachedToastCleanup) { throw 'Windows 通知 Toast 子程序未完成獨立輸入輸出設定。' }
    return [pscustomobject]@{
        GlobalNotificationStopHookCount = $globalNotificationStopHookCount
        ProjectNotificationStopHookCount = $projectNotificationStopHookCount
        GlobalCompletedNotificationHookCount = $notificationCompletedHookCount
        NotificationCommandConfigured = [bool]$notificationCommandConfigured
        ExternalNotificationCommandPreserved = [bool]$notificationLifecycle.ExternalNotifyCoexistence
        ProjectCompletedNotificationHookCount = $projectNotificationStopHookCount
        LegacyCompletedNotificationHookCount = $legacyCompletedNotificationHookCount
        StandaloneTokenUsageHookCount = $legacyTokenHookCount
        EffectiveCompletedNotificationHookCount = $effectiveCompletedNotificationHookCount
        ProjectLineEndingPreToolUseHookCount = $projectLineEndingPreToolUseHookCount
        ProjectLineEndingPostToolUseHookCount = $projectLineEndingPostToolUseHookCount
        ProjectLineEndingStopHookCount = $projectLineEndingStopHookCount
        ProjectLineEndingFinalizeHookCount = $projectLineEndingStopHookCount
        GlobalLineEndingPreToolUseHookCount = $trackHookCount
        GlobalLineEndingPostToolUseHookCount = $restoreHookCount
        GlobalLineEndingStopHookCount = $finalizeHookCount
        LegacyCrlfHookCount = $legacyCrlfHookCount
        LegacyTokenHookCount = $legacyTokenHookCount
        DuplicateManagedHookCount = [Math]::Max(0, $notificationQuestionHookCount - 1) + [Math]::Max(0, $notificationPermissionHookCount - 1) + [Math]::Max(0, $notificationCompletedHookCount - 1) + [Math]::Max(0, $trackHookCount - 1) + [Math]::Max(0, $restoreHookCount - 1) + [Math]::Max(0, $finalizeHookCount - 1)
        DetachedToastCleanup = $detachedToastCleanup
    }
}
