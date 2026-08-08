function Invoke-InstallationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Targets,
        [Parameter(Mandatory = $true)]$Transaction,
        [AllowNull()]$Discovery = $null,
        [switch]$Force
    )

    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in @($Targets)) {
        $previous = $null
        if ($null -ne $Discovery) {
            $snapshot = @($Discovery.targetSnapshots | Where-Object { [string]$_.targetId -eq [string]$target.Id } | Select-Object -First 1)[0]
            if ($null -ne $snapshot) { $previous = $snapshot.manifest }
        }
        [void]$results.Add((Invoke-TargetInstallation -Target $target -Transaction $Transaction -Force:$Force -PreviousManifest $previous))
    }
    return $results.ToArray()
}
