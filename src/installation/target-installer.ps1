function Invoke-TargetInstallation($Target, $Transaction, [switch]$Force, $PreviousManifest = $null) {
    if (-not (Test-Path -LiteralPath $Target.TemplateRoot -PathType Container)) { throw "找不到範本：$($Target.TemplateRoot)" }
    New-Item -ItemType Directory -Path $Target.Root -Force | Out-Null
    $transactionEntriesBeforeCleanup = $Transaction.Entries.Count
    $previous = if ($null -ne $PreviousManifest) { $PreviousManifest } else { Get-Manifest $Target.Root }
    $managedNotificationFingerprints = @(Get-ManifestManagedHookFingerprints -Manifest $previous -Kind Notification)
    $managedTokenFingerprints = @(Get-ManifestManagedHookFingerprints -Manifest $previous -Kind Token)
    $managedHookFingerprints = @($managedNotificationFingerprints + $managedTokenFingerprints)
    $projectRoot = $null
    if ($Target.Mode -eq 'Global') {
        Remove-GlobalLineEndingHooks -Root $Target.Root -Transaction $Transaction
        if ([bool]$Target.ManageWindowsNotifications) { Remove-ManagedGlobalNotificationHooks -Root $Target.Root -Transaction $Transaction -ManagedHookFingerprints $managedHookFingerprints }
        $targetCwd = if ($Target.PSObject.Properties.Name -contains 'Cwd') { [string]$Target.Cwd } else { (Get-Location).Path }
        $projectRoot = Find-CvsProjectRoot -StartPath $targetCwd
        if (-not [string]::IsNullOrWhiteSpace($projectRoot)) { Remove-ManagedProjectHooks -StartPath $projectRoot -Transaction $Transaction -PreserveNotifications:(-not [bool]$Target.ManageWindowsNotifications) -ManagedHookFingerprints $managedHookFingerprints | Out-Null }
    }
    $hookCleanupChanged = $Transaction.Entries.Count -gt $transactionEntriesBeforeCleanup
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $templatePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($templateEntry in Get-InstallTemplateEntries -Target $Target) {
        $relative = [string]$templateEntry.RelativePath
        [void]$templatePaths.Add($relative)
        $destination = Join-Path $Target.Root $relative
        $previousEntry = Get-ManifestEntry $previous $relative
        $strategy = Get-Strategy $Target.Mode $relative
        $template = [string]$templateEntry.Content
        $templateSha256 = Get-StringSha256 -Content $template
        $metadata = Get-FileMetadata -Path $destination
        $metadataKnown = $metadata.Exists -and $null -ne $previousEntry -and $previousEntry.PSObject.Properties.Name -contains 'fileLength' -and $previousEntry.PSObject.Properties.Name -contains 'lastWriteTimeUtcTicks'
        $metadataMatches = $metadataKnown -and [long]$previousEntry.fileLength -eq $metadata.Length -and [long]$previousEntry.lastWriteTimeUtcTicks -eq $metadata.LastWriteTimeUtcTicks
        $fastReplaceUnchanged = -not $Force -and $strategy.Name -eq 'replace' -and $metadataMatches -and [string]$previousEntry.templateSha256 -eq $templateSha256
        if ($fastReplaceUnchanged) {
            [void]$entries.Add((New-InstallFileResult -Path $relative -RelativePath $relative -Strategy $strategy.Name -ExistedBefore $true -Changed $false -Created $false -Updated $false -Sha256Before ([string]$previousEntry.Sha256) -Sha256After ([string]$previousEntry.Sha256) -TemplateSha256 $templateSha256 -FileLength $metadata.Length -LastWriteTimeUtcTicks $metadata.LastWriteTimeUtcTicks -Status 'Unchanged' -OriginalEncoding 'utf-8' -OriginalCodePage 65001))
            continue
        }
        $state = Get-TextFileState $destination
        $beforeHash = if (-not $state.Exists) { $null } elseif ($metadataMatches -and -not [string]::IsNullOrWhiteSpace([string]$previousEntry.Sha256)) { [string]$previousEntry.Sha256 } else { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash }
        $owned = $state.Exists -and $null -ne $previousEntry -and -not [string]::IsNullOrWhiteSpace([string]$previousEntry.Sha256) -and (($metadataMatches -and [string]$previousEntry.Sha256 -eq $beforeHash) -or [string]$previousEntry.Sha256 -eq [string]$beforeHash)
        if ($template.Length -gt 0 -and $template[0] -eq [char]0xFEFF -and $state.Encoding.GetPreamble().Length -gt 0) { $template = $template.Substring(1) }
        $template = [regex]::Replace($template, "`r`n|`r|`n", $state.NewLine)
        $isOptionalFeatureConfig = $Target.Mode -eq 'Global' -and $relative -eq 'config.toml' -and (Test-OptionalComponentKeepAction $Target.RequestUserInputAction)
        if ($isOptionalFeatureConfig) { $template = Add-DefaultModeRequestUserInputFeature -Content $template -NewLine $state.NewLine }

        $desiredContent = $null
        $preserveNotifications = $relative.Replace('\', '/') -eq 'hooks.json' -and -not [bool]$Target.ManageWindowsNotifications
        if ($preserveNotifications) {
            $desiredContent = Merge-HooksJson -ExistingContent (Remove-ManagedLineEndingHooksJson -Content $state.Content) -TemplateContent $template
        } elseif ($Force -and $state.Exists) {
            $desiredContent = $template
        } elseif ($strategy.Name -eq 'replace') {
            if ($state.Exists -and -not $owned -and $state.Content -ne $template) {
                throw "拒絕覆寫未受管理的檔案：$destination"
            }
            $desiredContent = $template
        } else {
            $existing = if ($owned -and $null -ne $previous -and [int]$previous.Version -lt 2) { '' } else { $state.Content }
            $desiredContent = switch ($strategy.Name) {
                'managed-block' {
                    if ($relative.Replace('\', '/').EndsWith('AGENTS.md')) {
                        Merge-ManagedMarkdownBlock $existing $template $strategy.Start $strategy.End $state.NewLine
                    } elseif ($relative.Replace('\', '/') -eq 'rules/default.rules') {
                        $rulesBase = Remove-LegacyDefaultRulesContent -ExistingContent $existing -NewLine $state.NewLine -SourceRoot $Target.SourceRoot
                        Merge-ManagedBlock $rulesBase $template $strategy.Start $strategy.End $state.NewLine
                    } else {
                        Merge-ManagedBlock $existing $template $strategy.Start $strategy.End $state.NewLine
                    }
                }
                'managed-toml' {
                    $configBase = Remove-ManagedBlock -Content $existing -StartMarker '# >>> CODEX-SETTINGS: >>>' -EndMarker '# <<< CODEX-SETTINGS: <<<'
                    Merge-TomlTemplate $configBase $template $strategy.Start $strategy.End $state.NewLine
                }
                'managed-hooks' {
                    $withoutLineEndingHooks = Remove-ManagedLineEndingHooksJson -Content $existing
                    Merge-HooksJson -ExistingContent $withoutLineEndingHooks -TemplateContent $template -RemoveManagedGlobalHooks:([bool]$Target.ManageWindowsNotifications) -ManagedHookFingerprints $managedHookFingerprints
                }
            }
            if ($isOptionalFeatureConfig) { $desiredContent = Add-DefaultModeRequestUserInputFeature -Content $desiredContent -NewLine $state.NewLine }
            elseif ($Target.Mode -eq 'Global' -and $relative -eq 'config.toml' -and $Target.RequestUserInputAction -eq 'Uninstall') { $desiredContent = Remove-DefaultModeRequestUserInputFeature -Content $desiredContent }
        }
        if ($Target.Mode -eq 'Global' -and $relative.Replace('\', '/') -eq 'config.toml') {
            if ([bool]$Target.ManageWindowsNotifications) {
                $desiredContent = if ([bool]$Target.InstallWindowsNotifications) { Merge-WindowsNotificationCommandConfig -Content $desiredContent -Root $Target.Root -NewLine $state.NewLine } else { Remove-WindowsNotificationCommandConfig -Content $desiredContent }
            } elseif (Test-WindowsNotificationCommandConfig -Content $state.Content -Root $Target.Root) {
                $desiredContent = Merge-WindowsNotificationCommandConfig -Content $desiredContent -Root $Target.Root -NewLine $state.NewLine
            }
        }
        if ($Target.Mode -eq 'Global' -and $relative.Replace('\', '/') -eq 'AGENTS.md') {
            $policyTemplate = Get-LongRunningAsyncWaitPolicyTemplate -SourceRoot $Target.SourceRoot
            $policyState = Get-LongRunningAsyncWaitPolicyState -Content $state.Content -ManagedContent $policyTemplate
            if (Test-OptionalComponentKeepAction $Target.LongRunningAsyncWaitAction) {
                $desiredContent = Set-LongRunningAsyncWaitPolicy -Content $desiredContent -ManagedContent $policyTemplate -Action Install -NewLine $state.NewLine
            } elseif ($Target.LongRunningAsyncWaitAction -eq 'Uninstall') {
                $desiredContent = Set-LongRunningAsyncWaitPolicy -Content $desiredContent -ManagedContent $policyTemplate -Action Remove -NewLine $state.NewLine
            } elseif ($policyState.ManagedBlockPresent) {
                $desiredContent = Set-LongRunningAsyncWaitPolicy -Content $desiredContent -ManagedContent $policyState.Content -Action Install -NewLine $state.NewLine
            } elseif ($policyState.Status -eq 'Conflict' -and $Force) {
                $desiredContent = $state.Content
            }
        }

        $changed = -not $state.Exists -or $state.Content -ne $desiredContent
        if ($changed) {
            Save-TransactionFile -Transaction $Transaction -Path $destination
            Write-TextFileState -Path $destination -Content $desiredContent -Encoding $state.Encoding
        }
        $afterHash = if ($changed) { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash } else { $beforeHash }
        $afterMetadata = Get-FileMetadata -Path $destination

        $status = if (-not $state.Exists) { 'Installed' } elseif ($changed) { 'Updated' } else { 'Unchanged' }
        [void]$entries.Add((New-InstallFileResult -Path $relative -RelativePath $relative -Strategy $strategy.Name -StartMarker $strategy.Start -EndMarker $strategy.End -ExistedBefore ([bool]$state.Exists) -Changed $changed -Created (-not $state.Exists) -Updated ([bool]($state.Exists -and $changed)) -Sha256Before $beforeHash -Sha256After $afterHash -TemplateSha256 $templateSha256 -FileLength $afterMetadata.Length -LastWriteTimeUtcTicks $afterMetadata.LastWriteTimeUtcTicks -Status $status -OriginalEncoding ([string]$state.EncodingName) -OriginalCodePage ([int]$state.CodePage)))
    }

    if ($null -ne $previous -and $null -ne $previous.Files) {
        foreach ($old in @($previous.Files)) {
            $oldPath = [string]$old.Path
            if ($templatePaths.Contains($oldPath)) { continue }
            if (-not [bool]$Target.ManageWindowsNotifications -and $oldPath.Replace('\', '/') -eq 'hooks/show-codex-notification.ps1') { continue }
            $obsolete = Join-Path $Target.Root $oldPath
            if (Test-Owned $old $obsolete) {
                Save-TransactionFile $Transaction $obsolete
                Remove-Item $obsolete -Force
            }
        }
    }

    if ($Target.Mode -eq 'Global' -and $Target.DevelopmentEnvironment -eq 'CVS' -and -not [string]::IsNullOrWhiteSpace($projectRoot)) {
        $projectHooksPath = Join-Path $projectRoot '.codex\hooks.json'
        if (Test-Path -LiteralPath $projectHooksPath -PathType Leaf) {
            $projectHooks = Get-Content -LiteralPath $projectHooksPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $projectPreHookCount = if ($null -ne $projectHooks.hooks -and $null -ne $projectHooks.hooks.PreToolUse) { @($projectHooks.hooks.PreToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count } else { 0 }
            $projectPostHookCount = if ($null -ne $projectHooks.hooks -and $null -ne $projectHooks.hooks.PostToolUse) { @($projectHooks.hooks.PostToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count } else { 0 }
            if ($projectPreHookCount -eq 1 -and $projectPostHookCount -eq 1) { Remove-GlobalLineEndingHookEntries -Root $Target.Root -Transaction $Transaction }
        }
    }

    if ($Target.Mode -eq 'Global') {
        $notificationsExpected = if ([bool]$Target.ManageWindowsNotifications) { [bool]$Target.InstallWindowsNotifications } else { Test-WindowsNotificationsInstalled -Root $Target.Root }
        Assert-GlobalLineEndingHook -DevelopmentEnvironment $Target.DevelopmentEnvironment -Root $Target.Root -InstallWindowsNotifications $notificationsExpected -ProjectRoot $projectRoot -ManagedNotificationFingerprints $managedNotificationFingerprints -ManagedTokenFingerprints $managedTokenFingerprints -ValidationPhase PreCommunity -PlannedNotificationAction ([string]$Target.WindowsNotificationAction) | Out-Null
    }

    $hookPathsChanged = @($entries | Where-Object { $_.Changed -and ([string]$_.Path -eq 'hooks.json' -or [string]$_.Path -like 'hooks\*') }).Count -gt 0
    return New-InstallationResult -Mode $Target.Mode -Root $Target.Root -DevelopmentEnvironment $Target.DevelopmentEnvironment -Files $entries.ToArray() -Previous $previous -HookChanged ($hookPathsChanged -or $hookCleanupChanged) -TransactionId ([string]$Transaction.Root)
}
