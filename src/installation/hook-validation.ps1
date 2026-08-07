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

function Remove-ManagedProjectHooks([string]$StartPath, $Transaction, [switch]$KeepCvsLineEndingHooks) {
    $projectRoot = Find-CvsProjectRoot -StartPath $StartPath
    if ([string]::IsNullOrWhiteSpace($projectRoot)) { return $null }

    $codexRoot = Join-Path $projectRoot '.codex'
    $hooksPath = Join-Path $codexRoot 'hooks.json'
    $changed = $false
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        $state = Get-TextFileState $hooksPath
        $cleaned = Remove-ManagedGlobalHooksJson -Content $state.Content
        $cleaned = if ($KeepCvsLineEndingHooks) { Normalize-ManagedProjectLineEndingHooksJson -Content $cleaned } else { Remove-ManagedLineEndingHooksJson -Content $cleaned }
        if ($cleaned -ne $state.Content) {
            Save-TransactionFile -Transaction $Transaction -Path $hooksPath
            Write-TextFileState -Path $hooksPath -Content $cleaned -Encoding $state.Encoding
            $changed = $true
        }
    }

    $removedScripts = 0
    foreach ($scriptName in @(
        'crlf-updated-files.ps1',
        'normalize-cvs-crlf.ps1',
        'preserve-line-endings.ps1',
        'show-turn-token-usage.ps1',
        'show-codex-notification.ps1'
    )) {
        $scriptPath = Join-Path $codexRoot ("hooks\$scriptName")
        if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
            Save-TransactionFile -Transaction $Transaction -Path $scriptPath
            Remove-Item -LiteralPath $scriptPath -Force
            $removedScripts++
            $changed = $true
        }
    }

    $hooksRoot = Join-Path $codexRoot 'hooks'
    if ((Test-Path -LiteralPath $hooksRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $hooksRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $hooksRoot -Force
    }
    return [pscustomobject]@{ ProjectRoot = $projectRoot; Changed = $changed; RemovedScripts = $removedScripts }
}

function Assert-GlobalLineEndingHook([ValidateSet('Git', 'CVS')][string]$DevelopmentEnvironment, [string]$Root, [bool]$InstallWindowsNotifications, [string]$ProjectRoot) {
    $hooksPath = Join-Path $Root 'hooks.json'
    $hookContent = if (Test-Path -LiteralPath $hooksPath -PathType Leaf) { [IO.File]::ReadAllText($hooksPath) } else { '' }
    $trackHookCount = 0
    $restoreHookCount = 0
    $finalizeHookCount = 0
    $legacyHookCount = 0
    $notificationQuestionHookCount = 0
    $notificationPermissionHookCount = 0
    $notificationCompletedHookCount = 0
    if (-not [string]::IsNullOrWhiteSpace($hookContent)) {
        $hookObject = $hookContent | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $hookObject.hooks) {
            foreach ($property in @($hookObject.hooks.PSObject.Properties)) {
                foreach ($entry in @($property.Value)) {
                    foreach ($managedEntry in @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:PreserveLineEndingHookSignaturePattern)) {
                        if ($property.Name -eq 'PreToolUse') { $trackHookCount++ }
                        if ($property.Name -eq 'PostToolUse') { $restoreHookCount++ }
                        if ($property.Name -eq 'Stop') { $finalizeHookCount++ }
                    }
                    $legacyHookCount += @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:LegacyCrlfHookSignaturePattern).Count
                    foreach ($managedEntry in @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:ManagedNotificationHookSignaturePattern)) {
                        if ($property.Name -eq 'PreToolUse') { $notificationQuestionHookCount++ }
                        if ($property.Name -eq 'PermissionRequest') { $notificationPermissionHookCount++ }
                        if ($property.Name -eq 'Stop') { $notificationCompletedHookCount++ }
                    }
                }
            }
        }
    }
    $preserveScriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\preserve-line-endings.ps1') -PathType Leaf) { 1 } else { 0 }
    $notificationScriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\show-codex-notification.ps1') -PathType Leaf) { 1 } else { 0 }
    $expectedNotificationCount = if ($InstallWindowsNotifications) { 1 } else { 0 }
    if ($notificationQuestionHookCount -ne $expectedNotificationCount -or $notificationPermissionHookCount -ne $expectedNotificationCount -or $notificationCompletedHookCount -ne $expectedNotificationCount -or $notificationScriptCount -ne $expectedNotificationCount) {
        throw "Windows 通知安裝檢查失敗：Expected=$expectedNotificationCount QuestionHookCount=$notificationQuestionHookCount PermissionHookCount=$notificationPermissionHookCount CompletedHookCount=$notificationCompletedHookCount NotificationScriptCount=$notificationScriptCount"
    }
    $projectNotificationStopHookCount = 0
    $projectLineEndingPreToolUseHookCount = 0
    $projectLineEndingPostToolUseHookCount = 0
    $projectLineEndingStopHookCount = 0
    $projectLegacyCrlfHookCount = 0
    $projectLegacyTokenHookCount = 0
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $projectHooksPath = Join-Path $ProjectRoot '.codex\hooks.json'
        if (Test-Path -LiteralPath $projectHooksPath -PathType Leaf) {
            $projectHooks = Get-Content -LiteralPath $projectHooksPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $projectHooks.hooks) {
                foreach ($property in @($projectHooks.hooks.PSObject.Properties)) {
                    foreach ($entry in @($property.Value)) {
                        if ($property.Name -eq 'Stop') { $projectNotificationStopHookCount += @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:ManagedNotificationHookSignaturePattern).Count }
                        if ($property.Name -eq 'PreToolUse') { $projectLineEndingPreToolUseHookCount += @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:PreserveLineEndingHookSignaturePattern).Count }
                        if ($property.Name -eq 'PostToolUse') { $projectLineEndingPostToolUseHookCount += @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:PreserveLineEndingHookSignaturePattern).Count }
                        if ($property.Name -eq 'Stop') { $projectLineEndingStopHookCount += @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:PreserveLineEndingHookSignaturePattern).Count }
                        $projectLegacyCrlfHookCount += @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:LegacyCrlfHookSignaturePattern).Count
                        $projectLegacyTokenHookCount += @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:ManagedTokenHookSignaturePattern).Count
                    }
                }
            }
        }
    }

    $notificationScriptPath = Join-Path $Root 'hooks\show-codex-notification.ps1'
    $detachedToastCleanup = -not $InstallWindowsNotifications
    if (Test-Path -LiteralPath $notificationScriptPath -PathType Leaf) {
        $notificationSource = [IO.File]::ReadAllText($notificationScriptPath)
        $detachedToastCleanup = $notificationSource -match '\$startInfo\.UseShellExecute\s*=\s*\$false' -and $notificationSource -match '\$startInfo\.CreateNoWindow\s*=\s*\$true' -and $notificationSource -match 'RedirectStandardInput' -and $notificationSource -match 'RedirectStandardOutput' -and $notificationSource -match 'RedirectStandardError'
    }

    $globalNotificationStopHookCount = $notificationCompletedHookCount
    $legacyTokenHookCount = 0
    if (-not [string]::IsNullOrWhiteSpace($hookContent)) {
        $hookObject = $hookContent | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $hookObject.hooks) {
            foreach ($property in @($hookObject.hooks.PSObject.Properties)) {
                foreach ($entry in @($property.Value)) {
                    $legacyTokenHookCount += @(Get-ManagedHookEntries -Entry $entry -SignaturePattern $script:ManagedTokenHookSignaturePattern).Count
                }
            }
        }
    }
    $legacyCrlfHookCount += $projectLegacyCrlfHookCount
    $legacyTokenHookCount += $projectLegacyTokenHookCount
    if ($projectNotificationStopHookCount -ne 0 -or $projectLegacyCrlfHookCount -ne 0 -or $projectLegacyTokenHookCount -ne 0) {
        throw "CVS 專案仍包含受管理的舊 Hook：NotificationStop=$projectNotificationStopHookCount LegacyCrlf=$projectLegacyCrlfHookCount LegacyToken=$projectLegacyTokenHookCount"
    }
    $projectHasLineEndingHooks = $projectLineEndingPreToolUseHookCount -eq 1 -and $projectLineEndingPostToolUseHookCount -eq 1 -and $projectLineEndingStopHookCount -in @(0, 1)
    if ($DevelopmentEnvironment -eq 'CVS') {
        if ($projectHasLineEndingHooks) {
            if ($trackHookCount -ne 0 -or $restoreHookCount -ne 0 -or $finalizeHookCount -ne 0 -or $preserveScriptCount -ne 1 -or $legacyHookCount -ne 0) { throw 'CVS 專案 Hook 已接管換行保護，但全域仍保留重複或不完整的換行 Hook。' }
        } elseif ($trackHookCount -ne 1 -or $restoreHookCount -ne 1 -or $finalizeHookCount -ne 1 -or $preserveScriptCount -ne 1 -or $legacyHookCount -ne 0) {
            throw "CVS 換行保護安裝檢查失敗：TrackHookCount=$trackHookCount RestoreHookCount=$restoreHookCount FinalizeHookCount=$finalizeHookCount PreserveLineEndingScriptCount=$preserveScriptCount LegacyCrlfHookCount=$legacyHookCount"
        }
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
        ProjectLineEndingPreToolUseHookCount = $projectLineEndingPreToolUseHookCount
        ProjectLineEndingPostToolUseHookCount = $projectLineEndingPostToolUseHookCount
        ProjectLineEndingStopHookCount = $projectLineEndingStopHookCount
        GlobalLineEndingPreToolUseHookCount = $trackHookCount
        GlobalLineEndingPostToolUseHookCount = $restoreHookCount
        GlobalLineEndingStopHookCount = $finalizeHookCount
        LegacyCrlfHookCount = $legacyCrlfHookCount
        LegacyTokenHookCount = $legacyTokenHookCount
        DuplicateManagedHookCount = [Math]::Max(0, $notificationQuestionHookCount - 1) + [Math]::Max(0, $notificationPermissionHookCount - 1) + [Math]::Max(0, $notificationCompletedHookCount - 1) + [Math]::Max(0, $trackHookCount - 1) + [Math]::Max(0, $restoreHookCount - 1) + [Math]::Max(0, $finalizeHookCount - 1)
        DetachedToastCleanup = $detachedToastCleanup
    }
}
