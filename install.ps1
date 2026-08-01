[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Git', 'CVS')]
    [string]$Mode = 'Interactive',
    [string]$ProjectPath,
    [switch]$SkipContext7Key,
    [switch]$SkipCcusageInstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupBase = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'
. (Join-Path $ScriptRoot 'lib\codex-settings-common.ps1')
. (Join-Path $ScriptRoot 'lib\install-functions.ps1')
. (Join-Path $ScriptRoot 'lib\project-registry.ps1')

if ($Mode -eq 'Interactive') { $Mode = Select-Mode }
$targets = @(Resolve-Targets $Mode $ProjectPath)
$preflight = if ($Mode -eq 'Global') { Join-Path $HOME '.codex' } else { $targets[0].Root }
Test-Prerequisites $Mode $preflight

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

        if ($Mode -in @('Git', 'CVS')) {
            $registryPath = Get-CodexProjectRegistryPath
            Save-TransactionFile $transaction $registryPath
            $registration = Register-CodexProject -Type $Mode -Path $targets[0].Root
        }

        Complete-FileTransaction -Transaction $transaction

        Write-Host ''
        Write-Host 'Installation completed successfully.'
        foreach ($result in $results) {
            $changedCount = @($result.Files | Where-Object Changed).Count
            Write-Host "Target: $($result.Root)"
            Write-Host "Files : $($result.Files.Count) (changed: $changedCount)"
        }
        if ($null -ne $registration) { Write-Host "Registered project: $($registration.Type) $($registration.Path)" }
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
