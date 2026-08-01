[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Project', 'All')]
    [string]$Mode = 'Interactive',

    [string]$ProjectPath,

    [string]$DestinationRoot = (Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup')
)

$ErrorActionPreference = 'Stop'

function Copy-ExistingItem {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return 0
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    return 1
}

if ($Mode -eq 'Interactive') {
    Write-Host ''
    Write-Host 'Backup Codex Settings'
    Write-Host '====================='
    Write-Host '[1] Global settings'
    Write-Host '[2] Project settings'
    Write-Host '[3] Global and project settings'
    Write-Host '[0] Exit'
    Write-Host ''

    switch (Read-Host 'Select') {
        '1' { $Mode = 'Global' }
        '2' { $Mode = 'Project' }
        '3' { $Mode = 'All' }
        '0' { exit 0 }
        default { throw 'Invalid selection.' }
    }
}

if (($Mode -eq 'Project' -or $Mode -eq 'All') -and [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Read-Host 'Enter the project root'
}

if ($Mode -eq 'Project' -or $Mode -eq 'All') {
    $ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
}

New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
$backupRoot = Join-Path $DestinationRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff-manual')
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

$itemCount = 0
$metadata = [ordered]@{
    Version = 1
    CreatedAt = (Get-Date).ToString('o')
    Mode = $Mode
    GlobalHome = $HOME
    ProjectRoot = $ProjectPath
}

if ($Mode -eq 'Global' -or $Mode -eq 'All') {
    $codexHome = Join-Path $HOME '.codex'
    $globalTarget = Join-Path $backupRoot 'global\.codex'

    foreach ($name in @('AGENTS.md', 'AGENTS.override.md', 'config.toml', 'rules', 'agents', 'hooks', '.codex-settings-manifest.json')) {
        $itemCount += Copy-ExistingItem -Source (Join-Path $codexHome $name) -Destination (Join-Path $globalTarget $name)
    }

    $userSkills = Join-Path $HOME '.agents\skills'
    $itemCount += Copy-ExistingItem -Source $userSkills -Destination (Join-Path $backupRoot 'global\.agents\skills')
}

if ($Mode -eq 'Project' -or $Mode -eq 'All') {
    $projectTarget = Join-Path $backupRoot 'project'
    foreach ($name in @('AGENTS.md', 'AGENTS.override.md', '.codex-root', '.codex', '.agents\skills', '.codex-settings-manifest.json')) {
        $itemCount += Copy-ExistingItem -Source (Join-Path $ProjectPath $name) -Destination (Join-Path $projectTarget $name)
    }
}

$metadata.ItemCount = $itemCount
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupRoot 'backup-meta.json') -Encoding UTF8

Write-Host ''
Write-Host "Backed up items : $itemCount"
Write-Host "Backup path     : $backupRoot"
