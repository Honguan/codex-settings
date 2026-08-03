[CmdletBinding()]
param(
    [switch]$SkipPackageInstall,
    [switch]$SkipRuntimeValidation,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'lib\codex-settings-common.ps1')

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or newer is required to install ccsessions and cdaily. Current: $($PSVersionTable.PSVersion)"
}

$templatePath = Join-Path $ScriptRoot 'templates\powershell\ccusage-profile.ps1'
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "ccusage profile template was not found: $templatePath"
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw 'npm was not found. Install Node.js before installing ccusage.'
}
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    throw 'npx was not found. Reinstall Node.js with npm package-runner support.'
}

$packageBefore = Get-CcusageState
$profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
$profileTargets = foreach ($profilePath in $profilePaths) {
    Test-DirectoryWritable -Path (Split-Path -Parent $profilePath)
    $profileState = Get-TextFileState -Path $profilePath
    $backupPath = $null
    if ($profileState.Exists) {
        $backupPath = "$profilePath.ccusage-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
        Copy-FileAtomic -Source $profilePath -Destination $backupPath
    }
    [pscustomobject]@{
        Path = $profilePath
        State = $profileState
        BackupPath = $backupPath
    }
}

try {
    if (-not $SkipPackageInstall) {
        $installOutput = & npm install --global 'ccusage@latest' 2>&1
        $installExitCode = $LASTEXITCODE
        $installOutput | Out-Host
        if ($installExitCode -ne 0) {
            throw "ccusage@latest installation failed with npm exit code $installExitCode.`n$($installOutput | Out-String)"
        }
    }

    $managedContent = [IO.File]::ReadAllText($templatePath).Trim()
    foreach ($profileTarget in $profileTargets) {
        $existingContent = Remove-CcusageProfileBlocks -Content $profileTarget.State.Content
        $newContent = if ([string]::IsNullOrWhiteSpace($existingContent)) {
            $managedContent + $profileTarget.State.NewLine
        } else {
            $existingContent.TrimEnd() + $profileTarget.State.NewLine + $profileTarget.State.NewLine + $managedContent + $profileTarget.State.NewLine
        }

        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($newContent, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            $firstError = $parseErrors[0]
            throw "PowerShell profile validation failed for $($profileTarget.Path) at line $($firstError.Extent.StartLineNumber): $($firstError.Message)"
        }

        Write-TextFileState -Path $profileTarget.Path -Content $newContent -Encoding $profileTarget.State.Encoding
    }

    Remove-Item Function:\ccsessions, Function:\cdaily -Force -ErrorAction SilentlyContinue
    . $templatePath | Out-Null

    if (-not (Get-Command ccsessions -ErrorAction SilentlyContinue)) {
        throw "The ccsessions function was not loaded from template: $templatePath"
    }
    if (-not (Get-Command cdaily -ErrorAction SilentlyContinue)) {
        throw "The cdaily function was not loaded from template: $templatePath"
    }

    if (-not $SkipRuntimeValidation) {
        $versionOutput = & npx --yes 'ccusage@latest' --version 2>&1
        $versionExitCode = $LASTEXITCODE
        if ($versionExitCode -ne 0) {
            throw "ccusage@latest runtime validation failed with exit code $versionExitCode.`n$($versionOutput | Out-String)"
        }
    }

    $packageAfter = Get-CcusageState
    $allHostsTarget = $profileTargets | Where-Object { $_.Path -eq $PROFILE.CurrentUserAllHosts } | Select-Object -First 1
    $result = [pscustomobject]@{
        ProfilePath = $allHostsTarget.Path
        ProfileExistedBefore = [bool]$allHostsTarget.State.Exists
        ProfileBackupPath = $allHostsTarget.BackupPath
        ProfilePaths = @($profileTargets.Path)
        ProfileBackupPaths = @($profileTargets.BackupPath | Where-Object { $null -ne $_ })
        PackageBefore = $packageBefore
        PackageAfter = $packageAfter
        InstalledLatest = -not $SkipPackageInstall
        PowerShellVersion = [string]$PSVersionTable.PSVersion
    }

    if ($PassThru) { return $result }

    Write-Host 'ccusage@latest, ccsessions, and cdaily installed successfully.'
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
    foreach ($profileTarget in $profileTargets) { Write-Host "Profile   : $($profileTarget.Path)" }
    foreach ($profileTarget in $profileTargets) {
        if ($profileTarget.BackupPath) { Write-Host "Backup    : $($profileTarget.BackupPath)" }
    }
} catch {
    $primaryError = $_.Exception.Message
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'

    try {
        foreach ($profileTarget in $profileTargets) {
            if ($profileTarget.State.Exists) {
                Copy-FileAtomic -Source $profileTarget.BackupPath -Destination $profileTarget.Path
            } else {
                Remove-Item -LiteralPath $profileTarget.Path -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        [void]$rollbackErrors.Add("Profile rollback failed: $($_.Exception.Message)")
    }

    if (-not $SkipPackageInstall) {
        try { Restore-CcusageState -State $packageBefore }
        catch { [void]$rollbackErrors.Add("ccusage rollback failed: $($_.Exception.Message)") }
    }

    $message = "ccusage setup failed: $primaryError"
    if ($rollbackErrors.Count -gt 0) { $message += "`nRollback errors:`n- " + ($rollbackErrors -join "`n- ") }
    throw $message
}
