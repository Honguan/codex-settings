function Install-Target($Target, $Transaction, [switch]$Force) {
    if (-not (Test-Path -LiteralPath $Target.Template -PathType Container)) { throw "找不到範本：$($Target.Template)" }
    New-Item -ItemType Directory -Path $Target.Root -Force | Out-Null
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
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $templatePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($templateEntry in Get-InstallTemplateEntries -Target $Target) {
        $relative = [string]$templateEntry.RelativePath
        [void]$templatePaths.Add($relative)
        $destination = Join-Path $Target.Root $relative
        $previousEntry = Get-ManifestEntry $previous $relative
        $owned = Test-Owned $previousEntry $destination
        $state = Get-TextFileState $destination
        $strategy = Get-Strategy $Target.Mode $relative
        $beforeHash = if ($state.Exists) { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash } else { $null }
        Save-TransactionFile -Transaction $Transaction -Path $destination
        $template = [string]$templateEntry.Content
        if ($template.Length -gt 0 -and $template[0] -eq [char]0xFEFF -and $state.Encoding.GetPreamble().Length -gt 0) { $template = $template.Substring(1) }
        $template = [regex]::Replace($template, "`r`n|`r|`n", $state.NewLine)
        $isOptionalFeatureConfig = $Target.Mode -eq 'Global' -and $relative -eq 'config.toml' -and [bool]$Target.EnableDefaultModeRequestUserInput
        if ($isOptionalFeatureConfig) { $template = Add-DefaultModeRequestUserInputFeature -Content $template -NewLine $state.NewLine }

        if ($Force -and $state.Exists) {
            Write-TextFileState -Path $destination -Content $template -Encoding $state.Encoding
        } elseif ($strategy.Name -eq 'replace') {
            if ($state.Exists -and -not $owned -and $state.Content -ne $template) {
                throw "拒絕覆寫未受管理的檔案：$destination"
            }
            Write-TextFileState -Path $destination -Content $template -Encoding $state.Encoding
        } else {
            $existing = if ($owned -and $null -ne $previous -and [int]$previous.Version -lt 2) { '' } else { $state.Content }
            switch ($strategy.Name) {
                'managed-block' {
                    if ($relative.Replace('\', '/').EndsWith('AGENTS.md')) {
                        $merged = Merge-ManagedMarkdownBlock $existing $template $strategy.Start $strategy.End $state.NewLine
                    } elseif ($relative.Replace('\', '/') -eq 'rules/default.rules') {
                        $rulesBase = Remove-LegacyDefaultRulesContent -ExistingContent $existing -NewLine $state.NewLine
                        $merged = Merge-ManagedBlock $rulesBase $template $strategy.Start $strategy.End $state.NewLine
                    } else {
                        $merged = Merge-ManagedBlock $existing $template $strategy.Start $strategy.End $state.NewLine
                    }
                }
                'managed-toml' {
                    $configBase = Remove-ManagedBlock -Content $existing -StartMarker '# >>> CODEX-SETTINGS: >>>' -EndMarker '# <<< CODEX-SETTINGS: <<<'
                    $merged = Merge-TomlTemplate $configBase $template $strategy.Start $strategy.End $state.NewLine
                }
                'managed-hooks' {
                    $withoutLineEndingHooks = Remove-ManagedLineEndingHooksJson -Content $existing
                    $merged = Merge-HooksJson -ExistingContent $withoutLineEndingHooks -TemplateContent $template -RemoveManagedGlobalHooks -ManagedHookFingerprints $managedHookFingerprints
                }
            }
            if ($isOptionalFeatureConfig) { $merged = Add-DefaultModeRequestUserInputFeature -Content $merged -NewLine $state.NewLine }
            Write-TextFileState $destination $merged $state.Encoding
        }

        [void]$entries.Add([pscustomobject]@{
            Path = $relative
            Strategy = $strategy.Name
            StartMarker = $strategy.Start
            EndMarker = $strategy.End
            ExistedBefore = [bool]$state.Exists
            OriginalEncoding = [string]$state.EncodingName
            OriginalCodePage = [int]$state.CodePage
            Sha256 = (Get-FileHash $destination -Algorithm SHA256).Hash
            Changed = $beforeHash -ne (Get-FileHash $destination -Algorithm SHA256).Hash
        })
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

    return [pscustomobject]@{ Mode = $Target.Mode; DevelopmentEnvironment = $Target.DevelopmentEnvironment; Root = $Target.Root; Previous = $previous; Files = $entries.ToArray() }
}

function Set-Context7Key([switch]$Skip, $PreviousManifest) {
    $name = 'CONTEXT7_API_KEY'
    $userBefore = [Environment]::GetEnvironmentVariable($name, 'User')
    $processBefore = [Environment]::GetEnvironmentVariable($name, 'Process')
    $createdNow = $false

    if ([string]::IsNullOrWhiteSpace($userBefore) -and -not $Skip) {
        Write-Host ''
        Write-Host 'Context7 API Key 為選填；設定後可提高使用額度。'
        $secure = Read-Host '輸入 Context7 API Key，或直接按 Enter 略過' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if (-not [string]::IsNullOrWhiteSpace($plain)) {
            [Environment]::SetEnvironmentVariable($name, $plain, 'User')
            [Environment]::SetEnvironmentVariable($name, $plain, 'Process')
            $createdNow = $true
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($userBefore)) {
        [Environment]::SetEnvironmentVariable($name, $userBefore, 'Process')
        Write-Host '使用既有的 CONTEXT7_API_KEY。'
    }

    $managedBefore = $false
    if ($null -ne $PreviousManifest -and $null -ne $PreviousManifest.External -and $null -ne $PreviousManifest.External.Context7) {
        $managedBefore = [bool]$PreviousManifest.External.Context7.CreatedByInstaller
    }
    return [pscustomobject]@{
        CreatedNow = $createdNow
        CreatedByInstaller = $managedBefore -or $createdNow
        UserBefore = $userBefore
        ProcessBefore = $processBefore
    }
}

function Write-Manifest($Result, $Transaction, $External) {
    $path = Join-Path $Result.Root '.codex-settings-manifest.json'
    Save-TransactionFile $Transaction $path
    $manifest = [ordered]@{
        Version = 5
        Mode = $Result.Mode
        DevelopmentEnvironment = $Result.DevelopmentEnvironment
        InstalledAt = (Get-Date).ToString('o')
        TargetRoot = $Result.Root
        Files = $Result.Files
    }
    if ($Result.Mode -eq 'Global') { $manifest.ManagedHooks = Get-ManagedHooksManifest -Root $Result.Root }
    if ($null -ne $External) { $manifest.External = $External }
    Write-JsonFileAtomic -Path $path -Value $manifest -Depth 14
}
