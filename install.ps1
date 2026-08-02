[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Git', 'CVS')]
    [string]$Mode = 'Interactive',
    [string[]]$ProjectPath,
    [switch]$SkipContext7Key,
    [switch]$SkipCcusageInstall,
    [switch]$InstallRequestExecutionOptimizer,
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
                    $paths = Select-GlobalProjectPaths
                    & $PSCommandPath -Mode Global -InstallStyle $style -ProjectPath $paths -InstallRequestExecutionOptimizer:$installRequestExecutionOptimizer
                }
                'Git' {
                    $style = Select-InstallStyle
                    $paths = Read-ProjectPaths 'Enter Git project paths (semicolon separated)'
                    & $PSCommandPath -Mode Git -InstallStyle $style -ProjectPath $paths
                }
                'CVS' {
                    $style = Select-InstallStyle
                    $paths = Read-ProjectPaths 'Enter CVS project paths (semicolon separated)'
                    & $PSCommandPath -Mode CVS -InstallStyle $style -ProjectPath $paths
                }
                'Backup' { & (Join-Path $ScriptRoot 'backup.ps1') }
                'Restore' { & (Join-Path $ScriptRoot 'restore.ps1') }
                'Update' { & (Join-Path $ScriptRoot 'update.ps1') }
                'Uninstall' { & (Join-Path $ScriptRoot 'uninstall.ps1') }
            }
        } catch {
            Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red
        }

        Write-Host ''
        [void](Read-Host 'Press Enter to return to the installer menu')
    }
}

if ($Force) { $InstallStyle = 'Replace' }
$Force = $InstallStyle -eq 'Replace'
$targets = @(Resolve-Targets $Mode $ProjectPath -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer)
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
    foreach ($path in $recovered) { Write-Warning "Recovered interrupted transaction: $path" }

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

            $profilePath = $PROFILE.CurrentUserAllHosts
            Save-TransactionFile $transaction $profilePath
            $ccusage = & (Join-Path $ScriptRoot 'install-ccusage.ps1') -SkipPackageInstall:$SkipCcusageInstall -PassThru

            $original = $ccusageBefore
            $installedByPackage = (-not [bool]$ccusageBefore.Installed) -and (-not $SkipCcusageInstall)
            if ($null -ne $global.Previous -and $null -ne $global.Previous.External -and $null -ne $global.Previous.External.Ccusage) {
                $old = $global.Previous.External.Ccusage
                $original = [pscustomobject]@{ Installed = [bool]$old.WasInstalledBefore; Version = [string]$old.PreviousVersion }
                $installedByPackage = [bool]$old.InstalledByPackage
            }

            $external = [ordered]@{
                PowerShellProfile = [ordered]@{
                    Path = $profilePath
                    ExistedBefore = [bool]$ccusage.ProfileExistedBefore
                    PowerShellMajor = $PSVersionTable.PSVersion.Major
                }
                Ccusage = [ordered]@{
                    Managed = $true
                    InstalledByPackage = $installedByPackage
                    WasInstalledBefore = [bool]$original.Installed
                    PreviousVersion = [string]$original.Version
                    CurrentVersion = [string]$ccusage.PackageAfter.Version
                    UsesLatest = $true
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
        Write-Host 'Installation completed successfully.'
        Write-Host "Style  : $InstallStyle"
        Write-Host "Targets: $($results.Count)"
        foreach ($result in $results) {
            $changedCount = @($result.Files | Where-Object Changed).Count
            $createdCount = @($result.Files | Where-Object { -not $_.ExistedBefore }).Count
            $updatedCount = @($result.Files | Where-Object { $_.ExistedBefore -and $_.Changed }).Count
            $unchangedCount = $result.Files.Count - $changedCount
            Write-Host "Target: $($result.Root)"
            Write-Host "Mode  : $($result.Mode)"
            Write-Host "Files : $($result.Files.Count) (created: $createdCount, updated: $updatedCount, unchanged: $unchangedCount)"
        }
        foreach ($registration in $registrations) { Write-Host "Registered project: $($registration.Type) $($registration.Path)" }
        Write-Host "Backup: $transactionRoot"
        if ($Mode -eq 'CVS') { Write-Host 'Restart Codex and use /hooks to review and trust the CVS hook.' }
        else { Write-Host 'Restart PowerShell and Codex to reload settings, commands, and MCP servers.' }
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
