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
    throw "PowerShell 7 or newer is required to install cs and cdaily. Current: $($PSVersionTable.PSVersion)"
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

$profilePath = $PROFILE.CurrentUserAllHosts
$profileDirectory = Split-Path -Parent $profilePath
Test-DirectoryWritable -Path $profileDirectory

$packageBefore = Get-CcusageState
$profileState = Get-TextFileState -Path $profilePath
$backupPath = $null
if ($profileState.Exists) {
    $backupPath = "$profilePath.ccusage-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
    Copy-FileAtomic -Source $profilePath -Destination $backupPath
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

    $existingContent = Remove-CcusageProfileBlocks -Content $profileState.Content
    $managedContent = [IO.File]::ReadAllText($templatePath).Trim()
    $newContent = if ([string]::IsNullOrWhiteSpace($existingContent)) {
        $managedContent + $profileState.NewLine
    } else {
        $existingContent.TrimEnd() + $profileState.NewLine + $profileState.NewLine + $managedContent + $profileState.NewLine
    }

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($newContent, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $firstError = $parseErrors[0]
        throw "PowerShell profile validation failed at line $($firstError.Extent.StartLineNumber): $($firstError.Message)"
    }

    Write-TextFileState -Path $profilePath -Content $newContent -Encoding $profileState.Encoding
    Remove-Item Function:\cs, Function:\cdaily -Force -ErrorAction SilentlyContinue
    . $profilePath | Out-Null

    if (-not (Get-Command cs -ErrorAction SilentlyContinue)) {
        throw "The cs function was not loaded from: $profilePath"
    }
    if (-not (Get-Command cdaily -ErrorAction SilentlyContinue)) {
        throw "The cdaily function was not loaded from: $profilePath"
    }

    if (-not $SkipRuntimeValidation) {
        $versionOutput = & npx --yes 'ccusage@latest' --version 2>&1
        $versionExitCode = $LASTEXITCODE
        if ($versionExitCode -ne 0) {
            throw "ccusage@latest runtime validation failed with exit code $versionExitCode.`n$($versionOutput | Out-String)"
        }
    }

    $packageAfter = Get-CcusageState
    $result = [pscustomobject]@{
        ProfilePath = $profilePath
        ProfileExistedBefore = [bool]$profileState.Exists
        ProfileBackupPath = $backupPath
        PackageBefore = $packageBefore
        PackageAfter = $packageAfter
        InstalledLatest = -not $SkipPackageInstall
        PowerShellVersion = [string]$PSVersionTable.PSVersion
    }

    if ($PassThru) { return $result }

    Write-Host 'ccusage@latest, cs, and cdaily installed successfully.'
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "Profile   : $profilePath"
    if ($backupPath) { Write-Host "Backup    : $backupPath" }
} catch {
    $primaryError = $_.Exception.Message
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'

    try {
        if ($profileState.Exists) {
            Copy-FileAtomic -Source $backupPath -Destination $profilePath
        } else {
            Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
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
