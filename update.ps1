[CmdletBinding()]
param(
    [switch]$Reinstall
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) {
    throw 'Git is required to update this settings repository.'
}

if (-not (Test-Path -LiteralPath (Join-Path $ScriptRoot '.git'))) {
    throw 'This folder is not a Git clone. Clone the repository before using update.ps1.'
}

$dirty = & git -C $ScriptRoot status --porcelain
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect the repository status.'
}
if ($dirty) {
    throw 'The settings repository has local changes. Commit or discard them before updating.'
}

& git -C $ScriptRoot pull --ff-only
if ($LASTEXITCODE -ne 0) {
    throw 'git pull --ff-only failed.'
}

Write-Host ''
Write-Host 'Repository updated.'

if (-not $Reinstall) {
    $answer = Read-Host 'Run the installer now? [y/N]'
    $Reinstall = $answer -in @('y', 'Y', 'yes', 'YES')
}

if ($Reinstall) {
    & (Join-Path $ScriptRoot 'install.ps1')
    exit $LASTEXITCODE
}
