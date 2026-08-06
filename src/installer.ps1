[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Backup', 'Restore', 'Uninstall')]
    [string]$Mode = 'Interactive',
    [switch]$SkipContext7Key,
    [switch]$SkipCcusageInstall,
    [switch]$InstallRequestExecutionOptimizer,
    [switch]$InstallMattPocockSkills,
    [switch]$EnableDefaultModeRequestUserInput,
    [ValidateSet('Git', 'CVS')]
    [string]$DevelopmentEnvironment,
    [switch]$Force,
    [ValidateSet('Merge', 'Replace')]
    [string]$InstallStyle = 'Merge'
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupBase = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'
. (Join-Path $ScriptRoot 'modules\common.ps1')
. (Join-Path $ScriptRoot 'modules\installation.ps1')
$globalRoot = Join-Path $HOME '.codex'
if ([string]::IsNullOrWhiteSpace($DevelopmentEnvironment)) {
    $DevelopmentEnvironment = Get-DefaultDevelopmentEnvironment -Root $globalRoot
}

if ($Mode -eq 'Interactive') {
    while ($true) {
        try {
            $selection = Select-Mode
            if ($selection -eq 'Exit') { return }

            switch ($selection) {
                'Global' {
                    $style = Select-InstallStyle
                    $developmentEnvironment = Select-DevelopmentEnvironment -Default $DevelopmentEnvironment
                    $installRequestExecutionOptimizer = Select-OptionalGlobalSkill
                    $installMattPocockSkills = Select-OptionalMattPocockSkills
                    $enableDefaultModeRequestUserInput = Select-OptionalDefaultModeRequestUserInput
                    & $PSCommandPath -Mode Global -InstallStyle $style -DevelopmentEnvironment $developmentEnvironment -InstallRequestExecutionOptimizer:$installRequestExecutionOptimizer -InstallMattPocockSkills:$installMattPocockSkills -EnableDefaultModeRequestUserInput:$enableDefaultModeRequestUserInput
                    return
                }
                default { & $PSCommandPath -Mode $selection }
            }
        } catch {
            Write-Host "作業失敗：$($_.Exception.Message)" -ForegroundColor Red
        }

        Write-Host ''
        [void](Read-Host '按 Enter 返回安裝器選單')
    }
}

if ($Mode -in @('Backup', 'Restore', 'Uninstall')) {
    $actionScript = Join-Path $ScriptRoot ("operations\{0}.ps1" -f $Mode.ToLowerInvariant())
    if (-not (Test-Path -LiteralPath $actionScript -PathType Leaf)) { throw "管理功能不存在：$actionScript" }
    if ($Mode -eq 'Restore') { & $actionScript }
    else { & $actionScript -Mode Global }
    return
}

if ($Force) { $InstallStyle = 'Replace' }
$Force = $InstallStyle -eq 'Replace'
if (-not $InstallMattPocockSkills -and (Test-MattPocockSkillsInstalled)) {
    $InstallMattPocockSkills = $true
}
$targets = @(Resolve-GlobalTargets -DevelopmentEnvironment $DevelopmentEnvironment -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput)
$preflight = $globalRoot
Test-Prerequisites 'Global' $preflight
foreach ($target in $targets) { Test-DirectoryWritable -Path $target.Root }

New-Item -ItemType Directory -Path $BackupBase -Force | Out-Null
$operationLock = $null
$transaction = $null
$ccusageBefore = $null
$contextState = $null

try {
    $operationLock = Enter-CodexSettingsLock
    $recovered = @(Repair-PendingTransactions -BackupRoot $BackupBase)
    if ($recovered.Count -gt 0) { Write-Host "已自動回復上次中斷的安裝交易：$($recovered.Count) 筆。" }

    $transactionRoot = Join-Path $BackupBase ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$($Mode.ToLowerInvariant())-transaction")
    $transaction = New-FileTransaction -Root $transactionRoot -Mode "Install-$Mode"
    $ccusageBefore = Get-CcusageState
    $context7KeyWasPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))
    $context7MayCreate = (-not $SkipContext7Key) -and (-not $context7KeyWasPresent)

    Save-TransactionMetadata -Transaction $transaction -Metadata @{
        Mode = $Mode
        Status = 'InProgress'
        CcusageBefore = $ccusageBefore
        Context7KeyWasPresent = $context7KeyWasPresent
        Context7InstallerMayCreate = $context7MayCreate
        Context7KeyCreatedNow = $false
    }

    $results = New-Object 'System.Collections.Generic.List[object]'

    try {
        $obsoleteProjects = Remove-ObsoleteProjectSettings -Transaction $transaction
        foreach ($target in $targets) { [void]$results.Add((Install-Target $target $transaction -Force:$Force)) }
        $external = $null

        $global = @($results | Where-Object Mode -eq 'Global' | Select-Object -First 1)[0]
            $contextState = Set-Context7Key -Skip:$SkipContext7Key -PreviousManifest $global.Previous
            Save-TransactionMetadata -Transaction $transaction -Metadata @{
                Context7KeyCreatedNow = [bool]$contextState.CreatedNow
            }

            $profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
            foreach ($profilePath in $profilePaths) { Save-TransactionFile $transaction $profilePath }
            $ccusage = & (Join-Path $ScriptRoot 'modules\ccusage.ps1') -SkipPackageInstall:$SkipCcusageInstall -PackageState $ccusageBefore -PassThru
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
            Write-Manifest $result $transaction $(if ($result.Mode -eq 'Global') { $external } else { $null })
        }

        Complete-FileTransaction -Transaction $transaction

        & (Join-Path $globalRoot 'hooks\show-codex-notification.ps1') -Type Completed -Test | Out-Null

        Write-Host ''
        Write-Host '安裝完成。'
        Write-Host "方式：$InstallStyle"
        Write-Host "預設專案體系：$DevelopmentEnvironment（已記錄於全域設定）"
        Write-Host "目標：$($results.Count)"
        foreach ($result in $results) {
            $changedCount = @($result.Files | Where-Object Changed).Count
            $createdCount = @($result.Files | Where-Object { -not $_.ExistedBefore }).Count
            $updatedCount = @($result.Files | Where-Object { $_.ExistedBefore -and $_.Changed }).Count
            $unchangedCount = $result.Files.Count - $changedCount
            Write-Host "目標：$($result.Root)"
            Write-Host "類型：$($result.Mode)"
            Write-Host "檔案：$($result.Files.Count)（新增：$createdCount、更新：$updatedCount、未變更：$unchangedCount）"
        }
        $packageStatus = if ([bool]$ccusage.PackageInstalledNow) { '已安裝 ccusage 套件' } elseif ([bool]$ccusageBefore.Installed) { '沿用既有 ccusage 套件' } else { '已略過 ccusage 套件' }
        $commandStatus = if ([bool]$ccusage.CommandsUpdated) { '已更新 ccsessions、cdaily 指令' } else { 'ccsessions、cdaily 指令未變更' }
        Write-Host "ccusage：$packageStatus；$commandStatus"
        Write-Host '  ccsessions [數量或 Session ID]：查看 Session 的模型、Token、費用與台北時間。'
        Write-Host '  ccsessions -Json <Session ID>：輸出每輪 Token Hook 使用的機器可讀資料。'
        Write-Host '  cdaily [天數]：查看每日 Token 與費用統計。'
        Write-Host "舊專案設定：處理 $($obsoleteProjects.Projects) 個專案、移除 $($obsoleteProjects.FilesRemoved) 個檔案、更新 $($obsoleteProjects.FilesUpdated) 個檔案"
        Write-Host "交易備份：$transactionRoot"
        Write-Host 'Windows 通知：已送出安裝測試通知。'
        Write-Host '請重新啟動 PowerShell 與 Codex，以載入設定、指令與 MCP。'
    } catch {
        $reason = $_.Exception.Message
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
        try { Undo-FileTransaction $transaction } catch { [void]$rollbackErrors.Add("File rollback failed: $($_.Exception.Message)") }
        if ($null -ne $ccusageBefore) {
            try { Restore-CcusageState $ccusageBefore } catch { [void]$rollbackErrors.Add("ccusage rollback failed: $($_.Exception.Message)") }
        }
        if ($null -ne $contextState -and [bool]$contextState.CreatedNow) {
            try {
                [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $contextState.UserBefore, 'User')
                [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $contextState.ProcessBefore, 'Process')
            } catch { [void]$rollbackErrors.Add("Context7 rollback failed: $($_.Exception.Message)") }
        }
        try {
            Save-TransactionMetadata -Transaction $transaction -Metadata @{
                Status = 'RolledBack'
                RolledBackAt = (Get-Date).ToString('o')
                FailureReason = $reason
                RollbackErrors = $rollbackErrors.ToArray()
            }
        } catch { [void]$rollbackErrors.Add("Journal update failed: $($_.Exception.Message)") }

        $message = "Installation failed and rollback was attempted.`nReason: $reason"
        if ($rollbackErrors.Count -gt 0) { $message += "`nRollback errors:`n- " + ($rollbackErrors -join "`n- ") }
        throw $message
    }
} finally {
    Exit-CodexSettingsLock -Lock $operationLock
}
