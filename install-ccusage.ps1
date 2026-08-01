[CmdletBinding()]
param(
    [switch]$SkipPackageInstall
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templatePath = Join-Path $ScriptRoot 'templates\powershell\ccusage-profile.ps1'

if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "ccusage profile template was not found: $templatePath"
}

if (-not $SkipPackageInstall) {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw 'npm was not found. Install Node.js before installing ccusage.'
    }

    & npm install --global 'ccusage@latest'
    if ($LASTEXITCODE -ne 0) {
        throw "ccusage installation failed with exit code $LASTEXITCODE."
    }
}

$profilePath = $PROFILE.CurrentUserAllHosts
$profileDirectory = Split-Path -Parent $profilePath
New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null

$existingBytes = if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    [IO.File]::ReadAllBytes($profilePath)
} else {
    [byte[]]@()
}

$encoding = New-Object Text.UTF8Encoding($false)
if ($existingBytes.Length -ge 3 -and $existingBytes[0] -eq 0xEF -and $existingBytes[1] -eq 0xBB -and $existingBytes[2] -eq 0xBF) {
    $encoding = New-Object Text.UTF8Encoding($true)
} elseif ($existingBytes.Length -ge 2 -and $existingBytes[0] -eq 0xFF -and $existingBytes[1] -eq 0xFE) {
    $encoding = [Text.Encoding]::Unicode
} elseif ($existingBytes.Length -ge 2 -and $existingBytes[0] -eq 0xFE -and $existingBytes[1] -eq 0xFF) {
    $encoding = [Text.Encoding]::BigEndianUnicode
}

$existingContent = if ($existingBytes.Length -gt 0) {
    $encoding.GetString($existingBytes).TrimStart([char]0xFEFF)
} else {
    ''
}

$backupPath = $null
if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    $backupPath = "$profilePath.ccusage-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $profilePath -Destination $backupPath -Force
}

foreach ($markers in @(
    @('# >>> CS CODEX SESSION VIEWER >>>', '# <<< CS CODEX SESSION VIEWER <<<'),
    @('# >>> CDAILY CODEX DAILY REPORT >>>', '# <<< CDAILY CODEX DAILY REPORT <<<')
)) {
    $pattern = '(?ms)^' + [regex]::Escape($markers[0]) + '\r?\n.*?^' + [regex]::Escape($markers[1]) + '\r?\n?'
    $existingContent = [regex]::Replace($existingContent, $pattern, '')
}

$managedContent = [IO.File]::ReadAllText($templatePath)
$newContent = if ([string]::IsNullOrWhiteSpace($existingContent)) {
    $managedContent.Trim() + "`r`n"
} else {
    $existingContent.TrimEnd() + "`r`n`r`n" + $managedContent.Trim() + "`r`n"
}

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput($newContent, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "PowerShell profile validation failed: $($parseErrors[0].Message)"
}

[IO.File]::WriteAllText($profilePath, $newContent, $encoding)
Remove-Item Function:\cs, Function:\cdaily -Force -ErrorAction SilentlyContinue
. $profilePath

if (-not (Get-Command cs -ErrorAction SilentlyContinue) -or -not (Get-Command cdaily -ErrorAction SilentlyContinue)) {
    throw 'cs or cdaily could not be loaded from the updated profile.'
}

Write-Host 'ccusage, cs, and cdaily installed successfully.'
Write-Host "Profile: $profilePath"
if ($backupPath) {
    Write-Host "Backup : $backupPath"
}
