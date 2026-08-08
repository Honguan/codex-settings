function Invoke-TargetInstallation($Target, $Transaction, [switch]$Force) {
    if (-not (Test-Path -LiteralPath $Target.TemplateRoot -PathType Container)) { throw "找不到範本：$($Target.TemplateRoot)" }
    New-Item -ItemType Directory -Path $Target.Root -Force | Out-Null
    $transactionEntriesBeforeCleanup = $Transaction.Entries.Count
    $previous = Get-Manifest $Target.Root
    $managedNotificationFingerprints = @(Get-ManifestManagedHookFingerprints -Manifest $previous -Kind Notification)
    $managedTokenFingerprints = @(Get-ManifestManagedHookFingerprints -Manifest $previous -Kind Token)
    $managedHookFingerprints = @($managedNotificationFingerprints + $managedTokenFingerprints)
    $projectRoot = $null
    if ($Target.Mode -eq 'Global') {
        Remove-GlobalLineEndingHooks -Root $Target.Root -Transaction $Transaction
        Remove-ManagedGlobalNotificationHooks -Root $Target.Root -Transaction $Transaction -ManagedHookFingerprints $managedHookFingerprints
        $targetCwd = if ($Target.PSObject.Properties.Name -contains 'Cwd') { [string]$Target.Cwd } else { (Get-Location).Path }
        $projectRoot = Find-CvsProjectRoot -StartPath $targetCwd
        if (-not [string]::IsNullOrWhiteSpace($projectRoot)) { Remove-ManagedProjectHooks -StartPath $projectRoot -Transaction $Transaction -KeepCvsLineEndingHooks:($Target.DevelopmentEnvironment -eq 'CVS') -ManagedHookFingerprints $managedHookFingerprints | Out-Null }
    }
    $hookCleanupChanged = $Transaction.Entries.Count -gt $transactionEntriesBeforeCleanup
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $templatePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($templateEntry in Get-InstallTemplateEntries -Target $Target) {
        $relative = [string]$templateEntry.RelativePath
        [void]$templatePaths.Add($relative)
        $destination = Join-Path $Target.Root $relative
        $previousEntry = Get-ManifestEntry $previous $relative
        $state = Get-TextFileState $destination
        $strategy = Get-Strategy $Target.Mode $relative
        $beforeHash = if ($state.Exists) { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash } else { $null }
        $owned = $state.Exists -and $null -ne $previousEntry -and -not [string]::IsNullOrWhiteSpace([string]$previousEntry.Sha256) -and [string]$previousEntry.Sha256 -eq [string]$beforeHash
        $template = [string]$templateEntry.Content
        if ($template.Length -gt 0 -and $template[0] -eq [char]0xFEFF -and $state.Encoding.GetPreamble().Length -gt 0) { $template = $template.Substring(1) }
        $template = [regex]::Replace($template, "`r`n|`r|`n", $state.NewLine)
        $isOptionalFeatureConfig = $Target.Mode -eq 'Global' -and $relative -eq 'config.toml' -and [bool]$Target.EnableDefaultModeRequestUserInput
        if ($isOptionalFeatureConfig) { $template = Add-DefaultModeRequestUserInputFeature -Content $template -NewLine $state.NewLine }

        $desiredContent = $null
        if ($Force -and $state.Exists) {
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
                    Merge-HooksJson -ExistingContent $withoutLineEndingHooks -TemplateContent $template -RemoveManagedGlobalHooks -ManagedHookFingerprints $managedHookFingerprints
                }
            }
            if ($isOptionalFeatureConfig) { $desiredContent = Add-DefaultModeRequestUserInputFeature -Content $desiredContent -NewLine $state.NewLine }
        }

        $changed = -not $state.Exists -or $state.Content -ne $desiredContent
        if ($changed) {
            Save-TransactionFile -Transaction $Transaction -Path $destination
            Write-TextFileState -Path $destination -Content $desiredContent -Encoding $state.Encoding
        }
        $afterHash = if ($changed) { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash } else { $beforeHash }

        $status = if (-not $state.Exists) { 'Installed' } elseif ($changed) { 'Updated' } else { 'Unchanged' }
        [void]$entries.Add((New-InstallFileResult -Path $relative -RelativePath $relative -Strategy $strategy.Name -StartMarker $strategy.Start -EndMarker $strategy.End -ExistedBefore ([bool]$state.Exists) -Changed $changed -Created (-not $state.Exists) -Updated ([bool]($state.Exists -and $changed)) -Sha256Before $beforeHash -Sha256After $afterHash -Status $status -OriginalEncoding ([string]$state.EncodingName) -OriginalCodePage ([int]$state.CodePage)))
    }

    if ($null -ne $previous -and $null -ne $previous.Files) {
        foreach ($old in @($previous.Files)) {
            $oldPath = [string]$old.Path
            if ($templatePaths.Contains($oldPath)) { continue }
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

    if ($Target.Mode -eq 'Global') { Assert-GlobalLineEndingHook -DevelopmentEnvironment $Target.DevelopmentEnvironment -Root $Target.Root -InstallWindowsNotifications ([bool]$Target.InstallWindowsNotifications) -ProjectRoot $projectRoot -ManagedNotificationFingerprints $managedNotificationFingerprints -ManagedTokenFingerprints $managedTokenFingerprints | Out-Null }

    $hookPathsChanged = @($entries | Where-Object { $_.Changed -and ([string]$_.Path -eq 'hooks.json' -or [string]$_.Path -like 'hooks\*') }).Count -gt 0
    return New-InstallationResult -Mode $Target.Mode -Root $Target.Root -DevelopmentEnvironment $Target.DevelopmentEnvironment -Files $entries.ToArray() -Previous $previous -HookChanged ($hookPathsChanged -or $hookCleanupChanged) -TransactionId ([string]$Transaction.Root)
}
