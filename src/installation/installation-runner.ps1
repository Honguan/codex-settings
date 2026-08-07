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
    try { Undo-FileTransaction $Transaction | Out-Null } catch { [void]$rollbackErrors.Add("File rollback failed: $($_.Exception.Message)") }
    if ($null -ne $CcusageBefore) {
        try { Restore-CcusageState $CcusageBefore | Out-Null } catch { [void]$rollbackErrors.Add("ccusage rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $ContextState -and [bool]$ContextState.CreatedNow) {
        try {
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $ContextState.UserBefore, 'User')
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $ContextState.ProcessBefore, 'Process')
        } catch { [void]$rollbackErrors.Add("Context7 rollback failed: $($_.Exception.Message)") }
    }
    try {
        Save-TransactionMetadata -Transaction $Transaction -Metadata @{
            Status = 'RolledBack'
            RolledBackAt = (Get-Date).ToString('o')
            FailureReason = $Reason
            RollbackErrors = $rollbackErrors.ToArray()
        }
    } catch { [void]$rollbackErrors.Add("Journal update failed: $($_.Exception.Message)") }
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
        [bool]$InstallWindowsNotifications
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
    Write-Host "Hook 信任：已驗證 $($HookTrust.TrustedCount) 個、更新 $($HookTrust.UpdatedCount) 個。"
    Write-Host "交易備份：$TransactionRoot"
    Write-Host $(if ($InstallWindowsNotifications) { 'Windows 通知與完成 Token 用量：已整合安裝，並送出測試通知。' } else { 'Windows 通知與完成 Token 用量：未安裝。' })
    Write-Host '請完全關閉並重新啟動 VS Code、Codex 與 PowerShell；既有 Session 不會載入新安裝的 Hook。'
}

function Invoke-GlobalInstallation {
    param(
        $Context,
        [switch]$SkipContext7Key,
        [switch]$SkipCcusageInstall,
        [switch]$InstallRequestExecutionOptimizer,
        [switch]$InstallMattPocockSkills,
        [switch]$EnableDefaultModeRequestUserInput
    )

    if (-not $InstallMattPocockSkills -and (Test-MattPocockSkillsInstalled)) {
        $InstallMattPocockSkills = $true
    }
    $targets = @(New-InstallationPlan -DevelopmentEnvironment $Context.DevelopmentEnvironment -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -InstallWindowsNotifications $Context.InstallWindowsNotifications)
    Test-Prerequisites 'Global' $Context.GlobalRoot
    foreach ($target in $targets) { Test-DirectoryWritable -Path $target.Root }

    New-Item -ItemType Directory -Path $Context.BackupRoot -Force | Out-Null
    $operationLock = $null
    $transaction = $null
    $ccusageBefore = $null
    $contextState = $null

    try {
        $operationLock = Enter-CodexSettingsLock
        $recovered = @(Repair-PendingTransactions -BackupRoot $Context.BackupRoot)
        if ($recovered.Count -gt 0) { Write-Host "已自動回復上次中斷的安裝交易：$($recovered.Count) 筆。" }

        $transactionRoot = Join-Path $Context.BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-global-transaction')
        $transaction = New-FileTransaction -Root $transactionRoot -Mode 'Install-Global'
        $ccusageBefore = Get-CcusageState
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

        $results = New-Object 'System.Collections.Generic.List[object]'
        try {
            foreach ($target in $targets) {
                [void]$results.Add((Invoke-TargetInstallation -Target $target -Transaction $transaction -Force:$Context.Force))
            }

            $global = @($results | Where-Object Mode -eq 'Global' | Select-Object -First 1)[0]
            $hookTrust = Set-CodexSettingsHookTrust -Root $Context.GlobalRoot -Cwd $Context.GlobalRoot
            $configEntry = @($global.Files | Where-Object Path -eq 'config.toml' | Select-Object -First 1)[0]
            if ($null -ne $configEntry) {
                $configHash = (Get-FileHash -LiteralPath (Join-Path $Context.GlobalRoot 'config.toml') -Algorithm SHA256).Hash
                if ([string]$configEntry.Sha256 -ne $configHash) { $configEntry.Changed = $true }
                $configEntry.Sha256 = $configHash
            }
            $contextState = Set-Context7EnvironmentState -Skip:$SkipContext7Key -PreviousManifest $global.Previous
            Save-TransactionMetadata -Transaction $transaction -Metadata @{
                Context7KeyCreatedNow = [bool]$contextState.CreatedNow
            }

            $profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
            foreach ($profilePath in $profilePaths) { Save-TransactionFile -Transaction $transaction -Path $profilePath }
            $ccusage = & (Join-Path $Context.ScriptRoot 'integrations\install-usage-tools.ps1') -SkipPackageInstall:$SkipCcusageInstall -PackageState $ccusageBefore -PassThru
            if ($InstallMattPocockSkills) {
                $mattPocockSkillNames = @(Get-MattPocockSkillNames)
                Write-Host "正在安裝或更新 mattpocock/skills 預設技能（$($mattPocockSkillNames.Count) 個）。"
                $skillsArguments = @(Get-MattPocockSkillsArguments)
                & npx @skillsArguments
                if ($LASTEXITCODE -ne 0) { throw "mattpocock/skills 安裝失敗，結束碼：$LASTEXITCODE" }
                Write-Host "mattpocock/skills：已安裝或更新 $($mattPocockSkillNames.Count) 個預設全域技能。"
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
            Complete-FileTransaction -Transaction $transaction

            if ($Context.InstallWindowsNotifications) {
                & (Join-Path $Context.GlobalRoot 'hooks\show-codex-notification.ps1') -Type Completed -Test | Out-Null
            }
            Write-InstallationSummary -InstallStyle $Context.InstallStyle -DevelopmentEnvironment $Context.DevelopmentEnvironment -Results $results.ToArray() -Ccusage $ccusage -CcusageBefore $ccusageBefore -HookTrust $hookTrust -TransactionRoot $transactionRoot -InstallWindowsNotifications $Context.InstallWindowsNotifications
        } catch {
            $reason = $_.Exception.Message
            $rollbackErrors = @(Invoke-InstallationRollback -Transaction $transaction -CcusageBefore $ccusageBefore -ContextState $contextState -Reason $reason)
            $message = "Installation failed and rollback was attempted.`nReason: $reason"
            if ($rollbackErrors.Count -gt 0) { $message += "`nRollback errors:`n- " + ($rollbackErrors -join "`n- ") }
            throw $message
        }
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

    Invoke-GlobalInstallation -Context $context -SkipContext7Key:$SkipContext7Key -SkipCcusageInstall:$SkipCcusageInstall -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -InstallMattPocockSkills:$InstallMattPocockSkills -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput
}
