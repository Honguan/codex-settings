$script:CsStartMarker = '# >>> CS CODEX SESSION VIEWER >>>'
$script:CsEndMarker = '# <<< CS CODEX SESSION VIEWER <<<'
$script:CdailyStartMarker = '# >>> CDAILY CODEX DAILY REPORT >>>'
$script:CdailyEndMarker = '# <<< CDAILY CODEX DAILY REPORT <<<'

function Remove-CcusageProfileBlocks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $result = Remove-ManagedBlock -Content $Content -StartMarker $script:CsStartMarker -EndMarker $script:CsEndMarker
    return Remove-ManagedBlock -Content $result -StartMarker $script:CdailyStartMarker -EndMarker $script:CdailyEndMarker
}

function Get-CcusageState {
    [CmdletBinding()]
    param()

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Installed = $false; Version = $null } }
    $output = & npm list --global ccusage --depth=0 --json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($output | Out-String))) { return [pscustomobject]@{ Installed = $false; Version = $null } }
    try {
        $data = ($output | Out-String) | ConvertFrom-Json -ErrorAction Stop
        $version = [string]$data.dependencies.ccusage.version
        return [pscustomobject]@{ Installed = -not [string]::IsNullOrWhiteSpace($version); Version = if ([string]::IsNullOrWhiteSpace($version)) { $null } else { $version } }
    } catch { return [pscustomobject]@{ Installed = $false; Version = $null } }
}

function Test-CcusageProfileCurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TemplatePath)

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { return $false }
    $managed = ([IO.File]::ReadAllText($TemplatePath) -replace "`r`n|`r", "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($managed)) { return $false }
    foreach ($profilePath in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { return $false }
        $content = ([IO.File]::ReadAllText($profilePath) -replace "`r`n|`r", "`n")
        if (-not $content.Contains($managed)) { return $false }
    }
    return $true
}

function New-CcusageUnchangedResult {
    [CmdletBinding()]
    param([AllowNull()]$PackageState = $null)

    $paths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
    return [pscustomobject][ordered]@{
        ProfilePath = $paths[0]
        ProfileExistedBefore = [bool](Test-Path -LiteralPath $paths[0] -PathType Leaf)
        ProfileBackupPath = $null
        ProfilePaths = $paths
        ProfileStates = @($paths | ForEach-Object { [pscustomobject]@{ Path = $_; ExistedBefore = [bool](Test-Path -LiteralPath $_ -PathType Leaf) } })
        ProfileBackupPaths = @()
        PackageBefore = $PackageState
        PackageAfter = $PackageState
        PackageInstalledNow = $false
        CommandsUpdated = $false
        PowerShellVersion = [string]$PSVersionTable.PSVersion
        Skipped = $true
    }
}

function Restore-CcusageState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm is required to restore the ccusage package state.' }
    if ([bool]$State.Installed) {
        if ([string]::IsNullOrWhiteSpace([string]$State.Version)) { throw 'The previous ccusage version is missing.' }
        & npm install --global ("ccusage@{0}" -f [string]$State.Version)
    } else {
        & npm uninstall --global ccusage
    }
    if ($LASTEXITCODE -ne 0) { throw "Unable to restore the ccusage package state. npm exit code: $LASTEXITCODE" }
}
