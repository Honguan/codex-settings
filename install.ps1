[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Git', 'CVS')]
    [string]$Mode = 'Interactive',
    [string]$ProjectPath,
    [switch]$SkipContext7Key,
    [switch]$SkipCcusageInstall
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
$transactionRoot = Join-Path $BackupBase ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$($Mode.ToLowerInvariant())-transaction")
$transaction = New-FileTransaction $transactionRoot
$ccusageBefore = if ($Mode -eq 'Global') { Get-CcusageState } else { $null }
$contextState = $null
$registration = $null
$results = New-Object 'System.Collections.Generic.List[object]'

try {
    foreach ($target in $targets) { [void]$results.Add((Install-Target $target $transaction)) }
    $external = $null

    if ($Mode -eq 'Global') {
        $global = @($results | Where-Object Mode -eq 'Global' | Select-Object -First 1)[0]
        $contextState = Set-Context7Key -Skip:$SkipContext7Key -PreviousManifest $global.Previous
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
            PowerShellProfile = [ordered]@{ Path = $profilePath; ExistedBefore = [bool]$ccusage.ProfileExistedBefore }
            Ccusage = [ordered]@{
                Managed = $true; InstalledByPackage = $installedByPackage
                WasInstalledBefore = [bool]$original.Installed; PreviousVersion = [string]$original.Version
                CurrentVersion = [string]$ccusage.PackageAfter.Version; UsesLatest = $true
            }
            Context7 = [ordered]@{
                EnvironmentVariable = 'CONTEXT7_API_KEY'; CreatedByInstaller = [bool]$contextState.CreatedByInstaller
                SecretStoredInRepository = $false
            }
        }
    }

    foreach ($result in $results) { Write-Manifest $result $transaction $(if ($result.Mode -eq 'Global') { $external } else { $null }) }

    if ($Mode -in @('Git', 'CVS')) {
        $registryPath = Get-CodexProjectRegistryPath
        Save-TransactionFile $transaction $registryPath
        $registration = Register-CodexProject -Type $Mode -Path $targets[0].Root
    }

    Save-TransactionMetadata $transaction @{
        Mode = $Mode; Status = 'Completed'; CcusageBefore = $ccusageBefore
        Context7KeyWasPresent = if ($null -eq $contextState) { $false } else { -not [string]::IsNullOrWhiteSpace([string]$contextState.UserBefore) }
        Context7KeyCreatedNow = if ($null -eq $contextState) { $false } else { [bool]$contextState.CreatedNow }
    }

    Write-Host ''
    Write-Host 'Installation completed successfully.'
    foreach ($result in $results) { Write-Host "Target: $($result.Root)"; Write-Host "Files : $($result.Files.Count)" }
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
    $message = "Installation failed and rollback was attempted.`nReason: $reason"
    if ($rollbackErrors.Count -gt 0) { $message += "`nRollback errors:`n- " + ($rollbackErrors -join "`n- ") }
    throw $message
}
