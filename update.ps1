[CmdletBinding()]
param(
    [switch]$SkipRepositoryPull,
    [switch]$SkipGlobal,
    [switch]$SkipCcusageInstall
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $SkipRepositoryPull) {
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptRoot '.git'))) {
        Write-Host '發佈安裝包不含 Git 工作目錄；略過儲存庫更新，套用目前解壓縮的版本。'
    } else {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw 'Git is required to update this settings repository.'
        }

        $dirty = & git -C $ScriptRoot status --porcelain
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to inspect the settings repository status.'
        }
        if ($dirty) {
            throw 'The settings repository has local changes. Commit or discard them before updating.'
        }

        & git -C $ScriptRoot pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            throw 'git pull --ff-only failed.'
        }

        Write-Host 'Settings repository updated.'
    }
} else {
    Write-Host 'Settings repository pull skipped.'
}

$registryLibrary = Join-Path $ScriptRoot 'lib\project-registry.ps1'
$installer = Join-Path $ScriptRoot 'install.ps1'
if (-not (Test-Path -LiteralPath $registryLibrary -PathType Leaf)) {
    throw "Project registry library is missing: $registryLibrary"
}
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "Installer is missing: $installer"
}
. $registryLibrary

$results = New-Object 'System.Collections.Generic.List[object]'

function Add-UpdateResult {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][bool]$Succeeded,
        [string]$Reason
    )

    [void]$results.Add([pscustomobject]@{
        Scope = $Scope
        Target = $Target
        Status = if ($Succeeded) { 'Updated' } else { 'Failed' }
        Reason = $Reason
    })
}

if (-not $SkipGlobal) {
    Write-Host ''
    Write-Host 'Updating global settings...'
    try {
        & $installer -Mode Global -SkipContext7Key -SkipCcusageInstall:$SkipCcusageInstall
        Add-UpdateResult -Scope 'Global' -Target (Join-Path $HOME '.codex') -Succeeded $true
    } catch {
        Add-UpdateResult -Scope 'Global' -Target (Join-Path $HOME '.codex') -Succeeded $false -Reason $_.Exception.Message
    }
}

$projects = @(Get-RegisteredCodexProjects)
foreach ($project in $projects) {
    $type = [string]$project.Type
    $path = [string]$project.Path

    Write-Host ''
    Write-Host "Updating registered $type project: $path"

    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Add-UpdateResult -Scope $type -Target $path -Succeeded $false -Reason 'Registered project directory does not exist.'
        continue
    }

    try {
        & $installer -Mode $type -ProjectPath $path
        Add-UpdateResult -Scope $type -Target $path -Succeeded $true
    } catch {
        Add-UpdateResult -Scope $type -Target $path -Succeeded $false -Reason $_.Exception.Message
    }
}

Write-Host ''
Write-Host 'Update summary'
Write-Host '=============='
if ($results.Count -eq 0) {
    Write-Host 'No update targets were selected or registered.'
    exit 0
}

$results | Select-Object Scope, Status, Target | Format-Table -AutoSize -Wrap | Out-Host
$failures = @($results | Where-Object Status -eq 'Failed')
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Failures:'
    foreach ($failure in $failures) {
        Write-Host "- [$($failure.Scope)] $($failure.Target)"
        Write-Host "  $($failure.Reason)"
    }
    Write-Host ''
    Write-Host "Updated: $($results.Count - $failures.Count); Failed: $($failures.Count)"
    exit 1
}

Write-Host "Updated: $($results.Count); Failed: 0"
Write-Host 'Restart PowerShell and Codex to reload updated settings.'
