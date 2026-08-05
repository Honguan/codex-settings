[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Git', 'CVS', 'Backup', 'Restore', 'Update', 'Uninstall')]
    [string]$Mode = 'Interactive',
    [string[]]$ProjectPath,
    [switch]$SkipContext7Key,
    [switch]$SkipCcusageInstall,
    [switch]$InstallRequestExecutionOptimizer,
    [switch]$EnableDefaultModeRequestUserInput,
    [switch]$Force,
    [ValidateSet('Merge', 'Replace')]
    [string]$InstallStyle = 'Merge'
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupBase = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'
. (Join-Path $ScriptRoot 'lib\codex-settings-common.ps1')
. (Join-Path $ScriptRoot 'lib\install-functions.ps1')
. (Join-Path $ScriptRoot 'lib\project-registry.ps1')

if ($Mode -eq 'Interactive') {
    while ($true) {
        try {
            $selection = Select-Mode
            if ($selection -eq 'Exit') { return }

            switch ($selection) {
                'Global' {
                    $style = Select-InstallStyle
                    $installRequestExecutionOptimizer = Select-OptionalGlobalSkill
                    $enableDefaultModeRequestUserInput = Select-OptionalDefaultModeRequestUserInput
                    $paths = Select-GlobalProjectPaths
                    & $PSCommandPath -Mode Global -InstallStyle $style -ProjectPath $paths -InstallRequestExecutionOptimizer:$installRequestExecutionOptimizer -EnableDefaultModeRequestUserInput:$enableDefaultModeRequestUserInput
                }
                'Git' {
                    $style = Select-InstallStyle
                    $paths = Read-ProjectPaths '輸入 Git 專案路徑（以分號分隔）'
                    & $PSCommandPath -Mode Git -InstallStyle $style -ProjectPath $paths
                }
                'CVS' {
                    $style = Select-InstallStyle
                    $paths = Read-ProjectPaths '輸入 CVS 專案路徑（以分號分隔）'
                    & $PSCommandPath -Mode CVS -InstallStyle $style -ProjectPath $paths
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

if ($Mode -in @('Backup', 'Restore', 'Update', 'Uninstall')) {
    $actionScript = Join-Path $ScriptRoot ("{0}.ps1" -f $Mode.ToLowerInvariant())
    if (-not (Test-Path -LiteralPath $actionScript -PathType Leaf)) { throw "管理功能不存在：$actionScript" }
    & $actionScript
    return
}

if ($Force) { $InstallStyle = 'Replace' }
$Force = $InstallStyle -eq 'Replace'
$targets = @(Resolve-Targets $Mode $ProjectPath -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput)
$preflight = if ($Mode -eq 'Global') { Join-Path $HOME '.codex' } else { $targets[0].Root }
Test-Prerequisites $Mode $preflight
foreach ($target in $targets) { Test-DirectoryWritable -Path $target.Root }

New-Item -ItemType Directory -Path $BackupBase -Force | Out-Null
$operationLock = $null
$transaction = $null
$ccusageBefore = $null
$contextState = $null

try {
    $operationLock = Enter-CodexSettingsLock
    $recovered = @(Repair-PendingTransactions -BackupRoot $BackupBase)
    foreach ($path in $recovered) { Write-Warning "已回復中斷的交易：$path" }

    $transactionRoot = Join-Path $BackupBase ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$($Mode.ToLowerInvariant())-transaction")
    $transaction = New-FileTransaction -Root $transactionRoot -Mode "Install-$Mode"
    $ccusageBefore = if ($Mode -eq 'Global') { Get-CcusageState } else { $null }
    $context7KeyWasPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))
    $context7MayCreate = $Mode -eq 'Global' -and (-not $SkipContext7Key) -and (-not $context7KeyWasPresent)

    Save-TransactionMetadata -Transaction $transaction -Metadata @{
        Mode = $Mode
        Status = 'InProgress'
        CcusageBefore = $ccusageBefore
        Context7KeyWasPresent = $context7KeyWasPresent
        Context7InstallerMayCreate = $context7MayCreate
        Context7KeyCreatedNow = $false
    }

    $registration = $null
    $registrations = New-Object 'System.Collections.Generic.List[object]'
    $results = New-Object 'System.Collections.Generic.List[object]'

    try {
        foreach ($target in $targets) { [void]$results.Add((Install-Target $target $transaction -Force:$Force)) }
        $external = $null

        if ($Mode -eq 'Global') {
            $global = @($results | Where-Object Mode -eq 'Global' | Select-Object -First 1)[0]
            $contextState = Set-Context7Key -Skip:$SkipContext7Key -PreviousManifest $global.Previous
            Save-TransactionMetadata -Transaction $transaction -Metadata @{
                Context7KeyCreatedNow = [bool]$contextState.CreatedNow
            }

            $profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
            foreach ($profilePath in $profilePaths) { Save-TransactionFile $transaction $profilePath }
            $ccusage = & (Join-Path $ScriptRoot 'install-ccusage.ps1') -SkipPackageInstall:$SkipCcusageInstall -PackageState $ccusageBefore -PassThru

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
        }

        foreach ($result in $results) {
            Write-Manifest $result $transaction $(if ($result.Mode -eq 'Global') { $external } else { $null })
        }

        $projectResults = @($results | Where-Object { $_.Mode -in @('Git', 'CVS') })
        if ($projectResults.Count -gt 0) {
            $registryPath = Get-CodexProjectRegistryPath
            Save-TransactionFile $transaction $registryPath
            foreach ($project in $projectResults) {
                [void]$registrations.Add((Register-CodexProject -Type $project.Mode -Path $project.Root))
            }
        }

        Complete-FileTransaction -Transaction $transaction

        Write-Host ''
        Write-Host '安裝完成。'
        Write-Host "方式：$InstallStyle"
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
        if ($Mode -eq 'Global') {
            $packageStatus = if ([bool]$ccusage.PackageInstalledNow) { '已安裝 ccusage 套件' } elseif ([bool]$ccusageBefore.Installed) { '沿用既有 ccusage 套件' } else { '已略過 ccusage 套件' }
            $commandStatus = if ([bool]$ccusage.CommandsUpdated) { '已更新 ccsessions、cdaily 指令' } else { 'ccsessions、cdaily 指令未變更' }
            Write-Host "ccusage：$packageStatus；$commandStatus"
        }
        foreach ($registration in $registrations) { Write-Host "已登記專案：$($registration.Type) $($registration.Path)" }
        Write-Host "交易備份：$transactionRoot"
        if ($Mode -eq 'CVS') { Write-Host '請重新啟動 Codex，並使用 /hooks 檢閱及信任 CVS Hook。' }
        else { Write-Host '請重新啟動 PowerShell 與 Codex，以載入設定、指令與 MCP。' }
    } catch {
        $reason = $_.Exception.Message
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
        try { Undo-FileTransaction $transaction } catch { [void]$rollbackErrors.Add("File rollback failed: $($_.Exception.Message)") }
        if ($Mode -eq 'Global' -and $null -ne $ccusageBefore) {
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
