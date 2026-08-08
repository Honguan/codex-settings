function Invoke-InstallationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Targets,
        [Parameter(Mandatory = $true)]$Transaction,
        [switch]$Force
    )

    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in @($Targets)) {
        [void]$results.Add((Invoke-TargetInstallation -Target $target -Transaction $Transaction -Force:$Force))
    }
    return $results.ToArray()
}
