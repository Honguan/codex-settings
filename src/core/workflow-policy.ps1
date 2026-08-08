function Get-CodexChangedInstallationPaths {
    [CmdletBinding()]
    param([AllowNull()][object[]]$Results = @())

    return @($Results | ForEach-Object {
        @($_.Files | Where-Object { [bool]$_.Changed } | ForEach-Object { [string]$_.RelativePath })
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function New-InstallationChangePlan {
    [CmdletBinding()]
    param(
        [AllowNull()]$Discovery = $null,
        [AllowNull()][object[]]$Results = @(),
        [AllowNull()]$CcusageBefore = $null,
        [bool]$ForceValidation = $false,
        [bool]$Force = $false,
        [bool]$ForceNotificationTest = $false,
        [bool]$SkipContext7Key = $false,
        [bool]$InstallMattPocockSkills = $false,
        [bool]$SkipPackageInstall = $false
    )

    $global = @($Results | Where-Object { [string]$_.Mode -eq 'Global' } | Select-Object -First 1)[0]
    $changedPaths = @(Get-CodexChangedInstallationPaths -Results $Results)
    $previousMissing = $null -eq $global -or $null -eq $global.Previous
    $hooksChanged = $previousMissing -or [bool]$global.HookChanged -or @($changedPaths | Where-Object { $_ -eq 'hooks.json' -or $_ -like 'hooks\*' }).Count -gt 0
    $configChanged = @($changedPaths | Where-Object { $_ -eq 'config.toml' }).Count -gt 0
    $profileCurrent = if ($null -ne $Discovery -and $null -ne $Discovery.usageTools) { [bool]$Discovery.usageTools.profileCurrent } else { $false }
    $packageInstalled = $null -ne $CcusageBefore -and [bool]$CcusageBefore.Installed
    $usageToolsChanged = (-not $packageInstalled -and -not $SkipPackageInstall) -or -not $profileCurrent
    $externalPackageChanged = (-not $packageInstalled -and -not $SkipPackageInstall)
    $context7Present = $null -ne $Discovery -and [bool]$Discovery.context7UserPresent
    $fullValidation = $Force -or $ForceValidation -or $previousMissing
    $validationLevel = if ($fullValidation) { 'Full' } elseif ($changedPaths.Count -eq 0 -and -not $usageToolsChanged) { 'Fast' } else { 'ChangedOnly' }
    $targetChanged = @($Results | Where-Object { $_.Summary.Created -gt 0 -or $_.Summary.Updated -gt 0 }).Count -gt 0
    $runHookTrust = $fullValidation -or $hooksChanged
    $runHookValidation = $fullValidation -or $hooksChanged
    $runConfigValidation = $fullValidation -or $configChanged
    $runUsageRuntimeValidation = $fullValidation -or $externalPackageChanged
    $runNotificationTest = $ForceNotificationTest -or $hooksChanged
    $runContext7 = -not $SkipContext7Key -and (-not $context7Present -or $fullValidation)
    $runSkills = [bool]$InstallMattPocockSkills

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        validationLevel = $validationLevel
        changedPathCount = $changedPaths.Count
        changedPaths = $changedPaths
        targetChanged = $targetChanged
        configChanged = $configChanged
        hooksChanged = $hooksChanged
        profileChanged = $usageToolsChanged
        usageToolsChanged = $usageToolsChanged
        notificationsChanged = $hooksChanged
        environmentChanged = $runContext7
        skillsChanged = $runSkills
        externalPackagesChanged = $externalPackageChanged
        manifestChanged = $targetChanged -or $previousMissing -or $usageToolsChanged
        runHookTrust = $runHookTrust
        runHookValidation = $runHookValidation
        runConfigValidation = $runConfigValidation
        runUsageRuntimeValidation = $runUsageRuntimeValidation
        runNotificationTest = $runNotificationTest
        runContext7 = $runContext7
        runSkills = $runSkills
        runMaintenance = $false
        critical = @('ownership-conflict', 'transaction-rollback', 'changed-file-integrity')
        conditional = @('hook-trust', 'hook-validation', 'config-validation', 'usage-runtime-validation', 'notification-test', 'external-package-resolution')
        deferred = @('state-ttl-cleanup', 'log-rotation', 'manifest-reconciliation')
        reason = if ($fullValidation) { 'full-validation-required' } elseif ($changedPaths.Count -eq 0 -and -not $usageToolsChanged) { 'no-managed-change' } else { 'changed-components-only' }
    }
}

function Test-CodexWorkflowDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][ValidateSet('HookTrust', 'HookValidation', 'ConfigValidation', 'UsageRuntimeValidation', 'NotificationTest', 'Context7', 'Skills')][string]$Operation
    )

    $property = switch ($Operation) {
        'HookTrust' { 'runHookTrust' }
        'HookValidation' { 'runHookValidation' }
        'ConfigValidation' { 'runConfigValidation' }
        'UsageRuntimeValidation' { 'runUsageRuntimeValidation' }
        'NotificationTest' { 'runNotificationTest' }
        'Context7' { 'runContext7' }
        'Skills' { 'runSkills' }
    }
    return $null -ne $Plan -and $null -ne $Plan.PSObject.Properties[$property] -and [bool]$Plan.$property
}

function Get-CodexMaintenanceDecision {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$LastMaintenanceAt = '',
        [datetime]$Now = (Get-Date).ToUniversalTime(),
        [timespan]$Interval = ([timespan]::FromDays(1))
    )

    if ([string]::IsNullOrWhiteSpace($LastMaintenanceAt)) {
        return [pscustomobject][ordered]@{ due = $true; reason = 'never-run'; lastMaintenanceAt = $null }
    }
    try {
        $last = [datetime]::Parse($LastMaintenanceAt).ToUniversalTime()
        $due = $Now.ToUniversalTime() - $last -lt [timespan]::Zero -or $Now.ToUniversalTime() - $last -ge $Interval
        return [pscustomobject][ordered]@{ due = $due; reason = if ($due) { 'interval-elapsed' } else { 'recently-completed' }; lastMaintenanceAt = $last.ToString('o') }
    } catch {
        return [pscustomobject][ordered]@{ due = $true; reason = 'invalid-state'; lastMaintenanceAt = $LastMaintenanceAt }
    }
}
