function Get-InstallationDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][object[]]$Targets,
        [AllowNull()]$CcusageBefore = $null
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

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToUniversalTime().ToString('o')
        sourceRoot = [string]$Context.ScriptRoot
        globalRoot = [string]$Context.GlobalRoot
        developmentEnvironment = [string]$Context.DevelopmentEnvironment
        installStyle = [string]$Context.InstallStyle
        targetSnapshots = $targetSnapshots.ToArray()
        ccusage = $CcusageBefore
        context7UserPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))
    }
}
