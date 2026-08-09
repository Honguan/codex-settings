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
                $installRequestExecutionOptimizer = Select-OptionalGlobalSkill
                $installMattPocockSkills = Select-OptionalMattPocockSkills
                $ponytailState = $null
                $installPonytail = Select-OptionalPonytail
                $ponytailMarketplaceAction = 'Auto'
                if ($installPonytail) {
                    . (Get-OptionalInstallationScriptPath -Name Ponytail)
                    $ponytailState = Get-PonytailInstallationState -Root $GlobalRoot
                    $ponytailMarketplaceAction = Select-PonytailMarketplaceAction -State $ponytailState
                    if ($ponytailMarketplaceAction -eq 'Skip') { $installPonytail = $false }
                }
                $installCodexOrchestration = Select-OptionalCodexOrchestration
                if ($installCodexOrchestration) { . (Get-OptionalInstallationScriptPath -Name CodexOrchestration) }
                $installSerena = Select-OptionalSerena
                $installSerenaUv = $false
                if ($installSerena) {
                    . (Get-OptionalInstallationScriptPath -Name Serena)
                    if (-not (Test-SerenaUvAvailable)) { $installSerenaUv = Select-SerenaUvInstallation }
                }
                $enableDefaultModeRequestUserInput = Select-OptionalDefaultModeRequestUserInput
                $installWindowsNotifications = Select-OptionalWindowsNotifications -AlreadyInstalled:(Test-WindowsNotificationsInstalled -Root $GlobalRoot)
                Invoke-Installer -Mode Global -InstallStyle $style -DevelopmentEnvironment $selectedEnvironment -InstallRequestExecutionOptimizer:$installRequestExecutionOptimizer -InstallMattPocockSkills:$installMattPocockSkills -InstallPonytail:$installPonytail -PonytailState $ponytailState -PonytailMarketplaceAction $ponytailMarketplaceAction -InstallCodexOrchestration:$installCodexOrchestration -ConfigureCodexOrchestration:$installCodexOrchestration -InstallSerena:$installSerena -InstallSerenaUv:$installSerenaUv -EnableDefaultModeRequestUserInput:$enableDefaultModeRequestUserInput -InstallWindowsNotifications:$installWindowsNotifications -SourceRoot $SourceRoot
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

function Invoke-InstallationRollback($Transaction, $CcusageBefore, $ContextState, $Ponytail, $CodexOrchestration, [string]$Reason) {
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $Transaction) {
        try { Undo-FileTransaction $Transaction | Out-Null } catch { [void]$rollbackErrors.Add("File rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $CcusageBefore) {
        try { Restore-CcusageState $CcusageBefore | Out-Null } catch { [void]$rollbackErrors.Add("ccusage rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $ContextState -and [bool]$ContextState.CreatedNow) {
        try {
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $ContextState.UserBefore, 'User')
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $ContextState.ProcessBefore, 'Process')
        } catch { [void]$rollbackErrors.Add("Context7 rollback failed: $($_.Exception.Message)") }
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
        $Progress,
        [string]$NotificationStatus = '',
        [int]$SkippedCount = 0,
        [switch]$SkipContext7Key,
        [switch]$InstallMattPocockSkills,
        [switch]$InstallRequestExecutionOptimizer,
        [switch]$EnableDefaultModeRequestUserInput,
        $ContextState,
        [int]$SkillsCount = 0,
        $Ponytail,
        $CodexOrchestration,
        $Serena
    )

    if ($null -ne $Progress) {
        $fileSummary = Get-InstallResultSummary -Results $Results
        $fileSummary.Skipped = [int]$fileSummary.Skipped + $SkippedCount
        $fileSummary.Footer = '請完全關閉並重新啟動 VS Code、Codex 與 PowerShell；既有 Session 不會載入新安裝的 Hook。'
        $ccusageStatus = if ([bool]$Ccusage.PackageInstalledNow) { 'Installed' } elseif ([bool]$CcusageBefore.Installed) { 'Existing' } else { 'SkippedByUser' }
        $commandStatus = if ([bool]$Ccusage.CommandsUpdated) { 'Updated' } else { 'Unchanged' }
        $context7Status = if ($SkipContext7Key) { 'SkippedByUser' } elseif ($null -ne $ContextState -and [bool]$ContextState.CreatedNow) { 'Installed' } elseif ($null -ne $ContextState -and [bool]$ContextState.CreatedByInstaller) { 'Existing' } else { 'Unchanged' }
        $hookStatus = if ([bool]$HookTrust.Skipped) { 'SkippedUnchanged' } elseif ([int]$HookTrust.UpdatedCount -gt 0) { 'Updated' } else { 'Validated' }
        $notificationComponentStatus = if (-not $InstallWindowsNotifications) { 'SkippedByUser' } elseif ($NotificationStatus -match '略過|未變更') { 'SkippedUnchanged' } else { 'Updated' }
        $components = @(
            [pscustomobject]@{ Name = 'Codex'; Status = 'Validated'; Result = "Environment=$DevelopmentEnvironment" }
            [pscustomobject]@{ Name = 'MCP / Context7'; Status = $context7Status; Result = $(if ($SkipContext7Key) { '使用者略過' } else { '環境設定已處理' }) }
            [pscustomobject]@{ Name = 'ccusage'; Status = $ccusageStatus; Result = [string]$Ccusage.PackageAfter.Version }
            [pscustomobject]@{ Name = 'ccsessions'; Status = $commandStatus; Result = $(if ($Ccusage.CommandsUpdated) { 'Profile 已更新' } else { 'Profile 未變更' }) }
            [pscustomobject]@{ Name = 'cdaily'; Status = $commandStatus; Result = $(if ($Ccusage.CommandsUpdated) { 'Profile 已更新' } else { 'Profile 未變更' }) }
            [pscustomobject]@{ Name = 'request-execution-optimizer'; Status = $(if ($InstallRequestExecutionOptimizer) { 'Enabled' } else { 'SkippedByUser' }); Result = $(if ($InstallRequestExecutionOptimizer) { '已選用' } else { '未選用' }) }
            [pscustomobject]@{ Name = 'mattpocock/skills'; Status = $(if ($InstallMattPocockSkills) { 'Updated' } else { 'SkippedByUser' }); Result = $(if ($InstallMattPocockSkills) { "已處理 $SkillsCount 個" } else { '未選用' }) }
            [pscustomobject]@{ Name = 'request_user_input feature'; Status = $(if ($EnableDefaultModeRequestUserInput) { 'Enabled' } else { 'SkippedByUser' }); Result = $(if ($EnableDefaultModeRequestUserInput) { '已啟用' } else { '未啟用' }) }
            [pscustomobject]@{ Name = 'Windows 開發狀態與使用量通知'; Status = $notificationComponentStatus; Result = $(if ($InstallWindowsNotifications) { $NotificationStatus + '（開發狀態 + Token / Cost 使用量）' } else { '未安裝' }) }
            [pscustomobject]@{ Name = 'Hook trust'; Status = $hookStatus; Result = $(if ($HookTrust.Skipped) { '未變更，略過重新 trust' } else { "已驗證 $($HookTrust.TrustedCount) 個、更新 $($HookTrust.UpdatedCount) 個" }) }
        )
        $components += @(Get-PonytailInstallationComponents -Result $Ponytail)
        $components += @(Get-CodexOrchestrationInstallationComponents -Result $CodexOrchestration)
        $components += @(Get-SerenaInstallationComponents -Result $Serena)
        Write-InstallLog -Progress $Progress -Message ("SUMMARY transaction={0}; components={1}; files={2}" -f $TransactionRoot, $components.Count, @($Results.Files).Count)
        Write-InstallResult -Progress $Progress -Status SUCCESS -Summary $fileSummary -Results $Results -Components $components
    }
}

function Invoke-GlobalInstallation {
    param(
        $Context,
        [switch]$SkipContext7Key,
        [switch]$SkipCcusageInstall,
        [switch]$InstallRequestExecutionOptimizer,
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
        [switch]$ForceValidation,
        [switch]$ForceNotificationTest,
        [ValidateSet('Auto', 'Interactive', 'Line')][string]$RendererMode = 'Auto'
    )

    if (-not $InstallMattPocockSkills -and (Test-MattPocockSkillsInstalled)) {
        $InstallMattPocockSkills = $true
    }
    if ($InstallPonytail -and $null -eq $PonytailState) { $PonytailState = Get-PonytailInstallationState -Root $Context.GlobalRoot }
    $targets = @(New-InstallationPlan -DevelopmentEnvironment $Context.DevelopmentEnvironment -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -InstallWindowsNotifications $Context.InstallWindowsNotifications -SourceRoot $Context.ScriptRoot -IncludeExistingSkills $Context.ExistingSkillsInstalled)
    $steps = New-InstallationProgressSteps -TargetCount $targets.Count -IncludeContext7:(-not $SkipContext7Key) -IncludeSkills:$InstallMattPocockSkills -IncludePonytail:$InstallPonytail -IncludeCodexOrchestration:$InstallCodexOrchestration -IncludeSerena:$InstallSerena -IncludeNotifications:$Context.InstallWindowsNotifications
    $progress = Start-InstallProgress -Steps $steps -Root $Context.GlobalRoot -Metadata @{
        Mode = 'Global'
        Environment = $Context.DevelopmentEnvironment
        InstallStyle = $Context.InstallStyle
    } -RendererMode $RendererMode
    $operationLock = $null
    $transaction = $null
    $ccusageBefore = $null
    $contextState = $null
    $results = New-Object 'System.Collections.Generic.List[object]'
    $transactionRoot = $null
    $notificationStatus = ''
    $skippedCount = 0
    $discovery = $null
    $changePlan = $null
    $currentSubOperation = ''
    $mattPocockSkillNames = @()
    $ponytail = New-PonytailSkippedResult
    $codexOrchestration = New-CodexOrchestrationSkippedResult
    $serena = New-SerenaSkippedResult

    try {
        Set-InstallProgress -Progress $progress -StepId 'Plan' -Detail '整理目標與外部套件狀態'
        $ccusageBefore = Get-CcusageState
        $discovery = Get-InstallationDiscovery -Context $Context -Targets $targets -CcusageBefore $ccusageBefore
        Write-InstallationPlan -Progress $progress -Context $Context -Targets $targets -CcusageBefore $ccusageBefore -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -InstallMattPocockSkills:$InstallMattPocockSkills -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -SkipContext7Key:$SkipContext7Key
        Complete-InstallStep -Progress $progress -Result ("已建立 $($targets.Count) 個目標")

        Set-InstallProgress -Progress $progress -StepId 'Prerequisites' -Detail '驗證 PowerShell、Node.js、Codex 與目標目錄'
        Test-Prerequisites 'Global' $Context.GlobalRoot
        if ($InstallPonytail) { [void](Assert-PonytailPrerequisites) }
        if ($InstallCodexOrchestration) { [void](Assert-CodexOrchestrationPrerequisites) }
        foreach ($target in $targets) { Test-DirectoryWritable -Path $target.Root }
        Complete-InstallStep -Progress $progress -Result '通過'

        Set-InstallProgress -Progress $progress -StepId 'Lock' -Detail '取得單一安裝操作鎖並回復中斷交易'
        $operationLock = Enter-CodexSettingsLock
        $recovered = @(Repair-PendingTransactions -BackupRoot $Context.BackupRoot)
        if ($recovered.Count -gt 0) { Write-InstallLog -Progress $progress -Message "RECOVERY restored=$($recovered.Count)" }
        Complete-InstallStep -Progress $progress -Result $(if ($recovered.Count -gt 0) { "已回復 $($recovered.Count) 筆交易" } else { '無待回復交易' })

        Set-InstallProgress -Progress $progress -StepId 'Backup' -Detail '建立交易目錄與外部狀態快照'
        New-Item -ItemType Directory -Path $Context.BackupRoot -Force | Out-Null
        $transactionRoot = Join-Path $Context.BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-global-transaction')
        $transaction = New-FileTransaction -Root $transactionRoot -Mode 'Install-Global'
        $context7KeyWasPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))
        $context7MayCreate = (-not $SkipContext7Key) -and (-not $context7KeyWasPresent)

        Save-TransactionMetadata -Transaction $transaction -Metadata @{
            Mode = 'Global'
            Status = 'InProgress'
            Discovery = $discovery
            CcusageBefore = $ccusageBefore
            Context7KeyWasPresent = $context7KeyWasPresent
            Context7InstallerMayCreate = $context7MayCreate
            Context7KeyCreatedNow = $false
        }
        Complete-InstallStep -Progress $progress -Result '已建立交易備份'

        try {
            Set-InstallProgress -Progress $progress -StepId 'Targets' -Detail ("處理 $($targets.Count) 個全域安裝目標")
            foreach ($result in @(Invoke-InstallationPlan -Targets $targets -Transaction $transaction -Discovery $discovery -Force:$Context.Force)) { [void]$results.Add($result) }
            Complete-InstallStep -Progress $progress -Result ("完成 $($results.Count) 個目標")

            [object[]]$resultArray = $results.ToArray()
            $changePlan = New-InstallationChangePlan -Discovery $discovery -Results $resultArray -CcusageBefore $ccusageBefore -ForceValidation:$ForceValidation -Force:$Context.Force -ForceNotificationTest:$ForceNotificationTest -SkipContext7Key:$SkipContext7Key -InstallMattPocockSkills:$InstallMattPocockSkills -SkipPackageInstall:$SkipCcusageInstall
            Save-TransactionMetadata -Transaction $transaction -Metadata @{ ChangePlan = $changePlan }
            Write-InstallLog -Progress $progress -Message ("WORKFLOW PLAN level={0}; hooksChanged={1}; configChanged={2}; usageToolsChanged={3}; notificationTest={4}; context7={5}" -f $changePlan.validationLevel, $changePlan.hooksChanged, $changePlan.configChanged, $changePlan.usageToolsChanged, $changePlan.runNotificationTest, $changePlan.runContext7)

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
                $hookTrust = Set-CodexSettingsHookTrust -Root $Context.GlobalRoot -Cwd $Context.GlobalRoot
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

            if (-not $SkipContext7Key) {
                Set-InstallProgress -Progress $progress -StepId 'Context7' -Detail $(if ($changePlan.runContext7) { '沿用或設定 Context7 API Key' } else { 'Context7 未變更，略過設定流程' })
            }
            $contextState = if ($changePlan.runContext7) { Set-Context7EnvironmentState -Skip:$SkipContext7Key -PreviousManifest $global.Previous -InformationAction Ignore } else { Set-Context7EnvironmentState -Skip:$true -PreviousManifest $global.Previous -InformationAction Ignore }
            Save-TransactionMetadata -Transaction $transaction -Metadata @{
                Context7KeyCreatedNow = [bool]$contextState.CreatedNow
            }
            if (-not $SkipContext7Key) { Complete-InstallStep -Progress $progress -Result $(if (-not $changePlan.runContext7) { '未變更，略過' } elseif ($contextState.CreatedNow) { '已建立' } elseif ($contextState.CreatedByInstaller) { '已沿用' } else { '未設定' }) }

            Set-InstallProgress -Progress $progress -StepId 'Ccusage' -Detail $(if ($changePlan.usageToolsChanged -or $changePlan.runUsageRuntimeValidation) { '只偵測一次套件狀態，更新必要的 Profile 區塊' } else { 'usage tools 未變更，略過外部程序' })
            $ccusage = if ($changePlan.usageToolsChanged -or $changePlan.runUsageRuntimeValidation) {
                & (Join-Path $Context.ScriptRoot 'integrations\install-usage-tools.ps1') -SkipPackageInstall:$SkipCcusageInstall -ForceRuntimeValidation:$ForceValidation -PackageState $ccusageBefore -Transaction $transaction -PassThru -InformationAction Ignore
            } else {
                New-CcusageUnchangedResult -PackageState $ccusageBefore
            }
            Write-InstallLog -Progress $progress -Message ("COMMAND usage-tools packageBeforeInstalled={0}; forceValidation={1}; skipped={2}" -f $ccusageBefore.Installed, $ForceValidation, $ccusage.Skipped)
            Complete-InstallStep -Progress $progress -Result $(if ($ccusage.CommandsUpdated) { 'Profile 已更新' } else { 'Profile 未變更' })

            if ($InstallMattPocockSkills) {
                Set-InstallProgress -Progress $progress -StepId 'Skills' -Detail '只在選用或偵測到既有技能時執行 npx'
                $mattPocockSkillNames = @(Get-MattPocockSkillNames)
                $skillsArguments = @(Get-MattPocockSkillsArguments)
                $skillsOutput = & npx @skillsArguments 2>&1
                if ($LASTEXITCODE -ne 0) { throw "mattpocock/skills 安裝失敗，結束碼：$LASTEXITCODE" }
                Write-InstallLog -Progress $progress -Message ("COMMAND npx skills installedOrUpdated={0}" -f $mattPocockSkillNames.Count)
                Write-InstallLog -Progress $progress -Message ("COMMAND OUTPUT npx skills: {0}" -f (Protect-InstallLogText ($skillsOutput -join [Environment]::NewLine)))
                Complete-InstallStep -Progress $progress -Result ("已處理 $($mattPocockSkillNames.Count) 個技能")
            }

            if ($InstallPonytail) {
                Set-InstallProgress -Progress $progress -StepId 'Ponytail' -Detail '更新 marketplace、同步 plugin 並驗證 lifecycle hooks'
                $ponytail = Invoke-PonytailInstallation -State $PonytailState -Root $Context.GlobalRoot -MarketplaceAction $PonytailMarketplaceAction
                if ($ponytail.ValidationStatus -ne 'Validated') { throw $(if ($ponytail.ValidationError) { [string]$ponytail.ValidationError } else { 'Ponytail lifecycle hooks 驗證失敗。' }) }
                Write-InstallLog -Progress $progress -Message ('PONYTAIL plugin=' + $ponytail.PluginStatus + '; hooks=' + $ponytail.HookCount + '; trust=' + $ponytail.TrustStatus)
                Complete-InstallStep -Progress $progress -Result ($ponytail.PluginStatus + '; hooks ' + $ponytail.HookCount)
            }

            if ($InstallCodexOrchestration) {
                Set-InstallProgress -Progress $progress -StepId 'CodexOrchestration' -Detail '檢查 Python、安裝/更新 plugin、處理 workflow 設定'
                $codexOrchestration = Invoke-CodexOrchestrationInstallation -InteractiveWorkflow:$ConfigureCodexOrchestration
                Write-InstallLog -Progress $progress -Message ('CODEX ORCHESTRATION plugin=' + $codexOrchestration.PluginStatus + '; workflow=' + $codexOrchestration.WorkflowStatus)
                if (-not [string]::IsNullOrWhiteSpace($codexOrchestration.SetupPrompt)) {
                    Write-Host ''
                    Write-Host '[!] Workflow Pending user setup'
                    Write-Host '請在新的 Codex Task 執行：'
                    Write-Host $codexOrchestration.SetupPrompt
                    Write-Host '$codex-orchestration:codex-orchestration status --require-effective'
                }
                Complete-InstallStep -Progress $progress -Result ($codexOrchestration.PluginStatus + '; workflow ' + $codexOrchestration.WorkflowStatus)
            }

            if ($InstallSerena) {
                Set-InstallProgress -Progress $progress -StepId 'Serena' -Detail '檢查 uv、安裝或更新 Serena、初始化並安全設定 Codex MCP'
                $serena = Invoke-SerenaInstallation -Root $Context.GlobalRoot -Transaction $transaction -InstallUv:$InstallSerenaUv
                Write-InstallLog -Progress $progress -Message ('SERENA cli=' + $serena.ToolStatus + '; init=' + $serena.InitializationStatus + '; mcp=' + $serena.CodexMcpStatus)
                Complete-InstallStep -Progress $progress -Result ($serena.ToolStatus + '; ' + $serena.CodexMcpStatus)
            }

            $original = $ccusageBefore
            $installedByPackage = [bool]$ccusage.PackageInstalledNow
            if ($null -ne $global.Previous -and $null -ne $global.Previous.External -and $null -ne $global.Previous.External.Ccusage) {
                $old = $global.Previous.External.Ccusage
                $original = [pscustomobject]@{ Installed = [bool]$old.WasInstalledBefore; Version = [string]$old.PreviousVersion }
                $installedByPackage = [bool]$old.InstalledByPackage
            }

            $external = [ordered]@{
                PowerShellProfiles = @($ccusage.ProfileStates)
                Ccusage = [ordered]@{
                    Managed = $installedByPackage
                    InstalledByPackage = $installedByPackage
                    WasInstalledBefore = [bool]$original.Installed
                    PreviousVersion = [string]$original.Version
                    CurrentVersion = [string]$ccusage.PackageAfter.Version
                    PackageInstalledNow = [bool]$ccusage.PackageInstalledNow
                }
                Ponytail = [ordered]@{ Managed = [bool]$ponytail.Managed; Marketplace = $script:PonytailMarketplaceSource; MarketplaceSource = [string]$ponytail.MarketplaceSource; MarketplaceStatus = [string]$ponytail.MarketplaceStatus; MarketplaceAddedNow = [bool]$ponytail.MarketplaceAddedNow; MarketplaceSwitchedNow = [bool]$ponytail.MarketplaceSwitchedNow; MarketplaceRecoveredNow = [bool]$ponytail.MarketplaceRecoveredNow; Plugin = $script:PonytailPluginId; WasInstalledBefore = [bool]$ponytail.WasInstalledBefore; InstalledNow = [bool]$ponytail.InstalledNow; UpdatedNow = [bool]$ponytail.UpdatedNow; HookCount = [int]$ponytail.HookCount; TrustedHookCount = [int]$ponytail.TrustedHookCount; HookIdentities = @($ponytail.HookIdentities); ValidationStatus = [string]$ponytail.ValidationStatus; TrustStatus = [string]$ponytail.TrustStatus }
                CodexOrchestration = [ordered]@{ pluginManaged = [bool]$codexOrchestration.Managed; pluginPresent = $codexOrchestration.PluginPresent; pluginUpdatedThisRun = [bool]$codexOrchestration.UpdatedNow; marketplace = $script:CodexOrchestrationMarketplaceSource; plugin = $script:CodexOrchestrationPluginId; workflowManaged = [bool]$codexOrchestration.WorkflowManaged; workflowConfigured = [bool]$codexOrchestration.WorkflowConfigured; workflowEffective = [bool]$codexOrchestration.WorkflowEffective; workflowStatus = [string]$codexOrchestration.WorkflowStatus; workflowConfigurationSummary = [string]$codexOrchestration.WorkflowConfigurationSummary; setupPrompt = [string]$codexOrchestration.SetupPrompt }
                Serena = [ordered]@{ Managed = [bool]$serena.Managed; SelectedByUser = [bool]$serena.SelectedByUser; UvAvailable = [bool]$serena.UvAvailable; UvVersion = [string]$serena.UvVersion; VersionBefore = [string]$serena.VersionBefore; VersionAfter = [string]$serena.VersionAfter; InstalledNow = [bool]$serena.InstalledNow; UpdatedNow = [bool]$serena.UpdatedNow; InitializationStatus = [string]$serena.InitializationStatus; CodexMcpConfigured = ([string]$serena.CodexMcpStatus -eq 'Configured'); RuntimeVerified = $false }
                Context7 = [ordered]@{
                    EnvironmentVariable = 'CONTEXT7_API_KEY'
                    CreatedByInstaller = [bool]$contextState.CreatedByInstaller
                    SecretStoredInRepository = $false
                }
            }

            Complete-Installation -Results $resultArray -Transaction $transaction -External $external | Out-Null

            if ($Context.InstallWindowsNotifications) {
                Set-InstallProgress -Progress $progress -StepId 'Notifications' -Detail '驗證開發狀態與 Token / Cost 使用量通知'
                if (Test-CodexWorkflowDecision -Plan $changePlan -Operation NotificationTest) {
                    $notificationScript = Join-Path $Context.GlobalRoot 'hooks\show-codex-notification.ps1'
                    $notificationOutput = & pwsh -NoLogo -NoProfile -NonInteractive -File $notificationScript -Type Completed -Test 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "Windows 通知測試失敗，結束碼：$LASTEXITCODE" }
                    $notificationStatus = '已送出測試通知'
                    Write-InstallLog -Progress $progress -Message 'COMMAND notification test completed'
                    Write-InstallLog -Progress $progress -Message ("COMMAND OUTPUT notification test: {0}" -f (Protect-InstallLogText ($notificationOutput -join [Environment]::NewLine)))
                    Complete-InstallStep -Progress $progress -Result $notificationStatus
                } else {
                    $notificationStatus = '腳本與 Hook 未變更，略過測試'
                    $skippedCount++
                    Complete-InstallStep -Progress $progress -Result $notificationStatus
                }
            }

            Set-InstallProgress -Progress $progress -StepId 'Final' -Detail '寫入 Manifest 並完成交易驗證'
            Complete-Installation -Results $resultArray -Transaction $transaction -External $external -FinalizeTransaction | Out-Null
            Complete-InstallStep -Progress $progress -Result 'Manifest 與交易驗證通過'
            Write-InstallationSummary -InstallStyle $Context.InstallStyle -DevelopmentEnvironment $Context.DevelopmentEnvironment -Results $resultArray -Ccusage $ccusage -CcusageBefore $ccusageBefore -HookTrust $hookTrust -TransactionRoot $transactionRoot -InstallWindowsNotifications $Context.InstallWindowsNotifications -Progress $progress -NotificationStatus $notificationStatus -SkippedCount $skippedCount -SkipContext7Key:$SkipContext7Key -InstallMattPocockSkills:$InstallMattPocockSkills -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -ContextState $contextState -SkillsCount $mattPocockSkillNames.Count -Ponytail $ponytail -CodexOrchestration $codexOrchestration -Serena $serena
        } catch {
            $reason = $_.Exception.Message
            Write-InstallErrorRecord -Progress $progress -ErrorRecord $_ -CurrentSubOperation $currentSubOperation
            Fail-InstallStep -Progress $progress -Reason $reason
            $rollbackErrors = @(Invoke-InstallationRollback -Transaction $transaction -CcusageBefore $ccusageBefore -ContextState $contextState -Ponytail $ponytail -CodexOrchestration $codexOrchestration -Reason $reason)
            $message = "Installation failed and rollback was attempted.`nReason: $reason"
            if ($rollbackErrors.Count -gt 0) { $message += "`nRollback errors:`n- " + ($rollbackErrors -join "`n- ") }
            $rollbackStatus = if ($rollbackErrors.Count -eq 0) { 'SUCCESS' } else { 'FAILED' }
            $failureSummary = Get-InstallResultSummary -Results $results.ToArray()
            $failureSummary.Rollback = $rollbackStatus
            Write-InstallResult -Progress $progress -Status FAILED -Summary $failureSummary -Results $results.ToArray()
            throw $message
        }
    } catch {
        if ($progress.Status -ne 'Failed') {
            $reason = $_.Exception.Message
            Write-InstallErrorRecord -Progress $progress -ErrorRecord $_ -CurrentSubOperation $currentSubOperation
            Fail-InstallStep -Progress $progress -Reason $reason
            $rollbackErrors = @(Invoke-InstallationRollback -Transaction $transaction -CcusageBefore $ccusageBefore -ContextState $contextState -Ponytail $ponytail -CodexOrchestration $codexOrchestration -Reason $reason)
            $failureSummary = Get-InstallResultSummary -Results $results.ToArray()
            $failureSummary.Rollback = if ($rollbackErrors.Count -eq 0) { 'SUCCESS' } else { 'FAILED' }
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
        [switch]$SkipContext7Key,
        [switch]$SkipCcusageInstall,
        [switch]$InstallRequestExecutionOptimizer,
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
        [switch]$ForceValidation,
        [switch]$ForceNotificationTest,
        [switch]$NoPause,
        [Nullable[bool]]$InstallWindowsNotifications,
        [ValidateSet('Git', 'CVS')]
        [string]$DevelopmentEnvironment,
        [switch]$Force,
        [ValidateSet('Merge', 'Replace')]
        [string]$InstallStyle = 'Merge',
        [string]$SourceRoot = ''
    )

    if ($InstallPonytail -and $SkipPonytail) { throw 'InstallPonytail 與 SkipPonytail 不可同時指定。' }
    if ($InstallCodexOrchestration -and $SkipCodexOrchestration) { throw 'InstallCodexOrchestration 與 SkipCodexOrchestration 不可同時指定。' }
    if ($ConfigureCodexOrchestration -and -not $InstallCodexOrchestration) { throw 'ConfigureCodexOrchestration 必須搭配 InstallCodexOrchestration。' }
    if ($InstallSerena -and $SkipSerena) { throw 'InstallSerena 與 SkipSerena 不可同時指定。' }
    if ($InstallPonytail) { . (Get-OptionalInstallationScriptPath -Name Ponytail) }
    if ($InstallCodexOrchestration) { . (Get-OptionalInstallationScriptPath -Name CodexOrchestration) }
    if ($InstallSerena) { . (Get-OptionalInstallationScriptPath -Name Serena) }
    if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = [string]$ScriptRoot }
    if ($Mode -in @('Backup', 'Restore', 'Uninstall')) {
        Invoke-ManagementMode -Mode $Mode -SourceRoot $SourceRoot
        return
    }

    $context = New-InstallerContext -SourceRoot $SourceRoot -DevelopmentEnvironment $DevelopmentEnvironment -InstallStyle $InstallStyle -Force:$Force -InstallWindowsNotifications $InstallWindowsNotifications
    if ($Mode -eq 'Interactive') {
        Invoke-InteractiveMode -DevelopmentEnvironment $context.DevelopmentEnvironment -GlobalRoot $context.GlobalRoot -SourceRoot $context.ScriptRoot
        return
    }

    if ($InstallPonytail -and $null -eq $PonytailState) { $PonytailState = Get-PonytailInstallationState -Root $context.GlobalRoot }
    Invoke-GlobalInstallation -Context $context -SkipContext7Key:$SkipContext7Key -SkipCcusageInstall:$SkipCcusageInstall -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -InstallMattPocockSkills:$InstallMattPocockSkills -InstallPonytail:$InstallPonytail -SkipPonytail:$SkipPonytail -PonytailState $PonytailState -PonytailMarketplaceAction $PonytailMarketplaceAction -InstallCodexOrchestration:$InstallCodexOrchestration -SkipCodexOrchestration:$SkipCodexOrchestration -ConfigureCodexOrchestration:$ConfigureCodexOrchestration -InstallSerena:$InstallSerena -SkipSerena:$SkipSerena -InstallSerenaUv:$InstallSerenaUv -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -ForceValidation:$ForceValidation -ForceNotificationTest:$ForceNotificationTest -RendererMode $(if ($NoPause) { 'Line' } else { 'Auto' })
}
