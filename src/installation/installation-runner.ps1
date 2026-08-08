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
        [string]$GlobalRoot
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
                $enableDefaultModeRequestUserInput = Select-OptionalDefaultModeRequestUserInput
                $installWindowsNotifications = Select-OptionalWindowsNotifications -AlreadyInstalled:(Test-WindowsNotificationsInstalled -Root $GlobalRoot)
                Invoke-Installer -Mode Global -InstallStyle $style -DevelopmentEnvironment $selectedEnvironment -InstallRequestExecutionOptimizer:$installRequestExecutionOptimizer -InstallMattPocockSkills:$installMattPocockSkills -EnableDefaultModeRequestUserInput:$enableDefaultModeRequestUserInput -InstallWindowsNotifications:$installWindowsNotifications
                return
            }

            Invoke-ManagementMode -Mode $selection -SourceRoot $ScriptRoot
        } catch {
            Write-Host "作業失敗：$($_.Exception.Message)" -ForegroundColor Red
        }

        Write-Host ''
        [void](Read-Host '按 Enter 返回安裝器選單')
    }
}

function Invoke-InstallationRollback($Transaction, $CcusageBefore, $ContextState, [string]$Reason) {
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
        [int]$SkippedCount = 0
    )

    Write-Host ''
    Write-Host '安裝完成。'
    Write-Host "方式：$InstallStyle"
    Write-Host "預設專案體系：$DevelopmentEnvironment（已記錄於全域設定）"
    Write-Host "目標：$($Results.Count)"
    foreach ($result in $Results) {
        $changedCount = @($result.Files | Where-Object Changed).Count
        $createdCount = @($result.Files | Where-Object { -not $_.ExistedBefore }).Count
        $updatedCount = @($result.Files | Where-Object { $_.ExistedBefore -and $_.Changed }).Count
        $unchangedCount = $result.Files.Count - $changedCount
        Write-Host "目標：$($result.Root)"
        Write-Host "類型：$($result.Mode)"
        Write-Host "檔案：$($result.Files.Count)（新增：$createdCount、更新：$updatedCount、未變更：$unchangedCount）"
    }
    $packageStatus = if ([bool]$Ccusage.PackageInstalledNow) { '已安裝 ccusage 套件' } elseif ([bool]$CcusageBefore.Installed) { '沿用既有 ccusage 套件' } else { '已略過 ccusage 套件' }
    $commandStatus = if ([bool]$Ccusage.CommandsUpdated) { '已更新 ccsessions、cdaily 指令' } else { 'ccsessions、cdaily 指令未變更' }
    Write-Host "ccusage：$packageStatus；$commandStatus"
    Write-Host '  ccsessions [數量或 Session ID]：查看 Session 的模型、Token、費用與台北時間。'
    Write-Host '  ccsessions -Json <Session ID>：輸出完成通知使用的機器可讀資料。'
    Write-Host '  cdaily [天數]：查看每日 Token 與費用統計。'
    $hookStatus = if ([bool]$HookTrust.Skipped) { '未變更，略過重新 trust' } else { "已驗證 $($HookTrust.TrustedCount) 個、更新 $($HookTrust.UpdatedCount) 個" }
    Write-Host "Hook 信任：$hookStatus。"
    Write-Host "交易備份：$TransactionRoot"
    if ($InstallWindowsNotifications) {
        Write-Host "Windows 通知與完成 Token 用量：已整合安裝；$NotificationStatus。"
    } else {
        Write-Host 'Windows 通知與完成 Token 用量：未安裝。'
    }
    Write-Host '請完全關閉並重新啟動 VS Code、Codex 與 PowerShell；既有 Session 不會載入新安裝的 Hook。'

    if ($null -ne $Progress) {
        $fileSummary = Get-InstallResultSummary -Results $Results
        $fileSummary.Skipped = [int]$fileSummary.Skipped + $SkippedCount
        Write-InstallResult -Progress $Progress -Status SUCCESS -Summary $fileSummary
    }
}

function Invoke-GlobalInstallation {
    param(
        $Context,
        [switch]$SkipContext7Key,
        [switch]$SkipCcusageInstall,
        [switch]$InstallRequestExecutionOptimizer,
        [switch]$InstallMattPocockSkills,
        [switch]$EnableDefaultModeRequestUserInput,
        [switch]$ForceValidation,
        [switch]$ForceNotificationTest
    )

    if (-not $InstallMattPocockSkills -and (Test-MattPocockSkillsInstalled)) {
        $InstallMattPocockSkills = $true
    }
    $targets = @(New-InstallationPlan -DevelopmentEnvironment $Context.DevelopmentEnvironment -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -InstallWindowsNotifications $Context.InstallWindowsNotifications)
    $steps = New-InstallationProgressSteps -TargetCount $targets.Count -IncludeContext7:(-not $SkipContext7Key) -IncludeSkills:$InstallMattPocockSkills -IncludeNotifications:$Context.InstallWindowsNotifications
    $progress = Start-InstallProgress -Steps $steps -Root $Context.GlobalRoot -Metadata @{
        Mode = 'Global'
        Environment = $Context.DevelopmentEnvironment
        InstallStyle = $Context.InstallStyle
    }
    $operationLock = $null
    $transaction = $null
    $ccusageBefore = $null
    $contextState = $null
    $results = New-Object 'System.Collections.Generic.List[object]'
    $transactionRoot = $null
    $notificationStatus = ''
    $skippedCount = 0

    try {
        Set-InstallProgress -Progress $progress -StepId 'Plan' -Detail '整理目標與外部套件狀態'
        $ccusageBefore = Get-CcusageState
        Write-InstallationPlan -Progress $progress -Context $Context -Targets $targets -CcusageBefore $ccusageBefore -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -InstallMattPocockSkills:$InstallMattPocockSkills -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -SkipContext7Key:$SkipContext7Key
        Complete-InstallStep -Progress $progress -Result ("已建立 $($targets.Count) 個目標")

        Set-InstallProgress -Progress $progress -StepId 'Prerequisites' -Detail '驗證 PowerShell、Node.js、Codex 與目標目錄'
        Test-Prerequisites 'Global' $Context.GlobalRoot
        foreach ($target in $targets) { Test-DirectoryWritable -Path $target.Root }
        Complete-InstallStep -Progress $progress -Result '通過'

        Set-InstallProgress -Progress $progress -StepId 'Lock' -Detail '取得單一安裝操作鎖並回復中斷交易'
        $operationLock = Enter-CodexSettingsLock
        $recovered = @(Repair-PendingTransactions -BackupRoot $Context.BackupRoot)
        if ($recovered.Count -gt 0) { Write-Host "已自動回復上次中斷的安裝交易：$($recovered.Count) 筆。" }
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
            CcusageBefore = $ccusageBefore
            Context7KeyWasPresent = $context7KeyWasPresent
            Context7InstallerMayCreate = $context7MayCreate
            Context7KeyCreatedNow = $false
        }
        Complete-InstallStep -Progress $progress -Result '已建立交易備份'

        try {
            Set-InstallProgress -Progress $progress -StepId 'Targets' -Detail ("處理 $($targets.Count) 個全域安裝目標")
            foreach ($target in $targets) {
                [void]$results.Add((Invoke-TargetInstallation -Target $target -Transaction $transaction -Force:$Context.Force))
            }
            Complete-InstallStep -Progress $progress -Result ("完成 $($results.Count) 個目標")

            Set-InstallProgress -Progress $progress -StepId 'Hooks' -Detail '驗證受管理 Hook 狀態；未變更時略過昂貴的 trust 呼叫'
            $global = @($results | Where-Object Mode -eq 'Global' | Select-Object -First 1)[0]
            $hookChanged = [bool]$global.HookChanged -or $null -eq $global.Previous
            if ($hookChanged) {
                $hookTrust = Set-CodexSettingsHookTrust -Root $Context.GlobalRoot -Cwd $Context.GlobalRoot
            } else {
                $hookTrust = [pscustomobject]@{ TrustedCount = 0; UpdatedCount = 0; Verified = $true; Skipped = $true }
                Write-InstallLog -Progress $progress -Message 'HOOK TRUST skipped; no managed Hook changes detected'
            }
            $configEntry = @($global.Files | Where-Object Path -eq 'config.toml' | Select-Object -First 1)[0]
            if ($null -ne $configEntry) {
                $configHash = (Get-FileHash -LiteralPath (Join-Path $Context.GlobalRoot 'config.toml') -Algorithm SHA256).Hash
                if ([string]$configEntry.Sha256 -ne $configHash) { $configEntry.Changed = $true; $configEntry.Status = 'Updated' }
                $configEntry.Sha256 = $configHash
            }
            Complete-InstallStep -Progress $progress -Result $(if ($hookTrust.Skipped) { 'Hook 未變更，略過重新 trust' } else { "已驗證 $($hookTrust.TrustedCount) 個" })

            if (-not $SkipContext7Key) {
                Set-InstallProgress -Progress $progress -StepId 'Context7' -Detail '沿用或設定 Context7 API Key'
            }
            $contextState = Set-Context7EnvironmentState -Skip:$SkipContext7Key -PreviousManifest $global.Previous
            Save-TransactionMetadata -Transaction $transaction -Metadata @{
                Context7KeyCreatedNow = [bool]$contextState.CreatedNow
            }
            if (-not $SkipContext7Key) { Complete-InstallStep -Progress $progress -Result $(if ($contextState.CreatedNow) { '已建立' } elseif ($contextState.CreatedByInstaller) { '已沿用' } else { '未設定' }) }

            Set-InstallProgress -Progress $progress -StepId 'Ccusage' -Detail '只偵測一次套件狀態，更新必要的 Profile 區塊'
            $ccusage = & (Join-Path $Context.ScriptRoot 'integrations\install-usage-tools.ps1') -SkipPackageInstall:$SkipCcusageInstall -ForceRuntimeValidation:$ForceValidation -PackageState $ccusageBefore -Transaction $transaction -PassThru
            Write-InstallLog -Progress $progress -Message ("COMMAND usage-tools packageBeforeInstalled={0}; forceValidation={1}" -f $ccusageBefore.Installed, $ForceValidation)
            Complete-InstallStep -Progress $progress -Result $(if ($ccusage.CommandsUpdated) { 'Profile 已更新' } else { 'Profile 未變更' })

            if ($InstallMattPocockSkills) {
                Set-InstallProgress -Progress $progress -StepId 'Skills' -Detail '只在選用或偵測到既有技能時執行 npx'
                $mattPocockSkillNames = @(Get-MattPocockSkillNames)
                Write-Host "正在安裝或更新 mattpocock/skills 預設技能（$($mattPocockSkillNames.Count) 個）。"
                $skillsArguments = @(Get-MattPocockSkillsArguments)
                & npx @skillsArguments
                if ($LASTEXITCODE -ne 0) { throw "mattpocock/skills 安裝失敗，結束碼：$LASTEXITCODE" }
                Write-Host "mattpocock/skills：已安裝或更新 $($mattPocockSkillNames.Count) 個預設全域技能。"
                Write-InstallLog -Progress $progress -Message ("COMMAND npx skills installedOrUpdated={0}" -f $mattPocockSkillNames.Count)
                Complete-InstallStep -Progress $progress -Result ("已處理 $($mattPocockSkillNames.Count) 個技能")
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
                Context7 = [ordered]@{
                    EnvironmentVariable = 'CONTEXT7_API_KEY'
                    CreatedByInstaller = [bool]$contextState.CreatedByInstaller
                    SecretStoredInRepository = $false
                }
            }

            foreach ($result in $results) {
                Save-InstallationManifest -Result $result -Transaction $transaction -External $(if ($result.Mode -eq 'Global') { $external } else { $null })
            }

            if ($Context.InstallWindowsNotifications) {
                Set-InstallProgress -Progress $progress -StepId 'Notifications' -Detail '最後執行非關鍵通知測試'
                $notificationChanged = [bool]$global.HookChanged -or @($global.Files | Where-Object { $_.Changed -and ([string]$_.Path -eq 'hooks.json' -or [string]$_.Path -eq 'hooks\show-codex-notification.ps1') }).Count -gt 0
                if ($ForceNotificationTest -or $notificationChanged) {
                    & (Join-Path $Context.GlobalRoot 'hooks\show-codex-notification.ps1') -Type Completed -Test | Out-Null
                    $notificationStatus = '已送出測試通知'
                    Write-InstallLog -Progress $progress -Message 'COMMAND notification test completed'
                    Complete-InstallStep -Progress $progress -Result $notificationStatus
                } else {
                    $notificationStatus = '腳本與 Hook 未變更，略過測試'
                    $skippedCount++
                    Complete-InstallStep -Progress $progress -Result $notificationStatus
                }
            }

            Set-InstallProgress -Progress $progress -StepId 'Final' -Detail '寫入 Manifest 並完成交易驗證'
            Complete-FileTransaction -Transaction $transaction
            Complete-InstallStep -Progress $progress -Result 'Manifest 與交易驗證通過'
            Write-InstallationSummary -InstallStyle $Context.InstallStyle -DevelopmentEnvironment $Context.DevelopmentEnvironment -Results $results.ToArray() -Ccusage $ccusage -CcusageBefore $ccusageBefore -HookTrust $hookTrust -TransactionRoot $transactionRoot -InstallWindowsNotifications $Context.InstallWindowsNotifications -Progress $progress -NotificationStatus $notificationStatus -SkippedCount $skippedCount
        } catch {
            $reason = $_.Exception.Message
            Fail-InstallStep -Progress $progress -Reason $reason
            $rollbackErrors = @(Invoke-InstallationRollback -Transaction $transaction -CcusageBefore $ccusageBefore -ContextState $contextState -Reason $reason)
            $message = "Installation failed and rollback was attempted.`nReason: $reason"
            if ($rollbackErrors.Count -gt 0) { $message += "`nRollback errors:`n- " + ($rollbackErrors -join "`n- ") }
            $rollbackStatus = if ($rollbackErrors.Count -eq 0) { 'SUCCESS' } else { 'FAILED' }
            $failureSummary = Get-InstallResultSummary -Results $results.ToArray()
            $failureSummary.Rollback = $rollbackStatus
            Write-InstallResult -Progress $progress -Status FAILED -Summary $failureSummary
            throw $message
        }
    } catch {
        if ($progress.Status -ne 'Failed') {
            $reason = $_.Exception.Message
            Fail-InstallStep -Progress $progress -Reason $reason
            $rollbackErrors = @(Invoke-InstallationRollback -Transaction $transaction -CcusageBefore $ccusageBefore -ContextState $contextState -Reason $reason)
            $failureSummary = Get-InstallResultSummary -Results $results.ToArray()
            $failureSummary.Rollback = if ($rollbackErrors.Count -eq 0) { 'SUCCESS' } else { 'FAILED' }
            Write-InstallResult -Progress $progress -Status FAILED -Summary $failureSummary
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
        [switch]$EnableDefaultModeRequestUserInput,
        [switch]$ForceValidation,
        [switch]$ForceNotificationTest,
        [switch]$NoPause,
        [Nullable[bool]]$InstallWindowsNotifications,
        [ValidateSet('Git', 'CVS')]
        [string]$DevelopmentEnvironment,
        [switch]$Force,
        [ValidateSet('Merge', 'Replace')]
        [string]$InstallStyle = 'Merge'
    )

    if ($Mode -in @('Backup', 'Restore', 'Uninstall')) {
        Invoke-ManagementMode -Mode $Mode -SourceRoot $ScriptRoot
        return
    }

    $context = New-InstallerContext -DevelopmentEnvironment $DevelopmentEnvironment -InstallStyle $InstallStyle -Force:$Force -InstallWindowsNotifications $InstallWindowsNotifications
    if ($Mode -eq 'Interactive') {
        Invoke-InteractiveMode -DevelopmentEnvironment $context.DevelopmentEnvironment -GlobalRoot $context.GlobalRoot
        return
    }

    Invoke-GlobalInstallation -Context $context -SkipContext7Key:$SkipContext7Key -SkipCcusageInstall:$SkipCcusageInstall -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -InstallMattPocockSkills:$InstallMattPocockSkills -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -ForceValidation:$ForceValidation -ForceNotificationTest:$ForceNotificationTest
}
