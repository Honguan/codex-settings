function Get-InstallationDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][object[]]$Targets,
        [AllowNull()]$CcusageBefore = $null,
        [AllowNull()]$SerenaDashboard = $null
    )

    $targetSnapshots = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in @($Targets)) {
        $manifest = Get-Manifest -Root $target.Root
        [void]$targetSnapshots.Add([pscustomobject][ordered]@{
            targetId = [string]$target.Id
            root = [string]$target.Root
            manifest = $manifest
            manifestVersion = if ($null -eq $manifest) { $null } else { [int]$manifest.Version }
            existingFiles = if ($null -eq $manifest) { @() } else { @($manifest.Files) }
        })
    }

    $usageTemplatePath = Join-Path $Context.ScriptRoot 'templates\profile\usage-commands.ps1'
    $profileCurrent = Test-CcusageProfileCurrent -TemplatePath $usageTemplatePath

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToUniversalTime().ToString('o')
        sourceRoot = [string]$Context.ScriptRoot
        globalRoot = [string]$Context.GlobalRoot
        developmentEnvironment = [string]$Context.DevelopmentEnvironment
        installStyle = [string]$Context.InstallStyle
        targetSnapshots = $targetSnapshots.ToArray()
        ccusage = $CcusageBefore
        usageTools = [ordered]@{
            profileCurrent = $profileCurrent
            profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
        }
        windowsUsageNotifications = Get-WindowsNotificationLifecycleState -Root $Context.GlobalRoot
        context7UserPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))
        serenaDashboard = $SerenaDashboard
    }
}
