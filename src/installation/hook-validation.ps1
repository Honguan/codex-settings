function Remove-GlobalLineEndingHooks([string]$Root, $Transaction) {
    Remove-GlobalLineEndingHookEntries -Root $Root -Transaction $Transaction
    foreach ($scriptName in @('mixed-line-ending-hook.ps1', 'crlf-updated-files.ps1', 'normalize-cvs-crlf.ps1', 'preserve-line-endings.ps1')) {
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

function Normalize-ManagedProjectLineEndingHooksJson([string]$Content) {
    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return $Content }
    $templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\environments\cvs\hooks.json'
    $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $hasManagedLineEndingHook = $false
    foreach ($eventName in @('PreToolUse', 'PostToolUse', 'Stop')) {
        $property = $object.hooks.PSObject.Properties[$eventName]
        if ($null -eq $property) { continue }
        foreach ($group in @($property.Value)) {
            if (@(Get-ManagedHookEntries -Entry $group -SignaturePattern $script:ManagedLineEndingHookSignaturePattern).Count -gt 0) { $hasManagedLineEndingHook = $true; break }
        }
        if ($hasManagedLineEndingHook) { break }
    }
    foreach ($eventName in @('PreToolUse', 'PostToolUse', 'Stop')) {
        $property = $object.hooks.PSObject.Properties[$eventName]
        $managedCount = 0
        $unmanagedGroups = New-Object 'System.Collections.Generic.List[object]'
        $groups = if ($null -eq $property) { @() } else { @($property.Value) }
        foreach ($group in $groups) {
            $hookProperty = $group.PSObject.Properties['hooks']
            if ($null -eq $hookProperty) {
                if (-not (Test-ManagedLineEndingHookEntry $group)) { [void]$unmanagedGroups.Add($group) }
                continue
            }
            $unmanagedHooks = @($hookProperty.Value | Where-Object {
                if (Test-ManagedLineEndingHookEntry $_) { $managedCount = $managedCount + 1; $false } else { $true }
            })
            if ($unmanagedHooks.Count -gt 0) {
                $group | Add-Member -NotePropertyName hooks -NotePropertyValue $unmanagedHooks -Force
                [void]$unmanagedGroups.Add($group)
            }
        }
        if ($managedCount -eq 0 -and -not $hasManagedLineEndingHook) { continue }
        $canonical = @($template.hooks.$eventName)[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json -ErrorAction Stop
        $object.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue ($unmanagedGroups.ToArray() + @($canonical)) -Force
    }
    return ($object | ConvertTo-Json -Depth 30)
}

function Remove-ManagedProjectHooks([string]$StartPath, $Transaction, [switch]$KeepCvsLineEndingHooks, [switch]$PreserveNotifications, [string[]]$ManagedHookFingerprints = @()) {
    $projectRoot = Find-CvsProjectRoot -StartPath $StartPath
    if ([string]::IsNullOrWhiteSpace($projectRoot)) { return $null }

    $codexRoot = Join-Path $projectRoot '.codex'
    $hooksPath = Join-Path $codexRoot 'hooks.json'
    $changed = $false
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        $state = Get-TextFileState $hooksPath
        $referencedScripts = if ($PreserveNotifications) { @() } else { @(Get-ManagedHookScriptPaths -Content $state.Content -Root $codexRoot -ManagedHookFingerprints $ManagedHookFingerprints) }
        $cleaned = if ($PreserveNotifications) { $state.Content } else { Remove-ManagedGlobalHooksJson -Content $state.Content -ManagedHookFingerprints $ManagedHookFingerprints }
        $cleaned = if ($KeepCvsLineEndingHooks) { Normalize-ManagedProjectLineEndingHooksJson -Content $cleaned } else { Remove-ManagedLineEndingHooksJson -Content $cleaned }
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
        LineEndingSessionStart = 0
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
                    if ($property.Name -eq 'SessionStart') { $counts.LineEndingSessionStart++ }
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
    } elseif ($question -eq 1 -and $permission -eq 1 -and $completed -eq 0 -and $scriptCount -eq 1 -and $configState -eq 'CurrentManagedBlock') {
        'InstalledCurrent'
    } elseif ($question -eq 1 -and $permission -eq 1 -and $completed -eq 0 -and $scriptCount -eq 1 -and $externalNotifyCoexistence) {
        'InstalledUpdateAvailable'
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
    $sessionStartHookCount = [int]$globalCounts.LineEndingSessionStart
    $trackHookCount = [int]$globalCounts.LineEndingPreToolUse
    $restoreHookCount = [int]$globalCounts.LineEndingPostToolUse
    $finalizeHookCount = [int]$globalCounts.LineEndingStop
    $legacyHookCount = [int]$globalCounts.LegacyCrlf
    $notificationQuestionHookCount = [int]$globalCounts.NotificationPreToolUse
    $notificationPermissionHookCount = [int]$globalCounts.NotificationPermissionRequest
    $notificationCompletedHookCount = [int]$globalCounts.NotificationStop
    $preserveScriptCount = @(@('mixed-line-ending-hook.ps1', 'preserve-line-endings.ps1') | Where-Object { Test-Path -LiteralPath (Join-Path $Root "hooks\$_") -PathType Leaf }).Count
    $notificationScriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\show-codex-notification.ps1') -PathType Leaf) { 1 } else { 0 }
    $expectedNotificationCount = 0
    $notificationLifecycle = Get-WindowsNotificationLifecycleState -Root $Root -ManagedNotificationFingerprints $ManagedNotificationFingerprints
    $completionNotificationConfigured = $notificationCommandConfigured
    $transitionPending = $false
    if ($notificationQuestionHookCount -ne 0 -or $notificationPermissionHookCount -ne 0 -or $notificationCompletedHookCount -ne 0 -or $notificationCommandConfigured -or $notificationScriptCount -ne 0) {
        throw "封存的 Windows 通知 Hook 仍存在：QuestionHookCount=$notificationQuestionHookCount PermissionHookCount=$notificationPermissionHookCount CompletedStopHookCount=$notificationCompletedHookCount NotificationCommandConfigured=$notificationCommandConfigured NotificationScriptCount=$notificationScriptCount"
    }
    $projectCounts = [pscustomobject]@{ NotificationStop = 0; LegacyNotificationStop = 0; Token = 0; LineEndingSessionStart = 0; LineEndingPreToolUse = 0; LineEndingPostToolUse = 0; LineEndingStop = 0; LegacyCrlf = 0 }
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $projectHooksPath = Join-Path $ProjectRoot '.codex\hooks.json'
        if (Test-Path -LiteralPath $projectHooksPath -PathType Leaf) { $projectCounts = Get-HookConfigurationCounts -HooksPath $projectHooksPath }
    }
    $projectNotificationStopHookCount = [int]$projectCounts.NotificationStop
    $projectLineEndingSessionStartHookCount = [int]$projectCounts.LineEndingSessionStart
    $projectLineEndingPreToolUseHookCount = [int]$projectCounts.LineEndingPreToolUse
    $projectLineEndingPostToolUseHookCount = [int]$projectCounts.LineEndingPostToolUse
    $projectLineEndingStopHookCount = [int]$projectCounts.LineEndingStop
    $projectLegacyCrlfHookCount = [int]$projectCounts.LegacyCrlf
    $projectLegacyTokenHookCount = [int]$projectCounts.Token

    $detachedToastCleanup = $true

    $globalNotificationStopHookCount = $notificationCompletedHookCount
    $legacyTokenHookCount = [int]$globalCounts.Token + $projectLegacyTokenHookCount
    $legacyCompletedNotificationHookCount = [int]$globalCounts.LegacyNotificationStop + [int]$projectCounts.LegacyNotificationStop
    $effectiveCompletedNotificationHookCount = $notificationCompletedHookCount + $projectNotificationStopHookCount
    $legacyCrlfHookCount += $projectLegacyCrlfHookCount
    if ((-not $transitionPending -and $legacyCompletedNotificationHookCount -ne 0) -or ($transitionPending -and [int]$projectCounts.LegacyNotificationStop -ne 0) -or $projectLegacyCrlfHookCount -ne 0 -or $legacyTokenHookCount -ne 0) {
        throw "仍包含受管理的舊 Hook：LegacyCompletedNotification=$legacyCompletedNotificationHookCount LegacyCrlf=$legacyCrlfHookCount LegacyToken=$legacyTokenHookCount"
    }
    if ($effectiveCompletedNotificationHookCount -ne 0) { throw "專案仍包含封存的 Windows 通知 Hook：Global=$notificationCompletedHookCount Project=$projectNotificationStopHookCount" }
    if ($sessionStartHookCount -ne 0 -or $trackHookCount -ne 0 -or $restoreHookCount -ne 0 -or $finalizeHookCount -ne 0 -or $preserveScriptCount -ne 0 -or $legacyHookCount -ne 0 -or $projectLineEndingSessionStartHookCount -ne 0 -or $projectLineEndingPreToolUseHookCount -ne 0 -or $projectLineEndingPostToolUseHookCount -ne 0 -or $projectLineEndingStopHookCount -ne 0) {
        throw '仍包含封存的 CVS 換行保護 Hook。'
    }
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
        ProjectLineEndingSessionStartHookCount = $projectLineEndingSessionStartHookCount
        ProjectLineEndingPostToolUseHookCount = $projectLineEndingPostToolUseHookCount
        ProjectLineEndingStopHookCount = $projectLineEndingStopHookCount
        ProjectLineEndingFinalizeHookCount = $projectLineEndingStopHookCount
        GlobalLineEndingPreToolUseHookCount = $trackHookCount
        GlobalLineEndingSessionStartHookCount = $sessionStartHookCount
        GlobalLineEndingPostToolUseHookCount = $restoreHookCount
        GlobalLineEndingStopHookCount = $finalizeHookCount
        LegacyCrlfHookCount = $legacyCrlfHookCount
        LegacyTokenHookCount = $legacyTokenHookCount
        DuplicateManagedHookCount = [Math]::Max(0, $notificationQuestionHookCount - 1) + [Math]::Max(0, $notificationPermissionHookCount - 1) + [Math]::Max(0, $notificationCompletedHookCount - 1) + $sessionStartHookCount + $trackHookCount + $restoreHookCount + $finalizeHookCount
        DetachedToastCleanup = $detachedToastCleanup
    }
}
