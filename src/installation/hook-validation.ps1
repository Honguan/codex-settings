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
    $}x�N-�G����ƭy�pe = 'command'; command = 'custom-project-post.ps1' }
            ) })
        }
    }
    Write-JsonFileAtomic -Path (Join-Path $projectCodex 'hooks.json') -Value $projectHooks -Depth 10
    foreach ($scriptName in @('crlf-updated-files.ps1', 'normalize-cvs-crlf.ps1', 'preserve-line-endings.ps1', 'show-turn-token-usage.ps1', 'show-codex-notification.ps1', 'legacy-completion-notification.ps1')) {
        [IO.File]::WriteAllText((Join-Path $projectCodex ("hooks\$scriptName")), '# managed legacy hook', [Text.UTF8Encoding]::new($false))
    }
    $customProjectScript = Join-Path $projectCodex 'hooks\custom-project-stop.ps1'
    [IO.File]::WriteAllText($customProjectScript, '# user custom hook', [Text.UTF8Encoding]::new($false))
    $customProjectToastScript = Join-Path $projectCodex 'hooks\user-toast.ps1'
    [IO.File]::WriteAllText($customProjectToastScript, '# user custom notification hook', [Text.UTF8Encoding]::new($false))
    Install-TestEnvironment -Environment CVS -Cwd $projectRoot
    $projectHooksAfter = Get-Content -LiteralPath (Join-Path $projectCodex 'hooks.json') -Raw | ConvertFrom-Json
    $projectNotificationCount = @($projectHooksAfter.hooks.Stop | Where-Object { $null -ne $_ -and (Test-ManagedNotificationHookEntry $_) }).Count
    $projectPreLineCount = @($projectHooksAfter.hooks.PreToolUse | Where-Object { $null -ne $_ -and (Test-ManagedLineEndingHookEntry $_) }).Count
    $projectPostLineCount = @($projectHooksAfter.hooks.PostToolUse | Where-Object { $null -ne $_ -and (Test-ManagedLineEndingHookEntry $_) }).Count
    $projectStopLineCount = @($projectHooksAfter.hooks.Stop | Where-Object { $null -ne $_ -and (Test-ManagedLineEndingHookEntry $_) }).Count
    if ($projectNotificationCount -ne 0 -or $projectPreLineCount -ne 0 -or $projectPostLineCount -ne 0 -or $projectStopLineCount -ne 0) { throw "CVS 專案更新未清理受管理的重複 Hook：notification=$projectNotificationCount pre=$projectPreLineCount post=$projectPostLineCount stop=$projectStopLineCount" }
    $projectCheck = Assert-GlobalLineEndingHook -DevelopmentEnvironment CVS -Root $globalRoot -InstallWindowsNotifications $true -ProjectRoot $projectRoot
    if ($projectCheck.GlobalNotificationStopHookCount -ne 0 -or -not $projectCheck.NotificationCommandConfigured -or $projectCheck.ProjectNotificationStopHookCount -ne 0 -or $projectCheck.EffectiveCompletedNotificationHookCount -ne 1 -or $projectCheck.LegacyCompletedNotificationHookCount -ne 0 -or $projectCheck.StandaloneTokenUsageHookCount -ne 0 -or $projectCheck.ProjectLineEndingPreToolUseHookCount -ne 0 -or $projectCheck.ProjectLineEndingPostToolUseHookCount -ne 0 -or $projectCheck.ProjectLineEndingStopHookCount -ne 0 -or $projectCheck.GlobalLineEndingPreToolUseHookCount -ne 1 -or $projectCheck.GlobalLineEndingPostToolUseHookCount -ne 1 -or $projectCheck.GlobalLineEndingStopHookCount -ne 1 -or $projectCheck.LegacyCrlfHookCount -ne 0 -or $projectCheck.LegacyTokenHookCount -ne 0 -or $projectCheck.DuplicateManagedHookCount -ne 0 -or -not $projectCheck.DetachedToastCleanup) { throw 'CVS 專案 Hook 自檢結果不符合 Issue #125 驗收條件。' }
    if (-not (Test-Path -LiteralPath $customProjectScript -PathType Leaf)) { throw 'CVS 專案更新誤刪使用者自訂 Hook。' }
    if (-not (Test-Path -LiteralPath $customProjectToastScript -PathType Leaf) -or @($projectHooksAfter.hooks.Stop | ForEach-Object { @($_.hooks) } | Where-Object { (Get-HookEntryText -Entry $_) -match 'user-toast\.ps1' }).Count -ne 1) { throw 'CVS 專案更新誤刪使用者自訂 Toast Hook。' }
    foreach ($scriptName in @('crlf-updated-files.ps1', 'normalize-cvs-crlf.ps1', 'preserve-line-endings.ps1', 'show-turn-token-usage.ps1', 'show-codex-notification.ps1')) {
        if (Test-Path -LiteralPath (Join-Path $projectCodex ("hooks\$scriptName"))) { throw "CVS 專案更新保留舊受管理腳本：$scriptName" }
    }
    if (Test-Path -LiteralPath (Join-Path $projectCodex 'hooks\legacy-completion-notification.ps1')) { throw 'CVS 專案更新保留舊完成通知腳本。' }

    Install-TestEnvironment -Environment Git
    $manifest = Get-Manifest $globalRoot
    if ($manifest.ManagedHooks.managedId -ne 'codex-settings' -or [int]$manifest.ManagedHooks.managedVersion -ne 3 -or $manifest.ManagedHooks.notification.managedId -ne 'codex-settings-notification' -or [int]$manifest.ManagedHooks.notification.managedVersion -ne 5) { throw '安裝 manifest 缺少通知 managedId/managedVersion。' }
    $completedManifestHandlers = @($manifest.ManagedHooks.notification.handlers | Where-Object { $_.event -eq 'Stop' -and $_.handlerId -eq 'completed-toast' })
    if ($completedManifestHandlers.Count -ne 0 -or @($manifest.Community.windowsUsageNotifications.ManagedConfigSections) -notcontains 'notify') { throw '安裝 manifest 未記錄 canonical notify 所有權。' }
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    $config = Get-Content -LiteralPath (Join-Path $globalRoot 'config.toml') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# Git Project Rules' -or $agents -match '# CVS Project Rules') { throw 'Git AGENTS.md composition is invalid.' }
    if ([regex]::Matches($agents, '(?m)^## Issue Branch Workflow\s*$').Count -ne 1 -or [regex]::Matches($agents, '(?m)^## Pull Request and Main Verification\s*$').Count -ne 1 -or $agents -notmatch 'issue/<issue-number>-<short-description>' -or $agents -notmatch 'Refs #<issue-number>' -or $agents -notmatch 'only after the fixing commit is on the default branch') { throw 'Git Issue branch and main-verification workflow is missing or duplicated.' }
    if ([regex]::Matches($rules, 'Git project rules supplement').Count -ne 1 -or [regex]::Matches($rules, 'CVS project rules supplement').Count -ne 0) { throw 'Git rules contain duplicate or conflicting project-type settings.' }
    if ($config -notmatch 'project_root_markers = \["\.git", "CVS"\]' -or $config -match '\.codex-root' -or -not (Test-WindowsNotificationCommandConfig -Content $config -Root $globalRoot)) { throw 'Global project root markers or canonical notify config are invalid.' }
    if ((Get-DefaultDevelopmentEnvironment -Root $globalRoot) -ne 'Git') { throw 'Git was not recorded as the default project system.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.SessionStart).Count -ne 1 -or @($installedHooks.hooks.PreToolUse).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0 -or $installedHooks.hooks.PSObject.Properties.Name -contains 'PostToolUse') { throw 'Git installation did not preserve the global hooks.' }
    if (-not (Test-ManagedNotificationHookEntry $installedHooks.hooks.PreToolUse[0]) -or -not (Test-ManagedNotificationHookEntry $installedHooks.hooks.PermissionRequest[0]) -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0) { throw 'Git notification hooks are invalid.' }
    if (-not (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\show-codex-notification.ps1') -PathType Leaf)) { throw 'Git installation omitted the global notification script.' }
    $notificationScriptBytes = [IO.File]::ReadAllBytes((Join-Path $globalRoot 'hooks\show-codex-notification.ps1'))
    if ($notificationScriptBytes.Length -lt 3 -or $notificationScriptBytes[0] -ne 0xEF -or $notificationScriptBytes[1] -ne 0xBB -or $notificationScriptBytes[2] -ne 0xBF) { throw 'Installed notification script lost its UTF-8 BOM.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\preserve-line-endings.ps1')) { throw 'Git installation retained the CVS line-ending protection script.' }

    Install-TestEnvironment -Environment CVS
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# CVS Project Rules' -or $agents -match '# Git Project Rules') { throw 'CVS AGENTS.md composition is invalid.' }
    if ($agents -match '(?m)^## Issue Completion Workflow\s*$') { throw 'CVS installation retained Git Issue completion instructions.' }
    if ([regex]::Matches($rules, 'CVS project rules supplement').Count -ne 1 -or [regex]::Matches($rules, 'Git project rules supplement').Count -ne 0) { throw 'CVS rules contain duplicate or conflicting project-type settings.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.SessionStart).Count -ne 1) { throw 'CVS installation did not preserve the unmanaged user hook.' }
    if (@($installedHooks.hooks.PreToolUse).Count -ne 2 -or @($installedHooks.hooks.PermissionRequest).Count -ne 1 -or @($installedHooks.hooks.PostToolUse).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0) { throw 'Repeated CVS installation duplicated or omitted managed hooks.' }
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PostToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1) { throw 'Repeated CVS installation duplicated or omitted the line-ending protection hooks.' }
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0) { throw 'Repeated CVS installation duplicated or omitted the global notification hooks.' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:ScriptRoot 'templates\environments\cvs\hooks.json')) -or -not (Test-Path -LiteralPath (Join-Path $script:ScriptRoot 'templates\environments\cvs\hooks\preserve-line-endings.ps1'))) { throw 'CVS line-ending hook templates are missing.' }

    Install-TestEnvironment -Environment Git
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1')) { throw 'Switching environments retained the obsolete CVS hook script.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\preserve-line-endings.ps1')) { throw 'Switching environments retained the CVS line-ending protection script.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0) { throw 'Switching environments duplicated or removed the global notification hooks.' }

    Install-TestEnvironment -Environment Git -InstallWindowsNotifications $false
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.PSObject.Properties.Value | ForEach-Object { @($_) } | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0) { throw 'Disabling Windows notifications retained managed notification hooks.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\show-codex-notification.ps1')) { throw 'Disabling Windows notifications retained the notification script.' }
    if (Test-WindowsNotificationCommandConfig -Content ([IO.File]::ReadAllText((Join-Path $globalRoot 'config.toml'))) -Root $globalRoot) { throw 'Disabling Windows notifications retained canonical notify config.' }

    $script:notificationAnswer = ''
    $script:capturedNotificationPrompt = ''
    function Read-Host([string]$Prompt) {
        $script:capturedNotificationPrompt = $Prompt
        return $script:notificationAnswer
    }
    try {
        if ((Select-OptionalWindowsNotifications -AlreadyInstalled:$false) -ne 'Install') { throw 'Blank first-install selection must install Windows notifications.' }
        if ($script:capturedNotificationPrompt -ne '要安裝嗎？[Y/n]') { throw 'First-install notification prompt is invalid.' }
        if ((Select-OptionalWindowsNotifications -AlreadyInstalled:$true) -ne 'KeepCurrent') { throw 'Blank update selection must preserve Windows notifications.' }
        if ($script:capturedNotificationPrompt -ne '要保留並檢查更新嗎？[Y/n]') { throw 'Existing notification prompt is invalid.' }
    } finally {
        Remove-Item -LiteralPath Function:\Read-Host -ErrorAction SilentlyContinue
    }

    . (Get-OptionalInstallationScriptPath -Name Serena)
    $script:capturedSerenaPrompt = ''
    function Read-Host([string]$Prompt) {
        $script:capturedSerenaPrompt = $Prompt
        return ''
    }
    try {
        if ((Select-OptionalSerena) -ne 'Install') { throw 'Blank Serena selection must install Serena.' }
        if ($script:capturedSerenaPrompt -ne '要安裝嗎？[Y/n]') { throw 'Serena prompt must default to [Y/n].' }
    } finally {
        Remove-Item -LiteralPath Function:\Read-Host -ErrorAction SilentlyContinue
    }

    $serenaSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'installation\serena.ps1') -Raw
    foreach ($requiredCommand in @("@('tool', 'install', '-p', '3.13'", '@(''tool'', ''upgrade'', $script:SerenaPackageName)', "@('setup', 'codex')")) {
        if ($serenaSource -notmatch [regex]::Escape($requiredCommand)) { throw "Serena installer does not use the required official command: $requiredCommand" }
    }
    if ($serenaSource -match 'uvx' -or $serenaSource -match 'git\+') { throw 'Serena installer must not configure uvx or Git-based MCP startup.' }
    $script:capturedEnvironmentPrompt = ''
    function Read-Host([string]$Prompt) {
        $script:capturedEnvironmentPrompt = $Prompt
        return ''
    }
    try {
        if ((Select-DevelopmentEnvironment -Default CVS) -ne 'CVS') { throw 'Blank selection did not reuse the recorded CVS default.' }
        if ($script:capturedEnvironmentPrompt -ne '請選擇 [2]') { throw 'CVS default was not shown in the selection prompt.' }
    } finally {
        Remove-Item -LiteralPath Function:\Read-Host -ErrorAction SilentlyContinue
    }

    Write-Host 'Global development environment tests passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
