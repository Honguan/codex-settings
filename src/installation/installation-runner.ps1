function Invoke-ManagementMode {
    param(
        [ValidateSet('Backup', 'Restore', 'Uninstall')]
        [string]$Mode,
        [string]$SourceRoot
    )

    $actionScripts = @{
        Backup = 'commands\backup-settings.ps1'
        Restore = 'commands\restore-settings.ps1'
        Uninstall = 'commands\uninstall-settings.ps1'
    }
    $actionScript = Join-Path $SourceRoot $actionScripts[$Mode]
    if (-not (Test-Path -LiteralPath $actionScript -PathType Leaf)) { throw "管理功能不存在：$actionScript" }
    if ($Mode -eq 'Restore') { & $actionScript }
    else { & $actionScript -Mode Global }
}

function Invoke-InteractiveMode {
    param(
        [ValidateSet('Git', 'CVS')]
        [string]$DevelopmentEnvironment,
        [string]$TargetUserProfile,
        [string]$GlobalRoot,
        [string]$SourceRoot
    )

    while ($true) {
        try {
            $selection = Select-Mode
            if ($selection -eq 'Exit') { return }

            if ($selection -eq 'Global') {
                $style = Select-InstallStyle
                $selectedEnvironment = Select-DevelopmentEnvironment -Default $DevelopmentEnvironment
                Write-Host ''
                Write-Host ('=' * 60)
                Write-Host '個人 Codex Settings'
                Write-Host ('=' * 60)
                Write-Host '核心設定                         自動安裝／更新'
                $requestUserInputAction = Select-OptionalDefaultModeRequestUserInput -AlreadyInstalled:(Test-DefaultModeRequestUserInputInstalled -Root $GlobalRoot)
                $longRunningAsyncWaitAction = Select-LongRunningAsyncWaitPolicy -Root $GlobalRoot -SourceRoot $SourceRoot
                Write-Host ''
                Write-Host ('=' * 60)
                Write-Host '社區／開源元件'
                Write-Host ('=' * 60)
                $windowsNotificationState = Get-WindowsNotificationLifecycleState -Root $GlobalRoot
                $windowsNotificationsAction = if ($windowsNotificationState.State -notin @('NotInstalled', 'TrueUnmanagedConflict', 'MalformedUserOwnedState', 'Conflict', 'Unknown')) { 'Uninstall' } else { 'SkipNotInstalled' }
                $usageToolsAction = Select-OptionalUsageTools -SourceRoot $SourceRoot
                $mattPocockSkillsAction = Select-OptionalMattPocockSkills
                . (Get-OptionalInstallationScriptPath -Name Ponytail)
                $ponytailState = Get-PonytailInstallationState -Root $GlobalRoot
                $ponytailAction = Select-OptionalPonytail -AlreadyInstalled:([bool]$ponytailState.PluginPresent)
                $ponytailMarketplaceAction = 'Auto'
                if (Test-OptionalComponentKeepAction $ponytailAction) {
                    $ponytailMarketplaceAction = Select-PonytailMarketplaceAction -State $ponytailState
                    if ($ponytailMarketplaceAction -eq 'Skip') { $ponytailAction = 'LeaveUnchanged' }
                }
                . (Get-OptionalInstallationScriptPath -Name CodexOrchestration)
                $codexOrchestrationAction = Select-OptionalCodexOrchestration -AlreadyInstalled:([bool](Get-CodexOrchestrationInstallationState).PluginPresent)
                . (Get-OptionalInstallationScriptPath -Name Serena)
                $serenaState = Get-SerenaInstallationState
                $serenaAction = Select-OptionalSerena -AlreadyInstalled:([bool]$serenaState.ToolPresent)
                $installSerenaUv = $false
                if (Test-OptionalComponentKeepAction $serenaAction) {
                    if (-not (Test-SerenaUvAvailable)) { $installSerenaUv = Select-SerenaUvInstallation }
                }
                $actions = @{ requestUserInput = $requestUserInputAction; longRunningAsyncWait = $longRunningAsyncWaitAction; windowsUsageNotifications = $windowsNotificationsAction; usageTools = $usageToolsAction; mattpocockSkills = $mattPocockSkillsAction; ponytail = $ponytailAction; codexOrchestration = $codexOrchestrationAction; serena = $serenaAction }
                Invoke-Installer -Mode Global -InstallStyle $style -DevelopmentEnvironment $selectedEnvironment -TargetUserProfile $TargetUserProfile -InstallMattPocockSkills:(Test-OptionalComponentKeepAction $mattPocockSkillsAction) -InstallPonytail:(Test-OptionalComponentKeepAction $ponytailAction) -PonytailState $ponytailState -PonytailMarketplaceAction $PonytailMarketplaceAction -InstallCodexOrchestration:(Test-OptionalComponentKeepAction $codexOrchestrationAction) -ConfigureCodexOrchestration:(Test-OptionalComponentKeepAction $codexOrchestrationAction) -InstallSerena:(Test-OptionalComponentKeepAction $serenaAction) -InstallSerenaUv:$installSerenaUv -EnableDefaultModeRequestUserInput:(Test-OptionalComponentKeepAction $requestUserInputAction) -LongRunningAsyncWaitAction $longRunningAsyncWaitAction -InstallWindowsNotifications:(Test-OptionalComponentKeepAction $windowsNotificationsAction) -InstallUsageTools:(Test-OptionalComponentKeepAction $usageToolsAction) -OptionalComponentActions $actions -SourceRoot $SourceRoot
                return
            }

            Invoke-ManagementMode -Mode $selection -SourceRoot $SourceRoot
        } catch {
            Write-Host "作業失敗：$($_.Exception.Message)" -ForegroundColor Red
        }

        Write-Host ''
        [void](Read-Host '按 Enter 返回安裝器選單')
    }
}

function Invoke-InstallationRollback($Transaction, $CcusageBefore, $Ponytail, $CodexOrchestration, [string]$Reason) {
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $Transaction) {
        try { Undo-FileTransaction $Transaction | Out-Null } catch { [void]$rollbackErrors.Add("File rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $CcusageBefore) {
        try { Restore-CcusageState $CcusageBefore | Out-Null } catch { [void]$rollbackErrors.Add("ccusage rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $Ponytail -and ([bool]$Ponytail.InstalledNow -or [bool]$Ponytail.MarketplaceAddedNow -or [bool]$Ponytail.MarketplaceSwitchedNow)) {
        try { Undo-PonytailInstallation -Result $Ponytail } catch { [void]$rollbackErrors.Add("Ponytail rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $CodexOrchestration -and [bool]$CodexOrchestration.InstalledNow) {
        try { Undo-CodexOrchestrationInstallation -Result $CodexOrchestration } catch { [void]$rollbackErrors.Add("Codex-Orchestration rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $Transaction) {
        try {
        Save-TransactionMetadata -Transaction $Transaction -Metadata @{
            Status = 'RolledBack'
            RolledBackAt = (Get-Date).ToString('o')
            FailureReason = $Reason
            RollbackErrors = $rollbackErrors.ToArray()
        }
        } catch { [void]$rollbackErrors.Add("Journal update failed: $($_.Exception.Message)") }
    }
    return $rollbackErrors.ToArray()
}

function Invoke-IsolatedCommunityComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('WindowsUsageNotifications', 'UsageTools', 'MattPocockSkills', 'Ponytail', 'CodexOrchestration', 'Serena')][string]$Name,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [scriptblock]$Validate,
        [scriptblock]$Commit,
        [scriptblock]$RollbackExternal
    )

    $transactionRoot = Join-Path $BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fffffff') + '-' + $Name)
    $transaction = New-FileTransaction -Root $transactionRoot -Mode ($Name + 'Transaction')
    $componentResult = $null
    try {
        $componentResult = & $Operation $transaction
        if ($null -ne $Validate) { & $Validate $componentResult }
        if ($null -ne $Commit) { & $Commit $transaction $componentResult }
        Complete-FileTransaction -Transaction $transaction
        return [pscustomobject]@{ Name = $Name; Status = 'SUCCESS'; Result = $componentResult; Error = $null; TransactionRoot = $transactionRoot; Rollback = 'N/A' }
    } catch {
        $reason = $_.Exception.Message
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
        try { Undo-FileTransaction -Transaction $transaction } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        if ($null -ne $RollbackExternal) {
            try { & $RollbackExternal $componentResult } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        }
        try { Save-TransactionMetadata -Transaction $transaction -Metadata @{ Status = 'RolledBack'; RolledBackAt = (Get-Date).ToString('o'); FailureReason = $reason; RollbackErrors = $rollbackErrors.ToArray() } } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        return [pscustomobject]@{ Name = $Name; Status = 'FAILED'; Result = $componentResult; Error = $reason; TransactionRoot = $transactionRoot; Rollback = $(if ($rollbackErrors.Count -eq 0) { 'SUCCESS' } else { 'FAILED' }); RollbackErrors = $rollbackErrors.ToArray() }
    }
}

function Invoke-WithInstallerUserEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][scriptblock]$Operation
    )

    $values = [ordered]@{ CODEX_HOME = $Context.GlobalRoot; HOME = $Context.UserProfile; USERPROFILE = $Context.UserProfile; APPDATA = $Context.AppData; LOCALAPPDATA = $Context.LocalAppData }
    $previous = @{}
    foreach ($name in $values.Keys) { $previous[$name] = [pscustomobject]@{ Present = Test-Path -LiteralPath "Env:\$name"; Value = [Environment]::GetEnvironmentVariable($name, 'Process') } }
    try {
        foreach ($name in $values.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$values[$name], 'Process') }
        return & $Operation
    } finally {
        foreach ($name in $values.Keys) {
            if ($previous[$name].Present) { [Environment]::SetEnvironmentVariable($name, [string]$previous[$name].Value, 'Process') }
            else { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-WindowsUsageNotificationFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)]$Transaction,
        [switch]$Remove
    )

    $manifest = Get-Manifest -Root $Root
    $fingerprints = @(Get-ManifestManagedHookFingerprints -Manifest $manifest -Kind Notification)
    $lifecycle = Get-WindowsNotificationLifecycleState -Root $Root -ManagedNotificationFingerprints $fingerprints
    if ($lifecycle.State -in @('TrueUnmanagedConflict', 'MalformedUserOwnedState', 'Unknown')) { throw (Format-WindowsNotificationLifecycleDiagnostic -Lifecycle $lifecycle) }
    $hooksPath = Join-Path $Root 'hooks.json'
    $configPath = Join-Path $Root 'config.toml'
    $scriptPath = Join-Path $Root 'hooks\show-codex-notification.ps1'
    $hooksState = Get-TextFileState -Path $hooksPath
    $changed = $false
    $configState = Get-TextFileState -Path $configPath
    $desiredConfig = Remove-WindowsNotificationCommandConfig -Content $configState.Content -RestorePrevious
    if (-not [string]::IsNullOrWhiteSpace($desiredConfig)) { $desiredConfig = $desiredConfig.TrimEnd() + $configState.NewLine }
    if ($desiredConfig -ne $configState.Content) {
        Save-TransactionFile -Transaction $Transaction -Path $configPath
        Write-TextFileState -Path $configPath -Content $desiredConfig -Encoding $configState.Encoding
        $changed = $true
    }
    $unownedBefore = Remove-ManagedNotificationHooksJson -Content $hooksState.Content -ManagedHookFingerprints $fingerprints
    $desiredHooks = $unownedBefore
    $desiredHooks = [regex]::Replace($desiredHooks, "`r`n|`r|`n", $hooksState.NewLine)
    if ($desiredHooks -ne $hooksState.Content) {
        Save-TransactionFile -Transaction $Transaction -Path $hooksPath
        Write-TextFileState -Path $hooksPath -Content $desiredHooks -Encoding $hooksState.Encoding
        $changed = $true
    }

    if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
        Save-TransactionFile -Transaction $Transaction -Path $scriptPath
        Remove-Item -LiteralPath $scriptPath -Force
        $changed = $true
    }

    $hooksAfter = (Get-TextFileState -Path $hooksPath).Content
    $unownedAfter = Remove-ManagedNotificationHooksJson -Content $hooksAfter
    $getUnownedFingerprints = {
        param([string]$Content)
        if ([string]::IsNullOrWhiteSpace($Content)) { return @() }
        $object = $Content | ConvertFrom-Json
        return @($object.hooks.PSObject.Properties | ForEach-Object { foreach ($group in @($_.Value)) { foreach ($entry in @(Get-HookHandlerEntries $group)) { Get-HookEntryFingerprint $entry } } } | Sort-Object)
    }
    $unownedFingerprintsBefore = @(& $getUnownedFingerprints $unownedBefore) -join "`n"
    $unownedFingerprintsAfter = @(& $getUnownedFingerprints $unownedAfter) -join "`n"
    if ($unownedFingerprintsBefore -ne $unownedFingerprintsAfter) { throw 'WindowsUsageNotifications 嘗試修改非自身擁有的 Hook。' }

    return [pscustomobject]@{ Managed = $false; HookCount = 0; ScriptPath = $scriptPath; Removed = $true; Changed = $changed }
}

function Write-InstallationSummary {
    param(
        [string]$InstallStyle,
        [string]$DevelopmentEnvironment,
        [object[]]$Results,
        $Ccusage,
        $CcusageBefore,
        $HookTrust,
        [string]$TransactionRoot,
        [bool]$InstallWindowsNotifications,
        [bool]$InstallUsageTools,
        $Progress,
        [string]$NotificationStatus = '',
        [string]$UsageStatus = '',
        [int]$SkippedCount = 0,
        [switch]$InstallMattPocockSkills,
        [switch]$EnableDefaultModeRequestUserInput,
        $LongRunningAsyncWait,
        [int]$SkillsCount = 0,
        $Ponytail,
        $CodexOrchestration,
        $Serena,
        $Ownership,
        [object[]]$CommunityResults = @(),
        [ValidateSet('SUCCESS', 'PARTIAL SUCCESS')][string]$OverallStatus = 'SUCCESS'
    )

    if ($null -ne $Progress) {
        if ($null -eq $LongRunningAsyncWait) { $LongRunningAsyncWait = [pscustomobject]@{ Status = 'SkippedNotInstalled'; Result = '本次不變更' } }
        if ($null -eq $Ownership) { $Ownership = New-InstallationOwnershipManifest -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -InstallWindowsNotifications:$InstallWindowsNotifications -InstallUsageTools:$InstallUsageTools -InstallMattPocockSkills:$InstallMattPocockSkills }
        $fileSummary = Get-InstallResultSummary -Results $Results
        $fileSummary.Skipped = [int]$fileSummary.Skipped + $SkippedCount
        $fileSummary.Footer = '請完全關閉並重新啟動 VS Code、Codex 與 PowerShell；config.toml／MCP 與 Hook 可能由既有程序快取，在舊 App 中建立新對話仍可能沿用修復前設定。'
        $notificationComponentStatus = if ($NotificationStatus -eq 'Uninstalled') { 'Uninstalled' } elseif (-not $InstallWindowsNotifications) { 'SkippedNotInstalled' } elseif ($NotificationStatus -match '略過|未變更') { 'Current' } else { 'Updated' }
        $usageComponentStatus = if ($UsageStatus -eq 'Uninstalled') { 'Uninstalled' } elseif (-not $InstallUsageTools) { 'SkippedNotInstalled' } elseif ($UsageStatus -match '未變更') { 'Current' } else { 'Updated' }
        $failedNames = @($CommunityResults | Where-Object Status -eq 'FAILED' | ForEach-Object Name)
        $components = @(
            [pscustomobject]@{ Category = 'Personal'; Name = 'Codex Settings'; Status = 'Validated'; Result = "Environment=$DevelopmentEnvironment" }
            [pscustomobject]@{ Category = 'Personal'; Name = 'request_user_input feature'; Status = [string]$Ownership.personal.requestUserInput.Status; Result = [string]$Ownership.personal.requestUserInput.Action }
            [pscustomobject]@{ Category = 'Other Settings'; Name = 'Long-running async wait policy'; Status = [string]$LongRunningAsyncWait.Status; Result = [string]$LongRunningAsyncWait.Result }
            [pscustomobject]@{ Category = 'Community'; Name = 'Windows 開發狀態通知'; Status = $(if ($failedNames -contains 'WindowsUsageNotifications') { 'Failed' } else { $notificationComponentStatus }); Result = $(if ($InstallWindowsNotifications) { $NotificationStatus } else { '未安裝' }) }
            [pscustomobject]@{ Category = 'Community'; Name = 'ccusage、ccsessions、cdaily 用量指令'; Status = $(if ($failedNames -contains 'UsageTools') { 'Failed' } else { $usageComponentStatus }); Result = $(if ($InstallUsageTools) { $UsageStatus } else { '未安裝' }) }
            [pscustomobject]@{ Category = 'Community'; Name = 'mattpocock/skills'; Status = $(if ($failedNames -contains 'MattPocockSkills') { 'Failed' } else { [string]$Ownership.community.mattpocockSkills.Status }); Result = [string]$Ownership.community.mattpocockSkills.Action }
        )
        $components += @(Get-PonytailInstallationComponents -Result $Ponytail | ForEach-Object { $_ | Add-Member -NotePropertyName Category -NotePropertyValue Community -PassThru })
        $components += @(Get-CodexOrchestrationInstallationComponents -Result $CodexOrchestration | ForEach-Object { $_ | Add-Member -NotePropertyName Category -NotePropertyValue Community -PassThru })
        $components += @(Get-SerenaInstallationComponents -Result $Serena | ForEach-Object { $_ | Add-Member -NotePropertyName Category -NotePropertyValue Community -PassThru })
        foreach ($component in $components) {
            if (($failedNames -contains 'Ponytail') -and $component.Name -match 'Ponytail') { $component.Status = 'Failed' }
            if (($failedNames -contains 'CodexOrchestration') -and $component.Name -match 'Codex-Orchestration') { $component.Status = 'Failed' }
            if (($failedNames -contains 'Serena') -and $component.Name -match 'Serena') { $component.Status = 'Failed' }
        }
        $fileSummary.PersonalResult = 'SUCCESS'
        $fileSummary.CommunityResult = if ($OverallStatus -eq 'SUCCESS') { 'SUCCESS' } else { 'PARTIAL SUCCESS' }
        $fileSummary.OverallResult = $OverallStatus
        $fileSummary.PersonalStats = [ordered]@{ Installed = $fileSummary.Installed; Updated = $fileSummary.Updated; Unchanged = $fileSummary.Unchanged; Skipped = $fileSummary.Skipped; Failed = $fileSummary.Failed }
        $communityStats = [ordered]@{ Installed = 0; Updated = 0; Unchanged = 0; Skipped = 0; Failed = 0 }
        foreach ($name in @('WindowsUsageNotifications', 'UsageTools', 'MattPocockSkills', 'Ponytail', 'CodexOrchestration', 'Serena')) {
            $result = @($CommunityResults | Where-Object Name -eq $name | Select-Object -Last 1)[0]
            if ($null -eq $result) { $communityStats.Skipped++; continue }
            if ($result.Status -eq 'FAILED') { $communityStats.Failed++ } else { $communityStats.Updated++ }
        }
        $fileSummary.CommunityStats = $communityStats
        Write-InstallLog -Progress $Progress -Message ("SUMMARY transaction={0}; components={1}; files={2}" -f $TransactionRoot, $components.Count, @($Results.Files).Count)
        Write-InstallResult -Progress $Progress -Status $OverallStatus -Summary $fileSummary -Results $Results -Components $components
    }
}

function Invoke-GlobalInstallation {
    param(
        $Context,
        [switch]$SkipCcusageInstall,
        [switch]$InstallMattPocockSkills,
        [switch]$InstallPonytail,
        [switch]$SkipPonytail,
        $PonytailState,
        [ValidateSet('Auto', 'Preserve', 'Switch', 'Skip')][string]$PonytailMarketplaceAction = 'Auto',
        [switch]$InstallCodexOrchestration,
        [switch]$SkipCodexOrchestration,
        [switch]$ConfigureCodexOrchestration,
        [switch]$InstallSerena,
        [switch]$SkipSerena,
        [switch]$InstallSerenaUv,
        [switch]$EnableDefaultModeRequestUserInput,
        [ValidateSet('Auto', 'Install', 'KeepCurrent', 'Update', 'Repair', 'Uninstall', 'SkipNotInstalled', 'LeaveUnchanged', 'Blocked')][string]$LongRunningAsyncWaitAction = 'Auto',
        [switch]$ForceValidation,
        [switch]$ForceNotificationTest,
        [ValidateSet('Auto', 'Interactive', 'Line')][string]$RendererMode = 'Auto',
        [hashtable]$OptionalComponentActions = @{}
    )

    foreach ($optionalScript in @('Ponytail', 'CodexOrchestration', 'Serena')) { . (Get-OptionalInstallationScriptPath -Name $optionalScript) }
    if ($null -eq $PonytailState) { $PonytailState = Get-PonytailInstallationState -Root $Context.GlobalRoot }
    $codexOrchestrationState = Get-CodexOrchestrationInstallationState
    $serenaState = Get-SerenaInstallationState
    $requestUserInputInstalled = Test-DefaultModeRequestUserInputInstalled -Root $Context.GlobalRoot
    $notificationManifest = Get-Manifest -Root $Context.GlobalRoot
    $notificationFingerprints = @(Get-ManifestManagedHookFingerprints -Manifest $notificationManifest -Kind Notification)
    $windowsNotificationState = Get-WindowsNotificationLifecycleState -Root $Context.GlobalRoot -ManagedNotificationFingerprints $notificationFingerprints
    $windowsNotificationsInstalled = $windowsNotificationState.State -notin @('NotInstalled', 'TrueUnmanagedConflict', 'MalformedUserOwnedState', 'Conflict', 'Unknown')
    $usageToolsState = Get-UsageToolsLifecycleState -SourceRoot $Context.ScriptRoot
    $usageToolsInstalled = $usageToolsState -ne 'NotInstalled'
    $mattPocockSkillsInstalled = Test-MattPocockSkillsInstalled
    $requestUserInputAction = Get-OptionalComponentPlanAction -ExplicitAction ([string]$OptionalComponentActions.requestUserInput) -Installed $requestUserInputInstalled -Requested ([bool]$EnableDefaultModeRequestUserInput)
    $windowsNotificationsAction = if ($windowsNotificationsInstalled) { 'Uninstall' } else { 'SkipNotInstalled' }
    $usageToolsAction = if ($OptionalComponentActions.ContainsKey('usageTools')) { [string]$OptionalComponentActions.usageTools } elseif ([bool]$Context.InstallUsageTools) { Resolve-OptionalComponentAction -State $usageToolsState } else { Get-OptionalComponentPlanAction -Installed $usageToolsInstalled -Requested $false }
    $mattPocockSkillsAction = Get-OptionalComponentPlanAction -ExplicitAction ([string]$OptionalComponentActions.mattpocockSkills) -Installed $mattPocockSkillsInstalled -Requested ([bool]$InstallMattPocockSkills)
    $ponytailAction = Get-OptionalComponentPlanAction -ExplicitAction ([string]$OptionalComponentActions.ponytail) -Installed ([bool]$PonytailState.PluginPresent) -Requested ([bool]$InstallPonytail)
    $codexOrchestrationAction = Get-OptionalComponentPlanAction -ExplicitAction ([string]$OptionalComponentActions.codexOrchestration) -Installed ([bool]$codexOrchestrationState.PluginPresent) -Requested ([bool]$InstallCodexOrchestration)
    $serenaAction = Get-OptionalComponentPlanAction -ExplicitAction ([string]$OptionalComponentActions.serena) -Installed ([bool]$serenaState.ToolPresent) -Requested ([bool]$InstallSerena)
    if ($OptionalComponentActions.ContainsKey('longRunningAsyncWait')) { $LongRunningAsyncWaitAction = [string]$OptionalComponentActions.longRunningAsyncWait }
    $EnableDefaultModeRequestUserInput = Test-OptionalComponentKeepAction $requestUserInputAction
    $Context.InstallWindowsNotifications = $false
    $Context.InstallUsageTools = Test-OptionalComponentKeepAction $usageToolsAction
    $InstallMattPocockSkills = Test-OptionalComponentKeepAction $mattPocockSkillsAction
    $InstallPonytail = Test-OptionalComponentKeepAction $ponytailAction
    $InstallCodexOrchestration = Test-OptionalComponentKeepAction $codexOrchestrationAction
    $InstallSerena = Test-OptionalComponentKeepAction $serenaAction
    $policyTemplate = Get-LongRunningAsyncWaitPolicyTemplate -SourceRoot $Context.ScriptRoot
    $agentsPath = Join-Path $Context.GlobalRoot 'AGENTS.md'
    $policyBefore = Get-LongRunningAsyncWaitPolicyState -Content $(if (Test-Path -LiteralPath $agentsPath -PathType Leaf) { [IO.File]::ReadAllText($agentsPath) } else { '' }) -ManagedContent $policyTemplate
    if ($LongRunningAsyncWaitAction -eq 'Auto') {
        $policyLifecycleState = switch ($policyBefore.Status) { 'NotInstalled' { 'NotInstalled' }; 'InstalledCurrent' { 'InstalledCurrent' }; 'InstalledNeedsUpdate' { 'InstalledUpdateAvailable' }; default { 'Conflict' } }
        $LongRunningAsyncWaitAction = Resolve-OptionalComponentAction -State $policyLifecycleState
    }
    $targets = @(New-InstallationPlan -DevelopmentEnvironment $Context.DevelopmentEnvironment -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -RequestUserInputAction $requestUserInputAction -LongRunningAsyncWaitAction $LongRunningAsyncWaitAction -InstallWindowsNotifications $false -ManageWindowsNotifications $true -WindowsNotificationAction $windowsNotificationsAction -SourceRoot $Context.ScriptRoot)
    $steps = New-InstallationProgressSteps -TargetCount $targets.Count -IncludeSkills:($mattPocockSkillsAction -notin @('SkipNotInstalled', 'LeaveUnchanged', 'Blocked')) -IncludePonytail:($ponytailAction -notin @('SkipNotInstalled', 'LeaveUnchanged', 'Blocked')) -IncludeCodexOrchestration:($codexOrchestrationAction -notin @('SkipNotInstalled', 'LeaveUnchanged', 'Blocked')) -IncludeSerena:($serenaAction -notin @('SkipNotInstalled', 'LeaveUnchanged', 'Blocked')) -IncludeNotifications:($windowsNotificationsAction -notin @('SkipNotInstalled', 'LeaveUnchanged', 'Blocked')) -IncludeUsageTools:($usageToolsAction -notin @('SkipNotInstalled', 'LeaveUnchanged', 'Blocked'))
    $progress = Start-InstallProgress -Steps $steps -Root $Context.GlobalRoot -Metadata @{
        Mode = 'Global'
        Environment = $Context.DevelopmentEnvironment
        InstallStyle = $Context.InstallStyle
    } -RendererMode $RendererMode
    $operationLock = $null
    $transaction = $null
    $ccusageBefore = $null
    $results = New-Object 'System.Collections.Generic.List[object]'
    $transactionRoot = $null
    $notificationStatus = ''
    $usageStatus = ''
    $skippedCount = 0
    $discovery = $null
    $changePlan = $null
    $currentSubOperation = ''
    $mattPocockSkillNames = @()
    $ponytail = New-PonytailSkippedResult
    $codexOrchestration = New-CodexOrchestrationSkippedResult
    $serena = New-SerenaSkippedResult
    $communityResults = New-Object 'System.Collections.Generic.List[object]'
    $personalCommitted = $false
    $ownership = New-InstallationOwnershipManifest -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -LongRunningAsyncWaitAction $LongRunningAsyncWaitAction -InstallWindowsNotifications:([bool]$Context.InstallWindowsNotifications) -InstallUsageTools:([bool]$Context.InstallUsageTools) -InstallMattPocockSkills:$InstallMattPocockSkills -InstallPonytail:$InstallPonytail -InstallCodexOrchestration:$InstallCodexOrchestration -InstallSerena:$InstallSerena
    $componentActions = [ordered]@{ requestUserInput = $requestUserInputAction; longRunningAsyncWait = $LongRunningAsyncWaitAction; windowsUsageNotifications = $windowsNotificationsAction; usageTools = $usageToolsAction; mattpocockSkills = $mattPocockSkillsAction; ponytail = $ponytailAction; codexOrchestration = $codexOrchestrationAction; serena = $serenaAction }
    $componentStates = [ordered]@{ requestUserInput = (Get-OptionalComponentState -Installed $requestUserInputInstalled); longRunningAsyncWait = $(switch ($policyBefore.Status) { 'NotInstalled' { 'NotInstalled' }; 'InstalledCurrent' { 'InstalledCurrent' }; 'InstalledNeedsUpdate' { 'InstalledUpdateAvailable' }; default { 'Conflict' } }); windowsUsageNotifications = [string]$windowsNotificationState.State; usageTools = [string]$usageToolsState; mattpocockSkills = (Get-OptionalComponentState -Installed $mattPocockSkillsInstalled); ponytail = (Get-OptionalComponentState -Installed ([bool]$PonytailState.PluginPresent)); codexOrchestration = (Get-OptionalComponentState -Installed ([bool]$codexOrchestrationState.PluginPresent)); serena = (Get-OptionalComponentState -Installed ([bool]$serenaState.ToolPresent)) }
    foreach ($id in $componentActions.Keys) {
        $category = if ($id -eq 'requestUserInput') { $ownership.personal } elseif ($id -eq 'longRunningAsyncWait') { $ownership.otherSettings } else { $ownership.community }
        $category[$id].Action = [string]$componentActions[$id]
        $category[$id].DiscoveredState = [string]$componentStates[$id]
    }
    foreach ($category in @($ownership.personal, $ownership.otherSettings, $ownership.community)) {
        foreach ($component in $category.Values) {
            $component.Status = switch ([string]$component.Action) { 'SkipNotInstalled' { 'SkippedNotInstalled' }; 'LeaveUnchanged' { 'LeftUnchanged' }; 'Blocked' { 'Blocked' }; default { if ([bool]$component.Selected -or [string]$component.Action -eq 'Uninstall') { 'PENDING' } else { 'SKIPPED' } } }
        }
    }

    try {
        Set-InstallProgress -Progress $progress -StepId 'Plan' -Detail '整理目標與外部套件狀態'
        $ccusageBefore = Get-CcusageState
        $serenaDashboardDiscovery = if ($InstallSerena) { $value = Get-SerenaConfigurationState; $value | Add-Member -NotePropertyName Selected -NotePropertyValue $true -PassThru } else { $null }
        $discovery = Get-InstallationDiscovery -Context $Context -Targets $targets -CcusageBefore $ccusageBefore -SerenaDashboard $serenaDashboardDiscovery
        Write-InstallationPlan -Progress $progress -Context $Context -Targets $targets -CcusageBefore $ccusageBefore -InstallMattPocockSkills:$InstallMattPocockSkills -InstallUsageTools:$Context.InstallUsageTools -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -LongRunningAsyncWaitAction $LongRunningAsyncWaitAction -OptionalComponentActions $componentActions -SerenaDashboard $serenaDashboardDiscovery
        $notificationMigrationPending = $windowsNotificationsAction -in @('Update', 'Repair') -and $windowsNotificationState.State -in @('InstalledNeedsMigration', 'InstalledUpdateAvailable', 'InstalledNeedsRepair', 'ManagedPartialState', 'ManagedDuplicateState')
        Write-InstallLog -Progress $progress -Message ("NOTIFICATION {0} plannedNotificationAction={1} validationPhase=PreCommunity migrationPending={2}" -f (Format-WindowsNotificationLifecycleDiagnostic -Lifecycle $windowsNotificationState), $windowsNotificationsAction, $notificationMigrationPending)
        Complete-InstallStep -Progress $progress -Result ("已建立 $($targets.Count) 個目標")

        Set-InstallProgress -Progress $progress -StepId 'Prerequisites' -Detail '驗證 PowerShell、Node.js、Codex 與目標目錄'
        Test-Prerequisites 'Global' $Context.GlobalRoot
        foreach ($target in $targets) { Test-DirectoryWritable -Path $target.Root }
        Complete-InstallStep -Progress $progress -Result '通過'

        Set-InstallProgress -Progress $progress -StepId 'Lock' -Detail '取得單一安裝操作鎖並回復中斷交易'
        $operationLock = Enter-CodexSettingsLock
        $recovered = @(Repair-PendingTransactions -BackupRoot $Context.BackupRoot)
        if ($recovered.Count -gt 0) { Write-InstallLog -Progress $progress -Message "RECOVERY restored=$($recovered.Count)" }
        Complete-InstallStep -Progress $progress -Result $(if ($recovered.Count -gt 0) { "已回復 $($recovered.Count) 筆交易" } else { '無待回復交易' })

        Set-InstallProgress -Progress $progress -StepId 'Backup' -Detail '建立交易目錄與外部狀態快照'
        New-Item -ItemType Directory -Path $Context.BackupRoot -Force | Out-Null
        $transactionRoot = Join-Path $Context.BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-personal-transaction')
        $transaction = New-FileTransaction -Root $transactionRoot -Mode 'PersonalTransaction'
        Save-TransactionMetadata -Transaction $transaction -Metadata @{
            Mode = 'Global'
            Status = 'InProgress'
            Discovery = $discovery
            CcusageBefore = $ccusageBefore
        }
        Complete-InstallStep -Progress $progress -Result '已建立交易備份'

        try {
            Set-InstallProgress -Progress $progress -StepId 'Targets' -Detail ("處理 $($targets.Count) 個全域安裝目標")
            foreach ($result in @(Invoke-InstallationPlan -Targets $targets -Transaction $transaction -Discovery $discovery -Force:$Context.Force)) { [void]$results.Add($result) }
            Complete-InstallStep -Progress $progress -Result ("完成 $($results.Count) 個目標")

            [object[]]$resultArray = $results.ToArray()
            $policyAfter = Get-LongRunningAsyncWaitPolicyState -Content ([IO.File]::ReadAllText($agentsPath)) -ManagedContent $policyTemplate
            if ((Test-OptionalComponentKeepAction $LongRunningAsyncWaitAction) -and $policyAfter.Status -ne 'InstalledCurrent') { throw "Long-running async wait policy 安裝驗證失敗：$($policyAfter.Status)" }
            if ($LongRunningAsyncWaitAction -eq 'Uninstall' -and $policyAfter.Status -ne 'NotInstalled') { throw "Long-running async wait policy 移除驗證失敗：$($policyAfter.Status)" }
            $asyncWaitStatus = switch ($LongRunningAsyncWaitAction) {
                'Install' { if ($policyBefore.Status -eq 'NotInstalled') { 'Installed' } elseif ($policyBefore.Status -eq 'InstalledCurrent') { 'Unchanged' } else { 'Updated' } }
                { $_ -in @('KeepCurrent', 'Update', 'Repair') } { if ($policyBefore.Status -eq 'InstalledCurrent') { 'Unchanged' } else { 'Updated' } }
                'Uninstall' { if ($policyBefore.ManagedBlockPresent) { 'Uninstalled' } else { 'Unchanged' } }
                'SkipNotInstalled' { 'SkippedNotInstalled' }
                default { 'LeftUnchanged' }
            }
            $asyncWaitResult = [pscustomobject]@{ Status = $asyncWaitStatus; Result = $(if ($LongRunningAsyncWaitAction -eq 'Uninstall') { '已移除受管理區塊' } elseif ($LongRunningAsyncWaitAction -in @('SkipNotInstalled', 'LeaveUnchanged', 'Blocked')) { '本次不變更' } else { '新 Session/Task 生效' }); State = $policyAfter }
            $asyncWaitOwner = $ownership.otherSettings.longRunningAsyncWait
            $asyncWaitOwner.Status = $asyncWaitStatus
            $asyncWaitOwner.version = $script:LongRunningAsyncWaitPolicyVersion
            $asyncWaitOwner.managedBlockPresent = [bool]$policyAfter.ManagedBlockPresent
            $ownership.personal.requestUserInput.Status = switch ($requestUserInputAction) { 'Install' { 'Installed' }; 'Uninstall' { 'Uninstalled' }; 'SkipNotInstalled' { 'SkippedNotInstalled' }; 'LeaveUnchanged' { 'LeftUnchanged' }; default { 'Current' } }
            $changePlan = New-InstallationChangePlan -Discovery $discovery -Results $resultArray -CcusageBefore $ccusageBefore -ForceValidation:$ForceValidation -Force:$Context.Force -ForceNotificationTest:$ForceNotificationTest -InstallMattPocockSkills:$InstallMattPocockSkills -InstallUsageTools:$Context.InstallUsageTools -SkipPackageInstall:$SkipCcusageInstall
            Save-TransactionMetadata -Transaction $transaction -Metadata @{ ChangePlan = $changePlan }
            Write-InstallLog -Progress $progress -Message ("WORKFLOW PLAN level={0}; hooksChanged={1}; configChanged={2}; usageToolsChanged={3}; notificationTest={4}" -f $changePlan.validationLevel, $changePlan.hooksChanged, $changePlan.configChanged, $changePlan.usageToolsChanged, $changePlan.runNotificationTest)

            Set-InstallProgress -Progress $progress -StepId 'Hooks' -Detail '驗證受管理 Hook 狀態；未變更時略過昂貴的 trust 呼叫'
            $currentSubOperation = 'ResolveGlobalResult'
            Write-InstallLog -Progress $progress -Message "HOOKS subOperation=$currentSubOperation"
            $global = @($resultArray | Where-Object Mode -eq 'Global' | Select-Object -First 1)[0]

            $currentSubOperation = 'WorkflowDecision'
            Write-InstallLog -Progress $progress -Message "HOOKS subOperation=$currentSubOperation"
            $runHookTrust = Test-CodexWorkflowDecision -Plan $changePlan -Operation HookTrust
            if ($runHookTrust) {
                $currentSubOperation = 'HookTrust'
                Write-InstallLog -Progress $progress -Message "HOOKS subOperation=$currentSubOperation"
                $hookTrust = Set-CodexSettingsHookTrust -Root $Context.GlobalRoot -Cwd $Context.GlobalRoot -Kind Personal
            } else {
                $hookTrust = [pscustomobject]@{ TrustedCount = 0; UpdatedCount = 0; Verified = $true; Skipped = $true }
                Write-InstallLog -Progress $progress -Message 'HOOK TRUST skipped; no managed Hook changes detected'
            }

            $currentSubOperation = 'ConfigValidation'
            Write-InstallLog -Progress $progress -Message "HOOKS subOperation=$currentSubOperation"
            $configEntry = @($global.Files | Where-Object Path -eq 'config.toml' | Select-Object -First 1)[0]
            if ($null -ne $configEntry -and (Test-CodexWorkflowDecision -Plan $changePlan -Operation ConfigValidation)) {
                $configHash = (Get-FileHash -LiteralPath (Join-Path $Context.GlobalRoot 'config.toml') -Algorithm SHA256).Hash
                if ([string]$configEntry.Sha256 -ne $configHash) { $configEntry.Changed = $true; $configEntry.Status = 'Updated' }
                $configEntry.Sha256 = $configHash
            }

            $currentSubOperation = 'InstallationResultValidation'
            Write-InstallLog -Progress $progress -Message "HOOKS subOperation=$currentSubOperation"
            $changedResults = @($resultArray | Where-Object { $_.Summary.Created -gt 0 -or $_.Summary.Updated -gt 0 })
            $validateResults = $changePlan.validationLevel -ne 'Fast' -or $changedResults.Count -gt 0
            if ($validateResults) {
                foreach ($result in $resultArray) {
                    $result.validation = Get-InstallationVerificationResult -Result $result
                    if (-not [bool]$result.validation.Valid) { throw "安裝結果驗證失敗：$($result.validation.errors -join '; ')" }
                }
            } else {
                Write-InstallLog -Progress $progress -Message 'VALIDATION skipped; no managed content changes detected'
            }
            Complete-InstallStep -Progress $progress -Result $(if ($hookTrust.Skipped) { 'Hook 未變更，略過重新 trust' } else { "已驗證 $($hookTrust.TrustedCount) 個" })
            $currentSubOperation = ''

            Set-InstallProgress -Progress $progress -StepId 'PersonalCheckpoint' -Detail '驗證並提交個人 Codex Settings'
            foreach ($component in $ownership.personal.Values) { if ([bool]$component.Selected -and [string]$component.Status -eq 'PENDING') { $component.Status = 'SUCCESS' } }
            Complete-Installation -Results $resultArray -Transaction $transaction -Ownership $ownership -FinalizeTransaction | Out-Null
            $personalCommitted = $true
            Complete-InstallStep -Progress $progress -Result 'Personal 已提交；後續社區元件不會回滾此階段'

            $ccusage = New-CcusageUnchangedResult -PackageState $ccusageBefore
            if ($windowsNotificationsAction -eq 'Uninstall') {
                Set-InstallProgress -Progress $progress -StepId 'Notifications' -Detail '解除安裝受管理通知'
                $component = Invoke-IsolatedCommunityComponent -Name WindowsUsageNotifications -BackupRoot $Context.BackupRoot -Operation {
                    param($componentTransaction)
                    $files = Invoke-WindowsUsageNotificationFiles -Root $Context.GlobalRoot -SourceRoot $Context.ScriptRoot -Transaction $componentTransaction -Remove
                    [pscustomobject]@{ Files = $files; NotificationStatus = 'Uninstalled'; HookTrust = [pscustomobject]@{ Hooks = @() }; NotificationProbe = $null }
                }
                [void]$communityResults.Add($component)
                $ownership.community.windowsUsageNotifications.Status = $(if ($component.Status -eq 'SUCCESS') { 'Uninstalled' } else { 'FAILED' })
                if ($component.Status -eq 'SUCCESS') { $notificationStatus = 'Uninstalled'; Complete-InstallStep -Progress $progress -Result 'Uninstalled' } else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            }

            if ($usageToolsAction -eq 'Uninstall') {
                Set-InstallProgress -Progress $progress -StepId 'UsageTools' -Detail '解除安裝 ccusage、ccsessions、cdaily 用量指令'
                $component = Invoke-IsolatedCommunityComponent -Name UsageTools -BackupRoot $Context.BackupRoot -Operation {
                    param($componentTransaction)
                    $profileEntries = if ($null -ne $global.Previous -and $null -ne $global.Previous.External -and $null -ne $global.Previous.External.PowerShellProfiles) { @($global.Previous.External.PowerShellProfiles) } else { @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ Path = $_; ExistedBefore = $true } } }
                    $changed = $false
                    foreach ($profile in $profileEntries) {
                        $profilePath = [string]$profile.Path
                        if ([string]::IsNullOrWhiteSpace($profilePath) -or -not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { continue }
                        $state = Get-TextFileState -Path $profilePath
                        $newContent = Remove-CcusageProfileBlocks -Content $state.Content
                        if ($newContent -eq $state.Content) { continue }
                        Save-TransactionFile -Transaction $componentTransaction -Path $profilePath
                        if ([string]::IsNullOrWhiteSpace($newContent) -and -not [bool]$profile.ExistedBefore) { Remove-Item -LiteralPath $profilePath -Force }
                        else { Write-TextFileState -Path $profilePath -Content $(if ([string]::IsNullOrWhiteSpace($newContent)) { '' } else { $newContent.TrimEnd() + $state.NewLine }) -Encoding $state.Encoding }
                        $changed = $true
                    }
                    $previousPackage = if ($null -ne $global.Previous -and $null -ne $global.Previous.External -and $null -ne $global.Previous.External.Ccusage) { $global.Previous.External.Ccusage } else { $null }
                    $restoreState = if ($null -ne $previousPackage -and [bool]$previousPackage.Managed) { [pscustomobject]@{ Installed = [bool]$previousPackage.WasInstalledBefore; Version = [string]$previousPackage.PreviousVersion } } else { $ccusageBefore }
                    if ($null -ne $previousPackage -and [bool]$previousPackage.Managed) { Restore-CcusageState -State $restoreState }
                    [pscustomobject]@{ Ccusage = (New-CcusageUnchangedResult -PackageState $restoreState); CommandsUpdated = $changed; PackageInstalledNow = $false; Status = 'Uninstalled' }
                } -RollbackExternal { param($ignored) Restore-CcusageState -State $ccusageBefore | Out-Null }
                [void]$communityResults.Add($component)
                $ownership.community.usageTools.Status = $(if ($component.Status -eq 'SUCCESS') { 'Uninstalled' } else { 'FAILED' })
                if ($component.Status -eq 'SUCCESS') { $ccusage = $component.Result.Ccusage; $usageStatus = 'Uninstalled'; Complete-InstallStep -Progress $progress -Result 'Uninstalled' } else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            } elseif ($Context.InstallUsageTools) {
                Set-InstallProgress -Progress $progress -StepId 'UsageTools' -Detail '安裝／更新 ccusage、ccsessions、cdaily 用量指令'
                $component = Invoke-IsolatedCommunityComponent -Name UsageTools -BackupRoot $Context.BackupRoot -Operation {
                    param($componentTransaction)
                    $usage = & (Join-Path $Context.ScriptRoot 'integrations\install-usage-tools.ps1') -SkipPackageInstall:$SkipCcusageInstall -ForceRuntimeValidation:$ForceValidation -PackageState $ccusageBefore -Transaction $componentTransaction -PassThru -InformationAction Ignore
                    [pscustomobject]@{ Ccusage = $usage; CommandsUpdated = [bool]$usage.CommandsUpdated; PackageInstalledNow = [bool]$usage.PackageInstalledNow; Status = 'Installed' }
                } -RollbackExternal { param($ignored) Restore-CcusageState -State $ccusageBefore | Out-Null }
                [void]$communityResults.Add($component)
                $ownership.community.usageTools.Status = $(if ($component.Status -eq 'SUCCESS') { 'SUCCESS' } else { 'FAILED' })
                if ($component.Status -eq 'SUCCESS') { $ccusage = $component.Result.Ccusage; $usageStatus = if ($component.Result.CommandsUpdated -or $component.Result.PackageInstalledNow) { '已更新用量指令' } else { '套件與指令未變更' }; Complete-InstallStep -Progress $progress -Result $usageStatus } else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            }

            if ($mattPocockSkillsAction -eq 'Uninstall') {
                Set-InstallProgress -Progress $progress -StepId 'Skills' -Detail '解除安裝 mattpocock/skills 管理的技能'
                $component = Invoke-IsolatedCommunityComponent -Name MattPocockSkills -BackupRoot $Context.BackupRoot -Operation { param($componentTransaction) Invoke-MattPocockSkillsUninstall }
                [void]$communityResults.Add($component)
                $ownership.community.mattpocockSkills.Status = $(if ($component.Status -eq 'SUCCESS') { [string]$component.Result.Status } else { 'FAILED' })
                if ($component.Status -eq 'SUCCESS') { Complete-InstallStep -Progress $progress -Result ([string]$component.Result.Status) } else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            } elseif ($InstallMattPocockSkills) {
                Set-InstallProgress -Progress $progress -StepId 'Skills' -Detail '只在選用或偵測到既有技能時執行 npx'
                $component = Invoke-IsolatedCommunityComponent -Name MattPocockSkills -BackupRoot $Context.BackupRoot -Operation {
                    param($componentTransaction)
                    $names = @(Get-MattPocockSkillNames)
                    $skillsArguments = @(Get-MattPocockSkillsArguments)
                    $skillsOutput = & npx @skillsArguments 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "mattpocock/skills 安裝失敗，結束碼：$LASTEXITCODE" }
                    [pscustomobject]@{ Names = $names; Output = $skillsOutput }
                }
                [void]$communityResults.Add($component)
                $ownership.community.mattpocockSkills.Status = $(if ($component.Status -eq 'SUCCESS') { if ($mattPocockSkillsInstalled) { 'Updated' } else { 'Installed' } } else { 'FAILED' })
                if ($component.Status -eq 'SUCCESS') { $mattPocockSkillNames = @($component.Result.Names); Complete-InstallStep -Progress $progress -Result ("已處理 $($mattPocockSkillNames.Count) 個技能") }
                else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            }

            if ($ponytailAction -eq 'Uninstall') {
                Set-InstallProgress -Progress $progress -StepId 'Ponytail' -Detail '解除安裝 Ponytail plugin 與專用 marketplace'
                $component = Invoke-IsolatedCommunityComponent -Name Ponytail -BackupRoot $Context.BackupRoot -Operation { param($componentTransaction) Invoke-PonytailUninstall -State $PonytailState }
                [void]$communityResults.Add($component)
                $ownership.community.ponytail.Status = $(if ($component.Status -eq 'SUCCESS') { [string]$component.Result.Status } else { 'FAILED' })
                if ($component.Status -eq 'SUCCESS') { $ponytail = $component.Result; Complete-InstallStep -Progress $progress -Result ([string]$ponytail.Status) } else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            } elseif ($InstallPonytail) {
                Set-InstallProgress -Progress $progress -StepId 'Ponytail' -Detail '更新 marketplace、同步 plugin 並驗證 lifecycle hooks'
                $component = Invoke-IsolatedCommunityComponent -Name Ponytail -BackupRoot $Context.BackupRoot -Operation {
                    param($componentTransaction)
                    [void](Assert-PonytailPrerequisites)
                    Invoke-PonytailInstallation -State $PonytailState -Root $Context.GlobalRoot -MarketplaceAction $PonytailMarketplaceAction
                } -Validate { param($value) if ($value.ValidationStatus -ne 'Validated') { throw $(if ($value.ValidationError) { [string]$value.ValidationError } else { 'Ponytail lifecycle hooks 驗證失敗。' }) } } -RollbackExternal { param($value) if ($null -ne $value) { Undo-PonytailInstallation -Result $value } }
                [void]$communityResults.Add($component)
                $ownership.community.ponytail.Status = $component.Status
                if ($component.Status -eq 'SUCCESS') { $ponytail = $component.Result; Complete-InstallStep -Progress $progress -Result ($ponytail.PluginStatus + '; hooks ' + $ponytail.HookCount) }
                else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            }

            if ($codexOrchestrationAction -eq 'Uninstall') {
                Set-InstallProgress -Progress $progress -StepId 'CodexOrchestration' -Detail '解除安裝 Codex-Orchestration plugin'
                $component = Invoke-IsolatedCommunityComponent -Name CodexOrchestration -BackupRoot $Context.BackupRoot -Operation { param($componentTransaction) Invoke-CodexOrchestrationUninstall }
                [void]$communityResults.Add($component)
                $ownership.community.codexOrchestration.Status = $(if ($component.Status -eq 'SUCCESS') { [string]$component.Result.Status } else { 'FAILED' })
                if ($component.Status -eq 'SUCCESS') { $codexOrchestration = $component.Result; Complete-InstallStep -Progress $progress -Result ([string]$codexOrchestration.Status) } else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            } elseif ($InstallCodexOrchestration) {
                Set-InstallProgress -Progress $progress -StepId 'CodexOrchestration' -Detail '檢查 Python、安裝/更新 plugin、處理 workflow 設定'
                $component = Invoke-IsolatedCommunityComponent -Name CodexOrchestration -BackupRoot $Context.BackupRoot -Operation { param($componentTransaction) [void](Assert-CodexOrchestrationPrerequisites); Invoke-CodexOrchestrationInstallation -Root $Context.GlobalRoot -InteractiveWorkflow:$ConfigureCodexOrchestration } -RollbackExternal { param($value) if ($null -ne $value) { Undo-CodexOrchestrationInstallation -Result $value } }
                [void]$communityResults.Add($component)
                $ownership.community.codexOrchestration.Status = $component.Status
                if ($component.Status -eq 'SUCCESS') {
                    $codexOrchestration = $component.Result
                    $owner = $ownership.community.codexOrchestration
                    $owner.pluginStatus = [string]$codexOrchestration.PluginStatus
                    $owner.workflowRequested = [bool]$codexOrchestration.WorkflowRequested
                    $owner.workflowStatus = [string]$codexOrchestration.WorkflowStatus
                    $owner.setupPrompt = [string]$codexOrchestration.SetupPrompt
                    $owner.actionRequired = [bool]$codexOrchestration.ActionRequired
                    $owner.lastVerified = [string]$codexOrchestration.LastVerified
                    Complete-InstallStep -Progress $progress -Result ($codexOrchestration.PluginStatus + '; workflow ' + $codexOrchestration.WorkflowStatus)
                }
                else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            }

            if ($serenaAction -eq 'Uninstall') {
                Set-InstallProgress -Progress $progress -StepId 'Serena' -Detail '解除安裝 Serena tool 與受管理 Codex MCP 區段'
                $component = Invoke-IsolatedCommunityComponent -Name Serena -BackupRoot $Context.BackupRoot -Operation { param($componentTransaction) Invoke-SerenaUninstall -Root $Context.GlobalRoot -Transaction $componentTransaction }
                [void]$communityResults.Add($component)
                $ownership.community.serena.Status = $(if ($component.Status -eq 'SUCCESS') { [string]$component.Result.ToolStatus } else { 'FAILED' })
                if ($component.Status -eq 'SUCCESS') { $serena = $component.Result; Complete-InstallStep -Progress $progress -Result ([string]$serena.ToolStatus) } else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            } elseif ($InstallSerena) {
                Set-InstallProgress -Progress $progress -StepId 'Serena' -Detail '檢查 uv、安裝或更新 Serena、初始化並安全設定 Codex MCP'
                $component = Invoke-IsolatedCommunityComponent -Name Serena -BackupRoot $Context.BackupRoot -Operation { param($componentTransaction) Invoke-SerenaInstallation -Root $Context.GlobalRoot -Transaction $componentTransaction -InstallUv:$InstallSerenaUv }
                [void]$communityResults.Add($component)
                $ownership.community.serena.Status = $component.Status
                if ($component.Status -eq 'SUCCESS') { $serena = $component.Result; Complete-InstallStep -Progress $progress -Result ($serena.ToolStatus + '; Dashboard auto-open ' + $serena.DashboardAutoOpenStatus + '; ' + $serena.CodexMcpStatus) }
                else { Fail-InstallStep -Progress $progress -Reason $component.Error -Continue }
            }

            $original = $ccusageBefore
            $installedByPackage = [bool]$ccusage.PackageInstalledNow
            $usageWasUninstalled = $usageStatus -eq 'Uninstalled'
            if ($null -ne $global.Previous -and $null -ne $global.Previous.External -and $null -ne $global.Previous.External.Ccusage) {
                $old = $global.Previous.External.Ccusage
                $original = [pscustomobject]@{ Installed = [bool]$old.WasInstalledBefore; Version = [string]$old.PreviousVersion }
                $installedByPackage = [bool]$old.InstalledByPackage
            }

            $external = [ordered]@{
                PowerShellProfiles = @($ccusage.ProfileStates)
                Ccusage = [ordered]@{
                    Managed = if ($usageWasUninstalled) { $false } else { $installedByPackage }
                    InstalledByPackage = if ($usageWasUninstalled) { $false } else { $installedByPackage }
                    WasInstalledBefore = if ($usageWasUninstalled) { [bool]$ccusage.PackageAfter.Installed } else { [bool]$original.Installed }
                    PreviousVersion = if ($usageWasUninstalled) { [string]$ccusage.PackageAfter.Version } else { [string]$original.Version }
                    CurrentVersion = [string]$ccusage.PackageAfter.Version
                    PackageInstalledNow = [bool]$ccusage.PackageInstalledNow
                }
                Ponytail = [ordered]@{ Managed = [bool]$ponytail.Managed; Marketplace = $script:PonytailMarketplaceSource; MarketplaceSource = [string]$ponytail.MarketplaceSource; MarketplaceStatus = [string]$ponytail.MarketplaceStatus; MarketplaceAddedNow = [bool]$ponytail.MarketplaceAddedNow; MarketplaceSwitchedNow = [bool]$ponytail.MarketplaceSwitchedNow; MarketplaceRecoveredNow = [bool]$ponytail.MarketplaceRecoveredNow; Plugin = $script:PonytailPluginId; WasInstalledBefore = [bool]$ponytail.WasInstalledBefore; InstalledNow = [bool]$ponytail.InstalledNow; UpdatedNow = [bool]$ponytail.UpdatedNow; HookCount = [int]$ponytail.HookCount; TrustedHookCount = [int]$ponytail.TrustedHookCount; HookIdentities = @($ponytail.HookIdentities); ValidationStatus = [string]$ponytail.ValidationStatus; TrustStatus = [string]$ponytail.TrustStatus }
                CodexOrchestration = [ordered]@{ pluginManaged = [bool]$codexOrchestration.Managed; pluginPresent = $codexOrchestration.PluginPresent; pluginStatus = [string]$codexOrchestration.PluginStatus; pluginUpdatedThisRun = [bool]$codexOrchestration.UpdatedNow; marketplace = $script:CodexOrchestrationMarketplaceSource; plugin = $script:CodexOrchestrationPluginId; workflowRequested = [bool]$codexOrchestration.WorkflowRequested; workflowManaged = [bool]$codexOrchestration.WorkflowManaged; workflowConfigured = [bool]$codexOrchestration.WorkflowConfigured; workflowEffective = [bool]$codexOrchestration.WorkflowEffective; workflowStatus = [string]$codexOrchestration.WorkflowStatus; workflowConfigurationSummary = [string]$codexOrchestration.WorkflowConfigurationSummary; setupPrompt = [string]$codexOrchestration.SetupPrompt; actionRequired = [bool]$codexOrchestration.ActionRequired; lastVerified = [string]$codexOrchestration.LastVerified }
                Serena = [ordered]@{ Managed = [bool]$serena.Managed; SelectedByUser = [bool]$serena.SelectedByUser; UvAvailable = [bool]$serena.UvAvailable; UvVersion = [string]$serena.UvVersion; VersionBefore = [string]$serena.VersionBefore; VersionAfter = [string]$serena.VersionAfter; InstalledNow = [bool]$serena.InstalledNow; UpdatedNow = [bool]$serena.UpdatedNow; InitializationStatus = [string]$serena.InitializationStatus; DashboardEnabled = ([string]$serena.DashboardStatus -eq 'Enabled'); DashboardAutoOpen = $false; DashboardConfigStatus = [string]$serena.DashboardConfigStatus; CodexMcpConfigured = ([string]$serena.CodexMcpStatus -eq 'Configured'); RuntimeVerified = $false }
            }

            $windowsOwner = $ownership.community.windowsUsageNotifications
            $previousWindowsOwner = if ($null -ne $global.Previous -and $null -ne $global.Previous.Community) { $global.Previous.Community.windowsUsageNotifications } else { $null }
            $windowsOwner.installedBefore = $null -ne $previousWindowsOwner -and [bool]$previousWindowsOwner.managedByInstaller
            $windowsOwner.installedNow = $windowsOwner.Status -eq 'SUCCESS' -and -not $windowsOwner.installedBefore
            $windowsOwner.updatedNow = $windowsOwner.Status -eq 'SUCCESS' -and $windowsOwner.installedBefore
            $windowsOwner.managedByInstaller = $windowsOwner.Status -eq 'SUCCESS' -or ($windowsOwner.Status -eq 'SKIPPED' -and $windowsOwner.installedBefore)
            $windowsOwner.hookCount = $(if ($windowsOwner.Status -eq 'SUCCESS') { 2 } elseif ($windowsOwner.managedByInstaller) { [int]$previousWindowsOwner.hookCount } else { 0 })
            $windowsOwner.hookValidation = $(if ($windowsOwner.Status -eq 'SUCCESS') { 'Validated' } elseif ($windowsOwner.managedByInstaller) { [string]$previousWindowsOwner.hookValidation } else { $windowsOwner.Status })
            $windowsOwner.lastVerified = $(if ($windowsOwner.Status -eq 'SUCCESS') { (Get-Date).ToString('o') } elseif ($windowsOwner.managedByInstaller) { [string]$previousWindowsOwner.lastVerified } else { $null })
            $windowsOwner.rollbackCapability = 'ComponentScoped'

            $usageOwner = $ownership.community.usageTools
            $previousUsageOwner = if ($null -ne $global.Previous -and $null -ne $global.Previous.Community) { $global.Previous.Community.usageTools } else { $null }
            $legacyUsageManaged = $null -ne $global.Previous -and $null -ne $global.Previous.External -and $null -ne $global.Previous.External.Ccusage -and [bool]$global.Previous.External.Ccusage.Managed
            $usageOwner.installedBefore = ($null -ne $previousUsageOwner -and [bool]$previousUsageOwner.managedByInstaller) -or $legacyUsageManaged
            $usageOwner.installedNow = $usageOwner.Status -eq 'SUCCESS' -and -not $usageOwner.installedBefore
            $usageOwner.updatedNow = $usageOwner.Status -eq 'SUCCESS' -and $usageOwner.installedBefore
            $usageOwner.managedByInstaller = $usageOwner.Status -eq 'SUCCESS' -or ($usageOwner.Status -in @('SKIPPED', '') -and $usageOwner.installedBefore)
            $usageOwner.packageStatus = if ($usageOwner.Status -eq 'SUCCESS') { if ($ccusage.PackageInstalledNow) { 'Installed' } else { 'Current' } } elseif ($usageOwner.managedByInstaller) { [string]$(if ($null -ne $previousUsageOwner) { $previousUsageOwner.packageStatus } else { 'Current' }) } else { $usageOwner.Status }
            $usageOwner.commandsStatus = if ($usageOwner.Status -eq 'SUCCESS') { if ($ccusage.CommandsUpdated) { 'Updated' } else { 'Current' } } elseif ($usageOwner.managedByInstaller) { [string]$(if ($null -ne $previousUsageOwner) { $previousUsageOwner.commandsStatus } else { 'Current' }) } else { $usageOwner.Status }
            $usageOwner.lastVerified = if ($usageOwner.Status -eq 'SUCCESS') { (Get-Date).ToString('o') } elseif ($usageOwner.managedByInstaller -and $null -ne $previousUsageOwner) { [string]$previousUsageOwner.lastVerified } else { $null }
            $usageOwner.rollbackCapability = 'ComponentScoped'

            foreach ($category in @($ownership.personal, $ownership.otherSettings, $ownership.community)) {
                foreach ($component in $category.Values) {
                    if ($component.Contains('LastResult')) { $component.LastResult = [string]$component.Status }
                    elseif ($component.Contains('lastResult')) { $component.lastResult = [string]$component.Status }
                }
            }

            Set-InstallProgress -Progress $progress -StepId 'Final' -Detail '寫入 Manifest 並完成交易驗證'
            $finalTransaction = New-FileTransaction -Root (Join-Path $Context.BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fffffff') + '-manifest')) -Mode 'ManifestTransaction'
            Complete-Installation -Results $resultArray -Transaction $finalTransaction -External $external -Ownership $ownership -FinalizeTransaction | Out-Null
            Complete-InstallStep -Progress $progress -Result 'Manifest 與交易驗證通過'
            $overallStatus = if (@($communityResults | Where-Object Status -eq 'FAILED').Count -gt 0 -or $codexOrchestration.ActionRequired) { 'PARTIAL SUCCESS' } else { 'SUCCESS' }
            Write-InstallationSummary -InstallStyle $Context.InstallStyle -DevelopmentEnvironment $Context.DevelopmentEnvironment -Results $resultArray -Ccusage $ccusage -CcusageBefore $ccusageBefore -HookTrust $hookTrust -TransactionRoot $transactionRoot -InstallWindowsNotifications $Context.InstallWindowsNotifications -InstallUsageTools $Context.InstallUsageTools -Progress $progress -NotificationStatus $notificationStatus -UsageStatus $usageStatus -SkippedCount $skippedCount -InstallMattPocockSkills:$InstallMattPocockSkills -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -LongRunningAsyncWait $asyncWaitResult -SkillsCount $mattPocockSkillNames.Count -Ponytail $ponytail -CodexOrchestration $codexOrchestration -Serena $serena -Ownership $ownership -CommunityResults $communityResults.ToArray() -OverallStatus $overallStatus
        } catch {
            $reason = $_.Exception.Message
            Write-InstallErrorRecord -Progress $progress -ErrorRecord $_ -CurrentSubOperation $currentSubOperation
            Fail-InstallStep -Progress $progress -Reason $reason
            $rollbackErrors = if ($personalCommitted) { @() } else { @(Invoke-InstallationRollback -Transaction $transaction -CcusageBefore $null -Ponytail $null -CodexOrchestration $null -Reason $reason) }
            $message = "Installation failed and rollback was attempted.`nReason: $reason"
            if ($rollbackErrors.Count -gt 0) { $message += "`nRollback errors:`n- " + ($rollbackErrors -join "`n- ") }
            $rollbackStatus = if ($rollbackErrors.Count -eq 0) { 'SUCCESS' } else { 'FAILED' }
            $failureSummary = Get-InstallResultSummary -Results $results.ToArray()
            $failureSummary.Rollback = if ($personalCommitted) { 'NOT REQUIRED (Personal retained)' } else { $rollbackStatus }
            Write-InstallResult -Progress $progress -Status FAILED -Summary $failureSummary -Results $results.ToArray()
            throw $message
        }
    } catch {
        if ($progress.Status -ne 'Failed') {
            $reason = $_.Exception.Message
            Write-InstallErrorRecord -Progress $progress -ErrorRecord $_ -CurrentSubOperation $currentSubOperation
            Fail-InstallStep -Progress $progress -Reason $reason
            $rollbackErrors = if ($personalCommitted) { @() } else { @(Invoke-InstallationRollback -Transaction $transaction -CcusageBefore $null -Ponytail $null -CodexOrchestration $null -Reason $reason) }
            $failureSummary = Get-InstallResultSummary -Results $results.ToArray()
            $failureSummary.Rollback = if ($personalCommitted) { 'NOT REQUIRED (Personal retained)' } elseif ($rollbackErrors.Count -eq 0) { 'SUCCESS' } else { 'FAILED' }
            Write-InstallResult -Progress $progress -Status FAILED -Summary $failureSummary -Results $results.ToArray()
            throw
        }
        throw
    } finally {
        Exit-CodexSettingsLock -Lock $operationLock
    }
}

function Invoke-Installer {
    [CmdletBinding()]
    param(
        [ValidateSet('Interactive', 'Global', 'Backup', 'Restore', 'Uninstall')]
        [string]$Mode = 'Interactive',
        [switch]$SkipCcusageInstall,
        [switch]$InstallMattPocockSkills,
        [switch]$InstallPonytail,
        [switch]$SkipPonytail,
        $PonytailState,
        [ValidateSet('Auto', 'Preserve', 'Switch', 'Skip')][string]$PonytailMarketplaceAction = 'Auto',
        [switch]$InstallCodexOrchestration,
        [switch]$SkipCodexOrchestration,
        [switch]$ConfigureCodexOrchestration,
        [switch]$InstallSerena,
        [switch]$SkipSerena,
        [switch]$InstallSerenaUv,
        [switch]$EnableDefaultModeRequestUserInput,
        [ValidateSet('Auto', 'Install', 'KeepCurrent', 'Update', 'Repair', 'Uninstall', 'SkipNotInstalled', 'LeaveUnchanged', 'Blocked')][string]$LongRunningAsyncWaitAction = 'Auto',
        [switch]$ForceValidation,
        [switch]$ForceNotificationTest,
        [switch]$NoPause,
        [Nullable[bool]]$InstallWindowsNotifications,
        [Nullable[bool]]$InstallUsageTools,
        [ValidateSet('Git', 'CVS')]
        [string]$DevelopmentEnvironment,
        [string]$TargetUserProfile,
        [switch]$Force,
        [ValidateSet('Merge', 'Replace')]
        [string]$InstallStyle = 'Merge',
        [string]$SourceRoot = '',
        [hashtable]$OptionalComponentActions = @{}
    )

    if ($InstallPonytail -and $SkipPonytail) { throw 'InstallPonytail 與 SkipPonytail 不可同時指定。' }
    if ($InstallCodexOrchestration -and $SkipCodexOrchestration) { throw 'InstallCodexOrchestration 與 SkipCodexOrchestration 不可同時指定。' }
    if ($ConfigureCodexOrchestration -and -not $InstallCodexOrchestration) { throw 'ConfigureCodexOrchestration 必須搭配 InstallCodexOrchestration。' }
    if ($InstallSerena -and $SkipSerena) { throw 'InstallSerena 與 SkipSerena 不可同時指定。' }
    if ($InstallPonytail -or $OptionalComponentActions.ponytail -eq 'Uninstall') { . (Get-OptionalInstallationScriptPath -Name Ponytail) }
    if ($InstallCodexOrchestration -or $OptionalComponentActions.codexOrchestration -eq 'Uninstall') { . (Get-OptionalInstallationScriptPath -Name CodexOrchestration) }
    if ($InstallSerena -or $OptionalComponentActions.serena -eq 'Uninstall') { . (Get-OptionalInstallationScriptPath -Name Serena) }
    if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = [string]$ScriptRoot }
    if ($Mode -in @('Backup', 'Restore', 'Uninstall')) {
        Invoke-ManagementMode -Mode $Mode -SourceRoot $SourceRoot
        return
    }

    $context = New-InstallerContext -SourceRoot $SourceRoot -DevelopmentEnvironment $DevelopmentEnvironment -TargetUserProfile $TargetUserProfile -InstallStyle $InstallStyle -Force:$Force -InstallWindowsNotifications $InstallWindowsNotifications -InstallUsageTools $InstallUsageTools
    Invoke-WithInstallerUserEnvironment -Context $context -Operation {
        if ($Mode -eq 'Interactive') {
            Invoke-InteractiveMode -DevelopmentEnvironment $context.DevelopmentEnvironment -TargetUserProfile $context.UserProfile -GlobalRoot $context.GlobalRoot -SourceRoot $context.ScriptRoot
            return
        }

        if (($InstallPonytail -or $OptionalComponentActions.ponytail -eq 'Uninstall') -and $null -eq $PonytailState) { $PonytailState = Get-PonytailInstallationState -Root $context.GlobalRoot }
        Invoke-GlobalInstallation -Context $context -SkipCcusageInstall:$SkipCcusageInstall -InstallMattPocockSkills:$InstallMattPocockSkills -InstallPonytail:$InstallPonytail -SkipPonytail:$SkipPonytail -PonytailState $PonytailState -PonytailMarketplaceAction $PonytailMarketplaceAction -InstallCodexOrchestration:$InstallCodexOrchestration -SkipCodexOrchestration:$SkipCodexOrchestration -ConfigureCodexOrchestration:$ConfigureCodexOrchestration -InstallSerena:$InstallSerena -SkipSerena:$SkipSerena -InstallSerenaUv:$InstallSerenaUv -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -LongRunningAsyncWaitAction $LongRunningAsyncWaitAction -ForceValidation:$ForceValidation -ForceNotificationTest:$ForceNotificationTest -RendererMode $(if ($NoPause) { 'Line' } else { 'Auto' }) -OptionalComponentActions $OptionalComponentActions
    }
}
