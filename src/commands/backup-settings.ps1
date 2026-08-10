[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global')]
    [string]$Mode = 'Interactive',
    [string]$DestinationRoot = (Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup')
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $SourceRoot 'load-operations.ps1')

function Copy-ExistingItem {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) { return 0 }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    return 1
}

if ($Mode -eq 'Interactive') {
    Write-Host ''
    Write-Host '備份 Codex 設定'
    Write-Host '==============='
    Write-Host '[1] 全域受管理設定、Profile 與 ccusage 狀態'
    Write-Host '[0] 結束'
    Write-Host ''

    switch (Read-Host '請選擇') {
        '1' { $Mode = 'Global' }
        '0' { exit 0 }
        default { throw '選項無效。' }
    }
}

New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
$backupRoot = Join-Path $DestinationRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff-manual')
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

$itemCount = 0
$metadata = [ordered]@{
    Version = 4
    CreatedAt = (Get-Date).ToString('o')
    Mode = $Mode
    PowerShellVersion = [string]$PSVersionTable.PSVersion
}

if ($Mode -eq 'Global') {
    $codexHome = Join-Path $HOME '.codex'
    $globalTarget = Join-Path $backupRoot 'global\.codex'

    foreach ($name in @(
        'AGENTS.md', 'AGENTS.override.md', 'config.toml', 'rules', 'agents', 'skills', 'hooks.json', 'hooks', 'tools',
        '.codex-settings-manifest.json', 'model-router-state.json', 'config.toml.codex-model-router.bak'
    )) {
        $itemCount += Copy-ExistingItem -Source (Join-Path $codexHome $name) -Destination (Join-Path $globalTarget $name)
    }

    $userSkills = Join-Path $HOME '.agents\skills'
    $itemCount += Copy-ExistingItem -Source $userSkills -Destination (Join-Path $backupRoot 'global\.agents\skills')

    $profileItems = New-Object 'System.Collections.Generic.List[object]'
    $profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
    for ($index = 0; $index -lt $profilePaths.Count; $index++) {
        $profilePath = $profilePaths[$index]
        $relativePath = "global\powershell\profile-$($index + 1).ps1"
        $profileExisted = Test-Path -LiteralPath $profilePath -PathType Leaf
        if ($profileExisted) { $itemCount += Copy-ExistingItem -Source $profilePath -Destination (Join-Path $backupRoot $relativePath) }
        [void]$profileItems.Add([ordered]@{
            Path = $profilePath
            Existed = $profileExisted
            BackupRelativePath = if ($profileExisted) { $relativePath } else { $null }
        })
    }

    $ccusage = Get-CcusageState
    $metadata.Global = [ordered]@{
        BackedUpCodexItems = @(
            'AGENTS.md', 'AGENTS.override.md', 'config.toml', 'rules', 'agents', 'skills', 'hooks.json', 'hooks', 'tools',
            '.codex-settings-manifest.json', 'model-router-state.json', 'config.toml.codex-model-router.bak'
        )
        PowerShellProfiles = $profileItems.ToArray()
        Ccusage = [ordered]@{
            Installed = [bool]$ccusage.Installed
            Version = [string]$ccusage.Version
        }
    }
}

$metadata.ItemCount = $itemCount
Write-JsonFileAtomic -Path (Join-Path $backupRoot 'backup-meta.json') -Value $metadata -Depth 12

Write-Host ''
Write-Host "已備份項目：$itemCount"
Write-Host "備份位置：$backupRoot"
